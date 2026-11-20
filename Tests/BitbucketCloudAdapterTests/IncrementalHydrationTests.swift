import Foundation
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing
@testable import BitbucketCloudAdapter

/// `hydrate(_:previous:)` skip rules (DECISIONS D36), each from a Bitbucket change indicator.
@Suite("Bitbucket incremental hydration")
struct BitbucketIncrementalHydrationTests {
    /// After the fixture data (2026-09-27), so nothing in it counts as "recent".
    static let later = Date(timeIntervalSince1970: 1_791_000_000)

    struct Setup {
        let transport: StubTransport
        let provider: BitbucketCloudProvider
        let clock: TestClock

        init(step: Int = 0) {
            clock = TestClock(now: BitbucketIncrementalHydrationTests.later)
            transport = BitbucketFixtures.transport(step: step)
            provider = BitbucketCloudProvider(
                instance: BitbucketFixtures.instance, credential: .bearer("fixture-bitbucket-token"), transport: transport,
                clock: clock, directory: BitbucketRepositoryDirectory()
            )
        }

        func listed(_ number: Int) async throws -> ChangeRequestSummary {
            try #require(try await provider.listChangeRequests(ChangeRequestQuery(scope: .authored)).items.first { $0.key.number == number })
        }

        func paths(after count: Int) -> [String] {
            transport.requests.dropFirst(count).map { $0.url.path(percentEncoded: false) }
        }
    }

    @Test func theListingStandsInForTheDetailRequest() async throws {
        let setup = Setup()
        let summary = try await setup.listed(42)
        let before = setup.transport.requests.count
        _ = try await setup.provider.hydrate(summary)
        #expect(!setup.paths(after: before).contains("/2.0/repositories/acme/payments-api/pullrequests/42"),
                "participants came with the listing: no detail GET")
        // A minute later the listing is stale: the detail is read again.
        setup.clock.advance(by: 120)
        let again = setup.transport.requests.count
        _ = try await setup.provider.hydrate(summary)
        #expect(setup.paths(after: again).contains("/2.0/repositories/acme/payments-api/pullrequests/42"))
    }

    @Test func nothingChangedReusesEverySubResource() async throws {
        let setup = Setup()
        let summary = try await setup.listed(42)
        let first = try await setup.provider.hydrate(summary)
        let before = setup.transport.requests.count
        let second = try await setup.provider.hydrate(summary, previous: first)
        let paths = setup.paths(after: before)
        for resource in ["/comments", "/tasks", "/commits", "/diffstat", "/statuses", "/pipelines"] {
            #expect(!paths.contains { $0.contains(resource) }, "\(resource) skipped: \(paths)")
        }
        #expect(second.threads == first.threads)
        #expect(second.checks == first.checks)
        #expect(second.commits == first.commits && second.changedFiles == first.changedFiles)
        #expect(second.readiness == first.readiness)
        #expect(second.summary.headSHA == first.summary.headSHA, "the full head SHA is kept without /commits")
    }

    @Test func aNewCommentIsDetectedFromCommentCountAndRefetched() async throws {
        let setup = Setup(step: 0)
        let first = try await setup.provider.hydrate(try await setup.listed(42))
        setup.transport.replaceRoutes(BitbucketFixtures.routes(step: 1))
        let changed = try await setup.listed(42)
        #expect(changed.versionToken != first.summary.versionToken, "the listing carries the new comment_count")
        let before = setup.transport.requests.count
        let second = try await setup.provider.hydrate(changed, previous: first)
        let paths = setup.paths(after: before)
        #expect(paths.contains { $0.hasSuffix("/pullrequests/42/comments") }, "comments refetched")
        #expect(second.threads.contains { $0.key.remoteID == "513" }, "the new blocking comment arrived")
        #expect(!paths.contains { $0.contains("/diffstat") }, "same head: files reused")
    }

    @Test func checksAreReReadWhilePendingOrRecent() throws {
        let key = ChangeRequestKey(repo: RepoKey(account: BitbucketFixtures.accountKey, remoteRepoID: "{r}"), remoteID: "1", number: 1)
        let now = Self.later
        func snapshot(_ status: CheckStatus, completedAgo: TimeInterval, headSeenAgo: TimeInterval) -> ChangeRequestSnapshot {
            ChangeRequestSnapshot(
                summary: ChangeRequestSummary(
                    key: key, repository: Repository(key: key.repo, namespacePath: "acme", name: "r", fullPath: "acme/r", webURL: URL(string: "https://bitbucket.org/acme/r")!),
                    title: "t", author: Person(remoteID: "u", username: "u"), sourceBranch: "b", targetBranch: "main",
                    createdAt: now, updatedAt: now, webURL: URL(string: "https://bitbucket.org/acme/r/pull-requests/1")!
                ),
                checks: [CheckRun(
                    key: CheckKey(changeRequest: key, source: .bitbucketStatus, remoteID: "ci"), name: "CI", status: status,
                    completedAt: now.addingTimeInterval(-completedAgo)
                )],
                fetchedAt: now,
                nativeRefs: ["head_seen_at": String(now.addingTimeInterval(-headSeenAgo).timeIntervalSinceReferenceDate)]
            )
        }
        let seen = { (s: ChangeRequestSnapshot) in s.nativeRefs["head_seen_at"] }
        #expect(BitbucketReuse.checksMayChange(snapshot(.inProgress, completedAgo: 3_600, headSeenAgo: 3_600), headSeenAt: seen(snapshot(.inProgress, completedAgo: 3_600, headSeenAgo: 3_600)), now: now))
        #expect(BitbucketReuse.checksMayChange(snapshot(.success, completedAgo: 60, headSeenAgo: 3_600), headSeenAt: seen(snapshot(.success, completedAgo: 60, headSeenAgo: 3_600)), now: now))
        #expect(BitbucketReuse.checksMayChange(snapshot(.success, completedAgo: 3_600, headSeenAgo: 120), headSeenAt: seen(snapshot(.success, completedAgo: 3_600, headSeenAgo: 120)), now: now))
        let settled = snapshot(.success, completedAgo: 3_600, headSeenAgo: 3_600)
        #expect(!BitbucketReuse.checksMayChange(settled, headSeenAt: seen(settled), now: now))
    }

    @Test func directRepositoryEndpointsAvoidThePullRequestRedirects() async throws {
        let setup = Setup()
        let before = setup.transport.requests.count
        _ = try await setup.provider.hydrate(try await setup.listed(42))
        let paths = setup.paths(after: before)
        #expect(paths.contains { $0.contains("/repositories/acme/payments-api/commits/") })
        #expect(paths.contains { $0.contains("/repositories/acme/payments-api/diffstat/") })
        #expect(!paths.contains { $0.hasSuffix("/pullrequests/42/diffstat") || $0.hasSuffix("/pullrequests/42/commits") })
    }

    @Test func watchedAuthoredListingUsesTheWorkspaceEndpointFilteredClientSide() async throws {
        let setup = Setup()
        let payments = Repository(
            key: RepoKey(account: BitbucketFixtures.accountKey, remoteRepoID: BitbucketFixtures.IDs.paymentsRepoUUID),
            namespacePath: "acme", name: "payments-api", fullPath: "acme/payments-api",
            webURL: URL(string: "https://bitbucket.org/acme/payments-api")!
        )
        let other = Repository(
            key: RepoKey(account: BitbucketFixtures.accountKey, remoteRepoID: "{00000000-0000-4000-8000-000000000099}"),
            namespacePath: "acme", name: "other", fullPath: "acme/other", webURL: URL(string: "https://bitbucket.org/acme/other")!
        )
        let page = try await setup.provider.listChangeRequests(
            ChangeRequestQuery(scope: .authored, repositories: [other], restrictToRepositories: true)
        )
        #expect(page.items.isEmpty, "PRs of unwatched repositories are dropped")
        let watched = try await setup.provider.listChangeRequests(
            ChangeRequestQuery(scope: .authored, repositories: [payments, other], restrictToRepositories: true)
        )
        #expect(Set(watched.items.map(\.key.number)) == [42, 12])
        let paths = setup.transport.requests.map { $0.url.path(percentEncoded: false) }
        #expect(!paths.contains("/2.0/user/workspaces"), "the workspace comes from the watched repository")
        #expect(paths.filter { $0.hasPrefix("/2.0/workspaces/acme/pullrequests/") }.count >= 2, "one listing per cycle")
    }

    @Test func rateLimitHeadersAreParsed() {
        let url = URL(string: "https://api.bitbucket.org/2.0/user")!
        let parser = BitbucketRateLimitParser()
        let near = parser.parse(HTTPResponse(status: 200, headers: ["X-RateLimit-Limit": "1000", "X-RateLimit-NearLimit": "true"], url: url))
        #expect(near?.limit == 1_000 && near?.remaining == 200 && near?.resetAt == nil)
        let calm = parser.parse(HTTPResponse(status: 200, headers: ["X-RateLimit-Limit": "1000", "X-RateLimit-NearLimit": "false"], url: url))
        #expect(calm?.limit == 1_000 && calm?.remaining == nil)
        #expect(parser.parse(HTTPResponse(status: 200, url: url)) == nil)
    }

    @Test func involvedWindowIsAppliedServerSide() {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let bbql = BitbucketIdentifiers.participantQuery(userUUID: "{u}", updatedSince: since)
        #expect(bbql.hasPrefix(#"state="OPEN" AND updated_on > 2026-"#))
        #expect(!bbql.contains("\"2026"), "BBQL datetimes are unquoted")
        #expect(BitbucketIdentifiers.participantQuery(userUUID: "{u}") == #"state="OPEN""#)
    }
}
