import Foundation
import MergeCueCore
import MergeCueStore

// Public value types of the engine's UI-facing API. See `Sources/MergeCueEngine/README.md`.

/// Errors of the engine's user-facing API (the IPC/MCP surface uses `IPCError` instead). Messages are
/// user-facing and never contain credentials. The cases mirror the UI's `AppBackendError`.
public enum EngineError: Error, Sendable, Equatable, LocalizedError {
    case notFound(String)
    case invalidTransition(String)
    /// Remote writes are off for the account (Settings › Accounts).
    case writesDisabled(account: String)
    /// The owner's write policy disables this action (request changes, commit and push, merge).
    case disabledByPolicy(RemoteActionKind)
    case unsupported(String)
    /// The preview is unknown, expired, or no longer matches the task/fingerprint.
    case previewExpired
    case invalidInput(String)
    /// Another writer changed the record first (optimistic concurrency).
    case conflict(String)
    /// The provider rejected or could not serve the request.
    case provider(ProviderError)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): "\(what) no longer exists."
        case .invalidTransition(let message): message
        case .writesDisabled(let account):
            "Remote writes are turned off for \(account). Turn them on in Settings › Accounts to post or resolve."
        case .disabledByPolicy(let action): "\(action.displayName) is disabled by your write policy."
        case .unsupported(let message): message
        case .previewExpired: "The preview is out of date. Request a new preview and review it again."
        case .invalidInput(let message): message
        case .conflict(let message): message
        case .provider(let error): error.errorDescription ?? error.code
        case .failed(let message): SecretRedactor.redact(message)
        }
    }
}

/// The owner's remote write policy (DECISIONS, ARCHITECTURE §10): only replies and thread resolution may be
/// enabled; `request_changes`, `commit_and_push` and `merge` are modeled but disabled. `apply_patch` is local and
/// allowed with approval.
public enum RemoteWritePolicy {
    public static let enabledActions: Set<RemoteActionKind> = [.applyPatch, .postReply, .resolveThread]

    public static func isEnabled(_ action: RemoteActionKind) -> Bool {
        enabledActions.contains(action)
    }
}

/// A connected account with its independent sync status and the adapter's capability manifest.
public struct EngineAccountState: Sendable, Hashable, Identifiable {
    public var account: Account
    public var status: AccountSyncStatus
    public var capabilities: CapabilityManifest

    public init(account: Account, status: AccountSyncStatus, capabilities: CapabilityManifest) {
        self.account = account
        self.status = status
        self.capabilities = capabilities
    }

    public var id: AccountKey { account.id }
}

/// Input of `connectAccount`. The credential only ever reaches the credential store (Keychain) and the probe.
public struct AccountConnectionRequest: Sendable, Hashable, CustomStringConvertible {
    public var instance: ProviderInstance
    public var method: AuthMethod
    public var credential: Credential
    public var label: String?
    public var selectedNamespaces: [String]

    public init(
        instance: ProviderInstance,
        method: AuthMethod,
        credential: Credential,
        label: String? = nil,
        selectedNamespaces: [String] = []
    ) {
        self.instance = instance
        self.method = method
        self.credential = credential
        self.label = label
        self.selectedNamespaces = selectedNamespaces
    }

    public var kind: ProviderKind { instance.kind }

    public var description: String {
        "AccountConnectionRequest(\(instance.kind.rawValue), \(method.rawValue), credential: <redacted>)"
    }
}

/// A task with its append-only history, artifacts and approval decisions.
public struct TaskDetail: Sendable, Hashable, Identifiable {
    public var task: MCTask
    /// Oldest first.
    public var activities: [TaskActivity]
    /// Oldest first.
    public var artifacts: [Artifact]
    public var approvals: [ApprovalRecord]

    public init(task: MCTask, activities: [TaskActivity], artifacts: [Artifact], approvals: [ApprovalRecord]) {
        self.task = task
        self.activities = activities
        self.artifacts = artifacts
        self.approvals = approvals
    }

    public var id: TaskID { task.id }
}

/// Mine / Reviewing / All (by the change request's involvement).
public enum AttentionScope: String, Sendable, Hashable, CaseIterable {
    case mine, reviewing, all
}

/// Status filter of the inbox.
public enum AttentionStatusFilter: String, Sendable, Hashable, CaseIterable {
    /// Every item that is not dismissed.
    case all
    /// Actionable now (open, or snooze expired).
    case needsAction
    case unread
    /// Linked to a task.
    case withTask
    case snoozed
    /// Acknowledged or resolved.
    case done
}

/// Inbox query. Repository filtering uses the provider-qualified `RepoKey`.
public struct AttentionQuery: Sendable, Hashable {
    public var scope: AttentionScope
    public var provider: ProviderKind?
    public var account: AccountKey?
    public var repo: RepoKey?
    public var status: AttentionStatusFilter

    public init(
        scope: AttentionScope = .all,
        provider: ProviderKind? = nil,
        account: AccountKey? = nil,
        repo: RepoKey? = nil,
        status: AttentionStatusFilter = .all
    ) {
        self.scope = scope
        self.provider = provider
        self.account = account
        self.repo = repo
        self.status = status
    }
}

/// The exact content of a local or remote action the owner is asked to approve.
public struct ReviewPreview: Sendable, Hashable, Identifiable {
    /// `pv_…`.
    public var id: String
    public var taskID: TaskID
    /// Task version the preview was built from; a later task change invalidates it.
    public var taskVersion: Int
    public var action: RemoteActionKind
    /// "Post reply on acme/payments-api #42".
    public var title: String
    /// Where the action lands (thread, file, checkout).
    public var target: String
    /// The exact reply text, or the patch to apply.
    public var body: String
    /// Change request head the preview was built against.
    public var headSHA: String?
    /// Opaque version of the target thread (resolution + comments) at preview time.
    public var threadVersion: String?
    /// Mapped checkout head for `apply_patch`.
    public var checkoutHeadSHA: String?
    /// SHA-256 of the exact (unredacted) content that will be written (reply text or patch).
    public var contentDigest: String
    /// `MergeCueCoding.digest` of everything above that the approval covers.
    public var fingerprint: String
    public var warnings: [String]
    /// False when the action cannot be approved; `blockedReason` says why.
    public var canApprove: Bool
    public var blockedReason: String?
    public var createdAt: Date
    public var expiresAt: Date
    /// True in demo mode: fixtures, nothing reaches a real provider.
    public var isSimulated: Bool

    public init(
        id: String,
        taskID: TaskID,
        taskVersion: Int,
        action: RemoteActionKind,
        title: String,
        target: String,
        body: String,
        headSHA: String? = nil,
        threadVersion: String? = nil,
        checkoutHeadSHA: String? = nil,
        contentDigest: String,
        fingerprint: String,
        warnings: [String] = [],
        canApprove: Bool = true,
        blockedReason: String? = nil,
        createdAt: Date,
        expiresAt: Date,
        isSimulated: Bool
    ) {
        self.id = id
        self.taskID = taskID
        self.taskVersion = taskVersion
        self.action = action
        self.title = title
        self.target = target
        self.body = body
        self.headSHA = headSHA
        self.threadVersion = threadVersion
        self.checkoutHeadSHA = checkoutHeadSHA
        self.contentDigest = contentDigest
        self.fingerprint = fingerprint
        self.warnings = warnings
        self.canApprove = canApprove
        self.blockedReason = blockedReason
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isSimulated = isSimulated
    }
}

/// The owner's decision on a preview: must quote the fingerprint of the preview that was shown.
public struct PreviewApproval: Sendable, Hashable {
    public var fingerprint: String
    public var note: String?

    public init(fingerprint: String, note: String? = nil) {
        self.fingerprint = fingerprint
        self.note = note
    }
}

/// Result of `perform(previewID:approval:)`. Every case is already recorded (activity + audit).
public enum ActionOutcome: Sendable, Hashable {
    /// The write happened; `taskState` is `done` (last action) or `ready_for_review` (more actions remain).
    case performed(taskState: TaskState, message: String)
    /// The same fingerprint was already performed (or the identical reply is already on the thread); nothing
    /// was written again.
    case alreadyPerformed(message: String)
    /// Fresh remote/local state changed since the preview (head moved, thread changed, checkout unsafe); the task
    /// is `blocked` and nothing was written.
    case blocked(reason: String)
    /// The write failed; the task is back in `ready_for_review` with `lastError`.
    case failed(TaskErrorInfo)

    public var message: String {
        switch self {
        case .performed(_, let message), .alreadyPerformed(let message): message
        case .blocked(let reason): reason
        case .failed(let error): error.message
        }
    }
}

/// What the UI needs to hand a task to an external agent. Pure metadata: building it never writes anything.
public struct TaskHandoff: Sendable, Hashable {
    public var taskID: TaskID
    /// The canonical, agent-agnostic prompt (PLAN §7).
    public var command: String
    /// Folder the agent should be opened in (isolated worktree, or the mapped checkout for read-only tasks).
    public var workingDirectory: String?
    public var checkoutPolicy: CheckoutPolicy?
    public var blockedReason: String?
    /// "Task ready to start" until a real `claim_task` arrives, never "AI working".
    public var statusText: String

    public init(
        taskID: TaskID,
        command: String,
        workingDirectory: String?,
        checkoutPolicy: CheckoutPolicy?,
        blockedReason: String?,
        statusText: String
    ) {
        self.taskID = taskID
        self.command = command
        self.workingDirectory = workingDirectory
        self.checkoutPolicy = checkoutPolicy
        self.blockedReason = blockedReason
        self.statusText = statusText
    }

    /// The short handoff text. Carries only the task id; the agent fetches context through MergeCue MCP.
    public static func command(for taskID: TaskID) -> String {
        "Work on MergeCue task \(taskID.rawValue). Use MergeCue MCP for context and status updates. "
            + "Work only in the designated checkout. Stop before publishing anything."
    }
}

/// One consistent read of everything the UI shows.
public struct EngineSnapshot: Sendable, Hashable {
    public var accounts: [EngineAccountState]
    /// Every non-dismissed attention item (actionable first).
    public var attention: [AttentionItem]
    public var tasks: [TaskDetail]
    public var changeRequests: [ChangeRequestSnapshot]
    public var rules: [Rule]
    public var mappings: [RepoMapping]
    public var notificationsPausedUntil: Date?
    public var quietHours: QuietHours?
    public var lastRefreshAt: Date?
    public var isDemo: Bool

    public init(
        accounts: [EngineAccountState],
        attention: [AttentionItem],
        tasks: [TaskDetail],
        changeRequests: [ChangeRequestSnapshot],
        rules: [Rule],
        mappings: [RepoMapping],
        notificationsPausedUntil: Date?,
        quietHours: QuietHours?,
        lastRefreshAt: Date?,
        isDemo: Bool
    ) {
        self.accounts = accounts
        self.attention = attention
        self.tasks = tasks
        self.changeRequests = changeRequests
        self.rules = rules
        self.mappings = mappings
        self.notificationsPausedUntil = notificationsPausedUntil
        self.quietHours = quietHours
        self.lastRefreshAt = lastRefreshAt
        self.isDemo = isDemo
    }
}
