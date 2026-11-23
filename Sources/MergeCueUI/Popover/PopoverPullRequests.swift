import MergeCueCore
import SwiftUI

/// The popover's two views (D48): the Inbox sections, or the open pull/merge requests with their status.
public enum PopoverTab: String, Sendable, Hashable, CaseIterable, Identifiable {
    case inbox, pullRequests

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .pullRequests: "PRs"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .pullRequests: "arrow.triangle.pull"
        }
    }
}

/// The small tab bar at the top right of the popover.
struct PopoverTabBar: View {
    @Bindable var model: AppModel
    @SwiftUI.Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PopoverTab.allCases) { tab in
                let isSelected = model.popoverTab == tab
                Button {
                    withAnimation(Motion.snappy) { model.popoverTab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).scaledFont(.system(size: 11, weight: .semibold))
                        Text(tab.title).scaledFont(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        if tab == .inbox, model.needsYouCount > 0 {
                            Text("\(model.needsYouCount)")
                                .scaledFont(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                                .padding(.horizontal, 5)
                                .frame(minHeight: 16)
                                .background(Capsule().fill(isSelected ? Color.white.opacity(0.25) : Theme.surfaceRaised))
                        }
                    }
                    .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 26)
                    .background {
                        if isSelected {
                            Capsule().fill(Theme.actionGradient).matchedGeometryEffect(id: "tab", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(tab == .inbox ? "Inbox" : "Pull requests")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .glassShape(Capsule(), interactive: false, fallback: Theme.surfaceSunken)
        .fixedSize()
    }
}

/// Open pull/merge requests at a glance: yours first, then the ones you review, each with checks, approvals,
/// open threads and age. Clicking a row opens it in the app; ↗ opens it in the browser.
struct PopoverPullRequestList: View {
    let model: AppModel

    var body: some View {
        let open = model.state.changeRequests.filter { $0.summary.state == .open }
            .sorted { $0.summary.updatedAt > $1.summary.updatedAt }
        let mine = open.filter { $0.summary.involvement.contains(.authored) }
        let others = open.filter { !$0.summary.involvement.contains(.authored) }
        VStack(alignment: .leading, spacing: 18) {
            if open.isEmpty {
                NothingSelected(title: "No open pull requests", symbol: "arrow.triangle.pull",
                                message: "Pull and merge requests you author or review appear here.")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            }
            section("Your pull requests", rows: mine)
            section("Reviewing", rows: others)
        }
    }

    @ViewBuilder
    private func section(_ title: String, rows: [ChangeRequestSnapshot]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title)  ·  \(rows.count)")
                    .scaledFont(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(rows.enumerated()), id: \.element.key.id) { index, snapshot in
                    PopoverPullRequestRow(model: model, snapshot: snapshot)
                        .appearStaggered(index)
                }
            }
        }
    }
}

struct PopoverPullRequestRow: View {
    let model: AppModel
    let snapshot: ChangeRequestSnapshot
    @State private var isHovering = false

    var body: some View {
        let summary = snapshot.summary
        let approval = model.approvalSummary(summary.key)
        HStack(spacing: 10) {
            Button {
                model.openChangeRequestFromPopover(summary.key)
            } label: {
                HStack(spacing: 10) {
                    ProviderBadge(kind: summary.key.kind, size: 30, style: .circle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(UIFormat.untrustedDisplay(summary.title))
                            .scaledFont(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(summary.repository.fullPath) \(summary.key.kind.formattedNumber(summary.key.number)) · \(UIFormat.compactAge(from: summary.updatedAt, now: model.now))")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if summary.isDraft { Text("Draft").foregroundStyle(Theme.textTertiary) }
                        }
                        .scaledFont(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .help("Open in MergeCue")
            .layoutPriority(1)
            HStack(spacing: 6) {
                ChecksBadge(state: snapshot.aggregateCheckState)
                    .labelStyle(.iconOnly)
                if let approval {
                    ApprovalChip(text: approval.short, isNew: approval.isNew, compact: true)
                } else if let required = snapshot.approvals.requiredCount {
                    Label("0/\(required)", systemImage: "hand.thumbsup")
                        .scaledFont(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                if snapshot.unresolvedThreadCount > 0 {
                    Label("\(snapshot.unresolvedThreadCount)", systemImage: "bubble.left")
                        .scaledFont(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("\(snapshot.unresolvedThreadCount) unresolved threads")
                }
            }
            .labelStyle(.titleAndIcon)
            .fixedSize()
            Button {
                Task { await model.send(.openURL(summary.webURL)) }
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(IconButtonStyle(size: 24, filled: false))
            .help("Open in \(summary.key.kind.displayName)")
            .accessibilityLabel("Open in \(summary.key.kind.displayName)")
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 9)
        .selectableGlass(isSelected: false, isHovering: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }
}
