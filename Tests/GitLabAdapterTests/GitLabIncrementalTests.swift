import Foundation
@testable import GitLabAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

/// GitLab `hydrate(_:previous:)` skip rules and watched-project listings (DECISIONS D36).
@Suite("GitLab incremental hydration and watched projects")
struct GitLabIncrementalTests {
    func paths(_ h: GitLabHarness, after count: Int) -> [String] {
        h.transport.requests.dropFirst(count).map { $0.url.path(percentEncoded: false) }
    }

    @Test func unchangedMergeRequestOnlyReadsItsDetail() async throws {
        let h = GitLabHarness()
        let summary = try await h.summary(GitLabFixtures.mr42Key)
        let first = try await h.provider.hydrate(summary)
        let before = h.transport.requests.count
        let second = try await h.provider.hydrate(summary, previous: first)
        let paths = paths(h, after: before)
        #expect(paths == ["/api/v4/projects/278964/merge_requests/42"], "\(paths)")
        #expect(second.threads == first.threads)
        #expect(second.checks == first.checks)
        #expect(second.commits == first.commits && second.changedFiles == first.changedFiles)
        #expect(second.reviewers == first.reviewers && second.approvals == first.approvals)
        #expect(second.summary.repository == first.summary.repository)
    }

    @Test func newActivityRefetchesDiscussionsButNotTheDiff() async throws {
        let h = GitLabHarness(step: 0)
        let first = try await h.provider.hydrate(try await h.summary(GitLabFixtures.mr42Key))
        h.transport.replaceRoutes(GitLabFixtures.routes(step: 1))
        let before = h.transport.requests.count
        let second = try await h.provider.hydrate(try await h.summary(GitLabFixtures.mr42Key), previous: first)
        let paths = paths(h, after: before)
        #expect(paths.contains { $0.hasSuffix("/merge_requests/42/discussions") }, "updated_at moved: discussions refetched")
        #expect(paths.contains { $0.contains("/pipelines/") && $0.hasSuffix("/jobs") }, "a new head pipeline: jobs refetched")
        #expect(!paths.contains { $0.hasSuffix("/diffs") || $0.hasSuffix("/commits") || $0.hasSuffix("/versions") }, "same head")
        #expect(!paths.contains("/api/v4/projects/278964"), "project reused")
        #expect(second.threads.contains { $0.key.remoteID == GitLabFixtures.IDs.blockingDiscussion })
        #expect(second.checks.contains { $0.status.isFailing })
    }

    @Test func watchedProjectsAreListedOneByOne() async throws {
        let h = GitLabHarness()
        let payments = Repository(
            key: GitLabFixtures.repoKey(project: GitLabFixtures.IDs.paymentsProject), namespacePath: "acme", name: "payments-api",
            fullPath: "acme/payments-api", webURL: URL(string: "https://gitlab.com/acme/payments-api")!
        )
        let page = try await h.provider.listChangeRequests(
            ChangeRequestQuery(scope: .authored, repositories: [payments], restrictToRepositories: true)
        )
        #expect(Set(page.items.map(\.key)) == [GitLabFixtures.mr42Key, GitLabFixtures.mr12Key])
        let listing = try #require(h.transport.requests.first { $0.url.path().hasSuffix("/projects/278964/merge_requests") })
        #expect(listing.queryItems.contains(URLQueryItem(name: "author_id", value: GitLabFixtures.user.remoteID)))
        #expect(!h.transport.requests.contains { $0.url.path() == "/api/v4/merge_requests" }, "no account-wide listing")
    }
}
