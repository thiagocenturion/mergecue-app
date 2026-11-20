import Foundation
import MergeCueCore
import Testing
@testable import MergeCueSync

/// Pure scheduling arithmetic (DECISIONS D35) and the per-change-request schedule.
@Suite("Sync schedule")
struct SyncScheduleTests {
    typealias F = SyncFixture
    let now = F.at(100)
    let config = SyncConfiguration.deterministic

    // MARK: Defaults

    @Test func defaultsFollowTheGitButlerStyleModel() {
        let d = SyncConfiguration.default
        #expect(d.listInterval == 900)
        #expect(d.eventRefreshDebounce == 60)
        #expect(d.terminalRetryOnReturnAfter == 900)
        #expect([d.fastDetailInterval, d.mediumDetailInterval, d.slowDetailInterval] == [30, 300, 1800])
        #expect([d.fastDetailWindow, d.mediumDetailWindow] == [600, 3600])
        #expect(d.changeRequestBackoff == [30, 300, 1800])
        #expect(d.rateLimitFallback == [300, 900, 3600])
        #expect(d.requestBudget(for: .github) == 1500)
        #expect(d.requestBudget(for: .gitlab) == 1000)
        #expect(d.requestBudget(for: .bitbucketCloud) == 500)
        #expect(d.backoffCap == 900)
        #expect(d.hydrateConcurrency == 3)
    }

    // MARK: Detail tiers

    @Test func detailTiersByTimeSinceLastChange() {
        func interval(_ age: TimeInterval, hot: Bool = false, pending: Bool = false, slowdown: Double = 1) -> TimeInterval {
            SyncSchedule.detailInterval(sinceChange: age, isHot: hot, checksPending: pending, slowdown: slowdown, configuration: config)
        }
        #expect(interval(0) == 300, "recent: 5 min at the default 15-minute interval (D36)")
        #expect(interval(599) == 300)
        #expect(interval(600) == 900, "quiet: never faster than the list interval")
        #expect(interval(3_599) == 900)
        #expect(interval(3_600) == 1_800)
        #expect(interval(86_400) == 1_800)
        #expect(interval(86_400, hot: true) == 30, "an active task keeps its CR at the fast tier")
        #expect(interval(86_400, pending: true) == 30, "pending checks keep the CR at the fast tier")
        #expect(interval(0, hot: true) == 30)
        #expect(interval(86_400, slowdown: 4) == 7_200, "budget pressure slows every tier")
        #expect(interval(0, slowdown: 0.5) == 300, "slowdown never speeds up")
    }

    @Test func detailTiersScaleWithTheAccountsRefreshInterval() {
        func interval(_ age: TimeInterval, every list: TimeInterval, pending: Bool = false) -> TimeInterval {
            SyncSchedule.detailInterval(sinceChange: age, isHot: false, checksPending: pending, listInterval: list, configuration: config)
        }
        // Every 5 min: recent 100 s, quiet 5 min, idle 10 min.
        #expect([interval(0, every: 300), interval(900, every: 300), interval(7_200, every: 300)] == [100, 300, 600])
        // Every hour: recent 20 min, quiet 1 h, idle 2 h; pending checks still 30 s.
        #expect([interval(0, every: 3_600), interval(900, every: 3_600), interval(7_200, every: 3_600)] == [1_200, 3_600, 7_200])
        #expect(interval(7_200, every: 3_600, pending: true) == 30)
        let manual = Account(
            id: F.github, instance: .githubCom, username: "me", authMethod: .personalAccessToken,
            connectedAt: F.at(0), refreshInterval: .manual
        )
        #expect(SyncSchedule.listInterval(for: manual, configuration: config) == nil)
        var hourly = manual
        hourly.refreshInterval = .oneHour
        #expect(SyncSchedule.listInterval(for: hourly, configuration: config) == 3_600)
        hourly.refreshInterval = nil
        #expect(SyncSchedule.listInterval(for: hourly, configuration: config) == config.listInterval)
    }

    @Test func changeRequestBackoffLadder() {
        let delays = (1...5).map { SyncSchedule.changeRequestBackoff(failures: $0, configuration: config) }
        #expect(delays == [30, 300, 1_800, 1_800, 1_800])
    }

    @Test func budgetSlowdown() {
        #expect(SyncSchedule.budgetSlowdown(used: 0, budget: 500, configuration: config) == 1)
        #expect(SyncSchedule.budgetSlowdown(used: 374, budget: 500, configuration: config) == 1)
        #expect(SyncSchedule.budgetSlowdown(used: 375, budget: 500, configuration: config) == 2)
        #expect(SyncSchedule.budgetSlowdown(used: 500, budget: 500, configuration: config) == 4)
        #expect(SyncSchedule.budgetSlowdown(used: 10_000, budget: nil, configuration: config) == 1)
    }

    // MARK: Account failures

    @Test func backoffIsExponentialAndCapped() {
        let delays = (1...8).map {
            SyncSchedule.failureDelay(state: .offline, consecutiveFailures: $0, now: now, configuration: config)
        }
        #expect(delays == [30, 60, 120, 240, 480, 900, 900, 900])
        #expect(SyncSchedule.failureDelay(state: .error("x"), consecutiveFailures: 100, now: now, configuration: config) == 900)
        #expect(SyncSchedule.failureDelay(state: .permissionDenied("x"), consecutiveFailures: 1, now: now, configuration: config) == 30)
        #expect(SyncSchedule.failureDelay(state: .ok, consecutiveFailures: 0, now: now, configuration: config) == nil)
    }

    @Test func rateLimitHonoursResetElseFallbackLadder() {
        #expect(SyncSchedule.failureDelay(state: .rateLimited(until: F.at(1300)), consecutiveFailures: 1, now: now, configuration: config) == 1200)
        #expect(SyncSchedule.failureDelay(state: .rateLimited(until: F.at(0)), consecutiveFailures: 1, now: now, configuration: config) == 1)
        let fallback = (1...4).map {
            SyncSchedule.failureDelay(state: .rateLimited(until: nil), consecutiveFailures: $0, now: now, configuration: config)
        }
        #expect(fallback == [300, 900, 3_600, 3_600])
        #expect(SyncSchedule.failureDelay(state: .authExpired, consecutiveFailures: 1, now: now, configuration: config) == nil)
        #expect(SyncSchedule.failureDelay(state: .paused, consecutiveFailures: 0, now: now, configuration: config) == nil)
    }

    @Test func jitterStaysInBounds() {
        var config = config
        config.jitterFraction = 0.1
        #expect(SyncSchedule.listDelay(configuration: config, jitterSample: 0) == 810)
        let high = SyncSchedule.listDelay(configuration: config, jitterSample: 0.999)
        #expect(high < 990 && high > 989.8)
        // Rate limits are never retried early.
        let limited = SyncSchedule.failureDelay(state: .rateLimited(until: F.at(700)), consecutiveFailures: 1, now: now, configuration: config, jitterSample: 0)
        #expect(limited == 600)
    }

    // MARK: ChangeRequestSchedule

    @Test func newSnapshotsAreSeededFromTheirOwnActivity() {
        var schedule = ChangeRequestSchedule()
        let old = F.snapshot(F.crKey(number: 1), updatedAt: F.at(-86_400), fetchedAt: F.at(-60))
        let fresh = F.snapshot(F.crKey(number: 2), updatedAt: F.at(-120), fetchedAt: F.at(-60))
        schedule.seed(from: [old, fresh])
        let hints = ScheduleHints(now: now)
        #expect(schedule.dueDate(schedule.tracker(old.key)!, hints: hints, configuration: config) == F.at(-60 + 1_800))
        #expect(schedule.dueDate(schedule.tracker(fresh.key)!, hints: hints, configuration: config) == F.at(-60 + 300))
        #expect(schedule.dueKeys(hints: hints, configuration: config).isEmpty, "recent: due 5 min after its last fetch")
        var hot = hints
        hot.hotKeys = [old.key, fresh.key]
        #expect(Set(schedule.dueKeys(hints: hot, configuration: config)) == [old.key, fresh.key])
    }

    @Test func changesMoveTheLastChangeAndFailuresBackOff() {
        var schedule = ChangeRequestSchedule()
        let key = F.crKey()
        let first = F.snapshot(key, updatedAt: F.at(-86_400))
        schedule.recordSuccess(first, previous: nil, now: now)
        #expect(schedule.tracker(key)?.lastChangedAt == F.at(-86_400), "first sight: its own activity time")
        schedule.recordSuccess(first, previous: first, now: F.at(200))
        #expect(schedule.tracker(key)?.lastChangedAt == F.at(-86_400), "unchanged")
        let thread = F.threadKey(key)
        let commented = { var s = first; s.threads = [F.thread(thread, comments: [F.comment("c1", at: 250)])]; return s }()
        schedule.recordSuccess(commented, previous: first, now: F.at(300))
        #expect(schedule.tracker(key)?.lastChangedAt == F.at(300), "new activity")

        schedule.recordFailure(first.summary, error: .server(status: 502, message: ""), listVersion: "v1", now: F.at(400))
        let hints = ScheduleHints(now: F.at(400))
        #expect(schedule.dueDate(schedule.tracker(key)!, hints: hints, configuration: config) == F.at(430))
        schedule.recordFailure(first.summary, error: .server(status: 502, message: ""), listVersion: "v1", now: F.at(430))
        #expect(schedule.dueDate(schedule.tracker(key)!, hints: hints, configuration: config) == F.at(730))
        #expect(schedule.errors(configuration: config).first?.nextRetryAt == F.at(730))
        #expect(schedule.errors(configuration: config).first?.isTerminal == false)
    }

    @Test func terminalFailuresStopUntilTheListVersionChangesOrAReset() {
        var schedule = ChangeRequestSchedule()
        let summary = F.summary(F.crKey())
        let hints = ScheduleHints(now: now)
        let hydrate1 = schedule.shouldHydrate(listed: summary, listVersion: "v1", storedListVersion: nil, hasSnapshot: false, hints: hints, configuration: config)
        #expect(hydrate1)
        schedule.recordFailure(summary, error: .notFound("gone"), listVersion: "v1", now: now)
        let later = ScheduleHints(now: F.at(100_000))
        let hydrate2 = schedule.shouldHydrate(listed: summary, listVersion: "v1", storedListVersion: nil, hasSnapshot: false, hints: later, configuration: config)
        #expect(!hydrate2)
        #expect(schedule.earliestDue(hints: later, configuration: config) == nil)
        #expect(schedule.errors(configuration: config).map(\.code) == ["not_found"])
        #expect(schedule.errors(configuration: config).first?.isTerminal == true)
        let hydrate3 = schedule.shouldHydrate(listed: summary, listVersion: "v2", storedListVersion: nil, hasSnapshot: false, hints: later, configuration: config)
        #expect(hydrate3)

        schedule.recordFailure(summary, error: .forbidden(missingScope: nil, message: "SAML"), listVersion: "v2", now: F.at(100_000))
        // Return/focus only resets terminal failures older than a threshold (here 5 min).
        schedule.resetFailures(now: F.at(100_100), terminalOlderThan: 300)
        #expect(schedule.tracker(summary.key)?.isTerminal == true)
        schedule.resetFailures(now: F.at(100_400), terminalOlderThan: 300)
        #expect(schedule.tracker(summary.key)?.isTerminal == false)
        let hydrate4 = schedule.shouldHydrate(listed: summary, listVersion: "v2", storedListVersion: nil, hasSnapshot: false, hints: later, configuration: config)
        #expect(hydrate4)
        #expect(schedule.errors(configuration: config).isEmpty)
    }

    @Test func requestLedgerIsARollingHour() {
        let ledger = ProviderRequestLedger()
        let a = F.github, b = F.gitlab
        for second in 0..<100 { ledger.record(a, at: F.at(TimeInterval(second))) }
        ledger.record(b, at: F.at(0))
        #expect(ledger.count(a, now: F.at(100)) == 100)
        #expect(ledger.count(b, now: F.at(100)) == 1)
        #expect(ledger.count(a, now: F.at(3_650)) == 49)
        #expect(ledger.count(a, now: F.at(3_700)) == 0)
        ledger.reset(b)
        #expect(ledger.count(b, now: F.at(100)) == 0)
    }
}
