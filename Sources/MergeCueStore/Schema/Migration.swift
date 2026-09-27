import Foundation

/// One forward-only schema migration.
///
/// To add schema v2: write `SchemaV2.swift` with a `static let migration = Migration(version: 2, …)` and append it to
/// `Schema.migrations`. The migrator runs it exactly once, inside its own `BEGIN IMMEDIATE` transaction, and records it
/// in `schema_migrations`; if `apply` throws, the transaction (including the version row) rolls back and the database
/// stays at v1. Never edit a migration that has shipped — add a new one.
///
/// Migrations that rebuild a table (the SQLite "create new, copy, drop old, rename" procedure) must set
/// `disablesForeignKeys`: foreign keys are switched off *outside* the transaction (the pragma is a no-op inside one),
/// `PRAGMA foreign_key_check` must come back empty before COMMIT, and enforcement is switched back on afterwards.
struct Migration: Sendable {
    let version: Int
    let name: String
    let disablesForeignKeys: Bool
    let apply: @Sendable (SQLiteConnection) throws -> Void

    init(version: Int, name: String, disablesForeignKeys: Bool = false, apply: @escaping @Sendable (SQLiteConnection) throws -> Void) {
        self.version = version
        self.name = name
        self.disablesForeignKeys = disablesForeignKeys
        self.apply = apply
    }

    /// A migration that runs a fixed SQL script.
    init(version: Int, name: String, disablesForeignKeys: Bool = false, sql: String) {
        self.init(version: version, name: name, disablesForeignKeys: disablesForeignKeys) { connection in
            try connection.execute(sql)
        }
    }
}

/// The schema history shipped with this build.
enum Schema {
    /// Every migration, in order. Append only.
    static let migrations: [Migration] = [SchemaV1.migration]

    /// The newest schema version this build understands.
    static var latestVersion: Int { migrations.last?.version ?? 0 }
}

/// Applies pending migrations.
enum Migrator {
    static let bookkeepingSQL = """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            applied_at REAL NOT NULL
        ) STRICT;
        """

    /// Brings the database up to the last migration in `migrations`. Idempotent. Throws
    /// `StoreError.schemaTooNew` for a database written by a newer build (it is never downgraded or modified).
    /// Returns the versions applied by this call.
    @discardableResult
    static func migrate(_ connection: SQLiteConnection, migrations: [Migration], now: Date = Date()) throws -> [Int] {
        try validate(migrations)
        let supported = migrations.last?.version ?? 0
        try connection.transaction(.immediate) {
            try connection.execute(bookkeepingSQL)
        }
        let current = try currentVersion(connection)
        guard current <= supported else {
            throw StoreError.schemaTooNew(found: current, supported: supported)
        }
        var applied: [Int] = []
        for migration in migrations where migration.version > current {
            if try apply(migration, to: connection, now: now) {
                applied.append(migration.version)
            }
        }
        return applied
    }

    /// Highest applied version (0 for a new database).
    static func currentVersion(_ connection: SQLiteConnection) throws -> Int {
        try connection.queryFirst("SELECT COALESCE(MAX(version), 0) FROM schema_migrations") { $0.int(0) } ?? 0
    }

    /// Runs one migration in its own transaction. Returns false when another connection applied it first.
    private static func apply(_ migration: Migration, to connection: SQLiteConnection, now: Date) throws -> Bool {
        if migration.disablesForeignKeys {
            try connection.execute("PRAGMA foreign_keys = OFF")
        }
        defer {
            if migration.disablesForeignKeys {
                try? connection.execute("PRAGMA foreign_keys = ON")
            }
        }
        return try connection.transaction(.immediate) {
            // Re-check under the write lock: a concurrent process may have migrated in the meantime.
            let alreadyApplied = try connection.queryFirst(
                "SELECT 1 FROM schema_migrations WHERE version = ?", [.int(migration.version)]
            ) { _ in true } ?? false
            guard !alreadyApplied else { return false }
            try migration.apply(connection)
            if migration.disablesForeignKeys {
                let violations = try connection.query("PRAGMA foreign_key_check") { $0.text(0) }
                guard violations.isEmpty else {
                    throw StoreError.sqlite(
                        code: SQLiteResultCode.constraintForeignKey,
                        message: "migration \(migration.version) left foreign key violations in \(Set(violations).sorted())"
                    )
                }
            }
            try connection.run(
                "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)",
                [.int(migration.version), .text(migration.name), .date(now)]
            )
            return true
        }
    }

    private static func validate(_ migrations: [Migration]) throws {
        for (index, migration) in migrations.enumerated() where migration.version != index + 1 {
            throw StoreError.invalidValue(
                "migrations must be numbered 1…n without gaps (found v\(migration.version) at position \(index + 1))"
            )
        }
    }
}
