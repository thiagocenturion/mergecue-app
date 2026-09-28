import Foundation
import MergeCueCore
import Testing
@testable import WorkspaceInspector

/// A prepared PR worktree with agent edits, plus the user's checkout on the reviewed PR head.
struct PatchScenario {
    let sandbox: GitSandbox
    let scenario: RemoteScenario
    let checkout: URL
    let worktree: URL
    let prepared: PreparedWorktree
    let inspector: GitWorkspaceInspector

    static let appAgent = "line1\nline2 from the agent\nline3\nline4\nline5\n"

    init() async throws {
        sandbox = try GitSandbox()
        scenario = try RemoteScenario(sandbox: sandbox)
        checkout = try scenario.userCheckout()
        inspector = sandbox.inspector()
        prepared = try await inspector.prepareWorktree(WorktreeRequest(
            taskID: .sample("pat123"), checkoutPath: checkout.path,
            fetch: FetchHeadSpec(remoteURLs: [RemoteScenario.originHTTPS], refspec: "refs/pull/42/head"),
            destinationRoot: sandbox.worktreeRoot.path
        ))
        worktree = URL(fileURLWithPath: prepared.path)
        // The user reviews the PR on a local branch at its head.
        try sandbox.git(["checkout", "-q", "-b", "review-42", prepared.localRef], in: checkout)
    }

    /// Agent edits: a modification and a new untracked file.
    func agentEdits() throws {
        try sandbox.write(Self.appAgent, to: worktree.appending(path: "src/app.txt"))
        try sandbox.write("brand new\n", to: worktree.appending(path: "src/new.txt"))
    }
}

@Suite("Changes and patches")
struct ChangesAndPatchTests {
    @Test func changesIncludeCommittedUncommittedAndUntracked() async throws {
        let setup = try await PatchScenario()
        let sandbox = setup.sandbox, worktree = setup.worktree
        try sandbox.write("committed by agent\n", to: worktree.appending(path: "docs/agent.md"))
        let committed = try sandbox.commitAll(worktree, "Agent commit")
        try setup.agentEdits()
        try FileManager.default.removeItem(at: worktree.appending(path: "README.md"))
        let indexPath = try sandbox.git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: worktree)
        let indexBefore = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let checkoutBefore = try CheckoutSnapshot(setup.checkout, sandbox: sandbox)

        let changes = try await setup.inspector.changes(inWorktree: worktree.path, since: setup.prepared.baseSHA, maxBytes: 100_000)

        let byPath = Dictionary(uniqueKeysWithValues: changes.changedPaths.map { ($0.path, $0.status) })
        #expect(byPath == [
            "docs/agent.md": .added, "src/app.txt": .modified, "src/new.txt": .added, "README.md": .removed,
        ])
        #expect(changes.headSHA == committed)
        #expect(changes.hasUncommittedChanges)
        #expect(!changes.truncated)
        #expect(changes.unifiedDiff.contains("+brand new"))
        #expect(changes.unifiedDiff.contains("+line2 from the agent"))
        #expect(changes.unifiedDiff.contains("+committed by agent"))
        #expect(changes.unifiedDiff.contains("diff --git a/src/new.txt b/src/new.txt"))
        // The worktree's real index is untouched (intent-to-add happened in a temporary index copy).
        #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == indexBefore)
        #expect(try sandbox.git(["status", "--porcelain"], in: worktree).contains("?? src/new.txt"))
        #expect(try CheckoutSnapshot(setup.checkout, sandbox: sandbox) == checkoutBefore)
    }

    @Test func cleanWorktreeHasNoChanges() async throws {
        let setup = try await PatchScenario()
        let changes = try await setup.inspector.changes(inWorktree: setup.worktree.path, since: setup.prepared.baseSHA, maxBytes: 10_000)
        #expect(changes.changedPaths.isEmpty)
        #expect(changes.unifiedDiff.isEmpty)
        #expect(!changes.hasUncommittedChanges)
        #expect(changes.headSHA == setup.prepared.baseSHA)
    }

    @Test func diffIsBoundedOnCharacterBoundaries() async throws {
        let setup = try await PatchScenario()
        try setup.sandbox.write(String(repeating: "ünïcødé 🇧🇷 ", count: 400), to: setup.worktree.appending(path: "wide.txt"))
        let changes = try await setup.inspector.changes(inWorktree: setup.worktree.path, since: setup.prepared.baseSHA, maxBytes: 301)
        #expect(changes.truncated)
        #expect(changes.unifiedDiff.utf8.count <= 301)
        #expect(!changes.unifiedDiff.contains("\u{FFFD}"))
        #expect(changes.changedPaths == [ChangedPath(path: "wide.txt", status: .added)])
    }

    @Test func changesRejectUnknownBase() async throws {
        let setup = try await PatchScenario()
        await #expect(throws: WorkspaceError.self) {
            try await setup.inspector.changes(inWorktree: setup.worktree.path, since: String(repeating: "a", count: 40), maxBytes: 100)
        }
        await #expect(throws: WorkspaceError.self) {
            try await setup.inspector.changes(inWorktree: setup.worktree.path, since: "--output=/tmp/x", maxBytes: 100)
        }
    }

    @Test func checkThenApplyWritesWorkingTreeOnly() async throws {
        let setup = try await PatchScenario()
        let sandbox = setup.sandbox, checkout = setup.checkout
        try setup.agentEdits()
        let patch = try await setup.inspector.changes(inWorktree: setup.worktree.path, since: setup.prepared.baseSHA, maxBytes: 100_000).unifiedDiff
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)

        let check = try await setup.inspector.checkPatch(patch, into: checkout.path, expectedHeadSHA: setup.prepared.baseSHA)
        #expect(check.canApply)
        #expect(check.problems.isEmpty)
        #expect(check.targetHeadSHA == setup.prepared.baseSHA)
        #expect(check.targetSafety == .safe)
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)

        let applied = try await setup.inspector.applyPatch(patch, into: checkout.path, expectedHeadSHA: setup.prepared.baseSHA)
        #expect(applied.canApply)
        #expect(try sandbox.read(checkout.appending(path: "src/app.txt")) == PatchScenario.appAgent)
        #expect(try sandbox.read(checkout.appending(path: "src/new.txt")) == "brand new\n")
        let after = try CheckoutSnapshot(checkout, sandbox: sandbox)
        #expect(after.head == before.head)                      // same branch
        #expect(after.refs == before.refs)                      // no commit, no branch change
        #expect(after.index == before.index)                    // nothing staged
        #expect(after.stash.isEmpty)                            // nothing stashed
        #expect(try sandbox.git(["diff", "--cached", "--name-only"], in: checkout).isEmpty)
        #expect(after.status.contains("M src/app.txt"))
        #expect(after.status.contains("?? src/new.txt"))
    }

    @Test func largePatchStreamsThroughStdin() async throws {
        let setup = try await PatchScenario()
        let big = (0..<20_000).map { "generated line \($0) with some padding text" }.joined(separator: "\n") + "\n"
        try setup.sandbox.write(big, to: setup.worktree.appending(path: "big.txt"))
        let changes = try await setup.inspector.changes(inWorktree: setup.worktree.path, since: setup.prepared.baseSHA, maxBytes: 10_000_000)
        #expect(!changes.truncated)
        #expect(changes.unifiedDiff.utf8.count > 500_000)
        let applied = try await setup.inspector.applyPatch(changes.unifiedDiff, into: setup.checkout.path, expectedHeadSHA: nil)
        #expect(applied.canApply)
        #expect(try setup.sandbox.read(setup.checkout.appending(path: "big.txt")) == big)
    }

    @Test func conflictIsReportedAndNothingChanges() async throws {
        let setup = try await PatchScenario()
        let sandbox = setup.sandbox, checkout = setup.checkout
        try setup.agentEdits()
        let patch = try await setup.inspector.changes(inWorktree: setup.worktree.path, since: setup.prepared.baseSHA, maxBytes: 100_000).unifiedDiff
        try sandbox.git(["checkout", "-q", "main"], in: checkout)  // line2 differs from the PR head
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)

        let result = try await setup.inspector.applyPatch(patch, into: checkout.path, expectedHeadSHA: nil)

        #expect(!result.canApply)
        #expect(result.problems.contains { $0.contains("Patch conflict") && $0.contains("src/app.txt") })
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func dirtyCheckoutIsRefusedWithPaths() async throws {
        let setup = try await PatchScenario()
        let sandbox = setup.sandbox, checkout = setup.checkout
        try setup.agentEdits()
        let patch = try await setup.inspector.changes(inWorktree: setup.worktree.path, since: setup.prepared.baseSHA, maxBytes: 100_000).unifiedDiff
        try sandbox.write("my local work\n", to: checkout.appending(path: "README.md"))
        try sandbox.write("mine\n", to: checkout.appending(path: "local.txt"))
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)

        let result = try await setup.inspector.applyPatch(patch, into: checkout.path, expectedHeadSHA: setup.prepared.baseSHA)

        #expect(!result.canApply)
        #expect(result.targetSafety == .dirty)
        let problem = try #require(result.problems.first { $0.contains("uncommitted changes") })
        #expect(problem.contains("README.md"))
        #expect(problem.contains("local.txt"))
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func wrongHeadIsRefused() async throws {
        let setup = try await PatchScenario()
        let sandbox = setup.sandbox, checkout = setup.checkout
        try setup.agentEdits()
        let patch = try await setup.inspector.changes(inWorktree: setup.worktree.path, since: setup.prepared.baseSHA, maxBytes: 100_000).unifiedDiff
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)

        let result = try await setup.inspector.applyPatch(patch, into: checkout.path, expectedHeadSHA: setup.scenario.baseSHA)

        #expect(!result.canApply)
        #expect(result.problems.contains { $0.contains("HEAD is \(setup.prepared.baseSHA.prefix(12))") })
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func gitButlerWorkspaceIsNeverWritten() async throws {
        let setup = try await PatchScenario()
        let sandbox = setup.sandbox, checkout = setup.checkout
        try setup.agentEdits()
        let patch = try await setup.inspector.changes(inWorktree: setup.worktree.path, since: setup.prepared.baseSHA, maxBytes: 100_000).unifiedDiff
        try setup.scenario.makeGitButlerWorkspace(checkout)
        let before = try CheckoutSnapshot(checkout, sandbox: sandbox)

        let result = try await setup.inspector.applyPatch(patch, into: checkout.path, expectedHeadSHA: nil)

        #expect(!result.canApply)
        #expect(result.targetSafety == .gitButlerWorkspace)
        #expect(result.problems.contains { $0.contains("GitButler") })
        #expect(try CheckoutSnapshot(checkout, sandbox: sandbox) == before)
    }

    @Test func notARepositoryAndEmptyPatch() async throws {
        let setup = try await PatchScenario()
        let plain = setup.sandbox.url("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let notRepo = try await setup.inspector.checkPatch("diff --git a/x b/x\n", into: plain.path, expectedHeadSHA: nil)
        #expect(!notRepo.canApply)
        #expect(notRepo.targetSafety == .notARepository)
        let empty = try await setup.inspector.checkPatch("  \n", into: setup.checkout.path, expectedHeadSHA: nil)
        #expect(!empty.canApply)
        #expect(empty.problems == ["The patch is empty."])
    }

    @Test func patchEscapingTheCheckoutIsRejected() async throws {
        let setup = try await PatchScenario()
        let patch = """
        diff --git a/../escape.txt b/../escape.txt
        new file mode 100644
        --- /dev/null
        +++ b/../escape.txt
        @@ -0,0 +1 @@
        +escaped

        """
        let result = try await setup.inspector.applyPatch(patch, into: setup.checkout.path, expectedHeadSHA: nil)
        #expect(!result.canApply)
        #expect(!FileManager.default.fileExists(atPath: setup.sandbox.url("work/escape.txt").path))
    }
}
