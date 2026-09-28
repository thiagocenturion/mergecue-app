import Foundation
import MergeCueCore
import MergeCueNetworking
import Synchronization

/// `ReviewProvider` for GitLab REST v4 (GitLab.com or a self-managed instance).
///
/// Identity: the instance host is part of every key; `RepoKey.remoteRepoID` is the **target project id**,
/// `ChangeRequestKey.remoteID` the MR **global id** and `number` its **iid**. Every URL uses project id + iid.
/// Nothing is hard-coded to gitlab.com except the default `instance`.
public struct GitLabProvider: ReviewProvider {
    public static let protocolVersion = ReviewProviderContract.currentVersion

    /// What this adapter supports (GitLab REST v4).
    public static let capabilityManifest = CapabilityManifest(
        provider: .gitlab,
        manifestVersion: 1,
        entries: [
            .listAuthored: .supported,
            .listReviewRequested: .supported,
            .readThreads: .supported,
            .resolveThread: .supported,
            .readChecks: .partial(
                note: "Head pipeline and its jobs; downstream (child/multi-project) pipelines and external status checks are reflected only by the head pipeline status."
            ),
            .readFailureLog: .supported,
            .requestChanges: .partial(
                note: "Publishes a review summary with reviewer state “requested changes” (draft_notes/bulk_publish, recent GitLab versions). Only works when you are a reviewer and have no unpublished draft comments; otherwise request changes in GitLab."
            ),
            .createReply: .supported,
            .merge: .supported,
            .fetchHead: .supported,
            .deepLink: .supported,
        ]
    )

    public let instance: ProviderInstance
    public var capabilities: CapabilityManifest { Self.capabilityManifest }

    let api: GitLabAPI
    let session: GitLabSession
    let clock: any MCClock

    /// - Parameters:
    ///   - instance: GitLab.com by default; pass a self-managed instance (`apiURL` = `https://host/api/v4`).
    ///   - credential: Personal access token or OAuth token, sent as `Authorization: Bearer …`.
    public init(
        instance: ProviderInstance = .gitlabCom,
        credential: Credential,
        transport: any HTTPTransport = URLSessionTransport(),
        clock: any MCClock = SystemClock()
    ) {
        self.instance = instance
        self.api = GitLabAPI(client: APIClient(
            baseURL: instance.apiURL,
            credential: credential,
            transport: transport,
            rateLimitParser: GitLabRateLimitParser(),
            clock: clock
        ))
        self.session = GitLabSession()
        self.clock = clock
    }

    /// The underlying API client (rate-limit state for diagnostics).
    public var client: APIClient { api.client }

    // MARK: Account

    public func currentUser() async throws -> ProviderUser {
        let user = try await fetchUser()
        return GitLabMapping.providerUser(user, scopes: await tokenScopes())
    }

    /// Scopes of a personal access token (`/personal_access_tokens/self`). OAuth tokens and older instances do
    /// not support it: then scopes are unknown (empty), which is not an error.
    private func tokenScopes() async -> [String] {
        do {
            return try await api.get(GLTokenInfo.self, "/personal_access_tokens/self").scopes ?? []
        } catch {
            return []
        }
    }

    func fetchUser() async throws -> GLUser {
        let user = try await api.get(GLUser.self, "/user")
        session.setUser(user)
        return user
    }

    /// The authenticated user, fetched once per provider value.
    func cachedUser() async throws -> GLUser {
        if let user = session.user { return user }
        return try await fetchUser()
    }

    func accountKey() async throws -> AccountKey {
        AccountKey(instance: instance, remoteUserID: String(try await cachedUser().id))
    }

    public func listNamespaces() async throws -> [Namespace] {
        let user = try await cachedUser()
        let groups = try await api.getAll(
            GLGroup.self, "/groups",
            query: [URLQueryItem(name: "min_access_level", value: "10"), URLQueryItem(name: "all_available", value: "false")],
            maxPages: 10
        )
        return [GitLabMapping.userNamespace(user)] + groups.items.map(GitLabMapping.namespace)
    }

    public func listRepositories(namespace: Namespace?) async throws -> [Repository] {
        let account = try await accountKey()
        let path: String
        var query = [URLQueryItem(name: "simple", value: "true"), URLQueryItem(name: "archived", value: "false")]
        switch namespace?.kind {
        case nil:
            path = "/projects"
            query.append(URLQueryItem(name: "membership", value: "true"))
        case .user:
            let userID = namespace.flatMap { Self.numericSuffix(of: $0.id, prefix: "user:") } ?? namespace?.path ?? ""
            path = "/users/\(RequestURLBuilder.encodePathSegment(userID))/projects"
        case .group, .organization, .workspace:
            let groupID = namespace.flatMap { Self.numericSuffix(of: $0.id, prefix: "group:") } ?? namespace?.path ?? ""
            path = "/groups/\(RequestURLBuilder.encodePathSegment(groupID))/projects"
            query.append(URLQueryItem(name: "include_subgroups", value: "true"))
        }
        let projects = try await api.getAll(GLProject.self, path, query: query, maxPages: 20)
        return projects.items.map { GitLabMapping.repository($0, account: account) }
    }

    static func numericSuffix(of id: String, prefix: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        return !rest.isEmpty && rest.allSatisfy(\.isNumber) ? rest : nil
    }

    // MARK: Listing

    /// `GET /merge_requests?scope=created_by_me&state=opened` (authored) or
    /// `GET /merge_requests?scope=all&reviewer_id=<me>&state=opened` (review requested), all pages.
    public func listChangeRequests(_ query: ChangeRequestQuery) async throws -> ChangeRequestPage {
        let user = try await cachedUser()
        let userID = String(user.id)
        let account = AccountKey(instance: instance, remoteUserID: userID)
        var items: [URLQueryItem] = [URLQueryItem(name: "state", value: "opened")]
        switch query.scope {
        case .authored:
            items.append(URLQueryItem(name: "scope", value: "created_by_me"))
        case .reviewRequested:
            items.append(URLQueryItem(name: "scope", value: "all"))
            items.append(URLQueryItem(name: "reviewer_id", value: userID))
        }
        if let since = query.updatedSince {
            items.append(URLQueryItem(name: "updated_after", value: since.formatted(.iso8601)))
        }
        let paged = try await api.getAll(GLMergeRequest.self, "/merge_requests", query: items, maxPages: 10, useETag: true)
        if paged.allCacheHits, query.namespaces.isEmpty {
            return .unchanged
        }
        let prefixes = query.namespaces.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let summaries = paged.items.compactMap { mr -> ChangeRequestSummary? in
            let repository = GitLabMapping.repository(forListItem: mr, account: account, instance: instance)
            if !prefixes.isEmpty {
                let path = repository.fullPath.lowercased()
                guard prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return nil }
            }
            let summary = GitLabMapping.summary(
                mr, repository: repository, involvement: [query.scope.involvement], currentUserID: userID
            )
            GitLabLinkCache.remember(changeRequest: summary.key, webURL: summary.webURL, projectWebURL: repository.webURL)
            return summary
        }
        return ChangeRequestPage(items: summaries)
    }

    // MARK: Fresh state

    public func headInfo(for changeRequest: ChangeRequestKey) async throws -> HeadInfo {
        let mr = try await api.get(GLMergeRequest.self, GitLabAPI.mergeRequest(changeRequest))
        return HeadInfo(
            headSHA: GitLabMapping.headSHA(mr),
            state: GitLabMapping.state(mr.state),
            isDraft: GitLabMapping.isDraft(mr),
            updatedAt: ProviderDateParser.parse(mr.updatedAt) ?? mr.createdAt
        )
    }

    // MARK: Local checkout

    /// `refs/merge-requests/<iid>/head` on the **target** project: GitLab mirrors the source branch there, so it
    /// also works for merge requests from forks.
    public func fetchHeadSpec(for snapshot: ChangeRequestSnapshot) -> FetchHeadSpec? {
        let summary = snapshot.summary
        guard summary.key.kind == .gitlab else { return nil }
        var urls = summary.repository.cloneURLs
        if urls.isEmpty {
            urls = [summary.repository.webURL.absoluteString + ".git"]
        }
        return FetchHeadSpec(
            remoteURLs: urls,
            refspec: "refs/merge-requests/\(summary.key.number)/head",
            expectedSHA: summary.headSHA,
            isFork: snapshot.source?.isFork ?? false
        )
    }

    // MARK: Deep links

    public func deepLink(to target: DeepLinkTarget) -> URL? {
        let changeRequest = target.changeRequest
        guard changeRequest.kind == .gitlab else { return nil }
        let mrURL = mergeRequestWebURL(changeRequest)
        switch target {
        case .changeRequest:
            return mrURL
        case .thread(let key):
            guard let root = GitLabLinkCache.rootNoteID(key) else { return mrURL }
            return URL(string: mrURL.absoluteString + "#note_\(root)")
        case .comment(_, let commentID):
            return URL(string: mrURL.absoluteString + "#note_\(commentID)")
        case .check(let key):
            if let url = GitLabLinkCache.checkURL(key) { return url }
            if let project = GitLabLinkCache.projectURL(changeRequest.repo) {
                let kind = key.source == .gitlabPipeline ? "pipelines" : "jobs"
                return project.appending(path: "-/\(kind)/\(key.remoteID)")
            }
            return mrURL.appending(path: "pipelines")
        }
    }

    /// Exact MR URL when seen before; else `<project>/-/merge_requests/<iid>`; else the instance's
    /// `/projects/<id>` route (redirects to the project).
    func mergeRequestWebURL(_ key: ChangeRequestKey) -> URL {
        if let url = GitLabLinkCache.changeRequestURL(key) { return url }
        if let project = GitLabLinkCache.projectURL(key.repo) {
            return project.appending(path: "-/merge_requests/\(key.number)")
        }
        return instance.webURL.appending(path: "projects/\(key.repo.remoteRepoID)")
    }
}

/// Per-provider cache of the authenticated user (the reviewer id used by listings).
final class GitLabSession: Sendable {
    private let state = Mutex<GLUser?>(nil)

    var user: GLUser? { state.withLock { $0 } }

    func setUser(_ user: GLUser) {
        state.withLock { $0 = user }
    }
}

// MARK: - Link cache preloading

extension GitLabProvider {
    /// Seeds the process-wide link cache from a stored snapshot (e.g. at app launch, before the first sync
    /// hydrates anything) so `deepLink(to:)` returns exact merge request, note and job URLs right away.
    public static func rememberLinks(from snapshot: ChangeRequestSnapshot) {
        let summary = snapshot.summary
        guard summary.key.kind == .gitlab else { return }
        GitLabLinkCache.remember(changeRequest: summary.key, webURL: summary.webURL, projectWebURL: summary.repository.webURL)
        for thread in snapshot.threads {
            if let root = thread.rootComment { GitLabLinkCache.remember(thread: thread.key, rootNoteID: root.id) }
        }
        for check in snapshot.checks {
            if let url = check.detailsURL { GitLabLinkCache.remember(check: check.key, webURL: url) }
        }
    }
}
