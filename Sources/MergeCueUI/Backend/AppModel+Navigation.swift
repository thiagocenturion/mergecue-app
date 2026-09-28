import Foundation
import MergeCueCore

extension AppModel {
    // MARK: Primary actions

    /// Runs a row's primary action.
    public func perform(_ action: PrimaryAction) async {
        switch action {
        case .createTask(let attentionID, let type):
            await send(.createTask(attentionID: attentionID, type: type))
        case .openAttention(let attentionID, _):
            showAttention(attentionID)
        case .copyCommand(let taskID):
            await send(.copyHandoffCommand(taskID, agent: preferredAgent?.kind))
        case .openTask(let taskID, _):
            showTask(taskID)
        case .retryTask(let taskID):
            await send(.retryTask(taskID))
        }
    }

    /// Opens the row's detail in the main window (the second click of "reach any item within two clicks").
    public func open(_ item: PopoverItem) {
        switch item.source {
        case .attention(let id): showAttention(id)
        case .task(let id): showTask(id)
        }
    }

    /// "Fix with AI" in the window: creates the task (it starts as Waiting for agent) and opens its handoff screen.
    public func createTaskAndShow(attentionID: String, type: TaskType) async {
        guard let result = await send(.createTask(attentionID: attentionID, type: type)), let taskID = result.createdTaskID else { return }
        if handoffOffer?.taskID == taskID { handoffOffer = nil }
        showTask(taskID)
    }

    // MARK: Navigation

    /// Selects an attention item in the Inbox (relaxing filters that would hide it) and shows the window.
    public func showAttention(_ id: String) {
        screen = .inbox
        selectedAttentionID = id
        let visible = InboxQuery.run(state: state, filter: inboxFilter, now: now, showRead: showReadInInbox).visibleItems
        if !visible.contains(where: { $0.id == id }) {
            inboxFilter = InboxFilter(collapseRead: inboxFilter.collapseRead)
            showReadInInbox = true
        }
        if let item = attentionItem(id), item.isUnread {
            Task { await send(.markRead(attentionID: id, read: true)) }
        }
        openMainWindow()
    }

    public func showTask(_ id: TaskID) {
        screen = .tasks
        selectedTaskID = id
        openMainWindow()
    }

    public func showChangeRequest(_ key: ChangeRequestKey) {
        screen = .changeRequests
        selectedChangeRequestID = key.id
        changeRequestFilter.includeClosed = changeRequestFilter.includeClosed || snapshot(key)?.summary.state != .open
        openMainWindow()
    }

    public func showSettings(_ tab: SettingsTab = .accounts) {
        screen = .settings
        settingsTab = tab
        openMainWindow()
    }

    /// "View all" of a popover section.
    public func showAll(_ section: PopoverSection) {
        switch section {
        case .needsYou:
            screen = .inbox
            inboxFilter.status = .needsAction
            selectedAttentionID = sections.needsYou.first.flatMap { item -> String? in
                if case .attention(let id) = item.source { return id }
                return nil
            }
        case .waitingForAgent, .aiWorking, .ready:
            screen = .tasks
            selectedTaskID = sections.items(section).first.flatMap { item -> TaskID? in
                if case .task(let id) = item.source { return id }
                return nil
            }
        }
        openMainWindow()
    }

    public func showScreen(_ screen: MainScreen) {
        self.screen = screen
        openMainWindow()
    }

    /// Closes the popover and brings the main window forward.
    public func openMainWindow() {
        closePopoverHandler?()
        openMainWindowHandler?()
    }

    // MARK: Rules

    public func editRule(_ rule: Rule) {
        ruleEditor = RuleEditorContext(rule: rule, isNew: false)
    }

    public func newRule(from template: Rule? = nil) {
        let id = IDGenerator.ruleID()
        var rule = template.map { RuleTemplates.instantiate($0, id: id, now: now) }
            ?? Rule(id: id, name: "New rule", origin: .user, action: .notify, createdAt: now)
        rule.origin = template == nil ? .user : .template
        rule.isActive = false
        ruleEditor = RuleEditorContext(rule: rule, isNew: true)
    }

    // MARK: Helpers for views

    /// "Preview data" / "Demo data" label, nil when live.
    public var modeBadge: String? { mode.badgeText }

    /// Rules that an agent proposed and that wait for the user's activation.
    public var pendingRuleProposals: [Rule] {
        state.rules.filter { $0.origin == .agentProposal && !$0.isActive }
    }

    /// Accounts with a sync problem (offline, auth expired, rate limited, …).
    public var accountsWithProblems: [AccountState] {
        state.accounts.filter { $0.status.state.isProblem }
    }

    /// Short, user-facing account name: "GitHub · mona-dev".
    public func accountTitle(_ key: AccountKey) -> String {
        guard let account = account(key) else { return key.kind.displayName }
        return "\(account.kind.displayName) · \(account.account.displayLabel)"
    }

    /// The repositories known from change requests, one per provider-qualified `RepoKey`.
    public var knownRepositories: [Repository] {
        var seen = Set<RepoKey>()
        return state.changeRequests.map(\.summary.repository)
            .filter { seen.insert($0.key).inserted }
            .sorted { ($0.providerKind.rawValue, $0.fullPath) < ($1.providerKind.rawValue, $1.fullPath) }
    }
}
