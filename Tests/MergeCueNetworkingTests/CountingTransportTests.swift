import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

/// Request accounting (DECISIONS D35): every response counts except `304 Not Modified`.
@Suite("Counting transport")
struct CountingTransportTests {
    @Test func notModifiedAndTransportFailuresAreNotCounted() async throws {
        let etag = #"W/"v1""#
        let stub = StubTransport(routes: [
            StubTransport.Route(method: "GET", pathPattern: "/repos/{owner}/{repo}/pulls") { request, _ in
                if request.header("If-None-Match") == etag { return StubTransport.empty(status: 304, headers: ["ETag": etag]) }
                return StubTransport.json("[1]", headers: ["ETag": etag])
            },
            StubTransport.Route(method: "GET", pathPattern: "/rate") { _, _ in
                StubTransport.json(#"{"message":"API rate limit exceeded"}"#, status: 429, headers: ["Retry-After": "3600"])
            },
        ], baseURL: NetFixture.githubAPI)
        let clock = TestClock()
        let ledger = ProviderRequestLedger()
        let account = AccountKey(instance: .githubCom, remoteUserID: "1")
        let counted = CountingTransport(stub, ledger: ledger, account: account, clock: clock)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: counted)

        _ = try await client.get("/repos/acme/api/pulls", useETag: true)
        #expect(ledger.count(account, now: clock.now) == 1)
        let hit = try await client.get("/repos/acme/api/pulls", useETag: true)
        #expect(hit.isCacheHit)
        #expect(stub.requests.count == 2)
        #expect(ledger.count(account, now: clock.now) == 1, "the 304 is free")
        await #expect(throws: ProviderError.self) { _ = try await client.get("/rate") }
        #expect(ledger.count(account, now: clock.now) == 2, "error responses reached the provider and count")
        #expect(ledger.count(AccountKey(instance: .githubCom, remoteUserID: "2"), now: clock.now) == 0)
    }

    @Test func redirectHopsNotModifiedForBitbucketAndNearLimitAreRecorded() async throws {
        let stub = StubTransport(routes: [
            StubTransport.Route(method: "GET", pathPattern: "/diffstat") { _, _ in
                StubTransport.json("{}", headers: [HTTPHeaders.redirectHops: "1"])
            },
            StubTransport.Route(method: "GET", pathPattern: "/same") { _, _ in StubTransport.empty(status: 304) },
            StubTransport.Route(method: "GET", pathPattern: "/near") { _, _ in
                StubTransport.json("{}", headers: ["X-RateLimit-NearLimit": "true", "X-RateLimit-Limit": "1000"])
            },
        ], baseURL: NetFixture.githubAPI)
        let clock = TestClock()
        let ledger = ProviderRequestLedger()
        let account = AccountKey(instance: .bitbucketCloud, remoteUserID: "{u}")
        let counted = CountingTransport(stub, ledger: ledger, account: account, clock: clock, countsNotModified: true)
        let url = NetFixture.githubAPI
        _ = try await counted.send(HTTPRequest(method: "GET", url: url.appending(path: "diffstat")))
        #expect(ledger.count(account, now: clock.now) == 2, "the 302 hop is a request too")
        _ = try await counted.send(HTTPRequest(method: "GET", url: url.appending(path: "same")))
        #expect(ledger.count(account, now: clock.now) == 3, "Bitbucket 304s count")
        #expect(!ledger.isNearLimit(account, now: clock.now))
        _ = try await counted.send(HTTPRequest(method: "GET", url: url.appending(path: "near")))
        #expect(ledger.isNearLimit(account, now: clock.now))
        clock.advance(by: ProviderRequestLedger.nearLimitHold)
        #expect(!ledger.isNearLimit(account, now: clock.now), "the slowdown lasts 15 minutes")
    }

    @Test func ledgerTellsWhenTheCountDropsBelowALimit() {
        let ledger = ProviderRequestLedger()
        let account = AccountKey(instance: .bitbucketCloud, remoteUserID: "{u}")
        let start = Date(timeIntervalSince1970: 1_000_000)
        for minute in 0..<10 { ledger.record(account, at: start.addingTimeInterval(TimeInterval(minute * 60))) }
        let now = start.addingTimeInterval(600)
        #expect(ledger.date(account, whenCountBelow: 20, now: now) == now)
        // Below 4 means dropping the 7 oldest: the 7th (minute 6) leaves the window an hour after it was sent.
        #expect(ledger.date(account, whenCountBelow: 4, now: now) == start.addingTimeInterval(6 * 60 + 3_600))
    }
}
