import MergeCueCore
import SwiftUI

/// PRs & MRs across accounts, one section per account with its explicit state (Loading, No PRs/MRs, Offline,
/// Credentials expired, Rate limited, Unsupported permission). A problem on one account never hides the others.
struct ChangeRequestList: View {
    @Bindable var model: AppModel

    var body: some View {
        let sections = ChangeRequestQueryUI.run(state: model.state, filter: model.changeRequestFilter)
        VStack(spacing: 0) {
            filterBar
            Divider()
            if model.state.accounts.isEmpty {
                NothingSelected(title: "No accounts", symbol: "person.crop.circle.badge.plus",
                                message: "Connect GitHub, GitLab or Bitbucket Cloud in Settings › Accounts.")
            } else {
                List(selection: $model.selectedChangeRequestID) {
                    ForEach(sections) { section in
                        Section {
                            if section.listState.isProblem || section.items.isEmpty {
                                AccountListStateRow(model: model, section: section)
                                    .selectionDisabled()
                            }
                            ForEach(section.items) { snapshot in
                                ChangeRequestRow(model: model, snapshot: snapshot)
                                    .tag(snapshot.id as String?)
                            }
                        } header: {
                            AccountSectionHeader(model: model, account: section.account)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle("PRs & MRs")
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Scope", selection: $model.changeRequestFilter.scope) {
                    ForEach(InboxScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 4)
                Toggle("Show closed", isOn: $model.changeRequestFilter.includeClosed)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .fixedSize()
                    .help("Include merged and closed PRs/MRs")
            }
            SearchField(text: $model.changeRequestFilter.searchText, prompt: "Search title, repo, author, #42…")
            HStack(spacing: 6) {
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
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct AccountSectionHeader: View {
    let model: AppModel
    let account: AccountState

    var body: some View {
        HStack(spacing: 6) {
            ProviderGlyph(kind: account.kind, size: 13)
            Text("\(account.kind.displayName) · \(account.account.displayLabel)")
                .font(.caption.weight(.semibold))
                .textCase(nil)
            Spacer()
            Text(UIFormat.syncText(account.status, now: model.now))
                .font(.caption)
                .foregroundStyle(account.status.state.isProblem ? Theme.color(UIFormat.tone(of: account.status.state)) : Color.secondary)
                .textCase(nil)
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
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .credentialsExpired = section.listState {
                    Button("Reconnect…") {
                        model.connectSheetKind = section.account.kind
                        model.showSettings(.accounts)
                    }
                    .controlSize(.small)
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

    var body: some View {
        let summary = snapshot.summary
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ChangeRequestRefLabel(kind: summary.providerKind, repoFullPath: summary.repository.fullPath, number: summary.key.number,
                                      font: .caption, glyphSize: 13)
                Spacer(minLength: 4)
                Text(UIFormat.compactAge(from: summary.updatedAt, now: model.now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(summary.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 8) {
                Text("@\(summary.author.username)")
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(snapshot.approvals.isSatisfied == true ? Theme.mint : Color.secondary)
                        .accessibilityLabel("\(snapshot.approvals.approvedBy.count) of \(required) approvals")
                }
                if snapshot.unresolvedThreadCount > 0 {
                    Label("\(snapshot.unresolvedThreadCount)", systemImage: "bubble.left")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(snapshot.unresolvedThreadCount) unresolved threads")
                }
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
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
