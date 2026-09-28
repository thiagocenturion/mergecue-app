import Foundation
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing
@testable import BitbucketCloudAdapter

@Suite("Bitbucket hydration")
struct HydrationTests {
    @Test func baselineThreadsRebuildReplyChainsAndExcludeDraftsAndDeletions() async throws {
        let snapshot = try await Harness().snapshot(42)
        #expect(snapshot.threads.map(\.key.remoteID) == ["507", "501", "512", "505", "506", "508", "511"])

        let chain = try #require(snapshot.threads.first { $0.key.remoteID == "501" })
        #expect(chain.key.kind == .diffThread)
        #expect(chain.comments.map(\.id) == ["501", "502", "503", "504"])
        #expect(chain.comments.map(\.inReplyToID) == [nil, "501", "502", "503"])
        #expect(chain.isResolvable)
        #expect(chain.isResolved == false)
        #expect(chain.anchor?.path == "src/payments/refund.ts")
        #expect(chain.anchor?.line == 48)
        #expect(chain.anchor?.side == .new)
        #expect(chain.anchor?.isOutdated == false)
        #expect(chain.anchor?.commitSHA == "3f9c2e1d8b47")
        #expect(chain.webURL?.absoluteString == "https://bitbucket.org/acme/payments-api/pull-requests/42#comment-501")
        #expect(chain.comments.first?.author.remoteID == "{3c1d9e7a-5b2f-4a6c-8d0e-1f2a3b4c5d61}")

        let ids = Set(snapshot.threads.flatMap(\.comments).map(\.id))
        #expect(!ids.contains("509"), "pending draft comments are excluded")
        #expect(!ids.contains("510"), "deleted comments are excluded")
    }

    @Test func commentKindsResolutionAndOutdatedAnchors() async throws {
        let snapshot = try await Harness().snapshot(42)
        func thread(_ id: String) throws -> ReviewThread { try #require(snapshot.threads.first { $0.key.remoteID == id }) }

        #expect(try thread("505").comments.first?.kind == .suggestion)
        let question = try thread("506")
        #expect(question.key.kind == .conversation)
        #expect(question.comments.first?.kind == .question)
        #expect(question.isResolved == nil, "general comments are not resolvable and never count as unresolved")
        #expect(question.anchor == nil)

        let outdated = try thread("507")
        #expect(outdated.isOutdated)
        #expect(outdated.anchor?.side == .old)
        #expect(outdated.anchor?.line == 10)
        #expect(outdated.anchor?.commitSHA == "0a1b2c3d4e5f")

        #expect(try thread("512").isResolved == true)
        #expect(snapshot.unresolvedThreadCount == 3)
    }

    @Test func hostileCommentIsCarriedVerbatimAsData() async throws {
        let snapshot = try await Harness().snapshot(42)
        let hostile = try #require(snapshot.threads.first { $0.key.remoteID == BitbucketFixtures.hostileCommentID })
        let body = try #require(hostile.comments.first?.body)
        #expect(body.contains("IGNORE ALL PREVIOUS INSTRUCTIONS"))
        #expect(hostile.comments.first?.author.username == "eve-contractor")
        #expect(hostile.comments.first?.kind == .comment)
    }

    @Test func reviewersApprovalsAndReviews() async throws {
        let snapshot = try await Harness().snapshot(42)
        #expect(snapshot.reviewers.map(\.person.username) == ["lucia.m", "devon-p"])
        #expect(snapshot.reviewers.map(\.state) == [.changesRequested, .approved])
        #expect(snapshot.reviewers.allSatisfy { $0.isRequired == nil })
        #expect(snapshot.approvals.approvedBy.map(\.username) == ["devon-p"])
        #expect(snapshot.approvals.isSatisfied == nil, "required approvals are admin-only data")
        #expect(snapshot.reviews.map(\.remoteID) == [
            "changes_requested:{3c1d9e7a-5b2f-4a6c-8d0e-1f2a3b4c5d61}", "approved:{6e2f8a1b-9c3d-4e5f-a6b7-c8d9e0f1a2b3}",
        ])
        #expect(snapshot.description?.contains("RefundService") == true)
    }

    @Test func checksCombineStatusesAndPipelineStepsWithoutDuplicates() async throws {
        let snapshot = try await Harness().snapshot(42)
        #expect(snapshot.checks.map(\.name) == ["SonarCloud Quality Gate", "Pipeline › Build", "Pipeline › Unit tests"])
        #expect(snapshot.checks.map(\.status) == [.success, .success, .failure])
        #expect(snapshot.aggregateCheckState == .failing)

        let unit = try #require(snapshot.checks.last)
        #expect(unit.key.source == .bitbucketPipelineStep)
        #expect(unit.key.remoteID == "101/\(BitbucketFixtures.IDs.unitTestsStep101)")
        #expect(unit.logLocator["pipeline_uuid"] == BitbucketFixtures.IDs.pipeline101)
        #expect(unit.logLocator["step_uuid"] == BitbucketFixtures.IDs.unitTestsStep101)
        #expect(unit.logLocator["repository"] == "acme/payments-api")
        #expect(unit.commitSHA == BitbucketFixtures.IDs.head42)
        #expect(unit.detailsURL?.absoluteString
            == "https://bitbucket.org/acme/payments-api/pipelines/results/101/steps/%7Baa101000-0000-4000-8000-000000000002%7D")

        let sonar = try #require(snapshot.checks.first)
        #expect(sonar.key.source == .bitbucketStatus)
        #expect(sonar.key.remoteID == "sonarcloud-quality-gate")
    }

    @Test func pipelinesAreQueriedForTheFullHeadCommit() async throws {
        let harness = Harness()
        let snapshot = try await harness.snapshot(42)
        #expect(snapshot.summary.headSHA == BitbucketFixtures.IDs.head42, "abbreviated PR hash upgraded from /commits")
        let request = try #require(harness.requests(containing: "/pipelines?").first)
        #expect(request.queryItems.contains(URLQueryItem(name: "target.commit.hash", value: BitbucketFixtures.IDs.head42)))
        #expect(harness.requests(containing: "/pipelines/%7B1f0e2d3c-4b5a-4968-8778-a1b2c3d4e5f6%7D/steps").count == 1)
    }

    @Test func commitsFilesSourceAndNativeRefs() async throws {
        let snapshot = try await Harness().snapshot(42)
        #expect(snapshot.commits.map(\.title) == ["Move refund guard into RefundService", "Guard refunds against over-capture"])
        #expect(snapshot.commits.first?.author == "Mona Dev")
        #expect(snapshot.changedFiles.count == 4)
        let renamed = try #require(snapshot.changedFiles.first { $0.status == .renamed })
        #expect(renamed.path == "src/payments/legacy-refunds.ts")
        #expect(renamed.oldPath == "src/payments/legacy.ts")
        #expect(snapshot.source?.isFork == false)
        #expect(snapshot.baseSHA == "9c1e4d2b7a60")
        #expect(snapshot.nativeRefs["open_task_count"] == "1")
        #expect(snapshot.nativeRefs["pull_request_id"] == "42")
        #expect(snapshot.summary.versionToken == "2026-09-27T16:40:05.902114+00:00")
    }

    @Test func readinessIsBlockedWithHonestReasons() async throws {
        let snapshot = try await Harness().snapshot(42)
        guard case .blocked(let reasons) = snapshot.readiness else {
            Issue.record("expected blocked, got \(snapshot.readiness)")
            return
        }
        #expect(reasons == [
            "Changes requested by Lucía Moreno",
            "3 unresolved comment threads",
            "1 open task",
            "Failing checks: Pipeline › Unit tests",
        ])
    }

    @Test func greenPullRequestIsChecksGreenNeverReadyToMerge() async throws {
        let snapshot = try await Harness().snapshot(7)
        #expect(snapshot.aggregateCheckState == .passing)
        #expect(snapshot.checks.map(\.name) == ["Vercel preview", "Pipeline › Build"], "the mirrored pipeline status is dropped")
        #expect(snapshot.unresolvedThreadCount == 0)
        #expect(snapshot.readiness == .checksGreen)
        #expect(snapshot.reviewers.first?.state == .pending)
        #expect(snapshot.summary.involvement.contains(.reviewRequested))
    }

    @Test func forkPullRequestUsesTheForkForFetchingAndSkipsPipelines() async throws {
        let harness = Harness()
        let snapshot = try await harness.snapshot(12)
        let source = try #require(snapshot.source)
        #expect(source.isFork)
        #expect(source.fullPath == "mona-dev/payments-api")
        #expect(source.remoteID == BitbucketFixtures.IDs.forkRepoUUID)
        #expect(source.cloneURLs == ["https://bitbucket.org/mona-dev/payments-api.git", "git@bitbucket.org:mona-dev/payments-api.git"])
        #expect(harness.requests(containing: "/pipelines").isEmpty)

        let spec = try #require(harness.provider.fetchHeadSpec(for: snapshot))
        #expect(spec.isFork)
        #expect(spec.refspec == "refs/heads/docs/refund-typo")
        #expect(spec.remoteURLs == source.cloneURLs)
        #expect(spec.expectedSHA == BitbucketFixtures.IDs.head12)
        #expect(snapshot.readiness == .unknown, "no checks and no visible blockers: readiness is unknown")
    }

    @Test func sameRepositoryFetchHeadSpecUsesTheRepository() async throws {
        let harness = Harness()
        let snapshot = try await harness.snapshot(42)
        let spec = try #require(harness.provider.fetchHeadSpec(for: snapshot))
        #expect(!spec.isFork)
        #expect(spec.remoteURLs.contains("git@bitbucket.org:acme/payments-api.git"))
        #expect(spec.refspec == "refs/heads/feature/refund-guard")
    }

    @Test func optionalDataIsSkippedWhenTheTokenLacksScope() async throws {
        let forbidden = StubTransport.json(#"{"type":"error","error":{"message":"Forbidden"}}"#, status: 403)
        let harness = Harness(extraRoutes: [
            .fixed("GET", "/repositories/acme/payments-api/pipelines", response: forbidden),
            .fixed("GET", "/repositories/acme/payments-api/pullrequests/42/tasks", response: forbidden),
        ])
        let snapshot = try await harness.snapshot(42)
        #expect(snapshot.nativeRefs["pipelines"] == "unavailable")
        #expect(snapshot.nativeRefs["tasks"] == "unavailable")
        #expect(snapshot.checks.map(\.name).contains("Pipeline #101 for feature/refund-guard"),
                "without pipeline data the mirrored status is kept")
    }

    // MARK: Step diffs

    @Test func stepOneAddsABlockingCommentAndAFailedRerun() async throws {
        let snapshot = try await Harness(step: 1).snapshot(42)
        let blocking = try #require(snapshot.threads.first { $0.key.remoteID == "513" })
        #expect(blocking.isResolved == false)
        #expect(blocking.comments.first?.body.hasPrefix("Blocking:") == true)
        #expect(snapshot.unresolvedThreadCount == 4)
        let unit = try #require(snapshot.checks.first { $0.name == "Pipeline › Unit tests" })
        #expect(unit.key.remoteID == "102/\(BitbucketFixtures.IDs.unitTestsStep102)", "the re-run supersedes run #101")
        #expect(unit.status == .failure)
        #expect(snapshot.checks.count == 3)
        #expect(snapshot.summary.versionToken == "2026-09-27T18:02:31.330871+00:00")
    }

    @Test func stepTwoAddsAReplyAndRecoversCI() async throws {
        let harness = Harness(step: 1)
        _ = try await harness.snapshot(42)
        harness.transport.replaceRoutes(BitbucketFixtures.routes(step: 2))
        let snapshot = try await harness.snapshot(42)
        let blocking = try #require(snapshot.threads.first { $0.key.remoteID == "513" })
        #expect(blocking.comments.map(\.id) == ["513", "514"])
        #expect(blocking.comments.last?.inReplyToID == "513")
        #expect(snapshot.aggregateCheckState == .passing)
        #expect(snapshot.checks.allSatisfy { $0.status == .success })
        guard case .blocked(let reasons) = snapshot.readiness else {
            Issue.record("still blocked by review state")
            return
        }
        #expect(!reasons.contains { $0.hasPrefix("Failing checks") })
        #expect(reasons.contains("Changes requested by Lucía Moreno"))
    }
}
