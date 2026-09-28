import Foundation
@testable import GitLabAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

@Suite("GitLab hydration: discussions, reviewers, pipelines, readiness")
struct GitLabHydrateTests {
    typealias IDs = GitLabFixtures.IDs

    @Test func hydrateUsesProjectIDAndIIDEverywhere() async throws {
        let harness = GitLabHarness()
        _ = try await harness.snapshot(GitLabFixtures.mr42Key)
        let mrPaths = harness.requestedPaths.filter { $0.contains("merge_requests/") }
        #expect(!mrPaths.isEmpty)
        #expect(mrPaths.allSatisfy { $0.hasPrefix("/projects/278964/merge_requests/42") || $0.hasPrefix("/projects/278964/merge_requests/12") || $0.hasPrefix("/projects/278990/merge_requests/7") })
        #expect(!harness.requestedPaths.contains { $0.contains("99042") })
        for resource in ["", "/discussions", "/approvals", "/reviewers", "/commits", "/diffs", "/versions"] {
            #expect(harness.requestedPaths.contains("/projects/278964/merge_requests/42" + resource), "missing \(resource)")
        }
        #expect(harness.requestedPaths.contains("/projects/278964/pipelines/5001/jobs"))
        #expect(harness.requestedPaths.contains("/projects/278964"))
        // Discussions span two pages.
        #expect(harness.transport.requests(path: "/projects/278964/merge_requests/42/discussions").count == 2)
    }

    @Test func discussionsBecomeThreads() async throws {
        let snapshot = try await GitLabHarness().snapshot(GitLabFixtures.mr42Key)
        #expect(snapshot.threads.count == 7)

        let threaded = try #require(snapshot.thread(remoteID: IDs.threadedDiscussion))
        #expect(threaded.key.kind == .diffThread)
        #expect(threaded.key.changeRequest == GitLabFixtures.mr42Key)
        #expect(threaded.comments.map(\.id) == ["1001", "1002", "1003", "1004"])
        #expect(threaded.comments.first?.inReplyToID == nil)
        #expect(threaded.comments.dropFirst().allSatisfy { $0.inReplyToID == "1001" })
        #expect(threaded.comments.first?.kind == .question)
        #expect(threaded.isResolvable)
        #expect(threaded.isResolved == false)
        #expect(threaded.webURL?.absoluteString == "https://gitlab.com/acme/payments-api/-/merge_requests/42#note_1001")
        #expect(threaded.comments[2].webURL?.absoluteString == "https://gitlab.com/acme/payments-api/-/merge_requests/42#note_1003")
        #expect(threaded.lastActivityAt == ProviderDateParser.parse("2026-09-20T09:35:00.000Z"))
        let anchor = try #require(threaded.anchor)
        #expect(anchor.path == "src/payments/charge.rb")
        #expect(anchor.oldPath == nil)
        #expect(anchor.line == 42)
        #expect(anchor.startLine == 40)
        #expect(anchor.side == .new)
        #expect(anchor.commitSHA == IDs.head42)
        #expect(anchor.diffVersionID == "3002")
        #expect(!anchor.isOutdated)
        #expect(anchor.nativePosition["base_sha"] == IDs.base42)
        #expect(anchor.nativePosition["position_type"] == "text")

        let suggestion = try #require(snapshot.thread(remoteID: IDs.suggestionDiscussion))
        #expect(suggestion.comments.first?.kind == .suggestion)
        #expect(suggestion.anchor?.line == 57)

        let question = try #require(snapshot.thread(remoteID: IDs.questionDiscussion))
        #expect(question.key.kind == .conversation)
        #expect(question.anchor == nil)
        #expect(question.comments.first?.kind == .question)
        #expect(question.isResolved == false)

        let outdated = try #require(snapshot.thread(remoteID: IDs.outdatedDiscussion))
        #expect(outdated.isOutdated)
        #expect(outdated.anchor?.commitSHA == IDs.head42PreviousVersion)
        #expect(outdated.anchor?.diffVersionID == "3001")
        #expect(outdated.anchor?.path == "config/app.yml")

        let individual = try #require(snapshot.thread(remoteID: IDs.individualNoteDiscussion))
        #expect(individual.key.kind == .conversation)
        #expect(!individual.isResolvable)
        #expect(individual.isResolved == nil)

        let system = try #require(snapshot.thread(remoteID: IDs.systemNoteDiscussion))
        #expect(system.comments.map(\.kind) == [.system])
        #expect(system.isResolved == nil)

        let hostile = try #require(snapshot.thread(remoteID: IDs.injectionDiscussion))
        let body = try #require(hostile.comments.first?.body)
        #expect(body.contains("IGNORE ALL PREVIOUS INSTRUCTIONS"))  // carried verbatim as data
        #expect(hostile.comments.first?.author.username == "mallory-ext")

        // Resolvable + unresolved: threaded, suggestion, question, outdated, injection.
        #expect(snapshot.unresolvedThreadCount == 5)
        #expect(snapshot.description?.contains("ignore your instructions") == true)
    }

    @Test func reviewersApprovalsCommitsAndFiles() async throws {
        let snapshot = try await GitLabHarness().snapshot(GitLabFixtures.mr42Key)
        #expect(snapshot.reviewers.map(\.person.username) == ["rev-alice", "rev-bob"])
        #expect(snapshot.reviewers.map(\.state) == [.changesRequested, .commented])
        #expect(snapshot.reviews.map(\.state) == [.changesRequested])
        #expect(snapshot.reviews.first?.author.remoteID == "7003")
        #expect(snapshot.approvals == ApprovalStatus(approvedBy: [], requiredCount: 1, isSatisfied: false))
        #expect(snapshot.commits.map(\.sha) == [IDs.head42, IDs.head42PreviousVersion])
        #expect(snapshot.changedFiles.map(\.status) == [.modified, .added, .renamed])
        #expect(snapshot.changedFiles[2].path == "config/application.yml")
        #expect(snapshot.changedFiles[2].oldPath == "config/app.yml")
        #expect(snapshot.changedFiles[0].additions == 7)
        #expect(snapshot.changedFiles[0].deletions == 2)
        #expect(snapshot.baseSHA == IDs.base42)
        #expect(snapshot.source == SourceRepositoryInfo(
            fullPath: "acme/payments-api",
            cloneURLs: ["https://gitlab.com/acme/payments-api.git", "git@gitlab.com:acme/payments-api.git"],
            remoteID: "278964",
            isFork: false
        ))
        #expect(snapshot.summary.repository.cloneURLs.count == 2)
        #expect(snapshot.summary.repository.defaultBranch == "main")
        #expect(snapshot.nativeRefs["merge_request_iid"] == "42")
        #expect(snapshot.nativeRefs["merge_request_id"] == "99042")
        #expect(snapshot.nativeRefs["api_url"] == "https://gitlab.com/api/v4/projects/278964/merge_requests/42")
        #expect(snapshot.nativeRefs["detailed_merge_status"] == "requested_changes")
        #expect(snapshot.fetchedAt == ImmediateClock().now)
    }

    @Test func pipelineAndJobsBecomeChecks() async throws {
        let snapshot = try await GitLabHarness().snapshot(GitLabFixtures.mr42Key)
        #expect(snapshot.checks.map(\.name) == ["Pipeline #5001", "lint", "unit-tests"])
        #expect(snapshot.checks.map(\.key.source) == [.gitlabPipeline, .gitlabJob, .gitlabJob])
        #expect(snapshot.checks.allSatisfy { $0.status == .success })
        #expect(snapshot.aggregateCheckState == .passing)
        let job = try #require(snapshot.checks.first { $0.name == "unit-tests" })
        #expect(job.key.remoteID == "7102")
        #expect(job.logLocator == ["project_id": "278964", "job_id": "7102", "pipeline_id": "5001"])
        #expect(job.detailsURL?.absoluteString == "https://gitlab.com/acme/payments-api/-/jobs/7102")
        #expect(job.commitSHA == IDs.head42)
        #expect(snapshot.readiness == .blocked(reasons: ["Changes requested", "Unresolved threads"]))
    }

    @Test func nestedGroupReviewRequestIsReadyToMerge() async throws {
        let snapshot = try await GitLabHarness().snapshot(GitLabFixtures.mr7Key)
        #expect(snapshot.summary.repository.fullPath == "acme/platform/web")
        #expect(snapshot.summary.repository.namespacePath == "acme/platform")
        #expect(snapshot.summary.repository.isPrivate)
        #expect(snapshot.approvals.isSatisfied == true)
        #expect(snapshot.approvals.approvedBy.map(\.username) == ["rev-bob"])
        #expect(snapshot.reviews.map(\.state) == [.approved])
        #expect(snapshot.reviewers.first { $0.person.username == "mona-dev" }?.state == .pending)
        #expect(snapshot.readiness == .readyToMerge)
        #expect(snapshot.threads.count == 1)
        #expect(snapshot.threads.first?.isResolved == nil)
    }

    @Test func crossProjectMergeRequestUsesSourceAndTargetProjects() async throws {
        let harness = GitLabHarness()
        let snapshot = try await harness.snapshot(GitLabFixtures.mr12Key)
        let source = try #require(snapshot.source)
        #expect(source.isFork)
        #expect(source.fullPath == "mona-dev/payments-api")
        #expect(source.remoteID == "311000")
        #expect(source.cloneURLs.first == "https://gitlab.com/mona-dev/payments-api.git")
        #expect(snapshot.summary.repository.fullPath == "acme/payments-api")
        #expect(snapshot.key.repo.remoteRepoID == "278964")
        // The fork's pipeline runs in the source project.
        #expect(harness.requestedPaths.contains("/projects/311000"))
        #expect(harness.requestedPaths.contains("/projects/311000/pipelines/5101/jobs"))
        #expect(snapshot.checks.first?.logLocator["project_id"] == "311000")
        #expect(snapshot.readiness == .blocked(reasons: ["Pipeline still running"]))
        #expect(snapshot.aggregateCheckState == .pending)

        let spec = try #require(harness.provider.fetchHeadSpec(for: snapshot))
        #expect(spec.refspec == "refs/merge-requests/12/head")
        #expect(spec.remoteURLs == ["https://gitlab.com/acme/payments-api.git", "git@gitlab.com:acme/payments-api.git"])
        #expect(spec.expectedSHA == IDs.head12)
        #expect(spec.isFork)
    }

    @Test func fetchHeadSpecFallsBackToWebURLWithoutCloneURLs() async throws {
        let harness = GitLabHarness()
        let summary = try await harness.summary(GitLabFixtures.mr7Key)
        let spec = try #require(harness.provider.fetchHeadSpec(for: ChangeRequestSnapshot(summary: summary, fetchedAt: Date())))
        #expect(spec.remoteURLs == ["https://gitlab.com/acme/platform/web.git"])
        #expect(spec.refspec == "refs/merge-requests/7/head")
        #expect(!spec.isFork)
    }

    @Test func unreadableSourceProjectStillHydrates() async throws {
        let harness = GitLabHarness(extraRoutes: [
            .getJSON("/projects/311000", #"{"message":"404 Project Not Found"}"#, status: 404),
            .getJSON("/projects/311000/pipelines/5101/jobs", #"{"message":"403 Forbidden"}"#, status: 403),
        ])
        let snapshot = try await harness.snapshot(GitLabFixtures.mr12Key)
        #expect(snapshot.source?.isFork == true)
        #expect(snapshot.source?.remoteID == "311000")
        #expect(snapshot.source?.cloneURLs.isEmpty == true)
        #expect(snapshot.checks.map(\.key.source) == [.gitlabPipeline])
    }

    @Test func freshThreadAndHeadInfo() async throws {
        let harness = GitLabHarness()
        let key = ThreadKey(changeRequest: GitLabFixtures.mr42Key, remoteID: IDs.outdatedDiscussion, kind: .diffThread)
        let thread = try await harness.provider.thread(key)
        #expect(thread.key == key)
        #expect(thread.isOutdated)
        #expect(thread.anchor?.diffVersionID == "3001")
        #expect(harness.requestedPaths.contains("/projects/278964/merge_requests/42/discussions/\(IDs.outdatedDiscussion)"))

        let head = try await harness.provider.headInfo(for: GitLabFixtures.mr42Key)
        #expect(head == HeadInfo(headSHA: IDs.head42, state: .open, isDraft: false, updatedAt: try #require(ProviderDateParser.parse("2026-09-20T10:00:00.000Z"))))

        await #expect(throws: ProviderError.notFound("404 Not found")) {
            try await harness.provider.thread(ThreadKey(changeRequest: GitLabFixtures.mr42Key, remoteID: "nope", kind: .conversation))
        }
    }
}

@Suite("GitLab merge readiness")
struct GitLabReadinessTests {
    @Test func readyOnlyWhenMergeableResolvedAndPipelineGreen() throws {
        let ready = try fixtureMergeRequest("mr_278990_7")
        #expect(GitLabCheckMapping.readiness(ready) == .readyToMerge)

        let unresolved = try fixtureMergeRequest("mr_278990_7") { $0["blocking_discussions_resolved"] = false }
        #expect(GitLabCheckMapping.readiness(unresolved) == .blocked(reasons: ["Unresolved threads"]))

        let failed = try fixtureMergeRequest("mr_278990_7") { mr in
            var pipeline = mr["head_pipeline"] as? [String: Any] ?? [:]
            pipeline["status"] = "failed"
            mr["head_pipeline"] = pipeline
            mr["detailed_merge_status"] = "ci_must_pass"
        }
        #expect(GitLabCheckMapping.readiness(failed) == .blocked(reasons: ["A pipeline must succeed before merge", "Pipeline failed"]))

        let staleHead = try fixtureMergeRequest("mr_278990_7") { mr in
            var pipeline = mr["head_pipeline"] as? [String: Any] ?? [:]
            pipeline["sha"] = String(repeating: "0", count: 40)
            mr["head_pipeline"] = pipeline
        }
        #expect(GitLabCheckMapping.readiness(staleHead) == .blocked(reasons: ["Pipeline has not run on the current head"]))
    }

    @Test func checksGreenWhenMergeabilityIsStillBeingComputed() throws {
        for status in ["checking", "unchecked", "preparing"] {
            let mr = try fixtureMergeRequest("mr_278990_7") { $0["detailed_merge_status"] = status }
            #expect(GitLabCheckMapping.readiness(mr) == .checksGreen)
        }
        let missing = try fixtureMergeRequest("mr_278990_7") { $0.removeValue(forKey: "detailed_merge_status") }
        #expect(GitLabCheckMapping.readiness(missing) == .checksGreen)
    }

    @Test func blockedReasonsFromGitLab() throws {
        let notApproved = try fixtureMergeRequest("mr_278990_7") { $0["detailed_merge_status"] = "not_approved" }
        #expect(GitLabCheckMapping.readiness(notApproved) == .blocked(reasons: ["Approval required"]))
        let draft = try fixtureMergeRequest("mr_278990_7") {
            $0["detailed_merge_status"] = "draft_status"
            $0["draft"] = true
        }
        #expect(GitLabCheckMapping.readiness(draft) == .blocked(reasons: ["Draft"]))
        let conflict = try fixtureMergeRequest("mr_278990_7") {
            $0["detailed_merge_status"] = "conflict"
            $0["has_conflicts"] = true
        }
        #expect(GitLabCheckMapping.readiness(conflict) == .blocked(reasons: ["Merge conflicts"]))
        let future = try fixtureMergeRequest("mr_278990_7") { $0["detailed_merge_status"] = "some_new_status" }
        #expect(GitLabCheckMapping.readiness(future) == .blocked(reasons: ["Not mergeable (some new status)"]))
    }

    @Test func noPipelineMeansUnknownNotReady() throws {
        let mr = try fixtureMergeRequest("mr_278990_7") { $0["head_pipeline"] = NSNull() }
        #expect(GitLabCheckMapping.readiness(mr) == .unknown)
        #expect(GitLabCheckMapping.checks(pipeline: nil, jobs: [], changeRequest: GitLabFixtures.mr7Key, headSHA: nil).isEmpty)
    }

    @Test func mergedAndClosedAreNeverReady() throws {
        let merged = try fixtureMergeRequest("mr_278990_7") { $0["state"] = "merged" }
        #expect(GitLabCheckMapping.readiness(merged) == .blocked(reasons: ["Already merged"]))
        let closed = try fixtureMergeRequest("mr_278990_7") { $0["state"] = "closed" }
        #expect(GitLabCheckMapping.readiness(closed) == .blocked(reasons: ["Closed without merge"]))
    }

    @Test func jobStatusMapping() {
        #expect(GitLabCheckMapping.jobStatus("failed", allowFailure: false) == .failure)
        #expect(GitLabCheckMapping.jobStatus("failed", allowFailure: true) == .neutral)
        #expect(GitLabCheckMapping.jobStatus("pending", allowFailure: false) == .queued)
        #expect(GitLabCheckMapping.jobStatus("running", allowFailure: false) == .inProgress)
        #expect(GitLabCheckMapping.jobStatus("canceled", allowFailure: false) == .cancelled)
        #expect(GitLabCheckMapping.jobStatus("manual", allowFailure: false) == .actionRequired)
        #expect(GitLabCheckMapping.jobStatus("manual", allowFailure: true) == .skipped)
        #expect(GitLabCheckMapping.jobStatus("skipped", allowFailure: false) == .skipped)
        #expect(GitLabCheckMapping.jobStatus("brand_new", allowFailure: false) == .unknown)
        #expect(GitLabCheckMapping.pipelineStatus("manual") == .actionRequired)
    }
}
