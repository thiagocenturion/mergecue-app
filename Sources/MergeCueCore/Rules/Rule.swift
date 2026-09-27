import Foundation

/// What a rule does when it fires. Rules can never bypass approval for repository writes.
public enum RuleAction: Codable, Sendable, Hashable {
    case notify
    case createTask(TaskType)
    /// Create a task and request unattended execution; degrades to `createTask` unless an execution mode is verified.
    case requestExecution(TaskType)

    /// Stable machine name (JSON `type`): `notify`, `create_task`, `request_execution`.
    public var name: String {
        switch self {
        case .notify: "notify"
        case .createTask: "create_task"
        case .requestExecution: "request_execution"
        }
    }

    public var taskType: TaskType? {
        switch self {
        case .notify: nil
        case .createTask(let type), .requestExecution(let type): type
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case taskType = "task_type"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "notify": self = .notify
        case "create_task": self = .createTask(try container.decode(TaskType.self, forKey: .taskType))
        case "request_execution": self = .requestExecution(try container.decode(TaskType.self, forKey: .taskType))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown rule action \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .type)
        if let taskType {
            try container.encode(taskType, forKey: .taskType)
        }
    }
}

/// Who authored a rule.
public enum RuleOrigin: String, Codable, Sendable, CaseIterable {
    case user, template
    case agentProposal = "agent_proposal"
}

/// A daily quiet window in a given time zone. Overnight windows (`start > end`, e.g. 22:00–07:00) are supported;
/// `start == end` is an empty window.
public struct QuietHours: Codable, Sendable, Hashable {
    /// Minutes after local midnight, 0..<1440 (other values are normalized modulo 1440).
    public var startMinute: Int
    public var endMinute: Int
    public var timeZoneID: String

    public init(startMinute: Int, endMinute: Int, timeZoneID: String) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.timeZoneID = timeZoneID
    }

    /// Convenience: `QuietHours(start: (22, 0), end: (7, 0), timeZone: .current)`.
    public init(start: (hour: Int, minute: Int), end: (hour: Int, minute: Int), timeZone: TimeZone) {
        self.init(startMinute: start.hour * 60 + start.minute, endMinute: end.hour * 60 + end.minute, timeZoneID: timeZone.identifier)
    }

    /// The configured zone; unknown identifiers fall back to GMT (deterministic, never the machine zone).
    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneID) ?? .gmt
    }

    /// Whether `date` falls inside the window (start inclusive, end exclusive) in `timeZoneID`.
    public func contains(_ date: Date) -> Bool {
        let start = Self.normalize(startMinute)
        let end = Self.normalize(endMinute)
        guard start != end else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if start < end {
            return minute >= start && minute < end
        }
        return minute >= start || minute < end
    }

    private static func normalize(_ minute: Int) -> Int {
        ((minute % 1440) + 1440) % 1440
    }
}

/// A user-approved automation rule. Every set/list filter uses "empty = any".
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Only an explicit user activation in the app sets this to true.
    public var isActive: Bool
    public var origin: RuleOrigin
    public var providerKinds: Set<ProviderKind>
    public var accounts: Set<AccountKey>
    public var eventTypes: Set<ChangeEventType>
    /// Globs on `repoFullPath` (`*`, `**`, `?`), case-insensitive. Empty = any repository.
    public var repoInclude: [String]
    public var repoExclude: [String]
    public var involvement: Set<Involvement>
    /// Usernames (case-insensitive, optional leading `@`) whose events never fire the rule.
    public var excludeAuthors: [String]
    /// Restricts comment-bearing events to these comment kinds (e.g. `.question`). Empty = any event.
    public var commentKinds: Set<CommentKind>
    public var action: RuleAction
    /// Maximum firings in any rolling hour; values ≤ 0 mean the rule never fires.
    public var maxFiresPerHour: Int
    public var quietHours: QuietHours?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        name: String,
        isActive: Bool = false,
        origin: RuleOrigin,
        providerKinds: Set<ProviderKind> = [],
        accounts: Set<AccountKey> = [],
        eventTypes: Set<ChangeEventType> = [],
        repoInclude: [String] = [],
        repoExclude: [String] = [],
        involvement: Set<Involvement> = [],
        excludeAuthors: [String] = [],
        commentKinds: Set<CommentKind> = [],
        action: RuleAction,
        maxFiresPerHour: Int = 10,
        quietHours: QuietHours? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isActive = isActive
        self.origin = origin
        self.providerKinds = providerKinds
        self.accounts = accounts
        self.eventTypes = eventTypes
        self.repoInclude = repoInclude
        self.repoExclude = repoExclude
        self.involvement = involvement
        self.excludeAuthors = excludeAuthors
        self.commentKinds = commentKinds
        self.action = action
        self.maxFiresPerHour = maxFiresPerHour
        self.quietHours = quietHours
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isActive, origin, providerKinds, accounts, eventTypes, repoInclude, repoExclude, involvement
        case excludeAuthors, commentKinds, action, maxFiresPerHour, quietHours, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        origin = try c.decode(RuleOrigin.self, forKey: .origin)
        providerKinds = try c.decodeIfPresent(Set<ProviderKind>.self, forKey: .providerKinds) ?? []
        accounts = try c.decodeIfPresent(Set<AccountKey>.self, forKey: .accounts) ?? []
        eventTypes = try c.decodeIfPresent(Set<ChangeEventType>.self, forKey: .eventTypes) ?? []
        repoInclude = try c.decodeIfPresent([String].self, forKey: .repoInclude) ?? []
        repoExclude = try c.decodeIfPresent([String].self, forKey: .repoExclude) ?? []
        involvement = try c.decodeIfPresent(Set<Involvement>.self, forKey: .involvement) ?? []
        excludeAuthors = try c.decodeIfPresent([String].self, forKey: .excludeAuthors) ?? []
        commentKinds = try c.decodeIfPresent(Set<CommentKind>.self, forKey: .commentKinds) ?? []
        action = try c.decode(RuleAction.self, forKey: .action)
        maxFiresPerHour = try c.decode(Int.self, forKey: .maxFiresPerHour)
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}
