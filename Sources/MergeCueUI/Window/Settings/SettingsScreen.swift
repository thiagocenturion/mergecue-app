import MergeCueCore
import SwiftUI

/// Settings sections (content column).
struct SettingsList: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 14)
                .accessibilityAddTraits(.isHeader)
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = model.settingsTab == tab
                Button {
                    model.settingsTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 14))
                            .frame(width: 20)
                            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                        Text(tab.title)
                            .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if badge(tab) > 0 { CountBadge(count: badge(tab), highlighted: isSelected) }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? Theme.surfaceSelected : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isSelected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1))
                }
                .buttonStyle(PlainRowButtonStyle())
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.contentBackground)
    }

    private var selection: Binding<SettingsTab?> {
        Binding(get: { model.settingsTab }, set: { if let tab = $0 { model.settingsTab = tab } })
    }

    private func badge(_ tab: SettingsTab) -> Int {
        switch tab {
        case .accounts: model.accountsWithProblems.count
        case .repositories: model.state.mappings.filter { !$0.isConfirmed }.count
        case .agents: model.state.agents.filter { !$0.mcpRegistration.isVerified }.count
        default: 0
        }
    }
}

/// The selected settings pane.
struct SettingsDetail: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: model.settingsTab.symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                    Text(model.settingsTab.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    ModeBadge(mode: model.mode)
                }
                switch model.settingsTab {
                case .accounts: AccountsSettings(model: model)
                case .repositories: RepositoriesSettings(model: model)
                case .agents: AgentsSettings(model: model)
                case .notifications: NotificationsSettings(model: model)
                case .general: GeneralSettings(model: model)
                case .data: DataSettings(model: model)
                case .about: AboutPane(model: model)
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.windowBackground)
    }
}

// MARK: - Accounts

struct AccountsSettings: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MergeCue reads each provider's API directly with a token stored in your Keychain. Accounts sync independently — a problem with one never blocks the others.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Connect")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach([ProviderKind.github, .gitlab, .bitbucketCloud], id: \.self) { kind in
                    Button {
                        model.connectSheetKind = kind
                    } label: {
                        HStack(spacing: 6) {
                            ProviderGlyph(kind: kind, size: 14)
                            Text("\(kind.displayName)…")
                        }
                        .fixedSize()
                    }
                    .accessibilityLabel("Connect \(kind.displayName)")
                }
                Spacer(minLength: 8)
                Button {
                    Task { await model.send(.connectAccount(ConnectAccountRequest(kind: .github, method: .githubCLIImport))) }
                } label: {
                    Label("Import from GitHub CLI", systemImage: "terminal")
                        .fixedSize()
                }
                .help("Uses the token of your existing `gh auth login` session after you confirm")
            }
            if model.state.accounts.isEmpty {
                Text("No accounts connected yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
            ForEach(model.state.accounts) { account in
                AccountCard(model: model, account: account)
            }
        }
    }
}

struct AccountCard: View {
    let model: AppModel
    let account: AccountState
    @State private var confirmDisconnect = false

    var body: some View {
        let status = account.status
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProviderGlyph(kind: account.kind, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(account.account.displayName ?? account.account.username) · @\(account.account.username)")
                            .font(.headline)
                        Text("\(account.kind.displayName) · \(account.account.instance.host) · \(account.account.authMethod.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(UIFormat.syncText(status, now: model.now), systemImage: status.state.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Theme.color(UIFormat.tone(of: status.state)))
                        if let message = status.message, status.state.isProblem {
                            Text(SecretRedactor.redact(message))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !account.account.grantedScopes.isEmpty {
                    HStack(spacing: 4) {
                        Text("Scopes").font(.caption).foregroundStyle(.secondary)
                        ForEach(account.account.grantedScopes, id: \.self) { scope in
                            Text(scope)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                        }
                    }
                }
                Divider()
                Toggle(isOn: Binding(
                    get: { account.account.writesEnabled },
                    set: { enabled in Task { await model.send(.setWritesEnabled(account.id, enabled)) } }
                )) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Allow remote writes")
                            Text("Replies and resolving threads, each only after you approve a preview. Off by default.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                    }
                }
                .toggleStyle(.switch)
                CapabilitySummary(manifest: account.capabilities)
                HStack {
                    Button("Refresh") { Task { await model.send(.refresh(account: account.id)) } }
                    if status.state == .authExpired || status.state.isPermissionProblem {
                        Button("Reconnect…") { model.connectSheetKind = account.kind }
                            .buttonStyle(GradientButtonStyle(size: .small))
                    }
                    Spacer()
                    Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                }
            }
        }
        .confirmationDialog("Disconnect \(account.kind.displayName) · \(account.account.username)?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { Task { await model.send(.disconnectAccount(account.id)) } }
        } message: {
            Text("MergeCue deletes the token from your Keychain and removes this account's local data. Revoke the token on \(account.kind.displayName) too if you no longer need it.")
        }
    }
}

nonisolated extension AccountSyncState {
    var isPermissionProblem: Bool {
        if case .permissionDenied = self { return true }
        return false
    }
}

/// Which capabilities the provider adapter supports for this account.
struct CapabilitySummary: View {
    let manifest: CapabilityManifest
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Capability.allCases, id: \.self) { capability in
                    let support = manifest.support(for: capability)
                    GridRow {
                        Image(systemName: support.isUsable ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(support.isUsable ? Theme.mint : Color.secondary)
                        Text(capability.displayName).font(.callout)
                        Text(support.userFacingDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            let unusable = Capability.allCases.filter { !manifest.support(for: $0).isUsable }.count
            Text(unusable == 0 ? "All capabilities available" : "Capabilities · \(unusable) need write access or are unsupported")
                .font(.callout)
        }
    }
}
