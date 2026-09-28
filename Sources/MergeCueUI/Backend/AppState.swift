import Foundation
import MergeCueCore

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

/// Coding agents MergeCue can hand tasks to.
public nonisolated enum AgentKind: String, Sendable, Hashable, CaseIterable, Codable {
    case claudeCode = "claude_code"
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        }
    }
}

/// Whether the MergeCue MCP server is registered with (and verified by) an agent.
public nonisolated enum MCPRegistrationStatus: Sendable, Hashable {
    case notRegistered
    /// Registered; `verifiedAt` is set once a read-only `tools/list` + task round trip succeeded.
    case registered(verifiedAt: Date?)
    case needsAttention(String)

    public var displayText: String {
        switch self {
        case .notRegistered: "MergeCue MCP not registered"
        case .registered(let verifiedAt): verifiedAt == nil ? "Registered, not verified yet" : "Registered and verified"
        case .needsAttention(let message): message
        }
    }

    /// Verified registrations are the only ones treated as connected.
    public var isVerified: Bool {
        if case .registered(let verifiedAt) = self { return verifiedAt != nil }
        return false
    }
}

/// An agent found on this Mac.
public nonisolated struct DetectedAgent: Sendable, Hashable, Identifiable {
    public var name: String
    public var kind: AgentKind
    public var version: String?
    public var path: String
    public var mcpRegistration: MCPRegistrationStatus
    /// A tested CLI/deep link can open the task's checkout without overwriting an existing session.
    public var canOpenTasks: Bool

    public init(name: String, kind: AgentKind, version: String?, path: String, mcpRegistration: MCPRegistrationStatus, canOpenTasks: Bool = true) {
        self.name = name
        self.kind = kind
        self.version = version
        self.path = path
        self.mcpRegistration = mcpRegistration
        self.canOpenTasks = canOpenTasks
    }

    public var id: String { kind.rawValue + ":" + path }
}

/// Everything the UI shows, as one consistent value built from Core domain types.
public nonisolated struct AppState: Sendable, Hashable {
    public var accounts: [AccountState]
    public var attention: [AttentionItem]
    public var tasks: [TaskRecord]
    public var changeRequests: [ChangeRequestSnapshot]
    public var rules: [Rule]
    public var mappings: [RepoMapping]
    public var agents: [DetectedAgent]
    public var notificationsPausedUntil: Date?
    public var quietHours: QuietHours?
    public var lastRefreshAt: Date?

    public init(
        accounts: [AccountState] = [],
        attention: [AttentionItem] = [],
        tasks: [TaskRecord] = [],
        changeRequests: [ChangeRequestSnapshot] = [],
        rules: [Rule] = [],
        mappings: [RepoMapping] = [],
        agents: [DetectedAgent] = [],
        notificationsPausedUntil: Date? = nil,
        quietHours: QuietHours? = nil,
        lastRefreshAt: Date? = nil
    ) {
        self.accounts = accounts
        self.attention = attention
        self.tasks = tasks
        self.changeRequests = changeRequests
        self.rules = rules
        self.mappings = mappings
        self.agents = agents
        self.notificationsPausedUntil = notificationsPausedUntil
        self.quietHours = quietHours
        self.lastRefreshAt = lastRefreshAt
    }

    public static let empty = AppState()

    /// Whether notifications are paused at `now`.
    public func notificationsPaused(at now: Date) -> Bool {
        guard let until = notificationsPausedUntil else { return false }
        return until > now
    }
}
