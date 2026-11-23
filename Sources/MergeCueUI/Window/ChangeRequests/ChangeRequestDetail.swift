import MergeCueCore
import SwiftUI

/// PR/MR detail of the Pull requests screen: the change request panel (conversation with description, reviewers
/// and every thread; files; checks with CI excerpts; timeline).
struct ChangeRequestDetail: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            if model.detailTabsEnabled == true, !model.prTabs.isEmpty {
                DetailTabBar(
                    tabs: model.prTabs.compactMap { id in
                        model.snapshot(id: id).map { DetailTab(id: id, title: $0.summary.title, providerKind: $0.key.kind) }
                    },
                    selected: model.selectedChangeRequestID,
                    onSelect: { model.selectedChangeRequestID = $0 },
                    onClose: { model.closeChangeRequestDetail($0) },
                    onDisable: { withAnimation(Motion.smooth) { model.detailTabsEnabled = false } }
                )
            } else if model.detailTabsEnabled == nil, model.selectedChangeRequestID != nil {
                DetailTabsPrompt(model: model)
            }
            ZStack {
                if let snapshot = model.snapshot(id: model.selectedChangeRequestID) {
                    ChangeRequestPanel(model: model, changeRequest: snapshot.key, focus: nil,
                                       onClose: model.detailTabsEnabled == true ? nil : { model.closeChangeRequestDetail(snapshot.id) })
                        .id(snapshot.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 18)), removal: .opacity))
                } else {
                    NothingSelected(title: "Select a pull or merge request", symbol: "arrow.triangle.pull",
                                    message: "Pick a PR/MR to see its reviews, checks and threads.")
                }
            }
            .animation(Motion.smooth, value: model.selectedChangeRequestID)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

/// Reviewers with their state and the approval rule.
struct ReviewersCard: View {
    let snapshot: ChangeRequestSnapshot

    var body: some View {
        Card("Reviewers", systemImage: "person.2") {
            VStack(alignment: .leading, spacing: 9) {
                if snapshot.reviewers.isEmpty {
                    Text("No reviewers requested").scaledFont(Theme.body).foregroundStyle(Theme.textSecondary)
                }
                ForEach(snapshot.reviewers, id: \.person.remoteID) { reviewer in
                    HStack(spacing: 10) {
                        Avatar(name: reviewer.person.displayLabel, size: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(reviewer.person.displayLabel).scaledFont(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                            Text("@" + reviewer.person.username).scaledFont(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if reviewer.isRequired == true {
                            Text("Required").scaledFont(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                        }
                        ReviewStateChip(state: reviewer.state)
                    }
                    .accessibilityElement(children: .combine)
                }
                ThemeDivider()
                Text(approvalText)
                    .scaledFont(.system(size: 12))
                    .foregroundStyle(snapshot.approvals.isSatisfied == true ? Theme.mint : Theme.textSecondary)
            }
        }
    }

    private var approvalText: String {
        let approved = snapshot.approvals.approvedBy.count
        if let required = snapshot.approvals.requiredCount {
            return "\(approved) of \(required) required approvals"
        }
        return approved == 0 ? "No approvals yet (approval rules unknown)" : "\(approved) approval\(approved == 1 ? "" : "s")"
    }
}

struct ChangedFileList: View {
    let files: [ChangedFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(files, id: \.path) { file in
                HStack(spacing: 8) {
                    Image(systemName: symbol(file.status))
                        .foregroundStyle(color(file.status))
                        .frame(width: 16)
                        .accessibilityLabel(file.status.rawValue)
                    Text(file.path)
                        .scaledFont(Theme.monoSmall)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 6)
                    if let additions = file.additions { Text("+\(additions)").foregroundStyle(Theme.mintText) }
                    if let deletions = file.deletions { Text("−\(deletions)").foregroundStyle(Theme.criticalText) }
                }
                .scaledFont(.system(size: 12, weight: .medium).monospacedDigit())
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func symbol(_ status: FileChangeStatus) -> String {
        switch status {
        case .added: "plus.square"
        case .removed: "minus.square"
        case .renamed, .copied: "arrow.right.square"
        case .modified, .unknown: "square.and.pencil"
        }
    }

    private func color(_ status: FileChangeStatus) -> Color {
        switch status {
        case .added: Theme.mint
        case .removed: Theme.critical
        default: Theme.textSecondary
        }
    }
}

struct ReviewStateChip: View {
    var state: ReviewState

    var body: some View {
        switch state {
        case .approved: Chip(text: "Approved", symbol: "checkmark", tone: .success)
        case .changesRequested: Chip(text: "Changes requested", symbol: "exclamationmark.bubble", tone: .critical)
        case .commented: Chip(text: "Commented", symbol: "text.bubble")
        case .pending: Chip(text: "Pending", symbol: "clock")
        case .dismissed: Chip(text: "Dismissed", symbol: "xmark")
        }
    }
}
