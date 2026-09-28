import Darwin
import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueFixtures
import MergeCueNetworking
import MergeCueRuntime
import Synchronization
import Testing

/// Records Sync's grouped notifications instead of delivering them.
final class RecordingNotifier: NotificationDelivering {
    private let storage = Mutex<[GroupedNotification]>([])

    var delivered: [GroupedNotification] { storage.withLock { $0 } }

    func deliver(_ notification: GroupedNotification) async {
        storage.withLock { $0.append(notification) }
    }
}

/// A short, private `MERGECUE_HOME` under /tmp (`/private/tmp/mcint-XXXXXX`, symlinks resolved) so the IPC socket
/// path stays well below the 104-byte limit. Removed by `remove()`.
struct TestHome: Sendable {
    let root: URL

    static func make(prefix: String = "mcint") throws -> TestHome {
        var template = Array("/tmp/\(prefix)-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
        let path = String(cString: created)
        let resolved = realpath(path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? path
        return TestHome(root: URL(filePath: resolved, directoryHint: .isDirectory))
    }

    var path: String { MergeCuePaths.fileSystemPath(root) }

    /// Paths as the runtime and `mergecue-mcp` (with `MERGECUE_HOME=root`) resolve them.
    var paths: MergeCuePaths { MergeCuePaths(root: root, fallbackSocketParent: root) }

    /// Environment for spawned helpers / simulators.
    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[MergeCuePaths.homeEnvironmentKey] = path
        environment.removeValue(forKey: MergeCuePaths.socketEnvironmentKey)
        return environment
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// SwiftPM products built next to the tests (`swift build` / `swift test` build every product).
enum BuiltProducts {
    static func url(_ name: String) -> URL? {
        guard let root = MCPHelperLocator.packageRoot else { return nil }
        for candidate in [".build/debug/\(name)", ".build/arm64-apple-macosx/debug/\(name)"] {
            let url = root.appending(path: candidate)
            if FileManager.default.isExecutableFile(atPath: MergeCuePaths.fileSystemPath(url)) { return url }
        }
        return nil
    }

    static var mcp: URL? { url("mergecue-mcp") }
    static var agentSim: URL? { url("mergecue-agent-sim") }
}

/// Result of a child process.
struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

/// Runs `executable` to completion (bounded by `timeout`), capturing stdout/stderr.
func runProcess(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 120) async throws -> ProcessOutput {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let outData = Mutex(Data())
    let errData = Mutex(Data())
    out.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil } else { outData.withLock { $0.append(chunk) } }
    }
    err.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil } else { errData.withLock { $0.append(chunk) } }
    }
    let finished = Mutex(false)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        process.terminationHandler = { _ in
            let first = finished.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { continuation.resume() }
        }
        do {
            try process.run()
        } catch {
            finished.withLock { $0 = true }
            continuation.resume(throwing: error)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
    }
    // Let the readability handlers drain.
    try? await Task.sleep(for: .milliseconds(200))
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil
    outData.withLock { $0.append(out.fileHandleForReading.readDataToEndOfFile()) }
    errData.withLock { $0.append(err.fileHandleForReading.readDataToEndOfFile()) }
    let timedOut = process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM
    return ProcessOutput(
        status: process.terminationStatus,
        stdout: String(decoding: outData.withLock { $0 }, as: UTF8.self),
        stderr: String(decoding: errData.withLock { $0 }, as: UTF8.self),
        timedOut: timedOut
    )
}

/// A demo runtime in a private home, driven by a `TestClock` (no automatic polling, deterministic leases).
final class DemoHarness: Sendable {
    let home: TestHome
    let clock: TestClock
    let notifier: RecordingNotifier
    let runtime: MergeCueRuntime

    var engine: MergeCueEngine { runtime.engine }
    var scenario: DemoScenario { runtime.demo! }

    init(home: TestHome, clock: TestClock, notifier: RecordingNotifier, runtime: MergeCueRuntime) {
        self.home = home
        self.clock = clock
        self.notifier = notifier
        self.runtime = runtime
    }

    static func start(
        home: TestHome? = nil,
        ipc: Bool = false,
        leaseDuration: TimeInterval = 600,
        clock: TestClock = TestClock(now: Date(timeIntervalSince1970: 1_790_100_000))
    ) async throws -> DemoHarness {
        let home = try home ?? TestHome.make()
        let notifier = RecordingNotifier()
        let options = RuntimeOptions(
            clock: clock, leaseDuration: leaseDuration, notifier: notifier, startsIPCServer: ipc,
            peerValidation: .automatic, mcpHelperOverride: BuiltProducts.mcp, mappingSearchRoots: []
        )
        let runtime = try await MergeCueRuntime.makeDemo(paths: home.paths, appVersion: "0.0.0-test", options: options)
        try await runtime.start()
        return DemoHarness(home: home, clock: clock, notifier: notifier, runtime: runtime)
    }

    func stop(removeHome: Bool = true) async {
        await runtime.stop()
        if removeHome { home.remove() }
    }

    func items(_ kind: ProviderKind? = nil) async throws -> [AttentionItem] {
        try await engine.attentionItems(AttentionQuery(provider: kind))
    }

    /// The attention item of a review thread of #42 on `kind`.
    func threadItem(_ kind: ProviderKind, threadRemoteID: String) async throws -> AttentionItem? {
        try await items(kind).first { $0.thread?.remoteID == threadRemoteID && $0.changeRequest.number == 42 }
    }

    /// Runs `mergecue-agent-sim` against this runtime's socket and decodes its JSON report.
    func runAgentSim(scenario: String, taskID: TaskID?, extra: [String] = [], timeout: TimeInterval = 90) async throws -> (report: JSONValue, output: ProcessOutput) {
        let sim = try #require(BuiltProducts.agentSim, "mergecue-agent-sim is not built; run swift build first")
        let mcp = try #require(BuiltProducts.mcp, "mergecue-mcp is not built; run swift build first")
        var arguments = ["--mcp", MergeCuePaths.fileSystemPath(mcp), "--scenario", scenario, "--timeout", "\(Int(timeout))"]
        if let taskID { arguments += ["--task", taskID.rawValue] }
        arguments += extra
        let output = try await runProcess(sim, arguments, environment: home.environment, timeout: timeout + 15)
        let report = try JSONValue.defaultDecoder().decode(JSONValue.self, from: Data(output.stdout.utf8))
        return (report, output)
    }
}

extension JSONValue {
    /// Failed steps of an agent-sim report (for diagnostics).
    var failedSimSteps: [String] {
        (self["steps"]?.arrayValue ?? []).filter { $0["ok"]?.boolValue == false }.map { $0.jsonString() }
    }
}
