import MergeCueCore
import SwiftUI

/// The detail panel of a PR/MR (Inbox right column and the Pull requests screen): provider, repo #N, status pill,
/// title, "Opened … • by … • N commits", Conversation / Files / Checks / Timeline tabs and, for an actionable inbox
/// item, the large "Fix with AI" split button.
struct ChangeRequestPanel: View {
    @Bindable var model: AppModel
    let changeRequest: ChangeRequestKey
    /// The inbox item the panel is opened for (nil on the Pull requests screen).
    var focus: AttentionItem?

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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tabContent(snapshot)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let focus {
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
    private func header(_ snapshot: ChangeRequestSnapshot?) -> some View {
        let kind = changeRequest.kind
        let repoPath = snapshot?.summary.repository.fullPath ?? focus?.repoFullPath ?? ""
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ProviderBadge(kind: kind, size: 36, style: .circle)
                Text(repoPath)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(kind.formattedNumber(changeRequest.number))
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
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
                Spacer(minLength: 8)
                statusPill(snapshot)
                if let focus {
                    ItemActionsMenu(model: model, item: focus)
                }
            }
            .accessibilityElement(children: .contain)
            Text(snapshot?.summary.title ?? focus?.title ?? "")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            if let snapshot {
                Text(metaLine(snapshot))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func statusPill(_ snapshot: ChangeRequestSnapshot?) -> some View {
        if let focus {
            StatusPill(text: Presentation.statusPill(focus.reason), color: Theme.reasonColor(focus.reason), showsDot: true, size: 12)
        } else if let snapshot {
            let (text, color) = Self.readiness(snapshot)
            StatusPill(text: text, color: color, showsDot: true, size: 12)
        }
    }

    static func readiness(_ snapshot: ChangeRequestSnapshot) -> (String, Color) {
        switch snapshot.summary.state {
        case .merged: return ("Merged", Theme.violet)
        case .closed: return ("Closed", Theme.textSecondary)
        case .open: break
        }
        if snapshot.summary.isDraft { return ("Draft", Theme.textSecondary) }
        if snapshot.reviews.last(where: { $0.state == .changesRequested }) != nil,
           snapshot.reviewers.contains(where: { $0.state == .changesRequested }) {
            return ("Changes requested", Theme.needs)
        }
        switch snapshot.readiness {
        case .readyToMerge: return ("Ready to merge", Theme.mint)
        case .checksGreen: return ("Checks green", Theme.mint)
        case .blocked: return ("Blocked", Theme.waiting)
        case .unknown: return ("Open", Theme.accent)
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
        let tasks: [TaskRecord] = if let focus { model.activeTask(for: focus).map { [$0] } ?? [] }
            else { model.tasks(for: snapshot.key).filter { !$0.task.isTerminal } }
        ForEach(tasks) { LinkedTaskCard(model: model, record: $0) }
        let reviewerIDs = Set(snapshot.reviewers.map(\.person.remoteID) + snapshot.reviews.map(\.author.remoteID))
        let checkout = model.mapping(for: snapshot.key.repo)?.checkoutPath
        if let focus, let threadKey = focus.thread, let thread = snapshot.thread(threadKey) {
            ThreadView(thread: thread, providerKind: snapshot.summary.providerKind,
                       unreadSince: focus.isUnread ? focus.createdAt : nil, currentUserID: snapshot.key.account.remoteUserID,
                       now: model.now, reviewers: reviewerIDs, authorID: snapshot.summary.author.remoteID, checkoutPath: checkout,
                       onOpen: open, showsHeader: false)
        } else if let focus, let checkKey = focus.check, let check = snapshot.check(checkKey) {
            CheckDetail(model: model, check: check)
                .padding(14)
                .cardBackground(Theme.surface)
        } else {
            if let description = snapshot.description, !description.isEmpty {
                Card("Description", systemImage: "text.alignleft") {
                    CommentBody(text: description)
                }
            }
            ReviewersCard(snapshot: snapshot)
            let threads = snapshot.threads.sorted { lhs, rhs in
                if lhs.isUnresolved != rhs.isUnresolved { return lhs.isUnresolved }
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            ForEach(threads) { thread in
                let item = model.state.attention.first { $0.thread == thread.key }
                ThreadView(thread: thread, providerKind: snapshot.summary.providerKind,
                           unreadSince: item?.isUnread == true ? item?.createdAt : nil, currentUserID: snapshot.key.account.remoteUserID,
                           now: model.now, reviewers: reviewerIDs, authorID: snapshot.summary.author.remoteID, checkoutPath: checkout,
                           onOpen: open)
                    .padding(.top, 6)
            }
            if threads.isEmpty {
                Text("No review threads yet.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func open(_ url: URL) {
        Task { await model.send(.openURL(url)) }
    }
}

/// Mark read, acknowledge, snooze, dismiss, show PR details, open in provider.
struct ItemActionsMenu: View {
    let model: AppModel
    let item: AttentionItem

    var body: some View {
        Menu {
            Button(item.isUnread ? "Mark as Read" : "Mark as Unread") {
                Task { await model.send(.markRead(attentionID: item.id, read: item.isUnread)) }
            }
            if item.isActionable(now: model.now) {
                Button("Acknowledge") { Task { await model.send(.acknowledge(attentionID: item.id)) } }
                Menu("Snooze") {
                    Button("For 1 Hour") { snooze(model.now.addingTimeInterval(3_600)) }
                    Button("Until Tomorrow Morning") { snooze(PauseOptions.tomorrowMorning(after: model.now)) }
                    Button("For a Week") { snooze(model.now.addingTimeInterval(7 * 86_400)) }
                }
            }
            Divider()
            Button("Show \(item.providerKind.changeRequestAbbreviation) Details") { model.showChangeRequest(item.changeRequest) }
            Button("Dismiss") { Task { await model.send(.dismissAttention(attentionID: item.id)) } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    private func snooze(_ until: Date) {
        Task { await model.send(.snooze(attentionID: item.id, until: until)) }
    }
}

/// The large gradient "Fix with AI" split button (or the linked task when one is already active).
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
                    Text("Open task · \(TaskStateStyle.label(task))")
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(SecondaryButtonStyle(size: .large, fullWidth: true))
        } else if case .createTask(let attentionID, let type) = PopoverDerivation.primaryAction(for: item) {
            AITaskSplitButton(model: model, attentionID: attentionID, defaultType: type)
        } else {
            Button {
                Task { await model.send(.acknowledge(attentionID: item.id)) }
            } label: {
                Label("Acknowledge", systemImage: "checkmark")
            }
            .buttonStyle(SecondaryButtonStyle(size: .large, fullWidth: true))
            .disabled(!item.isActionable(now: model.now))
        }
    }
}

/// "✦ Fix with AI | ⌄": the main part creates the default task; the menu picks another task type or the agent.
struct AITaskSplitButton: View {
    @Bindable var model: AppModel
    let attentionID: String
    let defaultType: TaskType

    var body: some View {
        HStack(spacing: 0) {
            Button {
                start(defaultType)
            } label: {
                HStack(spacing: 10) {
                    SparkleIcon(size: 16)
                    Text(defaultType.actionTitle)
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainRowButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .help("\(defaultType.actionTitle) — creates a task for your agent (⌘↩)")
            Rectangle().fill(.white.opacity(0.28)).frame(width: 1, height: 50)
            Menu {
                Section("Task") {
                    ForEach(TaskType.allCases, id: \.self) { type in
                        Button(type.menuTitle) { start(type) }
                    }
                }
                Section("Agent") {
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        Toggle(isOn: Binding(get: { model.effectiveAgentKind == kind }, set: { if $0 { model.selectedAgentKind = kind } })) {
                            Text(model.state.agents.contains { $0.kind == kind } ? kind.shortName : "\(kind.shortName) (not detected)")
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 50)
            .accessibilityLabel("More AI actions")
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.brandGradient))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .shadow(color: Color(hex: 0x3B82F6).opacity(0.3), radius: 12, y: 3)
    }

    private func start(_ type: TaskType) {
        Task { await model.createTaskAndShow(attentionID: attentionID, type: type) }
    }
}

extension TaskType {
    /// Menu wording (Fix with AI / Address with AI / Draft reply / Investigate CI).
    var menuTitle: String {
        switch self {
        case .fixReview: "Fix with AI"
        case .addressSuggestion: "Address with AI"
        case .draftReply: "Draft reply"
        case .investigateCI: "Investigate CI"
        }
    }
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
                Text("+\(additions)").foregroundStyle(Theme.mint)
                Text("−\(deletions)").foregroundStyle(Theme.critical)
            }
            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            ChangedFileList(files: snapshot.changedFiles)
                .padding(14)
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
                .font(Theme.body)
                .foregroundStyle(Theme.textSecondary)
        }
        VStack(spacing: 0) {
            ForEach(Array(snapshot.checks.enumerated()), id: \.element.id) { index, check in
                if index > 0 { ThemeDivider() }
                HStack(spacing: 10) {
                    CheckStatusIcon(status: check.status)
                    Text(check.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if check.isRequired == true { Chip(text: "Required") }
                    Spacer(minLength: 6)
                    Text(check.summary ?? check.status.displayName)
                        .font(.system(size: 12))
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
                .accessibilityElement(children: .combine)
            }
        }
        .cardBackground(Theme.surface)
        ForEach(snapshot.checks.filter { $0.status.isFailing && $0.key.source != .gitlabPipeline }) { check in
            CheckDetail(model: model, check: check)
                .padding(14)
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
                                title: "\(review.author.displayLabel) \(verb)", detail: review.body))
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
                            .font(.system(size: 11, weight: .semibold))
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
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                            Spacer(minLength: 6)
                            Text(UIFormat.relative(from: event.date, now: now))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textTertiary)
                                .help(UIFormat.dateTime(event.date))
                        }
                        if let detail = event.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.bottom, 14)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .cardBackground(Theme.surface)
    }
}
