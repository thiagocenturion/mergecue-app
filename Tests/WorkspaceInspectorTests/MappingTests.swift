import Foundation
import MergeCueCore
import Testing
@testable import WorkspaceInspector

@Suite("Mapping")
struct MappingTests {
    static let exactURLs = [
        "https://github.com/acme/payments-api.git",
        "https://github.com/Acme/Payments-API",
        "git@github.com:acme/payments-api.git",
        "ssh://git@github.com/acme/payments-api.git",
        "ssh://git@ssh.github.com:443/acme/payments-api.git",
        "https://user:ghp_abcdefghijklmnopqrstuvwxyz0123456789@github.com/acme/payments-api.git",
    ]

    @Test(arguments: exactURLs)
    func exactMatchAcrossTransports(url: String) async throws {
        let sandbox = try GitSandbox()
        let repo = try sandbox.initRepo("r", remote: url)
        let suggestion = await sandbox.inspector().match(repo: RemoteScenario.repository, checkoutPath: repo.path)
        #expect(suggestion.confidence == .exact)
        #expect(suggestion.reason.contains("github.com/acme/payments-api"))
        #expect(!(suggestion.matchedRemote ?? "").contains("ghp_"))
    }

    @Test func pushURLAloneCanMatch() async throws {
        let sandbox = try GitSandbox()
        let repo = try sandbox.initRepo("r", remote: "https://example.com/mirror/other.git")
        try sandbox.git(["remote", "set-url", "--push", "origin", "git@github.com:acme/payments-api.git"], in: repo)
        let suggestion = await sandbox.inspector().match(repo: RemoteScenario.repository, checkoutPath: repo.path)
        #expect(suggestion.confidence == .exact)
    }

    @Test func forkRemoteIsProbable() async throws {
        let sandbox = try GitSandbox()
        let repo = try sandbox.initRepo("r", remote: "git@github.com:contrib/payments-api.git")
        let suggestion = await sandbox.inspector().match(repo: RemoteScenario.repository, checkoutPath: repo.path)
        #expect(suggestion.confidence == .probable)
        #expect(suggestion.reason.contains("fork"))
    }

    @Test func forkPlusUpstreamIsExact() async throws {
        let sandbox = try GitSandbox()
        let repo = try sandbox.initRepo("r", remote: "git@github.com:contrib/payments-api.git")
        try sandbox.git(["remote", "add", "upstream", "https://github.com/acme/payments-api"], in: repo)
        let suggestion = await sandbox.inspector().match(repo: RemoteScenario.repository, checkoutPath: repo.path)
        #expect(suggestion.confidence == .exact)
        #expect(suggestion.reason.contains("'upstream'"))
    }

    @Test func otherRepositoryIsMismatch() async throws {
        let sandbox = try GitSandbox()
        let repo = try sandbox.initRepo("r", remote: "https://gitlab.com/acme/billing.git")
        let suggestion = await sandbox.inspector().match(repo: RemoteScenario.repository, checkoutPath: repo.path)
        #expect(suggestion.confidence == .mismatch)
        #expect(suggestion.reason.contains("gitlab.com/acme/billing"))
    }

    @Test func notARepositoryOrMissingIsMismatch() async throws {
        let sandbox = try GitSandbox()
        let plain = sandbox.url("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let inspector = sandbox.inspector()
        #expect(await inspector.match(repo: RemoteScenario.repository, checkoutPath: plain.path).confidence == .mismatch)
        #expect(await inspector.match(repo: RemoteScenario.repository, checkoutPath: sandbox.url("missing").path).confidence == .mismatch)
    }

    @Test func folderNameWithoutRemotesIsProbable() async throws {
        let sandbox = try GitSandbox()
        let repo = try sandbox.initRepo("code/payments-api")
        let suggestion = await sandbox.inspector().match(repo: RemoteScenario.repository, checkoutPath: repo.path)
        #expect(suggestion.confidence == .probable)
    }

    @Test func suggestMappingsScansRootsToBoundedDepth() async throws {
        let sandbox = try GitSandbox()
        let exact = try sandbox.initRepo("dev/acme/payments-api", remote: RemoteScenario.originSSH)
        let fork = try sandbox.initRepo("dev/forks/pa", remote: RemoteScenario.forkHTTPS)
        _ = try sandbox.initRepo("dev/acme/billing", remote: "https://github.com/acme/billing.git")
        _ = try sandbox.initRepo("dev/node_modules/payments-api", remote: RemoteScenario.originHTTPS)
        _ = try sandbox.initRepo("dev/.hidden/payments-api", remote: RemoteScenario.originHTTPS)
        _ = try sandbox.initRepo("dev/a/b/c/d/e/payments-api", remote: RemoteScenario.originHTTPS)
        // A repository nested inside another checkout is not scanned (the outer one is the candidate).
        _ = try sandbox.initRepo("dev/acme/payments-api/vendor-copy", remote: RemoteScenario.originHTTPS)

        let suggestions = await sandbox.inspector().suggestMappings(
            for: RemoteScenario.repository, searchRoots: [sandbox.url("dev").path, sandbox.url("missing-root").path]
        )

        #expect(suggestions.map(\.checkoutPath) == [exact.path, fork.path])
        #expect(suggestions.map(\.confidence) == [.exact, .probable])
    }
}
