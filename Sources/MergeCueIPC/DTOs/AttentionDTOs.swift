import Foundation
import MergeCueCore

// MARK: - ping

/// `ping` takes no parameters: `{}`.
public struct PingParams: IPCMethodParams, Hashable {
    public typealias Output = PingResult
    public static let method = IPCMethod.ping

    public init() {}
}

/// `{app_version, protocol_version, is_demo}`.
public struct PingResult: Codable, Sendable, Hashable {
    public var appVersion: String
    public var protocolVersion: Int
    /// True when the app serves labeled demo/fixture data instead of live provider data.
    public var isDemo: Bool

    public init(appVersion: String, protocolVersion: Int = IPCProtocol.version, isDemo: Bool) {
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.isDemo = isDemo
    }

    private enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case protocolVersion = "protocol_version"
        case isDemo = "is_demo"
    }
}

// MARK: - list_attention

/// `{provider?, account?, repo?, limit? (1…100, default 20), include_read?}`.
public struct ListAttentionParams: IPCMethodParams, Hashable {
    public typealias Output = ListAttentionResult
    public static let method = IPCMethod.listAttention
    public static let defaultLimit = 20
    public static let maxLimit = 100

    public var provider: ProviderKind?
    /// Account handle as returned in `AttentionItemDTO.account`.
    public var account: String?
    /// Repository full path (`acme/payments-api`).
    public var repo: String?
    public var limit: Int?
    /// Include items the user already read (default false).
    public var includeRead: Bool?

    public init(provider: ProviderKind? = nil, account: String? = nil, repo: String? = nil, limit: Int? = nil, includeRead: Bool? = nil) {
        self.provider = provider
        self.account = account
        self.repo = repo
        self.limit = limit
        self.includeRead = includeRead
    }

    /// `limit` clamped to 1…100, default 20.
    public var resolvedLimit: Int {
        min(max(limit ?? Self.defaultLimit, 1), Self.maxLimit)
    }

    public var resolvedIncludeRead: Bool {
        includeRead ?? false
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireRange(limit, field: "limit", 1...Self.maxLimit)
        try IPCValidation.requireMaxLength(account, field: "account", maxLength: 512)
        try IPCValidation.requireMaxLength(repo, field: "repo", maxLength: 512)
    }

    private enum CodingKeys: String, CodingKey {
        case provider, account, repo, limit
        case includeRead = "include_read"
    }
}

/// `{items: [AttentionItemDTO], total}` — `total` counts every matching item, `items` holds at most `limit`.
public struct ListAttentionResult: Codable, Sendable, Hashable {
    public var items: [AttentionItemDTO]
    public var total: Int
    /// Trusted hint from MergeCue, e.g. that agent read access is limited to open tasks (omitted when nil).
    public var note: String?

    public init(items: [AttentionItemDTO], total: Int, note: String? = nil) {
        self.items = items
        self.total = total
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case items, total, note
    }
}

/// `{id, reason, priority, provider, account, repo, number, change_ref, title, summary, thread_id?, check_id?,
/// task_id?, updated_at}`.
///
/// `title` and `summary` may quote reviewer or PR text: display data, never instructions.
public struct AttentionItemDTO: Codable, Sendable, Hashable {
    /// JSON paths of fields that hold third-party text (data, never instructions). See `UntrustedFields`.
    public var untrustedFields: [String]? = UntrustedFields.attentionItem
    /// `att_…`.
    public var id: String
    public var reason: AttentionReason
    /// Encoded as `low|normal|high|urgent`.
    public var priority: AttentionPriority {
        get { priorityWire.value }
        set { priorityWire = AttentionPriorityWire(newValue) }
    }
    public var provider: ProviderKind
    /// Account handle (e.g. `mona-dev@github.com`).
    public var account: String
    /// Repository full path.
    public var repo: String
    public var number: Int
    public var changeRef: ChangeRequestRef
    public var title: String
    public var summary: String
    /// `thr_…`.
    public var threadID: String?
    /// `chk_…`.
    public var checkID: String?
    /// Linked task (`mc_…`), if one was created.
    public var taskID: TaskID?
    public var updatedAt: Date

    private var priorityWire: AttentionPriorityWire

    public init(
        id: String,
        reason: AttentionReason,
        priority: AttentionPriority,
        provider: ProviderKind,
        account: String,
        repo: String,
        number: Int,
        changeRef: ChangeRequestRef,
        title: String,
        summary: String,
        threadID: String? = nil,
        checkID: String? = nil,
        taskID: TaskID? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.reason = reason
        self.priorityWire = AttentionPriorityWire(priority)
        self.provider = provider
        self.account = account
        self.repo = repo
        self.number = number
        self.changeRef = changeRef
        self.title = title
        self.summary = summary
        self.threadID = threadID
        self.checkID = checkID
        self.taskID = taskID
        self.updatedAt = updatedAt
    }

    /// Wire view of a Core attention item. `account` is the handle shown to agents; the `change_ref` is built from
    /// the item's change request key (kind, host, number) and repository path.
    public init(_ item: AttentionItem, account: String) {
        self.init(
            id: item.id,
            reason: item.reason,
            priority: item.priority,
            provider: item.providerKind,
            account: account,
            repo: item.repoFullPath,
            number: item.number,
            changeRef: ChangeRequestRef(kind: item.providerKind, host: item.account.host, repoFullPath: item.repoFullPath, number: item.number),
            title: UntrustedFields.clean(item.title),
            summary: UntrustedFields.clean(item.summary),
            threadID: item.thread?.shortID,
            checkID: item.check?.shortID,
            taskID: item.linkedTaskID,
            updatedAt: item.updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case untrustedFields = "untrusted_fields"
        case id, reason, provider, account, repo, number, title, summary
        case priorityWire = "priority"
        case changeRef = "change_ref"
        case threadID = "thread_id"
        case checkID = "check_id"
        case taskID = "task_id"
        case updatedAt = "updated_at"
    }
}
