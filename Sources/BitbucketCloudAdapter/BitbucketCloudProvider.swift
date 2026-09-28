import Foundation
import MergeCueCore
import MergeCueNetworking

/// `ReviewProvider` for Bitbucket Cloud (REST 2.0, `https://api.bitbucket.org/2.0`).
///
/// Authentication: an Atlassian API token with the account email (`Credential.basic(username: email, password:
/// token)`) or a workspace/repository/project access token (`Credential.bearer`). App passwords are deprecated by
/// Atlassian and not offered.
///
/// Endpoints (all relative to the API base):
/// - `GET /user`, `GET /user/workspaces`, `GET /repositories/{workspace}?role=member`
/// - authored: `GET /workspaces/{workspace}/pullrequests/{user uuid}?state=OPEN`
/// - review requested: `GET /repositories/{workspace}/{repo}/pullrequests?q=reviewers.uuid="{uuid}" AND state="OPEN"`
/// - hydrate: `…/pullrequests/{id}`, `/comments`, `/tasks`, `/statuses`, `/commits`, `/diffstat`,
///   `GET /repositories/{workspace}/{repo}/pipelines?target.commit.hash=…` + `/pipelines/{uuid}/steps`
/// - logs: `…/pipelines/{uuid}/steps/{step uuid}/log`; diff: `…/pullrequests/{id}/diff`
/// - writes: `POST …/comments` (reply), `POST|DELETE …/comments/{id}/resolve`, `POST …/request-changes`,
///   `POST …/merge`
///
/// Every list endpoint is followed through its `next` links (bounded). Bitbucket UUIDs keep their braces as
/// identifiers and are percent-encoded in paths and queries.
public struct BitbucketCloudProvider: ReviewProvider {
    public static let protocolVersion = ReviewProviderContract.currentVersion

    public let instance: ProviderInstance
    public var capabilities: CapabilityManifest { Self.capabilityManifest }

    let client: APIClient
    let clock: any MCClock
    let directory: BitbucketRepositoryDirectory
    let session = BitbucketSessionState()
    let limits: BitbucketLimits

    public init(
        instance: ProviderInstance = .bitbucketCloud,
        credential: Credential,
        transport: any HTTPTransport = URLSessionTransport(),
        clock: any MCClock = SystemClock()
    ) {
        self.init(instance: instance, credential: credential, transport: transport, clock: clock, directory: .shared)
    }

    /// Full initializer (tests inject a private repository directory and tighter limits).
    public init(
        instance: ProviderInstance,
        credential: Credential,
        transport: any HTTPTransport,
        clock: any MCClock,
        directory: BitbucketRepositoryDirectory,
        limits: BitbucketLimits = .default
    ) {
        self.instance = instance
        self.clock = clock
        self.directory = directory
        self.limits = limits
        self.client = APIClient(
            baseURL: instance.apiURL,
            credential: credential,
            transport: transport,
            rateLimitParser: GenericRateLimitParser(),
            etagCache: nil,
            clock: clock
        )
    }

    // MARK: Identity

    public func currentUser() async throws -> ProviderUser {
        let response = try await client.get("/user")
        let account = try APIClient.decode(BBAccount.self, from: response)
        guard let uuid = BitbucketIdentifiers.normalizedUUID(account.uuid) else {
            throw ProviderError.decoding("Bitbucket /user returned no uuid.")
        }
        let scopes = (response.header("x-oauth-scopes") ?? response.header("x-accepted-oauth-scopes") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let user = ProviderUser(
            remoteID: uuid,
            username: account.nickname ?? account.username ?? account.accountID ?? uuid,
            displayName: account.displayName,
            avatarURL: account.links?.avatar?.href.flatMap(URL.init(string:)),
            grantedScopes: scopes,
            email: nil
        )
        session.store(user)
        return user
    }

    /// The current user (cached per provider value after the first `/user` call).
    func me() async throws -> ProviderUser {
        if let cached = session.cachedUser() { return cached }
        return try await currentUser()
    }

    func mapper() async throws -> BitbucketMapper {
        let user = try await me()
        return BitbucketMapper(instance: instance, account: AccountKey(instance: instance, remoteUserID: user.remoteID))
    }

    /// Workspaces of the current user (`GET /user/workspaces`; the older `/workspaces` and
    /// `/user/permissions/workspaces` listings are deprecated).
    public func listNamespaces() async throws -> [Namespace] {
        let access: [BBWorkspaceAccess] = try await collect(
            "/user/workspaces", query: [URLQueryItem(name: "pagelen", value: "100")], limit: limits.maxWorkspaces
        )
        return access.map { entry in
            Namespace(
                id: BitbucketIdentifiers.normalizedUUID(entry.workspace.uuid) ?? entry.workspace.slug,
                path: entry.workspace.slug,
                displayName: entry.workspace.name ?? entry.workspace.slug,
                kind: .workspace
            )
        }
    }

    /// Repositories the user is a member of, in one workspace or (nil) across all of the user's workspaces.
    public func listRepositories(namespace: Namespace?) async throws -> [Repository] {
        let workspaces = if let namespace { [namespace.path] } else { try await listNamespaces().map(\.path) }
        var result: [Repository] = []
        for workspace in workspaces {
            result += try await repositories(inWorkspace: workspace, limit: limits.maxRepositoriesPerWorkspace)
        }
        return result
    }

    func repositories(inWorkspace workspace: String, limit: Int, recentFirst: Bool = false) async throws -> [Repository] {
        let mapper = try await mapper()
        var query = [URLQueryItem(name: "role", value: "member"), URLQueryItem(name: "pagelen", value: "100")]
        if recentFirst { query.append(URLQueryItem(name: "sort", value: "-updated_on")) }
        let repos: [BBRepository] = try await collect(
            "/repositories/\(BitbucketIdentifiers.segment(workspace))", query: query, limit: limit
        )
        return repos.compactMap { repo in
            guard let repository = mapper.repository(repo) else { return nil }
            directory.remember(repository)
            return repository
        }
    }

    // MARK: Pagination

    /// Follows Bitbucket `next` links until `limit` values are collected (or the collection ends).
    func collect<Value: Decodable>(_ path: String, query: [URLQueryItem] = [], limit: Int) async throws -> [Value] {
        var values: [Value] = []
        var page: BBPage<Value> = try await client.getJSON(BBPage<Value>.self, path, query: query)
        var seen: Set<String> = []
        var pages = 1
        while true {
            values += page.values
            guard values.count < limit, pages < limits.maxPages, let next = page.next, !seen.contains(next),
                  let url = URL(string: next)
            else { break }
            seen.insert(next)
            pages += 1
            let response = try await client.getAbsolute(url)
            page = try APIClient.decode(BBPage<Value>.self, from: response)
        }
        return Array(values.prefix(limit))
    }

    // MARK: Repository resolution

    /// `workspace/repo` for a repository UUID: the directory first, then a lookup through the user's workspaces.
    func repoPath(for repo: RepoKey) async throws -> BitbucketRepoPath {
        if let entry = directory.entry(host: instance.host, uuid: repo.remoteRepoID) { return entry.path }
        let uuidSegment = BitbucketIdentifiers.segment(BitbucketIdentifiers.normalizedUUID(repo.remoteRepoID) ?? repo.remoteRepoID)
        for namespace in try await listNamespaces() {
            do {
                let found = try await client.getJSON(
                    BBRepository.self, "/repositories/\(BitbucketIdentifiers.segment(namespace.path))/\(uuidSegment)"
                )
                if let fullName = found.fullName, let path = BitbucketRepoPath(fullName: fullName) {
                    directory.record(
                        host: instance.host, uuid: repo.remoteRepoID, fullName: fullName,
                        webURL: found.links?.html?.href.flatMap(URL.init(string:))
                    )
                    return path
                }
            } catch let error as ProviderError {
                if case .notFound = error { continue }
                if case .forbidden = error { continue }
                throw error
            }
        }
        throw ProviderError.notFound("Bitbucket repository \(repo.remoteRepoID) is not accessible to this account.")
    }

    func pullRequestID(_ key: ChangeRequestKey) throws -> Int {
        guard let id = Int(key.remoteID) ?? (key.number > 0 ? key.number : nil) else {
            throw ProviderError.invalidRequest("Invalid Bitbucket pull request id \(key.remoteID).")
        }
        return id
    }

    func fetchPullRequest(_ key: ChangeRequestKey) async throws -> (BitbucketRepoPath, BBPullRequest) {
        let path = try await repoPath(for: key.repo)
        let pr = try await client.getJSON(BBPullRequest.self, path.pullRequestPath(try pullRequestID(key)))
        recordRepositories(of: pr)
        return (path, pr)
    }

    func recordRepositories(of pr: BBPullRequest) {
        for endpoint in [pr.destination, pr.source] {
            guard let repo = endpoint?.repository else { continue }
            directory.record(
                host: instance.host, uuid: repo.uuid, fullName: repo.fullName,
                webURL: repo.links?.html?.href.flatMap(URL.init(string:))
            )
        }
    }

    // MARK: Head state

    public func headInfo(for changeRequest: ChangeRequestKey) async throws -> HeadInfo {
        let (_, pr) = try await fetchPullRequest(changeRequest)
        return try await mapper().headInfo(pr)
    }

    // MARK: Fetch head / deep links

    /// Source repository clone URLs + `refs/heads/<source branch>` (the fork's URLs for fork pull requests).
    public func fetchHeadSpec(for snapshot: ChangeRequestSnapshot) -> FetchHeadSpec? {
        let branch = snapshot.summary.sourceBranch
        guard !branch.isEmpty else { return nil }
        let source = snapshot.source
        let urls = source.map(\.cloneURLs).flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.summary.repository.cloneURLs
        guard !urls.isEmpty else { return nil }
        return FetchHeadSpec(
            remoteURLs: urls,
            refspec: "refs/heads/\(branch)",
            expectedSHA: snapshot.summary.headSHA,
            isFork: source?.isFork ?? false
        )
    }

    public func deepLink(to target: DeepLinkTarget) -> URL? {
        switch target {
        case .changeRequest(let key):
            return pullRequestWebURL(key)
        case .thread(let thread):
            return pullRequestWebURL(thread.changeRequest)?.withFragment("comment-\(thread.remoteID)")
        case .comment(let thread, let commentID):
            return pullRequestWebURL(thread.changeRequest)?.withFragment("comment-\(commentID)")
        case .check(let check):
            if let cached = directory.checkURL(for: check) { return cached }
            guard check.source == .bitbucketPipelineStep,
                  let entry = directory.entry(host: instance.host, uuid: check.changeRequest.repo.remoteRepoID)
            else { return nil }
            let parts = check.remoteID.split(separator: "/", maxSplits: 1).map(String.init)
            guard let run = parts.first else { return nil }
            var url = instance.webURL.appending(path: entry.path.fullName).appending(path: "pipelines/results").appending(path: run)
            if parts.count == 2 { url = url.appending(path: "steps").appending(path: parts[1]) }
            return url
        }
    }

    func pullRequestWebURL(_ key: ChangeRequestKey) -> URL? {
        guard let entry = directory.entry(host: instance.host, uuid: key.repo.remoteRepoID) else { return nil }
        let repoURL = entry.webURL ?? instance.webURL.appending(path: entry.path.fullName)
        return repoURL.appending(path: "pull-requests").appending(path: String((try? pullRequestID(key)) ?? key.number))
    }
}

/// Bounds on Bitbucket requests (pagination, fan-out).
public struct BitbucketLimits: Sendable, Hashable {
    /// Pages followed per collection.
    public var maxPages: Int
    public var maxWorkspaces: Int
    public var maxRepositoriesPerWorkspace: Int
    /// Repositories queried for review requests when the query names none (most recently updated first).
    public var maxReviewerRepositories: Int
    public var maxPullRequestsPerListing: Int
    public var maxComments: Int
    public var maxCommits: Int
    public var maxFiles: Int
    /// Bytes requested from the end of a step log (`Range: bytes=-N`).
    public var maxLogFetchBytes: Int

    public init(
        maxPages: Int = 20, maxWorkspaces: Int = 50, maxRepositoriesPerWorkspace: Int = 500,
        maxReviewerRepositories: Int = 30, maxPullRequestsPerListing: Int = 500, maxComments: Int = 1_000,
        maxCommits: Int = 250, maxFiles: Int = 1_000, maxLogFetchBytes: Int = 2 * 1_024 * 1_024
    ) {
        self.maxPages = maxPages
        self.maxWorkspaces = maxWorkspaces
        self.maxRepositoriesPerWorkspace = maxRepositoriesPerWorkspace
        self.maxReviewerRepositories = maxReviewerRepositories
        self.maxPullRequestsPerListing = maxPullRequestsPerListing
        self.maxComments = maxComments
        self.maxCommits = maxCommits
        self.maxFiles = maxFiles
        self.maxLogFetchBytes = maxLogFetchBytes
    }

    public static let `default` = BitbucketLimits()
}
