import Foundation

/// Days off read from the user's calendars (the macOS Holidays calendar or calendars the user picked), for the
/// "Pause on holidays" rule of `AutoSyncSchedule`. Implemented with EventKit by the runtime; read-only.
public protocol HolidaySource: Sendable {
    /// All-day events between `start` and `end` in `calendarIDs` (empty = the detected holiday calendars), as
    /// `DayKey` → event title. Empty when calendar access is not granted.
    func daysOff(calendarIDs: [String], from start: Date, to end: Date, calendar: Calendar) async -> [String: String]
    /// Fires when the calendars change (events added, subscriptions refreshed, access granted).
    func changes() -> AsyncStream<Void>
}
