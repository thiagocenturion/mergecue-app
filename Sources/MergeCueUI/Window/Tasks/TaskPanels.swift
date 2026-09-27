import MergeCueCore
import SwiftUI

/// Copy command / Open in agent, with the exact handoff text.
struct HandoffPanel: View {
    let model: AppModel
    let record: TaskRecord
    var title: String
    var message: String?

    var body: some View {
        let command = HandoffText.command(for: record.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(title).font(.headline)
                Spacer()
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Handoff command: \(command)")
            HStack(spacing: 8) {
                Button {
                    Task { await model.send(.copyHandoffCommand(record.id, agent: model.preferredAgent?.kind)) }
                } label: {
                    Label("Copy Command", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                ForEach(model.state.agents) { agent in
                    Button {
                        Task { await model.send(.openInAgent(record.id, agent: agent.kind)) }
                    } label: {
                        Label("Open in \(agent.name)", systemImage: "terminal")
                    }
                    .disabled(!agent.canOpenTasks)
                    .help(agent.canOpenTasks ? "Opens \(agent.name) in the task checkout" : "Not verified for \(agent.name) yet — use Copy Command")
                }
                Spacer()
            }
            if let agent = model.preferredAgent {
                Label(agent.mcpRegistration.isVerified
                      ? "\(agent.name) has MergeCue MCP registered and verified."
                      : "\(agent.name): \(agent.mcpRegistration.displayText). Set it up in Settings › Agents.",
                      systemImage: agent.mcpRegistration.isVerified ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(agent.mcpRegistration.isVerified ? Color.secondary : Theme.attention)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.accent.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.accent.opacity(0.22)))
    }
}

/// Live agent status: who holds the lease, last heartbeat, latest progress.
struct WorkingPanel: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        let task = record.task
        let lease = task.lease
        let heartbeatAge = lease.map { model.now.timeIntervalSince($0.heartbeatAt) } ?? .infinity
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Theme.brandGradient)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(lease?.agentName ?? "The agent") is working")
                        .font(.headline)
                    if let lease {
                        Text("Last heartbeat \(UIFormat.relative(from: lease.heartbeatAt, now: model.now)) · lease expires \(UIFormat.time(lease.expiresAt))\(lease.runID.map { " · run \($0)" } ?? "")")
                            .font(.callout)
                            .foregroundStyle(heartbeatAge > 300 ? Theme.attention : Color.secondary)
                    }
                }
                Spacer()
                Button("Cancel Task") { Task { await model.send(.cancelTask(task.id)) } }
            }
            if let progress = record.latestProgress {
                HStack(spacing: 8) {
                    if let phase = progress.data["phase"] {
                        Chip(text: phase.capitalized, tone: .progress)
                    }
                    Text(progress.message)
                        .font(.callout)
                    Spacer()
                    Text(UIFormat.relative(from: progress.at, now: model.now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            PhaseTrack(current: record.latestProgress?.data["phase"])
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.accent.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.accent.opacity(0.22)))
    }
}

/// investigating → planning → editing → testing → finalizing (as reported by the agent; not a progress estimate).
struct PhaseTrack: View {
    var current: String?
    private let phases = ["investigating", "planning", "editing", "testing", "finalizing"]

    var body: some View {
        let index = current.flatMap { phases.firstIndex(of: $0) } ?? -1
        HStack(spacing: 4) {
            ForEach(Array(phases.enumerated()), id: \.offset) { offset, phase in
                VStack(alignment: .leading, spacing: 3) {
                    Capsule()
                        .fill(offset <= index ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.2)))
                        .frame(height: 4)
                    Text(phase.capitalized)
                        .font(.caption2)
                        .foregroundStyle(offset == index ? Color.primary : Color.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reported phase: \(current ?? "none")")
    }
}

/// The review gate: explicit next actions with previews (Apply patch, Post reply, Resolve thread), Mark done,
/// Discard and retry.
struct ReviewGatePanel: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        let task = record.task
        let hasDiff = record.artifact(.diff) != nil
        let hasReply = task.proposedReply != nil && task.origin.thread != nil
        let hasThread = task.origin.thread != nil
        let done = Set(task.approvals.filter { $0.decision == .approved }.map(\.action))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.mint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready for your review").font(.headline)
                    if let summary = task.resultSummary {
                        Text(summary)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(task.knownRisks, id: \.self) { risk in
                        Label(risk, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.attention)
                    }
                }
            }
            HStack(spacing: 8) {
                if hasDiff {
                    gateButton(.applyPatch, title: "Apply Patch…", symbol: "square.and.arrow.down", prominent: !done.contains(.applyPatch), done: done)
                }
                if hasReply {
                    gateButton(.postReply, title: "Post Reply…", symbol: "arrowshape.turn.up.left", prominent: false, done: done)
                }
                if hasThread {
                    gateButton(.resolveThread, title: "Resolve Thread…", symbol: "checkmark.bubble", prominent: false, done: done)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Mark Done") { Task { await model.send(.markTaskDone(task.id)) } }
                    .help("Close the task without any remote action")
                Button("Discard and Retry") { Task { await model.send(.rejectResult(task.id, note: nil)) } }
                    .help("Reject this result and put the task back in the queue for an agent")
                Spacer(minLength: 0)
            }
            Text("Each action opens a preview of exactly what will change or be posted. Nothing leaves your Mac without your approval.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.mint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.mint.opacity(0.3)))
    }

    @ViewBuilder
    private func gateButton(_ kind: RemoteActionKind, title: String, symbol: String, prominent: Bool, done: Set<RemoteActionKind>) -> some View {
        let button = Button {
            Task { await model.send(.requestActionPreview(record.id, kind)) }
        } label: {
            Label(done.contains(kind) ? "\(kind.displayName) ✓" : title, systemImage: symbol)
                .lineLimit(1)
                .fixedSize()
        }
        .disabled(done.contains(kind))
        if prominent {
            button.buttonStyle(.borderedProminent).tint(Theme.accent)
        } else {
            button
        }
    }
}

/// Shows exactly what an approval will do, with warnings and the reason it cannot be approved (if any).
struct ApprovalSheet: View {
    let model: AppModel
    let preview: ActionPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.title)
                        .font(.title3.weight(.semibold))
                    Text(preview.target)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if preview.action == .applyPatch {
                ScrollView {
                    DiffView(diff: preview.body)
                }
                .frame(maxHeight: 320)
            } else {
                Text(preview.body)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(preview.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let reason = preview.blockedReason {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Theme.critical)
                    Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if reason.contains("Settings") {
                        Button("Open Settings") {
                            dismiss()
                            model.pendingPreview = nil
                            model.showSettings(.accounts)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(Theme.critical.opacity(0.1)))
            }
            HStack {
                Text("Fingerprint \(String(preview.fingerprint.prefix(12)))…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .help("Your approval applies to exactly this content.")
                Spacer()
                Button("Decline") {
                    Task { await model.send(.declinePreview(preview)) }
                }
                Button("Cancel", role: .cancel) {
                    model.pendingPreview = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Approve \(preview.action.displayName)") {
                    Task { await model.send(.approvePreview(preview)) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!preview.canApprove)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private var symbol: String {
        switch preview.action {
        case .applyPatch: "square.and.arrow.down"
        case .postReply: "arrowshape.turn.up.left"
        case .resolveThread: "checkmark.bubble"
        case .requestChanges: "exclamationmark.bubble"
        case .commitAndPush: "arrow.up.circle"
        case .merge: "arrow.triangle.merge"
        }
    }
}
