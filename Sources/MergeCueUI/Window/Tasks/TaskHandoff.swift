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
                let wide = availableWidth >= 1_000
                HStack(alignment: .top, spacing: 18) {
                    leftColumn.frame(width: wide ? 320 : 300)
                    TaskStatePanel(model: model, record: record, wide: wide)
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 28)
            .padding(.top, MainWindowMetrics.contentTopInset - 8)
            .padding(.bottom, 24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 56 } action: { availableWidth = $0 }
        .background(Theme.contentBackground)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Text(Presentation.taskTitle(record, snapshot: snapshot))
                        .font(Theme.screenTitle)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                    StatusPill(text: TaskStateStyle.label(record), color: TaskStateStyle.color(record), symbol: statusSymbol, size: 13.5)
                }
                HStack(spacing: 10) {
                    ProviderGlyph(kind: task.origin.providerKind, size: 18)
                    Text("\(task.origin.providerKind.shortName)  ·  \(task.origin.changeRequestRef.repoFullPath)")
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        model.showChangeRequest(task.origin.changeRequest)
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
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                }
                .font(.system(size: 15))
            }
            Spacer(minLength: 12)
            TaskActionsMenu(model: model, record: record)
        }
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
            TriggerQuoteCard(model: model, record: record)
                .padding(.top, 14)
            Text("Context ready")
                .font(.system(size: 15, weight: .semibold))
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
                ProviderGlyph(kind: task.origin.providerKind, size: 26)
                Text(root.map { Presentation.shortName($0.author) } ?? quote?.author ?? (quote?.source == UntrustedText.Source.ciLog ? "CI log" : "Comment"))
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let date = quote?.createdAt ?? root?.createdAt {
                    Text(UIFormat.relative(from: date, now: model.now))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            if let quote {
                if quote.source == UntrustedText.Source.ciLog {
                    Text(quote.text)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                } else {
                    CommentBody(text: quote.text, font: .system(size: 14.5))
                        .padding(.leading, 36)
                }
            } else {
                Text("No comment was captured for this task.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(16)
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
                .font(.system(size: 16))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(item.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.status == .warning ? Theme.waiting : Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if item.kind == .repository, item.status == .warning {
                    Button("Map a checkout…") { model.showSettings(.repositories) }
                        .buttonStyle(PlainRowButtonStyle())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 6)
            statusIcon
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
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
                .font(.system(size: 21))
                .foregroundStyle(Color(hex: 0x0B1020), Theme.mint)
                .symbolRenderingMode(.palette)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.waiting)
        case .unavailable:
            Image(systemName: "minus.circle")
                .font(.system(size: 19))
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
            HandoffTracker(current: Presentation.handoffStep(record), currentColor: trackerColor, currentLabel: trackerLabel)
                .padding(.top, 30)
            ThemeDivider().padding(.top, 24)
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 15))
                Text(footnote)
                    .font(.system(size: 13))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 18)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(Theme.surface, radius: 16)
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
                    .font(.system(size: 13, weight: .medium))
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

/// "1 Open in your coding agent": agent picker, the exact command, Open / Copy and a terminal-style preview.
struct HandoffStepView: View {
    @Bindable var model: AppModel
    let record: TaskRecord
    var wide: Bool
    var number: String
    var title: String
    var message: String?

    private var agentKind: AgentKind { model.effectiveAgentKind }
    private var detected: AgentStatus? { model.state.agents.first { $0.kind == agentKind } }

    var body: some View {
        if wide {
            HStack(alignment: .top, spacing: 22) {
                controls
                TerminalPreview(model: model, record: record, agent: agentKind)
                    .frame(width: 250)
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                controls
                TerminalPreview(model: model, record: record, agent: agentKind)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                StepNumber(text: number)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let message {
                        Text(message)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SegmentedTrack(options: AgentKind.allCases, selection: Binding(get: { agentKind }, set: { model.selectedAgentKind = $0 }), height: 44) { kind, selected in
                HStack(spacing: 10) {
                    AgentMark(kind: kind, size: 20)
                    Text(kind.shortName)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                }
            }
            .padding(.top, 22)
            .accessibilityLabel("Coding agent")
            Text("Command")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 18)
            CommandField(command: HandoffText.command(for: record.id, handoffCode: record.task.handoffCode)) {
                Task { await model.send(.copyHandoffCommand(record.id, agent: agentKind)) }
            }
            .padding(.top, 8)
            HStack(spacing: 12) {
                Button {
                    Task { await model.send(.openInAgent(record.id, agent: agentKind)) }
                } label: {
                    HStack(spacing: 9) {
                        AgentMark(kind: agentKind, size: 16, monochrome: .white)
                        Text("Open in \(agentKind.shortName)")
                        Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .buttonStyle(GradientButtonStyle(size: .tall))
                .disabled(!(detected?.canOpenTasks ?? false))
                .help(openHelp)
                Button {
                    Task { await model.send(.copyHandoffCommand(record.id, agent: agentKind)) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy command")
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .buttonStyle(SecondaryButtonStyle(size: .tall))
            }
            .padding(.top, 16)
            agentNote
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var openHelp: String {
        guard let detected else { return "\(agentKind.shortName) wasn't found on this Mac — use Copy command" }
        return detected.canOpenTasks ? "Opens \(detected.name) in the task checkout" : "Opening \(detected.name) isn't verified yet — use Copy command"
    }

    @ViewBuilder
    private var agentNote: some View {
        if let detected {
            if !detected.mcpRegistration.isVerified {
                Label("\(detected.name): \(detected.mcpRegistration.displayText). Set it up in Settings › Agents.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.waiting)
            }
        } else {
            Label("\(agentKind.shortName) wasn't detected on this Mac. Copy the command into any MCP-capable agent.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.waiting)
        }
    }
}

/// The exact handoff command in a monospaced field with a copy button.
struct CommandField: View {
    var command: String
    var onCopy: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(command)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(IconButtonStyle(size: 28, filled: false))
            .help("Copy command")
            .accessibilityLabel("Copy command")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .cardBackground(Theme.surfaceSunken, radius: 11, border: Theme.borderStrong)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Handoff command: \(command)")
    }
}

/// A terminal-style illustration of what to run. Not live output: it lists only context MergeCue really has.
struct TerminalPreview: View {
    let model: AppModel
    let record: TaskRecord
    var agent: AgentKind

    var body: some View {
        let ready = Presentation.handoffContext(record, state: model.state).filter { $0.status == .ready }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 11, height: 11) }
                Spacer()
                Text(agent.shortName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xC9D1E0))
                Spacer()
                Color.clear.frame(width: 47, height: 1)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color(hex: 0x1A2133))
            VStack(alignment: .leading, spacing: 4) {
                line("> ", firstSentence, prompt: true)
                    .padding(.bottom, 8)
                comment("MergeCue has prepared the context")
                comment("for this task, including:")
                ForEach(ready) { comment("- \($0.title)") }
                comment("")
                comment("The agent will start working")
                comment("after you run this command.")
                HStack(spacing: 6) {
                    Text(">").foregroundStyle(Theme.cyan)
                    Rectangle().fill(Color(hex: 0xE6EAF2)).frame(width: 8, height: 15)
                }
                .padding(.top, 10)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.terminalBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
        .help("Illustration of the handoff — not live output from your agent.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the command in \(agent.shortName). Illustration, not live output.")
    }

    private var firstSentence: String {
        let command = HandoffText.command(for: record.id, handoffCode: record.task.handoffCode)
        return command.split(separator: ".").first.map(String.init) ?? command
    }

    private func line(_ prefix: String, _ text: String, prompt: Bool) -> some View {
        (Text(prefix).foregroundStyle(Theme.cyan) + Text(text).foregroundStyle(Color(hex: 0xE6EAF2)))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func comment(_ text: String) -> some View {
        Text("# " + text)
            .foregroundStyle(Color(hex: 0x98A2B6))
            .fixedSize(horizontal: false, vertical: true)
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
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let lease {
                        Text("Claimed \(UIFormat.relative(from: lease.claimedAt, now: model.now)) · last heartbeat \(UIFormat.relative(from: lease.heartbeatAt, now: model.now)) · lease until \(UIFormat.time(lease.expiresAt))\(lease.runID.map { " · \($0)" } ?? "")")
                            .font(.system(size: 13))
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
                        StatusPill(text: phase.capitalized, color: Theme.violet, size: 11.5)
                    }
                    Text(progress.message)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Spacer()
                    Text(UIFormat.relative(from: progress.at, now: model.now))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(14)
                .cardBackground(Theme.surfaceSunken, radius: 11)
            }
            PhaseTrack(current: record.latestProgress?.data["phase"])
            if let changes = record.activities.last(where: { $0.kind == .changesReported }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Changes reported so far")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(changes.data["changed_paths"] ?? changes.message)
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            DisclosureGroup {
                ActivityLog(record: record, now: model.now).padding(.top, 10)
            } label: {
                Text("Activity · \(record.activities.count)")
                    .font(.system(size: 13, weight: .medium))
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
                        .font(.system(size: 11))
                        .foregroundStyle(offset == index ? Theme.textPrimary : Theme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reported phase: \(current ?? "none")")
    }
}
