import Foundation
import MergeCueCore
import Testing
@testable import WorkspaceInspector

@Suite("Choose Folder and single-pass checkout scan")
struct CheckoutScanTests {
    static func repository(_ owner: String, _ name: String, id: String) -> Repository {
        Repository(
            key: RepoKey(account: AccountKey(kind: .github, host: "github.com", remoteUserID: "1"), remoteRepoID: id),
            namespacePath: owner, name: name, fullPath: "\(owner)/\(name)",
            webURL: URL(string: "https://github.com/\(owner)/\(name)")!,
            cloneURLs: ["https://github.com/\(owner)/\(name).git", "git@github.com:\(owner)/\(name).git"]
        )
    }

    /// The owner's failing path: a subfolder of the clone, with SSH / no-.git / differently-cased remotes.
    @Test(arguments: [
        "git@github.com:acme/payments-api.git",
        "https://github.com/acme/payments-api",
        "git@github.com:Acme/Payments-API.git",
    ])
    func subfolderResolvesToTopLevelAndMatchesExactly(remote: String) async throws {
        let sandbox = try GitSandbox()
        let repo = try sandbox.initRepo("code/payments-api", remote: remote)
        let sub = repo.appending(path: "Sources/App")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let suggestion = await sandbox.inspector().match(repo: RemoteScenario.repository, checkoutPath: sub.path)
        #expect(suggestion.confidence == .exact)
        #expect(suggestion.checkoutPath == GitWorkspaceInspector.canonicalPath(repo.path))
    }

    @Test func oneWalkMatchesManyRepositories() async throws {
        let sandbox = try GitSandbox()
        var repos: [Repository] = []
        for index in 0..<30 {
            let name = "svc-\(index)"
            repos.append(Self.repository("acme", name, id: "\(index)"))
            if index % 3 == 0 {
                _ = try sandbox.initRepo("root/team/\(name)", remote: "git@github.com:acme/\(name).git")
            }
        }
        _ = try sandbox.initRepo("root/forks/svc-1", remote: "https://github.com/someone/svc-1")  // fork → probable
        _ = try sandbox.initRepo("root/other/unrelated", remote: "https://gitlab.com/x/unrelated.git")
        try FileManager.default.createDirectory(at: sandbox.url("root/node_modules/svc-2/.git"), withIntermediateDirectories: true)
        let seen = Locked<[CheckoutScanProgress]>([])
        let result = await sandbox.inspector().scanCheckouts(for: repos, searchRoots: [sandbox.url("root").path, sandbox.url("root/team").path]) {
            progress in seen.update { $0.append(progress) }
        }
        #expect(result.checkoutsFound == 12, "10 exact + fork + unrelated; node_modules skipped, nested root not walked twice")
        #expect(!result.wasCancelled && !result.isTruncated)
        for index in stride(from: 0, to: 30, by: 3) {
            let found = try #require(result.suggestions[repos[index].key])
            #expect(found.map(\.confidence) == [.exact])
        }
        #expect(result.suggestions[repos[1].key]?.first?.confidence == .probable)
        #expect(result.suggestions[repos[2].key] == nil)
        #expect(seen.get().last?.isMatching == true)
    }

    @Test func cancelledScanReportsIt() async throws {
        let sandbox = try GitSandbox()
        _ = try sandbox.initRepo("root/a", remote: "git@github.com:acme/a.git")
        let task = Task { await sandbox.inspector().scanCheckouts(for: [Self.repository("acme", "a", id: "a")], searchRoots: [sandbox.url("root").path]) { _ in } }
        task.cancel()
        let result = await task.value
        #expect(result.wasCancelled)
        #expect(result.suggestions.isEmpty)
    }
}

/// Minimal lock for collecting progress callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}
