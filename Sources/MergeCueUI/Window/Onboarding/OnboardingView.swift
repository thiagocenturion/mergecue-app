import AgentHandoff
import MergeCueCore
import SwiftUI

/// Steps of the setup assistant.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, accounts, repositories, agents, notifications, done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .accounts: "Connect accounts"
        case .repositories: "Repositories"
        case .agents: "Coding agent"
        case .notifications: "Notifications"
        case .done: "Done"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .accounts: "person.crop.circle.badge.plus"
        case .repositories: "folder.badge.gearshape"
        case .agents: "terminal"
        case .notifications: "bell.badge"
        case .done: "checkmark.seal"
        }
    }
}

/// The setup assistant (first live launch without accounts; later from Settings › General): welcome, connect
/// accounts, map repositories, set up a coding agent, notifications permission, done.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        HStack(spacing: 0) {
            rail
                .frame(width: 200)
                .background(Theme.sidebarBackground)
            Rectangle().fill(Theme.divider).frame(width: 1)
            VStack(spacing: 0) {
                ScrollView {
                    content
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ThemeDivider()
                footer
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            }
            .background(Theme.contentBackground)
        }
        .frame(width: 900, height: 640)
        .overlay(alignment: .top) { BannerStack(model: model) }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                AppMark(size: 34)
                Text("MergeCue").font(.system(size: 17, weight: .semibold))
            }
            .padding(.bottom, 18)
            ForEach(OnboardingStep.allCases) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill" : item.symbol)
                        .foregroundStyle(item.rawValue < step.rawValue ? Theme.mint : (item == step ? Theme.accent : Theme.textTertiary))
                        .frame(width: 18)
                    Text(item.title)
                        .font(.system(size: 13, weight: item == step ? .semibold : .regular))
                        .foregroundStyle(item == step ? Theme.textPrimary : Theme.textSecondary)
                }
                .frame(height: 30)
                .accessibilityAddTraits(item == step ? [.isSelected] : [])
            }
            Spacer()
            ModeBadge(mode: model.mode)
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { move(-1) }
            }
            Spacer()
            if step != .done {
                Button("Close") { model.finishOnboarding() }
                    .buttonStyle(.link)
                    .help("You can run the setup assistant again from Settings › General")
            }
            Button(primaryTitle) {
                if step == .done { model.finishOnboarding() } else { move(1) }
            }
            .buttonStyle(GradientButtonStyle(size: .small))
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .done: "Open MergeCue"
        case .accounts where model.state.accounts.isEmpty: "Skip for Now"
        default: "Continue"
        }
    }

    private func move(_ delta: Int) {
        if let next = OnboardingStep(rawValue: step.rawValue + delta) { step = next }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep(model: model)
        case .accounts: AccountsStep(model: model)
        case .repositories: RepositoriesStep(model: model)
        case .agents:
            StepScaffold(title: "Set up your coding agent",
                         subtitle: "MergeCue hands tasks to Claude Code or Codex through its local MCP server. Review exactly what changes in your agent's configuration, register, then verify — an agent counts as connected only after a successful read-only round trip.") {
                AgentSetupList(model: model)
            }
        case .notifications: NotificationsStep(model: model)
        case .done: DoneStep(model: model)
        }
    }
}

/// Title + subtitle + content of a step.
struct StepScaffold<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

// MARK: - Steps

struct WelcomeStep: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: AboutPane.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 120, height: 120)
                .accessibilityLabel("MergeCue app icon")
            Text("MergeCue")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("PRs move forward. You stay in flow.")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 10) {
                point("tray.full", "One inbox for GitHub, GitLab and Bitbucket Cloud: what needs you, what your agent is doing, what's ready.")
                point("sparkles", "Hand a review comment or CI failure to the coding agent you already use. MergeCue runs no model itself.")
                point("lock.shield", "Tokens stay in your Keychain. Nothing is posted, pushed or applied without your approval of an exact preview. No telemetry.")
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.top, 12)
            if model.mode == .demo {
                Label(BackendMode.demo.explanation, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.attention)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AccountsStep: View {
    let model: AppModel
    @State private var expanded: ProviderKind?

    var body: some View {
        StepScaffold(title: "Connect your accounts",
                     subtitle: "MergeCue reads each provider's API directly with a token stored only in your Keychain. Read access is enough; remote writes (replies, resolving threads) stay off until you turn them on per account in Settings, and each one still needs your approval.") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    providerCard(kind)
                }
            }
        }
    }

    private func providerCard(_ kind: ProviderKind) -> some View {
        let connected = model.state.accounts.filter { $0.kind == kind }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProviderGlyph(kind: kind, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind == .gitlab ? "GitLab.com" : kind.displayName).font(.headline)
                        if connected.isEmpty {
                            Text("Not connected").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(connected) { account in
                            Text("@\(account.account.username) · \(UIFormat.syncText(account.status, now: model.now))")
                                .font(.caption)
                                .foregroundStyle(Theme.color(UIFormat.tone(of: account.status.state)))
                        }
                    }
                    Spacer()
                    Button(expanded == kind ? "Hide" : (connected.isEmpty ? "Connect…" : "Add or Reconnect…")) {
                        expanded = expanded == kind ? nil : kind
                    }
                }
                if expanded == kind {
                    ConnectAccountForm(model: model, kind: kind, showsCancel: true) { expanded = nil }
                }
            }
        }
    }
}

struct RepositoriesStep: View {
    let model: AppModel

    var body: some View {
        let repos = model.knownRepositories
        let mapped = Set(model.state.mappings.map(\.repo))
        StepScaffold(title: "Map your repositories",
                     subtitle: "Point each repository to its local checkout. Agents then work in an isolated worktree created from it; MergeCue never edits your checkout directly. Exact remote matches are confirmed automatically; anything less needs your confirmation.") {
            VStack(alignment: .leading, spacing: 12) {
                if repos.isEmpty {
                    HStack(spacing: 10) {
                        if !model.state.accounts.isEmpty { ProgressView().controlSize(.small) }
                        Text(model.state.accounts.isEmpty
                             ? "Connect an account first — repositories with open PRs/MRs appear here."
                             : "Syncing your PRs/MRs… repositories appear here as they arrive. You can also map them later in Settings › Repositories.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(repos, id: \.key) { repo in
                    Card {
                        if let mapping = model.state.mappings.first(where: { $0.repo == repo.key }), mapped.contains(repo.key) {
                            MappingRow(model: model, mapping: mapping)
                        } else {
                            UnmappedRepositoryRow(model: model, repo: repo)
                        }
                    }
                }
            }
        }
    }
}

struct NotificationsStep: View {
    let model: AppModel
    @State private var answer: String?

    var body: some View {
        StepScaffold(title: "Notifications",
                     subtitle: "MergeCue sends one grouped notification per PR/MR when something needs you — a blocking comment, a failed check, a reviewer question — or when your agent's result is ready. Your own comments and green re-runs never notify. Quiet hours and pausing are in Settings › Notifications.") {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    Task {
                        let result = await model.send(.requestNotificationPermission)
                        answer = result?.message
                    }
                } label: {
                    Label("Allow Notifications…", systemImage: "bell.badge")
                }
                .buttonStyle(GradientButtonStyle(size: .small))
                Text("macOS asks you once. Clicking a notification opens the item in MergeCue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let answer {
                    Text(answer).font(.callout).foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }
}

struct DoneStep: View {
    let model: AppModel

    var body: some View {
        let accounts = model.state.accounts.count
        let mapped = model.state.mappings.filter(\.isConfirmed).count
        let agents = model.state.agents.filter { $0.mcpRegistration.isVerified }
        StepScaffold(title: "You're set",
                     subtitle: "MergeCue lives in your menu bar. Click it to see what needs you; open the main window for the full inbox.") {
            VStack(alignment: .leading, spacing: 10) {
                summary("person.crop.circle", accounts == 0 ? "No account connected yet" : "\(accounts) account\(accounts == 1 ? "" : "s") connected", ok: accounts > 0)
                summary("folder", mapped == 0 ? "No repository mapped yet" : "\(mapped) repositor\(mapped == 1 ? "y" : "ies") mapped", ok: mapped > 0)
                summary("terminal", agents.isEmpty ? "No agent verified yet — Copy command still works with any MCP-capable agent"
                                                   : "\(agents.map(\.name).joined(separator: " and ")) connected", ok: !agents.isEmpty)
                Text("Run this assistant again any time from Settings › General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }

    private func summary(_ symbol: String, _ text: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : symbol)
                .foregroundStyle(ok ? Theme.mint : Theme.textTertiary)
                .frame(width: 20)
            Text(text).font(.system(size: 14))
        }
    }
}
