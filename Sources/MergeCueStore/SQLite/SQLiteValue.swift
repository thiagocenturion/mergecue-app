import Foundation

/// A value bound to a statement parameter.
///
/// Dates are stored as `REAL` seconds since the reference date (`timeIntervalSinceReferenceDate`) — the same
/// representation `MergeCueCoding.storageEncoder()` uses — so indexed date columns compare exactly with the dates
/// inside the JSON payloads.
enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    static func int(_ value: Int) -> SQLiteValue {
        .integer(Int64(value))
    }

    static func bool(_ value: Bool) -> SQLiteValue {
        .integer(value ? 1 : 0)
    }

    static func date(_ value: Date) -> SQLiteValue {
        .real(value.timeIntervalSinceReferenceDate)
    }

    static func optionalDate(_ value: Date?) -> SQLiteValue {
        value.map(date) ?? .null
    }

    static func optionalText(_ value: String?) -> SQLiteValue {
        value.map(SQLiteValue.text) ?? .null
    }

    /// JSON produced by `MergeCueCoding.storageEncoder()`, stored as UTF-8 `TEXT` (readable with the `sqlite3` CLI
    /// and `json_extract`).
    static func json(_ data: Data) -> SQLiteValue {
        .text(String(decoding: data, as: UTF8.self))
    }
}
