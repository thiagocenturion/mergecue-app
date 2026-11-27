import MergeCueCore
import SwiftUI

/// Inbox: the unified GitHub / GitLab / Bitbucket list (greeting, search, filters, summary cards, day groups) and
/// the change request panel of the selected item.
struct InboxScreen: View {
    let model: AppModel
    /// The detail width while the split line is being dragged (saved when the drag ends).
    @State private var dragWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            // The inbox column keeps 500 pt, the detail 400 pt; the owner's dragged width wins over the default (D49).
            let range = CGFloat(400)...max(400, proxy.size.width - 500)
            let preferred = dragWidth ?? model.splitWidth("inbox") ?? min(620, max(440, proxy.size.width * 0.47))
            let detailWidth = min(max(preferred, range.lowerBound), range.upperBound)
            HStack(spacing: 0) {
                InboxColumn(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SplitDivider(
                    width: Binding(get: { detailWidth }, set: { dragWidth = $0 }), range: range, controlsLeadingPane: false,
                    onReset: { model.setSplitWidth("inbox", nil) },
                    onCommit: {
                        if let dragWidth { model.setSplitWidth("inbox", dragWidth) }
                        dragWidth = nil
                    }
                )
                Group {
                    if model.inboxFilter.scope == .reviewing { ChangeRequestDetail(model: model) } else { InboxDetail(model: model) }
                }
                    .frame(width: detailWidth)
                    .frame(maxHeight: .infinity)
            }
        }
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
                FilterChips(options: [(InboxScope.all, "All"), (.mine, "Mine"), (.reviewing, "Reviews")], selection: $model.inboxFilter.scope)
                Spacer(minLength: 8)
                InboxFilterMenu(model: model)
            }
            .padding(.top, 22)
            InboxSummaryCards(model: model)
                .padding(.top, 18)
            // New approvals on your pull/merge requests (D47); not under the Reviews filter (others' PRs, D56).
            if model.inboxFilter.scope != .reviewing {
                ApprovalHighlights(model: model)
                    .padding(.top, 14)
            }
            if model.isLoaded, model.inboxFilter.scope == .reviewing {
                reviewLanes
            } else if !model.isLoaded {
                // First load: shimmering placeholders instead of an empty column.
                VStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { index in SkeletonCard(lines: index == 0 ? 3 : 2).appearStaggered(index) }
                    Spacer(minLength: 0)
                }
                .padding(.top, 16)
                .frame(maxHeight: .infinity)
            } else if result.groups.isEmpty {
                emptyState(result)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            // One collapsible group per pull/merge request (D46), expanded by default.
                            ForEach(Array(result.prGroups(now: model.now).enumerated()), id: \.element.id) { index, group in
                                InboxPRGroupView(model: model, group: group, listFocused: $listFocused)
                                    .transition(Motion.listTransition)
                                    .appearStaggered(index)
                            }
                            readToggle(result)
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                        .padding(.horizontal, 4)
                    }
                    .scrollIndicators(.automatic)
                    .shadowRoom()
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

    /// The Reviews filter's list (D56): To review / Changes requested / Approved, the rows of the Reviews screen.
    private var reviewLanes: some View {
        let queue = model.inboxReviewQueue
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ReviewTrackingPrompt(model: model)
                    if queue.isEmpty {
                        NothingSelected(title: "Nothing to review", symbol: "checkmark.bubble",
                                        message: "Pull and merge requests that request your review, or that you commented on or approved, appear here.")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else {
                        ReviewLanes(model: model, queue: queue, listFocused: $listFocused)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.automatic)
            .shadowRoom()
            .keyboardList(isFocused: $listFocused, hasSelection: model.selectedChangeRequestID != nil,
                          onMove: { model.moveReviewSelection(by: $0, in: queue) },
                          onOpen: { if let id = model.selectedChangeRequestID { model.openChangeRequest(id) } },
                          onPrimary: { model.performChangeRequestPrimaryAction() })
            .onChange(of: model.selectedChangeRequestID) { _, id in
                guard listFocused, let id else { return }
                proxy.scrollTo(id)
            }
            .accessibilityLabel("Pull and merge requests you review")
        }
        .padding(.top, 8)
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
                Label("Show \(result.hiddenReadCount) cleared item\(result.hiddenReadCount == 1 ? "" : "s")", systemImage: "chevron.down.circle")
                    .scaledFont(.system(size: 13))
                    .foregroundStyle(Theme.accentText)
            }
            .buttonStyle(PlainRowButtonStyle())
            .padding(.top, 6)
        } else if model.showReadInInbox && model.inboxFilter.collapseRead {
            Button {
                model.showReadInInbox = false
            } label: {
                Label("Collapse cleared items", systemImage: "chevron.up.circle")
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
                                message: "You're all caught up. \(result.hiddenReadCount) cleared item\(result.hiddenReadCount == 1 ? " is" : "s are") collapsed.")
                Button("Show Cleared Items") { model.showReadInInbox = true }
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
            let lhsActive = lhs.isActionable(now: now)
            let rhsActive = rhs.isActionable(now: now)
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

/// Provider, account, repository and status filters plus "Hide cleared", behind one control.
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
            Toggle("Hide Cleared Items", isOn: $model.inboxFilter.collapseRead)
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
                .glassShape(Circle(), tint: active ? Theme.accent : nil)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by provider, account, repository or status")
        .accessibilityLabel(active ? "Filters, active" : "Filters")
    }
}

/// Needs you / In progress / Ready counters.
struct InboxSummaryCards: View {
    let model: AppModel
    @Environment(\.textScale) private var textScale
    @Environment(\.glassEffectsEnabled) private var glassEnabled

    var body: some View {
        // The icons always show (owner preference); narrow columns get smaller icons, then shrinking labels.
        ViewThatFits(in: .horizontal) {
            cards(iconSize: 44, flexibleText: false)
            cards(iconSize: 34, flexibleText: false)
            cards(iconSize: 30, flexibleText: true)
        }
    }

    @ViewBuilder
    private func cards(iconSize: CGFloat, flexibleText: Bool) -> some View {
        HStack(spacing: flexibleText ? 10 : 14) {
            if model.inboxFilter.scope == .reviewing {
                // Reviews filter (D56): the review lanes; a card opens its lane.
                let queue = model.inboxReviewQueue
                ForEach(ReviewQueue.lanes, id: \.self) { lane in
                    card(title: Self.cardTitle(lane), spokenTitle: lane.title, symbol: Self.symbol(lane), count: queue.entries(lane).count,
                         color: Self.color(lane), iconSize: iconSize, flexibleText: flexibleText, hint: "Shows this group") {
                        withAnimation(Motion.smooth) { model.collapsedReviewLanes.remove(lane) }
                        model.selectedChangeRequestID = queue.entries(lane).first?.id ?? model.selectedChangeRequestID
                    }
                }
            } else {
                card(.needsYou, title: "Needs you", symbol: "exclamationmark", iconSize: iconSize, flexibleText: flexibleText) {
                    model.inboxFilter.status = .needsAction
                }
                card(.inProgress, title: "In progress", symbol: "progress.indicator", iconSize: iconSize, flexibleText: flexibleText) { model.showAll(.inProgress) }
                card(.ready, title: "Ready", symbol: "checkmark", iconSize: iconSize, flexibleText: flexibleText) { model.showAll(.ready) }
            }
        }
    }

    /// Short enough for a third of the Inbox column; the lane header below spells it out.
    static func cardTitle(_ lane: ReviewLane) -> String {
        switch lane {
        case .toReview: "To review"
        case .changesRequested: "Changes"
        case .approved, .closed: "Approved"
        }
    }

    static func symbol(_ lane: ReviewLane) -> String {
        switch lane {
        case .toReview: "eye"
        case .changesRequested: "exclamationmark.bubble"
        case .approved, .closed: "checkmark.seal"
        }
    }

    static func color(_ lane: ReviewLane) -> Color {
        switch lane {
        case .toReview: Theme.color(.needsYou)
        case .changesRequested: Theme.violet
        case .approved, .closed: Theme.color(.ready)
        }
    }

    /// Calculus's glass card with the tile's tighter padding (fallback where glass is off).
    private var tileStyle: any CardViewStyle {
        if #available(macOS 26.0, *), glassEnabled { return LiquidGlassCardViewStyle(padding: 14) }
        return FlatCardViewStyle(padding: 14)
    }

    private func card(_ section: PopoverSection, title: String, symbol: String, iconSize: CGFloat, flexibleText: Bool,
                      action: @escaping () -> Void) -> some View {
        card(title: title, symbol: symbol, count: model.sections.count(section),
             color: section == .inProgress ? Theme.violet : Theme.color(section), isProgress: section == .inProgress,
             iconSize: iconSize, flexibleText: flexibleText,
             hint: section == .needsYou ? "Shows only items that need action" : "Shows these tasks", action: action)
    }

    private func card(title: String, spokenTitle: String? = nil, symbol: String, count: Int, color: Color, isProgress: Bool = false, iconSize: CGFloat,
                      flexibleText: Bool, hint: String, action: @escaping () -> Void) -> some View {
        CardView(style: tileStyle, action: action) {
            HStack(spacing: iconSize >= 44 ? 14 : 10) {
                Image(systemName: symbol)
                    .scaledFont(.system(size: iconSize * 0.39, weight: .bold))
                    .foregroundStyle(isProgress ? AnyShapeStyle(LinearGradient(colors: [Theme.violet, Theme.cyan], startPoint: .bottomLeading, endPoint: .topTrailing)) : AnyShapeStyle(color))
                    .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: isProgress && count > 0)
                    .symbolEffect(.bounce, value: count)
                    .frame(width: iconSize * textScale, height: iconSize * textScale)
                    .background(Circle().fill(color.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .scaledFont(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(count)")
                        .scaledFont(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText(value: Double(count)))
                        .animation(Motion.snappy, value: count)
                }
                .fixedSize(horizontal: !flexibleText, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 58)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("\(spokenTitle ?? title): \(count)")
        .accessibilityHint(hint)
    }
}

extension Theme {
    /// Text colour for an attention reason (status pills).
    static func reasonTextColor(_ reason: AttentionReason) -> Color {
        switch reason {
        case .changesRequested, .ciFailed: needsText
        case .reviewerQuestion, .codeSuggestion: violetText
        case .reviewComment, .reply: accentText
        case .reviewRequested, .updatedSinceReview: cyanText
        case .readyToMerge: mintText
        case .mergeConflict, .reapprovalNeeded: waitingText
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
        case .reapprovalNeeded: "arrow.counterclockwise.circle.fill"
        case .updatedSinceReview: "arrow.triangle.2.circlepath.circle.fill"
        }
    }

    /// Colour of an attention reason's status glyph.
    static func reasonColor(_ reason: AttentionReason) -> Color {
        switch reason {
        case .changesRequested, .ciFailed: needs
        case .reviewerQuestion, .codeSuggestion: violet
        case .reviewComment, .reply: accent
        case .reviewRequested, .updatedSinceReview: cyan
        case .readyToMerge: mint
        case .mergeConflict, .reapprovalNeeded: waiting
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
    /// Inside a change request group: the group header already shows the provider, repository and number.
    var inGroup = false
    @State private var isHovering = false

    /// Unread or actionable items are set in a heavier weight (read, settled items used to be dimmed to 72 %).
    private var isActive: Bool { item.isActionable(now: model.now) || isUnread }
    /// The card stands for its whole conversation: unread while any of its items is.
    private var isUnread: Bool { model.conversationIsUnread(item) }
    private var activeTask: TaskRecord? { model.activeConversationTask(for: item) }

    var body: some View {
        let snapshot = model.snapshot(item.changeRequest)
        let text = Presentation.attentionText(item, snapshot: snapshot)
        let commentCount = model.conversationThread(for: item)?.comments.count ?? text.commentCount
        let actor = Presentation.actor(item, snapshot: snapshot)
        HStack(alignment: .top, spacing: 16) {
            if !inGroup {
                ProviderBadge(kind: item.providerKind, size: 42, style: .circle)
                    .avatarBadge(actor, size: 20)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if isUnread {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                    if inGroup, let actor {
                        PersonAvatar(person: actor, size: 16)
                    }
                    Text(inGroup ? item.reason.displayName : "\(item.providerKind.shortName)  •  \(item.repoFullPath)  \(item.providerKind.formattedNumber(item.number))")
                        .scaledFont(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(UIFormat.relative(from: item.updatedAt, now: model.now))
                        .scaledFont(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .help(UIFormat.dateTime(item.updatedAt))
                    InboxQuickActions(model: model, item: item)
                        .padding(.vertical, -4)
                    ItemActionsMenu(model: model, item: item, size: 24)
                        .padding(.vertical, -4)
                        .padding(.trailing, -6)
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
                    Label("\(commentCount)", systemImage: "bubble.left")
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("\(commentCount) comment\(commentCount == 1 ? "" : "s")")
                    if let task = activeTask {
                        TaskStateChip(record: task)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(Theme.cardPadding)
        .selectableGlass(isSelected: isSelected, isHovering: isHovering)
        .keyboardSelectionRing(isSelected && showsKeyboardFocus, cornerRadius: Theme.radius)
        .contentShape(SmoothRect())
        .onHover { isHovering = $0 }
        .onTapGesture {
            select()
            onSelect()
        }
        .contextMenu {
            ItemActionsMenuContent(model: model, item: item, includesOpen: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(isUnread ? "Unread. " : "")\(text.headline). \(text.subtitle). \(item.providerKind.displayName) \(item.repoFullPath) \(item.providerKind.formattedNumber(item.number)). \(UIFormat.spokenAge(from: item.updatedAt, now: model.now))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction { select() }
        .accessibilityAction(named: "Show details") { select() }
        .accessibilityAction(named: primaryActionName) { Task { await performPrimary() } }
    }

    private func select() {
        model.openInboxItem(item.id)
    }

    private var primaryActionName: String {
        if activeTask != nil { return "View task" }
        return PopoverDerivation.primaryAction(for: item).title
    }

    private func performPrimary() async {
        model.selectedAttentionID = item.id
        await model.performInboxPrimaryAction()
    }

    @ViewBuilder
    private var actionButton: some View {
        if let task = activeTask {
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
                } else if case .reviewWithAI(let key) = action {
                    model.startReview(key)
                } else {
                    select()
                }
            } label: {
                HStack(spacing: 7) {
                    if action.isAI, isSelected { SparkleIcon(size: 13) }
                    Text(title)
                }
            }
            .fixedSize()
            .accessibilityLabel("\(action.title), \(item.repoFullPath) \(item.providerKind.formattedNumber(item.number))")
            if isSelected, action.isAI {
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

/// Colour and label of a task state, honest about claims: "In progress" only with an agent claim or when you started it by hand.
enum TaskStateStyle {
    static func color(_ record: TaskRecord) -> Color {
        switch record.task.state {
        case .waitingForAgent: Theme.waiting
        case .working: record.hasRealClaim ? Theme.violet : record.isManuallyInProgress ? Theme.cyan : Theme.waiting
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
        case .working: record.hasRealClaim ? Theme.violetText : record.isManuallyInProgress ? Theme.cyanText : Theme.waitingText
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
        case .working: record.hasRealClaim ? "sparkles" : record.isManuallyInProgress ? "hammer.fill" : "clock.fill"
        case .readyForReview, .done: "checkmark.circle.fill"
        case .blocked, .stale: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .approvedAction: "checkmark.seal.fill"
        case .cancelled, .dismissed: "minus.circle.fill"
        }
    }

    static func label(_ record: TaskRecord) -> String {
        switch record.task.state {
        case .working: record.hasRealClaim || record.isManuallyInProgress ? "In progress" : "Waiting for agent"
        case .readyForReview: "Ready"
        default: record.task.state.displayName
        }
    }
}

/// One change request's cards in the Inbox under a collapsible header (D46).
struct InboxPRGroupView: View {
    let model: AppModel
    let group: InboxGroup
    var listFocused: FocusState<Bool>.Binding

    var body: some View {
        let unread = group.items.filter { model.conversationIsUnread($0) }.count
        PRGroupView(
            providerKind: group.changeRequest.kind, repoFullPath: group.repoFullPath, number: group.changeRequest.number,
            title: model.snapshot(group.changeRequest)?.summary.title ?? group.title, count: group.items.count,
            unreadCount: unread, marks: marks, latest: group.items.map(\.updatedAt).max(), now: model.now,
            isCollapsed: model.isInboxGroupCollapsed(group.changeRequest),
            approval: model.approvalSummary(group.changeRequest),
            onOpenExternal: model.snapshot(group.changeRequest).map { snapshot in { Task { await model.send(.openURL(snapshot.summary.webURL)) } } },
            toggle: { model.toggleInboxGroup(group.changeRequest) }
        ) {
            VStack(spacing: 10) {
                ForEach(group.items) { item in
                    InboxItemCard(model: model, item: item, isSelected: model.selectedAttentionID == item.id,
                                  showsKeyboardFocus: listFocused.wrappedValue, onSelect: { listFocused.wrappedValue = true }, inGroup: true)
                        .id(item.id)
                        .transition(Motion.listTransition)
                }
            }
        }
    }

    /// One mark per distinct reason, most urgent first.
    private var marks: [PRGroupMark] {
        var seen: Set<AttentionReason> = []
        return group.items.sorted { $0.priority > $1.priority }.compactMap { item in
            guard seen.insert(item.reason).inserted else { return nil }
            return PRGroupMark(symbol: Presentation.attentionText(item, snapshot: model.snapshot(item.changeRequest)).symbol,
                               color: Theme.reasonColor(item.reason))
        }
    }
}

/// The most used actions as icons next to the ••• menu (D48): Acknowledge (while it needs you) and open the
/// comment, thread or PR/MR in the provider.
struct InboxQuickActions: View {
    let model: AppModel
    let item: AttentionItem

    var body: some View {
        HStack(spacing: 2) {
            if model.conversationItems(for: item).contains(where: { $0.isActionable(now: model.now) }) {
                Button {
                    Task { await model.acknowledgeConversation(item) }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(IconButtonStyle(size: 24, filled: false))
                .help("Acknowledge")
                .accessibilityLabel("Acknowledge")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            if let url = model.providerURL(for: item) {
                Button {
                    Task { await model.send(.openURL(url)) }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(IconButtonStyle(size: 24, filled: false))
                .help(item.thread == nil ? "Open in \(item.providerKind.displayName)" : "Open the comment in \(item.providerKind.displayName)")
                .accessibilityLabel("Open in \(item.providerKind.displayName)")
            }
        }
    }
}
