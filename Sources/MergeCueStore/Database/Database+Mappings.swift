import Foundation
import MergeCueCore

extension MergeCueDatabase {
    // MARK: Repo mappings

    /// Inserts or replaces a mapping (its remote URL is already sanitized by `RepoMapping`). The repository's
    /// account must exist (`StoreError.notFound`).
    public func upsertMapping(_ mapping: RepoMapping) throws {
        let data = try json(mapping)
        try connection.transaction {
            try requireAccount(mapping.repo.account)
            try connection.run(
                """
                INSERT INTO repo_mappings (id, account_id, repo_id, checkout_path, created_at, data)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    account_id = excluded.account_id, repo_id = excluded.repo_id,
                    checkout_path = excluded.checkout_path, created_at = excluded.created_at, data = excluded.data
                """,
                [
                    .text(mapping.id), .text(mapping.repo.account.id), .text(mapping.repo.id),
                    .text(mapping.checkoutPath), .date(mapping.createdAt), data,
                ]
            )
        }
    }

    /// Mappings of one repository (all mappings when nil), oldest first.
    public func mappings(repo: RepoKey?) throws -> [RepoMapping] {
        if let repo {
            return try connection.query(
                "SELECT data FROM repo_mappings WHERE repo_id = ? ORDER BY created_at, id", [.text(repo.id)]
            ) { try decode(RepoMapping.self, from: $0, column: 0) }
        }
        return try connection.query("SELECT data FROM repo_mappings ORDER BY created_at, id") {
            try decode(RepoMapping.self, from: $0, column: 0)
        }
    }

    public func mapping(id: String) throws -> RepoMapping? {
        try connection.queryFirst("SELECT data FROM repo_mappings WHERE id = ?", [.text(id)]) {
            try decode(RepoMapping.self, from: $0, column: 0)
        }
    }

    /// Returns false if the mapping did not exist.
    @discardableResult
    public func deleteMapping(id: String) throws -> Bool {
        try connection.run("DELETE FROM repo_mappings WHERE id = ?", [.text(id)]) > 0
    }
}
