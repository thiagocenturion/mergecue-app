import MergeCueCore
import SwiftUI

/// Tasks ▸ Finished: done, cancelled and dismissed tasks, grouped by pull/merge request (the most recently
/// finished first), each with the day and time it finished. Hidden from the Tasks list unless asked for.
struct FinishedTaskList: View {
    @Bindable var model: AppModel

    var body: some View {
        let titles = Dictionary(
            model.state.changeRequests.map { ($0.key, $0.summary.title) }, uniquingKeysWith: { first, _ in first }
        )
        let groups = FinishedTasks.groups(model.state.tasks, titles: titles)
        let count = groups.reduce(0) { $0 + $1.records.count }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.showsFinishedTasks = false
                } label: {
                    Label("Tasks", systemImage: "chevron.left")
                        .scaledFont(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Back to open tasks")
                Text("Finished tasks")
                    .scaledFont(Theme.largeTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(count == 1 ? "1 task done, cancelled or dismissed" : "\(count) tasks done, cancelled or dismissed")
                    .scaledFont(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, MainWindowMetrics.contentTopInset)
            if groups.isEmpty {
                NothingSelected(title: "No finished tasks", symbol: "checkmark.circle",
                                message: "Tasks you mark done, cancel or dismiss show up here, grouped by pull request.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groups) { group in
                            FinishedGroupHeader(model: model, group: group)
                                .padding(.top, 14)
                            ForEach(group.records) { record in
                                FinishedTaskRow(model: model, record: record)
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 980, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "acme/payments-api #42 · Retry webhooks · 3 tasks" with a way to the PR/MR.
private struct FinishedGroupHeader: View {
    let model: AppModel
    let group: FinishedTaskGroup

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderBadge(kind: group.providerKind, size: 26, style: .tile)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .scaledFont(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(group.refText)  ·  \(group.records.count == 1 ? "1 task" : "\(group.records.count) tasks")")
                    .scaledFont(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("\(group.providerKind.changeRequestAbbreviation) Details") { model.showChangeRequest(group.changeRequest) }
                .help("Show this \(group.providerKind.changeRequestNoun) in MergeCue")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One finished task: status, title, and when it finished (day and time, plus how long ago).
private struct FinishedTaskRow: View {
    let model: AppModel
    let record: TaskRecord
    @State private var isHovering = false

    var body: some View {
        let task = record.task
        let snapshot = model.snapshot(task.origin.changeRequest)
        let finishedAt = FinishedTasks.finishedAt(record)
        Button {
            model.selectedTaskID = task.id
        } label: {
            HStack(spacing: 14) {
                StatusPill(text: TaskStateStyle.label(record), color: TaskStateStyle.color(record),
                           textColor: TaskStateStyle.textColor(record), showsDot: true, size: 11.5,
                           cueSymbol: TaskStateStyle.symbol(record))
                VStack(alignment: .leading, spacing: 4) {
                    Text(Presentation.taskTitle(record, snapshot: snapshot))
                        .scaledFont(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(task.id.rawValue)
                        .scaledFont(.system(size: 12).monospaced())
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(UIFormat.dateTime(finishedAt))
                        .scaledFont(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Text(UIFormat.relative(from: finishedAt, now: model.now))
                        .scaledFont(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.cardPadding)
            .selectableGlass(isSelected: false, isHovering: isHovering)
        }
        .buttonStyle(PlainRowButtonStyle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open") { model.selectedTaskID = task.id }
            Section("Set Status") { TaskStatusMenuItems(model: model, task: task) }
        }
        .accessibilityLabel("Task \(task.id.rawValue), \(Presentation.taskTitle(record, snapshot: snapshot)), \(TaskStateStyle.label(record)), finished \(UIFormat.dateTime(finishedAt))")
    }
}
