import Foundation
@testable import GitHubAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

@Suite("GitHub listing and hydration")
struct ListingAndHydrateTests {
    // MARK: Listing

    @Test func authoredListingIsOneSearchWithSummaries() async throws {
        let (provider, transport) = GH.provider()
        let page = try await provider.listChangeRequests(ChangeRequestQuery(scope: .authored))
        #expect(!page.notModified)
        #expect(page.items.map(\.key.number) == [42, 12])
        #expect(GH.operations(transport) == ["MergeCueSearch"])
        let query = try #require(transport.requests(path: "/graphql").first?.jsonBody?["variables"]?["q"]?.stringValue)
        #expect(query == "is:pr is:open archived:false author:@me")

        let pr = try #require(page.items.first)
        #expect(pr.key.remoteID == GH.IDs.pr42)
        #expect(pr.key.repo.remoteRepoID == GH.IDs.paymentsRepo)
        #expect(pr.key.account == GitHubFixtures.accountKey)
        #expect(pr.repository.fullPath == "acme/payments-api")
        #expect(pr.title == "Retry card charges on gateway timeouts")
        #expect(pr.author.username == "mona-dev" && pr.author.remoteID == "583231")
        #expect(pr.isDraft == false && pr.state == .open)
        #expect(pr.sourceBranch == "feature/charge-retries" && pr.targetBranch == "main")
        #expect(pr.headSHA == GH.IDs.head42)
        #expect(pr.involvement == [.authored])
        #expect(pr.webURL.absoluteString == "https://github.com/acme/payments-api/pull/42")
        #expect(pr.versionToken == "2026-09-20T10:00:00Z|\(GH.IDs.head42)|FAILURE")
        #expect(pr.ref.string == "github:github.com/acme/payments-api#42")
    }

    @Test func reviewRequestedListing() async throws {
        let (provider, transport) = GH.provider()
        let page = try await provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested))
        #expect(page.items.map(\.key.number) == [7])
        let pr = try #require(page.items.first)
        #expect(pr.involvement == [.reviewRequested])
        #expect(pr.repository.fullPath == "acme/web")
        #expect(pr.author.username == "carol-reviews")
        let query = transport.requests(path: "/graphql").first?.jsonBody?["variables"]?["q"]?.stringValue
        #expect(query == "is:pr is:open archived:false review-requested:@me")
    }

    @Test func involvedListingSearchesInvolvesButNotAuthored() async throws {
        let (provider, transport) = GH.provider()
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let page = try await provider.listChangeRequests(ChangeRequestQuery(scope: .involved, updatedSince: since))
        #expect(page.items.map(\.key.number) == [7])
        #expect(page.items.first?.involvement == [.participated])
        let query = transport.requests(path: "/graphql").first?.jsonBody?["variables"]?["q"]?.stringValue
        #expect(query == "is:pr is:open archived:false involves:@me -author:@me updated:>=2026-09-21T14:13:20Z")
        #expect(GitHubProvider.capabilityManifest.isUsable(.listInvolved))
        #expect(GitHubProvider.maxInvolvedPages == 2)
    }

    @Test func searchQueryQualifiersAndNamespaceFilter() async throws {
        let since = Date(timeIntervalSince1970: 1_790_000_000.25)
        let q = GitHubProvider.searchQuery(ChangeRequestQuery(scope: .authored, namespaces: ["acme", "bad name"], updatedSince: since))
        #expect(q == "is:pr is:open archived:false author:@me updated:>=2026-09-21T14:13:20Z user:acme")
        let long = GitHubProvider.searchQuery(ChangeRequestQuery(scope: .authored, namespaces: (0..<40).map { "org\($0)-namespace" }))
        #expect(long == "is:pr is:open archived:false author:@me")

        let (provider, _) = GH.provider()
        let filtered = try await provider.listChangeRequests(ChangeRequestQuery(scope: .authored, namespaces: ["someone-else"]))
        #expect(filtered.items.isEmpty)
    }

    // MARK: Hydration

    @Test func hydrationPaginatesThreadsAndThreadComments() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        #expect(GH.operations(transport) == [
            "MergeCueSearch", "MergeCuePullRequest", "MergeCueReviewThreadsPage", "MergeCueThreadCommentsPage",
        ])
        let pageRequest = try #require(transport.requests(path: "/graphql").first { $0.jsonBody?["operationName"]?.stringValue == "MergeCueReviewThreadsPage" })
        #expect(pageRequest.jsonBody?["variables"]?["after"]?.stringValue == GH.IDs.threadsCursor)
        #expect(pageRequest.jsonBody?["variables"]?["number"]?.intValue == 42)

        let diffThreads = snapshot.threads.filter { $0.key.kind == .diffThread }
        #expect(diffThreads.map(\.key.remoteID) == [
            GH.IDs.longThread, GH.IDs.suggestionThread, GH.IDs.questionThread, GH.IDs.resolvedThread,
            GH.IDs.outdatedThread, GH.IDs.hostileThread,
        ])
        let long = try GH.thread(snapshot, GH.IDs.longThread)
        #expect(long.comments.map(\.id) == ["2400000101", "2400000102", "2400000103", "2400000104"])
        #expect(long.comments.dropFirst().allSatisfy { $0.inReplyToID == GH.IDs.longThreadRootComment })
        #expect(long.comments.first?.inReplyToID == nil)
        #expect(long.isResolved == false && long.isResolvable)
        #expect(long.anchor?.path == "Sources/Payments/ChargeService.swift")
        #expect(long.anchor?.line == 84 && long.anchor?.side == .new)
        #expect(long.anchor?.commitSHA == GH.IDs.head42)
        #expect(long.anchor?.nativePosition["root_comment_id"] == GH.IDs.longThreadRootComment)
        #expect(long.webURL?.absoluteString == "https://github.com/acme/payments-api/pull/42#discussion_r2400000101")
        #expect(long.lastActivityAt == ISO8601DateFormatter().date(from: "2026-09-18T10:30:00Z"))
    }

    @Test func threadKindsAndIDsAreDistinct() async throws {
        let snapshot = try await GH.snapshot(step: 0)
        let conversation = snapshot.threads.filter { $0.key.kind == .conversation }
        #expect(conversation.map(\.key.remoteID) == ["ic:\(GH.IDs.issueComment)", "ic:\(GH.IDs.botIssueComment)"])
        #expect(conversation.allSatisfy { $0.isResolved == nil && !$0.isResolvable && $0.anchor == nil })
        #expect(conversation.last?.comments.first?.author.isBot == true)

        let summaries = snapshot.threads.filter { $0.key.kind == .reviewSummary }
        // Reviews without a body (the COMMENTED one) produce no thread.
        #expect(summaries.map(\.key.remoteID) == ["rv:\(GH.IDs.changesRequestedReview)"])
        let review = try #require(summaries.first)
        #expect(review.key == ThreadKey.githubReviewSummary(changeRequest: snapshot.key, reviewID: GH.IDs.changesRequestedReview))
        #expect(review.comments.first?.author.username == "carol-reviews")
        #expect(review.isResolved == nil)

        // Same numeric id space never collides across kinds.
        let ids = snapshot.threads.map(\.key.id)
        #expect(Set(ids).count == ids.count)
        let issueKey = ThreadKey.githubIssueComment(changeRequest: snapshot.key, commentID: "1")
        let reviewKey = ThreadKey.githubReviewSummary(changeRequest: snapshot.key, reviewID: "1")
        #expect(issueKey.id != reviewKey.id)
    }

    @Test func commentKindsOutdatedAnchorsAndHostileText() async throws {
        let snapshot = try await GH.snapshot(step: 0)
        #expect(try GH.thread(snapshot, GH.IDs.suggestionThread).comments.first?.kind == .suggestion)
        #expect(try GH.thread(snapshot, GH.IDs.questionThread).comments.first?.kind == .question)
        #expect(try GH.thread(snapshot, "rv:\(GH.IDs.changesRequestedReview)").comments.first?.kind == .question)
        #expect(try GH.thread(snapshot, GH.IDs.longThread).comments.first?.kind == .comment)

        let suggestion = try GH.thread(snapshot, GH.IDs.suggestionThread)
        #expect(suggestion.anchor?.startLine == 11 && suggestion.anchor?.line == 12)

        let outdated = try GH.thread(snapshot, GH.IDs.outdatedThread)
        #expect(outdated.isOutdated)
        #expect(outdated.anchor?.line == 40)  // falls back to originalLine
        #expect(outdated.anchor?.commitSHA == nil)
        #expect(outdated.anchor?.originalCommitSHA == "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432")
        #expect(outdated.anchor?.diffHunk?.hasPrefix("@@ -35,6 +35,8 @@") == true)
        #expect(outdated.isUnresolved)

        #expect(try GH.thread(snapshot, GH.IDs.resolvedThread).isResolved == true)

        // Untrusted text is carried verbatim as data.
        let hostile = try GH.thread(snapshot, GH.IDs.hostileThread)
        #expect(hostile.comments.first?.body.contains(GitHubFixtures.injectionString) == true)
        #expect(hostile.comments.first?.author.username == "mallory-contrib")
        #expect(snapshot.unresolvedThreadCount == 5)
    }

    @Test func checksReviewersAndMetadata() async throws {
        let snapshot = try await GH.snapshot(step: 0)
        #expect(snapshot.checks.map(\.name) == ["ci/lint", "unit-tests"])
        let lint = try #require(snapshot.checks.first)
        #expect(lint.key.source == .githubStatus && lint.key.remoteID == "ci/lint")
        #expect(lint.status == .success && lint.isRequired == false)
        #expect(lint.detailsURL?.absoluteString == "https://ci.acme.dev/builds/555")
        let job = try #require(snapshot.checks.last)
        #expect(job.key.source == .githubActionsJob && job.key.remoteID == GH.IDs.failingJob)
        #expect(job.status == .failure && job.isRequired == true)
        #expect(job.logLocator["job_id"] == "9001" && job.logLocator["run_id"] == "7001")
        #expect(job.logLocator["repo"] == "acme/payments-api" && job.logLocator["workflow"] == "CI")
        #expect(job.commitSHA == GH.IDs.head42)
        #expect(job.summary?.contains("2 tests failed") == true)
        #expect(snapshot.aggregateCheckState == .failing)

        #expect(snapshot.reviews.map(\.state) == [.changesRequested, .commented])
        #expect(snapshot.reviews.first?.remoteID == GH.IDs.changesRequestedReview)
        #expect(snapshot.reviews.last?.body == nil)
        #expect(snapshot.reviewers.map(\.person.username) == ["carol-reviews", "dave-sec", "payments-reviewers"])
        #expect(snapshot.reviewers.map(\.state) == [.changesRequested, .commented, .pending])
        #expect(snapshot.reviewers.last?.person.remoteID == "team:4401")
        #expect(snapshot.reviewers.last?.isRequired == true)
        #expect(snapshot.approvals.isSatisfied == false && snapshot.approvals.approvedBy.isEmpty)

        #expect(snapshot.commits.map(\.title) == ["Add retries to ChargeService", "Raise gateway timeout to 30s"])
        #expect(snapshot.changedFiles.count == 4)
        #expect(snapshot.changedFiles.first { $0.path.hasSuffix("RetryPolicy.swift") }?.status == .renamed)
        #expect(snapshot.baseSHA == GH.IDs.base42)
        #expect(snapshot.description?.contains("Demo fixture") == true)
        #expect(snapshot.source == SourceRepositoryInfo(
            fullPath: "acme/payments-api",
            cloneURLs: ["https://github.com/acme/payments-api.git", "git@github.com:acme/payments-api.git"],
            remoteID: GH.IDs.paymentsRepo, isFork: false
        ))
        #expect(snapshot.nativeRefs["merge_state_status"] == "BLOCKED")
        #expect(snapshot.nativeRefs["review_decision"] == "CHANGES_REQUESTED")
        #expect(snapshot.nativeRefs["api_url"] == "https://api.github.com/repos/acme/payments-api/pulls/42")
        #expect(snapshot.summary.involvement == [.authored])
        #expect(snapshot.readiness == .blocked(reasons: ["Changes requested", "5 unresolved threads", "Checks failing"]))
    }

    @Test func forkPullRequestIsReadyToMerge() async throws {
        let snapshot = try await GH.snapshot(step: 0, number: 12)
        #expect(snapshot.source?.isFork == true)
        #expect(snapshot.source?.fullPath == "mona-dev/payments-api")
        #expect(snapshot.source?.remoteID == GH.IDs.forkRepo)
        #expect(snapshot.summary.repository.fullPath == "acme/payments-api")
        #expect(snapshot.readiness == .readyToMerge)
        #expect(snapshot.approvals.isSatisfied == true)
        #expect(snapshot.approvals.approvedBy.map(\.username) == ["dave-sec"])
        #expect(snapshot.threads.isEmpty)
    }

    @Test func reviewRequestedPullRequestIsChecksGreen() async throws {
        let (provider, _) = GH.provider()
        let snapshot = try await GH.snapshot(provider, number: 7, scope: .reviewRequested)
        #expect(snapshot.readiness == .checksGreen)
        #expect(snapshot.aggregateCheckState == .passing)
        #expect(snapshot.reviewers.map(\.person.remoteID) == ["583231"])
        #expect(snapshot.reviewers.first?.state == .pending)
        #expect(snapshot.summary.involvement == [.reviewRequested])
    }

    @Test func freshThreadAndHeadReads() async throws {
        let (provider, transport) = GH.provider()
        let snapshot = try await GH.snapshot(provider)
        let fresh = try await provider.thread(ThreadKey(changeRequest: snapshot.key, remoteID: GH.IDs.longThread, kind: .diffThread))
        #expect(fresh == (try GH.thread(snapshot, GH.IDs.longThread)))

        let issue = try await provider.thread(.githubIssueComment(changeRequest: snapshot.key, commentID: GH.IDs.issueComment))
        let hydratedIssue = try GH.thread(snapshot, "ic:\(GH.IDs.issueComment)")
        #expect(issue.key == hydratedIssue.key && issue.webURL == hydratedIssue.webURL)
        #expect(issue.comments.map(\.id) == hydratedIssue.comments.map(\.id))
        #expect(issue.comments.first?.body == hydratedIssue.comments.first?.body)
        #expect(issue.comments.first?.author.remoteID == "700102")  // REST users carry no display name
        #expect(transport.requests("GET", path: "/repos/acme/payments-api/issues/comments/\(GH.IDs.issueComment)").count == 1)

        let review = try await provider.thread(.githubReviewSummary(changeRequest: snapshot.key, reviewID: GH.IDs.changesRequestedReview))
        #expect(review.comments.first?.body == (try GH.thread(snapshot, "rv:\(GH.IDs.changesRequestedReview)")).comments.first?.body)
        #expect(review.key.kind == .reviewSummary)

        let head = try await provider.headInfo(for: snapshot.key)
        #expect(head == HeadInfo(headSHA: GH.IDs.head42, state: .open, isDraft: false,
                                 updatedAt: try #require(ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z"))))

        await #expect(throws: ProviderError.self) {
            try await provider.thread(ThreadKey(changeRequest: snapshot.key, remoteID: "PRRT_missing", kind: .diffThread))
        }
    }

    @Test func unknownRepositoryPathIsResolvedByID() async throws {
        let (provider, transport) = GH.provider()  // fresh registry: nothing learned yet
        let repo = RepoKey(account: GitHubFixtures.accountKey, remoteRepoID: GH.IDs.paymentsRepo)
        let key = ChangeRequestKey(repo: repo, remoteID: GH.IDs.pr42, number: 42)
        #expect(provider.deepLink(to: .changeRequest(key)) == nil)
        let head = try await provider.headInfo(for: key)
        #expect(head.headSHA == GH.IDs.head42)
        #expect(transport.requests("GET", path: "/repositories/1296269").count == 1)
        _ = try await provider.headInfo(for: key)
        #expect(transport.requests("GET", path: "/repositories/1296269").count == 1)  // remembered
        #expect(provider.deepLink(to: .changeRequest(key))?.absoluteString == "https://github.com/acme/payments-api/pull/42")
    }
}
