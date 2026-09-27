import MergeCueCore
import SwiftUI

/// Tasks grouped by what they need: ready for review, a decision, active, finished.
struct TaskList: View {
    @Bindable var model: AppModel

    var body: some View {
        let groups = TaskGroup.allCases.map { group in
            (group, model.state.tasks.filter { TaskGroup.group(for: $0.task.state) == group }.sorted { $0.task.updatedAt > $1.task.updatedAt })
        }
        VStack(spacing: 0) {
            HStack {
                Text("Tasks")
                    .font(.headline)
                Spacer()
                Text("\(model.state.tasks.filter { !$0.task.isTerminal }.count) active")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            if model.state.tasks.isEmpty {
                NothingSelected(title: "No tasks yet", symbol: "sparkles",
                                message: "Use Fix with AI, Investigate with AI, Draft reply or Address with AI on an inbox item to create one.")
            } else {
                List(selection: $model.selectedTaskID) {
                    ForEach(groups, id: \.0) { group, records in
                        if !records.isEmpty {
                            Section(group.title) {
                                ForEach(records) { record in
                                    TaskRow(model: model, record: record)
                                        .tag(record.id as TaskID?)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle("Tasks")
    }
}

struct TaskRow: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        let task = record.task
        let (reason, _, tone, _, _) = PopoverDerivation.describe(record, now: model.now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: task.state.symbolName)
                    .foregroundStyle(Theme.color(task.state.tone))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(task.id.rawValue)
                    .font(.callout.monospaced().weight(.semibold))
                Text(task.type.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(UIFormat.compactAge(from: task.updatedAt, now: model.now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            ChangeRequestRefLabel(kind: task.origin.providerKind, repoFullPath: task.origin.changeRequestRef.repoFullPath,
                                  number: task.origin.changeRequest.number, font: .caption, glyphSize: 12)
                .padding(.leading, 22)
            Text(reason)
                .font(.caption)
                .foregroundStyle(tone == .critical ? Theme.critical : Color.secondary)
                .lineLimit(2)
                .padding(.leading, 22)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Task \(task.id.rawValue), \(task.type.displayName), \(task.state.displayName). \(reason)")
    }
}
