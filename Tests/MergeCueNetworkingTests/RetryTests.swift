import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

/// Retry behaviour, driven entirely by `TestClock` (no real sleeping).
@Suite("Retries and backoff")
struct RetryTests {
    // MARK: Policy arithmetic

    @Test func exponentialBackoffWithEqualJitter() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 8)
        #expect(policy.delay(forAttempt: 1, jitter: 1) == 1)
        #expect(policy.delay(forAttempt: 2, jitter: 1) == 2)
        #expect(policy.delay(forAttempt: 3, jitter: 1) == 4)
        #expect(policy.delay(forAttempt: 4, jitter: 1) == 8)
        #expect(policy.delay(forAttempt: 9, jitter: 1) == 8, "capped at maxDelay")
        #expect(policy.delay(forAttempt: 3, jitter: 0) == 2, "jitter never drops below half the backoff")
        #expect(policy.delay(forAttempt: 3, jitter: 0.5) == 3)
    }

    @Test func hostileInputsAreClamped() {
        let policy = RetryPolicy(maxAttempts: 0, baseDelay: -1, maxDelay: .infinity, maxRetryAfter: .nan)
        #expect(policy.maxAttempts == 1)
        #expect(policy.baseDelay == 0)
        #expect(policy.maxDelay == 0)
        #expect(policy.maxRetryAfter == 60)
        let normal = RetryPolicy.default
        #expect(normal.delay(forAttempt: 0, jitter: .nan) == normal.baseDelay / 2)
        #expect(normal.delay(forAttempt: Int.max, jitter: 7) == normal.maxDelay)
        #expect(normal.delay(forAttempt: -3, jitter: -1) == normal.baseDelay / 2)
    }

    @Test func defaultPolicy() {
        #expect(RetryPolicy.default.maxAttempts == 3)
        #expect(RetryPolicy.default.maxRetryAfter == 60)
        #expect(RetryPolicy.none.maxAttempts == 1)
    }

    // MARK: Client behaviour

    @Test func getRetries5xxWithBackoffThenSucceeds() async throws {
        let clock = TestClock()
        let stub = StubTransport(
            routes: [.sequence("GET", "/projects", responses: [
                StubTransport.json(#"{"message":"boom"}"#, status: 500),
                StubTransport.empty(status: 503),
                StubTransport.json("[1]"),
            ])],
            baseURL: NetFixture.gitlabAPI
        )
        let client = NetFixture.client(transport: stub, clock: clock)
        let task = Task { try await client.get("/projects") }

        #expect(await clock.advanceNextSleeper() == 1, "first backoff = baseDelay")
        #expect(await clock.advanceNextSleeper() == 2, "second backoff doubles")
        let response = try await task.value
        #expect(response.status == 200)
        #expect(stub.requests.count == 3)
        #expect(clock.now == NetFixture.date.addingTimeInterval(3))
    }

    @Test func getGivesUpAfterMaxAttempts() async throws {
        let clock = TestClock()
        let stub = StubTransport(routes: [.fixed("GET", "/projects", response: StubTransport.json(#"{"message":"down"}"#, status: 502))], baseURL: NetFixture.gitlabAPI)
        let client = NetFixture.client(transport: stub, clock: clock)
        let task = Task { try await client.get("/projects") }
        _ = await clock.advanceNextSleeper()
        _ = await clock.advanceNextSleeper()
        await #expect(throws: ProviderError.server(status: 502, message: "down")) { try await task.value }
        #expect(stub.requests.count == 3)
        #expect(clock.pendingSleeperCount == 0)
    }

    @Test(arguments: [URLError.Code.timedOut, .notConnectedToInternet, .networkConnectionLost])
    func getRetriesTimeoutsAndOffline(code: URLError.Code) async throws {
        let clock = TestClock()
        let stub = StubTransport(routes: [.failing("GET", "/user", error: URLError(code))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, clock: clock)
        let task = Task { try await client.get("/user") }
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines == [NetFixture.date.addingTimeInterval(1)])
        // The network comes back before the retry fires (a later route of equal specificity wins).
        stub.add(.getJSON("/user", #"{"login":"mona-dev"}"#))
        clock.advance(by: 1)
        let response = try await task.value
        #expect(response.status == 200)
        #expect(stub.requests.count == 2)
    }

    @Test func offlineGetEventuallyThrowsOffline() async throws {
        let clock = TestClock()
        let stub = StubTransport(routes: [.failing("GET", "/user", error: URLError(.notConnectedToInternet))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, clock: clock)
        let task = Task { try await client.get("/user") }
        _ = await clock.advanceNextSleeper()
        _ = await clock.advanceNextSleeper()
        await #expect(throws: ProviderError.offline) { try await task.value }
        #expect(stub.requests.count == 3)
    }

    @Test(arguments: ["POST", "PUT", "PATCH", "DELETE"])
    func writesAreNeverRetried(method: String) async throws {
        let clock = TestClock()
        let stub = StubTransport(
            routes: [
                .fixed(method, "/projects/1/notes", response: StubTransport.json(#"{"message":"oops"}"#, status: 503)),
                .failing(method, "/projects/1/offline", error: URLError(.timedOut)),
                .fixed(method, "/projects/1/limited", response: StubTransport.empty(status: 429, headers: ["Retry-After": "1"])),
            ],
            baseURL: NetFixture.gitlabAPI
        )
        let client = NetFixture.client(transport: stub, clock: clock)
        await #expect(throws: ProviderError.server(status: 503, message: "oops")) {
            try await client.send(method, "/projects/1/notes", json: ["body": "hi"])
        }
        await #expect(throws: ProviderError.timeout) {
            try await client.send(method, "/projects/1/offline", json: nil)
        }
        await #expect(throws: ProviderError.rateLimited(resetAt: nil, retryAfter: 1)) {
            try await client.send(method, "/projects/1/limited", json: nil)
        }
        #expect(stub.requests.count == 3)
        #expect(clock.pendingSleeperCount == 0)
        #expect(clock.now == NetFixture.date, "no time passed")
    }

    @Test func clientErrorsAreNotRetried() async throws {
        let clock = TestClock()
        let stub = StubTransport(baseURL: NetFixture.gitlabAPI)
        let client = NetFixture.client(transport: stub, clock: clock)
        await #expect(throws: ProviderError.self) { try await client.get("/missing") }
        #expect(stub.requests.count == 1)
    }

    @Test func shortRetryAfterIsHonouredExactly() async throws {
        let clock = TestClock()
        let stub = StubTransport(
            routes: [.sequence("GET", "/search/issues", responses: [
                StubTransport.json(#"{"message":"slow down"}"#, status: 429, headers: ["Retry-After": "30"]),
                StubTransport.json("{}"),
            ])],
            baseURL: NetFixture.githubAPI
        )
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, clock: clock)
        let task = Task { try await client.get("/search/issues") }
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingDeadlines == [NetFixture.date.addingTimeInterval(30)])
        clock.advance(by: 30)
        #expect(try await task.value.status == 200)
        #expect(stub.requests.count == 2)
    }

    @Test func secondaryRateLimit403WithShortRetryAfterIsRetried() async throws {
        let clock = TestClock()
        let stub = StubTransport(
            routes: [.sequence("GET", "/user", responses: [
                StubTransport.json(#"{"message":"You have exceeded a secondary rate limit."}"#, status: 403, headers: ["Retry-After": "5"]),
                StubTransport.json("{}"),
            ])],
            baseURL: NetFixture.githubAPI
        )
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, clock: clock)
        let task = Task { try await client.get("/user") }
        #expect(await clock.advanceNextSleeper() == 5)
        #expect(try await task.value.status == 200)
    }

    @Test func longRetryAfterSurfacesRateLimitedWithoutSleeping() async throws {
        let clock = TestClock()
        let stub = StubTransport(
            routes: [
                .fixed("GET", "/limited", response: StubTransport.empty(status: 429, headers: ["Retry-After": "61"])),
                .fixed("GET", "/maintenance", response: StubTransport.empty(status: 503, headers: ["Retry-After": "120"])),
                .fixed("GET", "/primary", response: StubTransport.json(
                    #"{"message":"API rate limit exceeded"}"#,
                    status: 403,
                    headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1767229200"]
                )),
            ],
            baseURL: NetFixture.githubAPI
        )
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, clock: clock)
        await #expect(throws: ProviderError.rateLimited(resetAt: nil, retryAfter: 61)) { try await client.get("/limited") }
        await #expect(throws: ProviderError.rateLimited(resetAt: NetFixture.date.addingTimeInterval(120), retryAfter: 120)) {
            try await client.get("/maintenance")
        }
        await #expect(throws: ProviderError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_767_229_200), retryAfter: nil)) {
            try await client.get("/primary")
        }
        #expect(stub.requests.count == 3, "one attempt each")
        #expect(clock.pendingSleeperCount == 0)
        #expect(await client.lastRateLimit?.remaining == 0)
    }

    @Test func retryAfterOn5xxReplacesTheBackoff() async throws {
        let clock = TestClock()
        let stub = StubTransport(
            routes: [.sequence("GET", "/x", responses: [
                StubTransport.empty(status: 503, headers: ["Retry-After": "10"]),
                StubTransport.json("{}"),
            ])],
            baseURL: NetFixture.githubAPI
        )
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, clock: clock)
        let task = Task { try await client.get("/x") }
        #expect(await clock.advanceNextSleeper() == 10)
        #expect(try await task.value.status == 200)
    }

    @Test func customMaxRetryAfterIsRespected() async throws {
        let clock = TestClock()
        let stub = StubTransport(
            routes: [.fixed("GET", "/x", response: StubTransport.empty(status: 429, headers: ["Retry-After": "20"]))],
            baseURL: NetFixture.githubAPI
        )
        let client = NetFixture.client(
            baseURL: NetFixture.githubAPI,
            transport: stub,
            retry: RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 8, maxRetryAfter: 10),
            clock: clock
        )
        await #expect(throws: ProviderError.rateLimited(resetAt: nil, retryAfter: 20)) { try await client.get("/x") }
        #expect(stub.requests.count == 1)
    }

    @Test func cancellationDuringBackoffThrowsCancellationError() async throws {
        let clock = TestClock()
        let stub = StubTransport(routes: [.fixed("GET", "/x", response: StubTransport.empty(status: 500))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, clock: clock)
        let task = Task { try await client.get("/x") }
        await clock.waitForSleepers(count: 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(stub.requests.count == 1)
    }

    @Test func transportCancellationIsNotReportedAsFailure() async throws {
        let stub = StubTransport(routes: [.failing("GET", "/x", error: URLError(.cancelled))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)
        await #expect(throws: CancellationError.self) { try await client.get("/x") }
        #expect(stub.requests.count == 1)
    }

    @Test func noRetryPolicyMakesOneAttempt() async throws {
        let stub = StubTransport(routes: [.fixed("GET", "/x", response: StubTransport.empty(status: 500))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, retry: .none)
        await #expect(throws: ProviderError.self) { try await client.get("/x") }
        #expect(stub.requests.count == 1)
    }
}
