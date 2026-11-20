import Foundation
import MergeCueCore
import MergeCueNetworking

/// Bitbucket Cloud rate-limit headers: `X-RateLimit-Limit` (requests per rolling hour) and
/// `X-RateLimit-NearLimit` (`true` once fewer than 20 % are left), plus `Retry-After` when present (Bitbucket does
/// not document one for 429). The rolling hour has no reset time, so `resetAt` stays nil; near the limit
/// `remaining` is reported as the 20 % threshold. The proactive slowdown itself is driven by
/// `ProviderRequestLedger.recordNearLimit` (see `CountingTransport`, DECISIONS D36).
public struct BitbucketRateLimitParser: RateLimitParsing {
    public init() {}

    public func parse(_ response: HTTPResponse) -> RateLimitInfo? {
        let limit = RateLimitHeaderParsing.integer(response.header("x-ratelimit-limit"))
        let nearLimit = response.header("x-ratelimit-nearlimit")?.lowercased() == "true"
        let info = RateLimitInfo(
            limit: limit,
            remaining: nearLimit ? limit.map { $0 / 5 } : nil,
            resetAt: nil,
            retryAfter: RateLimitHeaderParsing.retryAfter(in: response)
        )
        return info == RateLimitInfo() ? nil : info
    }
}
