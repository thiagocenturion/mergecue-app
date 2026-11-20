import EventKit
import MergeCueCore
import MergeCueRuntime
import SwiftUI

/// Settings ▸ Accounts ▸ account: "Automatic sync" (global, all accounts): the current pause, timed pauses, and the
/// rules that pause automatic sync on their own (weekends, outside working hours, holidays and days off from
/// calendars). Refresh always works.
struct AutoSyncScheduleSection: View {
    let model: AppModel
    @State private var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    @State private var calendars: [CalendarChoice] = []

    private var schedule: AutoSyncSchedule { model.state.trackingPreferences.autoSyncSchedule }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Automatic sync").scaledFont(.callout.weight(.medium))
                Text("All accounts").scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                pauseMenu
            }
            statusLine
            ruleRow("Pause on weekends", caption: "Your region's weekend days, Saturday and Sunday in most places.",
                    isOn: binding(\.pauseOnWeekends))
            VStack(alignment: .leading, spacing: 6) {
                ruleRow("Pause outside working hours", caption: nil, isOn: binding(\.pauseOutsideWorkingHours))
                if schedule.pauseOutsideWorkingHours {
                    HStack(spacing: 8) {
                        Text("Working hours").scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                        timePicker("Start of working hours", minute: \.workdayStartMinute)
                        Text("to").scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                        timePicker("End of working hours", minute: \.workdayEndMinute)
                    }
                    .padding(.leading, 20)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ruleRow("Pause on holidays and days off", caption: "All-day events in your calendars, such as Holidays.",
                        isOn: Binding(
                            get: { schedule.pauseOnHolidays },
                            set: { enabled in Task { await setHolidays(enabled) } }
                        ))
                if schedule.pauseOnHolidays { holidayDetails.padding(.leading, 20) }
            }
            Text("Sync resumes on its own when no rule applies. Click Refresh to check right away at any time.")
                .scaledFont(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { reloadCalendars() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadCalendars()
        }
    }

    // MARK: Status and pause

    @ViewBuilder private var statusLine: some View {
        if let pause = model.autoSyncPause {
            HStack(spacing: 8) {
                Label(AutoSyncText.status(pause, now: model.now), systemImage: "pause.circle")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if pause.reason == .manual {
                    Button("Resume") { Task { await model.pauseAutoSync(until: nil) } }
                } else {
                    Button("Sync Anyway") { Task { await model.syncAnywayUntil(pause.until) } }
                        .help(pause.until.map { "Syncs automatically until \(AutoSyncText.moment($0, now: model.now))" } ?? "Syncs automatically for the next 24 hours")
                }
            }
        } else if let override = model.state.trackingPreferences.autoSyncScheduleOverrideUntil, override > model.now {
            Label("Syncing anyway until \(AutoSyncText.moment(override, now: model.now)).", systemImage: "play.circle")
                .scaledFont(.caption)
                .foregroundStyle(Theme.textSecondary)
        } else {
            Label("Running. MergeCue checks each account once per its interval.", systemImage: "play.circle")
                .scaledFont(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var pauseMenu: some View {
        Menu("Pause") {
            Button("For 1 Hour") { Task { await model.pauseAutoSync(until: model.now.addingTimeInterval(3_600)) } }
            Button("Until Tomorrow 9:00") { Task { await model.pauseAutoSync(until: AutoSyncText.tomorrowMorning(after: model.now)) } }
            Button("Until Monday 9:00") { Task { await model.pauseAutoSync(until: AutoSyncText.nextMondayMorning(after: model.now)) } }
            Button("Until I Resume") { Task { await model.pauseAutoSync(until: .distantFuture) } }
        }
        .fixedSize()
        .accessibilityLabel("Pause automatic sync")
    }

    // MARK: Rules

    /// A rule with its switch on the trailing edge, like the other rows of the account card.
    private func ruleRow(_ title: String, caption: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption)
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AutoSyncSchedule, Bool>) -> Binding<Bool> {
        Binding(
            get: { schedule[keyPath: keyPath] },
            set: { enabled in
                var updated = schedule
                updated[keyPath: keyPath] = enabled
                Task { await model.setAutoSyncSchedule(updated) }
            }
        )
    }

    private func timePicker(_ label: String, minute keyPath: WritableKeyPath<AutoSyncSchedule, Int>) -> some View {
        DatePicker(label, selection: Binding(
            get: { AutoSyncText.date(minute: schedule[keyPath: keyPath]) },
            set: { date in
                var updated = schedule
                updated[keyPath: keyPath] = AutoSyncText.minute(of: date)
                Task { await model.setAutoSyncSchedule(updated) }
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(label)
    }

    // MARK: Holidays

    @ViewBuilder private var holidayDetails: some View {
        switch calendarAccess {
        case .fullAccess:
            if calendars.isEmpty {
                Text("No calendars found. In the Calendar app, turn on Settings ▸ General ▸ Show Holidays calendar.")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All-day events in these calendars pause automatic sync for the day.")
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(calendars) { choice in
                        Toggle(isOn: calendarBinding(choice)) {
                            HStack(spacing: 6) {
                                Circle().fill(choice.color).frame(width: 8, height: 8).accessibilityHidden(true)
                                Text(choice.title).scaledFont(.callout)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        case .notDetermined:
            HStack(spacing: 8) {
                Text("MergeCue needs to read your calendars to know your days off.")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Calendar Access…") { Task { await requestAccess() } }
            }
        default:
            HStack(spacing: 8) {
                Label("Calendar access is off, so holidays can't pause sync.", systemImage: "exclamationmark.circle")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    /// The chosen calendars; with none chosen, the detected holiday calendars count (shown checked).
    private var effectiveCalendarIDs: Set<String> {
        let chosen = schedule.holidayCalendarIDs
        if !chosen.isEmpty { return Set(chosen) }
        return Set(calendars.filter(\.looksLikeHolidays).map(\.id))
    }

    private func calendarBinding(_ choice: CalendarChoice) -> Binding<Bool> {
        Binding(
            get: { effectiveCalendarIDs.contains(choice.id) },
            set: { included in
                var ids = effectiveCalendarIDs
                if included { ids.insert(choice.id) } else { ids.remove(choice.id) }
                var updated = schedule
                // Keep the order of the calendar list; an empty choice falls back to the detected ones.
                updated.holidayCalendarIDs = calendars.map(\.id).filter(ids.contains)
                Task { await model.setAutoSyncSchedule(updated) }
            }
        )
    }

    private func setHolidays(_ enabled: Bool) async {
        if enabled, EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            await requestAccess()
        }
        var updated = schedule
        updated.pauseOnHolidays = enabled
        await model.setAutoSyncSchedule(updated)
    }

    private func requestAccess() async {
        let store = EKEventStore()
        _ = try? await store.requestFullAccessToEvents()
        reloadCalendars()
        // Nudge Sync to read the calendars now that access may have been granted.
        if schedule.pauseOnHolidays { await model.setAutoSyncSchedule(schedule) }
    }

    private func reloadCalendars() {
        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        guard calendarAccess == .fullAccess else {
            calendars = []
            return
        }
        calendars = CalendarChoice.load()
    }
}

/// One event calendar the user can count as days off.
struct CalendarChoice: Identifiable, Hashable {
    var id: String
    var title: String
    var color: Color
    var looksLikeHolidays: Bool

    /// Event calendars, holiday-looking ones first, then by title.
    static func load() -> [CalendarChoice] {
        EKEventStore().calendars(for: .event)
            .map { calendar in
                CalendarChoice(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    color: calendar.color.map { Color(nsColor: $0) } ?? .secondary,
                    looksLikeHolidays: EventKitHolidaySource.looksLikeHolidayCalendar(title: calendar.title)
                )
            }
            .sorted { lhs, rhs in
                if lhs.looksLikeHolidays != rhs.looksLikeHolidays { return lhs.looksLikeHolidays }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }
}
