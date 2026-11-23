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

/// Open pull/merge requests at a glance: the ones you review (D53: a "3 to review · 2 waiting · 4 approved" line
/// that opens the Reviews screen, then only the ones to review; first while any need you) and yours, each with checks, approvals, open
/// threads and age. Clicking a row opens it in the app; ↗ opens it in the browser.
struct PopoverPullRequestList: View {
    let model: AppModel

    var body: some View {
        let open = model.state.changeRequests.filter { $0.summary.state == .open }
            .sorted { $0.summary.updatedAt > $1.summary.updatedAt }
        let mine = open.filter { $0.summary.involvement.contains(.authored) }
        let reviews = ReviewQueue.run(state: model.state, filter: ChangeRequestFilter(), now: model.now)
        VStack(alignment: .leading, spacing: 18) {
            if mine.isEmpty && reviews.isEmpty {
                NothingSelected(title: "No open pull requests", symbol: "arrow.triangle.pull",
                                message: "Pull and merge requests you author or review appear here.")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            }
            // Reviews that need you come first (they ask for action); otherwise yours lead (D48, D53).
            if !reviews.toReview.isEmpty { reviewSection(reviews) }
            section("Your pull requests", rows: mine)
            if reviews.toReview.isEmpty { reviewSection(reviews) }
        }
    }

    @ViewBuilder
    private func reviewSection(_ queue: ReviewQueue) -> some View {
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    model.showScreen(.reviews)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Reviews")
                            .scaledFont(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(ReviewText.summaryLine(queue))
                            .scaledFont(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .scaledFont(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Reviews")
                .accessibilityLabel("Reviews: \(ReviewText.summaryLine(queue))")
                .accessibilityHint("Opens the Reviews screen")
                ForEach(Array(queue.toReview.enumerated()), id: \.element.id) { index, entry in
                    PopoverPullRequestRow(model: model, snapshot: entry.snapshot, review: entry)
                        .appearStaggered(index)
                }
            }
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
    /// Your review state, shown as a chip under the title (Reviews section).
    var review: ReviewEntry?
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
                        if let review {
                            let chip = ReviewText.chip(review)
                            Chip(text: chip.text, symbol: chip.symbol, tone: chip.tone)
                        }
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
