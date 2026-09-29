import Foundation
import MergeCueCore
import MergeCueStore
import Testing
@testable import MergeCueSync

/// Per-account failure handling, scheduling and hydration behaviour.
@Suite("SyncCoordinator resilience")
struct SyncResilienceTests {
    typealias F = SyncFixture
    static let second = F.accountKey(.github, user: "1002")

    func status(_ coordinator: SyncCoordinator, _ account: AccountKey) async throws -> AccountSyncStatus {
        try #require(await coordinator.statuses().first { $0.account == account })
    }

    /// Yields until `condition` holds (no real time passes; bounded so a bug fails instead of hanging).
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<20_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    @Test func accountFailuresAreIndependent() async throws {
        let accounts = [F.github, F.gitlab, F.bitbucket, Self.second]
        let h = try await SyncHarness(accounts: accounts)
        for account in accounts { h.remote(account).put(F.snapshot(F.crKey(account))) }
        h.remote(F.gitlab).listError = .unauthorized("token revoked")
        h.remote(F.bitbucket).listError = .rateLimited(resetAt: nil, retryAfter: 600)
        h.remote(Self.second).listError = .offline
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator, sleepers: 3) // the auth-expired account does not schedule another run

        let ok = try await status(coordinator, F.github)
        #expect(ok.state == .ok)
        #expect(ok.lastSuccessAt == F.start)
        #expect(ok.nextRunAt == F.at(30), "the fresh CR's details refresh at the fast tier; the next list is at 15 min")
        let expired = try await status(coordinator, F.gitlab)
        #expect(expired.state == .authExpired)
        #expect(expired.nextRunAt == nil)
        #expect(expired.consecutiveFailures == 1)
        #expect(expired.message?.contains("Reconnect") == true)
        let limited = try await status(coordinator, F.bitbucket)
        #expect(limited.state == .rateLimited(until: F.at(600)))
        #expect(limited.nextRunAt == F.at(600))
        let offline = try await status(coordinator, Self.second)
        #expect(offline.state == .offline)
        #expect(offline.nextRunAt == F.at(30))

        // GitHub keeps syncing while the others are down.
        let key = F.crKey(F.github)
        let thread = F.threadKey(key)
        h.remote(F.github).update(key) { $0 = $0.touched(60); $0.threads = [F.thread(thread, comments: [F.comment("c1", at: 60)])] }
        await h.advance(90, sleepers: 3)
        #expect(h.notifier.delivered.map(\.changeRequest) == [key])
        #expect(h.remote(F.gitlab).listCalls == 2, "one cycle (two listings), no retries after 401")
        let stillOffline = try await status(coordinator, Self.second)
        #expect(stillOffline.consecutiveFailures == 2)
        #expect(stillOffline.nextRunAt == F.at(150), "backoff doubled to 60 s")
        #expect(try await status(coordinator, F.bitbucket).consecutiveFailures == 1)

        // Wake: offline account retries, the rate-limited one waits for its reset, auth stays stopped.
        let bitbucketCalls = h.remote(F.bitbucket).listCalls
        h.remote(Self.second).listError = nil
        await coordinator.handleSystemWake()
        #expect(try await status(coordinator, Self.second).state == .ok)
        #expect(try await status(coordinator, Self.second).consecutiveFailures == 0)
        #expect(h.remote(F.bitbucket).listCalls == bitbucketCalls)
        #expect(h.remote(F.gitlab).listCalls == 2)

        // Rate limit reset passes.
        h.remote(F.bitbucket).listError = nil
        await h.clock.waitForSleepers(count: 3)
        await h.advance(520, sleepers: 3)
        #expect(try await status(coordinator, F.bitbucket).state == .ok)

        // Reconnecting the expired account restarts it immediately.
        h.remote(F.gitlab).listError = nil
        try h.credentials.save(.bearer("new-token"), for: F.gitlab)
        await coordinator.accountsDidChange()
        await h.clock.waitForSleepers(count: 4)
        let recovered = try await status(coordinator, F.gitlab)
        #expect(recovered.state == .ok)
        #expect(recovered.consecutiveFailures == 0)
        #expect(h.factory.providersMade(for: F.gitlab) == 2)
        await coordinator.stop()
    }

    @Test func networkRecoveryRefreshesAccounts() async throws {
        let h = try await SyncHarness()
        h.remote().put(F.snapshot(F.crKey()))
        h.remote().listError = .offline
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await status(coordinator, F.github).state == .offline)

        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        await coordinator.observeNetwork(stream)
        continuation.yield(false)
        h.remote().listError = nil
        continuation.yield(true)
        let recovered = await eventually { (try? await status(coordinator, F.github).state) == .ok }
        #expect(recovered)
        continuation.finish()
        await coordinator.stop()
    }

    @Test func serverErrorsBackOffAndRecover() async throws {
        let h = try await SyncHarness()
        h.remote().put(F.snapshot(F.crKey()))
        h.remote().listError = .server(status: 502, message: "Bad gateway")
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        var current = try await status(coordinator, F.github)
        #expect(current.state == .error(ProviderError.server(status: 502, message: "Bad gateway").errorDescription ?? ""))
        #expect(current.nextRunAt == F.at(30))
        await h.advance(30)
        current = try await status(coordinator, F.github)
        #expect(current.consecutiveFailures == 2)
        #expect(current.nextRunAt == F.at(90))
        h.remote().listError = nil
        await h.advance(60)
        current = try await status(coordinator, F.github)
        #expect(current.state == .ok)
        #expect(current.consecutiveFailures == 0)
        #expect(current.lastSuccessAt == F.at(90))
        #expect(current.nextRunAt == F.at(120), "fast detail tier (the list itself is due at 90 + 900 s)")
        await coordinator.stop()
    }

    @Test func forbiddenListingIsPermissionDenied() async throws {
        let h = try await SyncHarness()
        h.remote().listError = .forbidden(missingScope: "read_api", message: "")
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await status(coordinator, F.github).state == .permissionDenied("missing scope read_api"))
        await coordinator.stop()
    }

    @Test func missingCredentialIsAuthExpired() async throws {
        let h = try await SyncHarness(accounts: [F.github, F.gitlab])
        try h.credentials.delete(for: F.gitlab)
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator, sleepers: 1)
        #expect(try await status(coordinator, F.gitlab).state == .authExpired)
        #expect(try await status(coordinator, F.github).state == .ok)
        await coordinator.stop()
    }

    @Test func perChangeRequestHydrationFailuresDoNotFailTheAccount() async throws {
        let h = try await SyncHarness()
        let good = F.crKey(number: 1), hidden = F.crKey(number: 2)
        h.remote().put(F.snapshot(good))
        h.remote().put(F.snapshot(hidden))
        h.remote().setHydrateError(.forbidden(missingScope: nil, message: "SAML"), for: hidden)
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await status(coordinator, F.github).state == .ok)
        #expect(try await h.database.snapshot(good) != nil)
        #expect(try await h.database.snapshot(hidden) == nil)
        let failure = try #require(try await status(coordinator, F.github).changeRequestErrors.first)
        #expect(failure.changeRequest == hidden)
        #expect(failure.code == "forbidden")
        #expect(failure.isTerminal)
        #expect(failure.nextRetryAt == nil)
        // Terminal: not retried by detail cycles or unchanged lists…
        h.remote().setHydrateError(nil, for: hidden)
        await h.advance(90)
        await h.advance(900)
        #expect(h.remote().hydrateCalls(hidden) == 1)
        #expect(try await h.database.snapshot(hidden) == nil)
        // …until a manual refresh.
        await coordinator.refresh(account: F.github)
        #expect(try await h.database.snapshot(hidden) != nil)
        #expect(try await status(coordinator, F.github).changeRequestErrors.isEmpty)
        await coordinator.stop()
    }

    @Test func hydrationIsBoundedAndOnlyForChangedChangeRequests() async throws {
        let h = try await SyncHarness()
        let keys = (1...10).map { F.crKey(number: $0) }
        // Quiet for a day: the slow detail tier (30 min).
        for key in keys { h.remote().put(F.snapshot(key, updatedAt: F.at(-86_400))) }
        var configuration = SyncConfiguration.deterministic
        configuration.hydrateConcurrency = 2
        let coordinator = await h.makeCoordinator(configuration: configuration)
        await h.start(coordinator)
        #expect(h.remote().totalHydrateCalls == 10)
        #expect(h.remote().maxInFlightHydrations <= 2)
        #expect(try await h.database.snapshots(account: F.github).count == 10)

        await h.advance(90)
        #expect(h.remote().totalHydrateCalls == 10, "nothing is due before the next list")
        h.remote().update(keys[3]) { $0 = $0.touched(100) }
        await h.advance(900)
        #expect(h.remote().listCalls == 4)
        #expect(h.remote().totalHydrateCalls == 11, "only the CR whose list version changed")
        #expect(h.remote().hydrateCalls(keys[3]) == 2)
        await h.advance(900)
        #expect(h.remote().totalHydrateCalls == 21, "quiet CRs refresh on the slow tier (30 min)")
        #expect(h.remote().maxInFlightHydrations <= 2)
        await coordinator.stop()
    }

    @Test func disabledAccountsArePaused() async throws {
        let h = try await SyncHarness(accounts: [F.github, F.gitlab])
        var configuration = SyncConfiguration.deterministic
        configuration.disabledAccounts = [F.gitlab]
        let coordinator = await h.makeCoordinator(configuration: configuration)
        await h.start(coordinator, sleepers: 1)
        #expect(try await status(coordinator, F.gitlab).state == .paused)
        #expect(h.remote(F.gitlab).listCalls == 0)
        await coordinator.refresh(account: F.gitlab)
        #expect(h.remote(F.gitlab).listCalls == 0)

        await coordinator.setAccountEnabled(F.gitlab, enabled: true)
        await h.clock.waitForSleepers(count: 2)
        #expect(try await status(coordinator, F.gitlab).state == .ok)
        await coordinator.setAccountEnabled(F.gitlab, enabled: false)
        #expect(try await status(coordinator, F.gitlab).state == .paused)
        #expect(await coordinator.configuration.disabledAccounts == [F.gitlab])
        await coordinator.stop()
    }

    @Test func refreshRunsACycleAndWaitsForIt() async throws {
        let h = try await SyncHarness()
        let key = F.crKey()
        h.remote().put(F.snapshot(key))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        let thread = F.threadKey(key)
        h.remote().update(key) { $0 = $0.touched(5); $0.threads = [F.thread(thread, comments: [F.comment("c1", at: 5)])] }
        await coordinator.refresh(account: F.github)
        #expect(h.notifier.delivered.count == 1)
        await coordinator.refreshAll()
        #expect(h.remote().listCalls == 6)
        #expect(h.notifier.delivered.count == 1)
        await coordinator.stop()
    }

    @Test func removedAccountStopsSyncing() async throws {
        let h = try await SyncHarness(accounts: [F.github, F.gitlab])
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(await coordinator.statuses().count == 2)
        try await h.database.deleteAccount(F.gitlab)
        await coordinator.accountsDidChange()
        #expect(await coordinator.statuses().map(\.account) == [F.github])
        let calls = h.remote(F.gitlab).listCalls
        await h.advance(90, sleepers: 1)
        #expect(h.remote(F.gitlab).listCalls == calls)
        await coordinator.stop()
    }
}
