import Foundation
import MergeCueCore
import Testing
@testable import WorkspaceInspector

/// S2: an agent that controls the worktree must not be able to make MergeCue run commands of its choosing when
/// MergeCue recomputes the diff (report_changes / get_diff / review).
@Suite("Worktree git-dir pinning and filter neutralization")
struct GitDirPinningTests {
    /// A shell filter command that leaves `marker` behind if git ever runs it.
    static func evilFilter(_ marker: URL) -> String {
        "sh -c 'touch \(marker.path); cat'"
    }

    @Test func preparedWorktreeRecordsItsGitDirs() async throws {
        let setup = try await PatchScenario()
        let pin = try #require(setup.prepared.gitDirs)
        let common = try setup.sandbox.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: setup.checkout)
        #expect(GitWorkspaceInspector.canonicalPath(pin.commonDir) == GitWorkspaceInspector.canonicalPath(common))
        #expect(pin.gitDir.hasPrefix(pin.commonDir + "/worktrees/"))
        let pinned = try await setup.inspector.changes(
            inWorktree: setup.worktree.path, gitDirs: pin, checkoutPath: nil, since: setup.prepared.baseSHA, maxBytes: 10_000
        )
        #expect(pinned.changedPaths.isEmpty)
        // Without a recorded pin, the mapped checkout's registry yields the same git dir.
        let derived = try await setup.inspector.registeredGitDirs(worktree: setup.worktree.path, checkoutPath: setup.checkout.path)
        #expect(GitWorkspaceInspector.canonicalPath(derived.gitDir) == GitWorkspaceInspector.canonicalPath(pin.gitDir))
    }

    /// The exploit: the agent points the worktree's `.git` at a repository it created, whose config defines a
    /// clean filter and whose attributes apply it to every file. MergeCue must refuse without running anything.
    @Test func repointedGitFileIsRefusedAndNothingRuns() async throws {
        let setup = try await PatchScenario()
        let sandbox = setup.sandbox
        let pin = try #require(setup.prepared.gitDirs)
        try setup.agentEdits()
        let marker = sandbox.url("PWNED-repointed")
        let evil = sandbox.url("evil-repo")
        _ = try sandbox.git(["init", "-q", evil.path], in: sandbox.root)
        _ = try sandbox.git(["config", "filter.x.clean", Self.evilFilter(marker)], in: evil)
        _ = try sandbox.git(["config", "filter.x.smudge", "cat"], in: evil)
        try sandbox.write("* filter=x\n", to: evil.appending(path: ".git/info/attributes"))
        try sandbox.write("* filter=x\n", to: setup.worktree.appending(path: ".gitattributes"))
        try sandbox.write("gitdir: \(evil.appending(path: ".git").path)\n", to: setup.worktree.appending(path: ".git"))

        await #expect(throws: WorkspaceError.worktreeGitDirChanged(path: GitWorkspaceInspector.absolutePath(setup.worktree.path))) {
            _ = try await setup.inspector.changes(
                inWorktree: setup.worktree.path, gitDirs: pin, checkoutPath: nil, since: setup.prepared.baseSHA, maxBytes: 10_000
            )
        }
        // Deriving the pin from the mapped checkout refuses the same way.
        await #expect(throws: WorkspaceError.self) {
            _ = try await setup.inspector.changes(
                inWorktree: setup.worktree.path, gitDirs: nil, checkoutPath: setup.checkout.path, since: setup.prepared.baseSHA, maxBytes: 10_000
            )
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func symlinkedGitLinkIsRefused() async throws {
        let setup = try await PatchScenario()
        let pin = try #require(setup.prepared.gitDirs)
        let link = setup.worktree.appending(path: ".git")
        let saved = try Data(contentsOf: link)
        try FileManager.default.removeItem(at: link)
        let real = setup.sandbox.url("gitlink-copy")
        try saved.write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        await #expect(throws: WorkspaceError.self) {
            _ = try await setup.inspector.changes(
                inWorktree: setup.worktree.path, gitDirs: pin, checkoutPath: nil, since: setup.prepared.baseSHA, maxBytes: 10_000
            )
        }
    }

    /// Even with the genuine git dir, filters defined in the repository config and applied by in-tree
    /// `.gitattributes` or `info/attributes` never run while MergeCue computes the diff.
    @Test func repositoryFiltersNeverRunWhileComputingChanges() async throws {
        let setup = try await PatchScenario()
        let sandbox = setup.sandbox
        let pin = try #require(setup.prepared.gitDirs)
        let marker = sandbox.url("PWNED-filter")
        _ = try sandbox.git(["config", "filter.evil.clean", Self.evilFilter(marker)], in: setup.checkout)
        _ = try sandbox.git(["config", "filter.evil.process", Self.evilFilter(marker)], in: setup.checkout)
        _ = try sandbox.git(["config", "diff.evil.textconv", Self.evilFilter(marker)], in: setup.checkout)
        try sandbox.write("* filter=evil diff=evil\n", to: URL(fileURLWithPath: pin.commonDir).appending(path: "info/attributes"))
        try sandbox.write("* filter=evil diff=evil\n", to: setup.worktree.appending(path: ".gitattributes"))
        try setup.agentEdits()

        let changes = try await setup.inspector.changes(
            inWorktree: setup.worktree.path, gitDirs: pin, checkoutPath: nil, since: setup.prepared.baseSHA, maxBytes: 100_000
        )
        #expect(changes.unifiedDiff.contains("+line2 from the agent"))
        #expect(changes.changedPaths.map(\.path).contains("src/new.txt"))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "a repository filter ran (pinned)")
        let legacy = try await setup.inspector.changes(inWorktree: setup.worktree.path, since: setup.prepared.baseSHA, maxBytes: 100_000)
        #expect(legacy.unifiedDiff.contains("+brand new"))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "a repository filter ran")

        // Sanity check: plain git in this worktree does run the filter, so the test would catch a regression.
        _ = try sandbox.git(["diff", "--quiet", "HEAD"], in: setup.worktree, allowFailure: true)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
