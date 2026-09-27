import Foundation
import MergeCueCore

/// Parses the timestamp formats GitHub, GitLab and Bitbucket Cloud emit.
///
/// Accepted:
/// - ISO-8601 / RFC 3339 with or without a fraction of any length: `2024-01-01T12:00:00Z`,
///   `2024-01-01T12:00:00.123Z`, `2024-01-01T12:00:00.123456+00:00` (Bitbucket), `…+05:30`, `…-0800`.
/// - Lower-case `t`/`z` and a space instead of `T` (seen in some GitLab payloads).
/// - Date-only `2024-01-01` (GitLab due dates), interpreted as midnight UTC.
public enum ProviderDateParser {
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var bytes = Array(trimmed.utf8)
        guard bytes.count >= 10 else { return nil }

        if bytes.count == 10 {
            return MergeCueCoding.parseWireDate(trimmed + "T00:00:00Z")
        }
        guard bytes.count >= 20 else { return nil }
        // Normalize the date/time separator and a trailing lower-case zone designator.
        if bytes[10] == UInt8(ascii: " ") || bytes[10] == UInt8(ascii: "t") {
            bytes[10] = UInt8(ascii: "T")
        }
        if bytes.last == UInt8(ascii: "z") {
            bytes[bytes.count - 1] = UInt8(ascii: "Z")
        }
        // `+hhmm` / `-hhmm` → `+hh:mm`.
        let count = bytes.count
        if count >= 24, bytes[count - 5] == UInt8(ascii: "+") || bytes[count - 5] == UInt8(ascii: "-"),
           bytes[(count - 4)...].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        {
            bytes.insert(UInt8(ascii: ":"), at: count - 2)
        }
        // A bare `+hh` offset → `+hh:00`.
        let normalizedCount = bytes.count
        if normalizedCount >= 22, bytes[normalizedCount - 3] == UInt8(ascii: "+") || bytes[normalizedCount - 3] == UInt8(ascii: "-"),
           bytes[(normalizedCount - 2)...].allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
           bytes[normalizedCount - 4] != UInt8(ascii: ":")
        {
            bytes.append(contentsOf: Array(":00".utf8))
        }
        return MergeCueCoding.parseWireDate(String(decoding: bytes, as: UTF8.self))
    }
}

extension JSONDecoder {
    /// A decoder configured for provider REST/GraphQL payloads: dates via `ProviderDateParser` (ISO-8601 with or
    /// without fractional seconds, any offset), default keys (adapters declare their own `CodingKeys`).
    ///
    /// Each access returns a **new** instance, so callers may adjust it (e.g. `keyDecodingStrategy`) without
    /// affecting other users.
    public static var mergeCueProvider: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ProviderDateParser.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 timestamp, got \"\(BoundedText.truncate(text, maxBytes: 64).text)\""
                )
            }
            return date
        }
        return decoder
    }
}
