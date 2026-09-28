import Foundation
import MergeCueCore

/// Moving a selection through an ordered list with the arrow keys.
public nonisolated enum KeyboardSelection {
    /// The id `delta` rows away from `current`, clamped to the list. With no (or an unknown) current id, a move down
    /// selects the first row and a move up the last. Nil for an empty list.
    public static func step<ID: Equatable>(_ ids: [ID], from current: ID?, by delta: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta >= 0 ? ids.first : ids.last
        }
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }
}

/// Keyboard handling of the popover and the window's lists (arrow keys move, Return/Space open, ⌘↩ runs the
/// primary action), banner timing, and the window title.
extension AppModel {
    // MARK: Popover

    /// The popover is about to show: forget the old selection and reset focus. A popover opened from the keyboard
    /// (global shortcut) selects its first row so ↑/↓/Return work immediately.
    public func popoverWillShow(fromKeyboard: Bool) {
        popoverPresentationCount += 1
        popoverSelection = nil
        if fromKeyboard { movePopoverSelection(by: 1) }
    }

    /// Return / Space: opens the selected row's details in the main window (same as clicking the row).
    public func openPopoverSelection() {
        guard let id = popoverSelection, let row = popoverRows.first(where: { $0.id == id }) else { return }
        open(row)
    }

    // MARK: Inbox

    /// Inbox items in the order the list shows them (day groups, current filters).
    public var inboxKeyboardOrder: [String] {
        let result = InboxQuery.run(state: state, filter: inboxFilter, now: now, showRead: showReadInInbox)
        return InboxDayGroup.make(result.visibleItems, now: now).flatMap { $0.items.map(\.id) }
    }

    public func moveInboxSelection(by delta: Int) {
        guard let next = KeyboardSelection.step(inboxKeyboardOrder, from: selectedAttentionID, by: delta) else { return }
        if next != selectedAttentionID { changeRequestTab = .conversation }
        selectedAttentionID = next
    }

    /// Return / Space on an inbox row (same as clicking it): shows its conversation and marks it read.
    public func openInboxItem(_ id: String) {
        selectedAttentionID = id
        changeRequestTab = .conversation
        if let item = attentionItem(id), item.isUnread {
            Task { await send(.markRead(attentionID: id, read: true)) }
        }
    }

    public func openInboxSelection() {
        if let id = selectedAttentionID { openInboxItem(id) }
    }

    /// ⌘↩: the selected item's primary action — its active task, else "Fix with AI" (or the item's other task type).
    public func performInboxPrimaryAction() async {
        guard let item = attentionItem(selectedAttentionID) else { return }
        if let task = activeTask(for: item) {
            showTask(task.id)
            return
        }
        switch PopoverDerivation.primaryAction(for: item) {
        case .createTask(let id, let type): await createTaskAndShow(attentionID: id, type: type)
        default: openInboxItem(item.id)
        }
    }

    // MARK: Pull requests

    /// Change request ids in list order (account sections, current filters).
    public var changeRequestKeyboardOrder: [String] {
        ChangeRequestQueryUI.run(state: state, filter: changeRequestFilter).flatMap { $0.items.map(\.id) }
    }

    public func moveChangeRequestSelection(by delta: Int) {
        guard let next = KeyboardSelection.step(changeRequestKeyboardOrder, from: selectedChangeRequestID, by: delta) else { return }
        if next != selectedChangeRequestID { changeRequestTab = .conversation }
        selectedChangeRequestID = next
    }

    /// Return / Space on a PR/MR row: shows its conversation.
    public func openChangeRequest(_ id: String) {
        selectedChangeRequestID = id
        changeRequestTab = .conversation
    }

    /// ⌘↩ on a PR/MR row: opens its most recent attention item in the Inbox (where its AI actions are).
    public func performChangeRequestPrimaryAction() {
        guard let id = selectedChangeRequestID,
              let item = state.attention.filter({ $0.changeRequest.id == id }).max(by: { $0.updatedAt < $1.updatedAt }) else { return }
        showAttention(item.id)
    }

    // MARK: Rules

    /// Rules grouped like the Rules list: agent proposals waiting for activation, the user's rules, templates.
    public var ruleSections: (proposals: [Rule], mine: [Rule], templates: [Rule]) {
        let templateIDs = Set(RuleTemplates.all.map(\.id))
        let proposals = pendingRuleProposals
        let mine = state.rules.filter { !templateIDs.contains($0.id) && !($0.origin == .agentProposal && !$0.isActive) }
        let templates = state.rules.filter { templateIDs.contains($0.id) }
        return (proposals, mine, templates)
    }

    public var ruleKeyboardOrder: [String] {
        let sections = ruleSections
        return (sections.proposals + sections.mine + sections.templates).map(\.id)
    }

    public func moveRuleSelection(by delta: Int) {
        if let next = KeyboardSelection.step(ruleKeyboardOrder, from: selectedRuleID, by: delta) { selectedRuleID = next }
    }

    /// ⌘↩ on a rule: opens the editor (Edit… for your rules, Use as Template… for templates).
    public func performRulePrimaryAction() {
        guard let id = selectedRuleID, let rule = state.rules.first(where: { $0.id == id }) else { return }
        if RuleTemplates.template(id: rule.id) != nil { newRule(from: rule) } else { editRule(rule) }
    }

    // MARK: Banners

    /// Pauses (or resumes) a banner's auto-dismiss timer while the pointer is over it or focus is inside it.
    public func setBannerHeld(_ id: UUID, _ held: Bool) {
        if held { heldBanners.insert(id) } else { heldBanners.remove(id) }
    }

    /// Whether a banner's timer is paused.
    public func isBannerHeld(_ id: UUID) -> Bool { heldBanners.contains(id) }

    func autoDismissBanner(_ id: UUID, after delay: Duration) async {
        let step: Duration = .milliseconds(250)
        var remaining = delay
        while remaining > .zero {
            try? await Task.sleep(for: step)
            guard banners.contains(where: { $0.id == id }) else { return }
            if !heldBanners.contains(id) { remaining -= step }
        }
        dismissBanner(id)
    }

    // MARK: Notifications permission

    /// Reads the app's notification permission from macOS (Settings › Notifications, after asking).
    public func refreshNotificationPermission() async {
        guard let read = environment.notificationPermission else {
            notificationPermission = .unavailable
            return
        }
        notificationPermission = await read()
    }

    /// Opens System Settings › Notifications › MergeCue (installed app only).
    public var canOpenNotificationSettings: Bool { environment.openNotificationSettings != nil }

    public func openNotificationSettings() {
        environment.openNotificationSettings?()
    }

    // MARK: Window title

    /// Title and subtitle of the main window for the current screen (read by VoiceOver, Mission Control and the
    /// Window menu; the title bar itself is transparent).
    public var windowTitle: (title: String, subtitle: String) {
        let subtitle = ["MergeCue", mode.badgeText].compactMap(\.self).joined(separator: " · ")
        let title: String
        switch screen {
        case .inbox:
            if let item = attentionItem(selectedAttentionID) {
                title = "Inbox — \(item.repoFullPath) \(item.providerKind.formattedNumber(item.number))"
            } else {
                title = "Inbox"
            }
        case .changeRequests:
            if let snapshot = snapshot(id: selectedChangeRequestID) {
                title = "\(MainScreen.changeRequests.title) — \(snapshot.summary.repository.fullPath) \(snapshot.summary.providerKind.formattedNumber(snapshot.summary.key.number))"
            } else {
                title = MainScreen.changeRequests.title
            }
        case .tasks:
            if let record = task(selectedTaskID) {
                title = "Task \(record.id.rawValue) — \(TaskStateStyle.label(record))"
            } else {
                title = "Tasks"
            }
        case .rules:
            if let id = selectedRuleID, let rule = state.rules.first(where: { $0.id == id }) {
                title = "Rules — \(rule.name)"
            } else {
                title = "Rules"
            }
        case .settings:
            title = "Settings — \(settingsTab.title)"
        }
        return (title, subtitle)
    }
}

extension Banner {
    /// How long a banner stays before dismissing itself; nil for critical banners, which stay until dismissed.
    public static func autoDismissDelay(for tone: Tone) -> Duration? {
        switch tone {
        case .critical: nil
        case .attention: .seconds(8)
        case .neutral, .progress, .success: .seconds(5)
        }
    }
}
