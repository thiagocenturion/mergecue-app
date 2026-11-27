import EventKit
import Foundation
import MergeCueCore

/// Days off from the user's macOS calendars (EventKit, read-only) for the "Pause on holidays" rule.
///
/// Reads nothing until asked, and nothing without full calendar access (the user grants it from Settings when they
/// switch the rule on). Only all-day events of the chosen calendars count; with no calendar chosen, the calendars
/// that look like the macOS Holidays calendar ("Holidays in …", "Feriados …", …). Event titles stay on the Mac.
public actor EventKitHolidaySource: HolidaySource {
    private var store: EKEventStore?

    public init() {}

    public func daysOff(calendarIDs: [String], from start: Date, to end: Date, calendar: Calendar) async -> [String: String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, start < end else { return [:] }
        let store = self.store ?? EKEventStore()
        self.store = store
        let all = store.calendars(for: .event)
        let chosen = calendarIDs.isEmpty
            ? all.filter { Self.looksLikeHolidayCalendar(title: $0.title) }
            : all.filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [:] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
        var days: [String: String] = [:]
        for event in store.events(matching: predicate) where event.isAllDay {
            guard let first = event.startDate, let last = event.endDate else { continue }
            let title = (event.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "Day off"
            var day = calendar.startOfDay(for: first)
            // All-day events end at the following midnight (exclusive); a one-day event covers one day.
            repeat {
                let key = DayKey.of(day, calendar: calendar)
                if days[key] == nil { days[key] = String(title.prefix(80)) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            } while day < last && day < end
        }
        return days
    }

    public nonisolated func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = ObserverToken(NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: nil, queue: nil
            ) { _ in continuation.yield() })
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token.observer) }
        }
    }

    /// Whether a calendar title looks like a public-holiday calendar (the macOS Holidays calendar in common
    /// languages). Used only when the user did not pick calendars.
    public static func looksLikeHolidayCalendar(title: String) -> Bool {
        let lowered = title.lowercased()
        let words = [
            "holiday", "feriado", "férié", "ferie", "feiertag", "festivi", "festius", "feestdag", "helligdag", "helgdag",
            "pyhä", "święta", "svátk", "sviatk", "ünnep", "sărbători", "αργί", "праздн", "свята", "tatil", "חגים",
            "عطل", "祝日", "休日", "节假日", "假日", "공휴일", "วันหยุด", "ngày lễ", "libur", "cuti",
        ]
        return words.contains { lowered.contains($0) }
    }
}

/// Holds a `NotificationCenter` observer so the stream's termination handler can remove it.
private final class ObserverToken: @unchecked Sendable {
    let observer: any NSObjectProtocol
    init(_ observer: any NSObjectProtocol) { self.observer = observer }
}
