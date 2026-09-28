import Foundation
import MergeCueCore
import MergeCueNetworking

/// `ReviewProvider` for GitHub.com (and GitHub Enterprise Server instances configured with an `/api/v3` root).
///
/// Reads prefer GraphQL (one search per listing scope, one query per hydration plus cursor pages); REST is used for
/// the user/org/repo directory, diffs, Actions logs and writes. All HTTP goes through one `APIClient` per value
/// (auth, retries, rate limits, error mapping, credential scrubbing).
public struct GitHubProvider: ReviewProvider {
    public static let protocolVersion = ReviewProviderContract.currentVersion

    /// Classic OAuth/PAT scope needed by every write (fine-grained tokens: "Pull requests: write", plus
    /// "Contents: write" to merge).
    public static let writeScope = "repo"

    /// Static manifest (scopes unknown): reads supported, writes need `repo`.
    public static let capabilityManifest = CapabilityManifest(
        provider: .github,
        manifestVersion: 1,
        entries: [
            .listAuthored: .supported,
            .listReviewRequested: .supported,
            .readThreads: .supported,
            .readChecks: .supported,
            .readFailureLog: .partial(
                note: "Full logs for GitHub Actions jobs; other check runs return their output text; commit statuses only link to the external details page"
            ),
            .fetchHead: .supported,
            .deepLink: .supported,
            .createReply: .requiresWriteAccess(scope: writeScope),
            .resolveThread: .requiresWriteAccess(scope: writeScope),
            .requestChanges: .requiresWriteAccess(scope: writeScope),
            .merge: .requiresWriteAccess(scope: writeScope),
        ]
    )

    /// Manifest for a token whose classic scopes are known (`ProviderUser.grantedScopes`): `repo` unlocks writes;
    /// `public_repo` unlocks them for public repositories only; no scopes at all means a fine-grained/app token whose
    /// permissions GitHub does not report, so writes are marked partial.
    public static func capabilities(grantedScopes: [String]) -> CapabilityManifest {
        var manifest = capabilityManifest
        let scopes = Set(grantedScopes.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let writeSupport: CapabilitySupport?
        if scopes.contains("repo") {
            writeSupport = .supported
        } else if scopes.contains("public_repo") {
            writeSupport = .partial(note: "Token has public_repo: writes work on public repositories only")
        } else if scopes.isEmpty {
            writeSupport = .partial(note: "Fine-grained token: writes need the Pull requests (and Contents, to merge) write permission")
        } else {
            writeSupport = nil
        }
        if let writeSupport {
            for capability in Capability.allCases where capability.isWrite {
                manifest.entries[capability] = writeSupport
            }
        }
        return manifest
    }

    public let instance: ProviderInstance
    public let capabilities: CapabilityManifest

    let client: APIClient
    let graphQL: GitHubGraphQLClient
    let clock: any MCClock
    let links: GitHubLinkRegistry
    let viewer = GitHubViewerCache()

    /// Maximum pages followed for any one connection/listing (a runaway cursor must not loop forever).
    static let maxPages = 20

    /// - Parameters:
    ///   - grantedScopes: The account's known classic scopes; when given, `capabilities` reflects them
    ///     (`capabilities(grantedScopes:)`), otherwise the static manifest is used.
    ///   - linkRegistry: Where repository paths / thread roots are remembered (shared by default).
    public init(
        instance: ProviderInstance = .githubCom,
        credential: Credential,
        transport: any HTTPTransport = URLSessionTransport(),
        clock: any MCClock = SystemClock(),
        grantedScopes: [String]? = nil,
        linkRegistry: GitHubLinkRegistry = .shared
    ) {
        self.instance = instance
        self.clock = clock
        self.links = linkRegistry
        self.capabilities = grantedScopes.map(Self.capabilities(grantedScopes:)) ?? Self.capabilityManifest
        let client = APIClient(
            baseURL: instance.apiURL,
            credential: credential,
            transport: transport,
            rateLimitParser: GitHubRateLimitParser(),
            clock: clock,
            extraHeaders: [
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            ]
        )
        self.client = client
        self.graphQL = GitHubGraphQLClient(client: client, endpoint: GitHubGraphQLClient.endpoint(forAPIURL: instance.apiURL))
    }

    /// Rate-limit state of the most recent response.
    public func lastRateLimit() async -> RateLimitInfo? {
        await client.lastRateLimit
    }

    // MARK: Account key

    /// The account key for the authenticated user (from cache, else `currentUser()`).
    func accountKey() async throws -> AccountKey {
        if let cached = viewer.get() {
            return AccountKey(instance: instance, remoteUserID: cached.remoteID)
        }
        let user = try await currentUser()
        return AccountKey(instance: instance, remoteUserID: user.remoteID)
    }

    // MARK: Paths

    /// `owner/name` of a repository: registry first, else `GET /repositories/{id}`.
    func repositoryPath(_ repo: RepoKey) async throws -> String {
        if let known = links.repositoryPath(host: instance.host, remoteRepoID: repo.remoteRepoID) {
            return known
        }
        let fetched = try await client.getJSON(RESTRepository.self, "/repositories/\(Self.segment(repo.remoteRepoID))")
        links.registerRepository(host: instance.host, remoteRepoID: fetched.id.value, fullPath: fetched.fullName)
        return fetched.fullName
    }

    /// `/repos/{owner}/{name}` with encoded segments.
    static func repoAPIPath(_ fullPath: String) throws -> String {
        let parts = GitHubMapping.splitFullPath(fullPath)
        guard !parts.owner.isEmpty, !parts.name.isEmpty, parts.owner != fullPath else {
            throw ProviderError.invalidRequest("Invalid GitHub repository path.")
        }
        return "/repos/\(segment(parts.owner))/\(segment(parts.name))"
    }

    static func segment(_ value: String) -> String {
        RequestURLBuilder.encodePathSegment(value)
    }

    func register(_ repository: Repository) {
        links.registerRepository(host: instance.host, remoteRepoID: repository.key.remoteRepoID, fullPath: repository.fullPath)
    }
}
