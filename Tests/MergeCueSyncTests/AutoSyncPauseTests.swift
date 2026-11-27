import Foundation
import MergeCueCore
import MergeCueStore
import Testing
@testable import MergeCueSync

/// Pausing automatic sync (menu bar pause, weekend / working-hours / holiday rules): nothing is requested on its
/// own while paused, Refresh still works, and sync resumes by itself when the pause ends.
@Suite("Auto-sync pause")
struct AutoSyncPauseTests {
    typealias F = SyncFixture
    static let quiet = F.at(-86_400)
    /// F.at(0) = Thursday 2026-01-01 00:00 UTC.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    func status(_ coordinator: SyncCoordinator) async throws -> AccountSyncStatus {
        try #require(await coordinator.statuses().first { $0.account == F.github })
    }

    func preferences(_ change: (inout TrackingPreferences) -> Void) -> TrackingPreferences {
        var preferences = TrackingPreferences.all
        change(&preferences)
        return preferences
    }

    func makeCoordinator(_ h: SyncHarness) async -> SyncCoordinator {
        let coordinator = await h.makeCoordinator()
        await coordinator.setCalendar(Self.utc)
        return coordinator
    }

    @Test func timedPauseStopsEverythingButRefreshAndResumesOnItsOwn() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(F.snapshot(F.crKey(), updatedAt: Self.quiet))
        let coordinator = await makeCoordinator(h)
        await h.start(coordinator)
        #expect(remote.listCalls == 2)

        await coordinator.setTrackingPreferences(preferences { $0.autoSyncPausedUntil = F.at(3_600) })
        await h.clock.waitForSleepers(count: 1)
        var current = try await status(coordinator)
        #expect(current.autoSyncPause == AutoSyncPause(reason: .manual, until: F.at(3_600)))
        #expect(current.nextRunAt == F.at(3_600), "wakes when the pause ends, not at 15 min")

        await h.advance(900)
        await h.advance(900)
        await coordinator.userDidReturn()
        await coordinator.handleSystemWake()
        #expect(remote.listCalls == 2, "nothing automatic while paused")

        await coordinator.refresh(account: F.github)
        #expect(remote.listCalls == 4, "Refresh still checks")

        await h.advance(1_800)
        #expect(remote.listCalls == 6, "the overdue cycle runs as soon as the pause ends")
        current = try await status(coordinator)
        #expect(current.autoSyncPause == nil)
        #expect(current.nextRunAt == F.at(3_600 + 900))
        await coordinator.stop()
    }

    @Test func pauseUntilResumedStopsTheLoopUntilTheUserResumes() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(F.snapshot(F.crKey(), updatedAt: Self.quiet))
        let coordinator = await makeCoordinator(h)
        await h.start(coordinator)
        await coordinator.setTrackingPreferences(preferences { $0.autoSyncPausedUntil = .distantFuture })
        for _ in 0..<2_000 { await Task.yield() }
        let current = try await status(coordinator)
        #expect(current.autoSyncPause == AutoSyncPause(reason: .manual, until: nil))
        #expect(current.nextRunAt == nil, "no timer at all")
        h.clock.advance(by: 86_400)
        for _ in 0..<2_000 { await Task.yield() }
        #expect(remote.listCalls == 2)

        await coordinator.setTrackingPreferences(.all)
        await h.clock.waitForSleepers(count: 1)
        #expect(remote.listCalls == 4, "resuming runs the overdue cycle right away")
        #expect(try await status(coordinator).nextRunAt == h.clock.now.addingTimeInterval(900))
        await coordinator.stop()
    }

    @Test func weekendRuleSkipsTheLaunchListAndResumesOnMonday() async throws {
        let h = try await SyncHarness(clock: TestClock(now: F.at(2 * 86_400 + 12 * 3_600))) // Saturday noon
        let remote = h.remote()
        remote.put(F.snapshot(F.crKey(), updatedAt: Self.quiet))
        let coordinator = await makeCoordinator(h)
        await coordinator.setTrackingPreferences(preferences {
            $0.autoSyncSchedule = AutoSyncSchedule(pauseOnWeekends: true, pauseOutsideWorkingHours: true)
        })
        await h.start(coordinator)
        #expect(remote.listCalls == 0, "launching on a paused weekend requests nothing")
        let monday9 = F.at(4 * 86_400 + 9 * 3_600)
        var current = try await status(coordinator)
        #expect(current.autoSyncPause == AutoSyncPause(reason: .weekend, until: monday9))
        #expect(current.nextRunAt == monday9)

        await h.advance(monday9.timeIntervalSince(h.clock.now))
        #expect(remote.listCalls == 2, "Monday 9:00: the first cycle")
        current = try await status(coordinator)
        #expect(current.autoSyncPause == nil)
        #expect(current.nextRunAt == monday9.addingTimeInterval(900))

        // 18:00: paused again until Tuesday 9:00 (the last cycle runs at 17:45).
        while h.clock.now < monday9.addingTimeInterval(9 * 3_600) {
            try await advanceToNextRun(h, coordinator)
        }
        current = try await status(coordinator)
        #expect(current.autoSyncPause?.reason == .outsideWorkingHours)
        #expect(current.nextRunAt == monday9.addingTimeInterval(86_400))
        #expect(remote.listCalls == 2 * 36, "36 cycles between 9:00 and 17:45")
        await coordinator.stop()
    }

    @Test func holidaysAndSyncAnyway() async throws {
        let h = try await SyncHarness(clock: TestClock(now: F.at(5 * 86_400 + 10 * 3_600))) // Tuesday 6 Jan, 10:00
        let remote = h.remote()
        remote.put(F.snapshot(F.crKey(), updatedAt: Self.quiet))
        let coordinator = await makeCoordinator(h)
        await coordinator.setHolidays(["2026-01-06": "Epiphany"])
        await coordinator.setTrackingPreferences(preferences { $0.autoSyncSchedule = AutoSyncSchedule(pauseOnHolidays: true) })
        await h.start(coordinator)
        #expect(remote.listCalls == 0)
        #expect(try await status(coordinator).autoSyncPause == AutoSyncPause(reason: .holiday("Epiphany"), until: F.at(6 * 86_400)))

        // "Sync anyway" until the pause would have ended.
        await coordinator.setTrackingPreferences(preferences {
            $0.autoSyncSchedule = AutoSyncSchedule(pauseOnHolidays: true)
            $0.autoSyncScheduleOverrideUntil = F.at(6 * 86_400)
        })
        await h.clock.waitForSleepers(count: 1)
        #expect(remote.listCalls == 2)
        #expect(try await status(coordinator).autoSyncPause == nil)
        await h.advance(900)
        #expect(remote.listCalls == 4)

        // The holiday is removed from the calendar: nothing changes for a running sync.
        await coordinator.setHolidays([:])
        await h.clock.waitForSleepers(count: 1)
        #expect(try await status(coordinator).nextRunAt == h.clock.now.addingTimeInterval(900))
        await coordinator.stop()
    }

    @Test func accountsConnectedWhilePausedListOnce() async throws {
        let h = try await SyncHarness()
        h.remote(F.github).put(F.snapshot(F.crKey(), updatedAt: Self.quiet))
        let coordinator = await makeCoordinator(h)
        await coordinator.setTrackingPreferences(preferences { $0.autoSyncPausedUntil = .distantFuture })
        await coordinator.start()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(h.remote(F.github).listCalls == 0)

        try await h.database.upsertAccount(F.account(F.gitlab))
        try h.credentials.save(.bearer("test-token-gitlab"), for: F.gitlab)
        await coordinator.accountsDidChange()
        for _ in 0..<20_000 where h.remote(F.gitlab).listCalls < 2 { await Task.yield() }
        #expect(h.remote(F.gitlab).listCalls == 2, "a newly connected account loads its pull requests once")
        #expect(h.remote(F.github).listCalls == 0)
        await coordinator.stop()
    }

    /// Advances to the account's next wake-up.
    func advanceToNextRun(_ h: SyncHarness, _ coordinator: SyncCoordinator) async throws {
        let next = try #require(try await status(coordinator).nextRunAt)
        await h.advance(max(0, next.timeIntervalSince(h.clock.now)))
    }
}
