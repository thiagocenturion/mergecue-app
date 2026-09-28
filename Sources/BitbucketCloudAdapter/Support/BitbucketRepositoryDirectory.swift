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

/// Per-provider mutable caches (current user).
final class BitbucketSessionState: Sendable {
    private let user = Mutex<ProviderUser?>(nil)

    func cachedUser() -> ProviderUser? { user.withLock { $0 } }
    func store(_ value: ProviderUser) { user.withLock { $0 = value } }
}
