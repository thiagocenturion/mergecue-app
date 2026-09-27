import Foundation
import SQLite3

/// A prepared statement. Finalized on deinit; owned by one `SQLiteConnection` and never shared across threads.
final class SQLiteStatement {
    private(set) var handle: OpaquePointer?
    private let connection: SQLiteConnection
    let sql: String

    init(connection: SQLiteConnection, sql: String) throws {
        self.connection = connection
        self.sql = sql
        guard let db = connection.handle else { throw SQLiteConnection.closedError }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v3(db, sql, -1, 0, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw connection.error(code: code, context: "prepare")
        }
        handle = statement
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// `SQLITE_TRANSIENT`: SQLite copies bound text/blob buffers immediately (the macro is not imported into Swift).
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    // MARK: Binding

    /// Resets the statement and binds `values` to parameters 1…n.
    func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        let expected = Int(sqlite3_bind_parameter_count(handle))
        guard values.count == expected else {
            throw StoreError.sqlite(
                code: SQLiteResultCode.misuse,
                message: "statement expects \(expected) parameters, got \(values.count)"
            )
        }
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1))
        }
    }

    private func bind(_ value: SQLiteValue, at index: Int32) throws {
        let code: Int32
        switch value {
        case .null:
            code = sqlite3_bind_null(handle, index)
        case .integer(let int):
            code = sqlite3_bind_int64(handle, index, int)
        case .real(let double):
            code = sqlite3_bind_double(handle, index, double)
        case .text(let string):
            var string = string
            code = string.withUTF8 { buffer -> Int32 in
                // An empty buffer may have a nil base address, which SQLite would bind as NULL.
                guard let base = buffer.baseAddress, buffer.count > 0 else {
                    return sqlite3_bind_text(handle, index, "", 0, Self.transient)
                }
                return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
                    sqlite3_bind_text64(handle, index, pointer, sqlite3_uint64(buffer.count), Self.transient, UInt8(SQLITE_UTF8))
                }
            }
        case .blob(let data):
            code = data.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress, buffer.count > 0 else {
                    return sqlite3_bind_zeroblob(handle, index, 0)
                }
                return sqlite3_bind_blob64(handle, index, base, sqlite3_uint64(buffer.count), Self.transient)
            }
        }
        guard code == SQLITE_OK else { throw connection.error(code: code, context: "bind") }
    }

    // MARK: Stepping

    /// Steps once. Returns true when a row is available, false when the statement is done.
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            // The statement-level error is also recorded on the connection; reset so it can be reused.
            let error = connection.error(code: code, context: nil)
            sqlite3_reset(handle)
            throw error
        }
    }

    /// Runs the statement to completion (ignoring any rows) and returns the number of rows changed.
    @discardableResult
    func run(_ values: [SQLiteValue] = []) throws -> Int {
        try bind(values)
        defer { reset() }
        while try step() {}
        return connection.changes
    }

    /// Runs the statement and maps every result row.
    func query<T>(_ values: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> T) throws -> [T] {
        try bind(values)
        defer { reset() }
        var results: [T] = []
        while try step() {
            results.append(try map(SQLiteRow(statement: self)))
        }
        return results
    }

    /// Runs the statement and maps only the first row (nil when there is none).
    func queryFirst<T>(_ values: [SQLiteValue] = [], _ map: (SQLiteRow) throws -> T) throws -> T? {
        try bind(values)
        defer { reset() }
        guard try step() else { return nil }
        return try map(SQLiteRow(statement: self))
    }

    /// Ends the current execution so the statement holds no read snapshot or lock (bindings are kept).
    func reset() {
        sqlite3_reset(handle)
    }
}

/// Typed read access to the current result row of a statement. Column indices are zero-based.
struct SQLiteRow {
    private let statement: SQLiteStatement

    init(statement: SQLiteStatement) {
        self.statement = statement
    }

    private var handle: OpaquePointer? { statement.handle }

    var columnCount: Int { Int(sqlite3_column_count(handle)) }

    func isNull(_ index: Int) -> Bool {
        sqlite3_column_type(handle, Int32(index)) == SQLITE_NULL
    }

    func int64(_ index: Int) -> Int64 {
        sqlite3_column_int64(handle, Int32(index))
    }

    func int(_ index: Int) -> Int {
        Int(int64(index))
    }

    func bool(_ index: Int) -> Bool {
        int64(index) != 0
    }

    func double(_ index: Int) -> Double {
        sqlite3_column_double(handle, Int32(index))
    }

    func date(_ index: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: double(index))
    }

    func optionalDate(_ index: Int) -> Date? {
        isNull(index) ? nil : date(index)
    }

    func text(_ index: Int) -> String {
        String(decoding: bytes(index), as: UTF8.self)
    }

    func optionalText(_ index: Int) -> String? {
        isNull(index) ? nil : text(index)
    }

    /// The raw bytes of a TEXT or BLOB column (JSON payloads are read this way, without a String round trip).
    func data(_ index: Int) -> Data {
        bytes(index)
    }

    private func bytes(_ index: Int) -> Data {
        let column = Int32(index)
        // Call order matters: `sqlite3_column_blob` first, then `sqlite3_column_bytes` (see the SQLite docs).
        guard let pointer = sqlite3_column_blob(handle, column) else { return Data() }
        let count = Int(sqlite3_column_bytes(handle, column))
        return Data(bytes: pointer, count: count)
    }
}
