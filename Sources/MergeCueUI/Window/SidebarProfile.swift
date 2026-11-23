import MergeCueCore
import SwiftUI

/// The owner at the top of the sidebar (D48): avatar and name instead of the app logo. The avatar is the first
/// connected account that has one (or the one picked from the context menu); without any, initials on the brand
/// gradient. Images load from the provider's avatar URL and fall back to the initials if that fails.
struct SidebarProfile: View {
    let model: AppModel
    var compact = false

    var body: some View {
        let profile = model.ownerProfile
        VStack(spacing: 8) {
            OwnerAvatar(url: profile.avatarURL, initials: profile.initials, size: compact ? 40 : 60)
            if !compact {
                VStack(spacing: 2) {
                    Text(profile.name)
                        .scaledFont(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let handle = profile.handle {
                        Text(handle)
                            .scaledFont(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            let accounts = model.state.accounts.filter { $0.account.avatarURL != nil }
            if accounts.count > 1 {
                Section("Use Avatar From") {
                    ForEach(accounts) { account in
                        Button("\(account.kind.displayName) · \(account.account.username)") { model.avatarAccountID = account.id.id }
                    }
                }
            }
            Button("Settings…") { model.showSettings(.accounts) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profile.name)
        .help(profile.handle.map { "\(profile.name), \($0)" } ?? profile.name)
    }
}

/// A round avatar loaded from a URL, with initials while loading or when it can't be loaded.
struct OwnerAvatar: View {
    var url: URL?
    var initials: String
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Theme.brandGradientDiagonal)
            Text(initials)
                .scaledFont(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: Motion.smooth)) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill().transition(.opacity)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: Color(hex: 0x3B82F6).opacity(0.25), radius: 10, y: 2)
        .accessibilityHidden(true)
    }
}

extension AppModel {
    /// Name, handle, initials and avatar of the owner for the sidebar.
    var ownerProfile: (name: String, handle: String?, initials: String, avatarURL: URL?) {
        let accounts = state.accounts.map(\.account)
        let avatarAccount = accounts.first { $0.id.id == avatarAccountID && $0.avatarURL != nil } ?? accounts.first { $0.avatarURL != nil }
        let primary = avatarAccount ?? accounts.first
        let name = environment.userFullName.flatMap { $0.isEmpty ? nil : $0 }
            ?? primary?.displayName ?? primary?.username ?? "MergeCue"
        let handle = primary.map { "@\($0.username)" }
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return (name, handle, initials.isEmpty ? "M" : initials, avatarAccount?.avatarURL)
    }
}
