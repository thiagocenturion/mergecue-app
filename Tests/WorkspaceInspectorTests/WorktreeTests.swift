import Foundation
import MergeCueCore
import Testing
@testable import WorkspaceInspector

@Suite("Worktrees")
struct WorktreeTests {
    func request(
        _ sandbox: GitSandbox, checkout: URL, task: String = "abc123",
        urls: [String] = [RemoteScenario.originHTTPS], refspec: String = "refs/pull/42/head",
        expected: String? = nil, isFork: Bool = false
    ) -> WorktreeRequest {
        WorktreeRequest(
            taskID: .sample(task),
            checkoutPath: checkout.path,
            fetch: FetchHeadSpec(remoteURLs: urls, refspec: refspec, expectedSHA: expected, isFork: isFork),
            destinationRoot: sandbox.worktreeRoot.path
        )
    }

    @Test func pullRequestHeadInIsolatedWorktree() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)
        let inspector = sandbox.inspector()

        let prepared = try await inspector.prepareWorktree(request(sandbox, checkout: checkout, expected: scenario.pullSHA))

        #expect(prepared.path == sandbox.worktreeRoot.appending(path: "mc_abc123").path)
        #expect(prepared.baseSHA == scenario.pullSHA)
        #expect(prepared.localRef == "refs/mergecue/tasks/mc_abc123")
        let worktree = URL(fileURLWithPath: prepared.path)
        #expect(try sandbox.git(["rev-parse", "HEAD"], in: worktree) == scenario.pullSHA)
        #expect(try sandbox.read(worktree.appending(path: "src/app.txt")) == RemoteScenario.appPull)
        let info = try await inspector.inspect(path: prepared.path)
        #expect(info.safety == .detached)
        #expect(try sandbox.git(["rev-parse", prepared.localRef], in: checkout) == scenario.pullSHA)
        #expect(try await inspector.inspect(path: checkout.path).worktrees.contains(prepared.path))
        // No FETCH_HEAD, no remote-tracking update, no branch/index/working-tree/stash change.
        #expect(!FileManager.default.fileExists(atPath: checkout.appending(path: ".git/FETCH_HEAD").path))
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func dirtyCheckoutStaysUntouchedWhilePreparing() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        try sandbox.write("work in progress\n", to: checkout.appending(path: "README.md"))
        try sandbox.write("scratch\n", to: checkout.appending(path: "scratch.txt"))
        try sandbox.git(["add", "scratch.txt"], in: checkout)
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)

        let prepared = try await sandbox.inspector().prepareWorktree(request(sandbox, checkout: checkout))

        #expect(prepared.baseSHA == scenario.pullSHA)
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func gitLabMergeRequestViaMatchingSSHRemote() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let prepared = try await sandbox.inspector().prepareWorktree(request(
            sandbox, checkout: checkout, urls: [RemoteScenario.originSSH], refspec: "refs/merge-requests/7/head",
            expected: String(scenario.mergeRequestSHA.prefix(12))
        ))
        #expect(prepared.baseSHA == scenario.mergeRequestSHA)
        #expect(FileManager.default.fileExists(atPath: prepared.path + "/docs/mr.md"))
    }

    @Test func forkHeadIsFetchedDirectlyFromItsURL() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)
        let prepared = try await sandbox.inspector().prepareWorktree(request(
            sandbox, checkout: checkout, urls: [RemoteScenario.forkHTTPS], refspec: "refs/heads/feature-x",
            expected: scenario.forkSHA, isFork: true
        ))
        #expect(prepared.baseSHA == scenario.forkSHA)
        #expect(try sandbox.read(URL(fileURLWithPath: prepared.path).appending(path: "fork.txt")) == "from the fork\n")
        // No remote was added for the fork.
        #expect(try sandbox.git(["remote"], in: checkout) == "origin")
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func shaMismatchIsRejectedAndCleanedUp() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)
        await #expect(throws: WorkspaceError.headMismatch(expected: scenario.baseSHA, actual: scenario.pullSHA)) {
            try await sandbox.inspector().prepareWorktree(request(sandbox, checkout: checkout, expected: scenario.baseSHA))
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.worktreeRoot.appending(path: "mc_abc123").path))
        #expect(try sandbox.git(["for-each-ref", "refs/mergecue/"], in: checkout).isEmpty)
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func missingRefIsReportedClearly() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        do {
            _ = try await sandbox.inspector().prepareWorktree(request(sandbox, checkout: checkout, refspec: "refs/pull/99/head"))
            Issue.record("expected fetchFailed")
        } catch let WorkspaceError.fetchFailed(message) {
            #expect(message.contains("refs/pull/99/head was not found"))
            #expect(message.contains("github.com/acme/payments-api"))
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.worktreeRoot.appending(path: "mc_abc123").path))
    }

    @Test func unreachableRemoteIsReportedClearly() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        do {
            _ = try await sandbox.inspector().prepareWorktree(request(
                sandbox, checkout: checkout, urls: [RemoteScenario.goneHTTPS], refspec: "refs/heads/main"
            ))
            Issue.record("expected fetchFailed")
        } catch let WorkspaceError.fetchFailed(message) {
            #expect(message.contains("could not fetch from https://github.com/acme/gone.git"))
        }
    }

    @Test func invalidRequestsAreRejectedBeforeTouchingGit() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let inspector = sandbox.inspector()
        for refspec in ["refs/pull/42/head:refs/heads/main", "+refs/pull/42/head", "main", "refs/heads/a b", "refs/heads/bad..name"] {
            await #expect(throws: WorkspaceError.self) {
                try await inspector.prepareWorktree(request(sandbox, checkout: checkout, refspec: refspec))
            }
        }
        for url in ["--upload-pack=touch /tmp/pwned", "ext::sh -c touch% /tmp/pwned"] {
            await #expect(throws: WorkspaceError.self) {
                try await inspector.prepareWorktree(request(sandbox, checkout: checkout, urls: [url]))
            }
        }
        var outside = request(sandbox, checkout: checkout)
        outside.destinationRoot = sandbox.url("elsewhere").path
        await #expect(throws: WorkspaceError.pathOutsideCheckout(sandbox.url("elsewhere").path)) {
            try await inspector.prepareWorktree(outside)
        }
        await #expect(throws: WorkspaceError.self) {
            try await inspector.prepareWorktree(request(sandbox, checkout: checkout, expected: "not-a-sha"))
        }
        let plain = sandbox.url("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        await #expect(throws: WorkspaceError.notARepository(path: plain.path)) {
            try await inspector.prepareWorktree(request(sandbox, checkout: plain))
        }
        #expect(try sandbox.git(["for-each-ref", "refs/mergecue/"], in: checkout).isEmpty)
    }

    @Test func existingDestinationIsNotReused() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let inspector = sandbox.inspector()
        _ = try await inspector.prepareWorktree(request(sandbox, checkout: checkout))
        await #expect(throws: WorkspaceError.self) {
            try await inspector.prepareWorktree(request(sandbox, checkout: checkout))
        }
    }

    @Test func gitButlerCheckoutGetsAnIndependentClone() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        try scenario.makeGitButlerWorkspace(checkout)
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)
        let worktreesBefore = try sandbox.git(["worktree", "list", "--porcelain"], in: checkout)
        let inspector = sandbox.inspector()

        let prepared = try await inspector.prepareWorktree(request(sandbox, checkout: checkout, expected: scenario.pullSHA))

        let clone = URL(fileURLWithPath: prepared.path)
        #expect(prepared.baseSHA == scenario.pullSHA)
        #expect(try sandbox.git(["rev-parse", "HEAD"], in: clone) == scenario.pullSHA)
        #expect(try sandbox.git(["rev-parse", prepared.localRef], in: clone) == scenario.pullSHA)
        // An independent repository: its own .git directory, no alternates back into the GitButler repo.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: clone.appending(path: ".git").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: clone.appending(path: ".git/objects/info/alternates").path))
        #expect(try sandbox.git(["config", "remote.origin.url"], in: clone) == RemoteScenario.originHTTPS)
        // Nothing was written into the GitButler repository.
        #expect(try sandbox.git(["worktree", "list", "--porcelain"], in: checkout) == worktreesBefore)
        #expect(try sandbox.git(["for-each-ref", "refs/mergecue/"], in: checkout).isEmpty)
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)

        try await inspector.removeWorktree(path: prepared.path, checkoutPath: checkout.path)
        #expect(!FileManager.default.fileExists(atPath: prepared.path))
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func removeWorktreeDeletesWorktreeAndPrivateRef() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)
        let inspector = sandbox.inspector()
        let prepared = try await inspector.prepareWorktree(request(sandbox, checkout: checkout))
        try sandbox.write("agent edit\n", to: URL(fileURLWithPath: prepared.path).appending(path: "README.md"))

        try await inspector.removeWorktree(path: prepared.path, checkoutPath: checkout.path)

        #expect(!FileManager.default.fileExists(atPath: prepared.path))
        #expect(try await inspector.inspect(path: checkout.path).worktrees == [checkout.path])
        #expect(try sandbox.git(["for-each-ref", "refs/mergecue/"], in: checkout).isEmpty)
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
        // Idempotent.
        try await inspector.removeWorktree(path: prepared.path, checkoutPath: checkout.path)
    }

    @Test func removeWorktreeRefusesForeignPaths() async throws {
        let sandbox = try GitSandbox()
        let scenario = try RemoteScenario(sandbox: sandbox)
        let checkout = try scenario.userCheckout()
        let inspector = sandbox.inspector()

        await #expect(throws: WorkspaceError.pathOutsideCheckout(checkout.path)) {
            try await inspector.removeWorktree(path: checkout.path, checkoutPath: checkout.path)
        }
        await #expect(throws: WorkspaceError.self) {
            try await inspector.removeWorktree(path: sandbox.worktreeRoot.path, checkoutPath: checkout.path)
        }
        let escape = sandbox.worktreeRoot.path + "/../../work/payments-api"
        await #expect(throws: WorkspaceError.self) {
            try await inspector.removeWorktree(path: escape, checkoutPath: checkout.path)
        }
        // A symlink inside the root that points at the user's checkout.
        try FileManager.default.createDirectory(at: sandbox.worktreeRoot, withIntermediateDirectories: true)
        let link = sandbox.worktreeRoot.appending(path: "mc_link00")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: checkout)
        await #expect(throws: WorkspaceError.self) {
            try await inspector.removeWorktree(path: link.path, checkoutPath: checkout.path)
        }
        // A directory under the root that MergeCue did not create.
        let stranger = sandbox.worktreeRoot.appending(path: "mc_zzz999")
        try sandbox.write("keep\n", to: stranger.appending(path: "file.txt"))
        await #expect(throws: WorkspaceError.self) {
            try await inspector.removeWorktree(path: stranger.path, checkoutPath: checkout.path)
        }
        #expect(FileManager.default.fileExists(atPath: stranger.appending(path: "file.txt").path))
        #expect(FileManager.default.fileExists(atPath: checkout.appending(path: "README.md").path))
    }
}
