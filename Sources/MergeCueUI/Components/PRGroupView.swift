import MergeCueCore
import SwiftUI

/// A small status mark shown in a collapsed group's summary (one per distinct reason).
struct PRGroupMark: Hashable {
    var symbol: String
    var color: Color
}

/// One change request's rows under a collapsible glass header (Inbox and popover, D46). Expanded by default;
/// collapsed, the header keeps a summary (reason marks, unread count, item count, latest activity) and stacked
/// layers peek out underneath, so it is clear there is something inside.
struct PRGroupView<Rows: View>: View {
    var providerKind: ProviderKind
    var repoFullPath: String
    var number: Int
    var title: String
    var count: Int
    var unreadCount: Int
    var marks: [PRGroupMark]
    var latest: Date?
    var now: Date
    var isCollapsed: Bool
    /// Approvals on this change request ("2 approvals"); new ones glow (D47).
    var approval: ApprovalSummary?
    /// Opens the change request (popover: in the app); nil makes the title toggle the group.
    var onOpen: (() -> Void)?
    /// Opens the change request in the provider's web page.
    var onOpenExternal: (() -> Void)?
    /// Popover sizing (smaller type and badge).
    var compact = false
    var toggle: () -> Void
    @ViewBuilder var rows: Rows

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            header
            if !isCollapsed {
                rows
                    .padding(.leading, compact ? 10 : 14)
                    .overlay(alignment: .leading) {
                        // A rail ties the rows to their header.
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.accent.opacity(0.45), Theme.accent.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                            .frame(width: 2)
                            .padding(.vertical, 4)
                            .padding(.leading, compact ? 2 : 4)
                            .accessibilityHidden(true)
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                    ))
            }
        }
        .padding(.bottom, isCollapsed ? (compact ? 10 : 12) : 0)
    }

    private var header: some View {
        HStack(spacing: compact ? 8 : 10) {
            // The title area opens the change request when `onOpen` is set (popover), else it toggles the group.
            Button {
                if let onOpen { onOpen() } else { toggleAnimated() }
            } label: {
                HStack(spacing: compact ? 10 : 12) {
                    ProviderBadge(kind: providerKind, size: compact ? 28 : 32, style: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UIFormat.untrustedDisplay(title))
                            .scaledFont(.system(size: compact ? 13.5 : 14.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("\(repoFullPath) \(providerKind.formattedNumber(number))")
                            .scaledFont(.system(size: compact ? 11.5 : 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .help(onOpen == nil ? (isCollapsed ? "Expand" : "Collapse") : "Open in MergeCue")
            .accessibilityLabel(accessibilityText)
            .accessibilityHint(onOpen == nil ? (isCollapsed ? "Expands the group" : "Collapses the group") : "Opens the \(providerKind.changeRequestNoun) in MergeCue")
            .accessibilityAddTraits(.isHeader)
            .layoutPriority(1)
            if let approval {
                // The long form when it fits, else the count ("1/2").
                ViewThatFits(in: .horizontal) {
                    ApprovalChip(text: compact ? approval.short : approval.text, isNew: approval.isNew, compact: compact)
                    ApprovalChip(text: approval.short, isNew: approval.isNew, compact: true)
                }
                .layoutPriority(-1)
            }
            if isCollapsed {
                summary
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            } else {
                CountBadge(count: count, highlighted: unreadCount > 0)
                    .transition(.opacity)
            }
            if let onOpenExternal {
                Button(action: onOpenExternal) {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(IconButtonStyle(size: compact ? 24 : 26, filled: false))
                .help("Open in \(providerKind.displayName)")
                .accessibilityLabel("Open in \(providerKind.displayName)")
            }
            Button(action: toggleAnimated) {
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .help(isCollapsed ? "Expand" : "Collapse")
            .accessibilityLabel(isCollapsed ? "Expand group" : "Collapse group")
        }
        .padding(.leading, compact ? 8 : 10)
        .padding(.trailing, compact ? 10 : 14)
        .padding(.vertical, compact ? 7 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassShape(Capsule(), interactive: true, fallback: Theme.surface)
        .background(alignment: .bottom) { stack }
        .accessibilityElement(children: .contain)
    }

    private func toggleAnimated() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.smooth) { toggle() }
    }

    /// Collapsed: reason marks overlapping like avatars, the unread count, the item count and the latest activity.
    private var summary: some View {
        HStack(spacing: 8) {
            HStack(spacing: -7) {
                ForEach(Array(marks.prefix(3).enumerated()), id: \.offset) { index, mark in
                    StatusGlyph(symbol: mark.symbol, color: mark.color, size: compact ? 18 : 20)
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.5))
                        .zIndex(Double(3 - index))
                }
            }
            if unreadCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text("\(unreadCount) new")
                        .scaledFont(.system(size: compact ? 11.5 : 12, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                }
            }
            Text(count == 1 ? "1 item" : "\(count) items")
                .scaledFont(.system(size: compact ? 11.5 : 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
            if let latest, !compact {
                Text(UIFormat.compactAge(from: latest, now: now))
                    .scaledFont(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .fixedSize()
    }

    /// Collapsed: up to two layers peeking out below the header, one per hidden row.
    @ViewBuilder
    private var stack: some View {
        if isCollapsed {
            ZStack(alignment: .bottom) {
                if count > 1 {
                    Capsule().fill(.clear)
                        .glassShape(Capsule(), interactive: false, fallback: Theme.textPrimary.opacity(0.06))
                        .opacity(0.7)
                        .padding(.horizontal, 26)
                        .offset(y: compact ? 10 : 12)
                }
                Capsule().fill(.clear)
                    .glassShape(Capsule(), interactive: false, fallback: Theme.textPrimary.opacity(0.1))
                    .padding(.horizontal, 13)
                    .offset(y: compact ? 5 : 6)
            }
            .accessibilityHidden(true)
        }
    }

    private var accessibilityText: String {
        var text = "\(title), \(repoFullPath) \(providerKind.formattedNumber(number)), \(count) item\(count == 1 ? "" : "s")"
        if unreadCount > 0 { text += ", \(unreadCount) unread" }
        return text + (isCollapsed ? ", collapsed" : ", expanded")
    }
}

/// "✓ 2 approvals" in mint (compact: "✓ 2" or "✓ 1/2"); a new approval glows and its seal bounces once.
struct ApprovalChip: View {
    var text: String
    var isNew: Bool
    var compact = false
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill")
                .symbolEffect(.bounce, value: appeared && isNew)
            Text(text).monospacedDigit()
        }
        .scaledFont(.system(size: compact ? 11 : 11.5, weight: .semibold))
        .foregroundStyle(Theme.mintText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.mint.opacity(isNew ? 0.22 : 0.12)))
        .shadow(color: Theme.mint.opacity(isNew ? 0.5 : 0), radius: 6)
        .fixedSize()
        .onAppear { appeared = true }
        .help(isNew ? "New approval" : "Approvals")
        .accessibilityLabel(isNew ? "New approval: \(text)" : "Approvals: \(text)")
    }
}
