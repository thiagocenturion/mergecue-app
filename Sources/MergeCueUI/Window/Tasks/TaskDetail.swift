import MergeCueCore
import SwiftUI

/// Task detail. `ready_for_review` opens the focused result review; every other state uses the handoff layout
/// (exact comment + real context on the left, the state's panel with the 4-step tracker on the right).
struct TaskDetailScreen: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        if record.state == .readyForReview {
            TaskReviewScreen(model: model, record: record)
        } else {
            TaskHandoffScreen(model: model, record: record)
        }
    }
}

/// "‹" back to the task list.
struct BackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainRowButtonStyle())
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to tasks (⌘[)")
        .accessibilityLabel("Back to tasks")
    }
}

/// Lifecycle actions of a task (retry, unblock, reopen, cancel, dismiss, show PR).
struct TaskActionsMenu: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        let task = record.task
        Menu {
            Menu("Set Status") { TaskStatusMenuItems(model: model, task: task) }
            Divider()
            if [.failed, .blocked, .stale].contains(task.state) {
                Button("Retry") { send(.retryTask(task.id)) }
            }
            if task.state == .blocked { Button("Unblock") { send(.unblockTask(task.id)) } }
            if task.state == .readyForReview { Button("Mark Done Without Changes") { send(.markTaskDone(task.id)) } }
            mergeSection
            Button("Show \(task.origin.providerKind.changeRequestAbbreviation) Details") { model.showChangeRequest(task.origin.changeRequest) }
            Button("Open in \(task.origin.providerKind.displayName)") { send(.openURL(task.origin.webURL)) }
            Divider()
            if task.state.isTerminal {
                Button("Reopen") { send(.reopenTask(task.id)) }
            } else {
                Button("Cancel Task") { send(.cancelTask(task.id)) }
                Button("Dismiss") { send(.dismissTask(task.id)) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 42, height: 42)
                .glassShape(Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Task actions")
        .accessibilityLabel("Task actions")
    }

    /// "Add Item ▸" (open items of this PR without a task) and "Merge Into ▸" (other open tasks on this PR).
    @ViewBuilder
    private var mergeSection: some View {
        let task = record.task
        let addable = TaskMerging.acceptsAttachments(task.state) ? model.addableItems(for: record) : []
        let targets = task.isTerminal ? [] : model.mergeTargets(for: record)
        if !addable.isEmpty {
            Menu("Add Item") {
                ForEach(addable) { item in
                    Button(CoveredItemsCard.menuLabel(item, snapshot: model.snapshot(item.changeRequest))) {
                        Task { await model.addConversation(item, to: task.id) }
                    }
                }
            }
        }
        if !targets.isEmpty {
            let refusal = TaskMerging.mergeAwayRefusal(task.state)
            Menu("Merge Into") {
                if let refusal { Text(refusal) }
                ForEach(targets) { target in
                    Button(model.taskMenuTitle(target)) { send(.mergeTask(task.id, into: target.id)) }
                        .disabled(refusal != nil)
                }
            }
        }
        if !addable.isEmpty || !targets.isEmpty { Divider() }
    }

    private func send(_ command: AppCommand) {
        Task { await model.send(command) }
    }
}

/// Task created → Waiting for agent → AI working → Ready for review.
struct HandoffTracker: View {
    let current: Presentation.HandoffStep
    /// Colour of the current step (amber when stalled or blocked, red when failed).
    var currentColor: Color = Theme.mint
    var currentLabel: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Presentation.HandoffStep.allCases, id: \.self) { step in
                VStack(spacing: 12) {
                    HStack(spacing: 0) {
                        connector(visible: step != .created, done: step <= current)
                        node(step)
                        connector(visible: step != .ready, done: step < current)
                    }
                    Text(step == current ? (currentLabel ?? step.title) : step.title)
                        .scaledFont(.system(size: 13, weight: step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? Theme.textPrimary : Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress: \(currentLabel ?? current.title), step \(current.rawValue + 1) of 4")
    }

    @ViewBuilder
    private func node(_ step: Presentation.HandoffStep) -> some View {
        if step < current {
            Image(systemName: "checkmark")
                .scaledFont(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.surfaceRaised))
                .overlay(Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.5))
        } else if step == current {
            Circle()
                .fill(currentColor)
                .frame(width: 16, height: 16)
                .pulsing()
                .padding(4)
                .overlay(Circle().strokeBorder(currentColor.opacity(0.9), lineWidth: 2))
                .shadow(color: currentColor.opacity(0.6), radius: 8)
                .frame(width: 26, height: 26)
        } else {
            Circle()
                .strokeBorder(Theme.textTertiary.opacity(0.8), lineWidth: 1.5)
                .frame(width: 26, height: 26)
        }
    }

    private func connector(visible: Bool, done: Bool) -> some View {
        Rectangle()
            .fill(visible ? (done ? AnyShapeStyle(LinearGradient(colors: [Theme.textTertiary, currentColor], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Theme.divider)) : AnyShapeStyle(Color.clear))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }
}

/// Circled step number ("1").
struct StepNumber: View {
    var text: String
    var color: Color = Theme.blue

    var body: some View {
        Text(text)
            .scaledFont(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)], startPoint: .top, endPoint: .bottom)))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: color.opacity(0.45), radius: 10)
            .accessibilityHidden(true)
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
                    .scaledFont(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(color.opacity(0.14)))
                if !isLast {
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(activity.actorName ?? activity.actor.rawValue.capitalized)
                        .scaledFont(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let to = activity.toState, activity.fromState != to {
                        Chip(text: to.displayName, tone: to.tone)
                    }
                    Spacer(minLength: 4)
                    Text(UIFormat.relative(from: activity.at, now: now))
                        .scaledFont(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .help(UIFormat.dateTime(activity.at))
                }
                Text(activity.message)
                    .scaledFont(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
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
        case .agent: Theme.violet
        case .user: Theme.cyan
        case .system: Theme.textSecondary
        }
    }
}

/// The append-only activity history (popover from the timeline column, card in the handoff screen).
struct ActivityLog: View {
    let record: TaskRecord
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(record.activities.reversed().enumerated()), id: \.element.id) { index, activity in
                TimelineRow(activity: activity, now: now, isLast: index == record.activities.count - 1)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .scaledFont(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.color(tone))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .scaledFont(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(message)
                        .scaledFont(Theme.body)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) { actions }
                .padding(.leading, 36)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: Theme.color(tone))
    }
}

/// Full test output of the task's `test_run` artifact.
struct TestRunDetail: View {
    let artifact: Artifact
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text(artifact.metadata["command"] ?? artifact.title)
                    .scaledFont(Theme.mono)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                Spacer()
                if let passed = artifact.metadata["passed"] { Label("\(passed) passed", systemImage: "checkmark.circle").foregroundStyle(Theme.mintText) }
                if let failed = artifact.metadata["failed"] {
                    Label("\(failed) failed", systemImage: "xmark.circle").foregroundStyle(failed == "0" ? Theme.textSecondary : Theme.critical)
                }
                if let duration = artifact.metadata["duration_ms"].flatMap(Double.init) {
                    Label(String(format: "%.1f s", duration / 1000), systemImage: "timer").foregroundStyle(Theme.textSecondary)
                }
            }
            .scaledFont(.system(size: 12))
            Text(artifact.reportedBy == .agent ? "Reported by the agent \(UIFormat.relative(from: artifact.createdAt, now: now))" : "Run by MergeCue")
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            LogExcerptView(excerpt: LogExcerpt(text: artifact.content, truncated: false), maxHeight: 420)
        }
    }
}

/// Setting a task's status by hand (D40): Waiting for agent, In progress, Done. Only legal moves are enabled.
enum TaskStatusChoice: CaseIterable, Identifiable {
    case waiting, inProgress, done

    var id: Self { self }

    var title: String {
        switch self {
        case .waiting: "Waiting for Agent"
        case .inProgress: "In Progress"
        case .done: "Done"
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "clock"
        case .inProgress: "hammer"
        case .done: "checkmark.circle"
        }
    }

    /// The status a task is in, for the checkmark.
    static func current(_ state: TaskState) -> TaskStatusChoice? {
        switch state {
        case .waitingForAgent: .waiting
        case .working: .inProgress
        case .done: .done
        default: nil
        }
    }

    /// The command that moves `task` here, nil when it can't (or already is).
    func command(for task: MCTask) -> AppCommand? {
        let state = task.state
        func can(_ trigger: TaskTrigger) -> Bool { TaskStateMachine.canTransition(from: state, on: trigger, by: .user) }
        switch self {
        case .waiting:
            if state.isTerminal { return can(.reopen) ? .reopenTask(task.id) : nil }
            if state == .readyForReview { return .rejectResult(task.id, note: nil) }
            if state == .blocked { return .unblockTask(task.id) }
            return can(.retry) ? .retryTask(task.id) : nil
        case .inProgress:
            return can(.startManually) ? .startTaskManually(task.id) : nil
        case .done:
            return can(.markDone) ? .markTaskDone(task.id) : nil
        }
    }
}

/// The status choices as menu buttons (status pill menu, ••• menu, task list context menu).
struct TaskStatusMenuItems: View {
    let model: AppModel
    let task: MCTask

    var body: some View {
        let current = TaskStatusChoice.current(task.state)
        ForEach(TaskStatusChoice.allCases) { choice in
            let command = choice.command(for: task)
            Button {
                if let command { Task { await model.send(command) } }
            } label: {
                Label(choice.title, systemImage: choice == current ? "checkmark" : choice.symbol)
            }
            .disabled(command == nil)
        }
    }
}

/// The task's status pill; clicking it opens the status menu.
struct TaskStatusPillMenu: View {
    let model: AppModel
    let record: TaskRecord
    var symbol: String?

    var body: some View {
        Menu {
            Section("Set Status") { TaskStatusMenuItems(model: model, task: record.task) }
        } label: {
            HStack(spacing: 6) {
                StatusPill(text: TaskStateStyle.label(record), color: TaskStateStyle.color(record), textColor: TaskStateStyle.textColor(record),
                           symbol: symbol, size: 13.5)
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change the status")
        .accessibilityLabel("Status: \(TaskStateStyle.label(record)). Change status")
    }
}
