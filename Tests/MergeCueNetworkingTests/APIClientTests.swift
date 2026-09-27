import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

@Suite("API client")
struct APIClientTests {
    @Test func requestsCarryAuthorizationDefaultAcceptAndExtraHeaders() async throws {
        let stub = StubTransport(routes: [.getJSON("/user", "{}")], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(
            baseURL: NetFixture.githubAPI,
            transport: stub,
            extraHeaders: ["X-GitHub-Api-Version": "2022-11-28", "authorization": "Bearer attacker"]
        )
        _ = try await client.get("/user", headers: ["X-Request": "1", "AUTHORIZATION": "Bearer other"])
        let request = try #require(stub.requests.first)
        #expect(request.url.absoluteString == "https://api.github.com/user")
        #expect(request.method == "GET")
        #expect(request.header("Authorization") == "Bearer \(NetFixture.opaqueToken)", "the credential always wins")
        #expect(request.headers.keys.filter { $0.lowercased() == "authorization" }.count == 1)
        #expect(request.header("Accept") == "application/json")
        #expect(request.header("X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.header("x-request") == "1")
    }

    @Test func extraAcceptOverridesTheDefault() async throws {
        let stub = StubTransport(routes: [.getJSON("/user", "{}")], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, extraHeaders: ["accept": "application/vnd.github+json"])
        _ = try await client.get("/user")
        let request = try #require(stub.requests.first)
        #expect(request.header("Accept") == "application/vnd.github+json")
        #expect(request.headers.keys.filter { $0.lowercased() == "accept" }.count == 1)
    }

    @Test func basicCredentialsUseBasicAuthorization() async throws {
        let stub = StubTransport(routes: [.getJSON("/user", "{}")], baseURL: NetFixture.bitbucketAPI)
        let client = NetFixture.client(
            baseURL: NetFixture.bitbucketAPI,
            transport: stub,
            credential: .basic(username: "mona@example.com", password: "ATATT-secret"),
            parser: GenericRateLimitParser()
        )
        _ = try await client.get("/user")
        let expected = "Basic " + Data("mona@example.com:ATATT-secret".utf8).base64EncodedString()
        #expect(stub.requests.first?.header("Authorization") == expected)
    }

    @Test func getBuildsURLsUnderTheAPIPrefixWithQuery() async throws {
        let stub = StubTransport(routes: [.getJSON("/projects/{id}/merge_requests", "[]")], baseURL: NetFixture.gitlabAPI)
        let client = NetFixture.client(transport: stub, parser: GitLabRateLimitParser())
        _ = try await client.get(
            "/projects/\(RequestURLBuilder.encodePathSegment("acme/payments-api"))/merge_requests",
            query: [URLQueryItem(name: "state", value: "opened"), URLQueryItem(name: "labels", value: "a+b,c/d")]
        )
        #expect(stub.requests.first?.url.absoluteString
            == "https://gitlab.com/api/v4/projects/acme%2Fpayments-api/merge_requests?state=opened&labels=a%2Bb%2Cc%2Fd")
    }

    @Test func sendEncodesJSONWithTheWireEncoder() async throws {
        struct Reply: Encodable, Sendable {
            var body: String
            var createdAt: Date
        }
        let stub = StubTransport(routes: [.fixed("POST", "/x", response: StubTransport.json("{}", status: 201))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)
        let response = try await client.send("POST", "/x", json: Reply(body: "ok", createdAt: NetFixture.date))
        #expect(response.status == 201)
        let request = try #require(stub.requests.first)
        #expect(request.body.map { String(decoding: $0, as: UTF8.self) } == #"{"body":"ok","createdAt":"2026-01-01T00:00:00Z"}"#)
        #expect(request.header("Content-Type") == "application/json")
    }

    @Test func sendWithoutBodyOmitsContentType() async throws {
        let stub = StubTransport(routes: [.fixed("DELETE", "/x", response: StubTransport.empty(status: 204))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)
        #expect(try await client.send("DELETE", "/x", json: nil).status == 204)
        #expect(stub.requests.first?.header("Content-Type") == nil)
        #expect(stub.requests.first?.body == nil)
    }

    @Test func rawBodiesAndSendJSON() async throws {
        let stub = StubTransport(
            routes: [
                .fixed("POST", "/form", response: StubTransport.json("{}")),
                .fixed("PUT", "/merge", response: StubTransport.json(#"{"id":7,"name":"x","updated_at":"2024-01-01T00:00:00Z"}"#)),
            ],
            baseURL: NetFixture.githubAPI
        )
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)
        _ = try await client.send("post", "/form", body: Data("a=1".utf8), contentType: "application/x-www-form-urlencoded")
        #expect(stub.requests.first?.method == "POST")
        #expect(stub.requests.first?.header("content-type") == "application/x-www-form-urlencoded")
        let repo = try await client.sendJSON(Repo.self, "PUT", "/merge", json: ["sha": "abc"])
        #expect(repo.id == 7)
    }

    @Test func sendAbsoluteRequiresTheSameOrigin() async throws {
        let stub = StubTransport(routes: [.fixed("POST", "/graphql", response: StubTransport.json("{}"))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)
        let graphQL = URL(staticString: "https://api.github.com/graphql")
        #expect(try await client.sendAbsolute("POST", graphQL, json: ["query": "{ viewer { login } }"]).status == 200)
        await #expect(throws: ProviderError.self) {
            try await client.sendAbsolute("POST", URL(staticString: "https://uploads.example.com/graphql"), json: nil)
        }
        #expect(stub.requests.count == 1)
    }

    @Test func nonSuccessStatusesThrowMappedErrors() async throws {
        let stub = StubTransport(
            routes: [
                .fixed("GET", "/auth", response: StubTransport.json(#"{"message":"Bad credentials"}"#, status: 401)),
                .fixed("GET", "/redirect", response: StubTransport.empty(status: 302, headers: ["Location": "http://downgrade.example"])),
            ],
            baseURL: NetFixture.githubAPI
        )
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)
        await #expect(throws: ProviderError.unauthorized("Bad credentials")) { try await client.get("/auth") }
        await #expect(throws: ProviderError.server(status: 302, message: "Unexpected HTTP status 302.")) { try await client.get("/redirect") }
        await #expect(throws: ProviderError.notFound("stub: no route for GET /nothing")) { try await client.get("/nothing") }
    }

    @Test func dotSegmentPathsFailBeforeAnyRequest() async throws {
        let stub = StubTransport(baseURL: NetFixture.gitlabAPI)
        let client = NetFixture.client(transport: stub)
        await #expect(throws: ProviderError.self) { try await client.get("/projects/../../admin") }
        #expect(stub.requests.isEmpty)
    }
}
