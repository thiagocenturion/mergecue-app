import MergeCueCore
import SwiftUI

/// Right column of the Inbox: the change request panel focused on the selected item.
struct InboxDetail: View {
    let model: AppModel

    var body: some View {
        Group {
            if let item = model.attentionItem(model.selectedAttentionID) {
                ChangeRequestPanel(model: model, changeRequest: item.changeRequest, focus: item)
                    .id(item.id)
            } else {
                NothingSelected(title: "Select an item", symbol: "tray",
                                message: "Pick an item to see its conversation, code context, checks and actions.")
                    .cardBackground(Theme.panel, radius: 16)
            }
        }
        .padding(.top, MainWindowMetrics.contentTopInset - 6)
        .padding(.bottom, 14)
        .padding(.trailing, 14)
    }
}

extension Theme {
    /// The large rounded detail panel (right column).
    static let panel = Palette.panel.color
}

/// The task that handles an attention item.
struct LinkedTaskCard: View {
    let model: AppModel
    let record: TaskRecord

    var body: some View {
        let color = TaskStateStyle.color(record)
        let headline = Presentation.taskHeadline(record, snapshot: model.snapshot(record.task.origin.changeRequest), now: model.now)
        HStack(spacing: 12) {
            Image(systemName: record.task.state.symbolName)
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(Circle().fill(color.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(headline)
                        .scaledFont(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    StatusPill(text: TaskStateStyle.label(record), color: color, textColor: TaskStateStyle.textColor(record), size: 11)
                }
                Text("Task \(record.id.rawValue) · \(record.task.type.displayName) · updated \(UIFormat.relative(from: record.task.updatedAt, now: model.now))")
                    .scaledFont(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open task") { model.showTask(record.id) }
                .buttonStyle(SecondaryButtonStyle(size: .small))
        }
        .padding(12)
        .cardBackground(color.opacity(0.07), border: color.opacity(0.3))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task \(record.id.rawValue), \(TaskStateStyle.label(record)): \(headline)")
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
                    .scaledFont(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                StatusPill(text: check.status.displayName, color: Theme.color(CheckStatusIcon.tone(check.status)), textColor: Theme.textColor(CheckStatusIcon.tone(check.status)), size: 11)
                if check.isRequired == true { Chip(text: "Required") }
                Spacer()
                if let url = check.detailsURL {
                    Button {
                        Task { await model.send(.openURL(url)) }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Open log")
                            Image(systemName: "arrow.up.right.square").scaledFont(.system(size: 11))
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                }
            }
            if let summary = check.summary {
                Text(summary)
                    .scaledFont(Theme.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 14) {
                if let completed = check.completedAt {
                    Label("Finished \(UIFormat.relative(from: completed, now: model.now))", systemImage: "clock")
                }
                if let sha = check.commitSHA {
                    Label(UIFormat.shortSHA(sha), systemImage: "number")
                        .scaledFont(Theme.monoSmall)
                }
                if let started = check.startedAt, let completed = check.completedAt {
                    Label(UIFormat.duration(from: started, to: completed), systemImage: "timer")
                }
            }
            .scaledFont(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            if check.status.isFailing {
                if let excerpt = model.logExcerpts[check.key.id] {
                    LogExcerptView(excerpt: excerpt)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading log excerpt…").scaledFont(Theme.body).foregroundStyle(Theme.textSecondary)
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
