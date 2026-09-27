import Foundation
import MergeCueCore
import Testing

private struct SomeUnknownError: Error, LocalizedError {
    var errorDescription: String? { "boom with token=abc123secret" }
}

@Suite("ProviderError classification")
struct ProviderErrorTests {
    static let now = Fixture.date

    @Test(arguments: [
        (ProviderError.unauthorized("revoked"), AccountSyncState.authExpired),
        (.forbidden(missingScope: "read_api", message: "403"), .permissionDenied("missing scope read_api")),
        (.forbidden(missingScope: nil, message: "Resource not accessible"), .permissionDenied("Resource not accessible")),
        (.rateLimited(resetAt: nil, retryAfter: 60), .rateLimited(until: ProviderErrorTests.now.addingTimeInterval(60))),
        (.rateLimited(resetAt: ProviderErrorTests.now.addingTimeInterval(900), retryAfter: nil), .rateLimited(until: ProviderErrorTests.now.addingTimeInterval(900))),
        (.rateLimited(resetAt: nil, retryAfter: nil), .rateLimited(until: nil)),
        (.offline, .offline),
        (.timeout, .offline),
        (.server(status: 502, message: "Bad gateway"), .error("Provider error 502. Bad gateway")),
        (.notFound("PR 42"), .error("Not found. PR 42")),
    ])
    func syncStateMapping(_ error: ProviderError, expected: AccountSyncState) {
        #expect(AccountSyncState(providerError: error, now: Self.now) == expected)
    }

    @Test func hostileRetryAfterIsClamped() {
        let now = Self.now
        #expect(ProviderError.rateLimited(resetAt: nil, retryAfter: .infinity).retryDate(now: now) == now.addingTimeInterval(86_400))
        #expect(ProviderError.rateLimited(resetAt: nil, retryAfter: .nan).retryDate(now: now) == now)
        #expect(ProviderError.rateLimited(resetAt: nil, retryAfter: -5).retryDate(now: now) == now)
        #expect(ProviderError.rateLimited(resetAt: nil, retryAfter: .infinity).errorDescription == "Rate limited.")
        #expect(ProviderError.offline.retryDate(now: now) == nil)
    }

    @Test func taskErrorInfoMapping() {
        let info = TaskErrorInfo(providerError: .conflict("head moved to abc"), at: Self.now)
        #expect(info.code == "conflict")
        #expect(info.message == "Remote state changed. head moved to abc")
        #expect(!info.retryable)
        #expect(info.at == Self.now)
        #expect(TaskErrorInfo(providerError: .timeout, at: Self.now).retryable)
    }

    @Test func descriptionsRedactProviderMessages() {
        let errors: [ProviderError] = [
            .unauthorized("Bad credentials for Authorization: Bearer ghp_1234567890abcdefghijABCDEF"),
            .server(status: 500, message: "upstream https://x:hunter2secret@internal.example/api failed"),
            .decoding("unexpected body {\"token\": \"s3cr3t-value\"}"),
            .forbidden(missingScope: nil, message: "PRIVATE-TOKEN: glpat-abcdefghijklmnopqrst rejected"),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            #expect(text.contains(SecretRedactor.marker), "\(text)")
            #expect(!text.contains("1234567890abcdef") && !text.contains("hunter2secret") && !text.contains("s3cr3t-value")
                && !text.contains("abcdefghijklmnopqrst"), "\(text)")
        }
        #expect(AccountSyncState(providerError: errors[1], now: Self.now).displayText.contains(SecretRedactor.marker))
        #expect(ProviderError.offline.errorDescription == "Offline.")
    }

    @Test func classifyPassesProviderErrorsThrough() {
        #expect(ProviderError.classify(ProviderError.notFound("x")) == .notFound("x"))
    }

    @Test func cancellationIsNotAFailure() {
        #expect(ProviderError.classify(CancellationError()) == nil)
        #expect(ProviderError.classify(URLError(.cancelled)) == nil)
    }

    @Test(arguments: [
        (URLError.Code.timedOut, ProviderError.timeout),
        (.notConnectedToInternet, .offline),
        (.networkConnectionLost, .offline),
        (.cannotFindHost, .offline),
        (.cannotConnectToHost, .offline),
        (.dnsLookupFailed, .offline),
    ])
    func transportErrors(_ code: URLError.Code, expected: ProviderError) {
        #expect(ProviderError.classify(URLError(code)) == expected)
    }

    @Test func otherErrorsBecomeRedactedServerErrors() {
        guard case .server(let status, let message)? = ProviderError.classify(SomeUnknownError()) else {
            Issue.record("expected .server")
            return
        }
        #expect(status == 0)
        #expect(message == "boom with token=[REDACTED]")
        guard case .server(0, _)? = ProviderError.classify(URLError(.badServerResponse)) else {
            Issue.record("expected .server(0, …)")
            return
        }
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        guard case .decoding? = ProviderError.classify(decoding) else {
            Issue.record("expected .decoding")
            return
        }
    }
}
