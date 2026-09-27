import Foundation

/// Automatic retry settings for idempotent reads (`GET`/`HEAD`). Writes are never retried automatically.
public struct RetryPolicy: Sendable, Hashable {
    /// Total attempts including the first one (1 = no retries).
    public var maxAttempts: Int
    /// Backoff before the first retry.
    public var baseDelay: TimeInterval
    /// Upper bound for a single backoff delay.
    public var maxDelay: TimeInterval
    /// The longest `Retry-After` the client waits for; longer waits surface `ProviderError.rateLimited`
    /// immediately so the scheduler (not a suspended request) owns the wait.
    public var maxRetryAfter: TimeInterval

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval, maxRetryAfter: TimeInterval = 60) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay.isFinite ? max(0, baseDelay) : 0
        self.maxDelay = maxDelay.isFinite ? max(0, maxDelay) : 0
        self.maxRetryAfter = maxRetryAfter.isFinite ? max(0, maxRetryAfter) : 60
    }

    /// 3 attempts, 0.5 s base, 8 s cap, `Retry-After` up to 60 s.
    public static let `default` = RetryPolicy(maxAttempts: 3, baseDelay: 0.5, maxDelay: 8)

    /// A single attempt.
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)

    /// Backoff before retrying after the `attempt`-th failed attempt (1-based): exponential
    /// `baseDelay · 2^(attempt-1)` capped at `maxDelay`, with "equal jitter" — the result lies in
    /// `[capped / 2, capped]`, where `jitter` (clamped to `0...1`) picks the point.
    public func delay(forAttempt attempt: Int, jitter: Double) -> TimeInterval {
        let exponent = Double(min(max(attempt, 1) - 1, 62))
        let exponential = baseDelay * pow(2, exponent)
        let capped = min(exponential.isFinite ? exponential : maxDelay, maxDelay)
        let unit = jitter.isNaN ? 0 : min(max(jitter, 0), 1)
        return capped * (0.5 + 0.5 * unit)
    }
}
