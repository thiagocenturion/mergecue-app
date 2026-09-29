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
}
