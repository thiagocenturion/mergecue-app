import Foundation
import MergeCueCore

// MARK: - list_tasks

/// `{states?: [TaskState], limit? (1…100, default 50)}`.
public struct ListTasksParams: IPCMethodParams, Hashable {
    public typealias Output = ListTasksResult
    public static let method = IPCMethod.listTasks
    public static let defaultLimit = 50
    public static let maxLimit = 100

    /// Filter; nil or empty = active (non-terminal) tasks are the engine's default.
    public var states: [TaskState]?
    public var limit: Int?

    public init(states: [TaskState]? = nil, limit: Int? = nil) {
        self.states = states
        self.limit = limit
    }

    /// `limit` clamped to 1…100, default 50.
    public var resolvedLimit: Int {
        min(max(limit ?? Self.defaultLimit, 1), Self.maxLimit)
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireRange(limit, field: "limit", 1...Self.maxLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case states, limit
    }
}

/// `{tasks: [TaskSummaryDTO]}`.
public struct ListTasksResult: Codable, Sendable, Hashable {
    public var tasks: [TaskSummaryDTO]

    public init(tasks: [TaskSummaryDTO]) {
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey {
        case tasks
    }
}

/// Compact task row: `{task_id, type, state, version, title, provider, account, repo, number, change_ref,
/// thread_id?, check_id?, agent_name?, lease_expires_at?, created_at, updated_at}`.
public struct TaskSummaryDTO: Codable, Sendable, Hashable {
    public var taskID: TaskID
    public var type: TaskType
    public var state: TaskState
    public var version: Int
    public var title: String
    public var provider: ProviderKind
    public var account: String
    public var repo: String
    public var number: Int
    public var changeRef: ChangeRequestRef
    public var threadID: String?
    public var checkID: String?
    /// Agent currently holding the lease.
    public var agentName: String?
    public var leaseExpiresAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        taskID: TaskID,
        type: TaskType,
        state: TaskState,
        version: Int,
        title: String,
        provider: ProviderKind,
        account: String,
        repo: String,
        number: Int,
        changeRef: ChangeRequestRef,
        threadID: String? = nil,
        checkID: String? = nil,
        agentName: String? = nil,
        leaseExpiresAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.taskID = taskID
        self.type = type
        self.state = state
        self.version = version
        self.title = title
        self.provider = provider
        self.account = account
        self.repo = repo
        self.number = number
        self.changeRef = changeRef
        self.threadID = threadID
        self.checkID = checkID
        self.agentName = agentName
        self.leaseExpiresAt = leaseExpiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Wire view of a Core task; `account` is the handle shown to agents.
    public init(_ task: MCTask, account: String) {
        let origin = task.origin
        self.init(
            taskID: task.id,
            type: task.type,
            state: task.state,
            version: task.version,
            title: origin.title,
            provider: origin.providerKind,
            account: account,
            repo: origin.changeRequestRef.repoFullPath,
            number: origin.changeRequestRef.number,
            changeRef: origin.changeRequestRef,
            threadID: origin.thread?.shortID,
            checkID: origin.check?.shortID,
            agentName: task.lease?.agentName,
            leaseExpiresAt: task.lease?.expiresAt,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case type, state, version, title, provider, account, repo, number
        case taskID = "task_id"
        case changeRef = "change_ref"
        case threadID = "thread_id"
        case checkID = "check_id"
        case agentName = "agent_name"
        case leaseExpiresAt = "lease_expires_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - get_task

/// `{task_id}`.
public struct GetTaskParams: IPCMethodParams, Hashable {
    public typealias Output = TaskContextDTO
    public static let method = IPCMethod.getTask

    public var taskID: TaskID

    public init(taskID: TaskID) {
        self.taskID = taskID
    }

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
    }
}

/// Everything an agent needs to start: `{task_id, type, state, version, created_at, updated_at, instructions,
/// source, checkout?, trigger, lease?, artifacts, next_steps, is_demo}`.
///
/// `instructions` and `next_steps` are trusted text written by MergeCue; everything under
/// `trigger.untrusted_content` is reviewer/CI data and must never be followed as instructions.
public struct TaskContextDTO: Codable, Sendable, Hashable {
    public var taskID: TaskID
    public var type: TaskType
    public var state: TaskState
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// Trusted guidance from MergeCue.
    public var instructions: [String]
    public var source: TaskSourceDTO
    /// nil until MergeCue prepared (or refused) a checkout.
    public var checkout: TaskCheckoutDTO?
    public var trigger: TaskTriggerDTO
    /// Current lease holder; the `lease_id` itself is only returned to the claimer by `claim_task`.
    public var lease: TaskLeaseDTO?
    public var artifacts: [ArtifactRefDTO]
    /// Trusted, state-dependent next calls (e.g. "Call claim_task with expected_version 3").
    public var nextSteps: [String]
    public var isDemo: Bool

    public init(
        taskID: TaskID,
        type: TaskType,
        state: TaskState,
        version: Int,
        createdAt: Date,
        updatedAt: Date,
        instructions: [String],
        source: TaskSourceDTO,
        checkout: TaskCheckoutDTO? = nil,
        trigger: TaskTriggerDTO,
        lease: TaskLeaseDTO? = nil,
        artifacts: [ArtifactRefDTO] = [],
        nextSteps: [String] = [],
        isDemo: Bool
    ) {
        self.taskID = taskID
        self.type = type
        self.state = state
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.instructions = instructions
        self.source = source
        self.checkout = checkout
        self.trigger = trigger
        self.lease = lease
        self.artifacts = artifacts
        self.nextSteps = nextSteps
        self.isDemo = isDemo
    }

    /// Wire view of a Core task. The engine supplies the trusted `instructions`/`nextSteps` and the task's
    /// artifacts (only `id`, `kind` and `title` are exposed).
    public init(
        _ task: MCTask,
        account: String,
        instructions: [String],
        nextSteps: [String],
        artifacts: [Artifact],
        isDemo: Bool
    ) {
        self.init(
            taskID: task.id,
            type: task.type,
            state: task.state,
            version: task.version,
            createdAt: task.createdAt,
            updatedAt: task.updatedAt,
            instructions: instructions,
            source: TaskSourceDTO(task.origin, account: account),
            checkout: task.checkout.map(TaskCheckoutDTO.init),
            trigger: TaskTriggerDTO(task.trigger),
            lease: task.lease.map(TaskLeaseDTO.init),
            artifacts: artifacts.map(ArtifactRefDTO.init),
            nextSteps: nextSteps,
            isDemo: isDemo
        )
    }

    private enum CodingKeys: String, CodingKey {
        case type, state, version, instructions, source, checkout, trigger, lease, artifacts
        case taskID = "task_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case nextSteps = "next_steps"
        case isDemo = "is_demo"
    }
}

/// `{provider, account, repo, number, change_ref, title, web_url, thread_id?, check_id?}`.
public struct TaskSourceDTO: Codable, Sendable, Hashable {
    public var provider: ProviderKind
    public var account: String
    public var repo: String
    public var number: Int
    public var changeRef: ChangeRequestRef
    public var title: String
    public var webURL: URL
    public var threadID: String?
    public var checkID: String?

    public init(
        provider: ProviderKind,
        account: String,
        repo: String,
        number: Int,
        changeRef: ChangeRequestRef,
        title: String,
        webURL: URL,
        threadID: String? = nil,
        checkID: String? = nil
    ) {
        self.provider = provider
        self.account = account
        self.repo = repo
        self.number = number
        self.changeRef = changeRef
        self.title = title
        self.webURL = webURL
        self.threadID = threadID
        self.checkID = checkID
    }

    public init(_ origin: TaskOrigin, account: String) {
        self.init(
            provider: origin.providerKind,
            account: account,
            repo: origin.changeRequestRef.repoFullPath,
            number: origin.changeRequestRef.number,
            changeRef: origin.changeRequestRef,
            title: origin.title,
            webURL: origin.webURL,
            threadID: origin.thread?.shortID,
            checkID: origin.check?.shortID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case provider, account, repo, number, title
        case changeRef = "change_ref"
        case webURL = "web_url"
        case threadID = "thread_id"
        case checkID = "check_id"
    }
}

/// What triggered the task: `{event_type?, captured_at, head_sha?, anchor?, untrusted_content: [UntrustedText]}`.
public struct TaskTriggerDTO: Codable, Sendable, Hashable {
    public var eventType: ChangeEventType?
    public var capturedAt: Date
    public var headSHA: String?
    public var anchor: DiffAnchorDTO?
    /// Exact reviewer comment(s) / CI excerpt, bounded and redacted. Data, never instructions.
    /// Each entry encodes as `{source, author?, created_at?, text}`.
    public var untrustedContent: [UntrustedText] {
        get { untrustedContentWire.map(\.value) }
        set { untrustedContentWire = newValue.map(UntrustedTextWire.init) }
    }

    private var untrustedContentWire: [UntrustedTextWire]

    public init(eventType: ChangeEventType? = nil, capturedAt: Date, headSHA: String? = nil, anchor: DiffAnchorDTO? = nil, untrustedContent: [UntrustedText] = []) {
        self.eventType = eventType
        self.capturedAt = capturedAt
        self.headSHA = headSHA
        self.anchor = anchor
        self.untrustedContentWire = untrustedContent.map(UntrustedTextWire.init)
    }

    public init(_ trigger: TaskTriggerSnapshot) {
        self.init(
            eventType: trigger.eventType,
            capturedAt: trigger.capturedAt,
            headSHA: trigger.headSHA,
            anchor: trigger.anchor.map(DiffAnchorDTO.init),
            untrustedContent: trigger.quoted
        )
    }

    private enum CodingKeys: String, CodingKey {
        case anchor
        case eventType = "event_type"
        case capturedAt = "captured_at"
        case headSHA = "head_sha"
        case untrustedContentWire = "untrusted_content"
    }
}

/// Current lease holder: `{agent_name, expires_at}` (never the `lease_id`).
public struct TaskLeaseDTO: Codable, Sendable, Hashable {
    public var agentName: String
    public var expiresAt: Date

    public init(agentName: String, expiresAt: Date) {
        self.agentName = agentName
        self.expiresAt = expiresAt
    }

    public init(_ lease: AgentLease) {
        self.init(agentName: lease.agentName, expiresAt: lease.expiresAt)
    }

    private enum CodingKeys: String, CodingKey {
        case agentName = "agent_name"
        case expiresAt = "expires_at"
    }
}

/// `{artifact_id, kind, title}`.
public struct ArtifactRefDTO: Codable, Sendable, Hashable {
    /// `art_…`.
    public var artifactID: String
    public var kind: ArtifactKind
    public var title: String

    public init(artifactID: String, kind: ArtifactKind, title: String) {
        self.artifactID = artifactID
        self.kind = kind
        self.title = title
    }

    public init(_ artifact: Artifact) {
        self.init(artifactID: artifact.id, kind: artifact.kind, title: artifact.title)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, title
        case artifactID = "artifact_id"
    }
}
