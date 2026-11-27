import Foundation
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import MergeCueRuntime
import MergeCueStore
import MergeCueSync
import Testing

/// Measures the exact HTTP requests one account sends through the real adapters and the real `SyncCoordinator`
/// (fixture transports, `TestClock`): first sync, a manual refresh with nothing changed, and a manual refresh after
/// one pull request got one new comment. Counts are provider requests as the runtime's ledger records them
/// (`CountingTransport`: redirect hops included, Bitbucket 304s included). The request lists are printed
/// (`[request-count]`) and the counts asserted, so a regression in the polling model shows up as a failing number.
///
/// Before DECISIONS D36 (same scenarios, main 6d6e57e, transport requests without redirect hops):
/// Bitbucket 500 repositories / 2 authored PRs: 19 / 2 / 10; with review requests on: 520 / 502 / 510;
/// GitHub fixtures: 5 / 1 / 4; GitLab fixtures: 23 / 2 / 12.
@Suite("Sync request counts", .serialized)
struct SyncRequestCountTests {
    /// One account wired like the live app (real adapters over a stub transport, counted per account).
    final class Harness: Sendable {
        let clock = TestClock()
        let database: MergeCueDatabase
        let credentials = InMemoryCredentialStore()
        let ledger = ProviderRequestLedger()
        let coordinator: SyncCoordinator
        let account: Account

        init(account: Account, credential: Credential, transport: StubTransport, tracking: TrackingPreferences = .authoredOnly) async throws {
            self.account = account
            database = try MergeCueDatabase.inMemory()
            try await database.upsertAccount(account)
            try credentials.save(credential, for: account.id)
            let factory = LiveProviderFactory(clock: clock, requestLedger: ledger, transport: { _ in transport })
            coordinator = SyncCoordinator(
                database: database, credentials: credentials, providers: factory, notifier: RecordingNotifier(), clock: clock,
                configuration: .deterministic, requestLedger: ledger
            )
            await coordinator.setTrackingPreferences(tracking)
        }

        func start() async {
            await coordinator.start()
            await clock.waitForSleepers(count: 1)
        }

        func advance(_ seconds: TimeInterval) async {
            clock.advance(by: seconds)
            await clock.waitForSleepers(count: 1)
        }

        func refresh() async {
            await coordinator.refresh(account: account.id)
            await clock.waitForSleepers(count: 1)
        }

        /// Provider requests recorded for the account in the last hour (redirect hops included).
        var requests: Int { ledger.count(account.id, now: clock.now) }

        func status() async -> AccountSyncStatus? {
            await coordinator.statuses().first { $0.account == account.id }
        }
    }

    static func report(_ title: String, _ lines: [String]) {
        print("[request-count] \(title): \(lines.count) requests")
        for line in lines { print("[request-count]   \(line)") }
    }

    // MARK: Bitbucket: 500 repositories, 2 authored open PRs

    static func bitbucketAccount(watching: [Int]? = nil) -> Account {
        let key = AccountKey(instance: .bitbucketCloud, remoteUserID: BitbucketWorld.userUUID)
        return Account(
            id: key, instance: .bitbucketCloud, username: "mona-dev", authMethod: .bitbucketAPIToken,
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            watchedRepositories: watching.map { $0.map { RepoKey(account: key, remoteRepoID: BitbucketWorld.repoUUID($0)) } }
        )
    }

    static func bitbucketWorld(now: Date) -> BitbucketWorld {
        let quiet = now.addingTimeInterval(-2 * 86_400)
        return BitbucketWorld(repositoryCount: 500, pullRequests: [
            .init(id: 11, repoIndex: 7, head: "aaaaaaaaaaaa1111111111111111111111111111", updatedOn: quiet, comments: [(101, quiet)]),
            .init(id: 12, repoIndex: 42, head: "bbbbbbbbbbbb2222222222222222222222222222", updatedOn: quiet, comments: [(201, quiet)]),
        ])
    }

    /// The repositories cached by the onboarding repository list (all 500), as the live app has them.
    static func cacheRepositories(_ h: Harness) async throws {
        let mapper = (0..<500).map { index in
            Repository(
                key: RepoKey(account: h.account.id, remoteRepoID: BitbucketWorld.repoUUID(index)),
                namespacePath: BitbucketWorld.workspace, name: BitbucketWorld.slug(index),
                fullPath: "\(BitbucketWorld.workspace)/\(BitbucketWorld.slug(index))",
                webURL: URL(string: "https://bitbucket.org/\(BitbucketWorld.workspace)/\(BitbucketWorld.slug(index))")!
            )
        }
        try await h.database.upsertRepositories(mapper)
    }

    struct Counts: CustomStringConvertible {
        var firstSync = 0
        var unchangedRefresh = 0
        var newCommentRefresh = 0
        var description: String { "first sync \(firstSync), unchanged refresh \(unchangedRefresh), new comment refresh \(newCommentRefresh)" }
    }

    static func measureBitbucket(tracking: TrackingPreferences, watching: [Int]?, label: String) async throws -> Counts {
        let clock = TestClock()
        let world = bitbucketWorld(now: clock.now)
        let h = try await Harness(
            account: bitbucketAccount(watching: watching),
            credential: .basic(username: "mona@example.com", password: "fixture-api-token"),
            transport: world.transport, tracking: tracking
        )
        try await cacheRepositories(h)
        var counts = Counts()

        await h.start()
        report("Bitbucket \(label): first sync", world.requestLines)
        counts.firstSync = h.requests
        #expect(await h.status()?.state == .ok)
        #expect(try await h.database.snapshots(account: h.account.id).count == 2)

        await h.advance(120)
        world.clear()
        var before = h.requests
        await h.refresh()
        report("Bitbucket \(label): refresh, nothing changed", world.requestLines)
        counts.unchangedRefresh = h.requests - before

        await h.advance(120)
        let now = h.clock.now
        world.update { state in
            state.pullRequests[0].comments.append((102, now))
            state.pullRequests[0].updatedOn = now
        }
        world.clear()
        before = h.requests
        await h.refresh()
        report("Bitbucket \(label): refresh, one new comment", world.requestLines)
        counts.newCommentRefresh = h.requests - before
        let snapshot = try await h.database.snapshots(account: h.account.id).first { $0.key.number == 11 }
        #expect(snapshot?.threads.count == 2, "the new comment was fetched")
        #expect(snapshot?.checks.isEmpty == false, "checks are kept from the previous hydration")
        #expect(snapshot?.commits.count == 1 && snapshot?.changedFiles.count == 1, "commits and files are kept")
        await h.coordinator.stop()
        print("[request-count] Bitbucket \(label) totals: \(counts)")
        return counts
    }

    /// The owner's case: two watched repositories of a 500-repository workspace, two authored open PRs.
    @Test func bitbucketWatchedAuthoredOnly() async throws {
        let counts = try await Self.measureBitbucket(tracking: .authoredOnly, watching: [7, 42], label: "2 watched, authored only")
        // /user + one workspace listing + per PR: comments, statuses, commits, diffstat (green Pipelines status:
        // no steps; no open task: no /tasks).
        #expect(counts.firstSync == 10)
        #expect(counts.unchangedRefresh == 1, "one workspace listing")
        #expect(counts.newCommentRefresh == 2, "listing + comments of the changed PR")
    }

    @Test func bitbucketWatchedWithReviewRequests() async throws {
        let counts = try await Self.measureBitbucket(
            tracking: TrackingPreferences(includeReviewRequests: true), watching: [7, 42], label: "2 watched, authored + review requests"
        )
        #expect(counts.firstSync == 12, "two reviewer queries (one per watched repository), not 500")
        #expect(counts.unchangedRefresh == 3)
        #expect(counts.newCommentRefresh == 4)
    }

    @Test func bitbucketNothingWatchedAuthoredOnly() async throws {
        let counts = try await Self.measureBitbucket(tracking: .authoredOnly, watching: nil, label: "nothing watched, authored only")
        #expect(counts.firstSync == 11, "+ /user/workspaces (cached for the session)")
        #expect(counts.unchangedRefresh == 1)
        #expect(counts.newCommentRefresh == 2)
    }

    @Test func bitbucketNothingWatchedWithReviewRequests() async throws {
        let counts = try await Self.measureBitbucket(
            tracking: TrackingPreferences(includeReviewRequests: true), watching: nil, label: "nothing watched, authored + review requests"
        )
        // The 30 most recently updated repositories (listed once per session) instead of all 500 cached ones.
        #expect(counts.firstSync == 42)
        #expect(counts.unchangedRefresh == 31)
        #expect(counts.newCommentRefresh == 32)
    }

    // MARK: GitHub and GitLab fixtures (acme/payments-api #42 persona)

    static func fixtureAccount(_ key: AccountKey, instance: ProviderInstance, username: String, watching: [String]? = nil) -> Account {
        Account(
            id: key, instance: instance, username: username, authMethod: .personalAccessToken,
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            watchedRepositories: watching.map { $0.map { RepoKey(account: key, remoteRepoID: $0) } }
        )
    }

    static func lines(_ transport: StubTransport) -> [String] {
        transport.requests.map { request in
            var line = "\(request.method) \(request.url.path(percentEncoded: false))"
            if request.url.path.hasSuffix("/graphql"), let body = request.body,
               let text = String(data: body, encoding: .utf8), let name = text.firstMatch(of: /query (MergeCue\w+)/)?.1 {
                line += " \(name)"
            } else if let query = request.url.query(percentEncoded: false), !query.isEmpty {
                line += "?\(query)"
            }
            return line
        }
    }

    /// Step 0 baseline → refresh (unchanged) → step 1 (a new blocking review comment + a failed check) → refresh.
    static func measureFixtures(
        name: String, account: Account, credential: Credential, routes: @escaping @Sendable (Int) -> [StubTransport.Route], baseURL: URL,
        repositories: [Repository] = []
    ) async throws -> Counts {
        let transport = StubTransport(routes: routes(0), baseURL: baseURL)
        let h = try await Harness(account: account, credential: credential, transport: transport)
        try await h.database.upsertRepositories(repositories)
        var counts = Counts()
        await h.start()
        report("\(name): first sync", lines(transport))
        counts.firstSync = h.requests
        #expect(await h.status()?.state == .ok)

        await h.advance(120)
        transport.clearRequests()
        var before = h.requests
        await h.refresh()
        report("\(name): refresh, nothing changed", lines(transport))
        counts.unchangedRefresh = h.requests - before

        await h.advance(120)
        transport.replaceRoutes(routes(1))
        transport.clearRequests()
        before = h.requests
        await h.refresh()
        report("\(name): refresh, new comment (fixture step 1)", lines(transport))
        counts.newCommentRefresh = h.requests - before
        await h.coordinator.stop()
        print("[request-count] \(name) totals: \(counts)")
        return counts
    }

    @Test func gitHubFixtures() async throws {
        let counts = try await Self.measureFixtures(
            name: "GitHub", account: Self.fixtureAccount(GitHubFixtures.accountKey, instance: GitHubFixtures.instance, username: "mona-dev"),
            credential: GitHubFixtures.credential, routes: { GitHubFixtures.routes(step: $0) }, baseURL: GitHubFixtures.instance.apiURL
        )
        #expect(counts.firstSync == 5)
        #expect(counts.unchangedRefresh == 1)
        #expect(counts.newCommentRefresh == 4)
    }

    @Test func gitHubFixturesWatched() async throws {
        let key = GitHubFixtures.accountKey
        let payments = Repository(
            key: RepoKey(account: key, remoteRepoID: GitHubFixtures.IDs.paymentsRepo), namespacePath: "acme", name: "payments-api",
            fullPath: "acme/payments-api", webURL: URL(string: "https://github.com/acme/payments-api")!
        )
        let counts = try await Self.measureFixtures(
            name: "GitHub watched", account: Self.fixtureAccount(key, instance: GitHubFixtures.instance, username: "mona-dev", watching: [GitHubFixtures.IDs.paymentsRepo]),
            credential: GitHubFixtures.credential, routes: { GitHubFixtures.routes(step: $0) }, baseURL: GitHubFixtures.instance.apiURL,
            repositories: [payments]
        )
        #expect(counts.firstSync <= 5)
        #expect(counts.unchangedRefresh == 1, "one search qualified with repo:acme/payments-api")
    }

    @Test func gitLabFixtures() async throws {
        let counts = try await Self.measureFixtures(
            name: "GitLab", account: Self.fixtureAccount(GitLabFixtures.accountKey, instance: GitLabFixtures.instance, username: "mona-dev"),
            credential: GitLabFixtures.credential, routes: { GitLabFixtures.routes(step: $0) }, baseURL: GitLabFixtures.instance.apiURL
        )
        #expect(counts.firstSync == 22)
        // MR !12 has a running pipeline: a manual refresh re-reads it (detail + jobs); the listing answers 304.
        #expect(counts.unchangedRefresh == 2)
        #expect(counts.newCommentRefresh == 9, "detail + discussions (2 pages) + approvals + reviewers + jobs; no commits/diffs/versions/project")
    }

    @Test func gitLabFixturesWatched() async throws {
        let key = GitLabFixtures.accountKey
        let payments = Repository(
            key: GitLabFixtures.repoKey(project: GitLabFixtures.IDs.paymentsProject), namespacePath: "acme", name: "payments-api",
            fullPath: "acme/payments-api", webURL: URL(string: "https://gitlab.com/acme/payments-api")!
        )
        let counts = try await Self.measureFixtures(
            name: "GitLab watched",
            account: Self.fixtureAccount(key, instance: GitLabFixtures.instance, username: "mona-dev", watching: [GitLabFixtures.IDs.paymentsProject]),
            credential: GitLabFixtures.credential, routes: { GitLabFixtures.routes(step: $0) }, baseURL: GitLabFixtures.instance.apiURL,
            repositories: [payments]
        )
        #expect(counts.firstSync == 21, "one project listing instead of the account-wide pages")
        #expect(counts.unchangedRefresh == 2, "the project listing answers 304; MR !12's running pipeline is re-read")
        #expect(counts.newCommentRefresh == 9)
    }
}
