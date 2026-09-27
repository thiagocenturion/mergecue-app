import Foundation
import MergeCueCore
import Testing
@testable import MergeCueStore

@Suite("Migrations")
struct MigrationTests {
    @Test func freshDatabaseIsMigratedToTheLatestSchema() async throws {
        let database = try MergeCueDatabase.inMemory()
        #expect(try await database.schemaVersion() == MergeCueDatabase.latestSchemaVersion)
        #expect(MergeCueDatabase.latestSchemaVersion == 1)

        let tables = Set(try await database.queryTextForTesting("SELECT name FROM sqlite_master WHERE type = 'table'"))
        for table in SchemaV1.tables + ["schema_migrations"] {
            #expect(tables.contains(table), "missing table \(table)")
        }
        let versions = try await database.queryTextForTesting("SELECT version || ':' || name FROM schema_migrations")
        #expect(versions == ["1:initial_schema"])
    }

    @Test func schemaHasTheRequiredIndexesAndUniqueKeys() async throws {
        let database = try MergeCueDatabase.inMemory()
        let indexes = Set(try await database.queryTextForTesting("SELECT name FROM sqlite_master WHERE type = 'index'"))
        for index in [
            "change_requests_by_account", "change_requests_by_repo", "change_requests_by_state", "change_requests_by_updated",
            "events_by_account", "events_by_cr", "attention_by_disposition", "tasks_by_state", "rule_firings_by_rule_time",
        ] {
            #expect(indexes.contains(index), "missing index \(index)")
        }
        // UNIQUE event id, UNIQUE dedupe key, UNIQUE (rule_id, event_id) are backed by automatic indexes.
        let unique = try await database.queryTextForTesting(
            "SELECT tbl_name FROM sqlite_master WHERE type = 'index' AND name LIKE 'sqlite_autoindex_%' ORDER BY tbl_name"
        )
        #expect(unique.contains("events"))
        #expect(unique.contains("attention_items"))
        #expect(unique.contains("rule_firings"))
    }

    @Test func migrateIsIdempotent() async throws {
        let path = try StoreFixture.temporaryDatabasePath("migrate")
        do {
            let database = try MergeCueDatabase(path: path)
            try await database.upsertAccount(StoreFixture.account())
            try await database.migrate()
            try await database.migrate()
            #expect(try await database.queryTextForTesting("SELECT COUNT(*) FROM schema_migrations") == ["1"])
        }
        // Reopening applies nothing and keeps the data.
        let reopened = try MergeCueDatabase(path: path)
        try await reopened.migrate()
        #expect(try await reopened.queryTextForTesting("SELECT COUNT(*) FROM schema_migrations") == ["1"])
        #expect(try await reopened.accounts().map(\.id) == [StoreFixture.githubAccount])
    }

    @Test func connectionIsConfiguredForWALForeignKeysAndBusyTimeout() async throws {
        let path = try StoreFixture.temporaryDatabasePath("pragmas")
        let database = try MergeCueDatabase(path: path)
        #expect(try await database.queryTextForTesting("PRAGMA journal_mode") == ["wal"])
        #expect(try await database.queryTextForTesting("PRAGMA foreign_keys") == ["1"])
        #expect(try await database.queryTextForTesting("PRAGMA busy_timeout") == ["\(SQLiteConnection.busyTimeoutMilliseconds)"])
        #expect(try await database.queryTextForTesting("PRAGMA secure_delete") == ["1"])
    }

    @Test func simulatedV2MigrationUpgradesAV1DatabaseAndKeepsData() async throws {
        let path = try StoreFixture.temporaryDatabasePath("v2")
        do {
            let v1 = try MergeCueDatabase(path: path)
            try await v1.upsertAccount(StoreFixture.account())
            try await v1.insertTask(StoreFixture.task())
            #expect(try await v1.schemaVersion() == 1)
        }

        // v2 rebuilds `tasks` (the SQLite table-rebuild procedure) to add a column, with foreign keys suspended.
        let v2 = Migration(version: 2, name: "tasks_priority", disablesForeignKeys: true) { connection in
            try connection.execute(
                """
                CREATE TABLE tasks_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    cr_id TEXT NOT NULL,
                    type TEXT NOT NULL,
                    state TEXT NOT NULL,
                    is_terminal INTEGER NOT NULL,
                    version INTEGER NOT NULL CHECK (version >= 1),
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    priority INTEGER NOT NULL DEFAULT 0,
                    data TEXT NOT NULL
                ) STRICT;
                INSERT INTO tasks_new (id, account_id, cr_id, type, state, is_terminal, version, created_at, updated_at, data)
                    SELECT id, account_id, cr_id, type, state, is_terminal, version, created_at, updated_at, data FROM tasks;
                DROP TABLE tasks;
                ALTER TABLE tasks_new RENAME TO tasks;
                CREATE INDEX tasks_by_state ON tasks(state, updated_at);
                CREATE INDEX tasks_by_account ON tasks(account_id);
                CREATE INDEX tasks_by_cr ON tasks(cr_id, is_terminal);
                """
            )
        }
        let upgraded = try MergeCueDatabase(location: .file(path), migrations: Schema.migrations + [v2])
        #expect(try await upgraded.schemaVersion() == 2)
        #expect(try await upgraded.queryTextForTesting("SELECT version FROM schema_migrations ORDER BY version") == ["1", "2"])
        #expect(try await upgraded.queryTextForTesting("SELECT priority FROM tasks") == ["0"])
        #expect(try await upgraded.task(StoreFixture.task().id) == StoreFixture.task())
        #expect(try await upgraded.queryTextForTesting("PRAGMA foreign_keys") == ["1"])
        #expect(try await upgraded.integrityCheck())

        // The activities foreign key still points at the rebuilt table.
        try await upgraded.appendActivity(StoreFixture.activity())
        #expect(try await upgraded.activities(task: StoreFixture.task().id).count == 1)

        // Running again (and reopening) applies nothing.
        try await upgraded.migrate()
        let reopened = try MergeCueDatabase(location: .file(path), migrations: Schema.migrations + [v2])
        #expect(try await reopened.queryTextForTesting("SELECT COUNT(*) FROM schema_migrations") == ["2"])
    }

    @Test func failingMigrationRollsBackCompletely() async throws {
        let path = try StoreFixture.temporaryDatabasePath("rollback")
        do {
            let v1 = try MergeCueDatabase(path: path)
            try await v1.upsertAccount(StoreFixture.account())
        }
        struct Boom: Error {}
        let broken = Migration(version: 2, name: "broken") { connection in
            try connection.execute("CREATE TABLE half_done (id INTEGER PRIMARY KEY); DELETE FROM accounts;")
            throw Boom()
        }
        #expect(throws: Boom.self) {
            _ = try MergeCueDatabase(location: .file(path), migrations: Schema.migrations + [broken])
        }
        let database = try MergeCueDatabase(path: path)
        #expect(try await database.schemaVersion() == 1)
        #expect(try await database.queryTextForTesting("SELECT COUNT(*) FROM sqlite_master WHERE name = 'half_done'") == ["0"])
        #expect(try await database.accounts().count == 1)
    }

    @Test func databaseFromANewerBuildIsRefused() async throws {
        let path = try StoreFixture.temporaryDatabasePath("newer")
        do {
            let database = try MergeCueDatabase(path: path)
            try await database.executeForTesting(
                "INSERT INTO schema_migrations (version, name, applied_at) VALUES (7, 'from_the_future', 0)"
            )
        }
        #expect(throws: StoreError.schemaTooNew(found: 7, supported: 1)) {
            _ = try MergeCueDatabase(path: path)
        }
    }

    @Test func migrationListsMustBeContiguous() throws {
        let gap = [SchemaV1.migration, Migration(version: 3, name: "gap", sql: "SELECT 1")]
        #expect(throws: StoreError.self) {
            _ = try MergeCueDatabase(location: .memory, migrations: gap)
        }
    }
}
