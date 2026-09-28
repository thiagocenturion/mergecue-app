import MergeCueCore
import SwiftUI

/// Repositories of every connected account, for mapping (onboarding and Settings › Repositories): per account the
/// repositories with open PRs/MRs first, then a searchable list of the account's other repositories. The local
/// checkout scan runs once the listings settle; exact remote matches are mapped automatically.
struct AccountRepositoriesSection: View {
    let model: AppModel
    @State private var scanStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CheckoutScanStatus(model: model) { startScan(force: true) }
            ForEach(model.state.accounts) { account in
                AccountRepositoriesCard(model: model, account: account)
            }
        }
        .task { await model.loadMissingRepositoryLists() }
        .onChange(of: model.repositoryListsSettled, initial: true) { _, settled in
            if settled { startScan(force: false) }
        }
    }

    private func startScan(force: Bool) {
        guard force || !scanStarted, !model.state.checkoutScan.isRunning else { return }
        let candidates = model.checkoutScanCandidates
        guard !candidates.isEmpty else { return }
        scanStarted = true
        Task { await model.send(.scanCheckouts(candidates)) }
    }
}

/// Progress and outcome of the local checkout scan.
private struct CheckoutScanStatus: View {
    let model: AppModel
    var rescan: () -> Void

    var body: some View {
        let scan = model.state.checkoutScan
        HStack(spacing: 10) {
            if scan.isRunning {
                ProgressView(value: Double(scan.done), total: Double(max(scan.total, 1)))
                    .frame(width: 120)
                Text("Looking for checkouts in your usual folders… \(scan.done) of \(scan.total)")
            } else if let error = scan.errorMessage {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                Text("Checkout search failed: \(error)")
            } else if scan.finishedAt != nil {
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.mint)
                Text(scan.mappedCount == 0
                     ? "No exact checkout matches found in your usual folders. Use Find Checkouts or Choose Folder… per repository."
                     : "Mapped \(scan.mappedCount) repositor\(scan.mappedCount == 1 ? "y" : "ies") to exact remote matches automatically.")
            }
            Spacer()
            if !scan.isRunning && scan.finishedAt != nil {
                Button("Search Again", action: rescan)
                    .help("Looks in ~/Developer, ~/Projects, ~/Code, ~/src and ~/Documents/GitHub")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One account: its sync phase, repositories with open PRs/MRs, then its other repositories (searchable).
private struct AccountRepositoriesCard: View {
    let model: AppModel
    let account: AccountState
    @State private var search = ""

    private static let visibleLimit = 40

    var body: some View {
        let open = model.openRepositories(account.id)
        let openKeys = Set(open.map(\.key))
        Card("\(account.kind.displayName) · @\(account.account.username)", systemImage: "person.crop.circle") {
            VStack(alignment: .leading, spacing: 10) {
                phaseView
                ForEach(open, id: \.key) { repo in
                    row(repo, hasOpenPRs: true)
                    Divider()
                }
                otherRepositories(excluding: openKeys)
            }
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch model.repositoryPhase(account) {
        case .firstSync:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Syncing @\(account.account.username)'s \(account.kind.changeRequestAbbreviation)s… repositories with open ones appear here.")
            }
            .font(.callout).foregroundStyle(.secondary)
        case .synced(let count) where count == 0:
            Label("No open \(account.kind.changeRequestAbbreviation)s for @\(account.account.username) yet. You can still map any repository below.",
                  systemImage: "tray")
                .font(.callout).foregroundStyle(.secondary)
        case .synced:
            EmptyView()
        case .problem(let title, let message):
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.color(UIFormat.tone(of: account.status.state)))
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func otherRepositories(excluding: Set<RepoKey>) -> some View {
        let list = model.state.repositoryLists[account.id]
        let others = RepositoryDirectory.otherRepositories(list?.repositories ?? [], excluding: excluding, search: search)
        HStack(spacing: 8) {
            Text("Other repositories").font(.callout.weight(.medium))
            if list?.isLoading ?? true {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reload") { Task { await model.send(.loadRepositories(account.id, forceRefresh: true)) } }
                .disabled(list?.isLoading ?? true)
                .help("Asks \(account.kind.displayName) for the account's repositories again")
        }
        if let error = list?.errorMessage {
            Label("Couldn't list repositories: \(error)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Theme.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !(list?.repositories.isEmpty ?? true) {
            SearchField(text: $search, prompt: "Search repositories")
            if others.isEmpty {
                Text(search.isEmpty ? "No other repositories." : "No repository matches “\(search)”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(others.prefix(Self.visibleLimit), id: \.key) { repo in
                row(repo, hasOpenPRs: false)
            }
            if others.count > Self.visibleLimit {
                Text("Showing \(Self.visibleLimit) of \(others.count) — search to narrow the list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if case .loaded? = list {
            Text("No repositories found for this account.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func row(_ repo: Repository, hasOpenPRs: Bool) -> some View {
        if let mapping = model.state.mappings.first(where: { $0.repo == repo.key }) {
            MappingRow(model: model, mapping: mapping)
        } else {
            UnmappedRepositoryRow(model: model, repo: repo, hasOpenPRs: hasOpenPRs)
        }
    }
}
