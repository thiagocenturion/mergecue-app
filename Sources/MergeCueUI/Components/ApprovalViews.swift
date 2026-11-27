import MergeCueCore
import SwiftUI

/// New approvals on the owner's pull/merge requests (D47): mint-tinted glass cards at the top of the Inbox and the
/// popover, with a celebratory seal. They stay until the change request is opened or the card is dismissed.
struct ApprovalHighlights: View {
    let model: AppModel
    var compact = false

    var body: some View {
        let highlights = model.approvalHighlights
        if !highlights.isEmpty {
            VStack(spacing: compact ? 8 : 10) {
                ForEach(highlights) { highlight in
                    ApprovalHighlightCard(model: model, highlight: highlight, compact: compact)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.92, anchor: .top).combined(with: .opacity),
                            removal: .opacity.combined(with: .move(edge: .trailing))
                        ))
                }
            }
            .animation(Motion.smooth, value: highlights.map(\.id))
        }
    }
}

struct ApprovalHighlightCard: View {
    let model: AppModel
    let highlight: ApprovalHighlight
    var compact = false
    @State private var appeared = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: compact ? 10 : 14) {
            Image(systemName: "checkmark.seal.fill")
                .scaledFont(.system(size: compact ? 18 : 22, weight: .semibold))
                .foregroundStyle(Theme.onStatusFill, Theme.mint)
                .symbolRenderingMode(.palette)
                .symbolEffect(.bounce, value: appeared)
                .frame(width: compact ? 34 : 42, height: compact ? 34 : 42)
                .background(Circle().fill(Theme.mint.opacity(0.18)))
                .shadow(color: Theme.mint.opacity(appeared ? 0.45 : 0), radius: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    AvatarStack(people: highlight.newApprovers.isEmpty ? highlight.approvers : highlight.newApprovers,
                                size: compact ? 16 : 18, ring: Theme.surface)
                    Text(highlight.headline)
                        .scaledFont(.system(size: compact ? 13.5 : 14.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                Text("\(UIFormat.untrustedDisplay(highlight.title)) · \(highlight.providerKind.formattedNumber(highlight.changeRequest.number))")
                    .scaledFont(.system(size: compact ? 12 : 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !compact {
                    HStack(spacing: 6) {
                        Text(highlight.progressText)
                            .foregroundStyle(highlight.isSatisfied == true ? Theme.mintText : Theme.textSecondary)
                        if let at = highlight.latestApprovalAt {
                            Text("· \(UIFormat.relative(from: at, now: model.now))").foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .scaledFont(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            Button("View") {
                model.showApprovals(highlight.changeRequest)
            }
            .buttonStyle(TintedOutlineButtonStyle(color: Theme.mint, textColor: Theme.mintText, size: .small))
            .fixedSize()
            Button {
                withAnimation(Motion.smooth) { model.markApprovalsSeen(highlight.changeRequest) }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 24, filled: false))
            .fixedSize()
            .help("Dismiss")
            .accessibilityLabel("Dismiss approval")
        }
        .padding(.horizontal, compact ? 16 : Theme.cardPadding)
        .padding(.vertical, compact ? 10 : 12)
        .sheen(active: !reduceMotion, shape: SmoothRect())
        .glassCard(tint: Theme.mint, interactive: true)
        // The whole card opens the pull request at its approvals (D51); the buttons keep their own actions.
        .contentShape(SmoothRect())
        .onTapGesture { model.showApprovals(highlight.changeRequest) }
        .onHover { hovering in withAnimation(Motion.hover) { isHovering = hovering } }
        .scaleEffect(isHovering && !reduceMotion ? 1.01 : 1)
        .help("Open the \(highlight.providerKind.changeRequestNoun) at its approvals")
        .accessibilityAddTraits(.isButton)
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(highlight.headline). \(highlight.title). \(highlight.progressText)")
    }
}
