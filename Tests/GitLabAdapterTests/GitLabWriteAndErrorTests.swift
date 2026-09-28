import Foundation
@testable import GitLabAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

@Suite("GitLab writes, errors and deep links")
struct GitLabWriteAndErrorTests {
    typealias IDs = GitLabFixtures.IDs

    private var threadedKey: ThreadKey {
        ThreadKey(changeRequest: GitLabFixtures.mr42Key, remoteID: IDs.threadedDiscussion, kind: .diffThread)
    }

    // MARK: Writes

    @Test func createReplyPostsNoteToDiscussion() async throws {
        let harness = GitLabHarness()
        _ = try await harness.snapshot(GitLabFixtures.mr42Key)
        let comment = try await harness.provider.createReply(to: threadedKey, body: "Backoff added with jitter.")
        let request = try #require(harness.transport.requests("POST", path: "/projects/278964/merge_requests/42/discussions/\(IDs.threadedDiscussion)/notes").first)
        #expect(request.jsonBody == ["body": "Backoff added with jitter."])
        #expect(request.header("Content-Type") == "application/json")
        #expect(comment.id == "5001")
        #expect(comment.author.remoteID == "7001")
        #expect(comment.inReplyToID == "1001")
        #expect(comment.webURL?.absoluteString == "https://gitlab.com/acme/payments-api/-/merge_requests/42#note_5001")

        let fresh = try await harness.provider.thread(threadedKey)
        #expect(fresh.comments.last?.body == "Backoff added with jitter.")
        #expect(fresh.comments.count == 5)
    }

    @Test func emptyReplyIsRejectedLocally() async throws {
        let harness = GitLabHarness()
        await #expect(throws: ProviderError.invalidRequest("The reply is empty.")) {
            try await harness.provider.createReply(to: threadedKey, body: "  \n")
        }
        #expect(harness.transport.requests.isEmpty)
    }

    @Test func resolveAndReopenThread() async throws {
        let harness = GitLabHarness()
        try await harness.provider.resolveThread(threadedKey, resolved: true)
        let request = try #require(harness.transport.requests("PUT", path: "/projects/278964/merge_requests/42/discussions/\(IDs.threadedDiscussion)").first)
        #expect(request.jsonBody == ["resolved": true])
        #expect(try await harness.provider.thread(threadedKey).isResolved == true)

        try await harness.provider.resolveThread(threadedKey, resolved: false)
        #expect(harness.transport.requests("PUT", path: "/projects/278964/merge_requests/42/discussions/\(IDs.threadedDiscussion)").last?.jsonBody == ["resolved": false])
        #expect(try await harness.provider.thread(threadedKey).isResolved == false)
    }

    @Test func mergeSendsExpectedHeadSHA() async throws {
        let harness = GitLabHarness()
        try await harness.provider.merge(GitLabFixtures.mr7Key, expectedHeadSHA: IDs.head7)
        let request = try #require(harness.transport.requests("PUT", path: "/projects/278990/merge_requests/7/merge").first)
        #expect(request.jsonBody == ["sha": .string(IDs.head7)])
    }

    @Test func mergeWithStaleHeadIsAConflict() async throws {
        let harness = GitLabHarness()
        await #expect(throws: ProviderError.self) {
            try await harness.provider.merge(GitLabFixtures.mr7Key, expectedHeadSHA: IDs.head42)
        }
        do {
            try await harness.provider.merge(GitLabFixtures.mr7Key, expectedHeadSHA: IDs.head42)
        } catch let error as ProviderError {
            guard case .conflict(let message) = error else {
                Issue.record("expected conflict, got \(error)")
                return
            }
            #expect(message.contains("SHA does not match HEAD"))
        }
    }

    @Test(arguments: [(405, "conflict"), (422, "conflict"), (401, "forbidden")])
    func mergeRefusalsMapToConflictOrForbidden(status: Int, code: String) async throws {
        let harness = GitLabHarness(extraRoutes: [
            StubTransport.Route.fixed("PUT", "/projects/278990/merge_requests/7/merge",
                                      response: StubTransport.json(#"{"message":"refused"}"#, status: status)),
        ])
        do {
            try await harness.provider.merge(GitLabFixtures.mr7Key, expectedHeadSHA: IDs.head7)
            Issue.record("merge should fail")
        } catch let error as ProviderError {
            #expect(error.code == code)
        }
    }

    @Test func requestChangesPublishesReviewWithReviewerState() async throws {
        let harness = GitLabHarness()
        try await harness.provider.requestChanges(on: GitLabFixtures.mr7Key, body: "Please keep the old route as a fallback.")
        let publish = try #require(harness.transport.requests("POST", path: "/projects/278990/merge_requests/7/draft_notes/bulk_publish").first)
        #expect(publish.jsonBody == ["note": "Please keep the old route as a fallback.", "reviewer_state": "requested_changes"])
        #expect(harness.transport.requests("GET", path: "/projects/278990/merge_requests/7/draft_notes").count == 1)
        #expect(harness.transport.requests("GET", path: "/projects/278990/merge_requests/7/reviewers").count == 2)
    }

    @Test func requestChangesRequiresBeingAReviewer() async throws {
        let harness = GitLabHarness()
        // mona-dev authored !42 and is not one of its reviewers.
        do {
            try await harness.provider.requestChanges(on: GitLabFixtures.mr42Key, body: "x")
            Issue.record("should fail")
        } catch let error as ProviderError {
            #expect(error.code == "invalid_request")
        }
        #expect(harness.transport.requests("POST", path: "/projects/278964/merge_requests/42/draft_notes/bulk_publish").isEmpty)
    }

    @Test func requestChangesRefusesWhenDraftsArePending() async throws {
        let harness = GitLabHarness(extraRoutes: [
            .getJSON("/projects/278990/merge_requests/7/draft_notes", #"[{"id":1,"note":"pending"}]"#),
        ])
        do {
            try await harness.provider.requestChanges(on: GitLabFixtures.mr7Key, body: "x")
            Issue.record("should fail")
        } catch let error as ProviderError {
            #expect(error.code == "conflict")
        }
        #expect(harness.transport.requests("POST", path: "/projects/278990/merge_requests/7/draft_notes/bulk_publish").isEmpty)
    }

    @Test func requestChangesUnsupportedWhenStateIsNotRecorded() async throws {
        let harness = GitLabHarness(extraRoutes: [
            StubTransport.Route.fixed("POST", "/projects/278990/merge_requests/7/draft_notes/bulk_publish", response: StubTransport.empty(status: 204)),
        ])
        await #expect(throws: ProviderError.self) {
            try await harness.provider.requestChanges(on: GitLabFixtures.mr7Key, body: "x")
        }
        let old = GitLabHarness(extraRoutes: [
            StubTransport.Route.fixed("POST", "/projects/278990/merge_requests/7/draft_notes/bulk_publish",
                                      response: StubTransport.json(#"{"message":"404 Not Found"}"#, status: 404)),
        ])
        do {
            try await old.provider.requestChanges(on: GitLabFixtures.mr7Key, body: "x")
            Issue.record("should fail")
        } catch let error as ProviderError {
            guard case .unsupported(let capability, _) = error else {
                Issue.record("expected unsupported, got \(error)")
                return
            }
            #expect(capability == .requestChanges)
        }
    }

    // MARK: Error mapping

    @Test func httpErrorsMapToProviderErrors() async throws {
        let unauthorized = GitLabHarness(extraRoutes: [.getJSON("/user", #"{"message":"401 Unauthorized"}"#, status: 401)])
        await #expect(throws: ProviderError.unauthorized("401 Unauthorized")) { try await unauthorized.provider.currentUser() }

        let scope = GitLabHarness(extraRoutes: [
            .getJSON("/projects/278964/merge_requests/42", #"{"error":"insufficient_scope","error_description":"The request requires higher privileges than provided by the access token.","scope":"api read_api"}"#, status: 403),
        ])
        do {
            _ = try await scope.provider.headInfo(for: GitLabFixtures.mr42Key)
            Issue.record("should fail")
        } catch let error as ProviderError {
            guard case .forbidden(let missingScope, _) = error else {
                Issue.record("expected forbidden, got \(error)")
                return
            }
            #expect(missingScope?.contains("api") == true)
        }

        let missing = GitLabHarness()
        let unknownKey = ChangeRequestKey(repo: GitLabFixtures.repoKey(project: "1"), remoteID: "2", number: 3)
        await #expect(throws: ProviderError.notFound("404 Not found")) { try await missing.provider.headInfo(for: unknownKey) }

        let limited = GitLabHarness(extraRoutes: [
            .getJSON("/user", #"{"message":"429 Too Many Requests"}"#, status: 429, headers: ["retry-after": "3600", "ratelimit-reset": "1790003600"]),
        ])
        do {
            _ = try await limited.provider.currentUser()
            Issue.record("should fail")
        } catch let error as ProviderError {
            #expect(error.code == "rate_limited")
            #expect(error.isRetryable)
        }

        let down = GitLabHarness(extraRoutes: [.getJSON("/user", #"{"message":"502 Bad Gateway"}"#, status: 502)])
        await #expect(throws: ProviderError.server(status: 502, message: "502 Bad Gateway")) { try await down.provider.currentUser() }
        #expect(down.transport.requests(path: "/user").count == 3)  // GET retried with backoff

        let offline = GitLabHarness(extraRoutes: [.failing("GET", "/user", error: URLError(.notConnectedToInternet))])
        await #expect(throws: ProviderError.offline) { try await offline.provider.currentUser() }

        let garbage = GitLabHarness(extraRoutes: [.getJSON("/user", #"{"unexpected":true}"#)])
        do {
            _ = try await garbage.provider.currentUser()
            Issue.record("should fail")
        } catch let error as ProviderError {
            #expect(error.code == "decoding_error")
        }
    }

    @Test func hydrateToleratesMissingOptionalEndpointsButNotAuthFailures() async throws {
        let tolerant = GitLabHarness(extraRoutes: [
            .getJSON("/projects/278964/merge_requests/42/approvals", #"{"message":"404 Not found"}"#, status: 404),
            .getJSON("/projects/278964/merge_requests/42/reviewers", #"{"message":"404 Not found"}"#, status: 404),
        ])
        let snapshot = try await tolerant.snapshot(GitLabFixtures.mr42Key)
        #expect(snapshot.approvals == .unknown)
        #expect(snapshot.reviewers.map(\.state) == [.pending, .pending])  // from the MR's `reviewers` field

        let revoked = GitLabHarness(extraRoutes: [
            .getJSON("/projects/278964/merge_requests/42/approvals", #"{"message":"401 Unauthorized"}"#, status: 401),
        ])
        let summary = try await revoked.summary(GitLabFixtures.mr42Key)
        await #expect(throws: ProviderError.unauthorized("401 Unauthorized")) { try await revoked.provider.hydrate(summary) }
    }

    // MARK: Deep links

    @Test func deepLinksPointAtExactItems() async throws {
        let harness = GitLabHarness(step: 1)
        let snapshot = try await harness.snapshot(GitLabFixtures.mr42Key)
        let provider = harness.provider
        #expect(provider.deepLink(to: .changeRequest(GitLabFixtures.mr42Key))?.absoluteString
            == "https://gitlab.com/acme/payments-api/-/merge_requests/42")
        #expect(provider.deepLink(to: .thread(threadedKey))?.absoluteString
            == "https://gitlab.com/acme/payments-api/-/merge_requests/42#note_1001")
        #expect(provider.deepLink(to: .comment(threadedKey, commentID: "1003"))?.absoluteString
            == "https://gitlab.com/acme/payments-api/-/merge_requests/42#note_1003")
        let job = try #require(snapshot.checks.first { $0.key.remoteID == IDs.failedJob })
        #expect(provider.deepLink(to: .check(job.key))?.absoluteString == "https://gitlab.com/acme/payments-api/-/jobs/7103")
        let pipeline = try #require(snapshot.checks.first { $0.key.source == .gitlabPipeline })
        #expect(provider.deepLink(to: .check(pipeline.key))?.absoluteString == "https://gitlab.com/acme/payments-api/-/pipelines/5002")

        // A fork pipeline's job links into the source project.
        let fork = try await GitLabHarness(step: 1).snapshot(GitLabFixtures.mr12Key)
        let forkJob = try #require(fork.checks.first { $0.key.source == .gitlabJob })
        #expect(provider.deepLink(to: .check(forkJob.key))?.absoluteString == "https://gitlab.com/mona-dev/payments-api/-/jobs/9101")
    }

    @Test func deepLinkFallbacksNeverLeaveTheInstance() {
        let instance = ProviderInstance(
            kind: .gitlab,
            webURL: URL(string: "https://gitlab.example.org")!,
            apiURL: URL(string: "https://gitlab.example.org/api/v4")!
        )
        let provider = GitLabProvider(instance: instance, credential: GitLabFixtures.credential, transport: StubTransport(baseURL: instance.apiURL))
        let account = AccountKey(instance: instance, remoteUserID: "1")
        let key = ChangeRequestKey(repo: RepoKey(account: account, remoteRepoID: "31337"), remoteID: "900", number: 9)
        #expect(provider.deepLink(to: .changeRequest(key))?.absoluteString == "https://gitlab.example.org/projects/31337")
        let githubKey = ChangeRequestKey(repo: RepoKey(account: AccountKey(instance: .githubCom, remoteUserID: "1"), remoteRepoID: "1"), remoteID: "1", number: 1)
        #expect(provider.deepLink(to: .changeRequest(githubKey)) == nil)
    }
}
