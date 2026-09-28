import Foundation

/// What a notification is about, as the owner switches it on or off in Settings ▸ Notifications ("Notify me about").
///
/// Categories only decide whether an **alert** is delivered. Attention items, events, rules and tasks are derived
/// exactly the same way whatever the preferences say.
public enum NotificationCategory: String, Codable, Sendable, CaseIterable {
    /// Blocking review comments, requested changes, code suggestions, replies in threads you take part in and merge
    /// conflicts.
    case reviewComments = "review_comments"
    /// Failed CI checks / pipelines.
    case ciFailures = "ci_failures"
    /// Review comments that ask you something.
    case reviewerQuestions = "reviewer_questions"
    /// Someone requested your review.
    case reviewRequests = "review_requests"
    /// Approvals and "ready to merge" on your own PRs/MRs.
    case approvals
    /// An agent submitted a result that is ready for your review.
    case agentResults = "agent_results"

    /// The category of an attention reason.
    public init(reason: AttentionReason) {
        switch reason {
        case .reviewComment, .changesRequested, .codeSuggestion, .reply, .mergeConflict: self = .reviewComments
        case .reviewerQuestion: self = .reviewerQuestions
        case .ciFailed: self = .ciFailures
        case .reviewRequested: self = .reviewRequests
        case .readyToMerge: self = .approvals
        }
    }

    /// The category of an informational event (one that notifies without an attention item), if any.
    public init?(informationalEvent type: ChangeEventType) {
        switch type {
        case .approval, .readyToMerge: self = .approvals
        case .reviewComment, .changeRequested, .reply: self = .reviewComments
        case .ciFailed: self = .ciFailures
        case .reviewRequested: self = .reviewRequests
        case .ciRecovered, .merged, .closedWithoutMerge, .headChanged, .threadResolved: return nil
        }
    }

    /// Settings label.
    public var displayName: String {
        switch self {
        case .reviewComments: "Blocking review comments, replies and requested changes"
        case .ciFailures: "Failed CI checks on my PRs/MRs"
        case .reviewerQuestions: "Reviewer questions"
        case .reviewRequests: "Review requests"
        case .approvals: "Approvals and ready to merge on my PRs/MRs"
        case .agentResults: "Agent results ready for review"
        }
    }
}

/// The owner's per-category notification switches (persisted by the engine, honoured by Sync's
/// `NotificationGrouper` and by the engine's agent-result notification). Every category is on by default; only the
/// switched-off ones are stored, so categories added later start enabled.
public struct NotificationPreferences: Codable, Sendable, Hashable {
    /// Categories the owner switched off.
    public var disabled: Set<NotificationCategory>

    public init(disabled: Set<NotificationCategory> = []) {
        self.disabled = disabled
    }

    /// Everything on (the default).
    public static let allEnabled = NotificationPreferences()

    public func isEnabled(_ category: NotificationCategory) -> Bool {
        !disabled.contains(category)
    }

    /// Whether an attention item with `reason` may raise an alert.
    public func allows(_ reason: AttentionReason) -> Bool {
        isEnabled(NotificationCategory(reason: reason))
    }

    /// Whether an informational event (no attention item) may raise an alert. Events without a category are allowed.
    public func allows(informationalEvent type: ChangeEventType) -> Bool {
        NotificationCategory(informationalEvent: type).map(isEnabled) ?? true
    }

    public mutating func set(_ category: NotificationCategory, enabled: Bool) {
        if enabled { disabled.remove(category) } else { disabled.insert(category) }
    }

    public func setting(_ category: NotificationCategory, enabled: Bool) -> NotificationPreferences {
        var copy = self
        copy.set(category, enabled: enabled)
        return copy
    }

    // Sorted array encoding (stable bytes, D17); unknown categories from a newer build are ignored.
    private enum CodingKeys: String, CodingKey { case disabled }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String].self, forKey: .disabled) ?? []
        disabled = Set(raw.compactMap(NotificationCategory.init(rawValue:)))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(disabled.map(\.rawValue).sorted(), forKey: .disabled)
    }
}
