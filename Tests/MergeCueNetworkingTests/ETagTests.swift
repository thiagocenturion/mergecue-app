import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

@Suite("ETag conditional requests")
struct ETagTests {
    private static let pullsURL = URL(staticString: "https://api.github.com/repos/acme/api/pulls")

    /// Serves `200` + ETag, or `304` when `If-None-Match` matches.
    private static func conditionalRoute(etag: String, body: String) -> StubTransport.Route {
        StubTransport.Route(method: "GET", pathPattern: "/repos/{owner}/{repo}/pulls") { request, _ in
            if request.header("If-None-Match") == etag {
                return StubTransport.empty(status: 304, headers: [
                    "ETag": etag, "X-RateLimit-Remaining": "4990", "Content-Length": "0",
                ])
            }
            return StubTransport.json(body, headers: [
                "ETag": etag,
                "Link": #"<https://api.github.com/repos/acme/api/pulls?page=2>; rel="next""#,
                "X-RateLimit-Remaining": "4991",
                "Content-Length": "\(body.utf8.count)",
            ])
        }
    }

    @Test func notModifiedReturnsTheCachedBodyAsAHit() async throws {
        let stub = StubTransport(routes: [Self.conditionalRoute(etag: #"W/"abc""#, body: "[42]")], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)

        let first = try await client.get("/repos/acme/api/pulls", useETag: true)
        #expect(first.status == 200)
        #expect(!first.isCacheHit)
        #expect(stub.requests.first?.header("If-None-Match") == nil)

        let second = try await client.get("/repos/acme/api/pulls", useETag: true)
        #expect(stub.requests.last?.header("If-None-Match") == #"W/"abc""#)
        #expect(second.status == 200)
        #expect(second.header(HTTPHeaders.cacheStatus) == "hit")
        #expect(second.isCacheHit)
        #expect(second.bodyText == "[42]")
        #expect(second.header("content-length") == "4", "the 304's own Content-Length does not replace the cached one")
        #expect(Pagination.nextLink(from: second)?.absoluteString == "https://api.github.com/repos/acme/api/pulls?page=2",
                "the cached Link header survives the 304")
        #expect(await client.lastRateLimit?.remaining == 4990, "rate-limit headers of the 304 are tracked")

        let decoded = try await client.getJSON([Int].self, "/repos/acme/api/pulls", useETag: true)
        #expect(decoded == [42])
    }

    @Test func etagsAreOnlySentWhenRequested() async throws {
        let stub = StubTransport(routes: [Self.conditionalRoute(etag: "\"v1\"", body: "[]")], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)
        _ = try await client.get("/repos/acme/api/pulls", useETag: true)
        let plain = try await client.get("/repos/acme/api/pulls")
        #expect(stub.requests.last?.header("If-None-Match") == nil)
        #expect(!plain.isCacheHit)
    }

    @Test func changedRepresentationReplacesTheCacheEntry() async throws {
        let cache = ETagCache()
        let stub = StubTransport(routes: [Self.conditionalRoute(etag: "\"v1\"", body: "[1]")], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, etagCache: cache)
        _ = try await client.get("/repos/acme/api/pulls", useETag: true)
        stub.add(Self.conditionalRoute(etag: "\"v2\"", body: "[1,2]"))
        let changed = try await client.get("/repos/acme/api/pulls", useETag: true)
        #expect(changed.bodyText == "[1,2]")
        #expect(!changed.isCacheHit)
        #expect(await cache.get(Self.pullsURL)?.etag == "\"v2\"")
    }

    @Test func responsesWithoutAnETagEvictTheEntry() async throws {
        let cache = ETagCache()
        await cache.set(Self.pullsURL, etag: "\"old\"", body: Data("[0]".utf8))
        let stub = StubTransport(routes: [.getJSON("/repos/acme/api/pulls", "[9]")], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, etagCache: cache)
        let response = try await client.get("/repos/acme/api/pulls", useETag: true)
        #expect(response.bodyText == "[9]")
        #expect(await cache.get(Self.pullsURL) == nil)
    }

    @Test func notModifiedWithoutACachedEntryIsReturnedAsIs() async throws {
        let stub = StubTransport(routes: [.fixed("GET", "/x", response: StubTransport.empty(status: 304))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, etagCache: nil)
        let response = try await client.get("/x", headers: ["If-None-Match": "\"mine\""], useETag: true)
        #expect(response.status == 304)
        #expect(stub.requests.first?.header("If-None-Match") == "\"mine\"")
    }

    @Test func writesNeverUseTheCache() async throws {
        let cache = ETagCache()
        let url = URL(staticString: "https://api.github.com/repos/acme/api/pulls")
        await cache.set(url, etag: "\"v1\"", body: Data("[]".utf8))
        let stub = StubTransport(routes: [.fixed("POST", "/repos/acme/api/pulls", response: StubTransport.json("{}", status: 201, headers: ["ETag": "\"new\""]))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, etagCache: cache)
        _ = try await client.send("POST", "/repos/acme/api/pulls", json: ["title": "x"])
        #expect(stub.requests.first?.header("If-None-Match") == nil)
        #expect(await cache.get(url)?.etag == "\"v1\"")
    }

    // MARK: Cache bounds

    @Test func lruEvictsTheLeastRecentlyUsedEntry() async throws {
        let cache = ETagCache(capacity: 2)
        let a = try #require(URL(string: "https://x.test/a"))
        let b = try #require(URL(string: "https://x.test/b"))
        let c = try #require(URL(string: "https://x.test/c"))
        await cache.set(a, etag: "a", body: Data("1".utf8))
        await cache.set(b, etag: "b", body: Data("2".utf8))
        _ = await cache.get(a)  // a is now more recent than b
        await cache.set(c, etag: "c", body: Data("3".utf8))
        #expect(await cache.count == 2)
        #expect(await cache.get(a)?.etag == "a")
        #expect(await cache.get(b) == nil)
        #expect(await cache.get(c)?.etag == "c")
    }

    @Test func byteBudgetIsEnforced() async throws {
        let cache = ETagCache(capacity: 10, maxTotalBytes: 10)
        let a = try #require(URL(string: "https://x.test/a"))
        let b = try #require(URL(string: "https://x.test/b"))
        let big = try #require(URL(string: "https://x.test/big"))
        await cache.set(a, etag: "a", body: Data(repeating: 1, count: 6))
        await cache.set(b, etag: "b", body: Data(repeating: 2, count: 6))
        #expect(await cache.get(a) == nil, "evicted to stay within 10 bytes")
        #expect(await cache.byteCount == 6)
        await cache.set(big, etag: "x", body: Data(repeating: 3, count: 11))
        #expect(await cache.get(big) == nil, "bodies larger than the budget are not cached")
        #expect(await cache.byteCount == 6)
        await cache.set(b, etag: "b2", body: Data(repeating: 2, count: 2))
        #expect(await cache.byteCount == 2, "replacing an entry updates the byte count")
        await cache.removeAll()
        #expect(await cache.count == 0)
        #expect(await cache.byteCount == 0)
    }
}
