import Foundation
import MergeCueCore
import MergeCueStore

// Repository directory: every repository an account can map (not only the ones with open PRs/MRs), listed through
// the provider (`ReviewProvider.listRepositories(namespace:)`, bounded and paginated by the adapter), restricted to
// the account's selected namespaces and cached in the store with a TTL. Plus a bounded local checkout scan that maps
// exact remote matches automatically (the same rule as `addMapping`).

/// Repositories of one account, from the provider or the store cache.
public struct RepositoryListing: Sendable, Hashable {
    public var account: AccountKey
    /// Sorted by full path; archived repositories are left out by the adapters.
    public var repositories: [Repository]
    /// When the provider was last asked.
    public var fetchedAt: Date
    /// True when served from the store without contacting the provider.
    public var fromCache: Bool
    /// True when the result hit `MergeCueEngine.maxListedRepositories`.
    public var isTruncated: Bool

    public init(account: AccountKey, repositories: [Repository], fetchedAt: Date, fromCache: Bool, isTruncated: Bool) {
        self.account = account
        self.repositories = repositories
        self.fetchedAt = fetchedAt
        self.fromCache = fromCache
        self.isTruncated = isTruncated
    }
}

/// Outcome of `detectCheckouts(for:)`.
public struct CheckoutDetectionReport: Sendable, Hashable {
    /// Repositories matched against the scanned checkouts.
    public var scanned: Int
    /// Mappings created automatically (exactly one exact remote match, auto-confirmed).
    public var mapped: [RepoMapping]
    /// Non-exact (or ambiguous) candidates, for the owner to confirm.
    public var suggestions: [RepoKey: [MappingSuggestion]]
    /// Repositories left out because of `maxRepositories`.
    public var skipped: Int
    /// Directories walked by the single scan pass.
    public var directoriesScanned: Int = 0
    /// Git checkouts found by the walk.
    public var checkoutsFound: Int = 0
    /// A bound stopped the walk early.
    public var isTruncated: Bool = false
    /// The scan was cancelled; nothing was mapped.
    public var wasCancelled: Bool = false

    public init(scanned: Int = 0, mapped: [RepoMapping] = [], suggestions: [RepoKey: [MappingSuggestion]] = [:], skipped: Int = 0) {
        self.scanned = scanned
        self.mapped = mapped
        self.suggestions = suggestions
        self.skipped = skipped
    }
}

extension MergeCueEngine {
    /// How long a repository listing is served from the store before the provider is asked again.
    public static let repositoryListTTL: TimeInterval = 6 * 3_600
    /// Upper bound of repositories kept per account listing.
    public static let maxListedRepositories = 1_000
    /// Default upper bound of repositories searched by one `detectCheckouts` call.
    public static let maxDetectedRepositories = 1_000

    /// Every repository the account can access (its selected namespaces only, when any are selected). Served from
    /// the store while younger than `repositoryListTTL` unless `forceRefresh`. Provider failures throw
    /// `EngineError.provider`; the cache is left untouched.
    public func accountRepositories(_ key: AccountKey, forceRefresh: Bool = false) async throws(EngineError) -> RepositoryListing {
        try await uiCall {
            let account = try await requireAccount(key)
            let stampKey = SettingsKey.repositoryListFetchedAt(key)
            if !forceRefresh, let fetchedAt = try await database.setting(stampKey, as: Date.self),
               now.timeIntervalSince(fetchedAt) < Self.repositoryListTTL, fetchedAt <= now {
                let cached = try await database.repositories(account: key)
                return RepositoryListing(account: key, repositories: cached, fetchedAt: fetchedAt, fromCache: true,
                                         isTruncated: cached.count >= Self.maxListedRepositories)
            }
            let provider = try await provider(for: key)
            var collected: [Repository] = []
            if account.selectedNamespaces.isEmpty {
                collected = try await provider.listRepositories(namespace: nil)
            } else {
                let wanted = Set(account.selectedNamespaces.map { $0.lowercased() })
                let namespaces = try await provider.listNamespaces().filter { wanted.contains($0.path.lowercased()) }
                for namespace in namespaces where collected.count < Self.maxListedRepositories {
                    try Task.checkCancellation()
                    collected += try await provider.listRepositories(namespace: namespace)
                }
            }
            var seen = Set<RepoKey>()
            let unique = collected.filter { $0.key.account == key && seen.insert($0.key).inserted }
                .sorted { $0.fullPath.lowercased() < $1.fullPath.lowercased() }
            let bounded = Array(unique.prefix(Self.maxListedRepositories))
            try await database.upsertRepositories(bounded)
            try await database.setSetting(stampKey, now)
            return RepositoryListing(account: key, repositories: bounded, fetchedAt: now, fromCache: false,
                                     isTruncated: unique.count > bounded.count)
        }
    }

    /// Finds checkouts of the unmapped `repos` (at most `maxRepositories`, in order) with ONE bounded, cancellable
    /// walk of `searchRoots` (default: `checkoutSearchFolders()`): every git checkout found is indexed by its
    /// canonical remotes and all repositories are matched in a single pass (`WorkspaceInspecting.scanCheckouts`).
    /// A repository with exactly one exact remote match is mapped (and confirmed, like `addMapping`); other
    /// candidates are returned for the owner to confirm. `progress` reports directories walked and checkouts found.
    public func detectCheckouts(
        for repos: [RepoKey],
        searchRoots: [String]? = nil,
        maxRepositories: Int = MergeCueEngine.maxDetectedRepositories,
        progress: @escaping @Sendable (CheckoutScanProgress) -> Void = { _ in }
    ) async throws(EngineError) -> CheckoutDetectionReport {
        try await uiCall {
            var roots: [String] = []
            if let searchRoots {
                roots = searchRoots
            } else {
                roots = await checkoutSearchFolders()
            }
            let mapped = Set(try await database.mappings(repo: nil).map(\.repo))
            var seen = Set<RepoKey>()
            let candidates = repos.filter { !mapped.contains($0) && seen.insert($0).inserted }
            let batch = Array(candidates.prefix(max(0, maxRepositories)))
            var report = CheckoutDetectionReport(skipped: candidates.count - batch.count)
            var repositories: [Repository] = []
            for key in batch {
                if let repository = try await findRepository(key) { repositories.append(repository) }
            }
            report.scanned = repositories.count
            guard !roots.isEmpty, !repositories.isEmpty else { return report }
            let workspace = env.workspace
            let scan = await Task.detached(priority: .utility) {
                await workspace.scanCheckouts(for: repositories, searchRoots: roots, progress: progress)
            }.valueCancellingOnCancel()
            report.directoriesScanned = scan.directoriesScanned
            report.checkoutsFound = scan.checkoutsFound
            report.isTruncated = scan.isTruncated
            report.wasCancelled = scan.wasCancelled || Task.isCancelled
            for repository in repositories where !report.wasCancelled {
                let found = scan.suggestions[repository.key] ?? []
                let exact = found.filter { $0.confidence == .exact }
                if exact.count == 1, let only = exact.first {
                    let mapping = try await addMapping(repo: repository.key, repoFullPath: repository.fullPath, checkoutPath: only.checkoutPath)
                    if mapping.isConfirmed {
                        report.mapped.append(mapping)
                        continue
                    }
                }
                let others = found.filter { $0.confidence != .mismatch }
                if !others.isEmpty { report.suggestions[repository.key] = others }
            }
            return report
        }
    }

    // MARK: Search folders

    /// The folders `detectCheckouts` searches: the owner's list (Settings ▸ Repositories ▸ Search folders), else
    /// `EngineEnvironment.mappingSearchRoots`. Folders that do not exist are skipped by the scan.
    public func checkoutSearchFolders() async -> [String] {
        (try? await database.setting(SettingsKey.checkoutSearchFolders, as: [String].self)) ?? env.mappingSearchRoots
    }

    /// Replaces the search folders (absolute or `~/` paths; duplicates dropped). nil restores the defaults.
    @discardableResult
    public func setCheckoutSearchFolders(_ folders: [String]?) async throws(EngineError) -> [String] {
        try await uiCall {
            guard let folders else {
                try await database.removeSetting(SettingsKey.checkoutSearchFolders)
                emit(.mappings)
                return env.mappingSearchRoots
            }
            var seen = Set<String>()
            var cleaned: [String] = []
            for folder in folders {
                let path = ((folder.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath as NSString).standardizingPath
                guard !path.isEmpty else { continue }
                guard path.hasPrefix("/") else {
                    throw EngineError.invalidInput("Search folders must be absolute paths (\(folder)).")
                }
                if seen.insert(path).inserted { cleaned.append(path) }
            }
            try await database.setSetting(SettingsKey.checkoutSearchFolders, cleaned)
            emit(.mappings)
            return cleaned
        }
    }
}

extension Task where Failure == Never {
    /// Awaits the value, cancelling the task when the awaiting task is cancelled.
    func valueCancellingOnCancel() async -> Success {
        await withTaskCancellationHandler { await value } onCancel: { cancel() }
    }
}
