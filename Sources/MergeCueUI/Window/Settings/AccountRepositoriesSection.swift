import MergeCueCore
import SwiftUI

/// Repositories of every connected account, for mapping (onboarding and Settings › Repositories): per account the
/// repositories with open PRs/MRs first, then a searchable list of the account's other repositories. The local
/// checkout scan never starts by itself: one "Find Checkouts" button walks the search folders once and maps exact
/// remote matches automatically; every row also offers "Choose Folder…".
struct AccountRepositoriesSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CheckoutScanBar(model: model)
            ForEach(model.state.accounts) { account in
                AccountRepositoriesCard(model: model, account: account)
            }
        }
        .task { await model.loadMissingRepositoryLists() }
    }
}

/// The screen-level "Find Checkouts" button with the scan's progress (folders checked) and outcome.
struct CheckoutScanBar: View {
    let model: AppModel

    var body: some View {
        let scan = model.state.checkoutScan
        let candidates = model.checkoutScanCandidates
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if scan.isRunning {
                    ProgressView().controlSize(.small)
                    Text(scan.progressText)
                        .monospacedDigit()
                    Spacer()
                    Button("Cancel") { Task { await model.send(.cancelCheckoutScan) } }
                        .accessibilityLabel("Cancel the checkout search")
                } else {
                    Text(candidates.isEmpty
                         ? "Every listed repository is mapped."
                         : "Find local clones of \(candidates.count) unmapped repositor\(candidates.count == 1 ? "y" : "ies") in your search folders.")
                    Spacer()
                    Button(scan.finishedAt == nil ? "Find Checkouts" : "Find Again") {
                        Task { await model.send(.scanCheckouts(candidates)) }
                    }
                    .buttonStyle(GradientButtonStyle(size: .small))
                    .disabled(candidates.isEmpty)
                    .help("Walks \(searchFoldersHelp) once (4 levels deep) and matches every unmapped repository by its remotes")
                    .accessibilityLabel("Find checkouts for unmapped repositories")
                }
            }
            if !scan.isRunning, let summary = scan.summaryText {
                HStack(spacing: 6) {
                    if scan.errorMessage != nil {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                    } else if !scan.wasCancelled {
                        Image(systemName: "checkmark.circle").foregroundStyle(Theme.mint)
                    }
                    Text(summary)
                        .foregroundStyle(scan.errorMessage != nil ? Theme.attentionText : Theme.textSecondary)
                }
            }
        }
        .scaledFont(.callout)
        .foregroundStyle(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var searchFoldersHelp: String {
        let folders = model.state.checkoutSearchFolders
        return folders.isEmpty ? "your search folders" : folders.map(UIFormat.abbreviatedPath).joined(separator: ", ")
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
            .scaledFont(.callout).foregroundStyle(Theme.textSecondary)
        case .synced(let count) where count == 0:
            Label("No open \(account.kind.changeRequestAbbreviation)s for @\(account.account.username) yet. You can still map any repository below.",
                  systemImage: "tray")
                .scaledFont(.callout).foregroundStyle(Theme.textSecondary)
        case .synced:
            EmptyView()
        case .problem(let title, let message):
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.textColor(UIFormat.tone(of: account.status.state)))
                if let message {
                    Text(message).scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .scaledFont(.callout)
        }
    }

    @ViewBuilder
    private func otherRepositories(excluding: Set<RepoKey>) -> some View {
        let list = model.state.repositoryLists[account.id]
        let others = RepositoryDirectory.otherRepositories(list?.repositories ?? [], excluding: excluding, search: search)
        HStack(spacing: 8) {
            Text("Other repositories").scaledFont(.callout.weight(.medium))
            if list?.isLoading ?? true {
                ProgressView().controlSize(.small)
                Text("Loading…").scaledFont(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Reload") { Task { await model.send(.loadRepositories(account.id, forceRefresh: true)) } }
                .disabled(list?.isLoading ?? true)
                .help("Asks \(account.kind.displayName) for the account's repositories again")
        }
        if let error = list?.errorMessage {
            Label("Couldn't list repositories: \(error)", systemImage: "exclamationmark.triangle")
                .scaledFont(.caption)
                .foregroundStyle(Theme.attentionText)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !(list?.repositories.isEmpty ?? true) {
            SearchField(text: $search, prompt: "Search repositories")
            if others.isEmpty {
                Text(search.isEmpty ? "No other repositories." : "No repository matches “\(search)”.")
                    .scaledFont(.caption).foregroundStyle(Theme.textSecondary)
            }
            ForEach(others.prefix(Self.visibleLimit), id: \.key) { repo in
                row(repo, hasOpenPRs: false)
            }
            if others.count > Self.visibleLimit {
                Text("Showing \(Self.visibleLimit) of \(others.count) — search to narrow the list.")
                    .scaledFont(.caption).foregroundStyle(Theme.textSecondary)
            }
        } else if case .loaded? = list {
            Text("No repositories found for this account.").scaledFont(.caption).foregroundStyle(Theme.textSecondary)
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
