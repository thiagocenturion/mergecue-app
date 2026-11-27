import MergeCueCore
import SwiftUI

/// "Review with AI" (D60): someone else's pull/merge request summarized on the left, and on the right the same
/// "Open in your coding agent" panel a task has, with a review prompt (With MCP / Without MCP). No task is created:
/// the agent opens in the repository's folder (D61), reports its findings in its own session and nothing is posted.
struct ReviewHandoffScreen: View {
    @Bindable var model: AppModel
    let snapshot: ChangeRequestSnapshot
    let focus: ReviewFocus
    @State private var availableWidth: CGFloat = 1_071

    private var summary: ChangeRequestSummary { snapshot.summary }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackButton { model.reviewHandoff = nil }
                    .padding(.leading, -6)
                header
                    .padding(.top, 8)
                let panel = panelWidth
                HStack(alignment: .top, spacing: 18) {
                    ReviewSummaryCard(model: model, snapshot: snapshot)
                        .frame(minWidth: 300, maxWidth: .infinity)
                    panelCard(wide: panel >= 720)
                        .frame(width: panel)
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 28)
            .padding(.top, MainWindowMetrics.contentTopInset - 8)
            .padding(.bottom, 24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 56 } action: { availableWidth = $0 }
    }

    private var panelWidth: CGFloat {
        if model.handoffCollapsed { return 380 }
        return min(max(availableWidth * 0.56, 520), 820)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text("Review \(Presentation.shortName(summary.author))'s \(summary.providerKind.changeRequestNoun)")
                    .scaledFont(Theme.screenTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                focusMenu
            }
            HStack(spacing: 10) {
                ProviderGlyph(kind: summary.providerKind, size: 18)
                Text("\(summary.providerKind.shortName)  ·  \(summary.repository.fullPath)")
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    model.showChangeRequest(summary.key)
                } label: {
                    Text(summary.displayNumber)
                        .lineLimit(1)
                        .fixedSize()
                        .underline()
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                }
                .buttonStyle(PlainRowButtonStyle())
                .help("Show the \(summary.providerKind.changeRequestNoun)")
                Rectangle().fill(Theme.divider).frame(width: 1, height: 18).padding(.horizontal, 6)
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text("\(UIFormat.untrustedDisplay(summary.sourceBranch)) → \(UIFormat.untrustedDisplay(summary.targetBranch))")
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .scaledFont(.system(size: 15))
        }
    }

    /// The review focus as a pill that switches it.
    private var focusMenu: some View {
        Menu {
            ForEach(ReviewFocus.allCases, id: \.self) { option in
                Toggle(isOn: Binding(get: { focus == option }, set: { if $0 { model.reviewHandoff?.focus = option } })) {
                    Text(option == .full ? "Full review" : option.title)
                }
            }
        } label: {
            HStack(spacing: 6) {
                SparkleIcon(size: 12)
                Text(focus == .full ? "Full review" : focus.title)
                Image(systemName: "chevron.down").scaledFont(.system(size: 10, weight: .bold))
            }
            .scaledFont(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.accentText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.accent.opacity(0.12)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("What the agent looks for")
        .accessibilityLabel("Review focus: \(focus.title)")
    }

    // MARK: Panel

    private func panelCard(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HandoffStepView(model: model, target: .review(snapshot, focus), wide: wide, number: "1", title: "Open in your coding agent",
                            message: "MergeCue wrote a review prompt for this \(summary.providerKind.changeRequestNoun). Your agent reports its findings in its own session.")
            ThemeDivider().padding(.top, 24)
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .scaledFont(.system(size: 15))
                Text("Nothing is posted. You decide what to comment, approve or ask for.")
                    .scaledFont(.system(size: 13))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 18)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(Theme.surface, radius: 16)
    }
}

/// What the pull request is about: author, title, description, commits and changed files (all as data).
struct ReviewSummaryCard: View {
    let model: AppModel
    let snapshot: ChangeRequestSnapshot

    var body: some View {
        let summary = snapshot.summary
        VStack(alignment: .leading, spacing: 0) {
            Text("What it changes")
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
            HStack(alignment: .top, spacing: 12) {
                PersonAvatar(person: summary.author, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(UIFormat.untrustedDisplay(summary.title))
                        .scaledFont(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(summary.author.displayLabel) · opened \(UIFormat.relative(from: summary.createdAt, now: model.now))\(summary.isDraft ? " · Draft" : "")")
                        .scaledFont(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 14)
            if let description = snapshot.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                CommentBody(text: String(description.prefix(1_200)) + (description.count > 1_200 ? "…" : ""), font: .system(size: 13.5))
                    .padding(.top, 14)
            }
            if !snapshot.commits.isEmpty {
                section("Commits · \(snapshot.commits.count)")
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(snapshot.commits.suffix(6).enumerated()), id: \.offset) { _, commit in
                        HStack(spacing: 8) {
                            Text(UIFormat.shortSHA(commit.sha))
                                .scaledFont(Theme.monoSmall)
                                .foregroundStyle(Theme.textTertiary)
                            Text(UIFormat.untrustedDisplay(commit.title))
                                .scaledFont(.system(size: 13))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .padding(.top, 10)
            }
            if !snapshot.changedFiles.isEmpty {
                section("Files · \(snapshot.changedFiles.count)")
                ChangedFileList(files: Array(snapshot.changedFiles.prefix(10)))
                    .padding(.top, 10)
                if snapshot.changedFiles.count > 10 {
                    Text("and \(snapshot.changedFiles.count - 10) more")
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 6)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(Theme.surface, radius: 16)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .scaledFont(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 20)
    }
}
