import Foundation

/// The shared JSON coders. Every module must use these instead of ad-hoc `JSONEncoder()`s so dates and key order
/// agree across the store, IPC/MCP and digests.
///
/// - **Storage** (`storageEncoder`/`storageDecoder`): SQLite JSON blobs, settings, anything read back by MergeCue.
///   Dates are written as their exact `timeIntervalSinceReferenceDate` (`.deferredToDate`), so a value is `==` to
///   itself after a store round trip (sub-second provider timestamps, lease expiries). `.secondsSince1970` is *not*
///   lossless — the epoch shift drops low-order bits of most wall-clock dates.
/// - **Wire** (`wireEncoder`/`wireDecoder`): IPC/MCP DTOs and other human-readable JSON. RFC 3339 / ISO-8601 in UTC
///   with millisecond precision; the fraction is omitted when it is zero (`2026-01-01T00:00:00Z`,
///   `2026-01-01T00:00:00.123Z`). Decoding accepts any number of fractional digits (or none) and `Z` or `±hh:mm`.
///   Millisecond-precision dates (every provider timestamp) round-trip exactly; finer precision is rounded.
///
/// Both use sorted keys; `Set` properties of Core types encode as sorted arrays, so equal values always produce
/// identical bytes (use `digest(_:)` for fingerprints).
public enum MergeCueCoding {
    // MARK: Storage

    /// Lossless coder for persisted JSON (sorted keys, exact dates).
    public static func storageEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decoder matching `storageEncoder()`.
    public static func storageDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }

    // MARK: Wire

    /// ISO-8601 (UTC, millisecond precision) coder for IPC/MCP and exported JSON (sorted keys).
    public static func wireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            guard let text = formatWireDate(date) else {
                throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "Non-finite date"))
            }
            try container.encode(text)
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decoder matching `wireEncoder()`; accepts ISO-8601 with or without fractional seconds.
    public static func wireDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseWireDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 date, got \(text)")
            }
            return date
        }
        return decoder
    }

    /// `2026-01-01T00:00:00Z` / `2026-01-01T00:00:00.123Z` (rounded to the nearest millisecond). nil for
    /// non-finite dates.
    public static func formatWireDate(_ date: Date) -> String? {
        let millis = (date.timeIntervalSince1970 * 1000).rounded()
        guard millis.isFinite, abs(millis) < 1e17 else { return nil }
        let wholeMillis = Int64(millis)
        let (quotient, remainder) = wholeMillis.quotientAndRemainder(dividingBy: 1000)
        let seconds = remainder < 0 ? quotient - 1 : quotient
        let fraction = remainder < 0 ? remainder + 1000 : remainder
        let base = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(Date.ISO8601FormatStyle())
        guard fraction != 0, base.hasSuffix("Z") else { return base }
        let digits = String(fraction)
        return String(base.dropLast()) + "." + String(repeating: "0", count: 3 - digits.count) + digits + "Z"
    }

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±hh:mm)`. The fraction may have any number of digits; the result
    /// is the `Date` nearest to the written decimal value.
    public static func parseWireDate(_ text: String) -> Date? {
        let utf8 = Array(text.utf8)
        // "YYYY-MM-DDTHH:MM:SS" is 19 bytes; a fraction starts right after it.
        guard utf8.count >= 20 else { return nil }
        var fractionDigits: [UInt8] = []
        var rest = Array(utf8[19...])
        if rest.first == UInt8(ascii: ".") {
            rest.removeFirst()
            while let byte = rest.first, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                fractionDigits.append(byte)
                rest.removeFirst()
            }
            guard !fractionDigits.isEmpty else { return nil }
        }
        let base = String(decoding: utf8[..<19] + rest, as: UTF8.self)
        guard let whole = try? Date.ISO8601FormatStyle().parse(base) else { return nil }
        guard !fractionDigits.isEmpty else { return whole }
        let seconds = whole.timeIntervalSince1970
        let fraction = String(decoding: fractionDigits.prefix(17), as: UTF8.self)
        if seconds >= 0, let exact = Double("\(Int64(seconds)).\(fraction)") {
            return Date(timeIntervalSince1970: exact)
        }
        guard let value = Double("0.\(fraction)") else { return nil }
        return Date(timeIntervalSince1970: seconds + value)
    }

    // MARK: Digests

    /// Lowercase hex SHA-256 of the storage encoding of `value` — deterministic across processes (sorted keys,
    /// sorted `Set`s, exact dates). Use for preview fingerprints and change detection.
    public static func digest<T: Encodable>(_ value: T) throws -> String {
        ContentDigest.sha256Hex(try storageEncoder().encode(value))
    }
}

extension KeyedEncodingContainer {
    /// Encodes a `Set` as an array sorted by `sortKey`, so the bytes do not depend on hash-seed iteration order.
    mutating func encodeSorted<Element: Encodable & Hashable>(
        _ set: Set<Element>,
        forKey key: Key,
        by sortKey: (Element) -> String
    ) throws {
        try encode(set.sorted { sortKey($0) < sortKey($1) }, forKey: key)
    }
}
