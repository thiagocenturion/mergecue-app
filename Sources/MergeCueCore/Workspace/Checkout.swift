import Foundation

/// A configured git remote.
public struct GitRemote: Codable, Sendable, Hashable {
    public var name: String
    public var fetchURL: String
    public var pushURL: String?
    public var canonical: CanonicalRemote?

    /// `canonical` defaults to `CanonicalRemote.parse(fetchURL)`.
    public init(name: String, fetchURL: String, pushURL: String? = nil, canonical: CanonicalRemote? = nil) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL
        self.canonical = canonical ?? CanonicalRemote.parse(fetchURL)
    }
}

/// GitButler workspace detection result.
public struct GitButlerStatus: Codable, Sendable, Hashable {
    public var isManaged: Bool
    public var workspaceBranch: String?
    /// Human-readable evidence ("gitbutler/workspace branch checked out", ".git/gitbutler exists", …).
    public var evidence: [String]

    public init(isManaged: Bool, workspaceBranch: String? = nil, evidence: [String] = []) {
        self.isManaged = isManaged
        self.workspaceBranch = workspaceBranch
        self.evidence = evidence
    }

    public static let notManaged = GitButlerStatus(isManaged: false)
}

/// Whether a checkout may be written to directly.
public enum CheckoutSafety: String, Codable, Sendable, CaseIterable {
    case safe, dirty
    case gitButlerWorkspace = "gitbutler_workspace"
    case detached
    case notARepository = "not_a_repository"
    case missing

    public var displayName: String {
        switch self {
        case .safe: "Clean checkout"
        case .dirty: "Uncommitted changes"
        case .gitButlerWorkspace: "GitButler workspace"
        case .detached: "Detached HEAD"
        case .notARepository: "Not a git repository"
        case .missing: "Folder not found"
        }
    }
}

/// Result of inspecting a local path.
public struct CheckoutInfo: Codable, Sendable, Hashable {
    public var path: String
    public var isRepository: Bool
    public var topLevel: String?
    public var remotes: [GitRemote]
    public var currentBranch: String?
    public var headSHA: String?
    public var isDirty: Bool
    public var dirtyPaths: [String]
    public var worktrees: [String]
    public var gitButler: GitButlerStatus
    public var safety: CheckoutSafety

    public init(
        path: String,
        isRepository: Bool,
        topLevel: String? = nil,
        remotes: [GitRemote] = [],
        currentBranch: String? = nil,
        headSHA: String? = nil,
        isDirty: Bool = false,
        dirtyPaths: [String] = [],
        worktrees: [String] = [],
        gitButler: GitButlerStatus = .notManaged,
        safety: CheckoutSafety
    ) {
        self.path = path
        self.isRepository = isRepository
        self.topLevel = topLevel
        self.remotes = remotes
        self.currentBranch = currentBranch
        self.headSHA = headSHA
        self.isDirty = isDirty
        self.dirtyPaths = dirtyPaths
        self.worktrees = worktrees
        self.gitButler = gitButler
        self.safety = safety
    }
}

/// Request to create an isolated worktree at a change request head.
public struct WorktreeRequest: Codable, Sendable, Hashable {
    public var taskID: TaskID
    public var checkoutPath: String
    public var fetch: FetchHeadSpec
    public var destinationRoot: String

    public init(taskID: TaskID, checkoutPath: String, fetch: FetchHeadSpec, destinationRoot: String) {
        self.taskID = taskID
        self.checkoutPath = checkoutPath
        self.fetch = fetch
        self.destinationRoot = destinationRoot
    }
}

/// A prepared isolated worktree.
public struct PreparedWorktree: Codable, Sendable, Hashable {
    public var path: String
    public var baseSHA: String
    /// `refs/mergecue/tasks/<task id>`.
    public var localRef: String

    public init(path: String, baseSHA: String, localRef: String) {
        self.path = path
        self.baseSHA = baseSHA
        self.localRef = localRef
    }

    /// The local ref MergeCue uses for a task.
    public static func localRef(for taskID: TaskID) -> String {
        "refs/mergecue/tasks/\(taskID.rawValue)"
    }
}

public struct ChangedPath: Codable, Sendable, Hashable {
    public var path: String
    public var status: FileChangeStatus

    public init(path: String, status: FileChangeStatus) {
        self.path = path
        self.status = status
    }
}

/// Changes in a worktree relative to a base SHA, recomputed by the app (never trusted from the agent).
public struct WorkspaceChanges: Codable, Sendable, Hashable {
    public var changedPaths: [ChangedPath]
    public var unifiedDiff: String
    public var truncated: Bool
    public var headSHA: String?
    public var hasUncommittedChanges: Bool

    public init(changedPaths: [ChangedPath], unifiedDiff: String, truncated: Bool, headSHA: String? = nil, hasUncommittedChanges: Bool) {
        self.changedPaths = changedPaths
        self.unifiedDiff = unifiedDiff
        self.truncated = truncated
        self.headSHA = headSHA
        self.hasUncommittedChanges = hasUncommittedChanges
    }
}

/// Whether a patch applies cleanly to a checkout.
public struct PatchApplyCheck: Codable, Sendable, Hashable {
    public var canApply: Bool
    public var problems: [String]
    public var targetHeadSHA: String?
    public var targetSafety: CheckoutSafety

    public init(canApply: Bool, problems: [String] = [], targetHeadSHA: String? = nil, targetSafety: CheckoutSafety) {
        self.canApply = canApply
        self.problems = problems
        self.targetHeadSHA = targetHeadSHA
        self.targetSafety = targetSafety
    }
}

/// Result of a user-approved command.
public struct CommandResult: Codable, Sendable, Hashable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var durationMs: Int

    public init(exitCode: Int32, stdout: String, stderr: String, durationMs: Int) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.durationMs = durationMs
    }

    public var succeeded: Bool { exitCode == 0 }
}
