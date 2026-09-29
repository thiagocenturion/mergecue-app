import Foundation
import MergeCueCore
import MergeCueStore
import Testing
@testable import MergeCueSync

/// The GitButler-style polling model (DECISIONS D35) end to end: list cadence and events, progressive detail tiers,
/// hot change requests, per-CR backoff, rate limits, request accounting. `TestClock` only — nothing really sleeps.
@Suite("Sync polling model")
struct SyncPollingModelTests {
    typealias F = SyncFixture
    static let quiet = F.at(-86_400)

    func status(_ coordinator: SyncCoordinator, _ account: AccountKey = F.github) async throws -> AccountSyncStatus {
        try #require(await coordinator.statuses().first { $0.account == account })
    }

    /// Advances to the account's next wake-up.
    func advanceToNextRun(_ h: SyncHarness, _ coordinator: SyncCoordinator, sleepers: Int? = nil) async throws {
        let next = try #require(try await status(coordinator).nextRunAt)
        await h.advance(max(0, next.timeIntervalSince(h.clock.now)), sleepers: sleepers)
    }

    // MARK: List cadence and events

    @Test func listsEveryFifteenMinutesAndNothingInBetweenForQuietChangeRequests() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(F.snapshot(F.crKey(), updatedAt: Self.quiet))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(remote.listCalls == 2, "authored + review requested, immediately at launch")
        #expect(try await status(coordinator).nextRunAt == F.at(900))
        for step in 1...3 {
            await h.advance(300)
            #expect(remote.listCalls == 2 * (1 + step / 3))
        }
        #expect(remote.listCalls == 4)
        #expect(remote.totalHydrateCalls == 1, "a quiet CR is not re-hydrated before its 30-minute slot")
        await h.advance(900)
        #expect(remote.listCalls == 6)
        #expect(remote.totalHydrateCalls == 2)
        await coordinator.stop()
    }

    @Test func returnWakeAndNetworkRecoveryTriggerDebouncedLists() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(F.snapshot(F.crKey(), updatedAt: Self.quiet))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(remote.listCalls == 2)

        await coordinator.userDidReturn()
        #expect(remote.listCalls == 2, "within 60 s of the launch list")
        await h.advance(61)
        await coordinator.userDidReturn()
        #expect(remote.listCalls == 4, "popover open / window focus lists again")
        #expect(try await status(coordinator).nextRunAt == F.at(61 + 900), "the list timer restarts")
        await coordinator.handleSystemWake()
        #expect(remote.listCalls == 4, "debounced: another event within 60 s")
        await coordinator.refresh(account: F.github)
        #expect(remote.listCalls == 6, "manual refresh is never debounced")
        await h.advance(30)
        await coordinator.handleSystemWake()
        #expect(remote.listCalls == 6, "a manual list 30 s ago also debounces events")
        await h.advance(40)
        await coordinator.handleSystemWake()
        #expect(remote.listCalls == 8, "wake lists again after the debounce")

        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        await coordinator.observeNetwork(stream)
        await h.advance(61)
        continuation.yield(false)
        continuation.yield(true)
        var recovered = false
        for _ in 0..<20_000 where !recovered {
            recovered = remote.listCalls == 10
            await Task.yield()
        }
        #expect(recovered, "network recovery lists again")
        continuation.finish()
        await coordinator.stop()
    }

    // MARK: Progressive detail tiers

    @Test func detailRefreshSlowsDownAsTheChangeRequestStaysQuiet() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        let key = F.crKey()
        remote.put(F.snapshot(key)) // changed "now"
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)

        var gaps: [TimeInterval] = []
        var lastHydrate = h.clock.now
        var calls = remote.hydrateCalls(key)
        while h.clock.now < F.at(2 * 3600) {
            try await advanceToNextRun(h, coordinator)
            if remote.hydrateCalls(key) > calls {
                calls = remote.hydrateCalls(key)
                gaps.append(h.clock.now.timeIntervalSince(lastHydrate))
                lastHydrate = h.clock.now
            }
        }
        await coordinator.stop()
        #expect(gaps.prefix(20).allSatisfy { $0 == 30 }, "fast tier for the first 10 minutes: \(gaps.prefix(21))")
        #expect(gaps.contains(300), "medium tier up to an hour")
        #expect(gaps.last == 1_800, "slow tier after an hour")
        #expect(calls < 45, "about 20 + 10 + 2 detail refreshes in 2 h instead of 80 polls at 90 s (\(calls))")
    }

    @Test func newActivityReturnsTheChangeRequestToTheFastTier() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        let key = F.crKey()
        remote.put(F.snapshot(key, updatedAt: Self.quiet))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await status(coordinator).nextRunAt == F.at(900), "quiet: next is the list")

        // A new comment bumps the listing: the list cycle hydrates it at once, then the CR is fast again.
        let thread = F.threadKey(key)
        remote.update(key) { $0 = $0.touched(500); $0.threads = [F.thread(thread, comments: [F.comment("c1", at: 500)])] }
        await h.advance(900)
        #expect(remote.hydrateCalls(key) == 2)
        #expect(h.notifier.delivered.count == 1)
        #expect(try await status(coordinator).nextRunAt == F.at(930))

        // CI starts (no listing change): pending checks keep the fast tier.
        remote.update(key) { [key] in
            $0.checks = [F.check(key, id: "1", status: .inProgress, at: 920)]
            $0.aggregateCheckState = .pending
        }
        await h.advance(30)
        #expect(remote.hydrateCalls(key) == 3)
        await h.advance(3_600)
        #expect(try await status(coordinator).nextRunAt == h.clock.now.addingTimeInterval(30), "pending checks stay fast")
        await coordinator.stop()
    }

    @Test func activeTasksAndSetHotUseTheFastTier() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        let key = F.crKey()
        remote.put(F.snapshot(key, updatedAt: Self.quiet))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await status(coordinator).nextRunAt == F.at(900))

        await coordinator.setActiveChangeRequests([key])
        await h.clock.waitForSleepers(count: 1)
        #expect(await coordinator.activeChangeRequests() == [key])
        #expect(try await status(coordinator).nextRunAt == F.at(30), "an agent task makes its CR hot at once")
        await h.advance(30)
        #expect(remote.hydrateCalls(key) == 2)

        await coordinator.setActiveChangeRequests([])
        await h.clock.waitForSleepers(count: 1)
        #expect(try await status(coordinator).nextRunAt == F.at(900))

        await coordinator.setHot(until: F.at(10_000))
        await h.clock.waitForSleepers(count: 1)
        #expect(try await status(coordinator).nextRunAt == F.at(60))
        await coordinator.stop()
        #expect(try await status(coordinator).nextRunAt == nil)
    }

    // MARK: Per-CR errors

    @Test func failingChangeRequestBacksOffWithoutFailingTheAccount() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        let broken = F.crKey(number: 1)
        remote.put(F.snapshot(broken, updatedAt: Self.quiet))
        remote.setHydrateError(.server(status: 502, message: "Bad gateway"), for: broken)
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        var current = try await status(coordinator)
        #expect(current.state == .ok)
        #expect(current.changeRequestErrors.map(\.code) == ["server_error"])
        #expect(current.changeRequestErrors.first?.nextRetryAt == F.at(30))
        #expect(current.nextRunAt == F.at(30))

        await h.advance(30)
        #expect(remote.hydrateCalls(broken) == 2)
        current = try await status(coordinator)
        #expect(current.changeRequestErrors.first?.nextRetryAt == F.at(330), "30 s → 5 min")
        await h.advance(300)
        #expect(remote.hydrateCalls(broken) == 3)
        #expect(try await status(coordinator).changeRequestErrors.first?.nextRetryAt == F.at(330 + 1_800), "→ 30 min cap")

        remote.setHydrateError(nil, for: broken)
        await h.advance(900) // list at 900: not due yet (backoff until 2130)
        #expect(remote.hydrateCalls(broken) == 3)
        await h.advance(1_800)
        #expect(remote.hydrateCalls(broken) == 4)
        current = try await status(coordinator)
        #expect(current.changeRequestErrors.isEmpty)
        #expect(try await h.database.snapshot(broken) != nil)
        await coordinator.stop()
    }

    @Test func terminalFailureStopsUntilListChangeManualRefreshOrReturn() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        let gone = F.crKey(number: 9)
        remote.put(F.snapshot(gone))
        remote.setHydrateError(.notFound("Pull request not found"), for: gone)
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        let failure = try #require(try await status(coordinator).changeRequestErrors.first)
        #expect(failure.isTerminal)
        #expect(failure.reasonText == "not found")
        #expect(try await status(coordinator).state == .ok)

        for _ in 0..<4 { await h.advance(900) }
        #expect(remote.hydrateCalls(gone) == 1, "not retried on unchanged lists")

        // The listing changes → retried once.
        remote.update(gone) { $0 = $0.touched(4_000) }
        await h.advance(900)
        #expect(remote.hydrateCalls(gone) == 2)

        // Manual refresh → retried.
        await coordinator.refresh(account: F.github)
        #expect(remote.hydrateCalls(gone) == 3)

        // Return/focus → retried only once the failure is 15 min old.
        await h.advance(120)
        await coordinator.userDidReturn()
        #expect(remote.hydrateCalls(gone) == 3)
        await h.advance(840)
        await coordinator.userDidReturn()
        #expect(remote.hydrateCalls(gone) == 4)

        remote.setHydrateError(nil, for: gone)
        await coordinator.refresh(account: F.github)
        #expect(try await status(coordinator).changeRequestErrors.isEmpty)
        #expect(try await h.database.snapshot(gone) != nil)
        await coordinator.stop()
    }

    // MARK: Rate limits

    @Test func rateLimitWithoutResetBacksOffFiveFifteenSixtyMinutes() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.listError = .rateLimited(resetAt: nil, retryAfter: nil)
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        var current = try await status(coordinator)
        #expect(current.state == .rateLimited(until: F.at(300)))
        #expect(current.nextRunAt == F.at(300))
        #expect(current.message?.contains("GitHub rate limit reached for @mona-dev") == true)
        #expect(current.message?.contains("no reset time") == true)
        #expect(current.state.displayText.hasPrefix("Rate limited — retrying at "))
        #expect(!(current.message ?? "").contains("hour"))

        await coordinator.refresh(account: F.github)
        await coordinator.userDidReturn()
        #expect(remote.listCalls == 2, "no manual or event refresh before the retry time")

        await h.advance(300)
        #expect(try await status(coordinator).state == .rateLimited(until: F.at(300 + 900)))
        await h.advance(900)
        #expect(try await status(coordinator).state == .rateLimited(until: F.at(1_200 + 3_600)))
        await h.advance(3_600)
        #expect(try await status(coordinator).state == .rateLimited(until: F.at(4_800 + 3_600)), "capped at 1 h")

        remote.listError = nil
        await h.advance(3_600)
        current = try await status(coordinator)
        #expect(current.state == .ok)
        #expect(current.message == nil)
        await coordinator.stop()
    }

    @Test func providerResetTimeIsHonouredAndOtherAccountsKeepSyncing() async throws {
        let h = try await SyncHarness(accounts: [F.github, F.gitlab])
        let limited = h.remote(F.github)
        limited.put(F.snapshot(F.crKey(F.github)))
        limited.listError = .rateLimited(resetAt: F.at(2_345), retryAfter: nil)
        let healthy = h.remote(F.gitlab)
        let key = F.crKey(F.gitlab)
        healthy.put(F.snapshot(key))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)

        let github = try await status(coordinator, F.github)
        #expect(github.state == .rateLimited(until: F.at(2_345)))
        #expect(github.nextRunAt == F.at(2_345))
        #expect(github.message?.contains("waits for the reset time GitHub sent") == true)

        for _ in 0..<10 { await h.advance(30) }
        #expect(limited.listCalls == 2, "one attempt (two listings), then it waits")
        #expect(healthy.hydrateCalls(key) == 11, "GitLab keeps refreshing its fresh CR every 30 s")
        #expect(try await status(coordinator, F.gitlab).state == .ok)

        limited.listError = nil
        await h.advance(2_345 - 300)
        #expect(try await status(coordinator, F.github).state == .ok)
        await coordinator.stop()
    }

    // MARK: Request accounting

    @Test func requestsAreCountedPerAccountAndTheBudgetSlowsDetails() async throws {
        let h = try await SyncHarness(accounts: [F.github, F.gitlab])
        h.remote(F.github).put(F.snapshot(F.crKey(F.github)))
        h.remote(F.gitlab).put(F.snapshot(F.crKey(F.gitlab), updatedAt: Self.quiet))
        var configuration = SyncConfiguration.deterministic
        configuration.requestBudgets[.github] = 10
        let coordinator = await h.makeCoordinator(configuration: configuration)
        await h.start(coordinator)
        var github = try await status(coordinator, F.github)
        #expect(github.requestsLastHour == 3, "two lists + one hydration")
        #expect(github.requestBudget == 10)
        #expect(try await status(coordinator, F.gitlab).requestBudget == 1_000)

        var gaps: [TimeInterval] = []
        while (try await status(coordinator, F.github).requestsLastHour ?? 0) < 10 {
            let before = h.clock.now
            let next = try #require(try await status(coordinator, F.github).nextRunAt)
            await h.advance(next.timeIntervalSince(before), sleepers: 2)
            gaps.append(h.clock.now.timeIntervalSince(before))
        }
        github = try await status(coordinator, F.github)
        #expect(github.isOverRequestBudget)
        #expect(gaps.contains(30) && gaps.contains(60), "full speed, then ×2 above 75 % of the budget: \(gaps)")
        #expect(github.nextRunAt == h.clock.now.addingTimeInterval(120), "×4 at the budget")
        #expect(try await status(coordinator, F.gitlab).requestsLastHour == 3, "counted per account")
        await coordinator.stop()
    }

    @Test func injectedLedgerIsReadNotWritten() async throws {
        let h = try await SyncHarness()
        h.remote().put(F.snapshot(F.crKey()))
        let ledger = ProviderRequestLedger()
        let coordinator = SyncCoordinator(
            database: h.database, credentials: h.credentials, providers: h.factory, notifier: h.notifier, clock: h.clock,
            configuration: .deterministic, requestLedger: ledger
        )
        await h.start(coordinator)
        #expect(try await status(coordinator).requestsLastHour == 0, "the transport, not Sync, records HTTP requests")
        for _ in 0..<7 { ledger.record(F.github, at: h.clock.now) }
        #expect(try await status(coordinator).requestsLastHour == 7)
        #expect(coordinator.requestLedger === ledger)
        await coordinator.stop()
    }

    // MARK: Regression

    /// Owner report: four Bitbucket PRs answering 404 were re-hydrated on every 90-second cycle, forever, until the
    /// account hit its rate limit. Old model over one hour: 40 cycles × (2 lists + 4 hydrations) = 240 provider calls.
    @Test func fourChangeRequestsFailing404NoLongerHammerTheProvider() async throws {
        let h = try await SyncHarness(accounts: [F.bitbucket])
        let remote = h.remote(F.bitbucket)
        let broken = (1...4).map { F.crKey(F.bitbucket, number: $0) }
        for key in broken {
            remote.put(F.snapshot(key))
            remote.setHydrateError(.notFound("Pull request not found"), for: key)
        }
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        var current = try await status(coordinator, F.bitbucket)
        #expect(current.state == .ok)
        #expect(current.changeRequestErrors.count == 4, "surfaced per CR, never a silent healthy-empty account")
        #expect(current.changeRequestErrors.allSatisfy { $0.isTerminal && $0.code == "not_found" })

        // One hour, checked every minute.
        for _ in 0..<60 { await h.advance(60) }
        let idleCalls = remote.listCalls + remote.totalHydrateCalls
        #expect(remote.totalHydrateCalls == 4, "each broken PR is tried once, not every cycle")
        #expect(remote.listCalls == 10, "lists at 0, 15, 30, 45 and 60 min")
        #expect(idleCalls == 14, "was 240 per hour with the 90 s model")

        // Same hour again, with the user opening the popover every two minutes.
        let before = idleCalls
        for _ in 0..<30 {
            await h.advance(120)
            await coordinator.userDidReturn()
        }
        let activeCalls = remote.listCalls + remote.totalHydrateCalls - before
        #expect(remote.totalHydrateCalls - 4 <= 16, "terminal CRs retried on return at most every 15 min")
        #expect(activeCalls < 100, "\(activeCalls) calls with a return every 2 min")
        current = try await status(coordinator, F.bitbucket)
        #expect(current.changeRequestErrors.count == 4)
        print("[regression] 4×404 over 1 h: \(idleCalls) provider calls idle, \(activeCalls) with a return every 2 min (old model: 240)")
        await coordinator.stop()
    }
}
