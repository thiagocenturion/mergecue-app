import AppKit
import Foundation
import MergeCueCore
import Observation

/// Main window screens (⌘1–⌘5).
public nonisolated enum MainScreen: String, Sendable, Hashable, CaseIterable, Identifiable {
    case inbox, changeRequests, tasks, rules, settings

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .changeRequests: "Pull requests"
        case .tasks: "Tasks"
        case .rules: "Rules"
        case .settings: "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .inbox: "tray"
        case .changeRequests: "arrow.triangle.pull"
        case .tasks: "checklist.checked"
        case .rules: "wand.and.stars"
        case .settings: "gearshape"
        }
    }

    /// "1"…"5" for ⌘1–⌘5.
    public var shortcutDigit: Character {
        switch self {
        case .inbox: "1"
        case .changeRequests: "2"
        case .tasks: "3"
        case .rules: "4"
        case .settings: "5"
        }
    }
}

/// Tabs of the change request panel (Conversation / Files / Checks / Timeline).
public nonisolated enum ChangeRequestTab: String, Sendable, Hashable, CaseIterable, Identifiable {
    case conversation, files, checks, timeline

    public var id: String { rawValue }
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Tabs of the result review (Changes / Tests / Reply).
public nonisolated enum ReviewTab: String, Sendable, Hashable, CaseIterable, Identifiable {
    case changes, tests, reply

    public var id: String { rawValue }
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

public nonisolated enum SettingsTab: String, Sendable, Hashable, CaseIterable, Identifiable {
    case accounts, repositories, agents, notifications, general, data, about

    public var id: String { rawValue }
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    public var symbol: String {
        switch self {
        case .accounts: "person.crop.circle"
        case .repositories: "folder"
        case .agents: "terminal"
        case .notifications: "bell"
        case .general: "gearshape"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }
}

/// A transient message shown at the top of the popover and the window.
public nonisolated struct Banner: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var tone: Tone
    public var message: String

    public init(id: UUID = UUID(), tone: Tone, message: String) {
        self.id = id
        self.tone = tone
        self.message = message
    }
}

/// Offered right after a task was created: copy the command or open the agent.
public nonisolated struct HandoffOffer: Sendable, Hashable {
    public var taskID: TaskID

    public init(taskID: TaskID) {
        self.taskID = taskID
    }
}

/// A provider link to an unfamiliar host, waiting for the user to confirm before it opens (`WebLinkPolicy`).
public nonisolated struct LinkConfirmation: Sendable, Hashable, Identifiable {
    public var url: URL
    public var host: String
    public var id: String { url.absoluteString }

    public init(url: URL, host: String) {
        self.url = url
        self.host = host
    }
}

/// The rule being edited in the rule editor sheet.
public nonisolated struct RuleEditorContext: Sendable, Hashable, Identifiable {
    public var rule: Rule
    public var isNew: Bool
    public var id: String { rule.id }
}

/// Side effects the model performs outside the backend (injectable for tests and snapshots).
public struct AppEnvironment {
    public var now: () -> Date
    public var copyToPasteboard: (String) -> Void
    public var openURL: (URL) -> Void
    public var autoDismissBanners: Bool
    /// How often relative times refresh; nil disables the ticker.
    public var tickInterval: Duration?
    /// The Mac user's full name for the greeting (`NSFullUserName()`); nil falls back to the account display name.
    public var userFullName: String?
    /// Where UI preferences (text size, global shortcut) persist. In memory unless `withSystemServices()`.
    public var preferences: PreferenceStore = .inMemory()
    /// Speaks a message to assistive technologies (VoiceOver announcement). Inert unless `withSystemServices()`.
    public var announce: (String, Tone) -> Void = { _, _ in }
    /// Reads the app's notification permission from macOS; nil where it can't be known (no app bundle, tests).
    public var notificationPermission: (() async -> NotificationPermission)?
    /// Opens System Settings › Notifications › MergeCue.
    public var openNotificationSettings: (() -> Void)?

    public init(now: @escaping () -> Date, copyToPasteboard: @escaping (String) -> Void, openURL: @escaping (URL) -> Void,
                autoDismissBanners: Bool, tickInterval: Duration?, userFullName: String? = nil) {
        self.now = now
        self.copyToPasteboard = copyToPasteboard
        self.openURL = openURL
        self.autoDismissBanners = autoDismissBanners
        self.tickInterval = tickInterval
        self.userFullName = userFullName
    }

    /// Real clock, the general pasteboard and the default browser.
    public static var system: AppEnvironment {
        AppEnvironment(
            now: { Date() },
            copyToPasteboard: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            openURL: { url in NSWorkspace.shared.open(url) },
            autoDismissBanners: true,
            tickInterval: .seconds(30),
            userFullName: NSFullUserName()
        )
    }

    /// Frozen clock, no side effects (tests, snapshots).
    public static func fixed(now: Date, copied: ((String) -> Void)? = nil, userFullName: String? = nil) -> AppEnvironment {
        AppEnvironment(now: { now }, copyToPasteboard: copied ?? { _ in }, openURL: { _ in }, autoDismissBanners: false, tickInterval: nil,
                       userFullName: userFullName)
    }
}

extension AppEnvironment {
    /// `.system` plus the services only the installed app uses: persisted preferences, VoiceOver announcements and
    /// the real notification permission.
    public static func withSystemServices() -> AppEnvironment {
        var environment = AppEnvironment.system
        environment.preferences = .userDefaults
        environment.announce = { message, tone in AccessibilityAnnouncer.announce(message, tone: tone) }
        environment.notificationPermission = { await NotificationPermission.current() }
        environment.openNotificationSettings = { NotificationPermission.openSystemSettings() }
        return environment
    }
}

/// The observable UI model: holds the `AppState`, derived popover sections, filters, selection/navigation state and
/// banners, and routes every user action through `send(_:)` to the `AppBackend`.
@MainActor
@Observable
public final class AppModel {
    public let backend: any AppBackend
    public let mode: BackendMode
    public private(set) var state: AppState
    public private(set) var now: Date
    public private(set) var sections: PopoverSections
    public private(set) var isLoaded: Bool
    public private(set) var isRefreshing = false
    public private(set) var logExcerpts: [String: LogExcerpt] = [:]
    public private(set) var loadingLogIDs: Set<String> = []
    private(set) var indexes: Indexes

    // MARK: Navigation and selection
    public var screen: MainScreen = .inbox
    public var selectedAttentionID: String?
    public var selectedChangeRequestID: String?
    public var selectedTaskID: TaskID?
    public var selectedRuleID: String?
    public var settingsTab: SettingsTab = .accounts
    /// Keyboard selection in the popover (`PopoverItem.id`).
    public var popoverSelection: String?

    // MARK: Filters
    public var inboxFilter = InboxFilter()
    public var showReadInInbox = false
    public var changeRequestFilter = ChangeRequestFilter()

    // MARK: Presentation
    public var banners: [Banner] = []
    /// The error message of the most recent failed `send` (also shown as a banner), for inline error states.
    public private(set) var lastCommandError: String?
    /// Presented as the approval sheet.
    public var pendingPreview: ActionPreview?
    public var handoffOffer: HandoffOffer?
    /// A link to an unfamiliar host, presented as a confirmation alert before it opens.
    public var pendingLinkConfirmation: LinkConfirmation?
    public var ruleEditor: RuleEditorContext?
    /// Presented as the connect-account sheet.
    public var connectSheetKind: ProviderKind?
    public var showCountInMenuBar = true
    /// Agent picked in the handoff screen and the "Fix with AI" menu.
    public var selectedAgentKind: AgentKind?
    /// Tab of the change request panel next to the inbox list.
    public var changeRequestTab: ChangeRequestTab = .conversation
    /// Tab of the result review (Changes / Tests / Reply).
    public var reviewTab: ReviewTab = .changes
    /// File selected in the result review's diff.
    public var reviewSelectedFile: String?
    /// Collapsed popover sections.
    public var collapsedPopoverSections: Set<PopoverSection> = []
    /// Presents the setup assistant (first live launch without accounts, or Settings › General).
    public var showsOnboarding = false
    /// Settings › General › Text size (persisted; applied at the window and popover roots).
    public var textSize: TextSizePreference = .standard {
        didSet { environment.preferences.save(UIPreferenceKeys.textSize, textSize.rawValue) }
    }
    /// Settings › General › Global shortcut that opens the popover from anywhere (persisted).
    public var globalHotKey: HotKeyPreset = .defaultPreset {
        didSet { environment.preferences.save(UIPreferenceKeys.globalHotKey, globalHotKey.rawValue) }
    }
    /// Incremented whenever the popover is shown, so it resets keyboard focus each time.
    public internal(set) var popoverPresentationCount = 0
    /// The app's notification permission as macOS reports it (Settings › Notifications).
    public internal(set) var notificationPermission: NotificationPermission = .unknown

    // MARK: Hooks installed by the app shell
    @ObservationIgnored public var openMainWindowHandler: (() -> Void)?
    @ObservationIgnored public var closePopoverHandler: (() -> Void)?
    /// Relaunches the app with another backend (Settings › General › Demo mode). Nil where switching isn't possible.
    @ObservationIgnored public var switchModeHandler: ((BackendMode) -> Void)?
    /// Called when the owner finishes (or skips) the setup assistant.
    @ObservationIgnored public var onboardingCompletedHandler: (() -> Void)?
    /// Quits the app (popover footer menu). Nil where quitting isn't possible (snapshots, tests).
    @ObservationIgnored public var quitHandler: (() -> Void)?
    /// Banners whose auto-dismiss timer is paused (pointer over them or keyboard focus inside).
    @ObservationIgnored var heldBanners: Set<UUID> = []

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored private var changeTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    public init(backend: any AppBackend, initialState: AppState? = nil, environment: AppEnvironment = .system) {
        self.backend = backend
        self.mode = backend.mode
        self.environment = environment
        let now = environment.now()
        let state = initialState ?? .empty
        self.now = now
        self.state = state
        self.indexes = Indexes(state)
        self.sections = PopoverDerivation.derive(from: state, now: now)
        self.isLoaded = initialState != nil
        self.textSize = environment.preferences.load(UIPreferenceKeys.textSize).flatMap(TextSizePreference.init(rawValue:)) ?? .standard
        self.globalHotKey = environment.preferences.load(UIPreferenceKeys.globalHotKey).flatMap(HotKeyPreset.init(rawValue:)) ?? .defaultPreset
    }

    // MARK: Lifecycle

    /// Loads the state and keeps it current (backend change stream + relative-time ticker).
    public func start() async {
        if changeTask == nil {
            let stream = backend.changes()
            changeTask = Task { [weak self] in
                for await _ in stream {
                    guard let self else { return }
                    await self.reload()
                }
            }
        }
        if tickTask == nil, let interval = environment.tickInterval {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    self?.tick()
                }
            }
        }
        await reload()
    }

    /// Stops observing the backend.
    public func stop() {
        changeTask?.cancel()
        tickTask?.cancel()
        changeTask = nil
        tickTask = nil
    }

    public func reload() async {
        let fresh = await backend.loadState()
        apply(fresh)
    }

    /// Replaces the state and recomputes everything derived from it.
    public func apply(_ newState: AppState) {
        now = environment.now()
        if newState != state { state = newState }
        indexes = Indexes(newState)
        sections = PopoverDerivation.derive(from: newState, now: now)
        isLoaded = true
        if let selection = popoverSelection, !popoverRows.contains(where: { $0.id == selection }) {
            popoverSelection = nil
        }
    }

    /// Advances the clock for relative times and snooze expiry.
    public func tick() {
        now = environment.now()
        sections = PopoverDerivation.derive(from: state, now: now)
    }

    // MARK: Commands

    /// Sends a command to the backend, applies its result (banner, pasteboard, URL, preview sheet) and reloads the
    /// state. Errors become banners; returns nil on failure.
    @discardableResult
    public func send(_ command: AppCommand) async -> AppCommandResult? {
        if case .refresh = command { isRefreshing = true }
        defer { if case .refresh = command { isRefreshing = false } }
        do {
            let result = try await backend.perform(command)
            handle(result, for: command)
            await reload()
            return result
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastCommandError = message
            showBanner(.critical, message)
            await reload()
            return nil
        }
    }

    /// The single choke point for opening links in the browser: only https (http only to a connected instance
    /// configured with http); the account instances and well-known CI hosts open directly, any other host needs
    /// confirmation (`pendingLinkConfirmation`), everything else is refused with a banner.
    public func openLink(_ url: URL) {
        switch WebLinkPolicy.decision(for: url, instances: state.accounts.map(\.account.instance)) {
        case .open(let safe):
            environment.openURL(safe)
        case .confirm(let safe, let host):
            pendingLinkConfirmation = LinkConfirmation(url: safe, host: host)
        case .reject(let reason):
            showBanner(.attention, reason)
        }
    }

    /// Opens the link the user confirmed (re-checked: it must still be a web link).
    public func confirmPendingLink() {
        guard let pending = pendingLinkConfirmation else { return }
        pendingLinkConfirmation = nil
        guard let url = WebLinkPolicy.webURL(pending.url) else { return }
        environment.openURL(url)
    }

    /// Drops the pending link without opening it.
    public func cancelPendingLink() {
        pendingLinkConfirmation = nil
    }

    private func handle(_ result: AppCommandResult, for command: AppCommand) {
        if let command = result.handoffCommand {
            environment.copyToPasteboard(command)
        }
        if let url = result.urlToOpen {
            openLink(url)
        }
        if let preview = result.preview {
            pendingPreview = preview
        }
        if let taskID = result.createdTaskID {
            handoffOffer = HandoffOffer(taskID: taskID)
        }
        if case .approvePreview = command { pendingPreview = nil }
        if case .declinePreview = command { pendingPreview = nil }
        if let message = result.message {
            showBanner(result.tone ?? (result.handoffCommand != nil || result.createdTaskID != nil ? .success : .neutral), message)
        }
    }

    /// Refreshes all accounts.
    public func refresh() async {
        await send(.refresh(account: nil))
    }

    /// Fetches (once) the bounded CI log excerpt of a check.
    public func loadLog(for check: CheckKey) async {
        guard logExcerpts[check.id] == nil, !loadingLogIDs.contains(check.id) else { return }
        loadingLogIDs.insert(check.id)
        defer { loadingLogIDs.remove(check.id) }
        do {
            let result = try await backend.perform(.loadCheckLog(check))
            if let excerpt = result.logExcerpt { logExcerpts[check.id] = excerpt }
        } catch {
            showBanner(.critical, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Seeds a log excerpt by `CheckKey.id` (snapshots render without waiting for the backend).
    public func seedLogExcerpt(_ excerpt: LogExcerpt, checkID: String) {
        logExcerpts[checkID] = excerpt
    }

    /// Copies user-visible text (redacted) and confirms with a banner.
    public func copyToPasteboard(_ text: String, confirmation: String = "Copied to the clipboard") {
        environment.copyToPasteboard(SecretRedactor.redact(text))
        showBanner(.success, confirmation)
    }

    /// Shows a banner and announces it to VoiceOver. Critical banners stay until dismissed; others dismiss
    /// themselves after `Banner.autoDismissDelay(for:)`, with the timer paused while the banner is held.
    public func showBanner(_ tone: Tone, _ message: String) {
        let banner = Banner(tone: tone, message: message)
        banners.append(banner)
        if banners.count > 3 { banners.removeFirst(banners.count - 3) }
        environment.announce(message, tone)
        guard environment.autoDismissBanners, let delay = Banner.autoDismissDelay(for: tone) else { return }
        Task { [weak self] in await self?.autoDismissBanner(banner.id, after: delay) }
    }

    public func dismissBanner(_ id: UUID) {
        banners.removeAll { $0.id == id }
        heldBanners.remove(id)
    }

    // MARK: Lookups

    public func attentionItem(_ id: String?) -> AttentionItem? {
        id.flatMap { indexes.attention[$0] }
    }

    public func task(_ id: TaskID?) -> TaskRecord? {
        id.flatMap { indexes.tasks[$0] }
    }

    public func snapshot(_ key: ChangeRequestKey?) -> ChangeRequestSnapshot? {
        key.flatMap { indexes.snapshots[$0.id] }
    }

    public func snapshot(id: String?) -> ChangeRequestSnapshot? {
        id.flatMap { indexes.snapshots[$0] }
    }

    public func account(_ key: AccountKey?) -> AccountState? {
        key.flatMap { indexes.accounts[$0] }
    }

    /// Non-terminal task linked to an attention item, if any.
    public func activeTask(for item: AttentionItem) -> TaskRecord? {
        if let linked = task(item.linkedTaskID), !linked.task.isTerminal { return linked }
        return state.tasks.first { $0.task.origin.attentionItemID == item.id && !$0.task.isTerminal }
    }

    /// Tasks created from a change request (newest first).
    public func tasks(for changeRequest: ChangeRequestKey) -> [TaskRecord] {
        state.tasks.filter { $0.task.origin.changeRequest == changeRequest }.sorted { $0.task.createdAt > $1.task.createdAt }
    }

    public func mapping(for repo: RepoKey) -> RepoMapping? {
        state.mappings.first { $0.repo == repo }
    }

    /// The agent used for "Open in …" and handoff commands: the one picked by the user, else a verified one first.
    public var preferredAgent: AgentStatus? {
        if let kind = selectedAgentKind, let agent = state.agents.first(where: { $0.kind == kind }) { return agent }
        return state.agents.first { $0.mcpRegistration.isVerified } ?? state.agents.first
    }

    /// The agent kind shown as selected in pickers (even when that agent is not installed).
    public var effectiveAgentKind: AgentKind {
        selectedAgentKind ?? preferredAgent?.kind ?? .claudeCode
    }

    /// First name for the greeting: the Mac user's name, else the first account's display name.
    public var userFirstName: String? {
        Presentation.firstName(environment.userFullName)
            ?? state.accounts.lazy.compactMap { Presentation.firstName($0.account.displayName) }.first
    }

    // MARK: Menu bar

    public var needsYouCount: Int { sections.needsYou.count }

    /// "MergeCue, 3 need you, 1 ready" (+ preview/demo marker).
    public var menuBarAccessibilityLabel: String {
        var parts = ["MergeCue"]
        if let badge = mode.badgeText { parts[0] += " (\(badge.lowercased()))" }
        let needs = sections.count(.needsYou)
        let ready = sections.count(.ready)
        let working = sections.count(.aiWorking)
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        if working > 0 { parts.append("\(working) in progress") }
        if ready > 0 { parts.append("\(ready) ready") }
        if needs == 0 && ready == 0 && working == 0 { parts.append("all caught up") }
        return parts.joined(separator: ", ")
    }

    /// Hover tooltip: counts only.
    public var menuBarToolTip: String {
        PopoverSection.allCases.map { "\($0.title): \(sections.count($0))" }.joined(separator: " · ")
    }

    public var notificationsPaused: Bool { state.notificationsPaused(at: now) }

    // MARK: Popover keyboard navigation

    /// Rows visible in the popover (top 3 per section), in keyboard order.
    public var popoverRows: [PopoverItem] {
        PopoverSection.allCases.filter { !collapsedPopoverSections.contains($0) }.flatMap { sections.items($0).prefix(Self.popoverRowLimit) }
    }

    public static let popoverRowLimit = 3

    public func movePopoverSelection(by delta: Int) {
        let rows = popoverRows
        guard !rows.isEmpty else { popoverSelection = nil; return }
        guard let current = popoverSelection, let index = rows.firstIndex(where: { $0.id == current }) else {
            popoverSelection = (delta >= 0 ? rows.first : rows.last)?.id
            return
        }
        popoverSelection = rows[min(max(index + delta, 0), rows.count - 1)].id
    }

    /// ⌘↩: runs the selected row's primary action (Return and Space open its details, see `openPopoverSelection`).
    public func activatePopoverSelection() async {
        guard let id = popoverSelection, let row = popoverRows.first(where: { $0.id == id }) else { return }
        await perform(row.primaryAction)
    }
}

/// Lookup tables rebuilt with every state change.
struct Indexes: Sendable {
    var attention: [String: AttentionItem] = [:]
    var tasks: [TaskID: TaskRecord] = [:]
    var snapshots: [String: ChangeRequestSnapshot] = [:]
    var accounts: [AccountKey: AccountState] = [:]

    nonisolated init(_ state: AppState) {
        attention = Dictionary(state.attention.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tasks = Dictionary(state.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        snapshots = Dictionary(state.changeRequests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        accounts = Dictionary(state.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
