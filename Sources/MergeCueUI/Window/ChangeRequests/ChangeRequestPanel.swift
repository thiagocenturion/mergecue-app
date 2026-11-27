import MergeCueCore
import SwiftUI

/// The detail panel of a PR/MR (Inbox right column and the Pull requests screen): provider, repo #N, status pill,
/// title, "Opened … • by … • N commits", Conversation / Files / Checks / Timeline tabs and, for an actionable inbox
/// item, the large "Fix now" split button.
struct ChangeRequestPanel: View {
    @Bindable var model: AppModel
    let changeRequest: ChangeRequestKey
    /// The inbox item the panel is opened for (nil on the Pull requests screen).
    var focus: AttentionItem?
    /// Closes the panel (detail tabs off; D48).
    var onClose: (() -> Void)?
    /// The scroll anchor briefly highlighted after a focus request (D51).
    @State private var highlighted: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animatesFocusScroll) private var animatesFocusScroll

    var body: some View {
        let snapshot = model.snapshot(changeRequest)
        VStack(alignment: .leading, spacing: 0) {
            header(snapshot)
                .padding(.horizontal, 22)
                .padding(.top, 20)
            UnderlineTabs(options: [
                (ChangeRequestTab.conversation, "Conversation", nil),
                (.files, "Files", snapshot?.changedFiles.count),
                (.checks, "Checks", nil),
                (.timeline, "Timeline", nil),
            ], selection: $model.changeRequestTab)
            .padding(.top, 18)
            .padding(.horizontal, 12)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tabContent(snapshot)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .task(id: "\(changeRequest.id)|\(snapshot?.summary.headSHA ?? "")") {
                    // Code context for line comments whose provider sends no hunk (read once per head).
                    if let snapshot { await model.loadDiffIfNeeded(snapshot) }
                }
                .task(id: "approvals|\(changeRequest.id)|\(snapshot?.approvals.approvedBy.count ?? 0)") {
                    // Approvals count as seen once the change request has been on screen for a moment.
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    model.markApprovalsSeen(changeRequest)
                }
            }
            .task(id: model.detailFocusRequest?.token) {
                await consumeFocusRequest(snapshot, proxy: proxy)
            }
            }
            if focus == nil, model.showsReviewWithAI(changeRequest) || model.showsApprove(changeRequest) {
                VStack(spacing: 10) {
                    if model.showsReviewWithAI(changeRequest) {
                        AIReviewSplitButton(model: model, changeRequest: changeRequest)
                    }
                    if model.showsApprove(changeRequest) {
                        ApproveButton(model: model, changeRequest: changeRequest)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 4)
            }
            if let focus {
                RelatedTaskBanner(model: model, item: focus)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                FocusActionBar(model: model, item: focus)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(Theme.panel, radius: 16)
    }

    // MARK: Header

    @ViewBuilder
    private func headerLeading(_ snapshot: ChangeRequestSnapshot?, kind: ProviderKind, repoPath: String) -> some View {
        ProviderBadge(kind: kind, size: 36, style: .circle)
        Text(repoPath)
            .scaledFont(.system(size: 16, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
        Text(kind.formattedNumber(changeRequest.number))
            .scaledFont(.system(size: 16))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(2)
        if let url = snapshot?.summary.webURL {
            Button {
                Task { await model.send(.openURL(url)) }
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(IconButtonStyle(size: 26, filled: false))
            .help("Open in \(kind.displayName)")
            .accessibilityLabel("Open in \(kind.displayName)")
        }
    }

    @ViewBuilder
    private var headerTrailing: some View {
        if let focus {
            ItemActionsMenu(model: model, item: focus)
        }
        if model.detailTabsEnabled == false {
            // The way back after turning tabs off from the tab bar (D50).
            Button {
                withAnimation(Motion.smooth) { model.detailTabsEnabled = true }
            } label: {
                Image(systemName: "rectangle.on.rectangle")
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .help("Open details in tabs")
            .accessibilityLabel("Use tabs")
        }
        if let onClose {
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 28))
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .help("Close (⇧⌘W)")
                .accessibilityLabel("Close details")
        }
    }

    @ViewBuilder
    private func header(_ snapshot: ChangeRequestSnapshot?) -> some View {
        let kind = changeRequest.kind
        let repoPath = snapshot?.summary.repository.fullPath ?? focus?.repoFullPath ?? ""
        VStack(alignment: .leading, spacing: 0) {
            // Narrow panels move the status pill to its own line instead of squeezing the repository to "…" (D48).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    headerLeading(snapshot, kind: kind, repoPath: repoPath)
                    Spacer(minLength: 8)
                    statusPill(snapshot)
                    headerTrailing
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        headerLeading(snapshot, kind: kind, repoPath: repoPath)
                        Spacer(minLength: 8)
                        headerTrailing
                    }
                    statusPill(snapshot)
                }
            }
            .accessibilityElement(children: .contain)
            Text(snapshot?.summary.title ?? focus?.title ?? "")
                .scaledFont(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            if let snapshot {
                Text(metaLine(snapshot))
                    .scaledFont(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func statusPill(_ snapshot: ChangeRequestSnapshot?) -> some View {
        if let focus {
            StatusPill(text: Presentation.statusPill(focus.reason), color: Theme.reasonColor(focus.reason),
                       textColor: Theme.reasonTextColor(focus.reason), showsDot: true, size: 12, cueSymbol: Theme.reasonSymbol(focus.reason))
        } else if let snapshot {
            let (text, color, textColor) = Self.readiness(snapshot)
            StatusPill(text: text, color: color, textColor: textColor, showsDot: true, size: 12)
        }
    }

    /// Readiness label with its fill and text colours.
    static func readiness(_ snapshot: ChangeRequestSnapshot) -> (String, Color, Color) {
        switch snapshot.summary.state {
        case .merged: return ("Merged", Theme.violet, Theme.violetText)
        case .closed: return ("Closed", Theme.textSecondary, Theme.textSecondary)
        case .open: break
        }
        if snapshot.summary.isDraft { return ("Draft", Theme.textSecondary, Theme.textSecondary) }
        if snapshot.reviews.last(where: { $0.state == .changesRequested }) != nil,
           snapshot.reviewers.contains(where: { $0.state == .changesRequested }) {
            return ("Changes requested", Theme.needs, Theme.needsText)
        }
        switch snapshot.readiness {
        case .readyToMerge: return ("Ready to merge", Theme.mint, Theme.mintText)
        case .checksGreen: return ("Checks green", Theme.mint, Theme.mintText)
        case .blocked: return ("Blocked", Theme.waiting, Theme.waitingText)
        case .unknown: return ("Open", Theme.accent, Theme.accentText)
        }
    }

    private func metaLine(_ snapshot: ChangeRequestSnapshot) -> String {
        let summary = snapshot.summary
        let commits = snapshot.commits.count
        return "Opened \(UIFormat.relative(from: summary.createdAt, now: model.now))  •  by \(summary.author.username)  •  \(commits) commit\(commits == 1 ? "" : "s")"
    }

    // MARK: Tabs

    @ViewBuilder
    private func tabContent(_ snapshot: ChangeRequestSnapshot?) -> some View {
        if let snapshot {
            switch model.changeRequestTab {
            case .conversation: conversation(snapshot)
            case .files: ChangeRequestFilesTab(snapshot: snapshot)
            case .checks: ChangeRequestChecksTab(model: model, snapshot: snapshot)
            case .timeline: ChangeRequestTimelineTab(snapshot: snapshot, now: model.now)
            }
        } else {
            NothingSelected(title: "Not loaded yet", symbol: "arrow.triangle.2.circlepath",
                            message: "MergeCue hasn't fetched this \(changeRequest.kind.changeRequestNoun) yet. Refresh to load it.")
        }
    }

    @ViewBuilder
    private func conversation(_ snapshot: ChangeRequestSnapshot) -> some View {
        let tasks: [TaskRecord] = if let focus { model.activeConversationTask(for: focus).map { [$0] } ?? [] }
            else { model.tasks(for: snapshot.key).filter { !$0.task.isTerminal } }
        ForEach(tasks) { LinkedTaskCard(model: model, record: $0) }
        let reviewerIDs = Set(snapshot.reviewers.map(\.person.remoteID) + snapshot.reviews.map(\.author.remoteID))
        let checkout = model.mapping(for: snapshot.key.repo)?.checkoutPath
        if let focus, let thread = model.conversationThread(for: focus) {
            // The whole conversation (replies, threads on the same line, top-level comments) in time order.
            let unread = model.conversationItems(for: focus).filter(\.isUnread).map(\.createdAt).min()
            ThreadView(thread: thread, providerKind: snapshot.summary.providerKind,
                       unreadSince: unread, currentUserID: snapshot.key.account.remoteUserID,
                       now: model.now, reviewers: reviewerIDs, authorID: snapshot.summary.author.remoteID, checkoutPath: checkout,
                       onOpen: open, showsHeader: false, codeLines: model.codeLines(for: thread, snapshot: snapshot),
                       isLoadingCode: isLoadingCode(snapshot))
                .focusHighlight(highlighted == Self.anchor(thread.key))
                .scrollAnchor(Self.anchor(thread.key))
        } else if let focus, let checkKey = focus.check, let check = snapshot.check(checkKey) {
            CheckDetail(model: model, check: check)
                .padding(Theme.cardPadding)
                .cardBackground(Theme.surface)
        } else {
            if let description = snapshot.description, !description.isEmpty {
                Card("Description", systemImage: "text.alignleft") {
                    CommentBody(text: description, onOpen: open)
                }
            }
            ReviewersCard(snapshot: snapshot)
                .focusHighlight(highlighted == Self.reviewersAnchor)
                .scrollAnchor(Self.reviewersAnchor)
            // One card per conversation, like the Inbox.
            let threads = ConversationGrouping.conversations(snapshot).compactMap { group -> ConversationEntry? in
                ConversationGrouping.merged(group).map { ConversationEntry(thread: $0, keys: group.map(\.key)) }
            }
            .sorted { lhs, rhs in
                if lhs.thread.isUnresolved != rhs.thread.isUnresolved { return lhs.thread.isUnresolved }
                return lhs.thread.lastActivityAt > rhs.thread.lastActivityAt
            }
            ForEach(threads, id: \.thread.id) { entry in
                // `scrollAnchor` (not `.id`): an `.id` on a ForEach row is never found by `scrollTo`.
                let (thread, keys) = (entry.thread, entry.keys)
                let unread = model.state.attention
                    .filter { item in item.isUnread && item.thread.map(keys.contains) == true }
                    .map(\.createdAt).min()
                ThreadView(thread: thread, providerKind: snapshot.summary.providerKind,
                           unreadSince: unread, currentUserID: snapshot.key.account.remoteUserID,
                           now: model.now, reviewers: reviewerIDs, authorID: snapshot.summary.author.remoteID, checkoutPath: checkout,
                           onOpen: open, codeLines: model.codeLines(for: thread, snapshot: snapshot),
                           isLoadingCode: isLoadingCode(snapshot))
                    .focusHighlight(highlighted == entry.anchor)
                    .scrollAnchor(entry.anchor)
                    .padding(.top, 6)
            }
            if threads.isEmpty {
                Text("No review threads yet.")
                    .scaledFont(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func open(_ url: URL) {
        Task { await model.send(.openURL(url)) }
    }

    // MARK: Focus (D51)

    static let reviewersAnchor = "reviewers"

    static func anchor(_ key: ThreadKey) -> String { "thread|\(key.id)" }

    /// The scroll anchor showing `target`: the conversation card that contains the thread, or the reviewers card.
    private func anchor(for target: DetailFocusRequest.Target, in snapshot: ChangeRequestSnapshot) -> String? {
        switch target {
        case .reviewers:
            return focus == nil ? Self.reviewersAnchor : nil
        case .thread(let key):
            if let focus, let thread = model.conversationThread(for: focus) { return Self.anchor(thread.key) }
            for group in ConversationGrouping.conversations(snapshot) where group.contains(where: { $0.key == key }) {
                return ConversationGrouping.merged(group).map { Self.anchor($0.key) }
            }
            return nil
        }
    }

    /// Scrolls to the requested thread or approvals once the content is laid out, highlights it for about a
    /// second, and clears the request.
    private func consumeFocusRequest(_ snapshot: ChangeRequestSnapshot?, proxy: ScrollViewProxy) async {
        guard let request = model.detailFocusRequest, request.changeRequestID == changeRequest.id, let snapshot else { return }
        model.changeRequestTab = .conversation
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let anchor = anchor(for: request.target, in: snapshot) else { return }
        withAnimation(scrollAnimation) { proxy.scrollTo(anchor, anchor: .top) }
        // The rest runs on its own: clearing the request changes this task's id, which cancels it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            // Again once layout has settled: the first scroll is lost when the content was not laid out yet, and
            // code context arriving after it shifts the target.
            withAnimation(scrollAnimation) { proxy.scrollTo(anchor, anchor: .top) }
            withAnimation(Motion.hover) { highlighted = anchor }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeOut(duration: 0.6)) { if highlighted == anchor { highlighted = nil } }
        }
        if model.detailFocusRequest?.token == request.token { model.detailFocusRequest = nil }
    }

    private var scrollAnimation: Animation? { reduceMotion || !animatesFocusScroll ? nil : Motion.smooth }

    /// The diff that gives line comments their code is still to come.
    private func isLoadingCode(_ snapshot: ChangeRequestSnapshot) -> Bool {
        model.isLoadingDiff(snapshot) || (model.needsDiff(snapshot) && model.diffFiles(for: snapshot) == nil)
    }
}

/// The ••• button of an inbox item (list card and detail header). Same actions as its right-click menu.
struct ItemActionsMenu: View {
    let model: AppModel
    let item: AttentionItem
    var size: CGFloat = 28

    var body: some View {
        Menu {
            ItemActionsMenuContent(model: model, item: item)
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: size, height: size)
                .glassShape(Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}

/// Actions on an inbox item's conversation: start or view its task, mark read, acknowledge, snooze, show the PR/MR,
/// open or copy the provider link, copy the latest comment, dismiss. Used by the ••• menu and the context menu, and
/// applied to every item of the conversation (`AppModel+Conversations`).
struct ItemActionsMenuContent: View {
    let model: AppModel
    let item: AttentionItem
    /// Shown in the list's context menu, where the card is not open yet.
    var includesOpen = false

    var body: some View {
        let isUnread = model.conversationIsUnread(item)
        let isActionable = model.conversationItems(for: item).contains { $0.isActionable(now: model.now) }
        if includesOpen {
            Button("Open") { model.openInboxItem(item.id) }
        }
        let attachable = model.attachableTasks(for: item)
        if let task = model.activeConversationTask(for: item) {
            Button("View Task") { model.showTask(task.id) }
            if model.attachingTask(for: item) != nil {
                if !attachable.isEmpty {
                    Menu("Move to Task") { taskButtons(attachable) }
                }
                Button("Remove from Task") { Task { await model.removeConversationFromTask(item) } }
            }
        } else {
            if case .createTask(let id, let type) = PopoverDerivation.primaryAction(for: item) {
                Button(type.menuTitle) { Task { await model.createTaskAndShow(attentionID: id, type: type) } }
                Menu("Start Task") {
                    ForEach(TaskType.allCases, id: \.self) { other in
                        Button(other.menuTitle) { Task { await model.createTaskAndShow(attentionID: id, type: other) } }
                    }
                }
            }
            if !attachable.isEmpty {
                Menu("Add to Task") { taskButtons(attachable) }
            }
        }
        Divider()
        Button(isUnread ? "Mark as Read" : "Mark as Unread") {
            Task { await model.markConversation(item, read: isUnread) }
        }
        if isActionable {
            Button("Acknowledge") { Task { await model.acknowledgeConversation(item) } }
            Menu("Snooze") {
                Button("For 1 Hour") { snooze(model.now.addingTimeInterval(3_600)) }
                Button("Until Tomorrow Morning") { snooze(PauseOptions.tomorrowMorning(after: model.now)) }
                Button("For a Week") { snooze(model.now.addingTimeInterval(7 * 86_400)) }
            }
        }
        Divider()
        Button("Show \(item.providerKind.changeRequestAbbreviation) Details") { model.showChangeRequest(item.changeRequest, thread: item.thread) }
        if let url = model.providerURL(for: item) {
            Button { Task { await model.send(.openURL(url)) } } label: {
                Label("Open in \(item.providerKind.displayName)", systemImage: OutsideLinkGlyph.symbol)
            }
            Button("Copy Link") { model.copyToPasteboard(url.absoluteString, confirmation: "Link copied") }
        }
        if let comment = model.conversationThread(for: item)?.latestComment {
            Button("Copy Latest Comment") { model.copyToPasteboard(comment.body, confirmation: "Comment copied") }
        }
        Divider()
        Button("Dismiss") { Task { await model.dismissConversation(item) } }
    }

    private func snooze(_ until: Date) {
        Task { await model.snoozeConversation(item, until: until) }
    }

    /// One button per task on this change request ("Investigate CI failure · Working").
    private func taskButtons(_ tasks: [TaskRecord]) -> some View {
        ForEach(tasks) { task in
            Button(model.taskMenuTitle(task)) { Task { await model.addConversation(item, to: task.id) } }
        }
    }
}

/// The large gradient "Fix now" split button (or the linked task when one is already active).
struct FocusActionBar: View {
    @Bindable var model: AppModel
    let item: AttentionItem

    var body: some View {
        if let task = model.activeTask(for: item) {
            Button {
                model.showTask(task.id)
            } label: {
                HStack(spacing: 10) {
                    Circle().fill(TaskStateStyle.color(task)).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text("Open task · \(TaskStateStyle.label(task))")
                    Image(systemName: "arrow.right").scaledFont(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(SecondaryButtonStyle(size: .large, fullWidth: true))
        } else if case .createTask(let attentionID, let type) = PopoverDerivation.primaryAction(for: item) {
            AITaskSplitButton(model: model, attentionID: attentionID, defaultType: type)
        } else if Self.reviewReasons.contains(item.reason), model.showsReviewWithAI(item.changeRequest) {
            // Reviews (D59, D60): Review with AI on top, Approve and Acknowledge below.
            VStack(spacing: 10) {
                AIReviewSplitButton(model: model, changeRequest: item.changeRequest)
                HStack(spacing: 10) {
                    if model.showsApprove(item.changeRequest) {
                        ApproveButton(model: model, changeRequest: item.changeRequest)
                    }
                    acknowledge
                }
            }
        } else if Self.reviewReasons.contains(item.reason), model.showsApprove(item.changeRequest) {
            // Reviews (D59): Approve first, Acknowledge beside it.
            HStack(spacing: 10) {
                ApproveButton(model: model, changeRequest: item.changeRequest)
                acknowledge
            }
        } else {
            acknowledge
        }
    }

    private var acknowledge: some View {
        Button {
            Task { await model.send(.acknowledge(attentionID: item.id)) }
        } label: {
            Label("Acknowledge", systemImage: "checkmark")
        }
        .buttonStyle(SecondaryButtonStyle(size: .large, fullWidth: true))
        .disabled(!item.isActionable(now: model.now))
    }

    /// Items about the owner's review of someone else's PR/MR, where Approve is the answer.
    static let reviewReasons: Set<AttentionReason> = [.reviewRequested, .reapprovalNeeded, .updatedSinceReview]
}

// MARK: - Tabs

struct ChangeRequestFilesTab: View {
    let snapshot: ChangeRequestSnapshot

    var body: some View {
        let additions = snapshot.changedFiles.compactMap(\.additions).reduce(0, +)
        let deletions = snapshot.changedFiles.compactMap(\.deletions).reduce(0, +)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("\(snapshot.changedFiles.count) changed file\(snapshot.changedFiles.count == 1 ? "" : "s")")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("+\(additions)").foregroundStyle(Theme.mintText)
                Text("−\(deletions)").foregroundStyle(Theme.criticalText)
            }
            .scaledFont(.system(size: 12.5, weight: .medium).monospacedDigit())
            ChangedFileList(files: snapshot.changedFiles)
                .padding(Theme.cardPadding)
                .cardBackground(Theme.surface)
        }
    }
}

struct ChangeRequestChecksTab: View {
    let model: AppModel
    let snapshot: ChangeRequestSnapshot

    var body: some View {
        if snapshot.checks.isEmpty {
            Text("No checks reported for this \(snapshot.summary.providerKind.changeRequestNoun).")
                .scaledFont(Theme.body)
                .foregroundStyle(Theme.textSecondary)
        }
        VStack(spacing: 0) {
            ForEach(Array(snapshot.checks.enumerated()), id: \.element.id) { index, check in
                if index > 0 { ThemeDivider() }
                HStack(spacing: 10) {
                    CheckStatusIcon(status: check.status)
                    Text(check.name)
                        .scaledFont(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if check.isRequired == true { Chip(text: "Required") }
                    Spacer(minLength: 6)
                    Text(check.summary ?? check.status.displayName)
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if let url = check.detailsURL {
                        Button {
                            Task { await model.send(.openURL(url)) }
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(IconButtonStyle(size: 24, filled: false))
                        .help("Open the check in \(snapshot.summary.providerKind.displayName)")
                        .accessibilityLabel("Open \(check.name)")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(check.name)\(check.isRequired == true ? ", required" : ""): \(check.summary ?? check.status.displayName)")
            }
        }
        .cardBackground(Theme.surface)
        ForEach(snapshot.checks.filter { $0.status.isFailing && $0.key.source != .gitlabPipeline }) { check in
            CheckDetail(model: model, check: check)
                .padding(Theme.cardPadding)
                .cardBackground(Theme.surface)
        }
    }
}

/// Opened, commits, reviews and comments in time order.
struct ChangeRequestTimelineTab: View {
    let snapshot: ChangeRequestSnapshot
    let now: Date

    private struct Event: Identifiable {
        var id: String
        var date: Date
        var symbol: String
        var color: Color
        var title: String
        var detail: String?
    }

    private var events: [Event] {
        var events: [Event] = [Event(id: "opened", date: snapshot.summary.createdAt, symbol: "arrow.triangle.pull", color: Theme.accent,
                                     title: "\(snapshot.summary.author.displayLabel) opened the \(snapshot.summary.providerKind.changeRequestNoun)",
                                     detail: "\(snapshot.summary.sourceBranch) → \(snapshot.summary.targetBranch)")]
        for commit in snapshot.commits {
            guard let date = commit.authoredAt else { continue }
            events.append(Event(id: "c-" + commit.sha, date: date, symbol: "smallcircle.filled.circle", color: Theme.textSecondary,
                                title: commit.title, detail: "\(UIFormat.shortSHA(commit.sha))\(commit.author.map { " · @\($0)" } ?? "")"))
        }
        for review in snapshot.reviews {
            guard let date = review.submittedAt else { continue }
            let (verb, color): (String, Color) = switch review.state {
            case .approved: ("approved", Theme.mint)
            case .changesRequested: ("requested changes", Theme.needs)
            case .commented: ("reviewed", Theme.accent)
            case .pending: ("started a review", Theme.textSecondary)
            case .dismissed: ("had a review dismissed", Theme.textSecondary)
            }
            events.append(Event(id: "r-" + review.remoteID, date: date, symbol: "person.crop.circle.badge.checkmark", color: color,
                                title: "\(review.author.displayLabel) \(verb)", detail: review.body.map(UIFormat.untrustedDisplay)))
        }
        for thread in snapshot.threads {
            for comment in thread.comments {
                events.append(Event(id: "m-" + comment.id, date: comment.createdAt, symbol: "bubble.left", color: Theme.violet,
                                    title: "\(comment.author.displayLabel) commented\(thread.anchor.map { " on \($0.path.split(separator: "/").last ?? "")" } ?? "")",
                                    detail: Presentation.firstLine(comment.body, limit: 90)))
            }
        }
        return events.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let all = events
            ForEach(Array(all.enumerated()), id: \.element.id) { index, event in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Image(systemName: event.symbol)
                            .scaledFont(.system(size: 11, weight: .semibold))
                            .foregroundStyle(event.color)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(event.color.opacity(0.14)))
                        if index < all.count - 1 {
                            Rectangle().fill(Theme.divider).frame(width: 1.5).frame(maxHeight: .infinity)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.title)
                                .scaledFont(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                            Spacer(minLength: 6)
                            Text(UIFormat.relative(from: event.date, now: now))
                                .scaledFont(.system(size: 11.5))
                                .foregroundStyle(Theme.textTertiary)
                                .help(UIFormat.dateTime(event.date))
                        }
                        if let detail = event.detail, !detail.isEmpty {
                            Text(detail)
                                .scaledFont(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.bottom, 14)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Theme.cardPadding)
        .cardBackground(Theme.surface)
    }
}

/// One conversation card in the change request's thread list, identified by its scroll anchor.
private struct ConversationEntry {
    var thread: ReviewThread
    var keys: [ThreadKey]
    var anchor: String { ChangeRequestPanel.anchor(thread.key) }
}
