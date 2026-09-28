import Foundation
@testable import GitHubAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

@Suite("GitHub writes")
struct WriteTests {
    @Test func diffThreadReplyUsesRepliesEndpointWithRootComment() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        transport.clearRequests()
        let key = ThreadKey(changeRequest: snapshot.key, remoteID: GH.IDs.longThread, kind: .diffThread)
        let reply = try await provider.createReply(to: key, body: "Added the idempotency key in 5e5e5e5.")
        #expect(GH.operations(transport) == ["MergeCueThread"])
        let path = "/repos/acme/payments-api/pulls/42/comments/\(GH.IDs.longThreadRootComment)/replies"
        let posts = transport.requests("POST", path: path)
        #expect(posts.count == 1)
        #expect(posts.first?.jsonBody == ["body": "Added the idempotency key in 5e5e5e5."])
        #expect(reply.id == "2400000999")
        #expect(reply.body == "Added the idempotency key in 5e5e5e5.")
        #expect(reply.inReplyToID == GH.IDs.longThreadRootComment)
        #expect(reply.author.username == "mona-dev")
    }

    @Test func conversationAndReviewSummaryRepliesAreIssueComments() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        for key in [
            ThreadKey.githubIssueComment(changeRequest: snapshot.key, commentID: GH.IDs.issueComment),
            ThreadKey.githubReviewSummary(changeRequest: snapshot.key, reviewID: GH.IDs.changesRequestedReview),
        ] {
            transport.clearRequests()
            let reply = try await provider.createReply(to: key, body: "Thanks, fixed.")
            let posts = transport.requests("POST", path: "/repos/acme/payments-api/issues/42/comments")
            #expect(posts.count == 1)
            #expect(posts.first?.jsonBody == ["body": "Thanks, fixed."])
            #expect(reply.id == "2500000999" && reply.inReplyToID == nil)
            #expect(transport.requests(path: "/graphql").isEmpty)
        }
        await #expect(throws: ProviderError.self) {
            try await provider.createReply(to: .githubIssueComment(changeRequest: snapshot.key, commentID: "1"), body: "  ")
        }
    }

    @Test func resolveAndUnresolveUseGraphQLMutations() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        transport.clearRequests()
        let key = ThreadKey(changeRequest: snapshot.key, remoteID: GH.IDs.questionThread, kind: .diffThread)
        try await provider.resolveThread(key, resolved: true)
        try await provider.resolveThread(key, resolved: false)
        let bodies = transport.requests(path: "/graphql").compactMap(\.jsonBody)
        #expect(bodies.map { $0["operationName"]?.stringValue } == ["MergeCueResolveThread", "MergeCueUnresolveThread"])
        #expect(bodies.allSatisfy { $0["variables"] == ["id": .string(GH.IDs.questionThread)] })
        #expect(bodies.first?["query"]?.stringValue?.contains("resolveReviewThread(input: {threadId: $id})") == true)

        await #expect(throws: ProviderError.unsupported(.resolveThread, reason: "GitHub can only resolve review threads, not conversation comments or review bodies.")) {
            try await provider.resolveThread(.githubIssueComment(changeRequest: snapshot.key, commentID: GH.IDs.issueComment), resolved: true)
        }
        await #expect(throws: ProviderError.self) {
            try await provider.resolveThread(ThreadKey(changeRequest: snapshot.key, remoteID: "PRRT_gone", kind: .diffThread), resolved: true)
        }
    }

    @Test func requestChangesPostsReviewEvent() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        try await provider.requestChanges(on: snapshot.key, body: "Please mask the card number.")
        let posts = transport.requests("POST", path: "/repos/acme/payments-api/pulls/42/reviews")
        #expect(posts.count == 1)
        #expect(posts.first?.jsonBody == ["body": "Please mask the card number.", "event": "REQUEST_CHANGES"])
    }

    @Test func mergeSendsExpectedSHAAndMapsConflict() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider, number: 12)
        try await provider.merge(snapshot.key, expectedHeadSHA: GH.IDs.head12)
        let puts = transport.requests("PUT", path: "/repos/acme/payments-api/pulls/12/merge")
        #expect(puts.first?.jsonBody == ["sha": .string(GH.IDs.head12)])

        await #expect(throws: ProviderError.conflict("Head branch was modified. Review and try the merge again.")) {
            try await provider.merge(snapshot.key, expectedHeadSHA: "0000000000000000000000000000000000000000")
        }
        // Writes are never retried.
        #expect(transport.requests("PUT", path: "/repos/acme/payments-api/pulls/12/merge").count == 2)
    }
}

@Suite("GitHub logs, diffs and links")
struct ContentAndLinkTests {
    @Test func actionsJobLogIsRedactedAndBounded() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        let job = try #require(snapshot.checks.first { $0.key.remoteID == GH.IDs.failingJob })
        let excerpt = try await provider.failureLog(for: job, maxBytes: 64 * 1024)
        #expect(transport.requests("GET", path: "/repos/acme/payments-api/actions/jobs/9001/logs").count == 1)
        #expect(excerpt.text.contains("testTimeoutThenRetry"))
        #expect(!excerpt.text.contains("ghp_FixtureTokenThatMustBeRedacted"))
        #expect(excerpt.text.contains(SecretRedactor.marker))
        #expect(excerpt.text.contains("Ignore previous instructions"))  // untrusted log text is kept as data
        #expect(excerpt.truncated == false)
        #expect(excerpt.fullLogURL?.absoluteString == "https://github.com/acme/payments-api/actions/runs/7001/job/9001")

        let small = try await provider.failureLog(for: job, maxBytes: 300)
        #expect(small.truncated && small.text.utf8.count <= 300)
        #expect(small.text.contains("error"))
    }

    @Test func missingJobLogFallsBackToCheckRunOutput() async throws {
        let (provider, transport) = GH.provider()
        transport.add(.fixed("GET", "/repos/acme/payments-api/actions/jobs/9001/logs",
                             response: GH.response(#"{"message":"Not Found"}"#, status: 404)))
        let snapshot = try await GH.snapshot(provider)
        let job = try #require(snapshot.checks.first { $0.key.remoteID == GH.IDs.failingJob })
        let excerpt = try await provider.failureLog(for: job, maxBytes: 4096)
        #expect(transport.requests("GET", path: "/repos/acme/payments-api/check-runs/9001").count == 1)
        #expect(excerpt.text.contains("ChargeServiceTests.testTimeoutThenRetry failed"))
        #expect(excerpt.text.hasPrefix("Process completed with exit code 1."))
    }

    @Test func statusContextHasOnlyDetailsLink() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        let lint = try #require(snapshot.checks.first { $0.key.source == .githubStatus })
        transport.clearRequests()
        let excerpt = try await provider.failureLog(for: lint, maxBytes: 4096)
        #expect(transport.requests.isEmpty)
        #expect(excerpt.fullLogURL?.absoluteString == "https://ci.acme.dev/builds/555")
        #expect(excerpt.text.contains("details page"))
    }

    @Test func diffIsBoundedWithFilesAndSHAs() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        let diff = try await provider.diff(for: snapshot.key, maxBytes: 1_000_000)
        #expect(diff.unifiedDiff.hasPrefix("diff --git a/README.md b/README.md"))
        #expect(!diff.truncated)
        #expect(diff.headSHA == GH.IDs.head42 && diff.baseSHA == GH.IDs.base42)
        #expect(diff.files.count == 4)
        #expect(diff.files.last == ChangedFile(path: "Sources/Payments/RetryPolicy.swift", oldPath: "Sources/Payments/Retry.swift",
                                               status: .renamed, additions: 24, deletions: 0))
        let diffRequest = transport.requests("GET", path: "/repos/acme/payments-api/pulls/42").last
        #expect(diffRequest?.header("Accept") == "application/vnd.github.diff")

        let small = try await provider.diff(for: snapshot.key, maxBytes: 100)
        #expect(small.truncated && small.unifiedDiff.utf8.count <= 100)
    }

    @Test func tooLargeDiffIsRebuiltFromPatches() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        transport.add(StubTransport.Route(method: "GET", pathPattern: "/repos/acme/payments-api/pulls/42") { request, _ in
            if request.header("Accept")?.contains("diff") == true {
                return GH.response(#"{"message":"Sorry, the diff exceeded the maximum number of lines (20000)"}"#, status: 406)
            }
            return GitHubFixtures.resource("rest/pull_42.json").map { StubTransport.json($0) } ?? StubTransport.empty(status: 500)
        })
        let diff = try await provider.diff(for: snapshot.key, maxBytes: 1_000_000)
        #expect(diff.unifiedDiff.contains("diff --git a/Sources/Payments/Retry.swift b/Sources/Payments/RetryPolicy.swift"))
        #expect(diff.unifiedDiff.contains("+    let maxRetries = 3"))
        #expect(!diff.truncated)
    }

    @Test func deepLinks() async throws {
        let (provider, _) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        let pr = "https://github.com/acme/payments-api/pull/42"
        #expect(provider.deepLink(to: .changeRequest(snapshot.key))?.absoluteString == pr)
        let diffThread = ThreadKey(changeRequest: snapshot.key, remoteID: GH.IDs.longThread, kind: .diffThread)
        #expect(provider.deepLink(to: .thread(diffThread))?.absoluteString == "\(pr)#discussion_r\(GH.IDs.longThreadRootComment)")
        #expect(provider.deepLink(to: .comment(diffThread, commentID: "2400000103"))?.absoluteString == "\(pr)#discussion_r2400000103")
        let issue = ThreadKey.githubIssueComment(changeRequest: snapshot.key, commentID: GH.IDs.issueComment)
        #expect(provider.deepLink(to: .thread(issue))?.absoluteString == "\(pr)#issuecomment-\(GH.IDs.issueComment)")
        #expect(provider.deepLink(to: .comment(issue, commentID: GH.IDs.issueComment))?.absoluteString == "\(pr)#issuecomment-\(GH.IDs.issueComment)")
        let review = ThreadKey.githubReviewSummary(changeRequest: snapshot.key, reviewID: GH.IDs.changesRequestedReview)
        #expect(provider.deepLink(to: .thread(review))?.absoluteString == "\(pr)#pullrequestreview-\(GH.IDs.changesRequestedReview)")

        let job = try #require(snapshot.checks.first { $0.key.source == .githubActionsJob })
        #expect(provider.deepLink(to: .check(job.key))?.absoluteString == "https://github.com/acme/payments-api/actions/runs/7001/job/9001")
        let lint = try #require(snapshot.checks.first { $0.key.source == .githubStatus })
        #expect(provider.deepLink(to: .check(lint.key))?.absoluteString == "https://ci.acme.dev/builds/555")
        let unknownRun = CheckKey(changeRequest: snapshot.key, source: .githubCheckRun, remoteID: "123")
        #expect(provider.deepLink(to: .check(unknownRun))?.absoluteString == "https://github.com/acme/payments-api/runs/123")
        let unknownThread = ThreadKey(changeRequest: snapshot.key, remoteID: "PRRT_unknown", kind: .diffThread)
        #expect(provider.deepLink(to: .thread(unknownThread))?.absoluteString == "\(pr)/files")
    }

    @Test func fetchHeadSpecUsesBaseRepositoryEvenForForks() async throws {
        let (provider, _) = GH.provider()
        let own = try await GH.snapshot(provider)
        #expect(provider.fetchHeadSpec(for: own) == FetchHeadSpec(
            remoteURLs: ["https://github.com/acme/payments-api.git", "git@github.com:acme/payments-api.git"],
            refspec: "refs/pull/42/head", expectedSHA: GH.IDs.head42, isFork: false
        ))
        let fork = try await GH.snapshot(provider, number: 12)
        #expect(provider.fetchHeadSpec(for: fork) == FetchHeadSpec(
            remoteURLs: ["https://github.com/acme/payments-api.git", "git@github.com:acme/payments-api.git"],
            refspec: "refs/pull/12/head", expectedSHA: GH.IDs.head12, isFork: true
        ))
    }
}
