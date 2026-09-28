import AppKit
import MergeCueCore
import MergeCueEngine
import SwiftUI

// MARK: - Repositories

struct RepositoriesSettings: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Map repositories from any provider to local checkouts. Agents work in an isolated worktree created from the mapped checkout; MergeCue never edits a GitButler workspace or a dirty checkout directly.")
                .scaledFont(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Card("Mapped", systemImage: "folder.badge.gearshape") {
                if model.state.mappings.isEmpty {
                    Text("No mappings yet").scaledFont(.callout).foregroundStyle(Theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.state.mappings.enumerated()), id: \.element.id) { index, mapping in
                        if index > 0 { Divider().padding(.vertical, 8) }
                        MappingRow(model: model, mapping: mapping)
                    }
                }
            }
            if model.state.accounts.isEmpty {
                Text("Connect an account in Settings › Accounts to list its repositories.")
                    .scaledFont(.callout).foregroundStyle(Theme.textSecondary)
            } else {
                AccountRepositoriesSection(model: model)
            }
        }
    }
}

/// A repository without a mapping: find matching checkouts (with confidence) or choose a folder.
struct UnmappedRepositoryRow: View {
    let model: AppModel
    let repo: Repository
    var hasOpenPRs = false
    @State private var found: [MappingSuggestion]?
    @State private var searching = false

    /// Own search results, else candidates from the background checkout scan.
    private var suggestions: [MappingSuggestion]? {
        found ?? model.state.checkoutScan.suggestions[repo.key]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProviderGlyph(kind: repo.providerKind, size: 16)
                Text(repo.fullPath).scaledFont(.callout)
                Text(repo.providerKind.displayName).scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                if hasOpenPRs {
                    Chip(text: "has open \(repo.providerKind.changeRequestAbbreviation)s", symbol: "arrow.triangle.pull", tone: .neutral)
                }
                Spacer()
                if searching { ProgressView().controlSize(.small) }
                Button("Find Checkouts") { find() }
                    .disabled(searching)
                    .help("Looks in ~/Developer, ~/Projects, ~/Code, ~/src and ~/Documents/GitHub for clones whose remote matches")
                Button("Choose Folder…") { chooseCheckout() }
            }
            if let suggestions {
                if suggestions.isEmpty {
                    Text("No matching checkout found — choose the folder yourself.").scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(suggestions, id: \.checkoutPath) { suggestion in
                    HStack(spacing: 8) {
                        ConfidenceChip(confidence: suggestion.confidence)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(UIFormat.abbreviatedPath(suggestion.checkoutPath)).scaledFont(.caption.monospaced())
                            Text(suggestion.matchedRemote.map { "\(suggestion.reason) · \($0)" } ?? suggestion.reason)
                                .scaledFont(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Use This Checkout") {
                            Task { await model.send(.addMapping(repo: repo.key, repoFullPath: repo.fullPath, checkoutPath: suggestion.checkoutPath)) }
                        }
                        .disabled(suggestion.confidence == .mismatch)
                    }
                    .padding(.leading, 24)
                }
            }
        }
    }

    private func find() {
        searching = true
        Task {
            found = await model.send(.findCheckouts(repo.key))?.mappingSuggestions ?? []
            searching = false
        }
    }

    private func chooseCheckout() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Map"
        panel.message = "Choose the local checkout of \(repo.fullPath) (\(repo.providerKind.displayName))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.send(.addMapping(repo: repo.key, repoFullPath: repo.fullPath, checkoutPath: url.path(percentEncoded: false))) }
    }
}

struct ConfidenceChip: View {
    var confidence: MappingConfidence
    var confirmed = false

    var body: some View {
        switch confidence {
        case .exact: Chip(text: confirmed ? "Exact match" : "Exact match · unconfirmed", symbol: "checkmark.seal", tone: .success)
        case .probable: Chip(text: confirmed ? "Confirmed" : "Probable · needs confirmation", symbol: "questionmark.circle",
                             tone: confirmed ? .neutral : .attention)
        case .mismatch: Chip(text: "Remote mismatch", symbol: "exclamationmark.triangle", tone: .critical)
        }
    }
}

struct MappingRow: View {
    let model: AppModel
    let mapping: RepoMapping

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderGlyph(kind: mapping.repo.kind, size: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mapping.repoFullPath).scaledFont(.callout.weight(.medium))
                    ConfidenceChip(confidence: mapping.confidence, confirmed: mapping.isConfirmed)
                }
                Text(UIFormat.abbreviatedPath(mapping.checkoutPath))
                    .scaledFont(.caption.monospaced())
                    .textSelection(.enabled)
                if let remote = mapping.matchedRemote {
                    Text("Matched remote \(remote)")
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let files = model.state.instructionFiles[mapping.checkoutPath], !files.isEmpty {
                    Text("Project instructions: \(files.joined(separator: ", "))")
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if !mapping.isConfirmed {
                Button("Confirm") { Task { await model.send(.confirmMapping(id: mapping.id)) } }
                    .buttonStyle(GradientButtonStyle(size: .small))
                    .accessibilityLabel("Confirm mapping of \(mapping.repoFullPath)")
            }
            Button("Remove") { Task { await model.send(.removeMapping(id: mapping.id)) } }
                .accessibilityLabel("Remove mapping of \(mapping.repoFullPath)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(mapping.repoFullPath), \(mapping.repo.kind.displayName), mapped to \(UIFormat.abbreviatedPath(mapping.checkoutPath))")
    }
}

// MARK: - Notifications

struct NotificationsSettings: View {
    let model: AppModel

    var body: some View {
        let quiet = model.state.quietHours
        VStack(alignment: .leading, spacing: 14) {
            NotificationPermissionCard(model: model)
            Card("Pause", systemImage: "bell.slash") {
                HStack(spacing: 8) {
                    if let until = model.state.notificationsPausedUntil, model.notificationsPaused {
                        Text("Paused until \(UIFormat.dateTime(until))").scaledFont(.callout)
                        Spacer()
                        Button("Resume") { Task { await model.send(.pauseNotifications(until: nil)) } }
                    } else {
                        Text("Notifications are on").scaledFont(.callout)
                        Spacer()
                        Button("Pause for 1 Hour") { Task { await model.send(.pauseNotifications(until: model.now.addingTimeInterval(3_600))) } }
                        Button("Until Tomorrow") { Task { await model.send(.pauseNotifications(until: PauseOptions.tomorrowMorning(after: model.now))) } }
                    }
                }
            }
            Card("Quiet hours", systemImage: "moon") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Silence notifications during quiet hours", isOn: Binding(
                        get: { quiet != nil },
                        set: { enabled in
                            let hours = enabled ? QuietHours(start: (22, 0), end: (7, 0), timeZone: .current) : nil
                            Task { await model.send(.setQuietHours(hours)) }
                        }
                    ))
                    .toggleStyle(.switch)
                    if let quiet {
                        HStack(spacing: 12) {
                            DatePicker("From", selection: minuteBinding(quiet, start: true), displayedComponents: .hourAndMinute)
                            DatePicker("Until", selection: minuteBinding(quiet, start: false), displayedComponents: .hourAndMinute)
                        }
                        .fixedSize()
                        Text("Items still appear in the inbox; only alerts are held back (\(quiet.timeZoneID)).")
                            .scaledFont(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Card("Notify me about", systemImage: "bell.badge") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(NotificationCategory.allCases, id: \.self) { category in
                        Toggle(category.displayName, isOn: categoryBinding(category))
                    }
                    Text("One grouped notification per PR/MR. Your own comments and green re-runs never notify. Switching a kind off only silences its alerts — the items still appear in the inbox.")
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func categoryBinding(_ category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { model.state.notificationPreferences.isEnabled(category) },
            set: { enabled in Task { await model.send(.setNotificationCategory(category, enabled: enabled)) } }
        )
    }

    private func minuteBinding(_ quiet: QuietHours, start: Bool) -> Binding<Date> {
        Binding(
            get: { RuleEditorSheet.date(minute: start ? quiet.startMinute : quiet.endMinute) },
            set: { date in
                var updated = quiet
                if start { updated.startMinute = RuleEditorSheet.minute(of: date) } else { updated.endMinute = RuleEditorSheet.minute(of: date) }
                Task { await model.send(.setQuietHours(updated)) }
            }
        )
    }
}

/// The app's notification permission as macOS reports it, with a way to change it.
struct NotificationPermissionCard: View {
    let model: AppModel

    var body: some View {
        let permission = model.notificationPermission
        Card("Permission", systemImage: "bell.badge") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: symbol(permission))
                        .foregroundStyle(Theme.color(permission.tone))
                        .accessibilityHidden(true)
                    Text("macOS: \(permission.title)")
                        .scaledFont(.callout.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    if permission == .notDetermined {
                        Button("Allow Notifications…") {
                            Task {
                                await model.send(.requestNotificationPermission)
                                await model.refreshNotificationPermission()
                            }
                        }
                        .buttonStyle(GradientButtonStyle(size: .small))
                    }
                    if model.canOpenNotificationSettings && permission != .unavailable {
                        Button("Open System Settings…") { model.openNotificationSettings() }
                            .help("System Settings › Notifications › MergeCue")
                    }
                }
                .accessibilityElement(children: .contain)
                Text(explanation(permission))
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.refreshNotificationPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshNotificationPermission() }
        }
    }

    private func explanation(_ permission: NotificationPermission) -> String {
        switch model.mode {
        case .live: permission.explanation
        case .demo: permission.explanation + " Demo notifications are titled “Demo · …”."
        case .preview: permission == .unavailable
            ? "Preview data: this build can't read or change macOS notification permission."
            : permission.explanation + " (This is the app's real macOS setting; the items shown are preview data.)"
        }
    }

    private func symbol(_ permission: NotificationPermission) -> String {
        switch permission {
        case .authorized: "checkmark.circle.fill"
        case .denied: "bell.slash.fill"
        case .provisional: "tray.full"
        case .notDetermined: "questionmark.circle"
        case .unknown, .unavailable: "minus.circle"
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var confirmModeSwitch = false

    private func trackingBinding(_ keyPath: WritableKeyPath<TrackingPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.state.trackingPreferences[keyPath: keyPath] },
            set: { enabled in
                var updated = model.state.trackingPreferences
                updated[keyPath: keyPath] = enabled
                Task { await model.send(.setTrackingPreferences(updated)) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card("Startup", systemImage: "power") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch MergeCue at login", isOn: Binding(
                        get: { loginItem == .enabled || loginItem == .requiresApproval },
                        set: { enabled in Task { await model.send(.setLaunchAtLogin(enabled)) } }
                    ))
                    .toggleStyle(.switch)
                    .disabled(loginItem == nil || loginItem == .unavailable)
                    Text(loginItemNote)
                        .scaledFont(.caption)
                        .foregroundStyle(loginItem == .requiresApproval ? Theme.waitingText : Theme.textSecondary)
                }
            }
            Card("Tracking", systemImage: "person.crop.circle.badge.checkmark") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your own PRs/MRs are always tracked.")
                        .scaledFont(.callout)
                    Toggle("Also track PRs/MRs that request my review", isOn: trackingBinding(\.includeReviewRequests))
                        .toggleStyle(.switch)
                    Toggle("Also track PRs/MRs I've reviewed or commented on", isOn: trackingBinding(\.includeInvolved))
                        .toggleStyle(.switch)
                    Text("Off by default: MergeCue then lists only pull/merge requests you authored. Other people's work appears only if you switch these on.")
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Card("Data source", systemImage: "externaldrive.connected.to.line.below") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Demo mode", isOn: Binding(get: { model.mode != .live }, set: { _ in confirmModeSwitch = true }))
                        .toggleStyle(.switch)
                        .disabled(model.switchModeHandler == nil || model.mode == .preview)
                    Text(model.mode == .preview
                         ? "Preview data (development build). Launch without --preview to use your accounts."
                         : "Demo mode shows bundled fixture PRs/MRs through the real engine, always badged “Demo data”. Its data is kept separately from your accounts; switching relaunches MergeCue.")
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Card("Setup", systemImage: "wand.and.rays") {
                HStack {
                    Text("Accounts, repositories, agents and notifications, step by step.")
                        .scaledFont(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Run Setup Assistant…") { model.showOnboarding() }
                }
            }
            Card("Menu bar", systemImage: "menubar.rectangle") {
                Toggle("Show the “Needs you” count next to the icon", isOn: $model.showCountInMenuBar)
                    .toggleStyle(.switch)
            }
            Card("Text size", systemImage: "textformat.size") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Text size", selection: $model.textSize) {
                        ForEach(TextSizePreference.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Text size")
                    Text("Sizes text in the MergeCue window and popover. macOS has no system-wide text size for Mac apps, so MergeCue has its own.")
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Card("Keyboard", systemImage: "keyboard") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text("Show the popover from any app")
                            .scaledFont(.callout)
                        Spacer(minLength: 8)
                        Picker("Global shortcut", selection: $model.globalHotKey) {
                            ForEach(HotKeyPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                                    .accessibilityLabel(preset.spokenName)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Global shortcut")
                        .accessibilityValue(model.globalHotKey.spokenName)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        shortcut(model.globalHotKey == .off ? "—" : model.globalHotKey.displayName, "Show or hide the popover (works in any app, no Accessibility permission needed)")
                        shortcut("⌘1 … ⌘5", "Inbox, PRs & MRs, Tasks, Rules, Settings")
                        shortcut("⌘R", "Refresh all accounts")
                        shortcut("⌘,", "Settings")
                        shortcut("⌘K", "Search the inbox")
                        shortcut("↑ ↓", "Move through the popover, the inbox, pull requests and rules")
                        shortcut("↩ or Space", "Open the selected item")
                        shortcut("⌘↩", "Primary action of the selected item (Fix with AI, view task, edit rule)")
                        shortcut("Esc", "Close the popover or a sheet")
                    }
                }
            }
        }
        .confirmationDialog(model.mode == .demo ? "Switch to your accounts?" : "Switch to demo data?", isPresented: $confirmModeSwitch) {
            Button(model.mode == .demo ? "Relaunch with My Accounts" : "Relaunch in Demo Mode") {
                model.switchModeHandler?(model.mode == .demo ? .live : .demo)
            }
        } message: {
            Text(model.mode == .demo
                 ? "MergeCue relaunches with your connected accounts. The demo data stays in its own folder."
                 : "MergeCue relaunches with bundled demo data (badged “Demo data”). Your accounts and data are untouched.")
        }
    }

    private var loginItem: LoginItemState? { model.state.runtime?.loginItem }

    private var loginItemNote: String {
        switch loginItem {
        case .enabled: "Opens in the menu bar when you log in. Manage it in System Settings › General › Login Items."
        case .requiresApproval: "Waiting for your approval in System Settings › General › Login Items."
        case .disabled: "Off. MergeCue opens only when you start it."
        case .unavailable: "Available in the installed app (not in development builds run from SwiftPM)."
        case nil: "Not available with preview data."
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys).scaledFont(.callout.monospaced()).foregroundStyle(Theme.textSecondary)
            Text(action).scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Data

struct DataSettings: View {
    let model: AppModel
    @State private var confirmReset = false
    @State private var confirmCleanup = false

    var body: some View {
        let info = model.state.runtime
        VStack(alignment: .leading, spacing: 14) {
            Card("Local data", systemImage: "externaldrive") {
                VStack(alignment: .leading, spacing: 6) {
                    if let info {
                        row("Data folder", info.dataRoot)
                        row("Database", info.databasePath)
                        row("Task worktrees", info.worktreesPath)
                        row("Agent config backups", info.backupsPath)
                        row("Logs", info.logsPath)
                        row("Agent socket", info.socketPath + (info.ipcRunning ? "" : " (not running)"))
                    } else {
                        Text("Preview data lives only in memory.").scaledFont(.callout).foregroundStyle(Theme.textSecondary)
                    }
                    Text(model.mode == .demo
                         ? "Demo data is kept in its own folder, separate from your accounts. Demo tokens are fixtures held in memory."
                         : "Tokens live only in your Keychain, never in the database or logs. Nothing is sent anywhere except the providers you connect. No telemetry.")
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if info != nil {
                Card("Housekeeping", systemImage: "clock.arrow.circlepath") {
                    HousekeepingCard(model: model) { confirmCleanup = true }
                }
            }
            Card("Maintenance", systemImage: "wrench.and.screwdriver") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Show in Finder") {
                            if let info { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: info.dataRoot, directoryHint: .isDirectory)]) }
                        }
                        .disabled(info == nil)
                        Button("Export Database…") { export() }
                            .disabled(info == nil)
                        Button("Reset Local Data…", role: .destructive) { confirmReset = true }
                            .disabled(info == nil)
                    }
                    Text(info == nil
                         ? "\(model.mode.badgeText ?? "Preview"): nothing is stored, so there is nothing to export or reset."
                         : "Export writes a copy of the database (no tokens). Reset deletes every stored token and all local data; your checkouts and agent configs are not touched.")
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog(
            "Remove \(model.state.worktreeCleanupCandidates.count) task worktree\(model.state.worktreeCleanupCandidates.count == 1 ? "" : "s")?",
            isPresented: $confirmCleanup
        ) {
            Button("Clean Up", role: .destructive) {
                Task { await model.send(.cleanUpWorktrees(model.state.worktreeCleanupCandidates.map(\.taskID))) }
            }
        } message: {
            Text("MergeCue removes the isolated git worktrees of these finished tasks. Your mapped checkouts, the tasks and their history stay. Unapplied agent changes in those worktrees are lost.")
        }
        .confirmationDialog("Reset all local data?", isPresented: $confirmReset) {
            Button("Delete Tokens and Data", role: .destructive) { Task { await model.send(.resetAllData) } }
        } message: {
            Text("MergeCue deletes every account token from your Keychain and all tasks, inbox items, rules and mappings\(model.mode == .demo ? " of the demo data" : ""). This can't be undone. Export the database first if you want a copy.")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MergeCue-\(model.mode == .demo ? "demo-" : "")\(Self.stamp(model.now)).sqlite"
        panel.canCreateDirectories = true
        panel.message = "Export a copy of MergeCue's database (contains no tokens)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.send(.exportDatabase(to: url)) }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).scaledFont(.callout).foregroundStyle(Theme.textSecondary).frame(width: 150, alignment: .leading)
            Text(UIFormat.abbreviatedPath(value)).scaledFont(.caption.monospaced()).textSelection(.enabled)
        }
    }
}

/// History retention status and the worktrees of finished tasks that can be removed (listed only; removal is the
/// owner's explicit "Clean up").
struct HousekeepingCard: View {
    let model: AppModel
    let onCleanUp: () -> Void

    var body: some View {
        let candidates = model.state.worktreeCleanupCandidates
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.retentionText(model.state.lastMaintenance))
                .scaledFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if candidates.isEmpty {
                Text("No worktrees of finished tasks to clean up.")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("Worktrees of finished tasks (unchanged for 14 days or more):")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.textSecondary)
                ForEach(candidates) { candidate in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(candidate.taskID.rawValue).scaledFont(.caption.monospaced())
                        Text("\(candidate.repoFullPath) · \(candidate.title)")
                            .scaledFont(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(candidate.state.displayName).scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .help(candidate.worktreePath)
                    .accessibilityElement(children: .combine)
                }
                HStack {
                    Spacer()
                    Button("Clean Up…", action: onCleanUp)
                }
            }
        }
    }

    static func retentionText(_ report: MaintenanceReport?) -> String {
        let policy = "History older than 90 days (events, finished tasks' activity and audit, resolved items of PRs/MRs no longer tracked) is pruned once a day."
        guard let report else { return policy + " Not run yet." }
        let size = ByteCountFormatter.string(fromByteCount: Int64(report.databaseBytes), countStyle: .file)
        return policy + " Last run \(UIFormat.dateTime(report.at)): \(report.removedRows) rows removed, database \(size)."
    }
}

// MARK: - About

struct AboutPane: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: AboutPane.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .accessibilityLabel("MergeCue app icon")
            Text("MergeCue")
                .scaledFont(.largeTitle.weight(.semibold))
            Text("PRs move forward. You stay in flow.")
                .scaledFont(.title3)
                .foregroundStyle(Theme.textSecondary)
            Text(version)
                .scaledFont(.callout.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            if model.mode != .live {
                ModeBadge(mode: model.mode)
                Text(model.mode.explanation)
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("GitHub, GitLab and Bitbucket Cloud in one place. See what needs you, and hand review comments and CI failures to the agent you already use.")
                .scaledFont(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 440)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// The running app's icon (`NSApp.applicationIconImage`); falls back to the approved icon shipped with the UI module.
    static var icon: NSImage {
        if Bundle.main.bundleURL.pathExtension == "app", let icon = NSApp?.applicationIconImage { return icon }
        return AppIconImage.image ?? NSApp?.applicationIconImage ?? NSImage()
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        guard let short else { return "Development build" }
        return "Version \(short)\(build.map { " (\($0))" } ?? "")"
    }
}
