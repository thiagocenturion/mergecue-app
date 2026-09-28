import Foundation

/// Local checkout inspection and isolated worktree management (implemented by `WorkspaceInspector`).
///
/// Implementations never modify an unrelated worktree, never write into a dirty or GitButler-managed
/// checkout, and run arbitrary commands only after explicit user approval.
public protocol WorkspaceInspecting: Sendable {
    func inspect(path: String) async throws -> CheckoutInfo
    func suggestMappings(for repo: Repository, searchRoots: [String]) async -> [MappingSuggestion]
    func match(repo: Repository, checkoutPath: String) async -> MappingSuggestion
    /// One bounded, cancellable walk of `searchRoots` that indexes every git checkout (canonical remotes → paths)
    /// and matches all `repos` against it. Default implementation (CheckoutScan.swift): per-repository
    /// `suggestMappings`.
    func scanCheckouts(
        for repos: [Repository], searchRoots: [String], progress: @escaping @Sendable (CheckoutScanProgress) -> Void
    ) async -> CheckoutScanResult
    func prepareWorktree(_ request: WorktreeRequest) async throws -> PreparedWorktree
    func changes(inWorktree path: String, since baseSHA: String, maxBytes: Int) async throws -> WorkspaceChanges
    /// `changes` pinned to the worktree's recorded git directories (S2): refuses with `worktreeGitDirChanged` when
    /// the worktree's `.git` now points elsewhere, and never runs repository filters/textconv/external diff
    /// drivers. With `gitDirs == nil` the pin is derived from `checkoutPath` (the mapped checkout that registered the
    /// worktree), never from the worktree itself.
    func changes(inWorktree path: String, gitDirs: WorktreeGitDirs?, checkoutPath: String?, since baseSHA: String, maxBytes: Int) async throws -> WorkspaceChanges
    func checkPatch(_ patch: String, into checkoutPath: String, expectedHeadSHA: String?) async throws -> PatchApplyCheck
    func applyPatch(_ patch: String, into checkoutPath: String, expectedHeadSHA: String?) async throws -> PatchApplyCheck
    func removeWorktree(path: String, checkoutPath: String) async throws
    /// Only after explicit user approval.
    func runCommand(_ argv: [String], in directory: String, timeout: TimeInterval) async throws -> CommandResult
}

extension WorkspaceInspecting {
    /// Default for implementations without git-dir pinning (test doubles): the unpinned `changes`.
    public func changes(inWorktree path: String, gitDirs: WorktreeGitDirs?, checkoutPath: String?, since baseSHA: String, maxBytes: Int) async throws -> WorkspaceChanges {
        try await changes(inWorktree: path, since: baseSHA, maxBytes: maxBytes)
    }
}

/// Provider-neutral workspace errors, so the engine can react without importing `WorkspaceInspector`.
public enum WorkspaceError: Error, Sendable, Equatable, LocalizedError {
    case gitUnavailable
    case notARepository(path: String)
    case missingPath(String)
    /// The checkout cannot be written to (dirty, GitButler workspace, detached, …).
    case unsafeCheckout(CheckoutSafety, path: String)
    case pathOutsideCheckout(String)
    case headMismatch(expected: String, actual: String?)
    case fetchFailed(String)
    case gitFailed(command: String, exitCode: Int32, stderr: String)
    case timedOut(command: String)
    case invalidRequest(String)
    /// The worktree's `.git` no longer points to the git directory MergeCue recorded (possible tampering).
    case worktreeGitDirChanged(path: String)

    public var errorDescription: String? {
        switch self {
        case .gitUnavailable: "git is not available."
        case .notARepository(let path): "\(path) is not a git repository."
        case .missingPath(let path): "\(path) does not exist."
        case .unsafeCheckout(let safety, let path): "Blocked: map a safe checkout (\(safety.displayName) at \(path))."
        case .pathOutsideCheckout(let path): "\(path) is outside the task checkout."
        case .headMismatch(let expected, let actual): "Head changed: expected \(expected), found \(actual ?? "none")."
        case .fetchFailed(let message): "Fetching the change request head failed: \(message)"
        case .gitFailed(let command, let exitCode, let stderr): "git \(command) failed (\(exitCode)): \(stderr)"
        case .timedOut(let command): "\(command) timed out."
        case .invalidRequest(let message): "Invalid workspace request: \(message)"
        case .worktreeGitDirChanged(let path):
            "The worktree \(path) no longer points to the git directory MergeCue created for it; MergeCue refuses to run git there."
        }
    }
}
