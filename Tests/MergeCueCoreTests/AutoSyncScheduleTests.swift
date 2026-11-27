import Foundation
import MergeCueCore
import Testing

/// Schedule rules that pause automatic sync (weekends, working hours, holidays) and the manual pause.
@Suite("Auto-sync schedule")
struct AutoSyncScheduleTests {
    /// 2026-01-01 is a Thursday; UTC keeps the arithmetic stable on every machine.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 1, day: day, hour: hour, minute: minute)
            .date ?? .distantPast
    }

    let calendar = Self.calendar
    let workdays = AutoSyncSchedule(pauseOnWeekends: true, pauseOutsideWorkingHours: true)

    @Test func noRulesNeverPause() {
        let schedule = AutoSyncSchedule.off
        #expect(!schedule.hasRules)
        #expect(schedule.pauseReason(at: Self.at(day: 3, 12), calendar: calendar, holidays: [:]) == nil)
        #expect(schedule.nextChange(after: Self.at(day: 3, 12), calendar: calendar, holidays: [:]) == nil)
    }

    @Test func weekendsAndWorkingHours() {
        #expect(workdays.pauseReason(at: Self.at(day: 1, 10), calendar: calendar, holidays: [:]) == nil, "Thursday 10:00")
        #expect(workdays.pauseReason(at: Self.at(day: 1, 8, 59), calendar: calendar, holidays: [:]) == .outsideWorkingHours)
        #expect(workdays.pauseReason(at: Self.at(day: 1, 18), calendar: calendar, holidays: [:]) == .outsideWorkingHours, "the end is exclusive")
        #expect(workdays.pauseReason(at: Self.at(day: 3, 12), calendar: calendar, holidays: [:]) == .weekend, "Saturday noon")
        #expect(workdays.pauseReason(at: Self.at(day: 4, 23), calendar: calendar, holidays: [:]) == .weekend, "Sunday night")
    }

    @Test func nextChangeSkipsTheWholeWeekend() {
        // Friday 18:00 → paused until Monday 9:00 (the weekend and the nights in between are one pause).
        let friday = Self.at(day: 2, 18)
        #expect(workdays.nextChange(after: friday, calendar: calendar, holidays: [:]) == Self.at(day: 5, 9), "evening + weekend")
        var weekendOnly = workdays
        weekendOnly.pauseOutsideWorkingHours = false
        #expect(weekendOnly.nextChange(after: Self.at(day: 3, 12), calendar: calendar, holidays: [:]) == Self.at(day: 5, 0))
        let preferences = TrackingPreferences(autoSyncSchedule: workdays)
        let pause = preferences.autoSyncPause(at: Self.at(day: 3, 12), calendar: calendar, holidays: [:])
        #expect(pause?.reason == .weekend)
        #expect(pause?.until == Self.at(day: 5, 9), "resumes Monday at the start of the working day")
        #expect(workdays.nextChange(after: Self.at(day: 5, 9), calendar: calendar, holidays: [:]) == Self.at(day: 5, 18))
        #expect(workdays.nextChange(after: Self.at(day: 1, 10), calendar: calendar, holidays: [:]) == Self.at(day: 1, 18))
    }

    @Test func overnightShiftsAndEmptyWindows() {
        let night = AutoSyncSchedule(pauseOutsideWorkingHours: true, workdayStartMinute: 22 * 60, workdayEndMinute: 6 * 60)
        #expect(night.isWorkingTime(Self.at(day: 1, 23), calendar: calendar))
        #expect(night.isWorkingTime(Self.at(day: 2, 5, 59), calendar: calendar))
        #expect(!night.isWorkingTime(Self.at(day: 2, 12), calendar: calendar))
        let always = AutoSyncSchedule(pauseOutsideWorkingHours: true, workdayStartMinute: 600, workdayEndMinute: 600)
        #expect(always.isWorkingTime(Self.at(day: 1, 3), calendar: calendar), "start == end counts as always working")
    }

    @Test func holidaysPauseTheWholeDay() {
        let schedule = AutoSyncSchedule(pauseOnHolidays: true)
        let holidays = [DayKey.of(Self.at(day: 6, 0), calendar: calendar): "Epiphany"]
        #expect(DayKey.of(Self.at(day: 6, 15), calendar: calendar) == "2026-01-06")
        #expect(schedule.pauseReason(at: Self.at(day: 6, 15), calendar: calendar, holidays: holidays) == .holiday("Epiphany"))
        #expect(schedule.pauseReason(at: Self.at(day: 7, 0), calendar: calendar, holidays: holidays) == nil)
        #expect(schedule.nextChange(after: Self.at(day: 6, 15), calendar: calendar, holidays: holidays) == Self.at(day: 7, 0))
        var withWeekend = schedule
        withWeekend.pauseOnWeekends = true
        let friday = [DayKey.of(Self.at(day: 2, 0), calendar: calendar): "Bridge day"]
        #expect(withWeekend.nextChange(after: Self.at(day: 2, 10), calendar: calendar, holidays: friday) == Self.at(day: 5, 0),
                "a Friday off joins the weekend")
        var off = schedule
        off.pauseOnHolidays = false
        #expect(off.pauseReason(at: Self.at(day: 6, 15), calendar: calendar, holidays: holidays) == nil, "the rule decides, not the data")
    }

    @Test func manualPauseWinsAndSyncAnywayLiftsTheSchedule() {
        let saturday = Self.at(day: 3, 12)
        var preferences = TrackingPreferences(autoSyncSchedule: workdays)
        preferences.autoSyncPausedUntil = .distantFuture
        #expect(preferences.autoSyncPause(at: saturday, calendar: calendar, holidays: [:]) == AutoSyncPause(reason: .manual, until: nil))
        preferences.autoSyncPausedUntil = Self.at(day: 3, 13)
        #expect(preferences.autoSyncPause(at: saturday, calendar: calendar, holidays: [:])?.until == Self.at(day: 3, 13))
        #expect(preferences.nextAutoSyncChange(after: saturday, calendar: calendar, holidays: [:]) == Self.at(day: 3, 13))
        preferences.autoSyncPausedUntil = nil
        preferences.autoSyncScheduleOverrideUntil = Self.at(day: 5, 0)
        #expect(preferences.autoSyncPause(at: saturday, calendar: calendar, holidays: [:]) == nil, "sync anyway")
        #expect(preferences.autoSyncPause(at: Self.at(day: 5, 0), calendar: calendar, holidays: [:])?.reason == .outsideWorkingHours)
    }

    @Test func preferencesDecodeOldPayloadsAndRoundTrip() throws {
        let old = Data(#"{"includeReviewRequests":true,"includeInvolved":false}"#.utf8)
        let decoded = try JSONDecoder().decode(TrackingPreferences.self, from: old)
        #expect(decoded.includeReviewRequests)
        #expect(decoded.autoSyncSchedule == .off)
        #expect(decoded.autoSyncPausedUntil == nil)
        let full = TrackingPreferences(
            autoSyncPausedUntil: Self.at(day: 3, 9),
            autoSyncSchedule: AutoSyncSchedule(pauseOnWeekends: true, pauseOnHolidays: true, holidayCalendarIDs: ["cal-1"]),
            autoSyncScheduleOverrideUntil: Self.at(day: 4, 9)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(TrackingPreferences.self, from: encoder.encode(full)) == full)
        let partial = Data(#"{"pauseOnWeekends":true}"#.utf8)
        #expect(try JSONDecoder().decode(AutoSyncSchedule.self, from: partial) == AutoSyncSchedule(pauseOnWeekends: true))
    }
}
