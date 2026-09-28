import MergeCueCore
import SwiftUI

/// Tasks grouped by what they need: ready for review, a decision, active, finished. Selecting one opens its
/// handoff / progress / review screen.
struct TaskList: View {
    @Bindable var model: AppModel

    var body: some View {
        let groups = TaskGroup.allCases.map { group in
            (group, model.state.tasks.filter { TaskGroup.group(for: $0.task.state) == group }.sorted { $0.task.updatedAt > $1.task.updatedAt })
        }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tasks")
                    .scaledFont(Theme.largeTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("\(model.state.tasks.filter { !$0.task.isTerminal }.count) active · handed to your agent through MergeCue MCP")
                    .scaledFont(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, MainWindowMetrics.contentTopInset)
            if model.state.tasks.isEmpty {
                NothingSelected(title: "No tasks yet", symbol: "sparkles",
                                message: "Use Fix with AI, Investigate, Draft reply or Address with AI on an inbox item to create one.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.0) { group, records in
                            if !records.isEmpty {
                                Text("\(group.title)  ·  \(records.count)")
                                    .scaledFont(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.top, 14)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(records) { record in
                                    TaskCard(model: model, record: record)
                                }
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
        .background(Theme.contentBackground)
    }
}

struct TaskCard: View {
    let model: AppModel
    let record: TaskRecord
    @State private var isHovering = false

    var body: some View {
        let task = record.task
        let snapshot = model.snapshot(task.origin.changeRequest)
        let color = TaskStateStyle.color(record)
        Button {
            model.selectedTaskID = task.id
        } label: {
            HStack(spacing: 16) {
                ProviderBadge(kind: task.origin.providerKind, size: 42, style: .tile)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(task.origin.providerKind.shortName) · \(task.origin.changeRequestRef.repoFullPath) \(task.origin.providerKind.formattedNumber(task.origin.changeRequest.number)) · \(task.id.rawValue)")
                        .scaledFont(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Text(Presentation.taskTitle(record, snapshot: snapshot))
                        .scaledFont(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(Presentation.taskHeadline(record, snapshot: snapshot, now: model.now))
                        .scaledFont(.system(size: 12.5))
                        .foregroundStyle(task.state == .failed ? Theme.critical : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if record.hasRealClaim { WorkingSpinner(size: 22) }
                StatusPill(text: TaskStateStyle.label(record), color: color, textColor: TaskStateStyle.textColor(record), showsDot: true, size: 11.5, cueSymbol: TaskStateStyle.symbol(record))
                Text(UIFormat.compactAge(from: task.updatedAt, now: model.now))
                    .scaledFont(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 34, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(isHovering ? Theme.surfaceHover : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(PlainRowButtonStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel("Task \(task.id.rawValue), \(Presentation.taskTitle(record, snapshot: snapshot)), \(TaskStateStyle.label(record))")
    }
}
