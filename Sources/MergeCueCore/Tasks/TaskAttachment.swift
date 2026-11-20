import Foundation

/// An inbox item added to an existing task ("Add to Task" / "Merge into…"), so related feedback on one change
/// request is handled by one task instead of several (DECISIONS D38).
///
/// The task's `origin` stays its main item: replies and thread resolution apply to `origin.thread` only. Attached
/// items are extra context: their comment(s) / CI excerpt are captured when attached, bounded and redacted like
/// the trigger snapshot, and are always untrusted data.
public struct TaskAttachment: Codable, Sendable, Hashable, Identifiable {
    public var attentionItemID: String
    public var reason: AttentionReason?
    public var thread: ThreadKey?
    public var check: CheckKey?
    public var attachedAt: Date
    public var headSHA: String?
    /// Exact comment(s) / CI log excerpt captured when the item was attached (bounded, redacted, untrusted).
    public var quoted: [UntrustedText]
    public var anchor: DiffAnchor?
    /// The task this item came from when that task was merged into this one.
    public var mergedFromTaskID: TaskID?

    public var id: String { attentionItemID }

    public init(
        attentionItemID: String,
        reason: AttentionReason? = nil,
        thread: ThreadKey? = nil,
        check: CheckKey? = nil,
        attachedAt: Date,
        headSHA: String? = nil,
        quoted: [UntrustedText] = [],
        anchor: DiffAnchor? = nil,
        mergedFromTaskID: TaskID? = nil
    ) {
        self.attentionItemID = attentionItemID
        self.reason = reason
        self.thread = thread
        self.check = check
        self.attachedAt = attachedAt
        self.headSHA = headSHA
        self.quoted = quoted
        self.anchor = anchor
        self.mergedFromTaskID = mergedFromTaskID
    }
}

/// Which tasks can take more items, and which can be merged into another one.
public enum TaskMerging {
    /// Upper bound of attached items per task (keeps `get_task` bounded).
    public static let maxAttachments = 20

    /// Active tasks except while an approved remote action runs.
    public static func acceptsAttachments(_ state: TaskState) -> Bool {
        !state.isTerminal && state != .approvedAction
    }

    /// Tasks with no agent work in flight and no result waiting: merging them loses nothing.
    public static func canMergeAway(_ state: TaskState) -> Bool {
        [.waitingForAgent, .blocked, .failed, .stale].contains(state)
    }

    /// Why `state` cannot be merged into another task, for the UI and errors.
    public static func mergeAwayRefusal(_ state: TaskState) -> String? {
        switch state {
        case .waitingForAgent, .blocked, .failed, .stale: nil
        case .working: "An agent is working on this task. Wait for its result or cancel it first."
        case .readyForReview: "This task has a result waiting for your review. Review it or discard it first."
        case .approvedAction: "An approved action is running on this task."
        case .done, .cancelled, .dismissed: "This task is finished."
        }
    }
}

extension MCTask {
    /// Attention item ids this task covers: the origin item first, then attached items in the order added.
    public var coveredAttentionIDs: [String] {
        (origin.attentionItemID.map { [$0] } ?? []) + attachments.map(\.attentionItemID)
    }

    /// The attachment for `attentionID`, if it was added to this task.
    public func attachment(for attentionID: String) -> TaskAttachment? {
        attachments.first { $0.attentionItemID == attentionID }
    }
}
