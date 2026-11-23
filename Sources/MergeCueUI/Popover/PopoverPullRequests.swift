import MergeCueCore
import SwiftUI

/// The popover's views: the Inbox sections, your open pull/merge requests (D48), and the ones you review (D54).
public enum PopoverTab: String, Sendable, Hashable, CaseIterable, Identifiable {
    case inbox, pullRequests, reviews

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .pullRequests: "PRs"
        case .reviews: "Reviews"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .pullRequests: "arrow.triangle.pull"
        case .reviews: "checkmark.bubble"
        }
    }

    var accessibilityName: String {
        switch self {
        case .inbox: "Inbox"
        case .pullRequests: "Your pull requests"
        case .reviews: "Reviews"
        }
    }
}

/// The small tab bar at the top right of the popover. Inbox counts what needs you; Reviews counts what is to review.
/// Only the selected tab shows its title (the others an icon and count, with the title as a tooltip), so three tabs
/// fit beside the brand.
struct PopoverTabBar: View {
    @Bindable var model: AppModel
    @SwiftUI.Namespace private var highlight

    var body: some View {
        let toReview = ReviewQueue.run(state: model.state, filter: ChangeRequestFilter(), now: model.now).toReview.count
        HStack(spacing: 2) {
            ForEach(PopoverTab.allCases) { tab in
                let isSelected = model.popoverTab == tab
                let count = tab == .inbox ? model.needsYouCount : tab == .reviews ? toReview : 0
                Button {
                    withAnimation(Motion.snappy) { model.popoverTab = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).scaledFont(.system(size: 11, weight: .semibold))
                        if isSelected {
                            Text(tab.title).scaledFont(.system(size: 12, weight: .semibold))
                        }
                        if count > 0 {
                            Text("\(count)")
                                .scaledFont(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                                .padding(.horizontal, 5)
                                .frame(minHeight: 16)
                                .background(Capsule().fill(isSelected ? Color.white.opacity(0.25) : Theme.surfaceRaised))
                        }
                    }
                    .foregroundStyle(isSelected ? Color.white : Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 26)
                    .background {
                        if isSelected {
                            Capsule().fill(Theme.actionGradient).matchedGeometryEffect(id: "tab", in: highlight)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScaleButtonStyle())
                .help(tab.accessibilityName)
                .accessibilityLabel(count > 0 ? "\(tab.accessibilityName), \(count)" : tab.accessibilityName)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .glassShape(Capsule(), interactive: false, fallback: Theme.surfaceSunken)
        .fixedSize()
    }
}

/// All / Mine / Reviews above the popover's Inbox sections: a quick way to see only your own PRs' activity. It is the
/// same filter as the window's Inbox chips (`inboxFilter.scope`), so switching one switches both (D54).
struct PopoverScopeChips: View {
    @Bindable var model: AppModel

    var body: some View {
        FilterChips(options: [(InboxScope.all, "All"), (.mine, "Mine"), (.reviewing, "Reviews")], selection: $model.inboxFilter.scope,
                    compact: true)
            .accessibilityLabel("Show activity from")
    }
}

/// Your own open pull/merge requests at a glance, each with checks, approvals, open threads and age. Others' PRs
/// are on the Reviews tab (D54). Clicking a row opens it in the app; ↗ opens it in the browser.
struct PopoverPullRequestList: View {
    let model: AppModel

    var body: some View {
        let mine = model.state.changeRequests
            .filter { $0.summary.state == .open && $0.summary.involvement.contains(.authored) }
            .sorted { $0.summary.updatedAt > $1.summary.updatedAt }
        VStack(alignment: .leading, spacing: 18) {
            if mine.isEmpty {
                NothingSelected(title: "No open pull requests", symbol: "arrow.triangle.pull",
                                message: "Pull and merge requests you author appear here.")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
            }
            section("Your pull requests", rows: mine)
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

/// The pull/merge requests you review (D53, D54): a "3 to review · 2 waiting · 4 approved" line that opens the
/// Reviews screen, then the three lanes. Lanes collapse like on the Reviews screen (shared state).
struct PopoverReviewList: View {
    @Bindable var model: AppModel

    var body: some View {
        let queue = ReviewQueue.run(state: model.state, filter: ChangeRequestFilter(), now: model.now)
        VStack(alignment: .leading, spacing: 14) {
            Button {
                model.showScreen(.reviews)
            } label: {
                HStack(spacing: 8) {
                    Text(ReviewText.summaryLine(queue))
                        .scaledFont(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("Open Reviews")
                        .scaledFont(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                    Image(systemName: "chevron.right")
                        .scaledFont(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accentText)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reviews: \(ReviewText.summaryLine(queue))")
            .accessibilityHint("Opens the Reviews screen")
            if queue.isEmpty {
                NothingSelected(title: "Nothing to review", symbol: "checkmark.bubble",
                                message: model.state.trackingPreferences.includeReviewRequests
                                    ? "Pull and merge requests that request your review, or that you reviewed, appear here."
                                    : "Review requests aren't tracked. Turn them on in MergeCue's Reviews screen.")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach([ReviewLane.toReview, .waitingOnAuthor, .approved], id: \.self) { lane in
                    laneSection(lane, entries: queue.entries(lane))
                }
            }
        }
    }

    @ViewBuilder
    private func laneSection(_ lane: ReviewLane, entries: [ReviewEntry]) -> some View {
        if !entries.isEmpty {
            let isCollapsed = model.collapsedReviewLanes.contains(lane)
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(Motion.smooth) {
                        if isCollapsed { model.collapsedReviewLanes.remove(lane) } else { model.collapsedReviewLanes.insert(lane) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("\(lane.title)  ·  \(entries.count)")
                            .scaledFont(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .scaledFont(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    }
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainRowButtonStyle())
                .accessibilityLabel("\(lane.title), \(entries.count)")
                .accessibilityHint(isCollapsed ? "Expands the group" : "Collapses the group")
                .accessibilityAddTraits(.isHeader)
                if !isCollapsed {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        PopoverPullRequestRow(model: model, snapshot: entry.snapshot, review: entry)
                            .appearStaggered(index)
                    }
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
