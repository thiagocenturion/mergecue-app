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
    /// Repositories whose folders were searched.
    public var scanned: Int
    /// Mappings created automatically (exactly one exact remote match, auto-confirmed).
    public var mapped: [RepoMapping]
    /// Non-exact (or ambiguous) candidates, for the owner to confirm.
    public var suggestions: [RepoKey: [MappingSuggestion]]
    /// Repositories left out because of `maxRepositories`.
    public var skipped: Int

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
    public static let maxDetectedRepositories = 40

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

    /// Searches `searchRoots` (default `EngineEnvironment.mappingSearchRoots`) for checkouts of up to
    /// `maxRepositories` unmapped repositories, in the given order. A repository with exactly one exact remote match
    /// is mapped (and confirmed, like `addMapping`); other candidates are returned for the owner to confirm.
    /// `progress(done, total)` is called after each repository. Stops early when the task is cancelled.
    public func detectCheckouts(
        for repos: [RepoKey],
        searchRoots: [String]? = nil,
        maxRepositories: Int = MergeCueEngine.maxDetectedRepositories,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws(EngineError) -> CheckoutDetectionReport {
        try await uiCall {
            let roots = searchRoots ?? env.mappingSearchRoots
            let mapped = Set(try await database.mappings(repo: nil).map(\.repo))
            var seen = Set<RepoKey>()
            let candidates = repos.filter { !mapped.contains($0) && seen.insert($0).inserted }
            let batch = Array(candidates.prefix(max(0, maxRepositories)))
            var report = CheckoutDetectionReport(skipped: candidates.count - batch.count)
            progress(0, batch.count)
            guard !roots.isEmpty else {
                progress(batch.count, batch.count)
                return report
            }
            for (index, key) in batch.enumerated() {
                if Task.isCancelled { break }
                defer { progress(index + 1, batch.count) }
                guard let repository = try await findRepository(key) else { continue }
                let found = await env.workspace.suggestMappings(for: repository, searchRoots: roots)
                report.scanned += 1
                let exact = found.filter { $0.confidence == .exact }
                if exact.count == 1, let only = exact.first {
                    let mapping = try await addMapping(repo: key, repoFullPath: repository.fullPath, checkoutPath: only.checkoutPath)
                    if mapping.isConfirmed {
                        report.mapped.append(mapping)
                        continue
                    }
                }
                let others = found.filter { $0.confidence != .mismatch }
                if !others.isEmpty { report.suggestions[key] = others }
            }
            return report
        }
    }
}
