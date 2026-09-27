import Foundation
import MergeCueCore

/// Everything one sync cycle of one account persists, applied atomically by `MergeCueDatabase.applySyncBatch(_:)`.
///
/// Every snapshot, removed key, event and attention item must belong to `account` (the batch is rejected
/// otherwise), so one account's cycle can never write another account's rows.
public struct SyncBatch: Sendable, Hashable {
    public var account: AccountKey
    /// Upserted by change request id.
    public var snapshots: [ChangeRequestSnapshot]
    /// Deleted after the upserts (a key in both lists ends up removed).
    public var removedChangeRequests: [ChangeRequestKey]
    /// Inserted exactly once by event id; `applySyncBatch` returns only the newly inserted ones.
    public var events: [ChangeEvent]
    /// Merged into stored items by dedupe key with `AttentionMergePolicy`.
    public var attentionUpserts: [AttentionItem]
    /// Replaces the account's stored cursor.
    public var cursor: [String: String]
    public var syncedAt: Date

    public init(
        account: AccountKey,
        snapshots: [ChangeRequestSnapshot] = [],
        removedChangeRequests: [ChangeRequestKey] = [],
        events: [ChangeEvent] = [],
        attentionUpserts: [AttentionItem] = [],
        cursor: [String: String] = [:],
        syncedAt: Date
    ) {
        self.account = account
        self.snapshots = snapshots
        self.removedChangeRequests = removedChangeRequests
        self.events = events
        self.attentionUpserts = attentionUpserts
        self.cursor = cursor
        self.syncedAt = syncedAt
    }
}

/// An append-only audit record: agent-reported events, rejected calls and every attempt/outcome of a user-approved
/// write. Audit entries are kept when an account is deleted and are only removed by retention.
public struct AuditEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Outcome: String, Codable, Sendable, CaseIterable {
        case attempted, succeeded, failed, rejected
    }

    /// `aud_…` (`IDGenerator.auditID()`).
    public var id: String
    public var at: Date
    /// Who acted: `user`, `system`, or `agent:<name>`.
    public var actor: String
    /// What was done, e.g. a `RemoteActionKind` raw value (`post_reply`) or an IPC method (`claim_task`).
    public var action: String
    /// What it was done to: a task id, change ref, thread short id, …
    public var target: String
    public var outcome: Outcome
    /// Free text. Redacted with `SecretRedactor` before it is stored.
    public var detail: String
    /// The task this entry belongs to, if any (audit of non-terminal tasks is never pruned).
    public var taskID: TaskID?

    public init(
        id: String,
        at: Date,
        actor: String,
        action: String,
        target: String,
        outcome: Outcome,
        detail: String = "",
        taskID: TaskID? = nil
    ) {
        self.id = id
        self.at = at
        self.actor = actor
        self.action = action
        self.target = target
        self.outcome = outcome
        self.detail = detail
        self.taskID = taskID
    }
}

/// How `applySyncBatch` merges an incoming (derived) attention item into the stored item with the same dedupe key.
///
/// Sync owns the *content* of an item; the user owns its *state*. Concretely, for a stored item `S` and an incoming
/// item `I`:
/// - **Content** (title, summary, reason, priority, thread, check, suggested actions, repo path, change request)
///   comes from `I`. `id` and `createdAt` stay those of `S`; `updatedAt` is the later of both; `eventIDs` is the
///   union (stored order first, then new ids), capped to the newest `maxEventIDs`; `linkedTaskID` keeps `S`'s link
///   (`I`'s only fills an empty one).
/// - **New activity** means `I` carries event ids `S` has not seen **and** `I.updatedAt > S.updatedAt` (Sync sets
///   `updatedAt` to the time of the item's latest activity, so re-sent or older events never count).
/// - **State** (`isUnread`, `disposition`):
///   - `I` is `.resolved` (condition cleared) → `.resolved`, unless the user dismissed it (stays `.dismissed`);
///     `isUnread` is kept.
///   - new activity on a `.resolved` or `.acknowledged` item → reopened: `.open` and unread.
///   - new activity on an `.open` item → unread again; on a `.snoozed` item → unread but still snoozed until the
///     snooze expires; on a `.dismissed` item → nothing (dismissed stays dismissed, read state kept).
///   - anything else (the same state re-derived every cycle) → `S`'s `isUnread` and `disposition` are kept.
public enum AttentionMergePolicy {
    /// Upper bound of `eventIDs` kept on one item (the newest are kept).
    public static let maxEventIDs = 200

    /// The item to store when `incoming` is upserted and `existing` is already stored (nil = insert `incoming`).
    public static func merge(existing: AttentionItem?, incoming: AttentionItem) -> AttentionItem {
        guard let existing else { return incoming }
        var merged = incoming
        merged.id = existing.id
        merged.createdAt = existing.createdAt
        merged.updatedAt = max(existing.updatedAt, incoming.updatedAt)
        merged.linkedTaskID = existing.linkedTaskID ?? incoming.linkedTaskID

        let known = Set(existing.eventIDs)
        var seen = known
        var newIDs: [String] = []
        for id in incoming.eventIDs where !seen.contains(id) {
            seen.insert(id)
            newIDs.append(id)
        }
        merged.eventIDs = Array((existing.eventIDs + newIDs).suffix(maxEventIDs))

        let hasNewActivity = !newIDs.isEmpty && incoming.updatedAt > existing.updatedAt
        merged.isUnread = existing.isUnread
        merged.disposition = existing.disposition

        if incoming.disposition == .resolved {
            if existing.disposition != .dismissed {
                merged.disposition = .resolved
            }
            return merged
        }
        guard hasNewActivity else { return merged }
        switch existing.disposition {
        case .resolved, .acknowledged:
            merged.disposition = .open
            merged.isUnread = true
        case .open, .snoozed:
            merged.isUnread = true
        case .dismissed:
            break
        }
        return merged
    }
}
