import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

/// The credential must never surface in anything a thrown error or a printed request exposes.
@Suite("Credential never leaks")
struct CredentialSafetyTests {
    private static let basicPassword = "Plain-Opaque-Password-77"
    private static let basicPair = "mona@example.com:\(basicPassword)"

    /// Every rendering of an error a caller might log, persist or show.
    private func renderings(_ error: any Error) -> [String] {
        var dumped = ""
        dump(error, to: &dumped)
        return [
            String(describing: error),
            String(reflecting: error),
            error.localizedDescription,
            (error as? LocalizedError)?.errorDescription ?? "",
            (error as? ProviderError)?.code ?? "",
            dumped,
        ]
    }

    private func secrets(for credential: Credential) -> [String] {
        switch credential.secret {
        case .bearer(let token):
            [token, credential.authorizationHeaderValue()]
        case .basic:
            [Self.basicPassword, Self.basicPair, Data(Self.basicPair.utf8).base64EncodedString(), credential.authorizationHeaderValue()]
        }
    }

    /// A hostile server that echoes the request's Authorization header (and the raw token) back in every body.
    private func echoingStub(baseURL: URL, status: Int, extraHeaders: [String: String] = [:]) -> StubTransport {
        StubTransport(
            routes: [
                StubTransport.Route(method: "*", pathPattern: "/**") { request, _ in
                    let auth = request.header("Authorization") ?? ""
                    let bare = auth.split(separator: " ").last.map(String.init) ?? ""
                    let decoded = Data(base64Encoded: bare).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let body: JSONValue = [
                        "message": .string("rejected \(auth) token=\(bare) raw \(bare) pair \(decoded)"),
                        "errors": [["message": .string("echo \(bare)")]],
                        "error_description": .string(bare),
                    ]
                    return StubTransport.json(value: body, status: status, headers: extraHeaders)
                },
            ],
            baseURL: baseURL
        )
    }

    static let statuses = [400, 401, 403, 404, 409, 410, 422, 429, 500, 502, 503]

    @Test(arguments: statuses)
    func bearerTokenNeverAppearsInThrownErrors(status: Int) async throws {
        let stub = echoingStub(baseURL: NetFixture.githubAPI, status: status)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, retry: .none)
        try await assertNoLeak(credential: NetFixture.credential) {
            _ = try await client.get("/repos/acme/api")
        }
        try await assertNoLeak(credential: NetFixture.credential) {
            _ = try await client.send("POST", "/repos/acme/api/issues/1/comments", json: ["body": "hi"])
        }
    }

    @Test(arguments: statuses)
    func basicCredentialsNeverAppearInThrownErrors(status: Int) async throws {
        let credential = Credential.basic(username: "mona@example.com", password: Self.basicPassword)
        let stub = echoingStub(baseURL: NetFixture.bitbucketAPI, status: status)
        let client = NetFixture.client(baseURL: NetFixture.bitbucketAPI, transport: stub, credential: credential, parser: GenericRateLimitParser(), retry: .none)
        try await assertNoLeak(credential: credential) {
            _ = try await client.get("/repositories/acme/api")
        }
    }

    @Test func forbiddenScopeHintsAreScrubbedToo() async throws {
        let token = NetFixture.opaqueToken
        let stub = StubTransport(
            routes: [.fixed("GET", "/x", response: StubTransport.json(
                #"{"error":"insufficient_scope","scope":"\#(token)"}"#,
                status: 403,
                headers: ["X-Accepted-GitHub-Permissions": token]
            ))],
            baseURL: NetFixture.githubAPI
        )
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)
        try await assertNoLeak(credential: NetFixture.credential) { _ = try await client.get("/x") }
    }

    @Test func decodingErrorsDoNotIncludeTheToken() async throws {
        let token = NetFixture.opaqueToken
        let stub = StubTransport(routes: [.getJSON("/x", #"{"id":"\#(token)","name":1}"#)], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub)
        try await assertNoLeak(credential: NetFixture.credential) { _ = try await client.getJSON(Repo.self, "/x") }
    }

    @Test func transportErrorsDoNotIncludeTheToken() async throws {
        let stub = StubTransport(routes: [.failing("GET", "/x", error: URLError(.secureConnectionFailed))], baseURL: NetFixture.githubAPI)
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, retry: .none)
        try await assertNoLeak(credential: NetFixture.credential) { _ = try await client.get("/x") }
    }

    @Test func refreshTokensAreScrubbed() async throws {
        let credential = Credential.bearer("access-Token-Opaque-111", refreshToken: "refresh-Token-Opaque-222")
        let stub = StubTransport(
            routes: [.fixed("GET", "/x", response: StubTransport.json(#"{"message":"bad refresh-Token-Opaque-222"}"#, status: 401))],
            baseURL: NetFixture.githubAPI
        )
        let client = NetFixture.client(baseURL: NetFixture.githubAPI, transport: stub, credential: credential)
        do {
            _ = try await client.get("/x")
            Issue.record("expected an error")
        } catch {
            for text in renderings(error) {
                #expect(!text.contains("refresh-Token-Opaque-222"))
            }
        }
    }

    @Test func printedRequestsMaskSecretHeaders() {
        let request = HTTPRequest(
            method: "GET",
            url: URL(staticString: "https://api.github.com/user"),
            headers: ["Authorization": "Bearer \(NetFixture.opaqueToken)", "PRIVATE-TOKEN": "glpat-abc", "Cookie": "s=1", "Accept": "application/json"]
        )
        var dumped = ""
        dump(request, to: &dumped)
        for text in [String(describing: request), String(reflecting: request), dumped, "\(request)"] {
            #expect(!text.contains(NetFixture.opaqueToken))
            #expect(!text.contains("glpat-abc"))
            #expect(!text.contains("s=1"))
        }
        #expect(String(reflecting: request).contains("Accept: application/json"))
        #expect(String(reflecting: request).contains("Authorization: [REDACTED]"))
    }

    @Test func scrubberCoversEncodedForms() {
        let credential = Credential.bearer("tok/en+with=chars")
        let scrubber = CredentialScrubber(credential)
        #expect(scrubber.scrub("url?t=tok%2Fen%2Bwith%3Dchars") == "url?t=[REDACTED]")
        #expect(scrubber.scrub("raw tok/en+with=chars end") == "raw [REDACTED] end")
        #expect(scrubber.scrub("nothing here") == "nothing here")
    }

    // MARK: Helpers

    private func assertNoLeak(
        credential: Credential,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> Void
    ) async throws {
        do {
            try await body()
            Issue.record("expected an error", sourceLocation: sourceLocation)
        } catch {
            for text in renderings(error) {
                for secret in secrets(for: credential) {
                    #expect(!text.contains(secret), "leaked in: \(text.prefix(200))", sourceLocation: sourceLocation)
                }
            }
        }
    }
}
