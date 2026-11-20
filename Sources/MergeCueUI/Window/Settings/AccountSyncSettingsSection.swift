import MergeCueCore
import SwiftUI

/// One watched repository row (the full path comes from the repository list, open PRs or the mapping).
struct WatchedRepositoryRow: Identifiable, Hashable {
    var key: RepoKey
    var fullPath: String
    var id: String { key.id }
}

extension AppModel {
    /// The effective watched repositories of `account` (DECISIONS D36), in order; empty = every repository.
    func watchedRepositoryRows(_ account: AccountState) -> [WatchedRepositoryRow] {
        let mappings = state.mappings.filter { $0.repo.account == account.id }
        let keys = WatchedRepositories.effective(for: account.account, mapped: mappings.map(\.repo))
        let listed = (state.repositoryLists[account.id]?.repositories ?? []) + openRepositories(account.id)
        return keys.map { key in
            let path = listed.first { $0.key == key }?.fullPath
                ?? mappings.first { $0.repo == key }?.repoFullPath
                ?? key.remoteRepoID
            return WatchedRepositoryRow(key: key, fullPath: path)
        }
    }
}

/// Settings ▸ Accounts ▸ account: "Check for updates" (the account's refresh interval), followed by the global
/// "Automatic sync" pause and schedule.
struct AccountRefreshIntervalRow: View {
    let model: AppModel
    let account: AccountState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            intervalRow
            Divider()
            AutoSyncScheduleSection(model: model)
        }
    }

    private var intervalRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Check for updates")
                Text(caption)
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Picker("Check for updates", selection: Binding(
                get: { account.account.effectiveRefreshInterval },
                set: { interval in Task { await model.send(.setRefreshInterval(account.id, interval)) } }
            )) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval == .default ? "\(interval.displayName) (default)" : interval.displayName).tag(interval)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Check \(account.kind.displayName) for updates")
        }
    }

    private var caption: String {
        if account.account.effectiveRefreshInterval.isManual {
            return "Only at launch and when you click Refresh. Nothing is checked in the background."
        }
        return "Never more often than this, even when you open MergeCue or CI is running. Click Refresh to check right away."
    }
}

/// Settings ▸ Accounts ▸ account: "Repositories to watch". Only these repositories are synced; the list starts
/// with the repositories mapped to a local checkout.
struct WatchedRepositoriesSection: View {
    let model: AppModel
    let account: AccountState
    @State private var showPicker = false

    var body: some View {
        let rows = model.watchedRepositoryRows(account)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Repositories to watch").scaledFont(.callout.weight(.medium))
                Spacer()
                Button("Add Repository…") { showPicker = true }
                    .accessibilityLabel("Add a repository to watch for \(account.kind.displayName) @\(account.account.username)")
            }
            if rows.isEmpty {
                Label("All repositories are synced. Pick the ones you work on so MergeCue only asks \(account.kind.displayName) about those.",
                      systemImage: "exclamationmark.circle")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(WatchedRepositories.followsMappings(account.account)
                     ? "Only these repositories are synced. They follow your mapped checkouts until you change the list."
                     : "Only these repositories are synced.")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                        Text(row.fullPath).scaledFont(.callout)
                        Spacer()
                        Button("Remove") { remove(row.key, from: rows) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Stop watching \(row.fullPath)")
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            WatchRepositoryPicker(model: model, account: account, watched: Set(rows.map(\.key))) { repository in
                let keys = rows.map(\.key) + [repository.key]
                Task { await model.send(.setWatchedRepositories(account.id, keys)) }
            }
        }
    }

    private func remove(_ key: RepoKey, from rows: [WatchedRepositoryRow]) {
        // Removing the last one leaves an explicit empty list: every repository is synced again (shown above).
        let keys = rows.map(\.key).filter { $0 != key }
        Task { await model.send(.setWatchedRepositories(account.id, keys)) }
    }
}

/// Searchable picker over the account's cached repository list (listed once, on demand; never by Sync).
struct WatchRepositoryPicker: View {
    let model: AppModel
    let account: AccountState
    let watched: Set<RepoKey>
    let onPick: (Repository) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private static let visibleLimit = 60

    var body: some View {
        let list = model.state.repositoryLists[account.id]
        let candidates = RepositoryDirectory.otherRepositories(list?.repositories ?? [], excluding: watched, search: search)
        VStack(alignment: .leading, spacing: 12) {
            Text("Watch a repository")
                .scaledFont(.headline)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("\(account.kind.displayName) · @\(account.account.username). Only watched repositories are synced.")
                .scaledFont(.caption)
                .foregroundStyle(Theme.textSecondary)
            SearchField(text: $search, prompt: "Search repositories")
            if list?.isLoading ?? true {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading repositories…").scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            if let error = list?.errorMessage {
                Label("Couldn't list repositories: \(error)", systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption)
                    .foregroundStyle(Theme.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(candidates.prefix(Self.visibleLimit), id: \.key) { repository in
                        Button {
                            onPick(repository)
                            dismiss()
                        } label: {
                            HStack {
                                Text(repository.fullPath).scaledFont(.callout).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(Theme.accent)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Watch \(repository.fullPath)")
                    }
                    if candidates.isEmpty, !(list?.isLoading ?? true) {
                        Text(search.isEmpty ? "No other repositories." : "No repository matches “\(search)”.")
                            .scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if candidates.count > Self.visibleLimit {
                        Text("Showing \(Self.visibleLimit) of \(candidates.count). Search to narrow the list.")
                            .scaledFont(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 360)
            HStack {
                Button("Reload List") { Task { await model.send(.loadRepositories(account.id, forceRefresh: true)) } }
                    .disabled(list?.isLoading ?? true)
                    .help("Asks \(account.kind.displayName) for the account's repositories again")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Theme.windowBackground)
        .task {
            if model.state.repositoryLists[account.id] == nil {
                await model.send(.loadRepositories(account.id, forceRefresh: false))
            }
        }
    }
}
