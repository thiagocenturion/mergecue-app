import Foundation
import MergeCueCore

/// Builds request URLs from an API base URL, a relative path and query items.
///
/// - The base URL's path is a prefix that is always kept: `https://gitlab.com/api/v4` + `/projects/1` →
///   `https://gitlab.com/api/v4/projects/1` (a leading `/` on the path does **not** replace the prefix).
/// - `path` is treated as already percent-encoded: valid `%XX` escapes are kept (GitLab's `acme%2Fpayments-api`),
///   other characters outside RFC 3986 `pchar` (spaces, `{`, `}`, non-ASCII, a stray `%`) are encoded.
///   Use `encodePathSegment(_:)` for dynamic values so `/` inside a value cannot add segments.
/// - `.` / `..` segments (also when percent-encoded) are rejected, so provider data cannot walk out of the API
///   prefix.
/// - A query written inside `path` (`/search?q=x`) is kept; `query` items are appended, each name and value
///   encoded with only RFC 3986 unreserved characters left as-is (`+` → `%2B`, `/` → `%2F`, space → `%20`).
public enum RequestURLBuilder {
    /// RFC 3986 unreserved characters.
    static let unreserved: Set<UInt8> = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))
    /// RFC 3986 `pchar` minus `%` (handled separately), plus `/`.
    static let pathAllowed: Set<UInt8> = unreserved.union(Array("!$&'()*+,;=:@/".utf8))
    /// RFC 3986 query characters minus `%`.
    static let queryAllowed: Set<UInt8> = pathAllowed.union(Array("?".utf8))

    /// Joins `path` (and optional `query`) onto `baseURL`.
    ///
    /// - Throws: `ProviderError.invalidRequest` for dot segments or a base URL that cannot be extended.
    public static func url(baseURL: URL, path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw ProviderError.invalidRequest("Invalid API base URL.")
        }
        var relative = path
        if let hash = relative.firstIndex(of: "#") {
            relative = String(relative[..<hash])
        }
        var inlineQuery: String?
        if let questionMark = relative.firstIndex(of: "?") {
            inlineQuery = String(relative[relative.index(after: questionMark)...])
            relative = String(relative[..<questionMark])
        }

        let encodedRelative = escape(relative, allowed: pathAllowed)
        let segments = encodedRelative.split(separator: "/", omittingEmptySubsequences: true)
        for segment in segments {
            let decoded = String(segment).removingPercentEncoding ?? String(segment)
            if decoded == "." || decoded == ".." {
                throw ProviderError.invalidRequest("Request paths must not contain dot segments.")
            }
        }

        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        var trimmedRelative = Substring(encodedRelative)
        while trimmedRelative.hasPrefix("/") { trimmedRelative.removeFirst() }
        if trimmedRelative.isEmpty {
            components.percentEncodedPath = basePath.isEmpty && !encodedRelative.isEmpty ? "/" : basePath
        } else {
            components.percentEncodedPath = basePath + "/" + trimmedRelative
        }

        var queryParts: [String] = []
        if let existing = components.percentEncodedQuery, !existing.isEmpty {
            queryParts.append(existing)
        }
        if let inlineQuery, !inlineQuery.isEmpty {
            queryParts.append(escape(inlineQuery, allowed: queryAllowed))
        }
        let encodedItems = encodeQuery(query)
        if !encodedItems.isEmpty {
            queryParts.append(encodedItems)
        }
        components.percentEncodedQuery = queryParts.isEmpty ? nil : queryParts.joined(separator: "&")
        components.fragment = nil

        guard let url = components.url else {
            throw ProviderError.invalidRequest("Could not build a request URL.")
        }
        return url
    }

    /// `name=value&…` with every name and value strictly encoded (only unreserved characters left as-is).
    /// Items without a value are written as `name`. Order is preserved.
    public static func encodeQuery(_ items: [URLQueryItem]) -> String {
        items.map { item in
            let name = encodeQueryComponent(item.name)
            guard let value = item.value else { return name }
            return name + "=" + encodeQueryComponent(value)
        }
        .joined(separator: "&")
    }

    /// Percent-encodes everything except RFC 3986 unreserved characters (`A-Z a-z 0-9 - . _ ~`).
    public static func encodeQueryComponent(_ value: String) -> String {
        percentEncode(value, keeping: unreserved)
    }

    /// Encodes a single dynamic path segment (owner, repo, project path, UUID…): everything except unreserved
    /// characters is escaped, so `/` becomes `%2F` and `{…}` becomes `%7B…%7D`.
    public static func encodePathSegment(_ value: String) -> String {
        percentEncode(value, keeping: unreserved)
    }

    // MARK: Encoding primitives

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    private static func percentEncode(_ value: String, keeping allowed: Set<UInt8>) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if allowed.contains(byte) {
                output.append(byte)
            } else {
                appendEscaped(byte, to: &output)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Escapes bytes outside `allowed`, keeping well-formed `%XX` escapes and escaping a stray `%` as `%25`.
    static func escape(_ value: String, allowed: Set<UInt8>) -> String {
        let bytes = Array(value.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) {
                output.append(contentsOf: bytes[index...(index + 2)])
                index += 3
                continue
            }
            if allowed.contains(byte) {
                output.append(byte)
            } else {
                appendEscaped(byte, to: &output)
            }
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func appendEscaped(_ byte: UInt8, to output: inout [UInt8]) {
        output.append(UInt8(ascii: "%"))
        output.append(hexDigits[Int(byte >> 4)])
        output.append(hexDigits[Int(byte & 0x0F)])
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"), UInt8(ascii: "A")...UInt8(ascii: "F"):
            true
        default:
            false
        }
    }
}
