import Foundation

/// Progress of a single-pass checkout scan (`WorkspaceInspecting.scanCheckouts`), counted in directories walked —
/// the number of repositories being matched does not change the amount of work.
public struct CheckoutScanProgress: Sendable, Hashable, Codable {
    /// Directories visited so far (across every search folder).
    public var directoriesScanned: Int
    /// Git checkouts found so far.
    public var checkoutsFound: Int
    /// True once the walk finished and remotes are being matched.
    public var isMatching: Bool

    public init(directoriesScanned: Int = 0, checkoutsFound: Int = 0, isMatching: Bool = false) {
        self.directoriesScanned = directoriesScanned
        self.checkoutsFound = checkoutsFound
        self.isMatching = isMatching
    }
}

/// Outcome of one `scanCheckouts` pass: candidates (exact and probable only) for each repository.
public struct CheckoutScanResult: Sendable, Hashable {
    /// Non-mismatch candidates by repository, exact first. Repositories without candidates are absent.
    public var suggestions: [RepoKey: [MappingSuggestion]]
    public var directoriesScanned: Int
    public var checkoutsFound: Int
    /// True when a bound (directories / checkouts) stopped the walk early.
    public var isTruncated: Bool
    /// True when the task was cancelled before the walk finished.
    public var wasCancelled: Bool

    public init(suggestions: [RepoKey: [MappingSuggestion]] = [:], directoriesScanned: Int = 0, checkoutsFound: Int = 0,
                isTruncated: Bool = false, wasCancelled: Bool = false) {
        self.suggestions = suggestions
        self.directoriesScanned = directoriesScanned
        self.checkoutsFound = checkoutsFound
        self.isTruncated = isTruncated
        self.wasCancelled = wasCancelled
    }
}

extension WorkspaceInspecting {
    /// Default for implementations without a single-pass index (test doubles): the per-repository
    /// `suggestMappings`, one call per repository. `GitWorkspaceInspector` walks the folders once instead.
    public func scanCheckouts(
        for repos: [Repository], searchRoots: [String], progress: @escaping @Sendable (CheckoutScanProgress) -> Void
    ) async -> CheckoutScanResult {
        var result = CheckoutScanResult()
        for repo in repos {
            if Task.isCancelled {
                result.wasCancelled = true
                break
            }
            let found = await suggestMappings(for: repo, searchRoots: searchRoots).filter { $0.confidence != .mismatch }
            if !found.isEmpty { result.suggestions[repo.key] = found }
            result.checkoutsFound += found.count
        }
        progress(CheckoutScanProgress(directoriesScanned: 0, checkoutsFound: result.checkoutsFound, isMatching: true))
        return result
    }
}

/// Result of `MergeCueEngine.previewMapping`: what choosing a folder would map, before anything is saved.
public struct MappingPreview: Sendable, Hashable, Codable, Identifiable {
    public var repository: Repository
    /// The folder the owner chose (may be a subfolder of `suggestion.checkoutPath`).
    public var chosenPath: String
    /// The match against the checkout's top level.
    public var suggestion: MappingSuggestion
    /// False for missing folders and folders that are not git checkouts (never mappable).
    public var isRepository: Bool
    /// "origin → git@github.com:acme/app.git" (sanitized, no credentials).
    public var remotesFound: [String]
    /// Canonical locations of the repository ("github.com/acme/app").
    public var remotesExpected: [String]

    public init(repository: Repository, chosenPath: String, suggestion: MappingSuggestion, isRepository: Bool,
                remotesFound: [String], remotesExpected: [String]) {
        self.repository = repository
        self.chosenPath = chosenPath
        self.suggestion = suggestion
        self.isRepository = isRepository
        self.remotesFound = remotesFound
        self.remotesExpected = remotesExpected
    }

    public var id: String { chosenPath + "|" + suggestion.checkoutPath }

    /// Mismatched but a real checkout: the owner may map it anyway (confirmed mismatches stay usable per the
    /// checkout policy, ranked after exact/probable mappings).
    public var canMapAnyway: Bool { isRepository && suggestion.confidence == .mismatch }
}
