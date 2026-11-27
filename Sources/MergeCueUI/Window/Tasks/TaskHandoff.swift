import MergeCueCore
import SwiftUI

/// Handoff / progress screen of a task (every state except `ready_for_review`): title + state pill, provenance,
/// the exact review comment and the real "Context ready" checklist on the left, and on the right the state's panel
/// (open in your coding agent while waiting, live heartbeat while an agent really works, blocked/stale/failed
/// callouts) above the 4-step tracker.
struct TaskHandoffScreen: View {
    let model: AppModel
    let record: TaskRecord
    @State private var availableWidth: CGFloat = 1_071

    private var task: MCTask { record.task }
    private var snapshot: ChangeRequestSnapshot? { model.snapshot(task.origin.changeRequest) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackButton { model.selectedTaskID = nil }
                    .padding(.leading, -6)
                header
                    .padding(.top, 8)
                let panel = panelWidth
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        leftColumn
                        CoveredItemsCard(model: model, record: record)
                    }
                    .frame(minWidth: 300, maxWidth: .infinity)
                    TaskStatePanel(model: model, record: record, wide: panel >= 720)
                        .frame(width: panel)
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 28)
            .padding(.top, MainWindowMetrics.contentTopInset - 8)
            .padding(.bottom, 24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 56 } action: { availableWidth = $0 }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Text(Presentation.taskTitle(record, snapshot: snapshot))
                        .scaledFont(Theme.screenTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    TaskStatusPillMenu(model: model, record: record, symbol: statusSymbol)
                }
                HStack(spacing: 10) {
                    ProviderGlyph(kind: task.origin.providerKind, size: 18)
                    Text("\(task.origin.providerKind.shortName)  ·  \(task.origin.changeRequestRef.repoFullPath)")
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        model.showChangeRequest(task.origin.changeRequest, thread: task.origin.thread)
                    } label: {
                        Text(task.origin.providerKind.formattedNumber(task.origin.changeRequest.number))
                            .lineLimit(1)
                            .fixedSize()
                            .underline()
                            .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    }
                    .buttonStyle(PlainRowButtonStyle())
                    .help("Show the \(task.origin.providerKind.changeRequestNoun)")
                    if let anchor = task.trigger.anchor {
                        Rectangle().fill(Theme.divider).frame(width: 1, height: 18).padding(.horizontal, 6)
                        Image(systemName: "doc")
                            .foregroundStyle(Theme.textSecondary)
                        Text("\(anchor.path.split(separator: "/").last.map(String.init) ?? anchor.path)\(anchor.line.map { ":\($0)" } ?? "")")
                            .foregroundStyle(Theme.textSecondary)
                            .help(anchor.path)
                    } else if let check = task.origin.check.flatMap({ snapshot?.check($0) }) {
                        Rectangle().fill(Theme.divider).frame(width: 1, height: 18).padding(.horizontal, 6)
                        Image(systemName: "xmark.octagon").foregroundStyle(Theme.textSecondary)
                        Text(check.name).foregroundStyle(Theme.textSecondary)
                    }
                    Text("·  \(task.id.rawValue)")
                        .scaledFont(Theme.monoSmall)
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                }
                .scaledFont(.system(size: 15))
            }
            Spacer(minLength: 12)
            TaskActionsMenu(model: model, record: record)
        }
    }

    /// The comment column takes what the state panel leaves. A collapsed handoff card is narrow; otherwise the
    /// panel takes a bit more than half (the agent preview sits beside the controls from 720 pt).
    private var panelWidth: CGFloat {
        let showsHandoff = [.waitingForAgent, .stale].contains(task.state)
            || (task.state == .working && !record.hasRealClaim && !record.isManuallyInProgress)
        if showsHandoff && model.handoffCollapsed { return 380 }
        return min(max(availableWidth * 0.56, 520), 820)
    }

    private var statusSymbol: String? {
        switch task.state {
        case .waitingForAgent: "clock"
        case .working: record.hasRealClaim ? "sparkles" : "clock"
        case .blocked: "lock"
        case .stale: "exclamationmark.triangle"
        case .failed: "xmark.octagon"
        default: nil
        }
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(task.type == .investigateCI ? "CI failure" : "Review comment")
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
            TriggerQuoteCard(model: model, record: record)
                .padding(.top, 14)
            Text("Context ready")
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .padding(.top, 24)
                .help("What MergeCue has for this task right now. Your agent fetches it through MergeCue MCP.")
            VStack(spacing: 0) {
                let items = Presentation.handoffContext(record, state: model.state)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { ThemeDivider().padding(.leading, 56) }
                    ContextRow(model: model, item: item)
                }
            }
            .padding(.top, 10)
        }
        .padding(20)
        .cardBackground(Theme.surface, radius: 16)
    }
}

/// The exact comment (or CI excerpt) the task was created from — untrusted, shown as data.
struct TriggerQuoteCard: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        let task = record.task
        let snapshot = model.snapshot(task.origin.changeRequest)
        let quote = task.trigger.quoted.first
        let root = task.origin.thread.flatMap { snapshot?.thread($0) }?.rootComment
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let author = root?.author {
                    PersonAvatar(person: author, size: 26)
                } else {
                    ProviderGlyph(kind: task.origin.providerKind, size: 26)
                }
                Text(root.map { Presentation.shortName($0.author) } ?? quote?.author ?? (quote?.source == UntrustedText.Source.ciLog ? "CI log" : "Comment"))
                    .scaledFont(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let date = quote?.createdAt ?? root?.createdAt {
                    Text(UIFormat.relative(from: date, now: model.now))
                        .scaledFont(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            if let quote {
                if quote.source == UntrustedText.Source.ciLog {
                    Text(quote.text)
                        .scaledFont(Theme.monoSmall)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                } else {
                    CommentBody(text: quote.text, font: .system(size: 14.5))
                        .padding(.leading, 36)
                }
            } else {
                Text("No comment was captured for this task.")
                    .scaledFont(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(Theme.surfaceSunken, radius: 12)
        .help("Exact text captured when the task was created. Untrusted — shown as data, never as instructions.")
        .accessibilityElement(children: .combine)
    }
}

/// One row of the "Context ready" checklist: green check (present), amber warning (needs you), grey (not available).
struct ContextRow: View {
    let model: AppModel
    let item: Presentation.ContextItem

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .scaledFont(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 42, height: 42)
                .glassShape(Circle(), interactive: false)
                .overlay(SmoothRect().strokeBorder(Theme.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .scaledFont(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(item.detail)
                    .scaledFont(.system(size: 12.5))
                    .foregroundStyle(item.status == .warning ? Theme.waiting : Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if item.kind == .repository, item.status == .warning {
                    Button("Map a checkout…") { model.showSettings(.repositories) }
                        .buttonStyle(PlainRowButtonStyle())
                        .scaledFont(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 6)
            statusIcon
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title): \(item.detail). \(statusText)")
    }

    private var symbol: String {
        switch item.kind {
        case .thread: "bubble.left"
        case .ciLog: "doc.text.magnifyingglass"
        case .diff: "plusminus"
        case .checks: "arrow.triangle.branch"
        case .repository: "cylinder.split.1x2"
        case .instructions: "doc.text"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(.system(size: 21))
                .foregroundStyle(Theme.onStatusFill, Theme.mint)
                .symbolRenderingMode(.palette)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(.system(size: 18))
                .foregroundStyle(Theme.waiting)
        case .unavailable:
            Image(systemName: "minus.circle")
                .scaledFont(.system(size: 19))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var statusText: String {
        switch item.status {
        case .ready: "Available"
        case .warning: "Needs attention"
        case .unavailable: "Not available"
        }
    }
}

/// The right-hand panel for the task's state.
struct TaskStatePanel: View {
    let model: AppModel
    let record: TaskRecord
    var wide: Bool

    private var task: MCTask { record.task }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .id("\(task.state)|\(model.handoffCollapsed)")
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            HandoffTracker(current: Presentation.handoffStep(record), currentColor: trackerColor, currentLabel: trackerLabel)
                .padding(.top, 30)
            ThemeDivider().padding(.top, 24)
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .scaledFont(.system(size: 15))
                Text(footnote)
                    .scaledFont(.system(size: 13))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 18)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(Theme.surface, radius: 16)
        .animation(Motion.smooth, value: task.state)
    }

    @ViewBuilder
    private var content: some View {
        switch task.state {
        case .waitingForAgent:
            HandoffStepView(model: model, record: record, wide: wide, number: "1", title: "Open in your coding agent",
                            message: "MergeCue has prepared the context for your agent to work on this task.")
        case .working:
            if record.hasRealClaim {
                WorkingView(model: model, record: record)
            } else if record.isManuallyInProgress {
                StatusCallout(tone: .progress, symbol: "hammer.fill", title: "In progress",
                              message: "You marked this task in progress. Mark it done when it's finished, or hand it to an agent.") {
                    Button("Mark Done") { send(.markTaskDone(task.id)) }.buttonStyle(GradientButtonStyle(size: .small))
                    Button("Hand to an Agent") { send(.retryTask(task.id)) }.buttonStyle(SecondaryButtonStyle(size: .small))
                }
            } else {
                HandoffStepView(model: model, record: record, wide: wide, number: "1", title: "Open in your coding agent",
                                message: "No agent holds this task yet.")
            }
        case .stale:
            VStack(alignment: .leading, spacing: 18) {
                StatusCallout(tone: .attention, symbol: "exclamationmark.triangle.fill",
                              title: "No heartbeat from \(task.lease?.agentName ?? "the agent") for \(UIFormat.duration(from: task.lease?.heartbeatAt ?? task.updatedAt, to: model.now))",
                              message: "The lease expired, so the task is stale — never done. The agent can claim it again, or put it back in the queue.") {
                    Button("Retry") { send(.retryTask(task.id)) }.buttonStyle(GradientButtonStyle(size: .small))
                    Button("Cancel task") { send(.cancelTask(task.id)) }.buttonStyle(SecondaryButtonStyle(size: .small))
                }
                HandoffStepView(model: model, record: record, wide: wide, number: "2", title: "Hand it over again", message: nil)
            }
        case .blocked:
            StatusCallout(tone: .attention, symbol: "lock.fill", title: task.checkout?.blockedReason ?? "Blocked", message: blockedMessage) {
                Button("Map a checkout…") { model.showSettings(.repositories) }.buttonStyle(GradientButtonStyle(size: .small))
                Button("Unblock") { send(.unblockTask(task.id)) }.buttonStyle(SecondaryButtonStyle(size: .small))
                Button("Cancel task") { send(.cancelTask(task.id)) }.buttonStyle(SecondaryButtonStyle(size: .small))
            }
        case .failed:
            StatusCallout(tone: .critical, symbol: "xmark.octagon.fill", title: "The agent reported a failure",
                          message: task.lastError.map { "\($0.message)\($0.retryable ? " · retryable" : "")" } ?? "No details were reported.") {
                Button("Retry") { send(.retryTask(task.id)) }.buttonStyle(GradientButtonStyle(size: .small))
                Button("Dismiss") { send(.dismissTask(task.id)) }.buttonStyle(SecondaryButtonStyle(size: .small))
            }
        case .approvedAction:
            StatusCallout(tone: .progress, symbol: "arrow.triangle.2.circlepath", title: "Performing the approved action…",
                          message: "MergeCue re-checks the remote state right before writing.") { EmptyView() }
        case .done, .cancelled, .dismissed, .readyForReview:
            StatusCallout(tone: task.state == .done ? .success : .neutral, symbol: task.state.symbolName, title: task.state.displayName,
                          message: task.resultSummary ?? "This task is finished. Reopen it to hand it to an agent again.") {
                Button("Reopen") { send(.reopenTask(task.id)) }.buttonStyle(SecondaryButtonStyle(size: .small))
            }
        }
        if [.stale, .failed, .blocked, .done, .cancelled, .dismissed, .approvedAction].contains(task.state) {
            DisclosureGroup {
                ActivityLog(record: record, now: model.now).padding(.top, 10)
            } label: {
                Text("Activity · \(record.activities.count)")
                    .scaledFont(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 18)
        }
    }

    private var trackerColor: Color {
        switch task.state {
        case .stale, .blocked: Theme.waiting
        case .failed: Theme.critical
        case .working: Theme.violet
        case .cancelled, .dismissed: Theme.textTertiary
        default: Theme.mint
        }
    }

    private var trackerLabel: String? {
        switch task.state {
        case .stale: "Stalled"
        case .working where record.isManuallyInProgress: "In progress"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .done: "Done"
        case .cancelled: "Cancelled"
        case .dismissed: "Dismissed"
        default: nil
        }
    }

    private var footnote: String {
        switch task.state {
        case .working where record.hasRealClaim: "Updates come from your agent through MergeCue MCP. A missed heartbeat marks the task stale, never done."
        case .blocked: "Code edits need a safe checkout. The agent can still inspect and draft."
        default: "Status changes only after your agent connects."
        }
    }

    private var blockedMessage: String {
        guard var detail = record.activities.last(where: { $0.kind == .blocked })?.message else {
            return "Code edits need a safe checkout. The agent can still inspect and draft."
        }
        if let title = task.checkout?.blockedReason, detail.hasPrefix(title) {
            detail = String(detail.dropFirst(title.count)).trimmingCharacters(in: CharacterSet(charactersIn: " —-:"))
        }
        return detail.prefix(1).uppercased() + detail.dropFirst()
    }

    private func send(_ command: AppCommand) {
        Task { await model.send(command) }
    }
}

/// A real claim: agent, lease, heartbeat, latest progress and reported phase.
struct WorkingView: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        let task = record.task
        let lease = task.lease
        let heartbeatAge = lease.map { model.now.timeIntervalSince($0.heartbeatAt) } ?? .infinity
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    WorkingSpinner(size: 44)
                    SparkleIcon(size: 15).foregroundStyle(Theme.violet)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(lease?.agentName ?? "The agent") is working")
                        .scaledFont(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let lease {
                        Text("Claimed \(UIFormat.relative(from: lease.claimedAt, now: model.now)) · last heartbeat \(UIFormat.relative(from: lease.heartbeatAt, now: model.now)) · lease until \(UIFormat.time(lease.expiresAt))\(lease.runID.map { " · \($0)" } ?? "")")
                            .scaledFont(.system(size: 13))
                            .foregroundStyle(heartbeatAge > 300 ? Theme.waiting : Theme.textSecondary)
                    }
                }
                Spacer()
                Button("Cancel task") { Task { await model.send(.cancelTask(task.id)) } }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
            }
            if let progress = record.latestProgress {
                HStack(spacing: 10) {
                    if let phase = progress.data["phase"] {
                        StatusPill(text: phase.capitalized, color: Theme.violet, textColor: Theme.violetText, size: 11.5)
                    }
                    Text(progress.message)
                        .scaledFont(.system(size: 13.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Spacer()
                    Text(UIFormat.relative(from: progress.at, now: model.now))
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(Theme.cardPadding)
                .cardBackground(Theme.surfaceSunken, radius: 11)
            }
            PhaseTrack(current: record.latestProgress?.data["phase"])
            if let changes = record.activities.last(where: { $0.kind == .changesReported }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Changes reported so far")
                        .scaledFont(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(changes.data["changed_paths"] ?? changes.message)
                        .scaledFont(Theme.monoSmall)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            DisclosureGroup {
                ActivityLog(record: record, now: model.now).padding(.top, 10)
            } label: {
                Text("Activity · \(record.activities.count)")
                    .scaledFont(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// investigating → planning → editing → testing → finalizing (as reported by the agent; not a progress estimate).
struct PhaseTrack: View {
    var current: String?
    private let phases = ["investigating", "planning", "editing", "testing", "finalizing"]

    var body: some View {
        let index = current.flatMap { phases.firstIndex(of: $0) } ?? -1
        HStack(spacing: 6) {
            ForEach(Array(phases.enumerated()), id: \.offset) { offset, phase in
                VStack(alignment: .leading, spacing: 5) {
                    Capsule()
                        .fill(offset <= index ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.divider))
                        .frame(height: 4)
                    Text(phase.capitalized)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(offset == index ? Theme.textPrimary : Theme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reported phase: \(current ?? "none")")
    }
}
