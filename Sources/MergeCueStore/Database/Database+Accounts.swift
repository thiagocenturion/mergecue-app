import Foundation
import MergeCueCore

extension MergeCueDatabase {
    // MARK: Accounts

    /// Inserts or replaces an account (it holds no secrets; credentials live in the Keychain).
    public func upsertAccount(_ account: Account) throws {
        let data = try json(account)
        try connection.run(
            """
            INSERT INTO accounts (id, kind, host, remote_user_id, username, is_demo, connected_at, data)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind, host = excluded.host, remote_user_id = excluded.remote_user_id,
                username = excluded.username, is_demo = excluded.is_demo, connected_at = excluded.connected_at,
                data = excluded.data
            """,
            [
                .text(account.id.id), .text(account.id.kind.rawValue), .text(account.id.host),
                .text(account.id.remoteUserID), .text(account.username), .bool(account.isDemo),
                .date(account.connectedAt), data,
            ]
        )
    }

    /// Every account, oldest connection first.
    public func accounts() throws -> [Account] {
        try connection.query("SELECT data FROM accounts ORDER BY connected_at, id") {
            try decode(Account.self, from: $0, column: 0)
        }
    }

    public func account(_ key: AccountKey) throws -> Account? {
        try connection.queryFirst("SELECT data FROM accounts WHERE id = ?", [.text(key.id)]) {
            try decode(Account.self, from: $0, column: 0)
        }
    }

    /// Deletes the account and, by cascade, everything it owns: repositories, snapshots, sync state, events,
    /// attention items, tasks (with their activities, artifacts and approvals) and repo mappings. The audit log
    /// is kept. Returns false if the account did not exist.
    @discardableResult
    public func deleteAccount(_ key: AccountKey) throws -> Bool {
        try connection.transaction {
            try connection.run("DELETE FROM accounts WHERE id = ?", [.text(key.id)]) > 0
        }
    }

    // MARK: Repositories

    /// Inserts or replaces repositories. Each repository's account must exist (`StoreError.notFound`).
    public func upsertRepositories(_ repositories: [Repository]) throws {
        guard !repositories.isEmpty else { return }
        let rows = try repositories.map { repository in
            (repository, try json(repository))
        }
        try connection.transaction {
            var knownAccounts: Set<String> = []
            let statement = try connection.prepare(
                """
                INSERT INTO repositories (id, account_id, full_path, data) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    account_id = excluded.account_id, full_path = excluded.full_path, data = excluded.data
                """
            )
            for (repository, data) in rows {
                let account = repository.key.account
                if !knownAccounts.contains(account.id) {
                    try requireAccount(account)
                    knownAccounts.insert(account.id)
                }
                try statement.run([.text(repository.id), .text(account.id), .text(repository.fullPath), data])
            }
        }
    }

    /// The account's repositories, sorted by full path.
    public func repositories(account: AccountKey) throws -> [Repository] {
        try connection.query(
            "SELECT data FROM repositories WHERE account_id = ? ORDER BY full_path, id", [.text(account.id)]
        ) {
            try decode(Repository.self, from: $0, column: 0)
        }
    }
}
