import Foundation
import MergeCueCore
import Synchronization

/// Remembers which `workspace/repo_slug` a Bitbucket repository UUID belongs to.
///
/// Core keys identify a repository by its immutable UUID only, but every Bitbucket REST path needs the workspace
/// (and deep links need the full name). Listings and hydration record the mapping here so key-only calls
/// (`headInfo`, `thread`, writes, `deepLink`) can build paths without another round trip. On a miss the provider
/// resolves the UUID through the user's workspaces (`/repositories/{workspace}/{repo uuid}`).
///
/// `shared` is process-wide (keyed by instance host + UUID; repository UUIDs are globally unique and paths are not
/// secret), so a provider created just for a write still benefits from an earlier sync. Tests inject their own.
public final class BitbucketRepositoryDirectory: Sendable {
    public static let shared = BitbucketRepositoryDirectory()

    struct Entry: Sendable, Hashable {
        var path: BitbucketRepoPath
        var webURL: URL?
    }

    private struct State {
        var repositories: [String: Entry] = [:]
        var checkURLs: [String: URL] = [:]
    }

    /// Bound on remembered entries (oldest are not tracked; the map is simply cleared when full).
    static let maxEntries = 5_000
    private let state = Mutex(State())

    public init() {}

    private static func key(host: String, uuid: String) -> String {
        "\(host)|\(BitbucketIdentifiers.normalizedUUID(uuid) ?? uuid)"
    }

    func record(host: String, uuid: String?, fullName: String?, webURL: URL? = nil) {
        guard let uuid, let fullName, let path = BitbucketRepoPath(fullName: fullName) else { return }
        let key = Self.key(host: host, uuid: uuid)
        state.withLock { state in
            if state.repositories.count >= Self.maxEntries, state.repositories[key] == nil {
                state.repositories.removeAll()
            }
            let existingURL = state.repositories[key]?.webURL
            state.repositories[key] = Entry(path: path, webURL: webURL ?? existingURL)
        }
    }

    func entry(host: String, uuid: String) -> Entry? {
        state.withLock { $0.repositories[Self.key(host: host, uuid: uuid)] }
    }

    func recordCheckURL(_ url: URL?, for key: CheckKey) {
        guard let url else { return }
        state.withLock { state in
            if state.checkURLs.count >= Self.maxEntries { state.checkURLs.removeAll() }
            state.checkURLs[key.id] = url
        }
    }

    func checkURL(for key: CheckKey) -> URL? {
        state.withLock { $0.checkURLs[key.id] }
    }

    /// Records the repository a public `Repository` value describes (e.g. from the Store) so key-only calls can
    /// resolve its path. Safe to call repeatedly.
    public func remember(_ repository: Repository) {
        record(
            host: repository.key.account.host,
            uuid: repository.key.remoteRepoID,
            fullName: repository.fullPath,
            webURL: repository.webURL
        )
    }
}

/// Per-provider mutable caches: the current user (for the provider's lifetime, which is the account's credential
/// lifetime in Sync), the user's workspaces and the reviewer-listing fallback repositories (both bounded by
/// `ttl`). Sync keeps one provider per account, so a cycle does not ask for any of them again (DECISIONS D36).
final class BitbucketSessionState: Sendable {
    /// How long workspaces and fallback repositories are reused (6 h, like the engine's repository list).
    static let ttl: TimeInterval = 6 * 3_600

    private struct Cached<Value: Sendable>: Sendable {
        var value: Value
        var at: Date
    }

    private struct State: Sendable {
        var user: ProviderUser?
        var workspaces: Cached<[Namespace]>?
        var fallbackRepositories: [String: Cached<[Repository]>] = [:]
        /// Pull request objects of the latest listings, by change request id (stand in for detail requests).
        var listedPullRequests: [String: Cached<BBPullRequest>] = [:]
    }

    /// Bound on remembered listed pull requests (the map is cleared when full).
    static let maxListedPullRequests = 1_000

    private let state = Mutex(State())

    func cachedUser() -> ProviderUser? { state.withLock { $0.user } }
    func store(_ value: ProviderUser) { state.withLock { $0.user = value } }

    func cachedWorkspaces(now: Date) -> [Namespace]? {
        state.withLock { state in
            guard let cached = state.workspaces, now.timeIntervalSince(cached.at) < Self.ttl, cached.at <= now else { return nil }
            return cached.value
        }
    }

    func storeWorkspaces(_ value: [Namespace], at now: Date) {
        state.withLock { $0.workspaces = Cached(value: value, at: now) }
    }

    func cachedFallbackRepositories(_ key: String, now: Date) -> [Repository]? {
        state.withLock { state in
            guard let cached = state.fallbackRepositories[key], now.timeIntervalSince(cached.at) < Self.ttl, cached.at <= now else {
                return nil
            }
            return cached.value
        }
    }

    func storeListedPullRequest(_ pr: BBPullRequest, id: String, at now: Date) {
        state.withLock { state in
            if state.listedPullRequests.count >= Self.maxListedPullRequests, state.listedPullRequests[id] == nil {
                state.listedPullRequests.removeAll()
            }
            state.listedPullRequests[id] = Cached(value: pr, at: now)
        }
    }

    /// The pull request object listed for `id` at most `maxAge` before `now`.
    func listedPullRequest(_ id: String, now: Date, maxAge: TimeInterval) -> BBPullRequest? {
        state.withLock { state in
            guard let cached = state.listedPullRequests[id], cached.at <= now, now.timeIntervalSince(cached.at) <= maxAge else {
                return nil
            }
            return cached.value
        }
    }

    func storeFallbackRepositories(_ value: [Repository], key: String, at now: Date) {
        state.withLock { $0.fallbackRepositories[key] = Cached(value: value, at: now) }
    }
}

extension BitbucketRepositoryDirectory {
    /// Records the repositories and check links of a stored snapshot (e.g. at app launch, before the first sync)
    /// so key-only calls and `deepLink(to:)` work right away. Safe to call repeatedly.
    public func remember(_ snapshot: ChangeRequestSnapshot) {
        guard snapshot.key.kind == .bitbucketCloud else { return }
        remember(snapshot.summary.repository)
        for check in snapshot.checks {
            recordCheckURL(check.detailsURL, for: check.key)
        }
    }
}
