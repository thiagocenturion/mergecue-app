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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(InboxDayGroup.make(result.visibleItems, now: model.now)) { group in
                            Text(group.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 10)
                                .padding(.leading, 2)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.items) { item in
                                InboxItemCard(model: model, item: item, isSelected: model.selectedAttentionID == item.id)
                            }
                        }
                        readToggle(result)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.automatic)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Presentation.greeting(now: model.now, firstName: model.userFirstName))
                    .font(Theme.largeTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Text(Presentation.attentionSubtitle(count: model.sections.count(.needsYou)))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            SearchField(text: $model.inboxFilter.searchText, prompt: "Search", showsShortcut: true, focus: $searchFocused)
                .frame(width: 200)
                .padding(.top, 2)
                .help("Search title, repository, #42 (⌘K)")
        }
    }

    @ViewBuilder
    private func readToggle(_ result: InboxResult) -> some View {
        if result.hiddenReadCount > 0 {
            Button {
                model.showReadInInbox = true
            } label: {
                Label("Show \(result.hiddenReadCount) read item\(result.hiddenReadCount == 1 ? "" : "s")", systemImage: "chevron.down.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(PlainRowButtonStyle())
            .padding(.top, 6)
        } else if model.showReadInInbox && model.inboxFilter.collapseRead {
            Button {
                model.showReadInInbox = false
            } label: {
                Label("Collapse read items", systemImage: "chevron.up.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.surfaceRaised))
                .overlay(Circle().strokeBorder(Theme.borderStrong, lineWidth: 1))
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

    var body: some View {
        HStack(spacing: 14) {
            card(.needsYou, title: "Needs you", symbol: "exclamationmark") {
                model.inboxFilter.status = .needsAction
            }
            card(.aiWorking, title: "AI working", symbol: "sparkles") { model.showAll(.aiWorking) }
            card(.ready, title: "Ready", symbol: "checkmark") { model.showAll(.ready) }
        }
    }

    private func card(_ section: PopoverSection, title: String, symbol: String, action: @escaping () -> Void) -> some View {
        let count = model.sections.count(section)
        let color = section == .aiWorking ? Theme.violet : Theme.color(section)
        return Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(section == .aiWorking ? AnyShapeStyle(LinearGradient(colors: [Theme.violet, Theme.cyan], startPoint: .bottomLeading, endPoint: .topTrailing)) : AnyShapeStyle(color))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(color.opacity(0.16)))
                    .overlay(Circle().strokeBorder(color.opacity(0.4), lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(count)")
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 78)
            .frame(maxWidth: .infinity)
            .cardBackground()
        }
        .buttonStyle(PlainRowButtonStyle())
        .accessibilityLabel("\(title): \(count)")
        .accessibilityHint(section == .needsYou ? "Shows only items that need action" : "Shows these tasks")
    }
}

extension Theme {
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
    @State private var isHovering = false

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
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(UIFormat.relative(from: item.updatedAt, now: model.now))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .help(UIFormat.dateTime(item.updatedAt))
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 9) {
                            StatusGlyph(symbol: text.symbol, color: Theme.reasonColor(item.reason), size: 20)
                            Text(text.headline)
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                        }
                        Text(text.subtitle)
                            .font(.system(size: 13))
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
                        .font(.system(size: 12))
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
        .shadow(color: isSelected ? Theme.accent.opacity(0.18) : .clear, radius: 12)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { select() }
        .opacity(item.isActionable(now: model.now) || item.isUnread ? 1 : 0.72)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.isUnread ? "Unread. " : "")\(text.headline). \(text.subtitle). \(item.providerKind.displayName) \(item.repoFullPath) \(item.providerKind.formattedNumber(item.number)). \(UIFormat.spokenAge(from: item.updatedAt, now: model.now))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: "Show details") { select() }
    }

    private func select() {
        model.selectedAttentionID = item.id
        model.changeRequestTab = .conversation
        if item.isUnread {
            Task { await model.send(.markRead(attentionID: item.id, read: true)) }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let task = model.activeTask(for: item) {
            Button("View task") { model.showTask(task.id) }
                .buttonStyle(SecondaryButtonStyle(size: .regular))
                .fixedSize()
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
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(color)
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

    static func label(_ record: TaskRecord) -> String {
        switch record.task.state {
        case .working: record.hasRealClaim ? "AI working" : "Waiting for agent"
        case .readyForReview: "Ready"
        default: record.task.state.displayName
        }
    }
}
