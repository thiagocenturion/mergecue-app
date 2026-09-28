import Foundation
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing
@testable import BitbucketCloudAdapter

@Suite("Bitbucket writes, logs, diffs and fresh state")
struct WriteAndDetailTests {
    /// A harness whose repository directory already knows the fixture repositories (as after a sync).
    private func primed(step: Int = 0, extraRoutes: [StubTransport.Route] = []) async throws -> Harness {
        let harness = Harness(step: step, extraRoutes: extraRoutes)
        _ = try await harness.authored()
        harness.transport.clearRequests()
        return harness
    }

    // MARK: Writes

    @Test func createReplyPostsContentRawWithParentID() async throws {
        let harness = try await primed()
        let comment = try await harness.provider.createReply(to: Fx.thread("501"), body: "Thanks, fixed in the latest push.")
        let post = try #require(harness.requests("POST", containing: "/pullrequests/42/comments").first)
        #expect(post.url.path() == "/2.0/repositories/acme/payments-api/pullrequests/42/comments")
        #expect(post.jsonBody == ["content": ["raw": "Thanks, fixed in the latest push."], "parent": ["id": 501]])
        #expect(post.header("Content-Type") == "application/json")
        #expect(comment.id == "601")
        #expect(comment.inReplyToID == "501")
        #expect(comment.author.remoteID == Fx.me)
        #expect(comment.body == "Thanks, fixed in the latest push.")
    }

    @Test func resolveAndReopenUseTheRootCommentResolveEndpoint() async throws {
        let harness = try await primed()
        try await harness.provider.resolveThread(Fx.thread("501"), resolved: true)
        try await harness.provider.resolveThread(Fx.thread("501"), resolved: false)
        let calls = harness.requests(containing: "/comments/501/resolve")
        #expect(calls.map(\.method) == ["POST", "DELETE"])
        #expect(calls.allSatisfy { $0.body == nil })
    }

    @Test func resolvingAnAlreadyResolvedThreadIsAConflict() async throws {
        let conflict = StubTransport.json(#"{"type":"error","error":{"message":"Comment is already resolved"}}"#, status: 409)
        let harness = try await primed(extraRoutes: [
            .fixed("POST", "/repositories/acme/payments-api/pullrequests/42/comments/512/resolve", response: conflict),
        ])
        await #expect(throws: ProviderError.conflict("Comment is already resolved")) {
            try await harness.provider.resolveThread(Fx.thread("512"), resolved: true)
        }
    }

    @Test func requestChangesPostsTheVerdictThenTheExplanation() async throws {
        let harness = try await primed()
        try await harness.provider.requestChanges(on: Fx.prKey(42), body: "Please propagate the gateway error.")
        let writes = harness.transport.requests.filter { $0.method == "POST" }
        #expect(writes.map { $0.url.lastPathComponent } == ["request-changes", "comments"])
        #expect(writes.first?.body == nil)
        #expect(writes.last?.jsonBody == ["content": ["raw": "Please propagate the gateway error."]], "a general comment has no parent")
    }

    @Test func requestChangesWithoutBodyPostsOnlyTheVerdict() async throws {
        let harness = try await primed()
        try await harness.provider.requestChanges(on: Fx.prKey(42), body: "  ")
        #expect(harness.transport.requests.filter { $0.method == "POST" }.count == 1)
    }

    @Test func mergeRechecksTheHeadImmediatelyBefore() async throws {
        let harness = try await primed(step: 2)
        try await harness.provider.merge(Fx.prKey(42), expectedHeadSHA: BitbucketFixtures.IDs.head42)
        let methods = harness.transport.requests.map { "\($0.method) \($0.url.lastPathComponent)" }
        #expect(methods == ["GET 42", "POST merge"], "fresh head read right before the merge")
        #expect(harness.transport.requests.last?.body == nil)
    }

    @Test func mergeRefusesAMovedHeadWithoutPosting() async throws {
        let harness = try await primed()
        await #expect(throws: ProviderError.self) {
            try await harness.provider.merge(Fx.prKey(42), expectedHeadSHA: "0000000000000000000000000000000000000000")
        }
        #expect(harness.requests("POST", containing: "/merge").isEmpty)
    }

    @Test func mergeConflictFromBitbucketIsReported() async throws {
        let conflict = StubTransport.json(#"{"type":"error","error":{"message":"A ref changed while merging"}}"#, status: 409)
        let harness = try await primed(extraRoutes: [
            .fixed("POST", "/repositories/acme/payments-api/pullrequests/42/merge", response: conflict),
        ])
        await #expect(throws: ProviderError.conflict("A ref changed while merging")) {
            try await harness.provider.merge(Fx.prKey(42), expectedHeadSHA: "3f9c2e1d8b47")
        }
    }

    // MARK: Fresh state

    @Test func headInfoAndThreadAreFetchedFresh() async throws {
        let harness = try await primed(step: 2)
        let head = try await harness.provider.headInfo(for: Fx.prKey(42))
        #expect(head.headSHA == "3f9c2e1d8b47")
        #expect(head.state == .open)
        #expect(head.isDraft == false)
        let thread = try await harness.provider.thread(Fx.thread("513"))
        #expect(thread.comments.map(\.id) == ["513", "514"])
        await #expect(throws: ProviderError.self) { try await harness.provider.thread(Fx.thread("999999")) }
    }

    @Test func unknownRepositoryIsResolvedThroughTheUsersWorkspaces() async throws {
        let harness = Harness()  // empty directory: nothing listed yet
        let head = try await harness.provider.headInfo(for: Fx.prKey(42))
        #expect(head.headSHA == "3f9c2e1d8b47")
        let lookup = try #require(harness.requests(containing: "/repositories/acme/%7B5d3c1a2b").first)
        #expect(lookup.url.path(percentEncoded: true) == "/2.0/repositories/acme/%7B5d3c1a2b-7e8f-4a9b-b0c1-d2e3f4a5b6c7%7D")
        #expect(harness.directory.entry(host: "bitbucket.org", uuid: BitbucketFixtures.IDs.paymentsRepoUUID)?.path.fullName
            == "acme/payments-api")
    }

    // MARK: Logs and diffs

    @Test func failureLogReadsTheStepLogRedactedAndBounded() async throws {
        let harness = Harness()
        let snapshot = try await harness.snapshot(42)
        let unit = try #require(snapshot.checks.first { $0.name == "Pipeline › Unit tests" })
        harness.transport.clearRequests()
        let excerpt = try await harness.provider.failureLog(for: unit, maxBytes: 400)
        #expect(excerpt.text.utf8.count <= 400)
        #expect(excerpt.text.contains("reports gateway failures") || excerpt.text.contains("exit code 1"))
        #expect(!excerpt.text.contains("AKIAIOSFODNN7EXAMPLE"), "secrets in logs are redacted")
        #expect(excerpt.fullLogURL == unit.detailsURL)
        let request = try #require(harness.transport.requests.first)
        #expect(request.url.path(percentEncoded: true)
            == "/2.0/repositories/acme/payments-api/pipelines/%7B1f0e2d3c-4b5a-4968-8778-a1b2c3d4e5f6%7D/steps/%7Baa101000-0000-4000-8000-000000000002%7D/log")
        #expect(request.header("Range")?.hasPrefix("bytes=-") == true)
    }

    @Test func partialLogResponsesReportTheTotalSize() async throws {
        let partial = StubTransport.text("…tail of the log\nError: exit 1\n", status: 206, headers: ["Content-Range": "bytes 4970-4999/5000"])
        let harness = Harness(extraRoutes: [
            .fixed("GET", "/repositories/acme/payments-api/pipelines/{p}/steps/{s}/log", response: partial),
        ])
        let snapshot = try await harness.snapshot(42)
        let unit = try #require(snapshot.checks.first { $0.status == .failure })
        let excerpt = try await harness.provider.failureLog(for: unit, maxBytes: 4_000)
        #expect(excerpt.totalBytes == 5_000)
        #expect(excerpt.truncated)
    }

    @Test func statusChecksWithoutPipelinesOnlyCarryTheirURL() async throws {
        let harness = Harness()
        let snapshot = try await harness.snapshot(42)
        let sonar = try #require(snapshot.checks.first { $0.key.source == .bitbucketStatus })
        harness.transport.clearRequests()
        let excerpt = try await harness.provider.failureLog(for: sonar, maxBytes: 1_000)
        #expect(excerpt.fullLogURL?.absoluteString == "https://sonarcloud.io/dashboard?id=acme_payments-api&pullRequest=42")
        #expect(harness.transport.requests.isEmpty)
        #expect(excerpt.truncated == false)
    }

    @Test func diffIsBoundedAndListsFiles() async throws {
        let harness = try await primed()
        let full = try await harness.provider.diff(for: Fx.prKey(42), maxBytes: 100_000)
        #expect(full.unifiedDiff.contains("RefundExceedsCaptureError"))
        #expect(!full.truncated)
        #expect(full.files.count == 4)
        #expect(full.headSHA == "3f9c2e1d8b47")
        #expect(full.baseSHA == "9c1e4d2b7a60")

        let bounded = try await harness.provider.diff(for: Fx.prKey(42), maxBytes: 200)
        #expect(bounded.truncated)
        #expect(bounded.unifiedDiff.utf8.count <= 200)
    }
}
