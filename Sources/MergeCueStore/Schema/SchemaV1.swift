import Foundation

/// Schema v1.
///
/// Conventions: every table is `STRICT`; complex values live in a `data` JSON column (encoded with
/// `MergeCueCoding.storageEncoder()`), next to the indexed columns queries filter/sort on; dates are `REAL` seconds
/// since the reference date (exact, same as the JSON). Account-owned rows cascade from `accounts`; task-owned rows
/// cascade from `tasks`. `audit_log` has no foreign keys, so it survives account deletion. Append-only tables are
/// guarded by triggers: no UPDATE ever, DELETE only while `store_maintenance.retention_active = 1` (set by
/// `pruneHistory` inside its transaction) — or, for task activities, when their task is gone (cascade).
/// No table has a column for credentials: tokens live in the Keychain only.
enum SchemaV1 {
    static let migration = Migration(version: 1, name: "initial_schema", sql: sql)

    static let sql = """
        CREATE TABLE store_maintenance (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            retention_active INTEGER NOT NULL DEFAULT 0 CHECK (retention_active IN (0, 1))
        ) STRICT;
        INSERT INTO store_maintenance (id, retention_active) VALUES (1, 0);

        CREATE TABLE accounts (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            host TEXT NOT NULL,
            remote_user_id TEXT NOT NULL,
            username TEXT NOT NULL,
            is_demo INTEGER NOT NULL CHECK (is_demo IN (0, 1)),
            connected_at REAL NOT NULL,
            data TEXT NOT NULL
        ) STRICT;

        CREATE TABLE repositories (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            full_path TEXT NOT NULL,
            data TEXT NOT NULL
        ) STRICT;
        CREATE INDEX repositories_by_account ON repositories(account_id, full_path);

        CREATE TABLE change_requests (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            repo_id TEXT NOT NULL,
            repo_full_path TEXT NOT NULL,
            number INTEGER NOT NULL,
            state TEXT NOT NULL,
            is_draft INTEGER NOT NULL CHECK (is_draft IN (0, 1)),
            head_sha TEXT,
            updated_at REAL NOT NULL,
            fetched_at REAL NOT NULL,
            data TEXT NOT NULL
        ) STRICT;
        CREATE INDEX change_requests_by_account ON change_requests(account_id, updated_at);
        CREATE INDEX change_requests_by_repo ON change_requests(repo_id, number);
        CREATE INDEX change_requests_by_state ON change_requests(state, updated_at);
        CREATE INDEX change_requests_by_updated ON change_requests(updated_at);

        CREATE TABLE sync_state (
            account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            cursor TEXT NOT NULL,
            initial_sync_done INTEGER NOT NULL DEFAULT 0 CHECK (initial_sync_done IN (0, 1)),
            last_sync_at REAL
        ) STRICT;

        CREATE TABLE events (
            seq INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            cr_id TEXT NOT NULL,
            type TEXT NOT NULL,
            occurred_at REAL NOT NULL,
            detected_at REAL NOT NULL,
            is_baseline INTEGER NOT NULL CHECK (is_baseline IN (0, 1)),
            data TEXT NOT NULL
        ) STRICT;
        CREATE INDEX events_by_account ON events(account_id, detected_at);
        CREATE INDEX events_by_cr ON events(cr_id, occurred_at);
        CREATE INDEX events_by_detected ON events(detected_at);

        CREATE TABLE attention_items (
            id TEXT PRIMARY KEY NOT NULL,
            dedupe_key TEXT NOT NULL UNIQUE,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            cr_id TEXT NOT NULL,
            reason TEXT NOT NULL,
            priority INTEGER NOT NULL,
            disposition TEXT NOT NULL,
            snoozed_until REAL,
            is_unread INTEGER NOT NULL CHECK (is_unread IN (0, 1)),
            linked_task_id TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            data TEXT NOT NULL
        ) STRICT;
        CREATE INDEX attention_by_account ON attention_items(account_id);
        CREATE INDEX attention_by_cr ON attention_items(cr_id);
        CREATE INDEX attention_by_disposition ON attention_items(disposition, priority, updated_at);
        CREATE INDEX attention_by_task ON attention_items(linked_task_id) WHERE linked_task_id IS NOT NULL;

        CREATE TABLE tasks (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            cr_id TEXT NOT NULL,
            type TEXT NOT NULL,
            state TEXT NOT NULL,
            is_terminal INTEGER NOT NULL CHECK (is_terminal IN (0, 1)),
            version INTEGER NOT NULL CHECK (version >= 1),
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            data TEXT NOT NULL
        ) STRICT;
        CREATE INDEX tasks_by_state ON tasks(state, updated_at);
        CREATE INDEX tasks_by_account ON tasks(account_id);
        CREATE INDEX tasks_by_cr ON tasks(cr_id, is_terminal);

        CREATE TABLE task_activities (
            seq INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            at REAL NOT NULL,
            kind TEXT NOT NULL,
            data TEXT NOT NULL
        ) STRICT;
        CREATE INDEX task_activities_by_task ON task_activities(task_id, at);
        CREATE TRIGGER task_activities_no_update BEFORE UPDATE ON task_activities
        BEGIN
            SELECT RAISE(ABORT, 'task_activities is append-only');
        END;
        CREATE TRIGGER task_activities_no_delete BEFORE DELETE ON task_activities
        WHEN (SELECT retention_active FROM store_maintenance WHERE id = 1) IS NOT 1
            AND EXISTS (SELECT 1 FROM tasks WHERE id = OLD.task_id)
        BEGIN
            SELECT RAISE(ABORT, 'task_activities is append-only');
        END;

        CREATE TABLE artifacts (
            id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            created_at REAL NOT NULL,
            data TEXT NOT NULL
        ) STRICT;
        CREATE INDEX artifacts_by_task ON artifacts(task_id, created_at);

        CREATE TABLE approvals (
            id TEXT PRIMARY KEY NOT NULL,
            task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            action TEXT NOT NULL,
            decision TEXT NOT NULL,
            decided_at REAL NOT NULL,
            preview_fingerprint TEXT NOT NULL,
            data TEXT NOT NULL
        ) STRICT;
        CREATE INDEX approvals_by_task ON approvals(task_id, decided_at);
        CREATE INDEX approvals_by_fingerprint ON approvals(preview_fingerprint);

        CREATE TABLE audit_log (
            seq INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            at REAL NOT NULL,
            actor TEXT NOT NULL,
            action TEXT NOT NULL,
            target TEXT NOT NULL,
            outcome TEXT NOT NULL,
            task_id TEXT,
            data TEXT NOT NULL
        ) STRICT;
        CREATE INDEX audit_log_by_at ON audit_log(at);
        CREATE INDEX audit_log_by_task ON audit_log(task_id, at) WHERE task_id IS NOT NULL;
        CREATE TRIGGER audit_log_no_update BEFORE UPDATE ON audit_log
        BEGIN
            SELECT RAISE(ABORT, 'audit_log is append-only');
        END;
        CREATE TRIGGER audit_log_no_delete BEFORE DELETE ON audit_log
        WHEN (SELECT retention_active FROM store_maintenance WHERE id = 1) IS NOT 1
        BEGIN
            SELECT RAISE(ABORT, 'audit_log is append-only');
        END;

        CREATE TABLE rules (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
            origin TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            data TEXT NOT NULL
        ) STRICT;

        CREATE TABLE rule_firings (
            rule_id TEXT NOT NULL REFERENCES rules(id) ON DELETE CASCADE,
            event_id TEXT NOT NULL,
            fired_at REAL NOT NULL,
            UNIQUE (rule_id, event_id)
        ) STRICT;
        CREATE INDEX rule_firings_by_rule_time ON rule_firings(rule_id, fired_at);
        CREATE INDEX rule_firings_by_event ON rule_firings(event_id);

        CREATE TABLE repo_mappings (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            repo_id TEXT NOT NULL,
            checkout_path TEXT NOT NULL,
            created_at REAL NOT NULL,
            data TEXT NOT NULL
        ) STRICT;
        CREATE INDEX repo_mappings_by_repo ON repo_mappings(repo_id, created_at);
        CREATE INDEX repo_mappings_by_account ON repo_mappings(account_id);

        CREATE TABLE settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        ) STRICT;
        """

    /// Every table created by v1 (plus the migrator's `schema_migrations`).
    static let tables = [
        "accounts", "repositories", "change_requests", "sync_state", "events", "attention_items", "tasks",
        "task_activities", "artifacts", "approvals", "audit_log", "rules", "rule_firings", "repo_mappings", "settings",
        "store_maintenance",
    ]
}
