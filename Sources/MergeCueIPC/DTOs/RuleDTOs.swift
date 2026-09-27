import Foundation
import MergeCueCore

/// Rule action on the wire (`notify|create_task|request_execution`); the task type travels separately.
public enum RuleActionKind: String, Codable, Sendable, CaseIterable, Hashable {
    case notify
    case createTask = "create_task"
    case requestExecution = "request_execution"

    public init(_ action: RuleAction) {
        switch action {
        case .notify: self = .notify
        case .createTask: self = .createTask
        case .requestExecution: self = .requestExecution
        }
    }

    /// Whether the action needs a `task_type`.
    public var requiresTaskType: Bool {
        self != .notify
    }
}

/// Quiet window: `{start: "HH:MM", end: "HH:MM", time_zone}` (overnight windows such as 22:00–07:00 allowed).
public struct QuietHoursDTO: Codable, Sendable, Hashable {
    public var start: String
    public var end: String
    /// IANA identifier, e.g. `Europe/Lisbon`.
    public var timeZone: String

    public init(start: String, end: String, timeZone: String) {
        self.start = start
        self.end = end
        self.timeZone = timeZone
    }

    public init(_ quietHours: QuietHours) {
        self.init(start: Self.format(quietHours.startMinute), end: Self.format(quietHours.endMinute), timeZone: quietHours.timeZoneID)
    }

    /// The Core value, or nil when a time or the time zone is invalid.
    public var quietHours: QuietHours? {
        guard let startMinute = Self.parse(start), let endMinute = Self.parse(end), TimeZone(identifier: timeZone) != nil else {
            return nil
        }
        return QuietHours(startMinute: startMinute, endMinute: endMinute, timeZoneID: timeZone)
    }

    func validate() throws(IPCError) {
        if Self.parse(start) == nil {
            throw IPCError.invalidParams("'quiet_hours.start' must be a 24-hour time HH:MM (got '\(start.prefix(16))').")
        }
        if Self.parse(end) == nil {
            throw IPCError.invalidParams("'quiet_hours.end' must be a 24-hour time HH:MM (got '\(end.prefix(16))').")
        }
        if TimeZone(identifier: timeZone) == nil {
            throw IPCError.invalidParams("'quiet_hours.time_zone' must be an IANA time zone identifier (got '\(timeZone.prefix(64))').")
        }
    }

    /// `HH:MM` → minutes after midnight.
    static func parse(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return hour * 60 + minute
    }

    static func format(_ minute: Int) -> String {
        let normalized = ((minute % 1440) + 1440) % 1440
        let hour = normalized / 60
        let rest = normalized % 60
        return (hour < 10 ? "0" : "") + String(hour) + ":" + (rest < 10 ? "0" : "") + String(rest)
    }

    private enum CodingKeys: String, CodingKey {
        case start, end
        case timeZone = "time_zone"
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}

// MARK: - propose_rule

/// `{name, providers?, event_types, repo_include?, repo_exclude?, action, task_type?, quiet_hours?,
/// max_fires_per_hour?}`. A proposed rule is stored inactive; only the user can activate it in the app.
public struct ProposeRuleParams: IPCMethodParams, Hashable {
    public typealias Output = ProposeRuleResult
    public static let method = IPCMethod.proposeRule
    public static let maxNameLength = 120
    public static let maxPatterns = 50
    public static let maxPatternLength = 256
    public static let maxFiresPerHourRange = 1...1000

    public var name: String
    public var providers: [ProviderKind]?
    public var eventTypes: [ChangeEventType]
    /// Globs on the repository full path (`acme/*`, `**/payments-*`).
    public var repoInclude: [String]?
    public var repoExclude: [String]?
    public var action: RuleActionKind
    public var taskType: TaskType?
    public var quietHours: QuietHoursDTO?
    public var maxFiresPerHour: Int?

    public init(
        name: String,
        providers: [ProviderKind]? = nil,
        eventTypes: [ChangeEventType],
        repoInclude: [String]? = nil,
        repoExclude: [String]? = nil,
        action: RuleActionKind,
        taskType: TaskType? = nil,
        quietHours: QuietHoursDTO? = nil,
        maxFiresPerHour: Int? = nil
    ) {
        self.name = name
        self.providers = providers
        self.eventTypes = eventTypes
        self.repoInclude = repoInclude
        self.repoExclude = repoExclude
        self.action = action
        self.taskType = taskType
        self.quietHours = quietHours
        self.maxFiresPerHour = maxFiresPerHour
    }

    /// The Core action (nil only when a task action lacks `task_type`, which `validate()` rejects).
    public var ruleAction: RuleAction? {
        switch action {
        case .notify: .notify
        case .createTask: taskType.map(RuleAction.createTask)
        case .requestExecution: taskType.map(RuleAction.requestExecution)
        }
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireText(name, field: "name", maxLength: Self.maxNameLength)
        if eventTypes.isEmpty {
            throw IPCError.invalidParams("'event_types' must list at least one event type.")
        }
        try IPCValidation.requireList(repoInclude, field: "repo_include", maxCount: Self.maxPatterns, maxLength: Self.maxPatternLength)
        try IPCValidation.requireList(repoExclude, field: "repo_exclude", maxCount: Self.maxPatterns, maxLength: Self.maxPatternLength)
        if action.requiresTaskType, taskType == nil {
            throw IPCError.invalidParams("'task_type' is required when 'action' is \(action.rawValue).")
        }
        if !action.requiresTaskType, taskType != nil {
            throw IPCError.invalidParams("'task_type' is only valid with create_task or request_execution.")
        }
        try quietHours?.validate()
        try IPCValidation.requireRange(maxFiresPerHour, field: "max_fires_per_hour", Self.maxFiresPerHourRange)
    }

    private enum CodingKeys: String, CodingKey {
        case name, providers, action
        case eventTypes = "event_types"
        case repoInclude = "repo_include"
        case repoExclude = "repo_exclude"
        case taskType = "task_type"
        case quietHours = "quiet_hours"
        case maxFiresPerHour = "max_fires_per_hour"
    }
}

/// Status of an agent-proposed rule.
public enum RuleProposalStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case pendingActivation = "pending_activation"
}

/// `{rule_id, status: "pending_activation", preview}` — `preview` is a human-readable description of what the
/// rule would do, for the agent to relay to the user.
public struct ProposeRuleResult: Codable, Sendable, Hashable {
    public var ruleID: String
    public var status: RuleProposalStatus
    public var preview: String

    public init(ruleID: String, status: RuleProposalStatus = .pendingActivation, preview: String) {
        self.ruleID = ruleID
        self.status = status
        self.preview = preview
    }

    private enum CodingKeys: String, CodingKey {
        case status, preview
        case ruleID = "rule_id"
    }
}

// MARK: - list_rules

/// `list_rules` takes no parameters: `{}`.
public struct ListRulesParams: IPCMethodParams, Hashable {
    public typealias Output = ListRulesResult
    public static let method = IPCMethod.listRules

    public init() {}
}

/// `{rules: [RuleSummaryDTO]}`.
public struct ListRulesResult: Codable, Sendable, Hashable {
    public var rules: [RuleSummaryDTO]

    public init(rules: [RuleSummaryDTO]) {
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case rules
    }
}

/// `{rule_id, name, active, origin, action, task_type?, event_types}`.
public struct RuleSummaryDTO: Codable, Sendable, Hashable {
    public var ruleID: String
    public var name: String
    public var active: Bool
    public var origin: RuleOrigin
    public var action: RuleActionKind
    public var taskType: TaskType?
    /// Sorted by wire name (deterministic output).
    public var eventTypes: [ChangeEventType]

    public init(ruleID: String, name: String, active: Bool, origin: RuleOrigin, action: RuleActionKind, taskType: TaskType? = nil, eventTypes: [ChangeEventType]) {
        self.ruleID = ruleID
        self.name = name
        self.active = active
        self.origin = origin
        self.action = action
        self.taskType = taskType
        self.eventTypes = eventTypes
    }

    public init(_ rule: Rule) {
        self.init(
            ruleID: rule.id,
            name: rule.name,
            active: rule.isActive,
            origin: rule.origin,
            action: RuleActionKind(rule.action),
            taskType: rule.action.taskType,
            eventTypes: rule.eventTypes.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name, active, origin, action
        case ruleID = "rule_id"
        case taskType = "task_type"
        case eventTypes = "event_types"
    }
}
