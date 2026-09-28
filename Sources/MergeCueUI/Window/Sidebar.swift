import MergeCueCore
import SwiftUI

/// Logo, navigation (⌘1–⌘5), connected accounts with their sync status, the non-live badge and the sync footer.
struct Sidebar: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: MainWindowMetrics.titlebarInset)
            SidebarLogo()
                .padding(.bottom, 26)
            VStack(spacing: 4) {
                ForEach(MainScreen.allCases) { screen in
                    SidebarNavItem(screen: screen, isSelected: model.screen == screen, badge: badge(for: screen)) {
                        model.screen = screen
                        if screen == .tasks { model.selectedTaskID = nil }
                    }
                }
            }
            ThemeDivider()
                .padding(.vertical, 20)
                .padding(.horizontal, 8)
            SidebarAccounts(model: model)
            Spacer(minLength: 12)
            if model.mode != .live {
                ModeBadge(mode: model.mode)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            ThemeDivider()
                .padding(.horizontal, 8)
            SidebarSyncFooter(model: model)
                .padding(.vertical, 14)
        }
        .padding(.horizontal, 12)
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
    var body: some View {
        VStack(spacing: 10) {
            AppMark(size: 60)
                .shadow(color: Color(hex: 0x3B82F6).opacity(0.25), radius: 12, y: 2)
            Text("MergeCue")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
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
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: screen.symbol)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Text(screen.title)
                    .font(.system(size: 14.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textPrimary.opacity(0.82))
                Spacer(minLength: 4)
                if badge > 0 {
                    CountBadge(count: badge, highlighted: isSelected)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.surfaceSelected : (isHovering ? Theme.surfaceHover : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainRowButtonStyle())
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected accounts")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            if model.state.accounts.isEmpty {
                Button {
                    model.showSettings(.accounts)
                } label: {
                    Label("Connect an account", systemImage: "plus.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(PlainRowButtonStyle())
            }
            ForEach(model.state.accounts) { account in
                SidebarAccountRow(model: model, account: account)
            }
        }
    }
}

struct SidebarAccountRow: View {
    let model: AppModel
    let account: AccountState
    @State private var isHovering = false

    var body: some View {
        let status = UIFormat.syncText(account.status, now: model.now)
        Button {
            model.showSettings(.accounts)
        } label: {
            HStack(spacing: 12) {
                ProviderGlyph(kind: account.kind, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.kind.shortName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(account.account.displayLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Circle()
                    .fill(Self.dotColor(account.status.state))
                    .frame(width: 8, height: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isHovering ? Theme.surfaceHover : .clear))
        }
        .buttonStyle(PlainRowButtonStyle())
        .onHover { isHovering = $0 }
        .help("\(account.kind.displayName) · \(account.account.displayLabel): \(status)")
        .accessibilityLabel("\(account.kind.displayName) account \(account.account.displayLabel), \(status)")
        .accessibilityHint("Opens Settings, Accounts")
    }

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

    var body: some View {
        let summary = Presentation.syncSummary(accounts: model.state.accounts, now: model.now, refreshing: model.isRefreshing)
        Button {
            Task { await model.refresh() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(summary.tone == .success || summary.tone == .neutral ? Theme.textSecondary : Theme.color(summary.tone))
                    .symbolEffect(.rotate, isActive: model.isRefreshing)
                Text(summary.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(summary.tone == .success || summary.tone == .neutral ? Theme.textSecondary : Theme.color(summary.tone))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(PlainRowButtonStyle())
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh all accounts (⌘R)")
        .accessibilityLabel("\(summary.text). Refresh")
    }
}
