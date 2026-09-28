import Foundation
import MergeCueCore

/// Listing of one account's repositories (every repository it can access, not only those with open PRs/MRs).
public nonisolated enum RepositoryListState: Sendable, Hashable {
    case loading(previous: [Repository])
    case loaded([Repository], fetchedAt: Date, isTruncated: Bool)
    case failed(String, previous: [Repository])

    /// What to show now (the previous listing while reloading or after a failure).
    public var repositories: [Repository] {
        switch self {
        case .loading(let previous), .failed(_, let previous): previous
        case .loaded(let repositories, _, _): repositories
        }
    }

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var errorMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }
}

/// Progress of the local checkout scan (exact remote matches are mapped automatically).
public nonisolated struct CheckoutScanState: Sendable, Hashable {
    public var isRunning: Bool
    public var done: Int
    public var total: Int
    /// Repositories mapped automatically by the last scan.
    public var mappedCount: Int
    /// Candidates that need the owner's confirmation, by repository.
    public var suggestions: [RepoKey: [MappingSuggestion]]
    public var finishedAt: Date?
    public var errorMessage: String?

    public init(isRunning: Bool = false, done: Int = 0, total: Int = 0, mappedCount: Int = 0,
                suggestions: [RepoKey: [MappingSuggestion]] = [:], finishedAt: Date? = nil, errorMessage: String? = nil) {
        self.isRunning = isRunning
        self.done = done
        self.total = total
        self.mappedCount = mappedCount
        self.suggestions = suggestions
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }

    public static let idle = CheckoutScanState()
}

/// What the repositories step / pane shows for one account's PR-backed repositories.
public nonisolated enum AccountRepositoryPhase: Sendable, Hashable {
    /// The first sync is still running: repositories with open PRs/MRs are not known yet.
    case firstSync
    /// Synced; `count` repositories have open PRs/MRs (0 = the empty state).
    case synced(count: Int)
    /// Sync failed or is blocked; the account's real state and message.
    case problem(title: String, message: String?)
}

public nonisolated enum RepositoryDirectory {
    /// Spinner only while the account has never synced successfully and a sync is (about to be) running; a problem
    /// state shows the real reason; otherwise the (possibly empty) PR-backed repository count.
    public static func phase(status: AccountSyncStatus, openRepositoryCount: Int, now: Date) -> AccountRepositoryPhase {
        switch status.state {
        case .offline, .authExpired, .rateLimited, .permissionDenied, .error, .paused:
            if openRepositoryCount > 0 && status.lastSuccessAt != nil { return .synced(count: openRepositoryCount) }
            return .problem(title: UIFormat.syncText(status, now: now), message: problemMessage(status))
        case .syncing, .idle:
            if status.lastSuccessAt == nil && openRepositoryCount == 0 { return .firstSync }
            return .synced(count: openRepositoryCount)
        case .ok:
            return .synced(count: openRepositoryCount)
        }
    }

    static func problemMessage(_ status: AccountSyncStatus) -> String? {
        let detail: String? = switch status.state {
        case .permissionDenied(let message), .error(let message): message
        case .authExpired: "Reconnect the account in Settings › Accounts with a new token."
        case .offline: "MergeCue retries when the network is back."
        case .rateLimited: "MergeCue waits for the provider's limit to reset, then syncs again."
        case .paused: "Syncing is paused for this account."
        default: nil
        }
        let text = [status.message, detail].compactMap { $0 }.filter { !$0.isEmpty }.first
        return text.map(SecretRedactor.redact)
    }

    /// Repositories with open PRs/MRs of one account (from the synced snapshots), sorted by path.
    public static func openRepositories(_ changeRequests: [ChangeRequestSnapshot], account: AccountKey) -> [Repository] {
        var seen = Set<RepoKey>()
        return changeRequests.map(\.summary.repository)
            .filter { $0.key.account == account && seen.insert($0.key).inserted }
            .sorted { $0.fullPath.lowercased() < $1.fullPath.lowercased() }
    }

    /// The account's other repositories (not in `excluding`), filtered by a case-insensitive search of the path.
    public static func otherRepositories(_ listed: [Repository], excluding: Set<RepoKey>, search: String) -> [Repository] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return listed.filter { repo in
            !excluding.contains(repo.key) && (query.isEmpty || repo.fullPath.lowercased().contains(query))
        }
    }
}

// MARK: - AppModel

extension AppModel {
    /// Phase of an account's PR-backed repositories (spinner only during the first sync).
    public func repositoryPhase(_ account: AccountState) -> AccountRepositoryPhase {
        RepositoryDirectory.phase(status: account.status,
                                  openRepositoryCount: openRepositories(account.id).count, now: now)
    }

    /// Repositories of the account with open PRs/MRs.
    public func openRepositories(_ account: AccountKey) -> [Repository] {
        RepositoryDirectory.openRepositories(state.changeRequests, account: account)
    }

    /// Asks for the repository listing of every account that has none yet (cached by the engine).
    public func loadMissingRepositoryLists() async {
        for account in state.accounts where state.repositoryLists[account.id] == nil {
            await send(.loadRepositories(account.id, forceRefresh: false))
        }
    }

    /// True once every account's listing finished (loaded or failed).
    public var repositoryListsSettled: Bool {
        state.accounts.allSatisfy { account in
            guard let list = state.repositoryLists[account.id] else { return false }
            return !list.isLoading
        }
    }

    /// Unmapped repositories to search checkouts for: those with open PRs/MRs first, then the others.
    public var checkoutScanCandidates: [RepoKey] {
        let mapped = Set(state.mappings.map(\.repo))
        var seen = Set<RepoKey>()
        let open = state.accounts.flatMap { openRepositories($0.id) }
        let listed = state.accounts.flatMap { state.repositoryLists[$0.id]?.repositories ?? [] }
        return (open + listed).map(\.key).filter { !mapped.contains($0) && seen.insert($0).inserted }
    }
}
