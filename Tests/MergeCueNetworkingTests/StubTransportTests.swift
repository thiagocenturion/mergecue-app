import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

@Suite("Stub transport")
struct StubTransportTests {
    private func request(_ url: String, method: String = "GET") throws -> HTTPRequest {
        HTTPRequest(method: method, url: try #require(URL(string: url)))
    }

    private func echoParams(_ pattern: String, method: String = "GET", query: [String: String] = [:]) -> StubTransport.Route {
        StubTransport.Route(method: method, pathPattern: pattern, query: query) { _, match in
            StubTransport.json(value: .object(match.params.mapValues(JSONValue.string)))
        }
    }

    @Test func paramsAreCapturedRelativeToTheBasePath() async throws {
        let stub = StubTransport(routes: [echoParams("/projects/{id}/merge_requests/{iid}")], baseURL: NetFixture.gitlabAPI)
        let response = try await stub.send(request("https://gitlab.com/api/v4/projects/acme%2Fpayments-api/merge_requests/42"))
        #expect(response.status == 200)
        #expect(response.url.absoluteString == "https://gitlab.com/api/v4/projects/acme%2Fpayments-api/merge_requests/42")
        let json = try #require(try? JSONValue.defaultDecoder().decode(JSONValue.self, from: response.body))
        #expect(json["id"]?.stringValue == "acme/payments-api", "captures are percent-decoded")
        #expect(json["iid"]?.stringValue == "42")
    }

    @Test func patternsMayIncludeTheAPIPrefix() async throws {
        let stub = StubTransport(routes: [echoParams("/api/v4/projects/{id}")], baseURL: NetFixture.gitlabAPI)
        let response = try await stub.send(request("https://gitlab.com/api/v4/projects/7"))
        #expect(response.status == 200)
    }

    @Test func wildcardsMatchOneSegmentAndGlobMatchesTheRest() async throws {
        let stub = StubTransport(
            routes: [
                .getJSON("/repos/{owner}/{repo}/pulls/*", #"{"route":"one"}"#),
                .getJSON("/repos/**", #"{"route":"glob"}"#),
            ],
            baseURL: NetFixture.githubAPI
        )
        let one = try await stub.send(request("https://api.github.com/repos/acme/api/pulls/42"))
        #expect(one.bodyText == #"{"route":"one"}"#)
        let deeper = try await stub.send(request("https://api.github.com/repos/acme/api/pulls/42/reviews"))
        #expect(deeper.bodyText == #"{"route":"glob"}"#)
        let root = try await stub.send(request("https://api.github.com/repos"))
        #expect(root.bodyText == #"{"route":"glob"}"#)
    }

    @Test func affixedParams() async throws {
        let stub = StubTransport(routes: [echoParams("/repos/{o}/{r}/pulls/{number}.diff")], baseURL: NetFixture.githubAPI)
        let response = try await stub.send(request("https://api.github.com/repos/a/b/pulls/42.diff"))
        #expect(response.jsonBodyValue?["number"]?.stringValue == "42")
        let miss = try await stub.send(request("https://api.github.com/repos/a/b/pulls/42"))
        #expect(miss.status == 404)
    }

    @Test func queryConstraintsMustMatch() async throws {
        let stub = StubTransport(
            routes: [
                .getJSON("/merge_requests", query: ["scope": "created_by_me", "state": "opened"], #"{"route":"mine"}"#),
                .getJSON("/merge_requests", query: ["reviewer_id": "*"], #"{"route":"reviewing"}"#),
                .getJSON("/search/issues?q=is:pr author:@me", #"{"route":"search"}"#),
            ],
            baseURL: NetFixture.gitlabAPI
        )
        let mine = try await stub.send(request("https://gitlab.com/api/v4/merge_requests?state=opened&scope=created_by_me&per_page=100"))
        #expect(mine.bodyText == #"{"route":"mine"}"#)
        let reviewing = try await stub.send(request("https://gitlab.com/api/v4/merge_requests?reviewer_id=5&state=opened"))
        #expect(reviewing.bodyText == #"{"route":"reviewing"}"#)
        let neither = try await stub.send(request("https://gitlab.com/api/v4/merge_requests?state=opened"))
        #expect(neither.status == 404)
        let search = try await stub.send(request("https://gitlab.com/api/v4/search/issues?q=is%3Apr%20author%3A%40me"))
        #expect(search.bodyText == #"{"route":"search"}"#)
        let plusEncoded = try await stub.send(request("https://gitlab.com/api/v4/search/issues?q=is%3Apr+author%3A%40me"))
        #expect(plusEncoded.bodyText == #"{"route":"search"}"#)
    }

    @Test func methodsMustMatchAndStarMatchesAny() async throws {
        let stub = StubTransport(
            routes: [
                .fixed("POST", "/projects/{id}/notes", response: StubTransport.json("{}", status: 201)),
                .fixed("*", "/anything", response: StubTransport.empty(status: 204)),
            ],
            baseURL: NetFixture.gitlabAPI
        )
        #expect(try await stub.send(request("https://gitlab.com/api/v4/projects/1/notes", method: "POST")).status == 201)
        #expect(try await stub.send(request("https://gitlab.com/api/v4/projects/1/notes", method: "GET")).status == 404)
        #expect(try await stub.send(request("https://gitlab.com/api/v4/anything", method: "DELETE")).status == 204)
    }

    @Test func mostSpecificRouteWinsThenLatestAdded() async throws {
        let stub = StubTransport(
            routes: [
                .getJSON("/projects/{id}/merge_requests/{iid}", #"{"route":"generic"}"#),
                .getJSON("/projects/1/merge_requests/42", #"{"route":"specific"}"#),
                .getJSON("/projects/{id}/merge_requests/{iid}", #"{"route":"generic-late"}"#),
            ],
            baseURL: NetFixture.gitlabAPI
        )
        #expect(try await stub.send(request("https://gitlab.com/api/v4/projects/1/merge_requests/42")).bodyText == #"{"route":"specific"}"#)
        #expect(try await stub.send(request("https://gitlab.com/api/v4/projects/2/merge_requests/42")).bodyText == #"{"route":"generic-late"}"#)

        stub.add(.getJSON("/projects/1/merge_requests/42", #"{"route":"override"}"#))
        #expect(try await stub.send(request("https://gitlab.com/api/v4/projects/1/merge_requests/42")).bodyText == #"{"route":"override"}"#)
    }

    @Test func unmatchedRequestsGetA404JSONBodyAndAreRecorded() async throws {
        let stub = StubTransport(baseURL: NetFixture.gitlabAPI)
        let response = try await stub.send(request("https://gitlab.com/api/v4/projects/1?x=y", method: "DELETE"))
        #expect(response.status == 404)
        #expect(response.header("Content-Type")?.hasPrefix("application/json") == true)
        #expect(response.jsonBodyValue?["message"]?.stringValue == "stub: no route for DELETE /api/v4/projects/1")
        #expect(stub.unmatchedRequests.count == 1)
        #expect(stub.requests.count == 1)
    }

    @Test func otherHostsDoNotMatch() async throws {
        let stub = StubTransport(routes: [.getJSON("/user", "{}")], baseURL: NetFixture.githubAPI)
        #expect(try await stub.send(request("https://api.github.com/user")).status == 200)
        #expect(try await stub.send(request("https://evil.example/user")).status == 404)
    }

    @Test func requestsAreRecordedWithHeadersAndBodies() async throws {
        let stub = StubTransport(routes: [.fixed("POST", "/projects/{id}/notes", response: StubTransport.json("{}", status: 201))], baseURL: NetFixture.gitlabAPI)
        let client = NetFixture.client(transport: stub)
        _ = try await client.send("POST", "/projects/1/notes", json: ["body": "Thanks!"])
        let recorded = try #require(stub.requests(path: "/projects/1/notes").first)
        #expect(recorded.method == "POST")
        #expect(recorded.header("authorization") == "Bearer \(NetFixture.opaqueToken)")
        #expect(recorded.header("content-type") == "application/json")
        #expect(recorded.jsonBody == ["body": "Thanks!"])
        #expect(stub.requests("GET", path: "/projects/1/notes").isEmpty)

        stub.clearRequests()
        #expect(stub.requests.isEmpty)
    }

    @Test func sequencesAndFailures() async throws {
        let stub = StubTransport(
            routes: [
                .sequence("GET", "/flaky", responses: [StubTransport.empty(status: 503), StubTransport.json("[]")]),
                .failing("GET", "/down", error: URLError(.notConnectedToInternet)),
            ],
            baseURL: NetFixture.githubAPI
        )
        #expect(try await stub.send(request("https://api.github.com/flaky")).status == 503)
        #expect(try await stub.send(request("https://api.github.com/flaky")).status == 200)
        #expect(try await stub.send(request("https://api.github.com/flaky")).status == 200, "the last response repeats")
        await #expect(throws: URLError.self) { try await stub.send(request("https://api.github.com/down")) }
    }

    @Test func contractRespondPropertyStillReceivesTheRequest() async throws {
        var route = StubTransport.Route(method: "GET", pathPattern: "/users/{name}") { _, match in
            StubTransport.text("hello \(match["name"] ?? "?")")
        }
        let direct = route.respond(try request("https://api.github.com/users/mona"))
        #expect(direct.bodyText == "hello mona")

        route.respond = { request in StubTransport.text("replaced \(request.url.lastPathComponent)") }
        let stub = StubTransport(routes: [route], baseURL: NetFixture.githubAPI)
        #expect(try await stub.send(request("https://api.github.com/users/mona")).bodyText == "replaced mona")
    }

    @Test func concurrentUseIsSafe() async throws {
        let stub = StubTransport(routes: [echoParams("/items/{n}")], baseURL: NetFixture.githubAPI)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let url = try #require(URL(string: "https://api.github.com/items/\(index)"))
                    if index.isMultiple(of: 10) {
                        stub.add(.getJSON("/extra/\(index)", "{}"))
                    }
                    return try await stub.send(HTTPRequest(url: url)).status
                }
            }
            var statuses: [Int] = []
            for try await status in group { statuses.append(status) }
            #expect(statuses.count == 200)
            #expect(statuses.allSatisfy { $0 == 200 })
        }
        #expect(stub.requests.count == 200)
        #expect(Set(stub.requests.map(\.url.lastPathComponent)).count == 200)
    }

    @Test func helpersSetContentTypes() throws {
        #expect(StubTransport.json("{}").header("content-type") == "application/json; charset=utf-8")
        #expect(StubTransport.text("log").header("content-type") == "text/plain; charset=utf-8")
        #expect(StubTransport.json("{}", headers: ["Content-Type": "application/vnd.api+json"]).header("content-type") == "application/vnd.api+json")
        let encoded = try StubTransport.json(encoding: Repo(id: 1, name: "api", updatedAt: NetFixture.date))
        #expect(encoded.bodyText == #"{"id":1,"name":"api","updated_at":"2026-01-01T00:00:00Z"}"#)
    }
}

extension HTTPResponse {
    var jsonBodyValue: JSONValue? {
        try? JSONValue.defaultDecoder().decode(JSONValue.self, from: body)
    }
}
