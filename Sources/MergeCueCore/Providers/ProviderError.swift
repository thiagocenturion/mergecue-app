import Foundation

/// Typed provider failure. Messages must never include credentials.
public enum ProviderError: Error, Sendable, Equatable, LocalizedError {
    /// 401 / revoked / expired credentials.
    case unauthorized(String)
    case forbidden(missingScope: String?, message: String)
    case notFound(String)
    case rateLimited(resetAt: Date?, retryAfter: TimeInterval?)
    case server(status: Int, message: String)
    case offline
    case timeout
    case decoding(String)
    case unsupported(Capability, reason: String)
    /// Remote state changed (head SHA moved, thread already resolved, …).
    case conflict(String)
    case invalidRequest(String)

    /// Whether an automatic retry (with backoff) may succeed: rate limits, 5xx/408, offline and timeouts.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .offline, .timeout:
            true
        case .server(let status, _):
            status >= 500 || status == 408
        case .unauthorized, .forbidden, .notFound, .decoding, .unsupported, .conflict, .invalidRequest:
            false
        }
    }

    /// Stable machine code (snake_case) for storage, activities and MCP errors.
    public var code: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .notFound: "not_found"
        case .rateLimited: "rate_limited"
        case .server: "server_error"
        case .offline: "offline"
        case .timeout: "timeout"
        case .decoding: "decoding_error"
        case .unsupported: "unsupported"
        case .conflict: "conflict"
        case .invalidRequest: "invalid_request"
        }
    }

    /// Earliest time a retry makes sense for rate limits, relative to `now`.
    public func retryDate(now: Date) -> Date? {
        guard case .rateLimited(let resetAt, let retryAfter) = self else { return nil }
        if let retryAfter { return now.addingTimeInterval(max(0, retryAfter)) }
        return resetAt
    }

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            "Authentication failed. Reconnect the account. \(message)"
        case .forbidden(let scope, let message):
            if let scope { "Permission denied (missing scope \(scope)). \(message)" } else { "Permission denied. \(message)" }
        case .notFound(let message):
            "Not found. \(message)"
        case .rateLimited(let resetAt, let retryAfter):
            if let retryAfter { "Rate limited; retry after \(Int(retryAfter.rounded(.up))) s." }
            else if let resetAt { "Rate limited until \(resetAt.formatted(.iso8601))." }
            else { "Rate limited." }
        case .server(let status, let message):
            "Provider error \(status). \(message)"
        case .offline:
            "Offline."
        case .timeout:
            "The request timed out."
        case .decoding(let message):
            "Unexpected provider response. \(message)"
        case .unsupported(let capability, let reason):
            "\(capability.displayName) is unsupported: \(reason)"
        case .conflict(let message):
            "Remote state changed. \(message)"
        case .invalidRequest(let message):
            "Invalid request. \(message)"
        }
    }
}
