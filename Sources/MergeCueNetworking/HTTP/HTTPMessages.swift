import Foundation
import MergeCueCore

/// An outgoing HTTP request.
///
/// `description`, `debugDescription` and the reflection mirror mask the values of credential-bearing headers
/// (`Authorization`, `PRIVATE-TOKEN`, `Cookie`, …), so printing or dumping a request never leaks a secret.
public struct HTTPRequest: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// Upper-case HTTP method (`GET`, `POST`, …).
    public var method: String
    public var url: URL
    /// Header fields as written by the caller (names are case-insensitive; use `header(_:)` to read).
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method.uppercased()
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        HTTPHeaders.value(named: name, in: headers)
    }

    /// Whether the method is safe to repeat automatically (`GET`/`HEAD`).
    public var isIdempotentRead: Bool {
        let upper = method.uppercased()
        return upper == "GET" || upper == "HEAD"
    }

    public var description: String {
        "\(method) \(SecretRedactor.redact(url.absoluteString))"
    }

    public var debugDescription: String {
        let names = HTTPHeaders.redacted(headers)
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        return "HTTPRequest(\(description), headers: [\(names)], body: \(body?.count ?? 0) bytes)"
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "method": method,
                "url": SecretRedactor.redact(url.absoluteString),
                "headers": HTTPHeaders.redacted(headers),
                "bodyByteCount": body?.count ?? 0,
            ],
            displayStyle: .struct
        )
    }
}

/// A received HTTP response. Header names are stored lower-cased.
public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    /// Header fields with lower-cased names.
    public var headers: [String: String]
    public var body: Data
    /// The URL that produced the response (after redirects).
    public var url: URL

    /// Creates a response; header names are lower-cased (duplicates differing only by case are joined with `, `
    /// in a deterministic order).
    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), url: URL) {
        self.status = status
        self.headers = HTTPHeaders.lowercased(headers)
        self.body = body
        self.url = url
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        HTTPHeaders.value(named: name, in: headers)
    }

    /// 2xx.
    public var isSuccess: Bool { (200..<300).contains(status) }

    /// The body decoded as UTF-8 (invalid sequences replaced).
    public var bodyText: String { String(decoding: body, as: UTF8.self) }

    /// Whether this response was served from the `ETagCache` after a `304 Not Modified`.
    public var isCacheHit: Bool { header(HTTPHeaders.cacheStatus) == "hit" }
}

/// Performs HTTP requests. Implementations throw `URLError` for transport failures and return every HTTP status
/// (including 4xx/5xx) as a response.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Header helpers shared by the transport, client and stub.
public enum HTTPHeaders {
    /// Response header added to `304 Not Modified` responses served from the `ETagCache` (value `hit`).
    public static let cacheStatus = "x-mergecue-cache"

    /// Header names whose values are secrets and are masked by `redacted(_:)` (lower-cased).
    public static let sensitiveNames: Set<String> = [
        "authorization", "proxy-authorization", "private-token", "job-token", "cookie", "set-cookie",
        "x-api-key", "x-auth-token", "x-access-token",
    ]

    /// Whether `name` carries secret material (`Authorization`, `*-token`, cookies, API keys).
    public static func isSensitive(_ name: String) -> Bool {
        let lower = name.lowercased()
        return sensitiveNames.contains(lower) || lower.hasSuffix("-token") || lower.hasSuffix("-api-key")
    }

    /// Copy of `headers` with secret values replaced by `[REDACTED]`.
    public static func redacted(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            result[name] = isSensitive(name) ? SecretRedactor.marker : value
        }
        return result
    }

    /// Case-insensitive lookup.
    public static func value(named name: String, in headers: [String: String]) -> String? {
        if let exact = headers[name] { return exact }
        let lower = name.lowercased()
        if let lowered = headers[lower] { return lowered }
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    /// Lower-cases names; values of names that collide are joined with `, ` (sorted by original name so the
    /// result does not depend on dictionary order).
    public static func lowercased(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in headers.keys.sorted() {
            guard let value = headers[key] else { continue }
            let lower = key.lowercased()
            if let existing = result[lower] {
                result[lower] = existing + ", " + value
            } else {
                result[lower] = value
            }
        }
        return result
    }

    /// Merges header dictionaries left to right; a later name replaces an earlier one regardless of case.
    public static func merged(_ layers: [String: String]...) -> [String: String] {
        var result: [String: String] = [:]
        for layer in layers {
            for key in layer.keys.sorted() {
                guard let value = layer[key] else { continue }
                let lower = key.lowercased()
                for existing in result.keys where existing.lowercased() == lower {
                    result.removeValue(forKey: existing)
                }
                result[key] = value
            }
        }
        return result
    }

    /// Whether `headers` contains `name` (case-insensitive).
    public static func contains(_ name: String, in headers: [String: String]) -> Bool {
        value(named: name, in: headers) != nil
    }
}
