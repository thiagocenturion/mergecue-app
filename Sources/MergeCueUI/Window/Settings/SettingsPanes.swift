import AppKit
import MergeCueCore
import SwiftUI

// MARK: - Repositories

struct RepositoriesSettings: View {
    let model: AppModel

    var body: some View {
        let mapped = Set(model.state.mappings.map(\.repo))
        let unmapped = model.knownRepositories.filter { !mapped.contains($0.key) }
        VStack(alignment: .leading, spacing: 14) {
            Text("Map repositories from any provider to local checkouts. Agents work in an isolated worktree created from the mapped checkout; MergeCue never edits a GitButler workspace or a dirty checkout directly.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Card("Mapped", systemImage: "folder.badge.gearshape") {
                if model.state.mappings.isEmpty {
                    Text("No mappings yet").font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.state.mappings.enumerated()), id: \.element.id) { index, mapping in
                        if index > 0 { Divider().padding(.vertical, 8) }
                        MappingRow(model: model, mapping: mapping)
                    }
                }
            }
            Card("Not mapped", systemImage: "folder.badge.questionmark") {
                if unmapped.isEmpty {
                    Text("Every repository with open PRs/MRs is mapped.").font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(unmapped, id: \.key) { repo in
                        HStack(spacing: 8) {
                            ProviderGlyph(kind: repo.providerKind, size: 16)
                            Text(repo.fullPath).font(.callout)
                            Text(repo.providerKind.displayName).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Map Checkout…") { chooseCheckout(for: repo) }
                        }
                    }
                }
            }
        }
    }

    private func chooseCheckout(for repo: Repository) {
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

struct MappingRow: View {
    let model: AppModel
    let mapping: RepoMapping

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderGlyph(kind: mapping.repo.kind, size: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mapping.repoFullPath).font(.callout.weight(.medium))
                    confidenceChip
                }
                Text(UIFormat.abbreviatedPath(mapping.checkoutPath))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if let remote = mapping.matchedRemote {
                    Text("Matched remote \(remote)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !mapping.isConfirmed {
                Button("Confirm") { Task { await model.send(.confirmMapping(id: mapping.id)) } }
                    .buttonStyle(GradientButtonStyle(size: .small))
            }
            Button("Remove") { Task { await model.send(.removeMapping(id: mapping.id)) } }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var confidenceChip: some View {
        switch mapping.confidence {
        case .exact: Chip(text: mapping.isConfirmed ? "Exact match" : "Exact match · unconfirmed", symbol: "checkmark.seal", tone: .success)
        case .probable: Chip(text: mapping.isConfirmed ? "Confirmed" : "Needs confirmation", symbol: "questionmark.circle",
                             tone: mapping.isConfirmed ? .neutral : .attention)
        case .mismatch: Chip(text: "Remote mismatch", symbol: "exclamationmark.triangle", tone: .critical)
        }
    }
}

// MARK: - Agents

struct AgentsSettings: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MergeCue hands tasks to the coding agent you already use. It never runs a model itself and never edits your agent's configuration without your consent and a backup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.state.agents.isEmpty {
                Text("No supported agent found. Install Claude Code or Codex CLI, then refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.state.agents) { agent in
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "terminal.fill")
                                .font(.title2)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(agent.name)\(agent.version.map { " \($0)" } ?? "")").font(.headline)
                                Text(agent.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Chip(text: agent.mcpRegistration.displayText,
                                 symbol: agent.mcpRegistration.isVerified ? "checkmark.seal.fill" : "exclamationmark.triangle",
                                 tone: agent.mcpRegistration.isVerified ? .success : .attention)
                        }
                        Text(agent.canOpenTasks ? "Open in \(agent.name) is available for tasks." : "Open in \(agent.name) isn't verified yet — tasks offer Copy command.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DisclosureGroup("Register MergeCue MCP") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(agent.kind == .claudeCode ? "Run in Terminal:" : "Add to ~/.codex/config.toml:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(Self.setupSnippet(for: agent.kind))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceSunken))
                                Text("`mergecue-mcp --print-config \(agent.kind == .claudeCode ? "claude" : "codex")` prints the exact configuration for this Mac.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 6)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    static func setupSnippet(for kind: AgentKind) -> String {
        let binary = "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp"
        switch kind {
        case .claudeCode: return "claude mcp add mergecue -- \"\(binary)\""
        case .codex: return "[mcp_servers.mergecue]\ncommand = \"\(binary)\""
        }
    }
}

// MARK: - Notifications

struct NotificationsSettings: View {
    let model: AppModel
    @AppStorage("notify.blockingComments") private var blockingComments = true
    @AppStorage("notify.ciFailures") private var ciFailures = true
    @AppStorage("notify.questions") private var questions = true
    @AppStorage("notify.reviewRequests") private var reviewRequests = true
    @AppStorage("notify.results") private var results = true

    var body: some View {
        let quiet = model.state.quietHours
        VStack(alignment: .leading, spacing: 14) {
            Card("Pause", systemImage: "bell.slash") {
                HStack(spacing: 8) {
                    if let until = model.state.notificationsPausedUntil, model.notificationsPaused {
                        Text("Paused until \(UIFormat.dateTime(until))").font(.callout)
                        Spacer()
                        Button("Resume") { Task { await model.send(.pauseNotifications(until: nil)) } }
                    } else {
                        Text("Notifications are on").font(.callout)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Card("Notify me about", systemImage: "bell.badge") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Blocking review comments and requested changes", isOn: $blockingComments)
                    Toggle("Failed CI checks on my PRs/MRs", isOn: $ciFailures)
                    Toggle("Reviewer questions", isOn: $questions)
                    Toggle("Review requests", isOn: $reviewRequests)
                    Toggle("Agent results ready for review", isOn: $results)
                    Text("One grouped notification per PR/MR. Your own comments and green re-runs never notify.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
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

// MARK: - General

struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card("Startup", systemImage: "power") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch MergeCue at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .disabled(true)
                    Text("Opt-in via macOS Login Items; available in the signed app build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Card("Menu bar", systemImage: "menubar.rectangle") {
                Toggle("Show the “Needs you” count next to the icon", isOn: $model.showCountInMenuBar)
                    .toggleStyle(.switch)
            }
            Card("Keyboard", systemImage: "keyboard") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    shortcut("⌘1 … ⌘5", "Inbox, PRs & MRs, Tasks, Rules, Settings")
                    shortcut("⌘R", "Refresh all accounts")
                    shortcut("⌘,", "Settings")
                    shortcut("↑ ↓ ↩", "Move through the popover and run the primary action")
                    shortcut("⌘↩", "Primary AI action of the selected inbox item")
                    shortcut("Esc", "Close the popover")
                }
            }
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys).font(.callout.monospaced()).foregroundStyle(.secondary)
            Text(action).font(.callout)
        }
    }
}

// MARK: - Data

struct DataSettings: View {
    let model: AppModel

    var body: some View {
        let paths = MergeCuePaths()
        VStack(alignment: .leading, spacing: 14) {
            Card("Local data", systemImage: "externaldrive") {
                VStack(alignment: .leading, spacing: 6) {
                    row("Database", UIFormat.abbreviatedPath(paths.database.path(percentEncoded: false)))
                    row("Task worktrees", UIFormat.abbreviatedPath(paths.worktrees.path(percentEncoded: false)))
                    row("Logs", UIFormat.abbreviatedPath(paths.logs.path(percentEncoded: false)))
                    Text("Tokens live only in your Keychain, never in the database or logs. Nothing is sent anywhere except the providers you connect. No telemetry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Card("Maintenance", systemImage: "wrench.and.screwdriver") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([paths.root]) }
                            .disabled(!FileManager.default.fileExists(atPath: paths.root.path(percentEncoded: false)))
                        Button("Export Database…") {}
                            .disabled(true)
                        Button("Reset Local Data…", role: .destructive) {}
                            .disabled(true)
                    }
                    Text(model.mode == .live ? "Export and reset are available once the local store is connected."
                         : "\(model.mode.badgeText ?? "Preview"): nothing is stored, so there is nothing to export or reset.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
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
                .font(.largeTitle.weight(.semibold))
            Text("PRs move forward. You stay in flow.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(version)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if model.mode != .live {
                ModeBadge(mode: model.mode)
                Text(model.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("GitHub, GitLab and Bitbucket Cloud in one place. See what needs you, and hand review comments and CI failures to the agent you already use.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
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
