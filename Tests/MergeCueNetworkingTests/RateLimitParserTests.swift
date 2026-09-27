import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

@Suite("Rate-limit parsers")
struct RateLimitParserTests {
    private let serverDate = "Thu, 01 Jan 2026 00:00:00 GMT"

    @Test func gitHubHeaders() throws {
        let response = NetFixture.response(200, headers: [
            "X-RateLimit-Limit": "5000",
            "X-RateLimit-Remaining": "4987",
            "X-RateLimit-Reset": "1767229200",
            "X-RateLimit-Used": "13",
            "X-RateLimit-Resource": "core",
        ])
        let info = try #require(GitHubRateLimitParser().parse(response))
        #expect(info == RateLimitInfo(limit: 5000, remaining: 4987, resetAt: Date(timeIntervalSince1970: 1_767_229_200)))
        #expect(!info.isExhausted)
    }

    @Test func gitHubExhaustedWithRetryAfter() throws {
        let response = NetFixture.response(403, headers: ["x-ratelimit-remaining": "0", "retry-after": "60"])
        let info = try #require(GitHubRateLimitParser().parse(response))
        #expect(info.isExhausted)
        #expect(info.retryAfter == 60)
        #expect(info.limit == nil)
    }

    @Test func gitLabHeaders() throws {
        let response = NetFixture.response(200, headers: [
            "RateLimit-Limit": "2000",
            "RateLimit-Remaining": "1999",
            "RateLimit-Observed": "1",
            "RateLimit-Reset": "1767229200",
            "RateLimit-ResetTime": "Thu, 01 Jan 2026 01:00:00 GMT",
        ])
        let info = try #require(GitLabRateLimitParser().parse(response))
        #expect(info == RateLimitInfo(limit: 2000, remaining: 1999, resetAt: Date(timeIntervalSince1970: 1_767_229_200)))
    }

    @Test func gitLabResetTimeAndDeltaReset() throws {
        let resetTimeOnly = NetFixture.response(429, headers: ["RateLimit-ResetTime": "Thu, 01 Jan 2026 01:00:00 GMT", "Retry-After": "3600"])
        let first = try #require(GitLabRateLimitParser().parse(resetTimeOnly))
        #expect(first.resetAt == Date(timeIntervalSince1970: 1_767_229_200))
        #expect(first.retryAfter == 3600)

        let delta = NetFixture.response(429, headers: ["RateLimit-Reset": "30", "Date": serverDate])
        #expect(GitLabRateLimitParser().parse(delta)?.resetAt == NetFixture.date.addingTimeInterval(30))
    }

    @Test func genericParserReadsOnlyRetryAfter() throws {
        #expect(GenericRateLimitParser().parse(NetFixture.response(429, headers: ["X-RateLimit-Remaining": "0"])) == nil)
        #expect(GenericRateLimitParser().parse(NetFixture.response(429, headers: ["Retry-After": "7"])) == RateLimitInfo(retryAfter: 7))
        let dated = NetFixture.response(503, headers: ["Retry-After": "Thu, 01 Jan 2026 00:02:00 GMT", "Date": serverDate])
        #expect(GenericRateLimitParser().parse(dated)?.retryAfter == 120)
        let past = NetFixture.response(503, headers: ["Retry-After": "Wed, 31 Dec 2025 23:00:00 GMT", "Date": serverDate])
        #expect(GenericRateLimitParser().parse(past)?.retryAfter == 0)
    }

    @Test func responsesWithoutHeadersYieldNil() {
        let plain = NetFixture.response(200, headers: ["Content-Type": "application/json"])
        #expect(GitHubRateLimitParser().parse(plain) == nil)
        #expect(GitLabRateLimitParser().parse(plain) == nil)
        #expect(GenericRateLimitParser().parse(plain) == nil)
    }

    @Test(arguments: ["-5", "abc", "1e9", "NaN", "inf", " ", "99999999999999999999999"])
    func hostileValuesAreIgnored(value: String) {
        let response = NetFixture.response(403, headers: [
            "X-RateLimit-Remaining": value, "X-RateLimit-Reset": value, "X-RateLimit-Limit": value, "Retry-After": value,
        ])
        let info = GitHubRateLimitParser().parse(response)
        #expect(info?.remaining == nil)
        #expect(info?.limit == nil)
        #expect(info?.resetAt == nil)
        if let retryAfter = info?.retryAfter {
            #expect(retryAfter.isFinite && retryAfter >= 0)
        }
    }

    @Test func epochResetBeyond2100IsIgnored() {
        #expect(RateLimitHeaderParsing.epochDate("4102444800") != nil)
        #expect(RateLimitHeaderParsing.epochDate("4102444801") == nil)
    }

    @Test func httpDateFormats() {
        let expected = Date(timeIntervalSince1970: 784_111_777)
        #expect(RateLimitHeaderParsing.httpDate("Sun, 06 Nov 1994 08:49:37 GMT") == expected)
        #expect(RateLimitHeaderParsing.httpDate("Sunday, 06-Nov-94 08:49:37 GMT") == expected)
        #expect(RateLimitHeaderParsing.httpDate("Sun Nov  6 08:49:37 1994") == expected)
        #expect(RateLimitHeaderParsing.httpDate("not a date") == nil)
    }

    @Test func clientTracksTheLastRateLimit() async throws {
        let stub = StubTransport(
            routes: [
                .getJSON("/user", "{}", headers: ["X-RateLimit-Limit": "5000", "X-RateLimit-Remaining": "4999", "X-RateLimit-Reset": "1767229200"]),
                .getJSON("/meta", "{}"),
            ],
            baseURL: NetFixture.githubAPI
        )
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)
        #expect(await client.lastRateLimit == nil)
        _ = try await client.get("/user")
        #expect(await client.lastRateLimit?.remaining == 4999)
        _ = try await client.get("/meta")
        #expect(await client.lastRateLimit?.remaining == 4999, "responses without headers keep the last known value")
    }
}
