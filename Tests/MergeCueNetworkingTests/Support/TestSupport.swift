import Foundation
import MergeCueCore
@testable import MergeCueNetworking

/// Shared deterministic values for the networking tests.
enum NetFixture {
    /// 2026-01-01T00:00:00Z (the `TestClock` default).
    static let date = Date(timeIntervalSince1970: 1_767_225_600)

    static let githubAPI = URL(staticString: "https://api.github.com")
    static let gitlabAPI = URL(staticString: "https://gitlab.com/api/v4")
    static let bitbucketAPI = URL(staticString: "https://api.bitbucket.org/2.0")

    /// An opaque token that `SecretRedactor` cannot recognize by shape — only the client's scrubbing hides it.
    static let opaqueToken = "opaque-Secret-Value-9f8e7d6c5b4a"
    static let credential = Credential.bearer(opaqueToken)

    static let account = AccountKey(kind: .github, host: "github.com", remoteUserID: "123")

    static func client(
        baseURL: URL = gitlabAPI,
        transport: any HTTPTransport,
        credential: Credential = credential,
        parser: any RateLimitParsing = GitHubRateLimitParser(),
        retry: RetryPolicy = RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 8),
        etagCache: ETagCache? = ETagCache(),
        clock: any MCClock = TestClock(),
        extraHeaders: [String: String] = [:],
        jitter: Double = 1
    ) -> APIClient {
        APIClient(
            baseURL: baseURL,
            credential: credential,
            transport: transport,
            rateLimitParser: parser,
            retry: retry,
            etagCache: etagCache,
            clock: clock,
            extraHeaders: extraHeaders,
            jitter: { jitter }
        )
    }

    static func response(
        _ status: Int,
        headers: [String: String] = [:],
        body: String = "",
        url: URL = URL(staticString: "https://api.github.com/x")
    ) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(body.utf8), url: url)
    }
}

/// Waits (without real time) until `task` is suspended in the clock or finished, then advances.
extension TestClock {
    /// Waits for one sleeper, asserts nothing, and advances by its full delay.
    func advanceNextSleeper() async -> TimeInterval? {
        await waitForSleepers(count: 1)
        guard let deadline = pendingDeadlines.first else { return nil }
        let delay = deadline.timeIntervalSince(now)
        advance(to: deadline)
        return delay
    }
}

struct Repo: Codable, Sendable, Equatable {
    var id: Int
    var name: String
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name
        case updatedAt = "updated_at"
    }
}
