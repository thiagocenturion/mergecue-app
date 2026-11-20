import Foundation
import MergeCueCore
import MergeCueStore

// Per-account sync settings (DECISIONS D36): the repositories to watch (Sync lists only their PRs/MRs, with scoped
// provider queries) and the refresh interval ("Check for updates"). Both live on `Account` (additive, persisted with
// the account row) and reach Sync through `accountsDidChange()`, which applies them in place.

/// The repositories one account syncs, for Settings ▸ Accounts ▸ "Repositories to watch".
public struct WatchedRepositoriesState: Sendable, Hashable {
    public var account: AccountKey
    /// The effective watched repositories, in order (empty = every repository of the account is synced).
    public var repositories: [Repository]
    /// True while the owner never edited the list: it follows the checkout mappings.
    public var followsMappings: Bool

    public init(account: AccountKey, repositories: [Repository], followsMappings: Bool) {
        self.account = account
        self.repositories = repositories
        self.followsMappings = followsMappings
    }

    /// Nothing chosen: all repositories are synced (the UI nudges to pick some).
    public var watchesAll: Bool { repositories.isEmpty }
}

extension MergeCueEngine {
    /// The effective watched repositories of `key` (explicit list, else the mapped repositories, else all).
    public func watchedRepositories(_ key: AccountKey) async throws(EngineError) -> WatchedRepositoriesState {
        try await uiCall {
            let account = try await requireAccount(key)
            let mappings = try await database.mappings(repo: nil).filter { $0.repo.account == key }
            let keys = WatchedRepositories.effective(for: account, mapped: mappings.map(\.repo))
            var repositories: [Repository] = []
            for repo in keys {
                if let found = try await findRepository(repo) {
                    repositories.append(found)
                } else if let mapping = mappings.first(where: { $0.repo == repo }) {
                    repositories.append(Self.placeholderRepository(repo, fullPath: mapping.repoFullPath, instance: account.instance))
                }
            }
            return WatchedRepositoriesState(account: key, repositories: repositories, followsMappings: WatchedRepositories.followsMappings(account))
        }
    }

    /// Replaces the watched repositories (explicit order kept, duplicates and other accounts' repositories
    /// dropped). `nil` returns to the default (follow the checkout mappings); an empty list syncs every repository.
    /// Sync lists again right away.
    public func setWatchedRepositories(_ key: AccountKey, _ repositories: [RepoKey]?) async throws(EngineError) {
        try await uiCall {
            var account = try await requireAccount(key)
            var seen = Set<RepoKey>()
            account.watchedRepositories = repositories?.filter { $0.account == key && seen.insert($0).inserted }
            try await database.upsertAccount(account)
            await appendAudit(
                actor: "user", action: "set_watched_repositories", target: "\(key.kind.rawValue):\(key.host)",
                outcome: .succeeded,
                detail: account.watchedRepositories.map { $0.isEmpty ? "All repositories" : "\($0.count) repositories" }
                    ?? "Follow checkout mappings"
            )
            await env.sync.accountsDidChange()
            emit(.accounts)
        }
    }

    /// Sets how often the account checks for updates (Sync applies it from the next scheduling decision).
    public func setRefreshInterval(_ key: AccountKey, _ interval: RefreshInterval) async throws(EngineError) {
        try await uiCall {
            var account = try await requireAccount(key)
            guard account.refreshInterval != interval else { return }
            account.refreshInterval = interval
            try await database.upsertAccount(account)
            await env.sync.accountsDidChange()
            emit(.accounts)
            emit(.syncStatus)
        }
    }

    /// A new checkout mapping also watches its repository when the owner keeps an explicit, non-empty list (the
    /// default list follows mappings already; an explicit empty list means "all" and stays so). Sync reloads either
    /// way, since the default watched list may have changed.
    func watchMappedRepository(_ repo: RepoKey) async throws {
        if var account = try await database.account(repo.account), let explicit = account.watchedRepositories,
           !explicit.isEmpty, !explicit.contains(repo) {
            account.watchedRepositories = explicit + [repo]
            try await database.upsertAccount(account)
            emit(.accounts)
        }
        await env.sync.accountsDidChange()
    }

    static func placeholderRepository(_ key: RepoKey, fullPath: String, instance: ProviderInstance) -> Repository {
        let trimmed = fullPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let slash = trimmed.lastIndex(of: "/")
        return Repository(
            key: key,
            namespacePath: slash.map { String(trimmed[..<$0]) } ?? "",
            name: slash.map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed,
            fullPath: trimmed,
            webURL: instance.webURL.appending(path: trimmed)
        )
    }
}
