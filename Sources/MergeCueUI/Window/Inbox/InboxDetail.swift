import MergeCueCore
import SwiftUI

/// Detail of an attention item: heading, actions, linked task, full thread conversation (file/line + diff hunk,
/// unread markers) or failing check with its CI excerpt.
struct InboxDetail: View {
    let model: AppModel

    var body: some View {
        if let item = model.attentionItem(model.selectedAttentionID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AttentionHeader(model: model, item: item)
                    AttentionActionBar(model: model, item: item)
                    if let task = model.activeTask(for: item) ?? model.task(item.linkedTaskID) {
                        LinkedTaskCard(model: model, record: task)
                    }
                    content(for: item)
                }
                .padding(20)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .id(item.id)
        } else {
            NothingSelected(title: "Select an item", symbol: "tray", message: "Pick an item to see its conversation, checks and actions.")
        }
    }

    @ViewBuilder
    private func content(for item: AttentionItem) -> some View {
        let snapshot = model.snapshot(item.changeRequest)
        if let threadKey = item.thread, let thread = snapshot?.thread(threadKey) {
            Card(thread.comments.count == 1 ? "Comment" : "Conversation · \(thread.comments.count) comments", systemImage: "bubble.left.and.bubble.right") {
                ThreadView(thread: thread, providerKind: item.providerKind,
                           unreadSince: item.isUnread ? item.createdAt : nil,
                           currentUserID: item.account.remoteUserID, now: model.now) { url in
                    Task { await model.send(.openURL(url)) }
                }
            }
        }
        if let checkKey = item.check, let check = snapshot?.check(checkKey) {
            Card("Check", systemImage: "checklist") {
                CheckDetail(model: model, check: check)
            }
        }
        if let snapshot {
            ChangeRequestSummaryCard(model: model, snapshot: snapshot)
        }
    }
}

struct AttentionHeader: View {
    let model: AppModel
    let item: AttentionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChangeRequestRefLabel(kind: item.providerKind, repoFullPath: item.repoFullPath, number: item.number, font: .callout, glyphSize: 16)
            Text(item.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Chip(text: item.reason.displayName, symbol: item.reason.symbolName, tone: item.reason.tone)
                if item.priority >= .high {
                    Chip(text: item.priority == .urgent ? "Urgent" : "High priority", symbol: "flag.fill", tone: .critical)
                }
                if item.isUnread { Chip(text: "Unread", symbol: "circle.fill", tone: .progress) }
                Text("\(item.summary) · \(UIFormat.relative(from: item.updatedAt, now: model.now))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Primary AI action + direct actions (mark read, acknowledge, snooze, dismiss, open in provider).
struct AttentionActionBar: View {
    let model: AppModel
    let item: AttentionItem

    var body: some View {
        let primary = PopoverDerivation.primaryAction(for: item)
        let hasTask = model.activeTask(for: item) != nil
        HStack(spacing: 8) {
            if case .createTask = primary, !hasTask {
                Button {
                    Task { await model.perform(primary) }
                } label: {
                    Label(primary.title, systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("\(primary.title) (⌘↩)")
            }
            Button {
                Task { await model.send(.markRead(attentionID: item.id, read: item.isUnread)) }
            } label: {
                Label(item.isUnread ? "Mark Read" : "Mark Unread", systemImage: item.isUnread ? "envelope.open" : "envelope.badge")
            }
            if item.isActionable(now: model.now) {
                Button {
                    Task { await model.send(.acknowledge(attentionID: item.id)) }
                } label: {
                    Label("Acknowledge", systemImage: "checkmark")
                }
                Menu {
                    Button("For 1 Hour") { snooze(model.now.addingTimeInterval(3_600)) }
                    Button("Until Tomorrow Morning") { snooze(PauseOptions.tomorrowMorning(after: model.now)) }
                    Button("For a Week") { snooze(model.now.addingTimeInterval(7 * 86_400)) }
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                .fixedSize()
            }
            Spacer(minLength: 8)
            Menu {
                Button("Dismiss") { Task { await model.send(.dismissAttention(attentionID: item.id)) } }
                Button("Show \(item.providerKind.changeRequestAbbreviation) Details") { model.showChangeRequest(item.changeRequest) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
            Button {
                openInProvider()
            } label: {
                Label("Open in \(item.providerKind.displayName)", systemImage: "arrow.up.right.square")
            }
        }
        .controlSize(.regular)
        .labelStyle(.titleAndIcon)
    }

    private func snooze(_ until: Date) {
        Task { await model.send(.snooze(attentionID: item.id, until: until)) }
    }

    private func openInProvider() {
        let snapshot = model.snapshot(item.changeRequest)
        let url = item.thread.flatMap { snapshot?.thread($0)?.webURL }
            ?? item.check.flatMap { snapshot?.check($0)?.detailsURL }
            ?? snapshot?.summary.webURL
        if let url { Task { await model.send(.openURL(url)) } }
    }
}

/// The task handling an attention item.
struct LinkedTaskCard: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        let (reason, _, tone, _, _) = PopoverDerivation.describe(record, now: model.now)
        HStack(spacing: 10) {
            Image(systemName: record.task.state.symbolName)
                .font(.title3)
                .foregroundStyle(Theme.color(record.task.state.tone))
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Task \(record.id.rawValue)")
                        .font(.callout.monospaced().weight(.semibold))
                    Chip(text: record.task.state.displayName, tone: record.task.state.tone)
                    Text(record.task.type.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(tone == .critical ? Theme.critical : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Open Task") { model.showTask(record.id) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.tint(record.task.state.tone)))
        .accessibilityElement(children: .combine)
    }
}

/// A check with status, metadata and its on-demand CI log excerpt.
struct CheckDetail: View {
    let model: AppModel
    let check: CheckRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CheckStatusIcon(status: check.status)
                Text(check.name)
                    .font(.callout.weight(.semibold))
                Chip(text: check.status.displayName, tone: CheckStatusIcon.tone(check.status))
                if check.isRequired == true { Chip(text: "Required") }
                Spacer()
                if let url = check.detailsURL {
                    Button("Open Log") { Task { await model.send(.openURL(url)) } }
                        .buttonStyle(.link)
                }
            }
            if let summary = check.summary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                if let completed = check.completedAt {
                    Label("Finished \(UIFormat.relative(from: completed, now: model.now))", systemImage: "clock")
                }
                if let sha = check.commitSHA {
                    Label(UIFormat.shortSHA(sha), systemImage: "number")
                        .font(.caption.monospaced())
                }
                if let started = check.startedAt, let completed = check.completedAt {
                    Label(UIFormat.duration(from: started, to: completed), systemImage: "timer")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if check.status.isFailing {
                if let excerpt = model.logExcerpts[check.key.id] {
                    LogExcerptView(excerpt: excerpt)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading log excerpt…").font(.callout).foregroundStyle(.secondary)
                    }
                    .task { await model.loadLog(for: check.key) }
                }
            }
        }
    }
}

struct CheckStatusIcon: View {
    var status: CheckStatus

    var body: some View {
        Image(systemName: Self.symbol(status))
            .foregroundStyle(Theme.color(Self.tone(status)))
            .accessibilityLabel(status.displayName)
    }

    static func symbol(_ status: CheckStatus) -> String {
        switch status {
        case .success: "checkmark.circle.fill"
        case .failure, .timedOut: "xmark.circle.fill"
        case .actionRequired: "exclamationmark.circle.fill"
        case .inProgress: "circle.dotted.circle"
        case .queued: "clock"
        case .cancelled, .skipped, .stale: "minus.circle"
        case .neutral, .unknown: "circle"
        }
    }

    static func tone(_ status: CheckStatus) -> Tone {
        if status.isFailing { return .critical }
        if status == .success { return .success }
        if status.isPending { return .progress }
        return .neutral
    }
}
