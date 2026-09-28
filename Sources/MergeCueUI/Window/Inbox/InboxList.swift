import MergeCueCore
import SwiftUI

/// Inbox: the unified GitHub / GitLab / Bitbucket list (greeting, search, filters, summary cards, day groups) and
/// the change request panel of the selected item.
struct InboxScreen: View {
    let model: AppModel

    var body: some View {
        GeometryReader { proxy in
            let detailWidth = min(620, max(440, proxy.size.width * 0.47))
            HStack(spacing: 0) {
                InboxColumn(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                InboxDetail(model: model)
                    .frame(width: detailWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Theme.contentBackground)
    }
}

/// The middle column.
struct InboxColumn: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var headerWidth: CGFloat = 600
    @Environment(\.textScale) private var textScale

    var body: some View {
        let result = InboxQuery.run(state: model.state, filter: model.inboxFilter, now: model.now, showRead: model.showReadInInbox)
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: 10) {
                FilterChips(options: [(InboxScope.all, "All"), (.mine, "Mine"), (.reviewing, "Reviewing")], selection: $model.inboxFilter.scope)
                Spacer(minLength: 8)
                InboxFilterMenu(model: model)
            }
            .padding(.top, 22)
            InboxSummaryCards(model: model)
                .padding(.top, 18)
            if result.groups.isEmpty {
                emptyState(result)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(InboxDayGroup.make(result.visibleItems, now: model.now)) { group in
                                Text(group.title)
                                    .scaledFont(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.top, 10)
                                    .padding(.leading, 2)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.items) { item in
                                    InboxItemCard(model: model, item: item, isSelected: model.selectedAttentionID == item.id,
                                                  showsKeyboardFocus: listFocused) { listFocused = true }
                                        .id(item.id)
                                }
                            }
                            readToggle(result)
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                        .padding(.horizontal, 4)
                    }
                    .scrollIndicators(.automatic)
                    .keyboardList(isFocused: $listFocused, hasSelection: model.selectedAttentionID != nil,
                                  onMove: { model.moveInboxSelection(by: $0) },
                                  onOpen: { model.openInboxSelection() },
                                  onPrimary: { Task { await model.performInboxPrimaryAction() } })
                    .onChange(of: model.selectedAttentionID) { _, id in
                        guard listFocused, let id else { return }
                        proxy.scrollTo(id)
                    }
                    .accessibilityLabel("Inbox items")
                    .accessibilityHint("Use the up and down arrow keys to move, Return to open, Command-Return for the primary action")
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, MainWindowMetrics.contentTopInset)
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// Greeting and search side by side; stacked when the column is narrow or the text is large.
    private var header: some View {
        Group {
            if headerWidth >= 480 * textScale {
                HStack(alignment: .top, spacing: 16) {
                    greeting(lineLimit: 1)
                    Spacer(minLength: 12)
                    search.frame(width: 200).padding(.top, 2)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    greeting(lineLimit: 2)
                    search.frame(maxWidth: 360)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
    }

    private func greeting(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Presentation.greeting(now: model.now, firstName: model.userFirstName))
                .scaledFont(Theme.largeTitle)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(lineLimit)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Text(Presentation.attentionSubtitle(count: model.sections.count(.needsYou)))
                .scaledFont(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var search: some View {
        SearchField(text: $model.inboxFilter.searchText, prompt: "Search", showsShortcut: true, focus: $searchFocused)
            .help("Search title, repository, #42 (⌘K)")
    }

    @ViewBuilder
    private func readToggle(_ result: InboxResult) -> some View {
        if result.hiddenReadCount > 0 {
            Button {
                model.showReadInInbox = true
            } label: {
                Label("Show \(result.hiddenReadCount) read item\(result.hiddenReadCount == 1 ? "" : "s")", systemImage: "chevron.down.circle")
                    .scaledFont(.system(size: 13))
                    .foregroundStyle(Theme.accentText)
            }
            .buttonStyle(PlainRowButtonStyle())
            .padding(.top, 6)
        } else if model.showReadInInbox && model.inboxFilter.collapseRead {
            Button {
                model.showReadInInbox = false
            } label: {
                Label("Collapse read items", systemImage: "chevron.up.circle")
                    .scaledFont(.system(size: 13))
                    .foregroundStyle(Theme.accentText)
            }
            .buttonStyle(PlainRowButtonStyle())
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func emptyState(_ result: InboxResult) -> some View {
        if model.state.accounts.isEmpty {
            VStack(spacing: 12) {
                NothingSelected(title: "No accounts", symbol: "person.crop.circle.badge.plus",
                                message: "Connect GitHub, GitLab or Bitbucket Cloud to see what needs you across all of them.")
                Button("Connect an Account…") { model.showSettings(.accounts) }
                    .buttonStyle(GradientButtonStyle())
            }
        } else if model.inboxFilter.isNarrowed {
            VStack(spacing: 12) {
                NothingSelected(title: "No matching items", symbol: "line.3.horizontal.decrease.circle", message: "Nothing matches these filters.")
                Button("Clear Filters") { model.inboxFilter = InboxFilter(collapseRead: model.inboxFilter.collapseRead) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        } else if result.hiddenReadCount > 0 {
            VStack(spacing: 12) {
                NothingSelected(title: "No new activity", symbol: "checkmark.circle",
                                message: "You're all caught up. \(result.hiddenReadCount) read item\(result.hiddenReadCount == 1 ? " is" : "s are") collapsed.")
                Button("Show Read Items") { model.showReadInInbox = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
        } else {
            NothingSelected(title: "No new activity", symbol: "checkmark.circle", message: "You're all caught up.")
        }
    }
}

/// Items grouped by day: "Today", "Yesterday", "Earlier".
struct InboxDayGroup: Identifiable {
    var title: String
    var items: [AttentionItem]
    var id: String { title }

    static func make(_ items: [AttentionItem], now: Date, calendar: Calendar = .current) -> [InboxDayGroup] {
        let sorted = items.sorted { lhs, rhs in
            let lhsActive = lhs.isUnread || lhs.isActionable(now: now)
            let rhsActive = rhs.isUnread || rhs.isActionable(now: now)
            if lhsActive != rhsActive { return lhsActive }
            return lhs.updatedAt > rhs.updatedAt
        }
        var today: [AttentionItem] = [], yesterday: [AttentionItem] = [], earlier: [AttentionItem] = []
        for item in sorted {
            if calendar.isDate(item.updatedAt, inSameDayAs: now) { today.append(item) }
            else if calendar.isDateInYesterday(item.updatedAt) || calendar.isDate(item.updatedAt, inSameDayAs: now.addingTimeInterval(-86_400)) {
                yesterday.append(item)
            } else { earlier.append(item) }
        }
        return [("Today", today), ("Yesterday", yesterday), ("Earlier", earlier)]
            .filter { !$0.1.isEmpty }
            .map { InboxDayGroup(title: $0.0, items: $0.1) }
    }
}

/// Provider, account, repository and status filters plus "Hide read", behind one control.
struct InboxFilterMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        let filter = model.inboxFilter
        let active = filter.provider != nil || filter.account != nil || filter.repo != nil || filter.status != .all
        Menu {
            Picker("Provider", selection: $model.inboxFilter.provider) {
                Text("Any Provider").tag(ProviderKind?.none)
                ForEach(ProviderKind.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
            }
            Picker("Account", selection: $model.inboxFilter.account) {
                Text("Any Account").tag(AccountKey?.none)
                ForEach(model.state.accounts) { account in
                    Text(model.accountTitle(account.id)).tag(Optional(account.id))
                }
            }
            Picker("Repository", selection: $model.inboxFilter.repo) {
                Text("Any Repository").tag(RepoKey?.none)
                ForEach(model.knownRepositories, id: \.key) { repo in
                    Text("\(repo.fullPath) · \(repo.providerKind.displayName)").tag(Optional(repo.key))
                }
            }
            Picker("Status", selection: $model.inboxFilter.status) {
                ForEach(InboxStatusFilter.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Toggle("Hide Read Items", isOn: $model.inboxFilter.collapseRead)
            if active {
                Divider()
                Button("Clear Filters") {
                    model.inboxFilter = InboxFilter(scope: filter.scope, searchText: filter.searchText, collapseRead: filter.collapseRead)
                }
            }
        } label: {
            Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .scaledFont(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.surfaceRaised))
                .overlay(Circle().strokeBorder(active ? Theme.accent : Theme.controlBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by provider, account, repository or status")
        .accessibilityLabel(active ? "Filters, active" : "Filters")
    }
}

/// Needs you / AI working / Ready counters.
struct InboxSummaryCards: View {
    let model: AppModel
    @Environment(\.textScale) private var textScale

    var body: some View {
        // The icon circles drop out when the column is too narrow (small window or large text).
        ViewThatFits(in: .horizontal) {
            cards(showsIcons: true)
            cards(showsIcons: false)
        }
    }

    private func cards(showsIcons: Bool) -> some View {
        HStack(spacing: 14) {
            card(.needsYou, title: "Needs you", symbol: "exclamationmark", showsIcon: showsIcons) {
                model.inboxFilter.status = .needsAction
            }
            card(.aiWorking, title: "AI working", symbol: "sparkles", showsIcon: showsIcons) { model.showAll(.aiWorking) }
            card(.ready, title: "Ready", symbol: "checkmark", showsIcon: showsIcons) { model.showAll(.ready) }
        }
    }

    private func card(_ section: PopoverSection, title: String, symbol: String, showsIcon: Bool, action: @escaping () -> Void) -> some View {
        let count = model.sections.count(section)
        let color = section == .aiWorking ? Theme.violet : Theme.color(section)
        return Button(action: action) {
            HStack(spacing: 14) {
                if showsIcon {
                    Image(systemName: symbol)
                        .scaledFont(.system(size: 17, weight: .bold))
                        .foregroundStyle(section == .aiWorking ? AnyShapeStyle(LinearGradient(colors: [Theme.violet, Theme.cyan], startPoint: .bottomLeading, endPoint: .topTrailing)) : AnyShapeStyle(color))
                        .frame(width: 44 * textScale, height: 44 * textScale)
                        .background(Circle().fill(color.opacity(0.16)))
                        .overlay(Circle().strokeBorder(color.opacity(0.4), lineWidth: 1))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .scaledFont(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(count)")
                        .scaledFont(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 78)
            .frame(maxWidth: .infinity)
            .cardBackground()
        }
        .buttonStyle(PlainRowButtonStyle(cornerRadius: Theme.cardRadius))
        .accessibilityLabel("\(title): \(count)")
        .accessibilityHint(section == .needsYou ? "Shows only items that need action" : "Shows these tasks")
    }
}

extension Theme {
    /// Text colour for an attention reason (status pills).
    static func reasonTextColor(_ reason: AttentionReason) -> Color {
        switch reason {
        case .changesRequested, .ciFailed: needsText
        case .reviewerQuestion, .codeSuggestion: violetText
        case .reviewComment, .reply: accentText
        case .reviewRequested: cyanText
        case .readyToMerge: mintText
        case .mergeConflict: waitingText
        }
    }

    /// Shape cue for an attention reason (Differentiate Without Color).
    static func reasonSymbol(_ reason: AttentionReason) -> String {
        switch reason {
        case .changesRequested, .ciFailed: "exclamationmark.circle.fill"
        case .reviewerQuestion, .codeSuggestion: "questionmark.circle.fill"
        case .reviewComment, .reply: "bubble.left.fill"
        case .reviewRequested: "eye.fill"
        case .readyToMerge: "checkmark.circle.fill"
        case .mergeConflict: "exclamationmark.triangle.fill"
        }
    }

    /// Colour of an attention reason's status glyph.
    static func reasonColor(_ reason: AttentionReason) -> Color {
        switch reason {
        case .changesRequested, .ciFailed: needs
        case .reviewerQuestion, .codeSuggestion: violet
        case .reviewComment, .reply: accent
        case .reviewRequested: cyan
        case .readyToMerge: mint
        case .mergeConflict: waiting
        }
    }
}

/// One inbox card: provider badge, "GitHub • acme/payments-api #42", age, status glyph + headline, subtitle,
/// comment count and one action (gradient on the selected card).
struct InboxItemCard: View {
    let model: AppModel
    let item: AttentionItem
    let isSelected: Bool
    /// The list has keyboard focus: the selected card draws the focus indicator.
    var showsKeyboardFocus = false
    /// Called when the card is clicked (the list takes keyboard focus).
    var onSelect: () -> Void = {}
    @State private var isHovering = false

    /// Unread or actionable items are set in a heavier weight (read, settled items used to be dimmed to 72 %).
    private var isActive: Bool { item.isActionable(now: model.now) || item.isUnread }

    var body: some View {
        let snapshot = model.snapshot(item.changeRequest)
        let text = Presentation.attentionText(item, snapshot: snapshot)
        HStack(alignment: .top, spacing: 16) {
            ProviderBadge(kind: item.providerKind, size: 42, style: .circle)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if item.isUnread {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    Text("\(item.providerKind.shortName)  •  \(item.repoFullPath)  \(item.providerKind.formattedNumber(item.number))")
                        .scaledFont(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(UIFormat.relative(from: item.updatedAt, now: model.now))
                        .scaledFont(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .help(UIFormat.dateTime(item.updatedAt))
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 9) {
                            StatusGlyph(symbol: text.symbol, color: Theme.reasonColor(item.reason), size: 20)
                            Text(text.headline)
                                .scaledFont(.system(size: 15.5, weight: isActive ? .semibold : .regular))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                        }
                        Text(text.subtitle)
                            .scaledFont(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 29)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    actionButton
                }
                .padding(.top, 10)
                HStack(spacing: 10) {
                    Label("\(text.commentCount)", systemImage: "bubble.left")
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("\(text.commentCount) comments")
                    if let task = model.activeTask(for: item) {
                        TaskStateChip(record: task)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(isSelected ? Theme.surfaceSelected : (isHovering ? Theme.surfaceHover : Theme.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.75) : Theme.border, lineWidth: isSelected ? 1.3 : 1)
        )
        .keyboardSelectionRing(isSelected && showsKeyboardFocus, cornerRadius: Theme.cardRadius)
        .shadow(color: isSelected ? Theme.accent.opacity(0.18) : .clear, radius: 12)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture {
            select()
            onSelect()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.isUnread ? "Unread. " : "")\(text.headline). \(text.subtitle). \(item.providerKind.displayName) \(item.repoFullPath) \(item.providerKind.formattedNumber(item.number)). \(UIFormat.spokenAge(from: item.updatedAt, now: model.now))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction { select() }
        .accessibilityAction(named: "Show details") { select() }
        .accessibilityAction(named: primaryActionName) { Task { await performPrimary() } }
    }

    private func select() {
        model.openInboxItem(item.id)
    }

    private var primaryActionName: String {
        if model.activeTask(for: item) != nil { return "View task" }
        return PopoverDerivation.primaryAction(for: item).title
    }

    private func performPrimary() async {
        model.selectedAttentionID = item.id
        await model.performInboxPrimaryAction()
    }

    @ViewBuilder
    private var actionButton: some View {
        if let task = model.activeTask(for: item) {
            Button("View task") { model.showTask(task.id) }
                .buttonStyle(SecondaryButtonStyle(size: .regular))
                .fixedSize()
                .accessibilityLabel("View task \(task.id.rawValue), \(item.repoFullPath) \(item.providerKind.formattedNumber(item.number))")
        } else {
            let action = PopoverDerivation.primaryAction(for: item)
            let title = Presentation.compactTitle(action)
            let button = Button {
                if case .createTask(let id, let type) = action {
                    Task { await model.createTaskAndShow(attentionID: id, type: type) }
                } else {
                    select()
                }
            } label: {
                HStack(spacing: 7) {
                    if case .createTask = action, isSelected { SparkleIcon(size: 13) }
                    Text(title)
                }
            }
            .fixedSize()
            .accessibilityLabel("\(action.title), \(item.repoFullPath) \(item.providerKind.formattedNumber(item.number))")
            if isSelected, case .createTask = action {
                button.buttonStyle(GradientButtonStyle(size: .regular))
            } else {
                button.buttonStyle(SecondaryButtonStyle(size: .regular))
            }
        }
    }
}

/// "mc_q8w2e5 · Waiting for agent" chip.
struct TaskStateChip: View {
    let record: TaskRecord

    var body: some View {
        let color = TaskStateStyle.color(record)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(TaskStateStyle.label(record)) · \(record.id.rawValue)")
                .lineLimit(1)
        }
        .scaledFont(.system(size: 11.5, weight: .medium))
        .foregroundStyle(TaskStateStyle.textColor(record))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}

/// Colour and label of a task state, honest about claims (only a real claim reads "AI working").
enum TaskStateStyle {
    static func color(_ record: TaskRecord) -> Color {
        switch record.task.state {
        case .waitingForAgent: Theme.waiting
        case .working: record.hasRealClaim ? Theme.violet : Theme.waiting
        case .readyForReview, .done: Theme.mint
        case .blocked, .stale: Theme.waiting
        case .failed: Theme.critical
        case .approvedAction: Theme.cyan
        case .cancelled, .dismissed: Theme.textTertiary
        }
    }

    /// Text in the state's colour (≥ 4.5:1 on surfaces and tints).
    static func textColor(_ record: TaskRecord) -> Color {
        switch record.task.state {
        case .waitingForAgent: Theme.waitingText
        case .working: record.hasRealClaim ? Theme.violetText : Theme.waitingText
        case .readyForReview, .done: Theme.mintText
        case .blocked, .stale: Theme.waitingText
        case .failed: Theme.criticalText
        case .approvedAction: Theme.cyanText
        case .cancelled, .dismissed: Theme.textSecondary
        }
    }

    /// Shape cue for the state (Differentiate Without Color).
    static func symbol(_ record: TaskRecord) -> String {
        switch record.task.state {
        case .waitingForAgent: "clock.fill"
        case .working: record.hasRealClaim ? "sparkles" : "clock.fill"
        case .readyForReview, .done: "checkmark.circle.fill"
        case .blocked, .stale: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .approvedAction: "checkmark.seal.fill"
        case .cancelled, .dismissed: "minus.circle.fill"
        }
    }

    static func label(_ record: TaskRecord) -> String {
        switch record.task.state {
        case .working: record.hasRealClaim ? "AI working" : "Waiting for agent"
        case .readyForReview: "Ready"
        default: record.task.state.displayName
        }
    }
}
