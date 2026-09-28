import MergeCueCore
import SwiftUI

/// Logo, navigation (⌘1–⌘5), connected accounts with their sync status, the non-live badge and the sync footer.
/// In a narrow window (`compact`) it shows icons only; labels move to tooltips and VoiceOver.
struct Sidebar: View {
    let model: AppModel
    var compact = false

    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: 0) {
            Color.clear.frame(height: MainWindowMetrics.titlebarInset)
            SidebarLogo(compact: compact)
                .padding(.bottom, compact ? 18 : 26)
            ScrollView(.vertical) {
                VStack(alignment: compact ? .center : .leading, spacing: 0) {
                    VStack(spacing: 4) {
                        ForEach(MainScreen.allCases) { screen in
                            SidebarNavItem(screen: screen, isSelected: model.screen == screen, badge: badge(for: screen), compact: compact) {
                                model.screen = screen
                                if screen == .tasks { model.selectedTaskID = nil }
                            }
                        }
                    }
                    ThemeDivider()
                        .padding(.vertical, 20)
                        .padding(.horizontal, 8)
                    SidebarAccounts(model: model, compact: compact)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            Spacer(minLength: 12)
            if model.mode != .live {
                ModeBadge(mode: model.mode, compact: compact)
                    .padding(.horizontal, compact ? 0 : 10)
                    .padding(.bottom, 10)
            }
            ThemeDivider()
                .padding(.horizontal, 8)
            SidebarSyncFooter(model: model, compact: compact)
                .padding(.vertical, 14)
        }
        .padding(.horizontal, compact ? 8 : 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private func badge(for screen: MainScreen) -> Int {
        switch screen {
        case .inbox: model.sections.needsYou.filter { if case .attention = $0.source { true } else { false } }.count
        case .tasks: model.sections.count(.ready) + model.state.tasks.filter { [.blocked, .failed, .stale].contains($0.task.state) }.count
        case .rules: model.pendingRuleProposals.count
        case .changeRequests, .settings: 0
        }
    }
}

/// The approved app icon above the product name.
struct SidebarLogo: View {
    var compact = false

    var body: some View {
        VStack(spacing: 10) {
            AppMark(size: compact ? 40 : 60)
                .shadow(color: Color(hex: 0x3B82F6).opacity(0.25), radius: 12, y: 2)
            if !compact {
                Text("MergeCue")
                    .scaledFont(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MergeCue")
    }
}

struct SidebarNavItem: View {
    var screen: MainScreen
    var isSelected: Bool
    var badge: Int
    var compact = false
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: screen.symbol)
                    .scaledFont(.system(size: 16, weight: .regular))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .overlay(alignment: .topTrailing) {
                        if compact && badge > 0 {
                            Text("\(badge)")
                                .scaledFont(.system(size: 9.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 15, minHeight: 15)
                                .background(Capsule().fill(Color(hex: Palette.actionStops[1])))
                                .offset(x: 10, y: -8)
                        }
                    }
                if !compact {
                    Text(screen.title)
                        .scaledFont(.system(size: 14.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textPrimary.opacity(0.82))
                    Spacer(minLength: 4)
                    if badge > 0 {
                        CountBadge(count: badge, highlighted: isSelected)
                    }
                }
            }
            .padding(.horizontal, compact ? 0 : 12)
            .padding(.vertical, 6)
            .frame(minHeight: 42)
            .frame(maxWidth: compact ? 52 : nil)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.surfaceSelected : (isHovering ? Theme.surfaceHover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainRowButtonStyle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .keyboardShortcut(KeyEquivalent(screen.shortcutDigit), modifiers: .command)
        .help("\(screen.title) (⌘\(String(screen.shortcutDigit)))")
        .accessibilityLabel(badge > 0 ? "\(screen.title), \(badge)" : screen.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// "Connected accounts": provider mark, provider name, account, status dot, chevron (opens Settings › Accounts).
struct SidebarAccounts: View {
    let model: AppModel
    var compact = false

    var body: some View {
        VStack(alignment: compact ? .center : .leading, spacing: 6) {
            if !compact {
                Text("Connected accounts")
                    .scaledFont(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            if model.state.accounts.isEmpty {
                Button {
                    model.showSettings(.accounts)
                } label: {
                    Label("Connect an account", systemImage: "plus.circle")
                        .labelStyle(CompactAwareLabelStyle(compact: compact))
                        .scaledFont(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, compact ? 0 : 10)
                }
                .buttonStyle(PlainRowButtonStyle())
                .help("Connect an account")
            }
            ForEach(model.state.accounts) { account in
                SidebarAccountRow(model: model, account: account, compact: compact)
            }
        }
    }
}

/// Title and icon, or the icon only in the compact sidebar.
struct CompactAwareLabelStyle: LabelStyle {
    var compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
        } else {
            HStack(spacing: 6) {
                configuration.icon
                configuration.title
            }
        }
    }
}

/// An account's sync state as colour *and* shape: a dot when it syncs fine (a check mark with Differentiate
/// Without Color), a triangle for warnings, an octagon for errors, a dotted ring while syncing.
struct AccountStatusIndicator: View {
    var state: AccountSyncState
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    static let width: CGFloat = 13

    var body: some View {
        let tone = UIFormat.tone(of: state)
        Group {
            if tone == .success && !differentiateWithoutColor {
                Circle().fill(Theme.mint).frame(width: 8, height: 8)
            } else {
                Image(systemName: Self.symbol(for: tone))
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SidebarAccountRow.dotColor(state))
            }
        }
        .frame(width: Self.width)
        .accessibilityHidden(true)
    }

    static func symbol(for tone: Tone) -> String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .neutral, .progress: "circle.dotted"
        }
    }
}

struct SidebarAccountRow: View {
    let model: AppModel
    let account: AccountState
    var compact = false
    @State private var isHovering = false

    var body: some View {
        let status = UIFormat.syncText(account.status, now: model.now)
        Button {
            model.showSettings(.accounts)
        } label: {
            if compact {
                ProviderGlyph(kind: account.kind, size: 26)
                    .overlay(alignment: .bottomTrailing) {
                        AccountStatusIndicator(state: account.status.state)
                            .background(Circle().fill(Theme.sidebarBackground).padding(-2))
                            .offset(x: 4, y: 4)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isHovering ? Theme.surfaceHover : .clear))
            } else {
                row
            }
        }
        .buttonStyle(PlainRowButtonStyle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .help("\(account.kind.displayName) · \(account.account.displayLabel): \(status)")
        .accessibilityLabel("\(account.kind.displayName) account \(account.account.displayLabel), \(status)")
        .accessibilityHint("Opens Settings, Accounts")
    }

    private var row: some View {
            HStack(spacing: Self.spacing) {
                ProviderGlyph(kind: account.kind, size: 26)
                // The name column takes every point the trailing status needs not (layout priority), and a long
                // label wraps to a second line instead of being cut ("Bitbucket (de…" at the default width).
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.kind.shortName)
                        .scaledFont(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(account.account.displayLabel)
                        .scaledFont(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(Self.labelLineLimit)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                AccountStatusIndicator(state: account.status.state)
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: Self.minHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isHovering ? Theme.surfaceHover : .clear))
    }

    static let spacing: CGFloat = 10
    static let minHeight: CGFloat = 50
    /// Labels longer than one line wrap once; beyond that the middle is elided (the tooltip has the full label).
    static let labelLineLimit = 2

    /// Green ok, amber rate-limited / offline / syncing trouble, red credentials expired or errors.
    static func dotColor(_ state: AccountSyncState) -> Color {
        switch UIFormat.tone(of: state) {
        case .success: Theme.mint
        case .attention: Theme.waiting
        case .critical: Theme.critical
        case .neutral, .progress: Theme.textTertiary
        }
    }
}

/// "Synced just now" with a refresh control.
struct SidebarSyncFooter: View {
    let model: AppModel
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let summary = Presentation.syncSummary(accounts: model.state.accounts, now: model.now, refreshing: model.isRefreshing)
        let plain = summary.tone == .success || summary.tone == .neutral
        Button {
            Task { await model.refresh() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .scaledFont(.system(size: 14, weight: .medium))
                    .foregroundStyle(plain ? Theme.textSecondary : Theme.color(summary.tone))
                    .symbolEffect(.rotate, isActive: model.isRefreshing && !reduceMotion)
                if !compact {
                    Text(summary.text)
                        .scaledFont(.system(size: 12.5))
                        .foregroundStyle(plain ? Theme.textSecondary : Theme.textColor(summary.tone))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .scaledFont(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, compact ? 6 : 10)
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainRowButtonStyle())
        .keyboardShortcut("r", modifiers: .command)
        .help(compact ? "\(summary.text). Refresh all accounts (⌘R)" : "Refresh all accounts (⌘R)")
        .accessibilityLabel("\(summary.text). Refresh")
    }
}
