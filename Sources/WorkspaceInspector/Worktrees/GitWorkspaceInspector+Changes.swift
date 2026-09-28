import Foundation
import MergeCueCore

extension GitWorkspaceInspector {
    /// Changes in `path` relative to `baseSHA`: commits made since the base, uncommitted modifications and
    /// untracked (non-ignored) files, recomputed from git (never trusted from the agent).
    ///
    /// Untracked files are included by marking them intent-to-add in a **temporary copy** of the worktree's
    /// index (`GIT_INDEX_FILE`), so neither the worktree's real index nor anything else is modified. The unified
    /// diff always uses `a/`/`b/` prefixes (so it applies with `git apply -p1` whatever `diff.noprefix` says),
    /// no external diff drivers or textconv, and is cut to `maxBytes` UTF-8 bytes on a character boundary.
    public func changes(inWorktree path: String, since baseSHA: String, maxBytes: Int) async throws -> WorkspaceChanges {
        guard Self.isHexObjectID(baseSHA) else {
            throw WorkspaceError.invalidRequest("base '\(baseSHA)' is not a commit id")
        }
        let context: RepoContext
        switch try await inspectContext(path: path) {
        case .success(let value): context = value
        case .failure(let info):
            if info.safety == .missing { throw WorkspaceError.missingPath(info.path) }
            throw WorkspaceError.notARepository(path: info.path)
        }
        let top = context.topLevel
        let base = try await git(["rev-parse", "-q", "--verify", "\(baseSHA)^{commit}"], in: top)
        guard base.succeeded, !base.trimmed.isEmpty else {
            throw WorkspaceError.invalidRequest("base commit \(baseSHA) is not present in \(top)")
        }
        let baseCommit = base.trimmed

        let indexPath = try await gitChecked(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: top).trimmed
        let scratch = FileManager.default.temporaryDirectory.appending(path: "mergecue-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temporaryIndex = scratch.appending(path: "index").path
        if Self.pathKind(indexPath) == .file {
            try FileManager.default.copyItem(atPath: indexPath, toPath: temporaryIndex)
        }
        let indexEnvironment = ["GIT_INDEX_FILE": temporaryIndex]

        try await gitChecked(["add", "--intent-to-add", "--", "."], in: top, extraEnvironment: indexEnvironment)

        let diffOptions = [
            "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames", "--no-relative",
            "--src-prefix=a/", "--dst-prefix=b/", "--ignore-submodules=none",
        ]
        let names = try await gitChecked(
            ["diff", "--name-status", "-z"] + diffOptions + [baseCommit, "--"],
            in: top, extraEnvironment: indexEnvironment
        )
        let limit = max(0, maxBytes)
        let diff = try await gitChecked(
            ["diff"] + diffOptions + [baseCommit, "--"],
            in: top, extraEnvironment: indexEnvironment, maxOutputBytes: limit + 16
        )
        let bounded = BoundedText.truncate(diff.stdout, maxBytes: limit)

        let head = try await git(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: top)
        let status = try await gitChecked(
            ["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none"], in: top
        )

        return WorkspaceChanges(
            changedPaths: GitOutputParsing.nameStatus(names.stdout),
            unifiedDiff: bounded.text,
            truncated: bounded.isTruncated || diff.stdoutTruncated,
            headSHA: head.succeeded && !head.trimmed.isEmpty ? head.trimmed : nil,
            hasUncommittedChanges: !status.stdout.isEmpty
        )
    }
}
