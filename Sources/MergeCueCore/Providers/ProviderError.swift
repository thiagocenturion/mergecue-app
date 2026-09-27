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

    /// Earliest time a retry makes sense for rate limits, relative to `now`. `retryAfter` wins over `resetAt`;
    /// negative, NaN or absurd (> 1 day) delays from hostile headers are clamped to 0…86 400 s.
    public func retryDate(now: Date) -> Date? {
        guard case .rateLimited(let resetAt, let retryAfter) = self else { return nil }
        if let retryAfter {
            let seconds = retryAfter.isNaN ? 0 : min(max(0, retryAfter), 86_400)
            return now.addingTimeInterval(seconds)
        }
        return resetAt
    }

    /// User-facing description. Provider-supplied messages are run through `SecretRedactor` (they may echo request
    /// headers or URLs).
    public var errorDescription: String? {
        let text: String = switch self {
        case .unauthorized(let message):
            "Authentication failed. Reconnect the account. \(message)"
        case .forbidden(let scope, let message):
            if let scope { "Permission denied (missing scope \(scope)). \(message)" } else { "Permission denied. \(message)" }
        case .notFound(let message):
            "Not found. \(message)"
        case .rateLimited(let resetAt, let retryAfter):
            if let retryAfter, retryAfter.isFinite { "Rate limited; retry after \(Int(max(0, min(retryAfter, 86_400 * 365)).rounded(.up))) s." }
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
        return SecretRedactor.redact(text.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Shared classification (Sync, Engine account validation and UI must agree)

    /// Classifies any error thrown while talking to a provider.
    ///
    /// - `ProviderError` is returned as-is.
    /// - Cancellation (`CancellationError`, `URLError.cancelled`) is **not** a failure: returns nil, and callers
    ///   must neither record an error nor back off.
    /// - `URLError`: `timedOut` → `.timeout`; connectivity failures (no internet, lost connection, DNS/host
    ///   lookup, cannot connect, roaming/data not allowed) → `.offline`; anything else → `.server(status: 0, …)`.
    /// - `DecodingError` → `.decoding`.
    /// - Anything else → `.server(status: 0, message:)` with a redacted description.
    public static func classify(_ error: any Error) -> ProviderError? {
        if let providerError = error as? ProviderError { return providerError }
        if error is CancellationError { return nil }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .userCancelledAuthentication:
                return nil
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
                return .offline
            default:
                return .server(status: 0, message: "Network error (URLError \(urlError.code.rawValue)).")
            }
        }
        if error is DecodingError {
            return .decoding(SecretRedactor.redact(String(describing: error)))
        }
        return .server(status: 0, message: SecretRedactor.redact(error.localizedDescription))
    }
}
