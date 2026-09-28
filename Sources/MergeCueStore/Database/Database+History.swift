import Foundation
import MergeCueCore

extension MergeCueDatabase {
    // MARK: Audit (append-only)

    /// Appends an audit entry (`target` and `detail` are redacted). Entries are never updated and are only removed
    /// by `pruneHistory(olderThan:)`; they survive account deletion.
    public func appendAudit(_ entry: AuditEntry) throws {
        var entry = entry
        entry.target = SecretRedactor.redact(entry.target)
        entry.detail = SecretRedactor.redact(entry.detail)
        let data = try json(entry)
        try connection.run(
            """
            INSERT INTO audit_log (id, at, actor, action, target, outcome, task_id, data)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(entry.id), .date(entry.at), .text(entry.actor), .text(entry.action), .text(entry.target),
                .text(entry.outcome.rawValue), .optionalText(entry.taskID?.rawValue), data,
            ]
        )
    }

    /// The newest `limit` audit entries (optionally of one task), newest first.
    public func auditEntries(limit: Int, taskID: TaskID? = nil) throws -> [AuditEntry] {
        if let taskID {
            return try connection.query(
                "SELECT data FROM audit_log WHERE task_id = ? ORDER BY at DESC, seq DESC LIMIT ?",
                [.text(taskID.rawValue), .int(max(0, limit))]
            ) { try decode(AuditEntry.self, from: $0, column: 0) }
        }
        return try connection.query(
            "SELECT data FROM audit_log ORDER BY at DESC, seq DESC LIMIT ?", [.int(max(0, limit))]
        ) { try decode(AuditEntry.self, from: $0, column: 0) }
    }

    // MARK: Retention

    /// Removes history older than `cutoff` and returns the number of rows deleted:
    /// - events detected before `cutoff`, except those of change requests that still have a non-terminal task;
    /// - activities (before `cutoff`) of terminal tasks (`done`, `cancelled`, `dismissed`);
    /// - audit entries before `cutoff`, except those of non-terminal tasks;
    /// - rule firings before `cutoff` whose event no longer exists;
    /// - resolved/dismissed attention items last updated before `cutoff` whose change request is no longer tracked
    ///   (no stored snapshot) and that are not linked to a task.
    ///
    /// Tasks themselves, their artifacts/approvals, snapshots and attention items of tracked change requests are
    /// kept, and nothing belonging to a non-terminal task is ever removed. Deleted content is zeroed on disk (`secure_delete`).
    @discardableResult
    public func pruneHistory(olderThan cutoff: Date) throws -> Int {
        let before = SQLiteValue.date(cutoff)
        return try connection.transaction {
            // Opens the append-only guards of task_activities / audit_log for this transaction only.
            try connection.run("UPDATE store_maintenance SET retention_active = 1 WHERE id = 1")
            var removed = 0
            removed += try connection.run(
                """
                DELETE FROM events WHERE detected_at < ?
                    AND cr_id NOT IN (SELECT cr_id FROM tasks WHERE is_terminal = 0)
                """,
                [before]
            )
            removed += try connection.run(
                """
                DELETE FROM task_activities WHERE at < ?
                    AND task_id IN (SELECT id FROM tasks WHERE is_terminal = 1)
                """,
                [before]
            )
            removed += try connection.run(
                """
                DELETE FROM audit_log WHERE at < ?
                    AND (task_id IS NULL OR task_id NOT IN (SELECT id FROM tasks WHERE is_terminal = 0))
                """,
                [before]
            )
            removed += try connection.run(
                """
                DELETE FROM rule_firings WHERE fired_at < ?
                    AND NOT EXISTS (SELECT 1 FROM events WHERE events.id = rule_firings.event_id)
                """,
                [before]
            )
            removed += try connection.run(
                """
                DELETE FROM attention_items WHERE updated_at < ?
                    AND disposition IN ('resolved', 'dismissed')
                    AND linked_task_id IS NULL
                    AND cr_id NOT IN (SELECT id FROM change_requests)
                """,
                [before]
            )
            try connection.run("UPDATE store_maintenance SET retention_active = 0 WHERE id = 1")
            return removed
        }
    }

    /// Housekeeping after retention: truncates the write-ahead log (it otherwise keeps its high-water size) and lets
    /// SQLite refresh its query planner statistics (`PRAGMA optimize`). Safe while the app runs.
    public func checkpointAndOptimize() throws {
        try connection.execute("PRAGMA optimize")
        _ = try connection.query("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
    }

    /// Size in bytes of the database file plus its WAL (0 in memory).
    public func fileSizes() -> Int {
        guard let path else { return 0 }
        return [path, path + "-wal"].reduce(0) { total, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.intValue ?? 0
            return total + size
        }
    }
}
