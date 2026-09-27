import Foundation
import MergeCueCore

extension MergeCueDatabase {
    // MARK: Rules

    public func upsertRule(_ rule: Rule) throws {
        let data = try json(rule)
        try connection.run(
            """
            INSERT INTO rules (id, name, is_active, origin, created_at, updated_at, data) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, is_active = excluded.is_active, origin = excluded.origin,
                created_at = excluded.created_at, updated_at = excluded.updated_at, data = excluded.data
            """,
            [
                .text(rule.id), .text(rule.name), .bool(rule.isActive), .text(rule.origin.rawValue),
                .date(rule.createdAt), .date(rule.updatedAt), data,
            ]
        )
    }

    /// Every rule, oldest first.
    public func rules() throws -> [Rule] {
        try connection.query("SELECT data FROM rules ORDER BY created_at, id") {
            try decode(Rule.self, from: $0, column: 0)
        }
    }

    public func rule(id: String) throws -> Rule? {
        try connection.queryFirst("SELECT data FROM rules WHERE id = ?", [.text(id)]) {
            try decode(Rule.self, from: $0, column: 0)
        }
    }

    /// Deletes a rule and its firing records. Returns false if it did not exist.
    @discardableResult
    public func deleteRule(id: String) throws -> Bool {
        try connection.transaction {
            try connection.run("DELETE FROM rules WHERE id = ?", [.text(id)]) > 0
        }
    }

    // MARK: Rule firings

    /// Records that `ruleID` fired for `eventID`. Returns false — and records nothing — if that (rule, event) pair
    /// already fired (idempotency across retries and relaunches). The rule must exist (`StoreError.notFound`).
    @discardableResult
    public func recordRuleFiring(ruleID: String, eventID: String, at date: Date) throws -> Bool {
        try connection.transaction {
            guard try exists("rules", id: ruleID) else { throw StoreError.notFound }
            return try connection.run(
                """
                INSERT INTO rule_firings (rule_id, event_id, fired_at) VALUES (?, ?, ?)
                ON CONFLICT(rule_id, event_id) DO NOTHING
                """,
                [.text(ruleID), .text(eventID), .date(date)]
            ) == 1
        }
    }

    /// Number of firings of `ruleID` at or after `since` (for `maxFiresPerHour`).
    public func ruleFiringCount(ruleID: String, since: Date) throws -> Int {
        try connection.queryFirst(
            "SELECT COUNT(*) FROM rule_firings WHERE rule_id = ? AND fired_at >= ?", [.text(ruleID), .date(since)]
        ) { $0.int(0) } ?? 0
    }

    /// Whether `ruleID` already fired for `eventID`.
    public func hasRuleFired(ruleID: String, eventID: String) throws -> Bool {
        try connection.queryFirst(
            "SELECT 1 FROM rule_firings WHERE rule_id = ? AND event_id = ?", [.text(ruleID), .text(eventID)]
        ) { _ in true } ?? false
    }
}
