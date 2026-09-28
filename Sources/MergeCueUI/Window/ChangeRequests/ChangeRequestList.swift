import MergeCueCore
import SwiftUI

/// Pull and merge requests across accounts, one section per account with its explicit state (Loading, No PRs/MRs,
/// Offline, Credentials expired, Rate limited, Unsupported permission). A problem on one account never hides the others.
struct ChangeRequestList: View {
    @Bindable var model: AppModel

    var body: some View {
        let sections = ChangeRequestQueryUI.run(state: model.state, filter: model.changeRequestFilter)
        VStack(alignment: .leading, spacing: 0) {
            filterBar
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            ThemeDivider()
            if model.state.accounts.isEmpty {
                NothingSelected(title: "No accounts", symbol: "person.crop.circle.badge.plus",
                                message: "Connect GitHub, GitLab or Bitbucket Cloud in Settings › Accounts.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(sections) { section in
                            AccountSectionHeader(model: model, account: section.account)
                                .padding(.top, 12)
                                .padding(.horizontal, 6)
                            if section.listState.isProblem || section.items.isEmpty {
                                AccountListStateRow(model: model, section: section)
                                    .padding(12)
                                    .cardBackground(Theme.surface, radius: 11)
                            }
                            ForEach(section.items) { snapshot in
                                ChangeRequestRow(model: model, snapshot: snapshot, isSelected: model.selectedChangeRequestID == snapshot.id)
                                    .onTapGesture {
                                        model.selectedChangeRequestID = snapshot.id
                                        model.changeRequestTab = .conversation
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pull requests")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            SearchField(text: $model.changeRequestFilter.searchText, prompt: "Search title, repo, author, #42…")
            HStack(spacing: 8) {
                FilterMenu(title: model.changeRequestFilter.scope.title, isActive: model.changeRequestFilter.scope != .all) {
                    ForEach(InboxScope.allCases) { scope in
                        Button(scope.title) { model.changeRequestFilter.scope = scope }
                    }
                }
                FilterMenu(title: model.changeRequestFilter.provider?.displayName ?? "Provider", isActive: model.changeRequestFilter.provider != nil) {
                    Button("Any Provider") { model.changeRequestFilter.provider = nil }
                    Divider()
                    ForEach(ProviderKind.allCases, id: \.self) { kind in
                        Button(kind.displayName) { model.changeRequestFilter.provider = kind }
                    }
                }
                FilterMenu(title: model.changeRequestFilter.account.map { model.accountTitle($0) } ?? "Account",
                           isActive: model.changeRequestFilter.account != nil) {
                    Button("Any Account") { model.changeRequestFilter.account = nil }
                    Divider()
                    ForEach(model.state.accounts) { account in
                        Button(model.accountTitle(account.id)) { model.changeRequestFilter.account = account.id }
                    }
                }
                Spacer(minLength: 0)
                Toggle("Closed", isOn: $model.changeRequestFilter.includeClosed)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                    .help("Include merged and closed PRs/MRs")
            }
        }
    }
}

struct AccountSectionHeader: View {
    let model: AppModel
    let account: AccountState

    var body: some View {
        HStack(spacing: 6) {
            ProviderGlyph(kind: account.kind, size: 14)
            Text("\(account.kind.shortName) · \(account.account.displayLabel)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(UIFormat.syncText(account.status, now: model.now))
                .font(.system(size: 11.5))
                .foregroundStyle(account.status.state.isProblem ? Theme.color(UIFormat.tone(of: account.status.state)) : Theme.textSecondary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Explicit per-account state inside the PR/MR list.
struct AccountListStateRow: View {
    let model: AppModel
    let section: AccountChangeRequests

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.color(tone))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .credentialsExpired = section.listState {
                    Button("Reconnect…") {
                        model.connectSheetKind = section.account.kind
                        model.showSettings(.accounts)
                    }
                    .buttonStyle(SecondaryButtonStyle(size: .small))
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch section.listState {
        case .loading: "Loading…"
        case .empty, .ok: "No \(section.account.kind.changeRequestNounPlural) here"
        case .offline: "Offline"
        case .credentialsExpired: "Credentials expired"
        case .rateLimited(let until): until.map { "Rate limited until \(UIFormat.time($0))" } ?? "Rate limited"
        case .unsupportedPermission: "Unsupported permission"
        case .error: "Sync error"
        }
    }

    private var message: String {
        let stale = section.account.status.lastSuccessAt.map { "Showing data from \(UIFormat.time($0))." } ?? ""
        switch section.listState {
        case .loading: return "Fetching \(section.account.kind.changeRequestNounPlural) for the first time."
        case .empty, .ok: return "Nothing open where you're the author or a requested reviewer."
        case .offline: return "MergeCue retries automatically when the network is back. \(stale)"
        case .credentialsExpired: return "The token was revoked or expired. Other accounts keep syncing. \(stale)"
        case .rateLimited: return "\(section.account.kind.displayName) asked MergeCue to slow down; syncing resumes on its own. \(stale)"
        case .unsupportedPermission(let detail): return "\(detail). Reconnect with the scopes listed in Settings › Accounts."
        case .error(let detail): return "\(detail) \(stale)"
        }
    }

    private var symbol: String {
        switch section.listState {
        case .loading: "arrow.triangle.2.circlepath"
        case .empty, .ok: "tray"
        case .offline: "wifi.slash"
        case .credentialsExpired: "key.slash"
        case .rateLimited: "gauge.with.dots.needle.100percent"
        case .unsupportedPermission: "lock.slash"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tone: Tone {
        switch section.listState {
        case .loading, .empty, .ok: .neutral
        case .offline, .rateLimited: .attention
        case .credentialsExpired, .unsupportedPermission, .error: .critical
        }
    }
}

struct ChangeRequestRow: View {
    let model: AppModel
    let snapshot: ChangeRequestSnapshot
    var isSelected = false
    @State private var isHovering = false

    var body: some View {
        let summary = snapshot.summary
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ChangeRequestRefLabel(kind: summary.providerKind, repoFullPath: summary.repository.fullPath, number: summary.key.number,
                                      font: .system(size: 12), glyphSize: 13)
                Spacer(minLength: 4)
                Text(UIFormat.compactAge(from: summary.updatedAt, now: model.now))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(summary.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("@\(summary.author.username)")
                    .foregroundStyle(Theme.textSecondary)
                if summary.involvement.contains(.reviewRequested) {
                    Chip(text: "Reviewing", symbol: "eye", tone: .progress)
                } else if summary.involvement.contains(.authored) {
                    Chip(text: "Mine", symbol: "person")
                }
                if summary.isDraft { Chip(text: "Draft") }
                if summary.state != .open { Chip(text: summary.state == .merged ? "Merged" : "Closed", tone: summary.state == .merged ? .success : .neutral) }
                Spacer(minLength: 4)
                ChecksBadge(state: snapshot.aggregateCheckState)
                if let required = snapshot.approvals.requiredCount {
                    Label("\(snapshot.approvals.approvedBy.count)/\(required)", systemImage: "hand.thumbsup")
                        .foregroundStyle(snapshot.approvals.isSatisfied == true ? Theme.mint : Theme.textSecondary)
                        .accessibilityLabel("\(snapshot.approvals.approvedBy.count) of \(required) approvals")
                }
                if snapshot.unresolvedThreadCount > 0 {
                    Label("\(snapshot.unresolvedThreadCount)", systemImage: "bubble.left")
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel("\(snapshot.unresolvedThreadCount) unresolved threads")
                }
            }
            .font(.system(size: 11.5))
            .labelStyle(.titleAndIcon)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(isSelected ? Theme.surfaceSelected : (isHovering ? Theme.surfaceHover : Theme.surface)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(isSelected ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: isSelected ? 1.3 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}

struct ChecksBadge: View {
    var state: AggregateCheckState

    var body: some View {
        switch state {
        case .none: EmptyView()
        case .passing: Label("Checks", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.mint).accessibilityLabel("Checks passing")
        case .failing: Label("Failing", systemImage: "xmark.circle.fill").foregroundStyle(Theme.critical).accessibilityLabel("Checks failing")
        case .pending: Label("Running", systemImage: "circle.dotted.circle").foregroundStyle(Theme.accent).accessibilityLabel("Checks running")
        }
    }
}
