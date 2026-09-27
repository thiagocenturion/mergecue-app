import Foundation

/// Errors thrown by `MergeCueDatabase`. Every public store method throws only `StoreError`.
public enum StoreError: Error, Sendable, Equatable, LocalizedError {
    /// Optimistic-concurrency failure: the stored task has version `current`, not the expected one.
    case versionConflict(current: Int)
    /// The addressed row (or a required parent row such as the account or task) does not exist.
    case notFound
    /// The database file is damaged or is not a MergeCue/SQLite database (`SQLITE_CORRUPT`, `SQLITE_NOTADB`, or a
    /// stored JSON value that no longer decodes). Offer export + reset.
    case corrupted(String)
    /// Any other SQLite failure. `code` is the **extended** result code (e.g. 2067 = `SQLITE_CONSTRAINT_UNIQUE`).
    case sqlite(code: Int32, message: String)
    /// The caller passed a value the store refuses to persist (cannot be encoded, belongs to another account, looks
    /// like a credential, a task update that does not bump the version, …).
    case invalidValue(String)
    /// The database was migrated by a newer MergeCue (schema `found` > `supported`); it is never downgraded.
    case schemaTooNew(found: Int, supported: Int)

    /// The primary SQLite result code (`code & 0xFF`) for `.sqlite`, nil otherwise.
    public var sqlitePrimaryCode: Int32? {
        guard case .sqlite(let code, _) = self else { return nil }
        return code & 0xFF
    }

    /// Any constraint violation (`SQLITE_CONSTRAINT*`).
    public var isConstraintViolation: Bool {
        sqlitePrimaryCode == SQLiteResultCode.constraint
    }

    /// A duplicate primary key / unique value, e.g. a `TaskID` collision on `insertTask` (retry with a new id).
    public var isUniqueConstraintViolation: Bool {
        guard case .sqlite(let code, _) = self else { return false }
        return code == SQLiteResultCode.constraintPrimaryKey || code == SQLiteResultCode.constraintUnique
    }

    /// `SQLITE_BUSY` / `SQLITE_LOCKED`: another connection held the database longer than the busy timeout.
    public var isBusy: Bool {
        sqlitePrimaryCode == SQLiteResultCode.busy || sqlitePrimaryCode == SQLiteResultCode.locked
    }

    public var errorDescription: String? {
        switch self {
        case .versionConflict(let current):
            "The task changed in the meantime (current version \(current))."
        case .notFound:
            "The requested record does not exist."
        case .corrupted(let message):
            "The MergeCue database is damaged: \(message)"
        case .sqlite(let code, let message):
            "Database error \(code): \(message)"
        case .invalidValue(let message):
            "Refused to store value: \(message)"
        case .schemaTooNew(let found, let supported):
            "The database was created by a newer MergeCue (schema v\(found), this version supports v\(supported))."
        }
    }
}

/// SQLite result codes used by the store. Extended codes are spelled out because the C macros that build them
/// (`SQLITE_CONSTRAINT | (8<<8)`) are not imported into Swift.
enum SQLiteResultCode {
    static let ok: Int32 = 0
    static let error: Int32 = 1
    static let busy: Int32 = 5
    static let locked: Int32 = 6
    static let corrupt: Int32 = 11
    static let cantOpen: Int32 = 14
    static let constraint: Int32 = 19
    static let misuse: Int32 = 21
    static let notADatabase: Int32 = 26
    static let row: Int32 = 100
    static let done: Int32 = 101

    static let constraintForeignKey: Int32 = constraint | (3 << 8)
    static let constraintPrimaryKey: Int32 = constraint | (6 << 8)
    static let constraintUnique: Int32 = constraint | (8 << 8)
}
