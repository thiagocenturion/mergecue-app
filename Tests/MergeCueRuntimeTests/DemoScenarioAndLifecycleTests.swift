import Darwin
import Foundation
import MergeCueCore
import MergeCueFixtures
import MergeCueIPC
import MergeCueNetworking
import Testing
@testable import MergeCueRuntime

/// A private, short temporary directory (`/private/tmp/mcrt-XXXXXX`).
func makeTemporaryHome(prefix: String = "mcrt") throws -> URL {
    var template = Array("/tmp/\(prefix)-XXXXXX".utf8CString)
    guard let created = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
    let path = String(cString: created)
    let resolved = realpath(path, nil).map { pointer -> String in
        defer { free(pointer) }
        return String(cString: pointer)
    } ?? path
    return URL(filePath: resolved, directoryHint: .isDirectory)
}

/// Runs git read-only in `directory` with a hermetic config.
func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "HOME": directory.path(percentEncoded: false)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite("Demo scenario (fixtures)")
struct DemoScenarioTests {
    @Test func syntheticRepositoryIsDeterministicCleanAndRoutedLocally() throws {
        let first = try makeTemporaryHome()
        let second = try makeTemporaryHome()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let a = try DemoRepository.prepare(in: first)
        let b = try DemoRepository.prepare(in: second)
        #expect(a.headSHA == b.headSHA && a.baseSHA == b.baseSHA)
        #expect(a.headSHA != a.baseSHA)
        // Reused on relaunch.
        #expect(try DemoRepository.prepare(in: first).headSHA == a.headSHA)
        // The bare "remote" serves every provider's ref at the PR head.
        for ref in ["refs/pull/42/head", "refs/merge-requests/42/head"] + DemoRepository.sourceBranches.map({ "refs/heads/\($0)" }) {
            #expect(try git(["rev-parse", ref], in: a.bareRepository) == a.headSHA, "\(ref)")
        }
        // The checkout: clean, on the PR branch, provider URLs rewritten in its own config only.
        #expect(try git(["status", "--porcelain"], in: a.checkout).isEmpty)
        #expect(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: a.checkout) == DemoRepository.checkoutBranch)
        #expect(try git(["remote", "get-url", "origin"], in: a.checkout) == a.bareRepository.path(percentEncoded: false).trimmingSuffix("/"))
        #expect(try git(["config", "--local", "--get", "remote.gitlab.url"], in: a.checkout) == "https://gitlab.com/acme/payments-api.git")
        let rewrites = try git(["config", "--local", "--get-regexp", #"^url\..*\.insteadof$"#], in: a.checkout)
        #expect(rewrites.split(separator: "\n").count == DemoRepository.rewrittenURLs.count)
        // The GitHub step-1 comment's anchor: ChargeService.swift:84 logs the full card number.
        let source = try String(contentsOf: a.checkout.appending(path: "Sources/Payments/ChargeService.swift"), encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        #expect(lines[83].contains("request.cardNumber"))
    }

    @Test func stepsAdvancePersistAndClamp() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scenario = try DemoScenario(directory: home)
        #expect(scenario.steps.values.filter { $0 != 0 }.isEmpty)
        scenario.advance([.gitlab])
        #expect(scenario.step(for: .gitlab) == 1 && scenario.step(for: .github) == 0)
        scenario.advance()
        scenario.advance()
        scenario.advance()
        #expect(scenario.steps.values.filter { $0 != DemoScenario.maxStep }.isEmpty)
        let reloaded = try DemoScenario(directory: home)
        #expect(reloaded.steps == scenario.steps)
        #expect(DemoScenario.accounts.filter { !$0.isDemo }.isEmpty)
        #expect(Set(DemoScenario.accounts.map(\.kind)) == Set(ProviderKind.allCases))
    }

    @Test func transportRewritesFixtureSHAsBothWays() async throws {
        let base = URL(string: "https://api.example.test")!
        let stub = StubTransport(routes: [
            .fixed("GET", "/commits/aaaaaaaaaaaa/status", response: StubTransport.json(#"{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","short":"aaaaaaaaaaaa"}"#)),
        ], baseURL: base)
        let real = "0123456789abcdef0123456789abcdef01234567"
        let transport = DemoScenarioTransport(stub: stub, substitutions: [
            .init(fixture: String(repeating: "a", count: 40), real: real),
            .init(fixture: String(repeating: "a", count: 12), real: String(real.prefix(12))),
        ])
        let response = try await transport.send(HTTPRequest(url: base.appending(path: "commits/\(real.prefix(12))/status")))
        #expect(response.status == 200)
        #expect(response.bodyText == #"{"sha":"\#(real)","short":"\#(real.prefix(12))"}"#)
        #expect(stub.requests.first?.url.path == "/commits/aaaaaaaaaaaa/status")
        #expect(response.url.path.contains(String(real.prefix(12))))
    }

    @Test func onlyMutationsCountAsProviderWrites() throws {
        let graphQLRead = HTTPRequest(method: "POST", url: URL(string: "https://api.github.com/graphql")!, body: Data(#"{"operationName":"MergeCueSearch","query":"query MergeCueSearch"}"#.utf8))
        let graphQLWrite = HTTPRequest(method: "POST", url: URL(string: "https://api.github.com/graphql")!, body: Data(#"{"operationName":"MergeCueResolveThread","query":"mutation MergeCueResolveThread"}"#.utf8))
        #expect(!DemoScenario.isWrite(graphQLRead, kind: .github))
        #expect(DemoScenario.isWrite(graphQLWrite, kind: .github))
        #expect(DemoScenario.isWrite(HTTPRequest(method: "POST", url: URL(string: "https://gitlab.com/api/v4/x")!), kind: .gitlab))
        #expect(!DemoScenario.isWrite(HTTPRequest(url: URL(string: "https://gitlab.com/api/v4/x")!), kind: .gitlab))
    }
}

@Suite("Runtime lifecycle", .serialized)
struct RuntimeLifecycleTests {
    @Test func liveRuntimeServesIPCAndRemovesTheSocketOnStop() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = MergeCuePaths(root: home, fallbackSocketParent: home)
        let options = RuntimeOptions(credentials: InMemoryCredentialStore(), monitorsNetwork: false, mappingSearchRoots: [])
        let runtime = try await MergeCueRuntime.makeLive(paths: paths, appVersion: "9.9.9", options: options)
        #expect(runtime.mode == .live && !runtime.isDemo)
        try await runtime.start()
        try await runtime.start() // idempotent
        #expect(await runtime.isRunning)
        let status = await runtime.ipcStatus()
        #expect(status.isRunning)
        #expect(FileManager.default.fileExists(atPath: paths.socketPath))

        let client = IPCClient(paths: paths, clientInfo: IPCClientInfo(name: "runtime-test", version: "1", pid: getpid()))
        let pong = try await client.ping()
        #expect(pong.appVersion == "9.9.9")
        #expect(pong.isDemo == false)

        // A second instance on the same socket is refused.
        let second = try await MergeCueRuntime.makeLive(paths: paths, appVersion: "9.9.9", options: options)
        await #expect(throws: RuntimeError.alreadyRunning(socketPath: paths.socketPath)) { try await second.start() }

        await runtime.handleSystemWake()
        await runtime.stop()
        #expect(!FileManager.default.fileExists(atPath: paths.socketPath))
        #expect(!(await runtime.ipcStatus().isRunning))
        await #expect(throws: IPCError.self) { _ = try await client.ping() }
        #expect(runtime.loginItemStatus() == .unavailable)
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
