import Foundation
import MergeCueCore

extension MergeCueDatabase {
    // MARK: Attention items

    /// Attention items, highest priority and most recent activity first. With `includeInactive == false` only
    /// actionable items are returned (`AttentionItem.isActionable(now:)`: open, or snoozed with an expired snooze).
    public func attentionItems(includeInactive: Bool, now: Date = Date()) throws -> [AttentionItem] {
        if includeInactive {
            return try connection.query(
                "SELECT data FROM attention_items ORDER BY priority DESC, updated_at DESC, id"
            ) { try decode(AttentionItem.self, from: $0, column: 0) }
        }
        return try connection.query(
            """
            SELECT data FROM attention_items
            WHERE disposition = 'open' OR (disposition = 'snoozed' AND snoozed_until <= ?)
            ORDER BY priority DESC, updated_at DESC, id
            """,
            [.date(now)]
        ) { try decode(AttentionItem.self, from: $0, column: 0) }
    }

    /// Every attention item of one change request (any disposition), most recent activity first.
    public func attentionItems(changeRequest: ChangeRequestKey) throws -> [AttentionItem] {
        try connection.query(
            "SELECT data FROM attention_items WHERE cr_id = ? ORDER BY updated_at DESC, id", [.text(changeRequest.id)]
        ) { try decode(AttentionItem.self, from: $0, column: 0) }
    }

    public func attentionItem(id: String) throws -> AttentionItem? {
        try connection.queryFirst("SELECT data FROM attention_items WHERE id = ?", [.text(id)]) {
            try decode(AttentionItem.self, from: $0, column: 0)
        }
    }

    public func attentionItem(dedupeKey: String) throws -> AttentionItem? {
        try connection.queryFirst("SELECT data FROM attention_items WHERE dedupe_key = ?", [.text(dedupeKey)]) {
            try decode(AttentionItem.self, from: $0, column: 0)
        }
    }

    /// Marks an item read/unread (user action; does not change `updatedAt`, which tracks activity).
    public func setAttentionUnread(id: String, _ isUnread: Bool) throws {
        try updateAttentionItem(id: id) { $0.isUnread = isUnread }
    }

    /// Sets the user's disposition (acknowledge, snooze, dismiss, reopen).
    public func setAttentionDisposition(id: String, _ disposition: AttentionDisposition) throws {
        try updateAttentionItem(id: id) { $0.disposition = disposition }
    }

    /// Links the item to a task (nil unlinks). The task must exist (`StoreError.notFound`).
    public func linkAttention(id: String, taskID: TaskID?) throws {
        try connection.transaction {
            if let taskID {
                try requireTask(taskID)
            }
            try updateAttentionItem(id: id) { $0.linkedTaskID = taskID }
        }
    }

    // MARK: Internals

    private func updateAttentionItem(id: String, _ change: (inout AttentionItem) -> Void) throws {
        try connection.transaction {
            guard var item = try attentionItem(id: id) else { throw StoreError.notFound }
            change(&item)
            try writeAttentionItem(item)
        }
    }

    /// Inserts or replaces the row for `item.dedupeKey` (callers merge first).
    func writeAttentionItem(_ item: AttentionItem) throws {
        let snoozedUntil: SQLiteValue
        if case .snoozed(let until) = item.disposition {
            snoozedUntil = .date(until)
        } else {
            snoozedUntil = .null
        }
        try connection.run(
            """
            INSERT INTO attention_items
                (id, dedupe_key, account_id, cr_id, reason, priority, disposition, snoozed_until, is_unread,
                 linked_task_id, created_at, updated_at, data)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(dedupe_key) DO UPDATE SET
                id = excluded.id, account_id = excluded.account_id, cr_id = excluded.cr_id, reason = excluded.reason,
                priority = excluded.priority, disposition = excluded.disposition,
                snoozed_until = excluded.snoozed_until, is_unread = excluded.is_unread,
                linked_task_id = excluded.linked_task_id, created_at = excluded.created_at,
                updated_at = excluded.updated_at, data = excluded.data
            """,
            [
                .text(item.id), .text(item.dedupeKey), .text(item.account.id), .text(item.changeRequest.id),
                .text(item.reason.rawValue), .int(item.priority.rawValue), .text(item.disposition.name), snoozedUntil,
                .bool(item.isUnread), .optionalText(item.linkedTaskID?.rawValue), .date(item.createdAt),
                .date(item.updatedAt), try json(item),
            ]
        )
    }
}
