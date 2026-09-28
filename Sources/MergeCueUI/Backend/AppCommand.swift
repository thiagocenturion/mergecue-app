import AgentHandoff
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
    /// Agent (and run id) that claimed the task and produced the content, as it identified itself.
    public var claimant: String?

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
        isSimulated: Bool,
        claimant: String? = nil
    ) {
        self.claimant = claimant
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
    /// Settings ▸ Notifications ▸ "Notify me about" (persisted by the engine, honoured by Sync).
    case setNotificationCategory(NotificationCategory, enabled: Bool)
    /// Which PRs/MRs besides the user's own are tracked (Settings ▸ General ▸ Tracking).
    case setTrackingPreferences(TrackingPreferences)
    /// Settings ▸ Agents ▸ "Agent read access" (engine setting; default: only their tasks).
    case setAgentReadAccess(AgentReadAccess)

    // MARK: Data
    /// Removes the isolated worktrees of these finished tasks (Settings ▸ Data ▸ Clean up, after confirmation).
    case cleanUpWorktrees([TaskID])

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

    // MARK: Agent setup (wizard)
    /// Detects installed agents and their registration again.
    case refreshAgents
    /// Builds the exact plan (command, config snippet, files touched, backup folder) shown before consent.
    case prepareAgentRegistration(AgentKind, RegistrationAction)
    /// Applies a plan the owner confirmed in the UI (`RegistrationConsent.userConfirmed`). Backs up first.
    case applyAgentRegistration(MCPRegistrationPlan, RegistrationConsent)
    /// Spawns the bundled helper, lists its tools and makes a read-only round trip; only then "Connected".
    case verifyAgent(AgentKind)
    /// Settings ▸ Agents: deletes every agent-config backup MergeCue kept.
    case deleteAgentConfigBackups

    // MARK: Checkouts
    /// Local checkouts whose remotes match a repository (with confidence).
    case findCheckouts(RepoKey)
    /// Lists every repository of an account through the provider (cached; `forceRefresh` asks again). Runs in the
    /// background; progress and the result arrive in `AppState.repositoryLists`.
    case loadRepositories(AccountKey, forceRefresh: Bool)
    /// Searches the default folders for checkouts of these (unmapped) repositories, in order, bounded; exact remote
    /// matches are mapped automatically. Runs in the background; progress is in `AppState.checkoutScan`.
    case scanCheckouts([RepoKey])

    // MARK: App and data
    case setLaunchAtLogin(Bool)
    /// Asks macOS for notification permission (onboarding; never silently at launch).
    case requestNotificationPermission
    /// Writes a copy of the local database (no credentials) to a file the owner picked.
    case exportDatabase(to: URL)
    /// Deletes every stored credential and record (after the owner confirmed).
    case resetAllData

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
        case .setNotificationCategory(let category, _): "setNotificationCategory(\(category.rawValue))"
        case .setTrackingPreferences: "setTrackingPreferences"
        case .cleanUpWorktrees(let ids): "cleanUpWorktrees(\(ids.count))"
        case .setAgentReadAccess(let access): "setAgentReadAccess(\(access.rawValue))"
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
        case .refreshAgents: "refreshAgents"
        case .prepareAgentRegistration(let kind, let action): "prepareAgentRegistration(\(kind.rawValue), \(action.rawValue))"
        case .applyAgentRegistration(let plan, _): "applyAgentRegistration(\(plan.agent.rawValue), \(plan.action.rawValue))"
        case .verifyAgent(let kind): "verifyAgent(\(kind.rawValue))"
        case .deleteAgentConfigBackups: "deleteAgentConfigBackups"
        case .findCheckouts: "findCheckouts"
        case .loadRepositories(_, let force): "loadRepositories(force: \(force))"
        case .scanCheckouts(let repos): "scanCheckouts(\(repos.count))"
        case .setLaunchAtLogin(let enabled): "setLaunchAtLogin(\(enabled))"
        case .requestNotificationPermission: "requestNotificationPermission"
        case .exportDatabase: "exportDatabase"
        case .resetAllData: "resetAllData"
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
    /// Set by `.prepareAgentRegistration`: shown in full before the owner consents.
    public var registrationPlan: MCPRegistrationPlan?
    /// Set by `.verifyAgent`.
    public var verification: AgentVerification?
    /// Set by `.findCheckouts`.
    public var mappingSuggestions: [MappingSuggestion]?
    /// Banner tone for `message` (nil = derived: success for handoffs/new tasks, neutral otherwise). Recorded
    /// refusals (an approved action blocked by fresh state, a failed write) use `.critical`.
    public var tone: Tone?

    public init(
        message: String? = nil,
        preview: ActionPreview? = nil,
        handoffCommand: String? = nil,
        urlToOpen: URL? = nil,
        createdTaskID: TaskID? = nil,
        logExcerpt: LogExcerpt? = nil,
        registrationPlan: MCPRegistrationPlan? = nil,
        verification: AgentVerification? = nil,
        mappingSuggestions: [MappingSuggestion]? = nil,
        tone: Tone? = nil
    ) {
        self.message = message
        self.preview = preview
        self.handoffCommand = handoffCommand
        self.urlToOpen = urlToOpen
        self.createdTaskID = createdTaskID
        self.logExcerpt = logExcerpt
        self.registrationPlan = registrationPlan
        self.verification = verification
        self.mappingSuggestions = mappingSuggestions
        self.tone = tone
    }

    public static let none = AppCommandResult()
}

/// The short, agent-agnostic handoff command (PLAN §7). It carries only the task id and its handoff code (S7); the
/// agent fetches context through MergeCue MCP.
public nonisolated enum HandoffText {
    public static func command(for taskID: TaskID, handoffCode: String? = nil) -> String {
        "Work on MergeCue task \(taskID.rawValue)\(HandoffCode.promptFragment(handoffCode)). Use MergeCue MCP for context and status updates. "
            + "Work only in the designated checkout. Stop before publishing anything."
    }
}

/// Outcome of the agent wizard's verification step (`tools/list` + a read-only round trip through the helper).
public nonisolated struct AgentVerification: Sendable, Hashable {
    public var agent: AgentKind
    /// True only when the helper answered as `mergecue` with every required tool and the read-only call succeeded.
    public var succeeded: Bool
    public var toolCount: Int
    public var missingTools: [String]
    /// "list_attention answered", "MergeCue is not running", …
    public var roundTrip: String
    public var checkedAt: Date

    public init(agent: AgentKind, succeeded: Bool, toolCount: Int, missingTools: [String], roundTrip: String, checkedAt: Date) {
        self.agent = agent
        self.succeeded = succeeded
        self.toolCount = toolCount
        self.missingTools = missingTools
        self.roundTrip = roundTrip
        self.checkedAt = checkedAt
    }
}
