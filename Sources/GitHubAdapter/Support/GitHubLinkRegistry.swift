import Foundation
import MergeCueCore
import Synchronization

/// Process-wide memory of GitHub paths the adapter has seen, keyed by immutable ids.
///
/// Core keys only carry immutable ids (repository id, PR id, thread node id), but REST paths and web deep links
/// need `owner/name` — and `deepLink(to:)` is synchronous. Listing and hydration register what they learn here;
/// async calls fall back to `GET /repositories/{id}` on a miss. Thread root comment ids and check detail URLs are
/// remembered for precise deep links. Bounded: the registry is cleared when it exceeds `maxEntries`.
public final class GitHubLinkRegistry: Sendable {
    /// Shared by every `GitHubProvider` in the process (providers are cheap values created per account/probe).
    public static let shared = GitHubLinkRegistry()

    public static let maxEntries = 20_000

    private struct State {
        var repoPaths: [String: String] = [:]
        var threadRoots: [String: String] = [:]
        var checkURLs: [String: URL] = [:]

        var count: Int { repoPaths.count + threadRoots.count + checkURLs.count }
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: Repositories

    public func registerRepository(host: String, remoteRepoID: String, fullPath: String) {
        guard !fullPath.isEmpty else { return }
        update { $0.repoPaths[Self.repoKey(host, remoteRepoID)] = fullPath }
    }

    public func repositoryPath(host: String, remoteRepoID: String) -> String? {
        state.withLock { $0.repoPaths[Self.repoKey(host, remoteRepoID)] }
    }

    // MARK: Threads and checks

    /// Remembers the root review comment id of a diff thread (`#discussion_r<id>` anchors).
    public func registerThreadRoot(_ thread: ThreadKey, commentID: String) {
        update { $0.threadRoots[thread.id] = commentID }
    }

    public func threadRoot(_ thread: ThreadKey) -> String? {
        state.withLock { $0.threadRoots[thread.id] }
    }

    public func registerCheckURL(_ check: CheckKey, url: URL) {
        update { $0.checkURLs[check.id] = url }
    }

    public func checkURL(_ check: CheckKey) -> URL? {
        state.withLock { $0.checkURLs[check.id] }
    }

    // MARK: Private

    private func update(_ body: (inout State) -> Void) {
        state.withLock { state in
            if state.count >= Self.maxEntries {
                state = State()
            }
            body(&state)
        }
    }

    private static func repoKey(_ host: String, _ id: String) -> String {
        host.lowercased() + "|" + id
    }
}

/// The authenticated user, learned from `currentUser()` or the `viewer` field of a search.
final class GitHubViewerCache: Sendable {
    struct Viewer: Sendable, Hashable {
        var remoteID: String
        var login: String
    }

    private let value = Mutex<Viewer?>(nil)

    func get() -> Viewer? { value.withLock { $0 } }
    func set(_ viewer: Viewer) { value.withLock { $0 = viewer } }
}
