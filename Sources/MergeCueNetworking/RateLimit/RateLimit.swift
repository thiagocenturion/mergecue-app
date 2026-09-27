import Foundation

/// Rate-limit state reported by a provider response.
public struct RateLimitInfo: Sendable, Hashable, Codable {
    /// Requests allowed per window.
    public var limit: Int?
    /// Requests left in the current window.
    public var remaining: Int?
    /// When the window resets.
    public var resetAt: Date?
    /// Seconds to wait before retrying (`Retry-After`).
    public var retryAfter: TimeInterval?

    public init(limit: Int? = nil, remaining: Int? = nil, resetAt: Date? = nil, retryAfter: TimeInterval? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
        self.retryAfter = retryAfter
    }

    /// The window is used up (`remaining == 0`).
    public var isExhausted: Bool { remaining == 0 }
}

/// Extracts rate-limit information from a response. Returns nil when the response carries none.
public protocol RateLimitParsing: Sendable {
    func parse(_ response: HTTPResponse) -> RateLimitInfo?
}

/// GitHub REST/GraphQL: `x-ratelimit-limit`, `x-ratelimit-remaining`, `x-ratelimit-reset` (epoch seconds) and
/// `retry-after` (secondary limits).
public struct GitHubRateLimitParser: RateLimitParsing {
    public init() {}

    public func parse(_ response: HTTPResponse) -> RateLimitInfo? {
        let info = RateLimitInfo(
            limit: RateLimitHeaderParsing.integer(response.header("x-ratelimit-limit")),
            remaining: RateLimitHeaderParsing.integer(response.header("x-ratelimit-remaining")),
            resetAt: RateLimitHeaderParsing.epochDate(response.header("x-ratelimit-reset")),
            retryAfter: RateLimitHeaderParsing.retryAfter(in: response)
        )
        return info == RateLimitInfo() ? nil : info
    }
}

/// GitLab: `ratelimit-limit`, `ratelimit-remaining`, `ratelimit-reset` (epoch seconds; small values are treated
/// as a delta), `ratelimit-resettime` (HTTP date) and `retry-after`.
public struct GitLabRateLimitParser: RateLimitParsing {
    public init() {}

    public func parse(_ response: HTTPResponse) -> RateLimitInfo? {
        var resetAt: Date?
        if let reset = response.header("ratelimit-reset").flatMap(RateLimitHeaderParsing.integer) {
            if reset >= RateLimitHeaderParsing.epochThreshold {
                resetAt = RateLimitHeaderParsing.epochDate(String(reset))
            } else {
                resetAt = RateLimitHeaderParsing.responseDate(response).addingTimeInterval(TimeInterval(reset))
            }
        }
        if resetAt == nil, let text = response.header("ratelimit-resettime") {
            resetAt = RateLimitHeaderParsing.httpDate(text)
        }
        let info = RateLimitInfo(
            limit: RateLimitHeaderParsing.integer(response.header("ratelimit-limit")),
            remaining: RateLimitHeaderParsing.integer(response.header("ratelimit-remaining")),
            resetAt: resetAt,
            retryAfter: RateLimitHeaderParsing.retryAfter(in: response)
        )
        return info == RateLimitInfo() ? nil : info
    }
}

/// Only `Retry-After` (delta seconds or HTTP date). Used for Bitbucket Cloud and unknown servers.
public struct GenericRateLimitParser: RateLimitParsing {
    public init() {}

    public func parse(_ response: HTTPResponse) -> RateLimitInfo? {
        guard let retryAfter = RateLimitHeaderParsing.retryAfter(in: response) else { return nil }
        return RateLimitInfo(retryAfter: retryAfter)
    }
}

/// Defensive header parsing: hostile or malformed values yield nil instead of absurd dates or traps.
public enum RateLimitHeaderParsing {
    /// Values at or above this are epoch seconds (2001-09-09); smaller reset values are deltas.
    static let epochThreshold = 1_000_000_000
    /// Latest accepted epoch value (2100-01-01).
    static let maxEpoch = 4_102_444_800

    /// A non-negative decimal integer, or nil.
    public static func integer(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.count <= 18,
              text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return Int(text)
    }

    /// Epoch seconds between 1970 and 2100 as a date.
    public static func epochDate(_ text: String?) -> Date? {
        guard let value = integer(text), value <= maxEpoch else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    /// `Retry-After` in seconds: delta seconds (fractions tolerated) or an HTTP date relative to the response's
    /// `Date` header (or the current time). Negative, non-finite or unparsable values yield nil; past dates yield 0.
    public static func retryAfter(in response: HTTPResponse) -> TimeInterval? {
        guard let text = response.header("retry-after")?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        if let seconds = Double(text) {
            guard seconds.isFinite, seconds >= 0 else { return nil }
            return seconds
        }
        guard let date = httpDate(text) else { return nil }
        return max(0, date.timeIntervalSince(responseDate(response)))
    }

    /// The response's `Date` header, or now.
    public static func responseDate(_ response: HTTPResponse) -> Date {
        response.header("date").flatMap(httpDate) ?? Date()
    }

    /// Parses IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), RFC 850 and asctime dates.
    public static func httpDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}
