import Foundation

/// Rules that pause automatic sync on days and hours the user is off (weekends, outside working hours, holidays and
/// days off from chosen macOS calendars). Sync resumes on its own as soon as no rule applies any more.
///
/// Only automatic requests stop (timers, return/focus, wake, network recovery). Refresh and user actions still run.
public struct AutoSyncSchedule: Codable, Sendable, Hashable {
    /// Pause on the weekend days of the user's calendar (Saturday and Sunday in most regions).
    public var pauseOnWeekends: Bool
    /// Pause outside `workdayStartMinute ..< workdayEndMinute` (local time).
    public var pauseOutsideWorkingHours: Bool
    /// Start of the working day in minutes after midnight (default 9:00).
    public var workdayStartMinute: Int
    /// End of the working day in minutes after midnight (default 18:00). Earlier than the start = overnight shift.
    public var workdayEndMinute: Int
    /// Pause on days with an all-day event in `holidayCalendarIDs` (or, when empty, the macOS Holidays calendars).
    public var pauseOnHolidays: Bool
    /// EventKit calendar identifiers whose all-day events count as days off (empty = detected holiday calendars).
    public var holidayCalendarIDs: [String]

    public init(
        pauseOnWeekends: Bool = false,
        pauseOutsideWorkingHours: Bool = false,
        workdayStartMinute: Int = 9 * 60,
        workdayEndMinute: Int = 18 * 60,
        pauseOnHolidays: Bool = false,
        holidayCalendarIDs: [String] = []
    ) {
        self.pauseOnWeekends = pauseOnWeekends
        self.pauseOutsideWorkingHours = pauseOutsideWorkingHours
        self.workdayStartMinute = Self.clampMinute(workdayStartMinute)
        self.workdayEndMinute = Self.clampMinute(workdayEndMinute)
        self.pauseOnHolidays = pauseOnHolidays
        self.holidayCalendarIDs = holidayCalendarIDs
    }

    /// No rule: automatic sync always runs (the default).
    public static let off = AutoSyncSchedule()

    /// Whether any rule is switched on.
    public var hasRules: Bool { pauseOnWeekends || pauseOutsideWorkingHours || pauseOnHolidays }

    /// The rule that pauses automatic sync at `date`, if any. `holidays` maps day keys (`DayKey`) to a display name.
    public func pauseReason(at date: Date, calendar: Calendar, holidays: [String: String]) -> AutoSyncPauseReason? {
        if pauseOnHolidays, let name = holidays[DayKey.of(date, calendar: calendar)] {
            return .holiday(name)
        }
        if pauseOnWeekends, calendar.isDateInWeekend(date) {
            return .weekend
        }
        if pauseOutsideWorkingHours, !isWorkingTime(date, calendar: calendar) {
            return .outsideWorkingHours
        }
        return nil
    }

    /// Whether `date` falls inside the working hours (an empty window, start == end, counts as always working).
    public func isWorkingTime(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let start = workdayStartMinute, end = workdayEndMinute
        if start == end { return true }
        return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }

    /// The first moment after `date` at which automatic sync flips between paused and running (Friday 18:00 →
    /// Monday 9:00 with weekends and working hours on), searched up to `horizon` (default 21 days); nil when it
    /// never flips within the horizon.
    public func nextChange(
        after date: Date, calendar: Calendar, holidays: [String: String], horizon: TimeInterval = 21 * 86_400
    ) -> Date? {
        guard hasRules else { return nil }
        let paused = pauseReason(at: date, calendar: calendar, holidays: holidays) != nil
        var cursor = date
        let limit = date.addingTimeInterval(horizon)
        while cursor < limit {
            guard let next = nextBoundary(after: cursor, calendar: calendar), next > cursor else { return nil }
            if (pauseReason(at: next, calendar: calendar, holidays: holidays) != nil) != paused { return next }
            cursor = next
        }
        return nil
    }

    /// The next midnight, working-day start or working-day end after `date`: the only moments a rule can flip.
    private func nextBoundary(after date: Date, calendar: Calendar) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        var candidates: [Date] = []
        if let midnight = calendar.date(byAdding: .day, value: 1, to: startOfDay) { candidates.append(midnight) }
        if pauseOutsideWorkingHours {
            for dayOffset in 0...1 {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else { continue }
                for minute in [workdayStartMinute, workdayEndMinute] {
                    if let time = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day),
                       time > date {
                        candidates.append(time)
                    }
                }
            }
        }
        return candidates.filter { $0 > date }.min()
    }

    private static func clampMinute(_ minute: Int) -> Int { min(max(0, minute), 24 * 60 - 1) }

    private enum CodingKeys: String, CodingKey {
        case pauseOnWeekends, pauseOutsideWorkingHours, workdayStartMinute, workdayEndMinute, pauseOnHolidays
        case holidayCalendarIDs
    }

    /// Missing fields take their defaults (forward compatible with rules added later).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pauseOnWeekends: try c.decodeIfPresent(Bool.self, forKey: .pauseOnWeekends) ?? false,
            pauseOutsideWorkingHours: try c.decodeIfPresent(Bool.self, forKey: .pauseOutsideWorkingHours) ?? false,
            workdayStartMinute: try c.decodeIfPresent(Int.self, forKey: .workdayStartMinute) ?? 9 * 60,
            workdayEndMinute: try c.decodeIfPresent(Int.self, forKey: .workdayEndMinute) ?? 18 * 60,
            pauseOnHolidays: try c.decodeIfPresent(Bool.self, forKey: .pauseOnHolidays) ?? false,
            holidayCalendarIDs: try c.decodeIfPresent([String].self, forKey: .holidayCalendarIDs) ?? []
        )
    }
}

/// Why automatic sync is paused right now.
public enum AutoSyncPauseReason: Codable, Sendable, Hashable {
    /// The user paused it (menu bar ▸ Pause Auto-Sync).
    case manual
    case weekend
    case outsideWorkingHours
    /// A day off from a calendar (the event title, e.g. "Christmas Day").
    case holiday(String)
}

/// The effective automatic-sync pause (manual pause or schedule rule) published with each account's status.
public struct AutoSyncPause: Codable, Sendable, Hashable {
    public var reason: AutoSyncPauseReason
    /// When automatic sync resumes on its own; nil = only when the user resumes it.
    public var until: Date?

    public init(reason: AutoSyncPauseReason, until: Date?) {
        self.reason = reason
        self.until = until
    }
}

/// A calendar day as `yyyy-MM-dd` in a given calendar (holiday lookups).
public enum DayKey {
    public static func of(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension TrackingPreferences {
    /// The automatic-sync pause in effect at `now`, or nil when automatic sync runs. A manual pause wins over the
    /// schedule; "Sync anyway" (`autoSyncScheduleOverrideUntil`) lifts a schedule pause until it ends.
    public func autoSyncPause(at now: Date, calendar: Calendar, holidays: [String: String]) -> AutoSyncPause? {
        if isAutoSyncPaused(at: now), let until = autoSyncPausedUntil {
            return AutoSyncPause(reason: .manual, until: until == .distantFuture ? nil : until)
        }
        if let override = autoSyncScheduleOverrideUntil, override > now { return nil }
        guard let reason = autoSyncSchedule.pauseReason(at: now, calendar: calendar, holidays: holidays) else { return nil }
        return AutoSyncPause(reason: reason, until: autoSyncSchedule.nextChange(after: now, calendar: calendar, holidays: holidays))
    }

    /// When the automatic-sync pause state may change next (manual pause end, override end, or a schedule
    /// boundary); nil = not before something else changes the preferences.
    public func nextAutoSyncChange(after now: Date, calendar: Calendar, holidays: [String: String]) -> Date? {
        var candidates: [Date] = []
        if let until = autoSyncPausedUntil, until > now, until != .distantFuture { candidates.append(until) }
        if let override = autoSyncScheduleOverrideUntil, override > now { candidates.append(override) }
        if let change = autoSyncSchedule.nextChange(after: now, calendar: calendar, holidays: holidays) {
            candidates.append(change)
        }
        return candidates.min()
    }
}
