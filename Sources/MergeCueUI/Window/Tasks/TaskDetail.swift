import MergeCueCore
import SwiftUI

/// Task detail: provenance, exact initial comment, checkout, state panel (handoff / heartbeat / blocked / review
/// gate), changed files + diff, tests, proposed reply, timeline and approvals.
struct TaskDetail: View {
    let model: AppModel

    var body: some View {
        if let record = model.task(model.selectedTaskID) {
            TaskDetailContent(model: model, record: record)
                .id(record.id)
        } else {
            NothingSelected(title: "Select a task", symbol: "checklist",
                            message: "Tasks hand review comments and CI failures to your agent and show what it reported.")
        }
    }
}

struct TaskDetailContent: View {
    let model: AppModel
    let record: TaskRecord

    private var task: MCTask { record.task }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statePanel
                if !task.trigger.quoted.isEmpty {
                    Card(task.trigger.quoted.first?.source == UntrustedText.Source.ciLog ? "Triggering log excerpt" : "Exact initial comment",
                         systemImage: "quote.bubble") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(task.trigger.quoted.enumerated()), id: \.offset) { _, quote in
                                UntrustedQuote(quote: quote, now: model.now)
                            }
                            if let anchor = task.trigger.anchor {
                                Text("\(anchor.path)\(anchor.line.map { ":\($0)" } ?? "") · captured \(UIFormat.relative(from: task.trigger.capturedAt, now: model.now)) at \(UIFormat.shortSHA(task.trigger.headSHA))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                resultCards
                HStack(alignment: .top, spacing: 16) {
                    checkoutCard
                    timelineCard
                }
                .fixedSize(horizontal: false, vertical: true)
                if !task.approvals.isEmpty { approvalsCard }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(task.id.rawValue)
                    .font(.title2.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                Chip(text: task.state.displayName, symbol: task.state.symbolName, tone: task.state.tone)
                Text(task.type.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                lifecycleMenu
            }
            HStack(spacing: 6) {
                ChangeRequestRefLabel(kind: task.origin.providerKind, repoFullPath: task.origin.changeRequestRef.repoFullPath,
                                      number: task.origin.changeRequest.number, font: .callout, glyphSize: 15)
                Text(task.origin.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                Text(provenance)
                    .foregroundStyle(.secondary)
                Button("Show \(task.origin.providerKind.changeRequestAbbreviation)") { model.showChangeRequest(task.origin.changeRequest) }
                    .buttonStyle(.link)
                Button("Open in \(task.origin.providerKind.displayName)") { Task { await model.send(.openURL(task.origin.webURL)) } }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
    }

    private var provenance: String {
        let snapshot = model.snapshot(task.origin.changeRequest)
        var source = "Created \(UIFormat.relative(from: task.createdAt, now: model.now))"
        if let thread = task.origin.thread.flatMap({ snapshot?.thread($0) }), let root = thread.rootComment {
            source += " from @\(root.author.username)'s \(root.kind == .suggestion ? "code suggestion" : root.kind == .question ? "question" : "comment")"
        } else if let check = task.origin.check.flatMap({ snapshot?.check($0) }) {
            source += " from the failed check \(check.name)"
        }
        if task.origin.ruleID != nil { source += " by a rule" }
        return source + " · updated \(UIFormat.relative(from: task.updatedAt, now: model.now)) · v\(task.version)"
    }

    private var lifecycleMenu: some View {
        Menu {
            if [.failed, .blocked, .stale].contains(task.state) {
                Button("Retry") { send(.retryTask(task.id)) }
            }
            if task.state == .blocked { Button("Unblock") { send(.unblockTask(task.id)) } }
            if task.state.isTerminal {
                Button("Reopen") { send(.reopenTask(task.id)) }
            } else {
                Button("Cancel Task") { send(.cancelTask(task.id)) }
                Button("Dismiss") { send(.dismissTask(task.id)) }
            }
        } label: {
            Label("Task Actions", systemImage: "ellipsis.circle")
        }
        .fixedSize()
    }

    private func send(_ command: AppCommand) {
        Task { await model.send(command) }
    }

    // MARK: State panel

    @ViewBuilder
    private var statePanel: some View {
        switch task.state {
        case .waitingForAgent:
            HandoffPanel(model: model, record: record, title: "Awaiting agent connection",
                         message: "No agent has claimed this task yet. Hand it over with the command below; the status changes only when your agent calls claim_task through MergeCue MCP.")
        case .stale:
            VStack(alignment: .leading, spacing: 12) {
                StatusCallout(tone: .attention, symbol: "exclamationmark.triangle.fill",
                              title: "No heartbeat from \(task.lease?.agentName ?? "the agent") for \(UIFormat.duration(from: task.lease?.heartbeatAt ?? task.updatedAt, to: model.now))",
                              message: "The lease expired, so the task is stale — never done. The agent can claim it again, or you can put it back in the queue.") {
                    Button("Retry") { send(.retryTask(task.id)) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button("Cancel Task") { send(.cancelTask(task.id)) }
                }
                HandoffPanel(model: model, record: record, title: "Hand it over again", message: nil)
            }
        case .working:
            WorkingPanel(model: model, record: record)
        case .readyForReview:
            ReviewGatePanel(model: model, record: record)
        case .approvedAction:
            StatusCallout(tone: .progress, symbol: "arrow.triangle.2.circlepath", title: "Performing the approved action…",
                          message: "MergeCue re-checks the remote state right before writing.") { EmptyView() }
        case .blocked:
            StatusCallout(tone: .attention, symbol: "lock.fill", title: task.checkout?.blockedReason ?? "Blocked",
                          message: blockedMessage) {
                Button("Map a Checkout…") { model.showSettings(.repositories) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Unblock") { send(.unblockTask(task.id)) }
                Button("Cancel Task") { send(.cancelTask(task.id)) }
            }
        case .failed:
            StatusCallout(tone: .critical, symbol: "xmark.octagon.fill", title: "The agent reported a failure",
                          message: task.lastError.map { "\($0.message)\($0.retryable ? " · retryable" : "")" } ?? "No details were reported.") {
                Button("Retry") { send(.retryTask(task.id)) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Dismiss") { send(.dismissTask(task.id)) }
            }
        case .done, .cancelled, .dismissed:
            StatusCallout(tone: task.state == .done ? .success : .neutral, symbol: task.state.symbolName, title: task.state.displayName,
                          message: task.resultSummary ?? "This task is finished. Reopen it to hand it to an agent again.") {
                Button("Reopen") { send(.reopenTask(task.id)) }
            }
        }
    }

    private var blockedMessage: String {
        guard var detail = record.activities.last(where: { $0.kind == .blocked })?.message else {
            return "Code edits need a safe checkout. The agent can still inspect and draft."
        }
        // The activity repeats the headline ("Blocked: map a safe checkout — …"); show only the explanation.
        if let title = task.checkout?.blockedReason, detail.hasPrefix(title) {
            detail = String(detail.dropFirst(title.count)).trimmingCharacters(in: CharacterSet(charactersIn: " —-:"))
        }
        return detail.prefix(1).uppercased() + detail.dropFirst()
    }

    // MARK: Results

    @ViewBuilder
    private var resultCards: some View {
        if let diff = record.artifact(.diff) {
            let files = DiffParser.parse(diff.content)
            Card("Changed files · \(files.count)", systemImage: "doc.on.doc",
                 trailing: AnyView(Text(diff.reportedBy == .system ? "Recomputed by MergeCue from the worktree" : "Reported by the agent")
                    .font(.caption).foregroundStyle(.secondary))) {
                VStack(alignment: .leading, spacing: 10) {
                    ChangedFileList(files: files.map { ChangedFile(path: $0.path, status: .modified, additions: $0.additions, deletions: $0.deletions) })
                    DiffView(diff: diff.content)
                }
            }
        }
        if let tests = record.artifact(.testRun) {
            TestRunCard(artifact: tests, now: model.now)
        }
        if let reply = task.proposedReply {
            Card("Proposed reply", systemImage: "arrowshape.turn.up.left") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(reply)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Color(nsColor: .textBackgroundColor)))
                    Text("Nothing is posted until you approve a preview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if task.state == .working, let changes = record.activities.last(where: { $0.kind == .changesReported }) {
            Card("Changes reported so far", systemImage: "doc.badge.ellipsis") {
                Text(changes.data["changed_paths"] ?? changes.message)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Checkout and timeline

    private var checkoutCard: some View {
        Card("Checkout", systemImage: "folder") {
            VStack(alignment: .leading, spacing: 6) {
                if let checkout = task.checkout {
                    row("Policy", policyText(checkout.policy))
                    row("Mapped checkout", checkout.mappedCheckoutPath ?? "—", mono: true)
                    row("Worktree", checkout.worktreePath ?? "Created when an agent claims the task", mono: checkout.worktreePath != nil)
                    row("Branches", "\(checkout.sourceBranch) → \(checkout.targetBranch)", mono: true)
                    row("Base", UIFormat.shortSHA(checkout.baseSHA), mono: true)
                    if checkout.isGitButlerManaged {
                        Label("GitButler workspace — never edited directly", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.attention)
                    }
                    if let reason = checkout.blockedReason, task.state != .blocked {
                        Text(reason).font(.caption).foregroundStyle(Theme.attention)
                    }
                } else {
                    Text("No checkout prepared").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 340)
    }

    private func policyText(_ policy: CheckoutPolicy) -> String {
        switch policy {
        case .isolatedWorktree: "Isolated worktree"
        case .readOnly: "Read-only (inspect and draft)"
        case .blocked: "Blocked"
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(mono ? .caption.monospaced() : .callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var timelineCard: some View {
        Card("Timeline", systemImage: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(record.activities.reversed().enumerated()), id: \.element.id) { index, activity in
                    TimelineRow(activity: activity, now: model.now, isLast: index == record.activities.count - 1)
                }
            }
        }
    }

    private var approvalsCard: some View {
        Card("Approvals", systemImage: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(task.approvals, id: \.id) { approval in
                    HStack(spacing: 8) {
                        Image(systemName: approval.decision == .approved ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(approval.decision == .approved ? Theme.mint : Color.secondary)
                        Text("\(approval.decision == .approved ? "Approved" : "Declined") \(approval.action.displayName)")
                            .font(.callout)
                        Spacer()
                        Text(UIFormat.relative(from: approval.decidedAt, now: model.now))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(approval.previewFingerprint.prefix(10)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct TimelineRow: View {
    let activity: TaskActivity
    let now: Date
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(color.opacity(0.14)))
                if !isLast {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(activity.actorName ?? activity.actor.rawValue.capitalized)
                        .font(.caption.weight(.semibold))
                    if let to = activity.toState, activity.fromState != to {
                        Chip(text: to.displayName, tone: to.tone)
                    }
                    Spacer(minLength: 4)
                    Text(UIFormat.relative(from: activity.at, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(UIFormat.dateTime(activity.at))
                }
                Text(activity.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 12)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch activity.actor {
        case .agent: "sparkles"
        case .user: "person.fill"
        case .system: "gearshape.fill"
        }
    }

    private var color: Color {
        switch activity.actor {
        case .agent: Theme.accent
        case .user: Theme.cyan
        case .system: .secondary
        }
    }
}

struct TestRunCard: View {
    let artifact: Artifact
    let now: Date

    var body: some View {
        let status = artifact.metadata["status"] ?? "unknown"
        let tone: Tone = status == "passed" ? .success : (status == "failed" || status == "error" ? .critical : .neutral)
        Card("Tests", systemImage: "testtube.2", trailing: AnyView(Chip(text: status.capitalized, tone: tone))) {
            VStack(alignment: .leading, spacing: 8) {
                Text(artifact.metadata["command"] ?? artifact.title)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    if let passed = artifact.metadata["passed"] { Label("\(passed) passed", systemImage: "checkmark.circle").foregroundStyle(Theme.mint) }
                    if let failed = artifact.metadata["failed"] {
                        Label("\(failed) failed", systemImage: "xmark.circle").foregroundStyle(failed == "0" ? Color.secondary : Theme.critical)
                    }
                    if let skipped = artifact.metadata["skipped"] { Label("\(skipped) skipped", systemImage: "forward") }
                    if let duration = artifact.metadata["duration_ms"].flatMap(Double.init) {
                        Label(String(format: "%.1f s", duration / 1000), systemImage: "timer")
                    }
                    Text(artifact.reportedBy == .agent ? "Reported by the agent" : "Run by MergeCue")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                LogExcerptView(excerpt: LogExcerpt(text: artifact.content, truncated: false), maxHeight: 180)
            }
        }
    }
}

/// A colored callout with a title, message and action buttons.
struct StatusCallout<Actions: View>: View {
    var tone: Tone
    var symbol: String
    var title: String
    var message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Theme.color(tone))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) { actions }
                .padding(.leading, 34)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.tint(tone)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.color(tone).opacity(0.25)))
    }
}
