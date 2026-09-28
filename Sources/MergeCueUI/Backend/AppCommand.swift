import Foundation
import MergeCueCore

/// An opaque secret typed into a `SecureField`. It never prints, reflects or encodes its value; only the
/// credential store should call `exposeForCredentialStore()`.
public nonisolated struct SecretValue: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let storage: String

    public init(_ value: String) {
        storage = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { storage.isEmpty }

    /// The raw value, for handing to the Keychain-backed credential store only. Never log or display it.
    public func exposeForCredentialStore() -> String { storage }

    public var description: String { "SecretValue(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }
}

/// Input of the "Connect account" sheet.
public nonisolated struct ConnectAccountRequest: Sendable, Hashable, CustomStringConvertible {
    public var kind: ProviderKind
    public var method: AuthMethod
    public var instance: ProviderInstance
    /// Personal access token / API token / access token. Nil for `githubCLIImport` and device flows.
    public var token: SecretValue?
    /// Atlassian account email (Bitbucket API tokens use email + token).
    public var email: String?
    public var label: String?

    public init(kind: ProviderKind, method: AuthMethod, instance: ProviderInstance? = nil, token: SecretValue? = nil, email: String? = nil, label: String? = nil) {
        self.kind = kind
        self.method = method
        self.instance = instance ?? kind.defaultInstance
        self.token = token
        self.email = email
        self.label = label
    }

    public var description: String {
        "ConnectAccountRequest(\(kind.rawValue), \(method.rawValue), token: \(token == nil ? "none" : "<redacted>"))"
    }
}

/// What the user will approve: the exact content of a local or remote action, fingerprinted so the approval
/// matches what was shown.
public nonisolated struct ActionPreview: Sendable, Hashable, Identifiable {
    public var id: String
    public var taskID: TaskID
    public var action: RemoteActionKind
    /// "Post reply on acme/payments-api #61".
    public var title: String
    /// Where the action lands (thread, file, checkout).
    public var target: String
    /// The exact reply text, or the patch to apply.
    public var body: String
    public var headSHA: String?
    public var fingerprint: String
    public var warnings: [String]
    /// False when the action cannot be approved (writes disabled, policy, stale head); `blockedReason` says why.
    public var canApprove: Bool
    public var blockedReason: String?
    public var createdAt: Date
    /// True for preview/demo backends: approving records the decision but nothing is written anywhere.
    public var isSimulated: Bool

    public init(
        id: String,
        taskID: TaskID,
        action: RemoteActionKind,
        title: String,
        target: String,
        body: String,
        headSHA: String? = nil,
        fingerprint: String,
        warnings: [String] = [],
        canApprove: Bool = true,
        blockedReason: String? = nil,
        createdAt: Date,
        isSimulated: Bool
    ) {
        self.id = id
        self.taskID = taskID
        self.action = action
        self.title = title
        self.target = target
        self.body = body
        self.headSHA = headSHA
        self.fingerprint = fingerprint
        self.warnings = warnings
        self.canApprove = canApprove
        self.blockedReason = blockedReason
        self.createdAt = createdAt
        self.isSimulated = isSimulated
    }
}

/// Every user action available in the menu bar popover and the main window (PLAN §1 user stories, §4).
public nonisolated enum AppCommand: Sendable, CustomStringConvertible {
    // MARK: Attention
    case markRead(attentionID: String, read: Bool)
    case acknowledge(attentionID: String)
    case snooze(attentionID: String, until: Date)
    case dismissAttention(attentionID: String)

    // MARK: Tasks
    /// "Fix with AI" / "Investigate with AI" / "Draft reply" / "Address with AI". Creates `waiting_for_agent` only.
    case createTask(attentionID: String, type: TaskType)
    case cancelTask(TaskID)
    case retryTask(TaskID)
    case reopenTask(TaskID)
    case dismissTask(TaskID)
    case unblockTask(TaskID)
    case markTaskDone(TaskID)
    /// "Discard and retry": rejects the submitted result and returns the task to `waiting_for_agent`.
    case rejectResult(TaskID, note: String?)
    /// Builds the exact preview of an action for the review gate.
    case requestActionPreview(TaskID, RemoteActionKind)
    /// Approves exactly the previewed content (matched by id + fingerprint).
    case approvePreview(ActionPreview)
    /// Declines a preview; nothing is written and the decision is recorded.
    case declinePreview(ActionPreview)

    // MARK: Sync and notifications
    case refresh(account: AccountKey?)
    /// nil resumes notifications.
    case pauseNotifications(until: Date?)
    case setQuietHours(QuietHours?)

    // MARK: Rules
    case saveRule(Rule)
    case deleteRule(id: String)
    /// Only the user can activate a rule (agent proposals stay pending until then).
    case activateRule(id: String, active: Bool)

    // MARK: Accounts
    case connectAccount(ConnectAccountRequest)
    case disconnectAccount(AccountKey)
    case setWritesEnabled(AccountKey, Bool)

    // MARK: Repository mappings
    case addMapping(repo: RepoKey, repoFullPath: String, checkoutPath: String)
    case confirmMapping(id: String)
    case removeMapping(id: String)

    // MARK: Handoff and links
    case copyHandoffCommand(TaskID, agent: AgentKind?)
    case openInAgent(TaskID, agent: AgentKind)
    /// On-demand CI log excerpt for a failing check (bounded, redacted).
    case loadCheckLog(CheckKey)
    case openURL(URL)

    /// Safe, secret-free name for logs and diagnostics.
    public var description: String {
        switch self {
        case .markRead: "markRead"
        case .acknowledge: "acknowledge"
        case .snooze: "snooze"
        case .dismissAttention: "dismissAttention"
        case .createTask(_, let type): "createTask(\(type.rawValue))"
        case .cancelTask: "cancelTask"
        case .retryTask: "retryTask"
        case .reopenTask: "reopenTask"
        case .dismissTask: "dismissTask"
        case .unblockTask: "unblockTask"
        case .markTaskDone: "markTaskDone"
        case .rejectResult: "rejectResult"
        case .requestActionPreview(_, let kind): "requestActionPreview(\(kind.rawValue))"
        case .approvePreview: "approvePreview"
        case .declinePreview: "declinePreview"
        case .refresh: "refresh"
        case .pauseNotifications: "pauseNotifications"
        case .setQuietHours: "setQuietHours"
        case .saveRule: "saveRule"
        case .deleteRule: "deleteRule"
        case .activateRule: "activateRule"
        case .connectAccount(let request): "connectAccount(\(request.kind.rawValue))"
        case .disconnectAccount: "disconnectAccount"
        case .setWritesEnabled: "setWritesEnabled"
        case .addMapping: "addMapping"
        case .confirmMapping: "confirmMapping"
        case .removeMapping: "removeMapping"
        case .copyHandoffCommand: "copyHandoffCommand"
        case .openInAgent(_, let agent): "openInAgent(\(agent.rawValue))"
        case .loadCheckLog: "loadCheckLog"
        case .openURL: "openURL"
        }
    }
}

/// Outcome of an `AppCommand`.
public nonisolated struct AppCommandResult: Sendable {
    /// Short confirmation shown as a banner.
    public var message: String?
    /// Set by `.requestActionPreview`; the UI shows it in the approval sheet.
    public var preview: ActionPreview?
    /// Set by `.copyHandoffCommand`; the UI copies it to the pasteboard.
    public var handoffCommand: String?
    /// A URL the UI should open (provider link, token page).
    public var urlToOpen: URL?
    /// Set by `.createTask`.
    public var createdTaskID: TaskID?
    /// Set by `.loadCheckLog`.
    public var logExcerpt: LogExcerpt?

    public init(
        message: String? = nil,
        preview: ActionPreview? = nil,
        handoffCommand: String? = nil,
        urlToOpen: URL? = nil,
        createdTaskID: TaskID? = nil,
        logExcerpt: LogExcerpt? = nil
    ) {
        self.message = message
        self.preview = preview
        self.handoffCommand = handoffCommand
        self.urlToOpen = urlToOpen
        self.createdTaskID = createdTaskID
        self.logExcerpt = logExcerpt
    }

    public static let none = AppCommandResult()
}

/// The short, agent-agnostic handoff command (PLAN §7). It carries only the task id; the agent fetches context
/// through MergeCue MCP.
public nonisolated enum HandoffText {
    public static func command(for taskID: TaskID) -> String {
        "Work on MergeCue task \(taskID.rawValue). Use MergeCue MCP for context and status updates. "
            + "Work only in the designated checkout. Stop before publishing anything."
    }
}
