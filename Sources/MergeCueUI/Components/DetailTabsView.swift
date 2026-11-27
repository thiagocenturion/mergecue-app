import MergeCueCore
import SwiftUI

/// One detail tab: id, title, provider and whether it has something unread.
struct DetailTab: Identifiable, Hashable {
    var id: String
    var title: String
    var providerKind: ProviderKind
    var isUnread = false
}

/// The tab strip above the detail panel (D48): glass capsules with a close button each, the active one tinted, and
/// a button at the right end that turns tabs off.
struct DetailTabBar: View {
    var tabs: [DetailTab]
    var selected: String?
    var onSelect: (String) -> Void
    var onClose: (String) -> Void
    var onDisable: () -> Void
    @SwiftUI.Namespace private var highlight

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        DetailTabChip(tab: tab, isSelected: tab.id == selected, onSelect: { onSelect(tab.id) },
                                      onClose: { withAnimation(Motion.smooth) { onClose(tab.id) } })
                            .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity),
                                                    removal: .scale(scale: 0.85).combined(with: .opacity)))
                    }
                }
                .padding(.horizontal, 2)
            }
            // Room for the chips' glass and shadow inside the horizontal scroll view (it clips to its bounds).
            .shadowRail()
            .scrollIndicators(.never)
            .animation(Motion.smooth, value: tabs.map(\.id))
            Button(action: onDisable) {
                Image(systemName: "rectangle.on.rectangle.slash")
            }
            .buttonStyle(IconButtonStyle(size: 26, filled: false))
            .help("Turn off tabs")
            .accessibilityLabel("Turn off detail tabs")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open details")
    }
}

private struct DetailTabChip: View {
    var tab: DetailTab
    var isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    ProviderGlyph(kind: tab.providerKind, size: 13)
                    Text(UIFormat.untrustedDisplay(tab.title))
                        .scaledFont(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                    if tab.isUnread {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .scaledFont(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(isHovering || isSelected ? Theme.surfaceHover : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .help("Close tab")
            .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(minHeight: 28)
        .glassShape(Capsule(), tint: isSelected ? Theme.accent : nil, fallback: isSelected ? Theme.surfaceSelected : Theme.surface)
        .onHover { isHovering = $0 }
    }
}

/// The first time a detail opens: "Open details in tabs?" with Use Tabs / Not Now (D48).
struct DetailTabsPrompt: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accentText)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.accentText.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Open details in tabs?")
                    .scaledFont(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Keep several pull requests open and switch between them. You can turn this off from the tab bar.")
                    .scaledFont(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Not Now") { withAnimation(Motion.smooth) { model.detailTabsEnabled = false } }
                .buttonStyle(SecondaryButtonStyle(size: .small))
                .fixedSize()
            Button("Use Tabs") { withAnimation(Motion.smooth) { model.detailTabsEnabled = true } }
                .buttonStyle(GradientButtonStyle(size: .small))
                .fixedSize()
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 10)
        .glassCard(tint: Theme.accent)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
