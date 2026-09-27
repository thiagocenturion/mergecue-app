import Foundation
import MergeCueCore

extension MergeCueDatabase {
    // MARK: Sync batches

    /// Persists one sync cycle atomically, in ONE transaction: upserts `snapshots`, deletes
    /// `removedChangeRequests`, inserts `events` exactly once, merges `attentionUpserts` (see
    /// `AttentionMergePolicy`), stores `cursor` and marks the account's initial sync done (`syncedAt`). If anything
    /// fails, nothing is written.
    ///
    /// Events are inserted with `INSERT … ON CONFLICT(id) DO NOTHING` — the targeted form of `INSERT OR IGNORE`: a
    /// duplicate event id (already stored, or repeated in the batch) is skipped, while any other constraint
    /// violation still fails the batch.
    ///
    /// - Returns: only the events inserted by this call (in batch order) — the ones to notify/evaluate rules for.
    /// - Throws: `StoreError.invalidValue` when a row belongs to another account, `StoreError.notFound` when the
    ///   account does not exist (e.g. it was disconnected mid-cycle).
    @discardableResult
    public func applySyncBatch(_ batch: SyncBatch) throws -> [ChangeEvent] {
        try validate(batch)
        let accountID = batch.account.id
        // Encode everything before touching the database.
        let snapshotRows = try batch.snapshots.map { snapshot in
            let summary = snapshot.summary
            return [
                .text(summary.key.id), .text(accountID), .text(summary.key.repo.id), .text(summary.repository.fullPath),
                .int(summary.key.number), .text(summary.state.rawValue), .bool(summary.isDraft),
                .optionalText(summary.headSHA), .date(summary.updatedAt), .date(snapshot.fetchedAt), try json(snapshot),
            ] as [SQLiteValue]
        }
        let eventRows = try batch.events.map { event in
            (event, [
                .text(event.id), .text(accountID), .text(event.changeRequest.id), .text(event.type.rawValue),
                .date(event.occurredAt), .date(event.detectedAt), .bool(event.isBaseline), try json(event),
            ] as [SQLiteValue])
        }
        let cursor = try json(batch.cursor)

        return try connection.transaction {
            try requireAccount(batch.account)

            if !snapshotRows.isEmpty {
                let upsert = try connection.prepare(
                    """
                    INSERT INTO change_requests
                        (id, account_id, repo_id, repo_full_path, number, state, is_draft, head_sha, updated_at,
                         fetched_at, data)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        account_id = excluded.account_id, repo_id = excluded.repo_id,
                        repo_full_path = excluded.repo_full_path, number = excluded.number, state = excluded.state,
                        is_draft = excluded.is_draft, head_sha = excluded.head_sha, updated_at = excluded.updated_at,
                        fetched_at = excluded.fetched_at, data = excluded.data
                    """
                )
                for row in snapshotRows {
                    try upsert.run(row)
                }
            }

            if !batch.removedChangeRequests.isEmpty {
                let delete = try connection.prepare("DELETE FROM change_requests WHERE id = ? AND account_id = ?")
                for key in batch.removedChangeRequests {
                    try delete.run([.text(key.id), .text(accountID)])
                }
            }

            var inserted: [ChangeEvent] = []
            if !eventRows.isEmpty {
                let insert = try connection.prepare(
                    """
                    INSERT INTO events (id, account_id, cr_id, type, occurred_at, detected_at, is_baseline, data)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """
                )
                for (event, row) in eventRows {
                    if try insert.run(row) == 1 {
                        inserted.append(event)
                    }
                }
            }

            for item in batch.attentionUpserts {
                let existing = try attentionItem(dedupeKey: item.dedupeKey)
                try writeAttentionItem(AttentionMergePolicy.merge(existing: existing, incoming: item))
            }

            try connection.run(
                """
                INSERT INTO sync_state (account_id, cursor, initial_sync_done, last_sync_at) VALUES (?, ?, 1, ?)
                ON CONFLICT(account_id) DO UPDATE SET
                    cursor = excluded.cursor, initial_sync_done = 1, last_sync_at = excluded.last_sync_at
                """,
                [.text(accountID), cursor, .date(batch.syncedAt)]
            )
            return inserted
        }
    }

    private func validate(_ batch: SyncBatch) throws {
        let account = batch.account
        if let snapshot = batch.snapshots.first(where: { $0.key.account != account }) {
            throw StoreError.invalidValue("snapshot \(snapshot.key.shortID) belongs to another account")
        }
        if let key = batch.removedChangeRequests.first(where: { $0.account != account }) {
            throw StoreError.invalidValue("removed change request \(key.shortID) belongs to another account")
        }
        if let event = batch.events.first(where: { $0.account != account }) {
            throw StoreError.invalidValue("event \(event.id) belongs to another account")
        }
        if let item = batch.attentionUpserts.first(where: { $0.account != account }) {
            throw StoreError.invalidValue("attention item \(item.id) belongs to another account")
        }
    }

    // MARK: Snapshots

    public func snapshot(_ key: ChangeRequestKey) throws -> ChangeRequestSnapshot? {
        try connection.queryFirst("SELECT data FROM change_requests WHERE id = ?", [.text(key.id)]) {
            try decode(ChangeRequestSnapshot.self, from: $0, column: 0)
        }
    }

    /// Stored snapshots of one account (or all accounts when nil), most recently updated first.
    public func snapshots(account: AccountKey?) throws -> [ChangeRequestSnapshot] {
        if let account {
            return try connection.query(
                "SELECT data FROM change_requests WHERE account_id = ? ORDER BY updated_at DESC, id",
                [.text(account.id)]
            ) { try decode(ChangeRequestSnapshot.self, from: $0, column: 0) }
        }
        return try connection.query("SELECT data FROM change_requests ORDER BY updated_at DESC, id") {
            try decode(ChangeRequestSnapshot.self, from: $0, column: 0)
        }
    }

    // MARK: Sync state

    /// The cursor stored by the account's last batch (empty before the first one).
    public func cursor(account: AccountKey) throws -> [String: String] {
        try connection.queryFirst("SELECT cursor FROM sync_state WHERE account_id = ?", [.text(account.id)]) {
            try decode([String: String].self, from: $0, column: 0)
        } ?? [:]
    }

    /// Whether a batch was ever applied for the account (its baseline sync is done).
    public func hasCompletedInitialSync(account: AccountKey) throws -> Bool {
        try connection.queryFirst(
            "SELECT initial_sync_done FROM sync_state WHERE account_id = ?", [.text(account.id)]
        ) { $0.bool(0) } ?? false
    }

    /// `syncedAt` of the account's last applied batch.
    public func lastSyncAt(account: AccountKey) throws -> Date? {
        try connection.queryFirst("SELECT last_sync_at FROM sync_state WHERE account_id = ?", [.text(account.id)]) {
            $0.optionalDate(0)
        } ?? nil
    }

    // MARK: Events

    /// Events of one change request, oldest first.
    public func events(changeRequest: ChangeRequestKey) throws -> [ChangeEvent] {
        try connection.query(
            "SELECT data FROM events WHERE cr_id = ? ORDER BY occurred_at, seq", [.text(changeRequest.id)]
        ) { try decode(ChangeEvent.self, from: $0, column: 0) }
    }

    /// The most recently detected events across all accounts, newest first.
    public func recentEvents(limit: Int) throws -> [ChangeEvent] {
        try connection.query(
            "SELECT data FROM events ORDER BY detected_at DESC, seq DESC LIMIT ?", [.int(max(0, limit))]
        ) { try decode(ChangeEvent.self, from: $0, column: 0) }
    }

    public func event(id: String) throws -> ChangeEvent? {
        try connection.queryFirst("SELECT data FROM events WHERE id = ?", [.text(id)]) {
            try decode(ChangeEvent.self, from: $0, column: 0)
        }
    }
}
