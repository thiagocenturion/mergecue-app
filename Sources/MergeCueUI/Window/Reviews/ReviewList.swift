import MergeCueCore
import SwiftUI

/// Reviews (D53, D56): pull/merge requests of others you review, in three lanes. "To review" needs your first look
/// (requested, or re-approval needed); "Changes requested" holds the ones you asked changes for or commented on, with
/// author updates (new commits, replies) flagged and first; "Approved, watching" keeps your approvals until they merge.
struct ReviewList: View {
    @Bindable var model: AppModel
    @FocusState private var listFocused: Bool

    var body: some View {
        let queue = model.reviewQueue
        VStack(alignment: .leading, spacing: 0) {
            filterBar
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            ThemeDivider()
            if model.state.accounts.isEmpty {
                NothingSelected(title: "No accounts", symbol: "person.crop.circle.badge.plus",
                                message: "Connect GitHub, GitLab or Bitbucket Cloud in Settings › Accounts.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ReviewTrackingPrompt(model: model)
                            if queue.isEmpty {
                                emptyState
                            } else {
                                ReviewLanes(model: model, queue: queue, listFocused: $listFocused)
                            }
                            ReviewCoverageNote(model: model)
                                .padding(.top, 10)
                        }
                        .padding(.top, 12)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 24)
                    }
                    .shadowRoom()
                    .keyboardList(isFocused: $listFocused, hasSelection: model.selectedChangeRequestID != nil,
                                  onMove: { model.moveReviewSelection(by: $0) },
                                  onOpen: { if let id = model.selectedChangeRequestID { model.openChangeRequest(id) } },
                                  onPrimary: { model.performChangeRequestPrimaryAction() })
                    .onChange(of: model.selectedChangeRequestID) { _, id in
                        guard listFocused, let id else { return }
                        proxy.scrollTo(id)
                    }
                    .accessibilityLabel("Pull and merge requests you review")
                    .accessibilityHint("Use the up and down arrow keys to move, Return to open")
                }
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reviews")
                .scaledFont(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            SearchField(text: $model.reviewFilter.searchText, prompt: "Search title, repo, author, #42…")
            HStack(spacing: 8) {
                FilterMenu(title: model.reviewFilter.provider?.displayName ?? "Provider", isActive: model.reviewFilter.provider != nil) {
                    Button("Any Provider") { model.reviewFilter.provider = nil }
                    Divider()
                    ForEach(ProviderKind.allCases, id: \.self) { kind in
                        Button(kind.displayName) { model.reviewFilter.provider = kind }
                    }
                }
                FilterMenu(title: model.reviewFilter.account.map { model.accountTitle($0) } ?? "Account",
                           isActive: model.reviewFilter.account != nil) {
                    Button("Any Account") { model.reviewFilter.account = nil }
                    Divider()
                    ForEach(model.state.accounts) { account in
                        Button(model.accountTitle(account.id)) { model.reviewFilter.account = account.id }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var emptyState: some View {
        NothingSelected(title: "Nothing to review", symbol: "checkmark.bubble",
                        message: "Pull and merge requests that request your review, or that you commented on or approved, appear here.")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }

    static func emptyText(_ lane: ReviewLane) -> String {
        switch lane {
        case .toReview: "You're all caught up."
        case .changesRequested: "No pull requests with your requested changes."
        case .approved, .closed: "No approved pull requests to watch."
        }
    }
}

/// The three review lanes with their rows (D53, D56): shared by the Reviews screen and the Inbox's Reviews filter.
struct ReviewLanes: View {
    @Bindable var model: AppModel
    let queue: ReviewQueue
    var listFocused: FocusState<Bool>.Binding

    var body: some View {
        ForEach(ReviewQueue.lanes, id: \.self) { lane in
            laneSection(lane, entries: queue.entries(lane))
        }
    }

    @ViewBuilder
    private func laneSection(_ lane: ReviewLane, entries: [ReviewEntry]) -> some View {
        let isCollapsed = model.collapsedReviewLanes.contains(lane)
        VStack(alignment: .leading, spacing: 8) {
            ReviewLaneHeader(lane: lane, count: entries.count, isCollapsed: isCollapsed) {
                withAnimation(Motion.smooth) {
                    if isCollapsed { model.collapsedReviewLanes.remove(lane) } else { model.collapsedReviewLanes.insert(lane) }
                }
            }
            if !isCollapsed {
                if entries.isEmpty {
                    Text(ReviewList.emptyText(lane))
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let isSelected = model.selectedChangeRequestID == entry.id
                    ReviewRow(model: model, entry: entry, isSelected: isSelected)
                        .keyboardSelectionRing(isSelected && listFocused.wrappedValue, cornerRadius: Theme.radius)
                        .onTapGesture {
                            model.openChangeRequest(entry.id)
                            listFocused.wrappedValue = true
                        }
                        .accessibilityAction { model.openChangeRequest(entry.id) }
                        .id(entry.id)
                        .transition(Motion.listTransition)
                        .appearStaggered(index)
                }
            }
        }
        .padding(.bottom, 8)
    }

}

/// "To review · 3" with a one-line explanation and a chevron; the whole header toggles the lane.
struct ReviewLaneHeader: View {
    var lane: ReviewLane
    var count: Int
    var isCollapsed: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(lane.title)
                            .scaledFont(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        CountBadge(count: count, highlighted: lane == .toReview && count > 0)
                    }
                    Text(Self.hint(lane))
                        .scaledFont(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(lane.title), \(count)")
        .accessibilityHint(isCollapsed ? "Expands the group" : "Collapses the group")
        .accessibilityAddTraits(.isHeader)
    }

    static func hint(_ lane: ReviewLane) -> String {
        switch lane {
        case .toReview: "Review requested, or re-approval needed after a push"
        case .changesRequested: "You asked for changes or commented. Author updates come first."
        case .approved, .closed: "Your approval stands. Leaves the list when merged."
        }
    }
}

/// One pull/merge request you review: reference, title, author, your review state and its checks/approvals.
struct ReviewRow: View {
    let model: AppModel
    let entry: ReviewEntry
    var isSelected = false
    @State private var isHovering = false

    var body: some View {
        let summary = entry.snapshot.summary
        let chip = ReviewText.chip(entry)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ChangeRequestRefLabel(kind: summary.providerKind, repoFullPath: summary.repository.fullPath, number: summary.key.number,
                                      font: .system(size: 12), glyphSize: 13)
                Spacer(minLength: 4)
                Text(UIFormat.compactAge(from: summary.updatedAt, now: model.now))
                    .scaledFont(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel(UIFormat.spokenAge(from: summary.updatedAt, now: model.now))
            }
            Text(UIFormat.untrustedDisplay(summary.title))
                .scaledFont(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    PersonAvatar(person: summary.author, size: 16)
                    Text("@\(summary.author.username)")
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Chip(text: chip.text, symbol: chip.symbol, tone: chip.tone)
                if summary.isDraft { Chip(text: "Draft") }
                Spacer(minLength: 4)
                ChecksBadge(state: entry.snapshot.aggregateCheckState)
                if let approval = model.approvalSummary(summary.key) {
                    ApprovalChip(text: approval.short, isNew: false, compact: true)
                }
                if entry.snapshot.unresolvedThreadCount > 0 {
                    Label("\(entry.snapshot.unresolvedThreadCount)", systemImage: "bubble.left")
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("\(entry.snapshot.unresolvedThreadCount) unresolved threads")
                }
            }
            .scaledFont(.system(size: 11.5))
            .labelStyle(.titleAndIcon)
            if let note = ReviewText.note(entry) {
                Label(note, systemImage: "arrow.triangle.2.circlepath")
                    .scaledFont(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Theme.cardPadding)
        .selectableGlass(isSelected: isSelected, isHovering: isHovering)
        .contentShape(SmoothRect())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button { Task { await model.send(.openURL(summary.webURL)) } } label: {
                Label("Open in \(summary.providerKind.displayName)", systemImage: OutsideLinkGlyph.symbol)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
        .accessibilityHint("Shows the conversation")
    }
}

/// Live accounts track only your own PRs/MRs until you opt in (Settings ▸ General ▸ Tracking). The Reviews screen
/// needs review requests, and reviewed PRs to keep approved ones after a provider drops the request.
struct ReviewTrackingPrompt: View {
    let model: AppModel

    var body: some View {
        let tracking = model.state.trackingPreferences
        if !tracking.includeReviewRequests || !tracking.includeInvolved {
            let neither = !tracking.includeReviewRequests && !tracking.includeInvolved
            VStack(alignment: .leading, spacing: 10) {
                Label(neither ? "Reviews aren't tracked yet" : "Some reviews aren't tracked",
                      systemImage: "eye.slash")
                    .scaledFont(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(Self.message(tracking))
                    .scaledFont(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Track my reviews") {
                    var updated = tracking
                    updated.includeReviewRequests = true
                    updated.includeInvolved = true
                    Task { await model.send(.setTrackingPreferences(updated)) }
                }
                .buttonStyle(GradientButtonStyle(size: .small))
            }
            .padding(Theme.cardPadding)
            .cardBackground(Theme.surface, radius: Theme.radius)
            .padding(.bottom, 6)
        }
    }

    static func message(_ tracking: TrackingPreferences) -> String {
        if !tracking.includeReviewRequests && !tracking.includeInvolved {
            return "MergeCue lists only your own pull requests right now. Track the ones that request your review and the ones you reviewed or commented on."
        }
        if !tracking.includeReviewRequests {
            return "Pull requests that request your review aren't tracked, so new requests won't show up here."
        }
        return "Pull requests you reviewed or commented on aren't tracked. GitHub drops the request once you review, so approved ones can disappear before they merge."
    }
}

/// Bitbucket Cloud has no API for "every PR I review", so MergeCue looks repository by repository (D26, D53).
struct ReviewCoverageNote: View {
    let model: AppModel

    var body: some View {
        let bitbucket = model.state.accounts.filter { $0.kind == .bitbucketCloud }
        if !bitbucket.isEmpty {
            let watching = bitbucket.contains { account in
                let mapped = model.state.mappings.map(\.repo).filter { $0.account == account.id }
                return !WatchedRepositories.effective(for: account.account, mapped: mapped).isEmpty
            }
            Label(watching
                  ? "Bitbucket: reviews are found in your watched repositories."
                  : "Bitbucket: reviews are found in the 30 most recently updated repositories of each workspace. Choose watched repositories in Settings › Accounts to always include yours.",
                  systemImage: "info.circle")
                .scaledFont(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
        }
    }
}
