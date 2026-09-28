@_exported import AgentHandoff
import Foundation
import MergeCueCore
import MergeCueEngine

/// A connected account together with its independent sync status and the adapter's capability manifest.
public nonisolated struct AccountState: Sendable, Hashable, Identifiable {
    public var account: Account
    public var status: AccountSyncStatus
    public var capabilities: CapabilityManifest

    public init(account: Account, status: AccountSyncStatus, capabilities: CapabilityManifest) {
        self.account = account
        self.status = status
        self.capabilities = capabilities
    }

    public var id: AccountKey { account.id }
    public var kind: ProviderKind { account.kind }
}

/// A task with its append-only activity history and its artifacts.
public nonisolated struct TaskRecord: Sendable, Hashable, Identifiable {
    public var task: MCTask
    /// Chronological (oldest first).
    public var activities: [TaskActivity]
    public var artifacts: [Artifact]

    public init(task: MCTask, activities: [TaskActivity] = [], artifacts: [Artifact] = []) {
        self.task = task
        self.activities = activities
        self.artifacts = artifacts
    }

    public var id: TaskID { task.id }
    public var state: TaskState { task.state }

    /// The most recent artifact of `kind`.
    public func artifact(_ kind: ArtifactKind) -> Artifact? {
        artifacts.last { $0.kind == kind }
    }

    /// The most recent agent-reported progress entry.
    public var latestProgress: TaskActivity? {
        activities.last { $0.kind == .progress }
    }

    /// Whether an agent really holds the task (a successful `claim_task` produced a lease).
    public var hasRealClaim: Bool {
        task.state == .working && task.lease != nil
    }
}

/// Whether the MergeCue MCP server is registered with (and verified for) an agent. The agent kinds and the
/// detection result are AgentHandoff's (`AgentKind`, `DetectedAgent`); this is the UI's summary of the setup.
public nonisolated enum MCPConnectionState: Sendable, Hashable {
    case notRegistered
    /// Registered with this Mac's helper; `verifiedAt` is set once a `tools/list` + read-only round trip succeeded.
    case registered(verifiedAt: Date?)
    /// Registered with a different command, the CLI could not be queried, or verification failed.
    case needsAttention(String)

    public var displayText: String {
        switch self {
        case .notRegistered: "MergeCue MCP not registered"
        case .registered(let verifiedAt): verifiedAt == nil ? "Registered, not verified yet" : "Connected"
        case .needsAttention(let message): message
        }
    }

    /// Only a verified registration counts as connected.
    public var isVerified: Bool {
        if case .registered(let verifiedAt) = self { return verifiedAt != nil }
        return false
    }

    public var isRegistered: Bool {
        if case .registered = self { return true }
        return false
    }
}

/// A coding agent found on this Mac, with the state of its MergeCue MCP setup.
public nonisolated struct AgentStatus: Sendable, Hashable, Identifiable {
    public var kind: AgentKind
    /// AgentHandoff's detection result (executable, version, how it was found).
    public var detected: DetectedAgent
    public var mcpRegistration: MCPConnectionState
    /// A tested launcher can open the task's checkout in a new Terminal window without touching existing sessions.
    public var canOpenTasks: Bool

    public init(detected: DetectedAgent, mcpRegistration: MCPConnectionState, canOpenTasks: Bool = true) {
        self.kind = detected.kind
        self.detected = detected
        self.mcpRegistration = mcpRegistration
        self.canOpenTasks = canOpenTasks
    }

    public var id: String { kind.rawValue + ":" + detected.executablePath }
    public var name: String { kind.displayName }
    public var version: String? { detected.version }
    /// Executable path with `~` for the home directory.
    public var path: String { UIFormat.abbreviatedPath(detected.executablePath) }
}

/// Launch-at-login state (mirrors `MergeCueRuntime.LoginItemStatus`).
public nonisolated enum LoginItemState: String, Sendable, Hashable {
    case enabled, disabled, requiresApproval, unavailable
}

/// Where the running backend keeps its data and how agents reach it (Settings › Data, onboarding, agent setup).
public nonisolated struct RuntimeInfo: Sendable, Hashable {
    /// Data root (`~/Library/Application Support/MergeCue`, `<root>/demo` in demo mode, or `MERGECUE_HOME`).
    public var dataRoot: String
    public var databasePath: String
    public var worktreesPath: String
    public var logsPath: String
    /// Where agent config backups go before MergeCue changes an agent's MCP configuration.
    public var backupsPath: String
    public var socketPath: String
    public var ipcRunning: Bool
    /// The bundled `mergecue-mcp` agents are configured with (nil when not found).
    public var helperPath: String?
    /// `MERGECUE_HOME` the helper needs when this runtime does not use the default location.
    public var helperHome: String?
    public var loginItem: LoginItemState

    public init(dataRoot: String, databasePath: String, worktreesPath: String, logsPath: String, backupsPath: String,
                socketPath: String, ipcRunning: Bool, helperPath: String?, helperHome: String? = nil,
                loginItem: LoginItemState) {
        self.dataRoot = dataRoot
        self.databasePath = databasePath
        self.worktreesPath = worktreesPath
        self.logsPath = logsPath
        self.backupsPath = backupsPath
        self.socketPath = socketPath
        self.ipcRunning = ipcRunning
        self.helperPath = helperPath
        self.helperHome = helperHome
        self.loginItem = loginItem
    }
}

/// Everything the UI shows, as one consistent value built from Core domain types.
public nonisolated struct AppState: Sendable, Hashable {
    public var accounts: [AccountState]
    public var attention: [AttentionItem]
    public var tasks: [TaskRecord]
    public var changeRequests: [ChangeRequestSnapshot]
    public var rules: [Rule]
    public var mappings: [RepoMapping]
    /// Agents found on this Mac (only detected ones).
    public var agents: [AgentStatus]
    /// Project instruction files (`AGENTS.md`, `CLAUDE.md`) found at the root of each mapped checkout, keyed by
    /// checkout path. MergeCue only checks that they exist; it never reads them into the agent's context.
    public var instructionFiles: [String: [String]]
    /// nil for the in-memory preview.
    public var runtime: RuntimeInfo?
    public var notificationsPausedUntil: Date?
    public var quietHours: QuietHours?
    public var notificationPreferences: NotificationPreferences
    public var lastRefreshAt: Date?
    /// Last scheduled housekeeping (history retention) run; nil = never / preview.
    public var lastMaintenance: MaintenanceReport?
    /// Worktrees of finished tasks listed in Settings ▸ Data (removed only when the owner clicks Clean up).
    public var worktreeCleanupCandidates: [WorktreeCleanupCandidate]
    /// Every repository of each account (`.loadRepositories`), for mapping repositories without open PRs/MRs.
    public var repositoryLists: [AccountKey: RepositoryListState]
    /// The local checkout scan (`.scanCheckouts`).
    public var checkoutScan: CheckoutScanState

    public init(
        accounts: [AccountState] = [],
        attention: [AttentionItem] = [],
        tasks: [TaskRecord] = [],
        changeRequests: [ChangeRequestSnapshot] = [],
        rules: [Rule] = [],
        mappings: [RepoMapping] = [],
        agents: [AgentStatus] = [],
        instructionFiles: [String: [String]] = [:],
        runtime: RuntimeInfo? = nil,
        notificationsPausedUntil: Date? = nil,
        quietHours: QuietHours? = nil,
        notificationPreferences: NotificationPreferences = .allEnabled,
        lastRefreshAt: Date? = nil,
        lastMaintenance: MaintenanceReport? = nil,
        worktreeCleanupCandidates: [WorktreeCleanupCandidate] = [],
        repositoryLists: [AccountKey: RepositoryListState] = [:],
        checkoutScan: CheckoutScanState = .idle
    ) {
        self.repositoryLists = repositoryLists
        self.checkoutScan = checkoutScan
        self.accounts = accounts
        self.attention = attention
        self.tasks = tasks
        self.changeRequests = changeRequests
        self.rules = rules
        self.mappings = mappings
        self.agents = agents
        self.instructionFiles = instructionFiles
        self.runtime = runtime
        self.notificationsPausedUntil = notificationsPausedUntil
        self.quietHours = quietHours
        self.notificationPreferences = notificationPreferences
        self.lastMaintenance = lastMaintenance
        self.worktreeCleanupCandidates = worktreeCleanupCandidates
        self.lastRefreshAt = lastRefreshAt
    }

    public static let empty = AppState()

    /// Whether notifications are paused at `now`.
    public func notificationsPaused(at now: Date) -> Bool {
        guard let until = notificationsPausedUntil else { return false }
        return until > now
    }
}
