import Foundation
import MergeCueCore

/// Automatic-sync pause and schedule helpers shared by the menu bar menu and Settings (the setting itself lives
/// in `TrackingPreferences`, so it persists and reaches Sync through `.setTrackingPreferences`).
extension AppModel {
    /// The effective automatic-sync pause Sync reported (any account; the setting is global).
    var autoSyncPause: AutoSyncPause? {
        state.accounts.lazy.compactMap(\.status.autoSyncPause).first
    }

    /// Pauses automatic sync until `until` (`Date.distantFuture` = until resumed; nil resumes). Resuming also lifts
    /// a schedule pause until it would have ended ("Sync anyway").
    func pauseAutoSync(until: Date?) async {
        var updated = state.trackingPreferences
        updated.autoSyncPausedUntil = until
        if until != nil { updated.autoSyncScheduleOverrideUntil = nil }
        await send(.setTrackingPreferences(updated))
    }

    /// "Sync anyway": automatic sync runs until the current schedule pause would have ended.
    func syncAnywayUntil(_ until: Date?) async {
        var updated = state.trackingPreferences
        updated.autoSyncPausedUntil = nil
        updated.autoSyncScheduleOverrideUntil = until ?? now.addingTimeInterval(24 * 3_600)
        await send(.setTrackingPreferences(updated))
    }

    /// Replaces the schedule rules (an override of the previous rules is dropped).
    func setAutoSyncSchedule(_ schedule: AutoSyncSchedule) async {
        var updated = state.trackingPreferences
        updated.autoSyncSchedule = schedule
        updated.autoSyncScheduleOverrideUntil = nil
        await send(.setTrackingPreferences(updated))
    }
}

/// User-facing wording for automatic-sync pauses (no em dashes in copy).
enum AutoSyncText {
    /// "Weekend", "Outside working hours", the holiday's name, or "Paused by you".
    static func reason(_ reason: AutoSyncPauseReason) -> String {
        switch reason {
        case .manual: "Paused by you"
        case .weekend: "Weekend"
        case .outsideWorkingHours: "Outside working hours"
        case .holiday(let name): name
        }
    }

    /// "Auto-sync paused until Monday 9:00 (Weekend)." / "Auto-sync paused until you resume it."
    static func status(_ pause: AutoSyncPause, now: Date, calendar: Calendar = .current) -> String {
        let why = pause.reason == .manual ? "" : " (\(reason(pause.reason)))"
        guard let until = pause.until else { return "Auto-sync paused until you resume it\(why)." }
        return "Auto-sync paused until \(moment(until, now: now, calendar: calendar))\(why)."
    }

    /// "18:00", "tomorrow 9:00", "Monday 9:00" or "24 Dec 9:00" (local time).
    static func moment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        if date.timeIntervalSince(now) < 6 * 86_400 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }

    /// 9:00 on the next Monday after `now` (local time).
    static func nextMondayMorning(after now: Date, calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.weekday = 2
        components.hour = 9
        components.minute = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now.addingTimeInterval(7 * 86_400)
    }

    /// 9:00 tomorrow (local time).
    static func tomorrowMorning(after now: Date, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Minutes after midnight as a `Date` today (for time pickers) and back.
    static func date(minute: Int, calendar: Calendar = .current, reference: Date = Date()) -> Date {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: reference) ?? reference
    }

    static func minute(of date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
