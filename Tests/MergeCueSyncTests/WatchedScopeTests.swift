import Foundation
import MergeCueCore
import MergeCueStore
import Testing
@testable import MergeCueSync

/// Watched repositories, per-account refresh intervals and the in-place account updates of DECISIONS D36.
@Suite("Sync watched repositories and refresh intervals")
struct WatchedScopeTests {
    typealias F = SyncFixture
    static let quiet = F.at(-86_400)
    let watchedRepo = RepoKey(account: F.github, remoteRepoID: "repo-1")
    let otherRepo = RepoKey(account: F.github, remoteRepoID: "repo-2")

    func status(_ coordinator: SyncCoordinator) async throws -> AccountSyncStatus {
        try #require(await coordinator.statuses().first { $0.account == F.github })
    }

    func setAccount(_ h: SyncHarness, _ change: (inout Account) -> Void) async throws {
        var account = try #require(try await h.database.account(F.github))
        change(&account)
        try await h.database.upsertAccount(account)
    }

    @Test func effectiveListFollowsMappingsUntilChosen() {
        var account = F.account(F.github)
        let mapped = [watchedRepo, watchedRepo, RepoKey(account: F.gitlab, remoteRepoID: "x")]
        #expect(WatchedRepositories.effective(for: account, mapped: mapped) == [watchedRepo], "mapped, deduplicated, own account only")
        #expect(WatchedRepositories.effective(for: account, mapped: []).isEmpty, "nothing mapped: all repositories")
        account.watchedRepositories = [otherRepo]
        #expect(WatchedRepositories.effective(for: account, mapped: mapped) == [otherRepo], "an explicit list wins")
        account.watchedRepositories = []
        #expect(WatchedRepositories.effective(for: account, mapped: mapped).isEmpty, "explicit empty: all repositories")
        var demo = F.account(F.github)
        demo.isDemo = true
        #expect(WatchedRepositories.effective(for: demo, mapped: mapped).isEmpty, "demo accounts show every fixture repository")
    }

    @Test func watchedRepositoriesScopeTheListingAndDropOthersWithoutRequests() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        let watchedCR = F.crKey(number: 1, repoID: "repo-1")
        let otherCR = F.crKey(number: 2, repoID: "repo-2")
        remote.put(F.snapshot(watchedCR, updatedAt: Self.quiet))
        remote.put(F.snapshot(otherCR, updatedAt: Self.quiet))
        try await h.database.upsertRepositories([F.repository(watchedRepo), F.repository(otherRepo, fullPath: "acme/web")])
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(Set(try await h.database.snapshots(account: F.github).map(\.key)) == [watchedCR, otherCR], "nothing watched: all")
        #expect(remote.queries.allSatisfy { !$0.restrictToRepositories && $0.repositories.isEmpty },
                "never every stored repository")

        try await setAccount(h) { $0.watchedRepositories = [watchedRepo] }
        let hydrationsBefore = remote.totalHydrateCalls
        await coordinator.accountsDidChange()
        await h.clock.waitForSleepers(count: 1)
        let scoped = remote.queries.suffix(2)
        #expect(scoped.allSatisfy { $0.restrictToRepositories && $0.repositories.map(\.key) == [watchedRepo] })
        #expect(try await h.database.snapshots(account: F.github).map(\.key) == [watchedCR])
        #expect(remote.totalHydrateCalls == hydrationsBefore, "the unwatched CR is forgotten without another request")
        #expect(h.factory.providersMade(for: F.github) == 1, "a metadata change keeps the provider and its caches")
        await coordinator.stop()
    }

    @Test func mappingsAreTheDefaultWatchedRepositories() async throws {
        let h = try await SyncHarness()
        h.remote().put(F.snapshot(F.crKey(number: 1, repoID: "repo-1"), updatedAt: Self.quiet))
        h.remote().put(F.snapshot(F.crKey(number: 2, repoID: "repo-2"), updatedAt: Self.quiet))
        try await h.database.upsertMapping(RepoMapping(
            id: "map_1", repo: watchedRepo, repoFullPath: "acme/payments-api", checkoutPath: "/tmp/payments",
            confidence: .exact, confirmedAt: F.start, createdAt: F.start
        ))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await h.database.snapshots(account: F.github).map(\.key.repo) == [watchedRepo])
        #expect(h.remote().queries.first?.repositories.first?.fullPath == "acme/payments-api", "resolved from the mapping")
        await coordinator.stop()
    }

    @Test func incrementalHydrationReceivesTheStoredSnapshot() async throws {
        let h = try await SyncHarness()
        let key = F.crKey()
        h.remote().put(F.snapshot(key, updatedAt: Self.quiet))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        h.remote().update(key) { $0 = $0.touched(100) }
        await h.advance(120)
        await coordinator.refresh(account: F.github)
        #expect(h.remote().hydratedWithPrevious(key) == [false, true])
        await coordinator.stop()
    }

    @Test func manualRefreshHydratesOnlyWhatChangedOrHasPendingChecks() async throws {
        let h = try await SyncHarness()
        let quietCR = F.crKey(number: 1)
        let pendingCR = F.crKey(number: 2)
        h.remote().put(F.snapshot(quietCR, updatedAt: Self.quiet))
        h.remote().put({ () -> ChangeRequestSnapshot in
            var snapshot = F.snapshot(pendingCR, updatedAt: Self.quiet)
            snapshot.checks = [F.check(pendingCR, id: "1", status: .inProgress, at: -60)]
            snapshot.aggregateCheckState = .pending
            return snapshot
        }())
        let coordinator = await h.makeCoordinator(configuration: .deterministic)
        await h.start(coordinator)
        await h.advance(60)
        await coordinator.refresh(account: F.github)
        #expect(h.remote().hydrateCalls(quietCR) == 1, "unchanged and not due: not hydrated again")
        #expect(h.remote().hydrateCalls(pendingCR) == 2, "pending checks are invisible in the listing: re-read")
        await coordinator.stop()
    }

    @Test func manuallyOnlyListsAtLaunchAndOnRefreshNothingElse() async throws {
        let h = try await SyncHarness()
        try await setAccount(h) { $0.refreshInterval = .manual }
        let remote = h.remote()
        let key = F.crKey()
        var snapshot = F.snapshot(key)
        snapshot.checks = [F.check(key, id: "1", status: .inProgress, at: 0)]
        snapshot.aggregateCheckState = .pending
        remote.put(snapshot)
        let coordinator = await h.makeCoordinator()
        await coordinator.start()
        // The loop ends after the launch list: nothing is scheduled, so there is no sleeper to wait for.
        for _ in 0..<20_000 where remote.listCalls < 2 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(remote.listCalls == 2, "launch lists")
        #expect(try await status(coordinator).nextRunAt == nil, "no timer")
        h.clock.advance(by: 3 * 3_600)
        await coordinator.userDidReturn()
        await coordinator.handleSystemWake()
        try await Task.sleep(for: .milliseconds(50))
        #expect(remote.listCalls == 2, "no event refresh")
        #expect(remote.hydrateCalls(key) == 1, "no 30 s tier even with pending checks")
        await coordinator.refresh(account: F.github)
        #expect(remote.listCalls == 4, "manual refresh lists")
        #expect(remote.hydrateCalls(key) == 2, "and re-reads the pending checks")
        await coordinator.stop()
    }

    @Test func refreshIntervalSetsTheListCadence() async throws {
        let h = try await SyncHarness()
        try await setAccount(h) { $0.refreshInterval = .oneHour }
        h.remote().put(F.snapshot(F.crKey(), updatedAt: Self.quiet))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await status(coordinator).nextRunAt == F.at(3_600))

        try await setAccount(h) { $0.refreshInterval = .fiveMinutes }
        await coordinator.accountsDidChange()
        await h.clock.waitForSleepers(count: 1)
        #expect(try await status(coordinator).nextRunAt == F.at(300), "moved without listing again")
        #expect(h.remote().listCalls == 2)
        #expect(h.factory.providersMade(for: F.github) == 1)
        await coordinator.stop()
    }
}
