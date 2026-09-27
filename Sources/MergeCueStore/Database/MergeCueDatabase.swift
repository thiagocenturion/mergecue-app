import Foundation
import MergeCueCore
import SQLite3

/// MergeCue's local store: one SQLite connection (WAL, `foreign_keys=ON`, busy timeout, file mode 0600) behind an
/// actor, so every call is serialized and every multi-statement operation runs in one transaction.
///
/// Complex values are stored as JSON (`MergeCueCoding.storageEncoder()`, lossless dates) next to indexed columns;
/// a value read back is `==` to the value written. **No credentials are ever stored** — there is no API that accepts
/// one, settings refuse secret-shaped values, and audit/activity/artifact text is redacted on the way in.
///
/// All methods throw `StoreError`. The initializer creates the file if needed and migrates it to the latest schema;
/// `migrate()` is idempotent.
public actor MergeCueDatabase {
    /// The newest schema version this build writes.
    public static var latestSchemaVersion: Int { Schema.latestVersion }

    /// The database file, or nil for an in-memory database.
    public nonisolated let path: String?

    var connection: SQLiteConnection
    private let location: SQLiteConnection.Location
    private let migrations: [Migration]
    let encoder = MergeCueCoding.storageEncoder()
    let decoder = MergeCueCoding.storageDecoder()

    /// Opens (creating with mode 0600 if needed) and migrates the database at `path`. A file that is not a
    /// database, or whose schema cannot be read, throws `StoreError.corrupted`; see `removeDatabaseFiles(atPath:)`.
    public init(path: String) throws {
        try self.init(location: .file(path), migrations: Schema.migrations)
    }

    /// Opens the database at a file URL (e.g. `MergeCuePaths.database`).
    public init(url: URL) throws {
        try self.init(path: MergeCuePaths.fileSystemPath(url))
    }

    /// A fresh, private in-memory database (tests, previews). Each call returns an independent database.
    public static func inMemory() throws -> MergeCueDatabase {
        try MergeCueDatabase(location: .memory, migrations: Schema.migrations)
    }

    /// Designated initializer; tests pass custom migration lists to simulate schema upgrades.
    init(location: SQLiteConnection.Location, migrations: [Migration]) throws {
        let connection = try SQLiteConnection(location: location)
        try Migrator.migrate(connection, migrations: migrations)
        self.connection = connection
        self.location = location
        self.migrations = migrations
        if case .file(let path) = location {
            self.path = path
        } else {
            self.path = nil
        }
    }

    // MARK: Lifecycle

    /// Applies pending migrations (idempotent; the initializer already migrated).
    public func migrate() throws {
        try Migrator.migrate(connection, migrations: migrations)
    }

    /// The schema version recorded in `schema_migrations`.
    public func schemaVersion() throws -> Int {
        try Migrator.currentVersion(connection)
    }

    /// `PRAGMA integrity_check` (and `foreign_key_check`). Returns false for a damaged database — including one so
    /// damaged that the check itself fails with `SQLITE_CORRUPT`/`SQLITE_NOTADB`.
    public func integrityCheck() throws -> Bool {
        do {
            let report = try connection.query("PRAGMA integrity_check") { $0.text(0) }
            guard report == ["ok"] else { return false }
            let violations = try connection.query("PRAGMA foreign_key_check") { $0.text(0) }
            return violations.isEmpty
        } catch StoreError.corrupted {
            return false
        }
    }

    /// Writes a consistent, compacted copy of the database to `path` (`VACUUM INTO`), mode 0600. The copy is built in
    /// a private (0700) staging directory next to the destination and renamed over it, so an existing file is
    /// replaced atomically, the copy is never readable by other users, and a failed export leaves nothing behind.
    public func exportCopy(to path: String) throws {
        let destination = (path as NSString).standardizingPath
        if let own = self.path, (own as NSString).standardizingPath == destination {
            throw StoreError.invalidValue("cannot export the database onto itself")
        }
        let directory = (destination as NSString).deletingLastPathComponent
        let staging = (directory as NSString).appendingPathComponent(".mergecue-export-\(UUID().uuidString)")
        try DatabaseFile.createPrivateDirectory(atPath: staging)
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let copy = (staging as NSString).appendingPathComponent("export.sqlite")
        // VACUUM INTO refuses an existing output file (even an empty one), so SQLite creates it; the 0700 staging
        // directory keeps it private until it is tightened to 0600.
        try connection.run("VACUUM INTO ?", [.text(copy)])
        try DatabaseFile.makePrivate(atPath: copy)
        guard rename(copy, destination) == 0 else {
            let code = errno
            throw StoreError.sqlite(
                code: SQLiteResultCode.cantOpen,
                message: "rename export to \(destination): \(String(cString: strerror(code)))"
            )
        }
    }

    /// Deletes every stored record. The database file and its `-wal`/`-shm` companions are removed and recreated
    /// empty (works on a damaged database too), then migrated to the latest schema.
    ///
    /// - Important: MergeCue keeps one `MergeCueDatabase` per file; other connections to the same file must be
    ///   closed first.
    public func resetAll() throws {
        connection.close()
        if case .file(let path) = location {
            try DatabaseFile.removeFiles(atPath: path)
        }
        let fresh = try SQLiteConnection(location: location)
        try Migrator.migrate(fresh, migrations: migrations)
        connection = fresh
    }

    /// Removes a database file and its companions without opening it — the recovery path when `init(path:)`
    /// throws `StoreError.corrupted` (offer to keep a copy of the damaged file first).
    public static func removeDatabaseFiles(atPath path: String) throws {
        try DatabaseFile.removeFiles(atPath: path)
    }

    // MARK: Shared helpers (used by the feature extensions)

    /// Encodes `value` for a JSON column; encoding failures become `StoreError.invalidValue`.
    func json<T: Encodable>(_ value: T) throws -> SQLiteValue {
        do {
            return .json(try encoder.encode(value))
        } catch let EncodingError.invalidValue(_, context) {
            // The context only; the offending value itself is never echoed into errors or logs.
            throw StoreError.invalidValue("cannot encode \(T.self): \(context.debugDescription)")
        } catch {
            throw StoreError.invalidValue("cannot encode \(T.self)")
        }
    }

    /// Decodes a JSON column; failures become `StoreError.corrupted`.
    func decode<T: Decodable>(_ type: T.Type, from row: SQLiteRow, column: Int) throws -> T {
        do {
            return try decoder.decode(T.self, from: row.data(column))
        } catch {
            throw StoreError.corrupted("stored \(T.self) no longer decodes: \(error)")
        }
    }

    /// Whether a row with primary key `id` exists in `table` (a trusted, internal table name).
    func exists(_ table: String, id: String) throws -> Bool {
        try connection.queryFirst("SELECT 1 FROM \(table) WHERE id = ?", [.text(id)]) { _ in true } ?? false
    }

    /// Throws `StoreError.notFound` unless the account exists.
    func requireAccount(_ account: AccountKey) throws {
        guard try exists("accounts", id: account.id) else { throw StoreError.notFound }
    }

    /// Throws `StoreError.notFound` unless the task exists.
    func requireTask(_ id: TaskID) throws {
        guard try exists("tasks", id: id.rawValue) else { throw StoreError.notFound }
    }

    // MARK: Test support

    /// Executes raw SQL (tests only: pragmas, corruption and trigger checks).
    func executeForTesting(_ sql: String) throws {
        try connection.execute(sql)
    }

    /// Runs a single-column text query (tests only).
    func queryTextForTesting(_ sql: String) throws -> [String] {
        try connection.query(sql) { $0.optionalText(0) ?? "NULL" }
    }
}
