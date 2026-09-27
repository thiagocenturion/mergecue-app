import Foundation

/// Why an item needs the user.
public enum AttentionReason: String, Codable, Sendable, CaseIterable {
    case reviewComment = "review_comment"
    case changesRequested = "changes_requested"
    case reviewerQuestion = "reviewer_question"
    case codeSuggestion = "code_suggestion"
    case reply
    case ciFailed = "ci_failed"
    case reviewRequested = "review_requested"
    case readyToMerge = "ready_to_merge"
    case mergeConflict = "merge_conflict"

    public var displayName: String {
        switch self {
        case .reviewComment: "Review comment"
        case .changesRequested: "Changes requested"
        case .reviewerQuestion: "Reviewer question"
        case .codeSuggestion: "Code suggestion"
        case .reply: "New reply"
        case .ciFailed: "CI failed"
        case .reviewRequested: "Review requested"
        case .readyToMerge: "Ready to merge"
        case .mergeConflict: "Merge conflict"
        }
    }

    /// Default priority used by attention derivation.
    public var defaultPriority: AttentionPriority {
        switch self {
        case .changesRequested, .ciFailed, .mergeConflict: .high
        case .reviewComment, .reviewerQuestion, .codeSuggestion, .reply, .reviewRequested: .normal
        case .readyToMerge: .low
        }
    }

    /// Default actions offered for this reason.
    public var defaultSuggestedActions: [AttentionAction] {
        switch self {
        case .reviewComment, .changesRequested:
            [.fixWithAI, .draftReply, .openInProvider, .acknowledge, .snooze]
        case .reviewerQuestion, .reply:
            [.draftReply, .openInProvider, .acknowledge, .snooze]
        case .codeSuggestion:
            [.addressWithAI, .openInProvider, .acknowledge, .snooze]
        case .ciFailed:
            [.investigateWithAI, .openInProvider, .acknowledge, .snooze]
        case .reviewRequested, .readyToMerge, .mergeConflict:
            [.openInProvider, .acknowledge, .snooze]
        }
    }
}

/// Attention priority, ordered `low < normal < high < urgent`.
public enum AttentionPriority: Int, Codable, Sendable, Comparable, CaseIterable {
    case low, normal, high, urgent

    public static func < (lhs: AttentionPriority, rhs: AttentionPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The user's disposition of an attention item.
public enum AttentionDisposition: Codable, Sendable, Hashable {
    case open
    case acknowledged
    case snoozed(until: Date)
    /// The underlying condition cleared (thread resolved, CI recovered, merged/closed).
    case resolved
    case dismissed

    /// Stable machine name used as the JSON `type` (and as an indexed column value).
    public var name: String {
        switch self {
        case .open: "open"
        case .acknowledged: "acknowledged"
        case .snoozed: "snoozed"
        case .resolved: "resolved"
        case .dismissed: "dismissed"
        }
    }

    /// Open, or snoozed with an expired snooze.
    public func isActionable(now: Date) -> Bool {
        switch self {
        case .open: true
        case .snoozed(let until): now >= until
        case .acknowledged, .resolved, .dismissed: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, until
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "open": self = .open
        case "acknowledged": self = .acknowledged
        case "snoozed": self = .snoozed(until: try container.decode(Date.self, forKey: .until))
        case "resolved": self = .resolved
        case "dismissed": self = .dismissed
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown disposition \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .type)
        if case .snoozed(let until) = self {
            try container.encode(until, forKey: .until)
        }
    }
}

/// Actions the UI can offer on an attention item.
public enum AttentionAction: String, Codable, Sendable, CaseIterable {
    case fixWithAI = "fix_with_ai"
    case investigateWithAI = "investigate_with_ai"
    case draftReply = "draft_reply"
    case addressWithAI = "address_with_ai"
    case openInProvider = "open_in_provider"
    case acknowledge
    case snooze
    case markRead = "mark_read"
}

/// One actionable item in the inbox. One item per dedupe key (CR+thread, CR+check name, CR+reason).
public struct AttentionItem: Codable, Sendable, Hashable, Identifiable {
    /// `att_…` = `ShortID` of `dedupeKey`.
    public var id: String
    public var dedupeKey: String
    public var account: AccountKey
    public var providerKind: ProviderKind
    public var changeRequest: ChangeRequestKey
    public var repoFullPath: String
    public var number: Int
    public var title: String
    public var reason: AttentionReason
    public var priority: AttentionPriority
    public var summary: String
    public var thread: ThreadKey?
    public var check: CheckKey?
    public var eventIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var isUnread: Bool
    public var disposition: AttentionDisposition
    public var linkedTaskID: TaskID?
    public var suggestedActions: [AttentionAction]

    public init(
        id: String? = nil,
        dedupeKey: String,
        account: AccountKey,
        providerKind: ProviderKind? = nil,
        changeRequest: ChangeRequestKey,
        repoFullPath: String,
        number: Int? = nil,
        title: String,
        reason: AttentionReason,
        priority: AttentionPriority? = nil,
        summary: String,
        thread: ThreadKey? = nil,
        check: CheckKey? = nil,
        eventIDs: [String] = [],
        createdAt: Date,
        updatedAt: Date,
        isUnread: Bool = true,
        disposition: AttentionDisposition = .open,
        linkedTaskID: TaskID? = nil,
        suggestedActions: [AttentionAction]? = nil
    ) {
        self.id = id ?? Self.makeID(dedupeKey: dedupeKey)
        self.dedupeKey = dedupeKey
        self.account = account
        self.providerKind = providerKind ?? changeRequest.kind
        self.changeRequest = changeRequest
        self.repoFullPath = repoFullPath
        self.number = number ?? changeRequest.number
        self.title = title
        self.reason = reason
        self.priority = priority ?? reason.defaultPriority
        self.summary = summary
        self.thread = thread
        self.check = check
        self.eventIDs = eventIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isUnread = isUnread
        self.disposition = disposition
        self.linkedTaskID = linkedTaskID
        self.suggestedActions = suggestedActions ?? reason.defaultSuggestedActions
    }

    /// Open, or snoozed with an expired snooze; not resolved, dismissed or acknowledged.
    public func isActionable(now: Date) -> Bool {
        disposition.isActionable(now: now)
    }

    /// Provider-qualified reference.
    public var changeRequestRef: ChangeRequestRef {
        ChangeRequestRef(kind: providerKind, host: account.host, repoFullPath: repoFullPath, number: number)
    }

    // MARK: Dedupe keys (shared by Sync and Engine so both derive identical ids)

    /// `att_` + 10 hex of SHA-256(`dedupeKey`).
    public static func makeID(dedupeKey: String) -> String {
        ShortID.make(prefix: ShortID.attentionPrefix, from: dedupeKey)
    }

    /// One item per change request + thread.
    public static func dedupeKey(thread: ThreadKey) -> String {
        "att:thread/\(thread.id)"
    }

    /// One item per change request + check name (re-runs of the same check update the same item).
    public static func dedupeKey(changeRequest: ChangeRequestKey, checkName: String) -> String {
        "att:check/\(changeRequest.id)/\(StableID.encode(checkName))"
    }

    /// One item per change request + reason (review requested, ready to merge, merge conflict, …).
    public static func dedupeKey(changeRequest: ChangeRequestKey, reason: AttentionReason) -> String {
        "att:reason/\(changeRequest.id)/\(reason.rawValue)"
    }
}
