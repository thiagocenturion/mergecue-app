import Foundation
import MergeCueCore
import MergeCueRuntime
import Testing
@testable import MergeCueUI

/// Wording and dates of the automatic-sync pause (menu bar menu, Settings), and holiday calendar detection.
@Suite("Auto-sync text")
@MainActor
struct AutoSyncTextTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// Thursday 2026-01-01 10:00 UTC.
    let thursday = Date(timeIntervalSince1970: 1_767_225_600 + 10 * 3_600)

    @Test func pauseOptionsLandOnNineInTheMorning() {
        let monday = AutoSyncText.nextMondayMorning(after: thursday, calendar: Self.calendar)
        #expect(monday == Date(timeIntervalSince1970: 1_767_225_600 + 4 * 86_400 + 9 * 3_600))
        let tomorrow = AutoSyncText.tomorrowMorning(after: thursday, calendar: Self.calendar)
        #expect(tomorrow == Date(timeIntervalSince1970: 1_767_225_600 + 86_400 + 9 * 3_600))
        #expect(AutoSyncText.minute(of: AutoSyncText.date(minute: 18 * 60 + 30, calendar: Self.calendar), calendar: Self.calendar) == 18 * 60 + 30)
    }

    @Test func statusTextHasNoEmDashAndNamesTheReason() {
        let until = thursday.addingTimeInterval(86_400)
        let texts = [
            AutoSyncText.status(AutoSyncPause(reason: .weekend, until: until), now: thursday, calendar: Self.calendar),
            AutoSyncText.status(AutoSyncPause(reason: .manual, until: nil), now: thursday, calendar: Self.calendar),
            AutoSyncText.status(AutoSyncPause(reason: .holiday("Epiphany"), until: until), now: thursday, calendar: Self.calendar),
        ]
        #expect(texts[0].hasPrefix("Auto-sync paused until tomorrow "))
        #expect(texts[0].hasSuffix("(Weekend)."))
        #expect(texts[1] == "Auto-sync paused until you resume it.")
        #expect(texts[2].contains("(Epiphany)"))
        #expect(texts.allSatisfy { !$0.contains("—") })
    }

    @Test func holidayCalendarsAreDetectedInSeveralLanguages() {
        for title in ["Holidays in United Kingdom", "Feriados no Brasil", "Jours fériés en France", "Feiertage in Deutschland", "日本の祝日"] {
            #expect(EventKitHolidaySource.looksLikeHolidayCalendar(title: title), "\(title)")
        }
        for title in ["Work", "Family", "Birthdays"] {
            #expect(!EventKitHolidaySource.looksLikeHolidayCalendar(title: title), "\(title)")
        }
    }
}
