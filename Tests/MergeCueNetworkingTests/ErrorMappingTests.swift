import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

@Suite("HTTP and transport error mapping")
struct ErrorMappingTests {
    private let github = GitHubRateLimitParser()

    private func map(_ status: Int, headers: [String: String] = [:], body: String = "") -> ProviderError? {
        mapHTTPError(NetFixture.response(status, headers: headers, body: body), parser: github)
    }

    // MARK: Status table

    struct Row: Sendable, CustomTestStringConvertible {
        var status: Int
        var headers: [String: String] = [:]
        var body: String = ""
        var expected: ProviderError
        var testDescription: String { "\(status) \(headers.keys.sorted()) → \(expected.code)" }
    }

    static let table: [Row] = [
        Row(status: 401, body: #"{"message":"Bad credentials"}"#, expected: .unauthorized("Bad credentials")),
        Row(
            status: 403,
            headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1767229200", "X-RateLimit-Limit": "5000"],
            body: #"{"message":"API rate limit exceeded for user ID 1."}"#,
            expected: .rateLimited(resetAt: Date(timeIntervalSince1970: 1_767_229_200), retryAfter: nil)
        ),
        Row(
            status: 403,
            headers: ["Retry-After": "120", "X-RateLimit-Remaining": "4000"],
            body: #"{"message":"You have exceeded a secondary rate limit."}"#,
            expected: .rateLimited(resetAt: nil, retryAfter: 120)
        ),
        Row(
            status: 403,
            body: #"{"message":"You have exceeded a secondary rate limit. Please wait a few minutes."}"#,
            expected: .rateLimited(resetAt: nil, retryAfter: nil)
        ),
        Row(
            status: 403,
            headers: ["X-Accepted-OAuth-Scopes": "repo", "X-OAuth-Scopes": "read:user, gist", "X-RateLimit-Remaining": "4999"],
            body: #"{"message":"Resource not accessible by personal access token"}"#,
            expected: .forbidden(missingScope: "repo", message: "Resource not accessible by personal access token")
        ),
        Row(
            status: 403,
            headers: ["X-Accepted-OAuth-Scopes": "admin:org, read:org, write:org", "X-OAuth-Scopes": "repo"],
            body: #"{"message":"Must have admin rights"}"#,
            expected: .forbidden(missingScope: "read:org", message: "Must have admin rights")
        ),
        Row(
            status: 403,
            headers: ["X-Accepted-OAuth-Scopes": "read:org", "X-OAuth-Scopes": "admin:org, repo"],
            body: #"{"message":"Forbidden by org policy"}"#,
            expected: .forbidden(missingScope: nil, message: "Forbidden by org policy")
        ),
        Row(
            status: 403,
            headers: ["X-Accepted-GitHub-Permissions": "pull_requests=write"],
            body: #"{"message":"Resource not accessible by personal access token"}"#,
            expected: .forbidden(missingScope: "pull_requests=write", message: "Resource not accessible by personal access token")
        ),
        Row(
            status: 403,
            headers: ["WWW-Authenticate": #"Bearer realm="", error="insufficient_scope", error_description="The request requires higher privileges than provided by the access token.", scope="api""#],
            body: #"{"error":"insufficient_scope","error_description":"The request requires higher privileges than provided by the access token.","scope":"api"}"#,
            expected: .forbidden(missingScope: "api", message: "The request requires higher privileges than provided by the access token.")
        ),
        Row(
            status: 403,
            body: #"{"error":"insufficient_scope","error_description":"Needs more","scope":"api read_api"}"#,
            expected: .forbidden(missingScope: "read_api", message: "Needs more")
        ),
        Row(
            status: 403,
            body: #"{"type":"error","error":{"message":"Your credentials lack one or more required privilege scopes.","detail":{"granted":["account"],"required":["pullrequest"]}}}"#,
            expected: .forbidden(missingScope: "pullrequest", message: "Your credentials lack one or more required privilege scopes.")
        ),
        Row(status: 403, body: #"{"message":"Forbidden"}"#, expected: .forbidden(missingScope: nil, message: "Forbidden")),
        Row(status: 404, body: #"{"message":"404 Project Not Found"}"#, expected: .notFound("404 Project Not Found")),
        Row(status: 410, expected: .notFound("HTTP 410")),
        Row(status: 409, body: #"{"message":"Head branch was modified. Review and try the merge again."}"#,
            expected: .conflict("Head branch was modified. Review and try the merge again.")),
        Row(status: 422, body: #"{"message":"Validation Failed","errors":[{"resource":"PullRequestReviewComment","code":"custom","field":"body","message":"body is too long"}]}"#,
            expected: .invalidRequest("Validation Failed: body is too long")),
        Row(status: 422, body: #"{"message":{"base":["Thread already resolved"]}}"#, expected: .invalidRequest("base Thread already resolved")),
        Row(status: 400, body: #"{"type":"error","error":{"message":"Bad request","detail":"q is invalid"}}"#,
            expected: .invalidRequest("Bad request: q is invalid")),
        Row(status: 429, headers: ["Retry-After": "30"], expected: .rateLimited(resetAt: nil, retryAfter: 30)),
        Row(status: 429, expected: .rateLimited(resetAt: nil, retryAfter: nil)),
        Row(status: 500, body: #"{"message":"Server Error"}"#, expected: .server(status: 500, message: "Server Error")),
        Row(status: 502, body: "<html><body>Bad Gateway</body></html>", expected: .server(status: 502, message: "HTTP 502")),
        Row(status: 503, body: "Service Unavailable\n  try later", expected: .server(status: 503, message: "Service Unavailable try later")),
        Row(status: 408, expected: .server(status: 408, message: "HTTP 408")),
    ]

    @Test(arguments: table)
    func statusTable(row: Row) {
        #expect(map(row.status, headers: row.headers, body: row.body) == row.expected)
    }

    @Test(arguments: [100, 200, 201, 204, 301, 304, 399])
    func successAndRedirectStatusesAreNotErrors(status: Int) {
        #expect(map(status) == nil)
    }

    @Test func gitLabRateLimitHeadersOn403AreRecognizedWhateverTheParser() {
        let error = map(403, headers: ["RateLimit-Remaining": "0", "RateLimit-Reset": "1767229200"])
        #expect(error == .rateLimited(resetAt: Date(timeIntervalSince1970: 1_767_229_200), retryAfter: nil))
    }

    @Test func mappedErrorsAreRetryableOnlyWhenTheyShouldBe() {
        #expect(map(500)?.isRetryable == true)
        #expect(map(503)?.isRetryable == true)
        #expect(map(429)?.isRetryable == true)
        #expect(map(401)?.isRetryable == false)
        #expect(map(404)?.isRetryable == false)
        #expect(map(422)?.isRetryable == false)
    }

    @Test func messagesAreBoundedAndRedacted() throws {
        let long = String(repeating: "x", count: 5_000)
        let error = try #require(map(500, body: #"{"message":"\#(long)"}"#))
        guard case .server(_, let message) = error else {
            Issue.record("expected server error")
            return
        }
        #expect(message.utf8.count <= 500)

        let leaked = try #require(map(401, body: #"{"message":"bad token ghp_abcdefghijklmnopqrstuvwxyz0123456789"}"#))
        #expect(!String(describing: leaked).contains("abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    // MARK: Scope hierarchy

    @Test(arguments: [
        ("repo", "public_repo", true), ("repo", "repo:status", true), ("admin:org", "read:org", true),
        ("admin:org", "write:org", true), ("write:org", "read:org", true), ("read:org", "write:org", false),
        ("user", "user:email", true), ("user", "read:user", true), ("public_repo", "repo", false),
        ("write:packages", "read:packages", true), ("gist", "repo", false),
    ])
    func gitHubScopeHierarchy(granted: String, needed: String, covered: Bool) {
        #expect(ScopeHints.covers(granted, needed) == covered)
    }

    // MARK: Transport errors

    @Test(arguments: [
        (URLError.Code.timedOut, ProviderError.timeout),
        (.notConnectedToInternet, .offline),
        (.networkConnectionLost, .offline),
        (.cannotFindHost, .offline),
        (.cannotConnectToHost, .offline),
        (.dnsLookupFailed, .offline),
        (.dataNotAllowed, .offline),
        (.internationalRoamingOff, .offline),
    ])
    func urlErrorsMapToOfflineOrTimeout(code: URLError.Code, expected: ProviderError) {
        #expect(mapTransportError(URLError(code)) == expected)
    }

    @Test func otherTransportErrorsAreServerStatusZero() {
        guard case .server(let status, _) = mapTransportError(URLError(.secureConnectionFailed)) else {
            Issue.record("expected server error")
            return
        }
        #expect(status == 0)
        #expect(mapTransportError(ProviderError.conflict("x")) == .conflict("x"))
    }

    @Test func cancellationIsRecognized() {
        #expect(isCancellation(CancellationError()))
        #expect(isCancellation(URLError(.cancelled)))
        #expect(!isCancellation(URLError(.timedOut)))
        #expect(mapTransportError(CancellationError()).code == "server_error")
    }
}
