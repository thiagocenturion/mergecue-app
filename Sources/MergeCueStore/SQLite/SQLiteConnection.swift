import Foundation
import SQLite3

/// A thin wrapper over one `sqlite3*` connection.
///
/// Not thread-safe by design: it is opened with `SQLITE_OPEN_NOMUTEX` and owned by exactly one actor
/// (`MergeCueDatabase`), which serializes every use. Errors are always `StoreError`s carrying the extended SQLite
/// result code and message.
final class SQLiteConnection {
    /// Where the database lives.
    enum Location: Sendable, Hashable {
        case file(String)
        case memory

        var sqlitePath: String {
            switch self {
            case .file(let path): path
            case .memory: ":memory:"
            }
        }
    }

    enum TransactionMode: String {
        case deferred = "DEFERRED"
        case immediate = "IMMEDIATE"
        case exclusive = "EXCLUSIVE"
    }

    /// How long a statement waits for another connection's lock before failing with `SQLITE_BUSY`.
    static let busyTimeoutMilliseconds: Int32 = 5_000

    static var closedError: StoreError {
        .sqlite(code: SQLiteResultCode.misuse, message: "database connection is closed")
    }

    private(set) var handle: OpaquePointer?
    let location: Location
    private var savepointCounter = 0

    /// Opens (creating if needed) and configures the connection: extended result codes, busy timeout, WAL,
    /// `synchronous=NORMAL`, `foreign_keys=ON`, `secure_delete=ON`, `trusted_schema=OFF`. For files, the database
    /// (and any existing `-wal`/`-shm`) is created/tightened to mode 0600 *before* SQLite opens it, so SQLite's
    /// journal files inherit 0600 too.
    init(location: Location) throws {
        self.location = location
        if case .file(let path) = location {
            try DatabaseFile.preparePrivateFile(atPath: path)
        }
        var db: OpaquePointer?
        // No SQLITE_OPEN_NOFOLLOW: it rejects symlinks anywhere in the path (/var → /private/var, a symlinked
        // MERGECUE_HOME); `DatabaseFile.preparePrivateFile` already refuses a symlink as the file itself.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(location.sqlitePath, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(code))
            sqlite3_close_v2(db)
            throw Self.makeError(code: code, message: message, context: "open")
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, Self.busyTimeoutMilliseconds)
        do {
            try configure()
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    private func configure() throws {
        // journal_mode reads the file header, so a file that is not a database fails here with SQLITE_NOTADB.
        _ = try queryFirst("PRAGMA journal_mode = WAL") { $0.text(0) }
        try execute(
            """
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA secure_delete = ON;
            PRAGMA trusted_schema = OFF;
            """
        )
    }

    /// Closes the connection (idempotent). Later calls fail with `closedError`.
    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    var isOpen: Bool { handle != nil }

    // MARK: Execution

    /// Executes one or more SQL statements without parameters (schema scripts, pragmas).
    func execute(_ sql: String) throws {
        guard let handle else { throw Self.closedError }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            throw Self.makeError(code: sqlite3_extended_errcode(handle), message: message, context: nil)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(connection: self, sql: sql)
    }

    /// Runs one statement and returns the number of changed rows.
    @discardableResult
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws -> Int {
        try prepare(sql).run(values)
    }

    func query<T>(_ sql: String, _ values: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> T) throws -> [T] {
        try prepare(sql).query(values, map)
    }

    func queryFirst<T>(_ sql: String, _ values: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> T) throws -> T? {
        try prepare(sql).queryFirst(values, map)
    }

    /// Rows changed by the most recent INSERT/UPDATE/DELETE on this connection.
    var changes: Int {
        handle.map { Int(sqlite3_changes64($0)) } ?? 0
    }

    /// True while a transaction is open on this connection.
    var isInTransaction: Bool {
        guard let handle else { return false }
        return sqlite3_get_autocommit(handle) == 0
    }

    // MARK: Transactions

    /// Runs `body` in a transaction: COMMIT on return, ROLLBACK when it throws (the error is rethrown). Nested calls
    /// use savepoints, so an inner failure only rolls back the inner work.
    func transaction<T>(_ mode: TransactionMode = .immediate, _ body: () throws -> T) throws -> T {
        if isInTransaction {
            savepointCounter += 1
            let name = "mc_sp_\(savepointCounter)"
            try execute("SAVEPOINT \(name)")
            do {
                let result = try body()
                try execute("RELEASE \(name)")
                return result
            } catch {
                if isInTransaction {
                    try? execute("ROLLBACK TO \(name)")
                    try? execute("RELEASE \(name)")
                }
                throw error
            }
        }
        try execute("BEGIN \(mode.rawValue)")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            // Some errors (SQLITE_FULL, IOERR, …) already rolled back; only roll back what is still open.
            if isInTransaction {
                try? execute("ROLLBACK")
            }
            throw error
        }
    }

    // MARK: Errors

    /// The connection's current error for a failed call that returned `code`.
    func error(code: Int32, context: String?) -> StoreError {
        guard let handle else { return Self.closedError }
        let extended = sqlite3_extended_errcode(handle)
        // Prefer the connection's extended code when it refines the returned primary code.
        let resolved = (extended & 0xFF) == (code & 0xFF) ? extended : code
        return Self.makeError(code: resolved, message: String(cString: sqlite3_errmsg(handle)), context: context)
    }

    static func makeError(code: Int32, message: String, context: String?) -> StoreError {
        let text = context.map { "\($0): \(message)" } ?? message
        switch code & 0xFF {
        case SQLiteResultCode.corrupt, SQLiteResultCode.notADatabase:
            return .corrupted(text)
        default:
            return .sqlite(code: code, message: text)
        }
    }
}
