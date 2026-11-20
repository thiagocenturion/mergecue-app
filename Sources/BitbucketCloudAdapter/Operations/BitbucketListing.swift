import Foundation
import MergeCueCore
import MergeCueNetworking

extension BitbucketCloudProvider {
    /// Lists open pull requests.
    ///
    /// - `.authored`: `GET /workspaces/{workspace}/pullrequests/{user uuid}?state=OPEN` for every workspace in
    ///   `query.namespaces` (empty = all of the user's workspaces); with `restrictToRepositories` (watched
    ///   repositories) the same listing for the workspaces of the watched repositories, filtered client-side (a
    ///   per-repository BBQL `author.uuid` query when the token cannot read the workspace listing).
    /// - `.reviewRequested`: per-repository BBQL `reviewers.uuid="{uuid}" AND state="OPEN"` over
    ///   `query.repositories`; when none are given, over the most recently updated member repositories of the
    ///   selected workspaces (bounded by `limits.maxReviewerRepositories`).
    ///
    /// - `.involved`: the same per-repository iteration (same bound) with BBQL
    ///   `state="OPEN"` + `fields=+values.participants`, filtered client-side to PRs of others where the user is a
    ///   participant (BBQL rejects filtering on `participants`) — pull requests of others the user reviewed, approved
    ///   or commented on; the user's own pull requests are left to the authored listing.
    ///
    /// `updatedSince` filters client-side on `updated_on`. The result is complete (never `notModified`).
    public func listChangeRequests(_ query: ChangeRequestQuery) async throws -> ChangeRequestPage {
        let user = try await me()
        let mapper = try await mapper()
        var summaries: [ChangeRequestSummary] = []
        var seen: Set<String> = []

        let listedAt = clock.now
        func add(_ prs: [BBPullRequest], repository: Repository?) throws {
            for pr in prs {
                recordRepositories(of: pr)
                var summary = try mapper.summary(pr, knownRepository: repository, currentUserUUID: user.remoteID)
                guard query.includes(summary.key.repo) else { continue }
                session.storeListedPullRequest(pr, id: summary.key.id, at: listedAt)
                summary.involvement.insert(query.scope.involvement)
                if let since = query.updatedSince, summary.updatedAt < since { continue }
                guard seen.insert(summary.key.id).inserted else { continue }
                summaries.append(summary)
            }
        }

        switch query.scope {
        case .authored where query.restrictToRepositories:
            // Watched repositories: one workspace listing per workspace they live in, filtered client-side (one
            // request covers every watched repository of the workspace). A token that cannot read the workspace
            // listing (repository access token) falls back to one BBQL query per repository.
            var workspaces: [String] = []
            for repository in query.repositories {
                if let path = BitbucketRepoPath(fullName: repository.fullPath), !workspaces.contains(path.workspace) {
                    workspaces.append(path.workspace)
                }
            }
            for workspace in workspaces {
                let inWorkspace = query.repositories.filter { BitbucketRepoPath(fullName: $0.fullPath)?.workspace == workspace }
                inWorkspace.forEach(directory.remember)
                do {
                    let prs = try await workspacePullRequests(workspace, user: user)
                    try add(prs, repository: nil)
                } catch ProviderError.forbidden {
                    for repository in inWorkspace {
                        guard let path = BitbucketRepoPath(fullName: repository.fullPath) else { continue }
                        let prs: [BBPullRequest] = try await collect(
                            "\(path.apiPath)/pullrequests",
                            query: [
                                URLQueryItem(name: "q", value: BitbucketIdentifiers.authorQuery(userUUID: user.remoteID)),
                                URLQueryItem(name: "fields", value: Self.listingFields),
                                URLQueryItem(name: "pagelen", value: "50"),
                            ],
                            limit: limits.maxPullRequestsPerListing
                        )
                        try add(prs, repository: repository)
                    }
                }
            }
        case .authored:
            let workspaces = try await selectedWorkspaces(query.namespaces)
            for workspace in workspaces {
                try add(try await workspacePullRequests(workspace, user: user), repository: nil)
            }
        case .reviewRequested, .involved:
            let involved = query.scope == .involved
            let bbql = involved
                ? BitbucketIdentifiers.participantQuery(userUUID: user.remoteID, updatedSince: query.updatedSince)
                : BitbucketIdentifiers.reviewerQuery(userUUID: user.remoteID)
            for repository in try await reviewerRepositories(query) {
                guard let path = BitbucketRepoPath(fullName: repository.fullPath) else { continue }
                directory.remember(repository)
                // BBQL can't filter on `participants` ("does not support filtering"), so the involved scope lists
                // open PRs with their participants and filters client-side.
                let items = [
                    URLQueryItem(name: "q", value: bbql), URLQueryItem(name: "fields", value: Self.listingFields),
                    URLQueryItem(name: "pagelen", value: "50"),
                ]
                let prs: [BBPullRequest] = try await collect(
                    "\(path.apiPath)/pullrequests",
                    query: items,
                    limit: limits.maxPullRequestsPerListing
                )
                try add(involved ? prs.filter { pr in
                    !BitbucketIdentifiers.sameUUID(pr.author?.uuid, user.remoteID)
                        && (pr.participants ?? []).contains { BitbucketIdentifiers.sameUUID($0.user?.uuid, user.remoteID) }
                } : prs, repository: repository)
            }
        }
        summaries.sort { ($0.updatedAt, $0.key.id) > ($1.updatedAt, $1.key.id) }
        return ChangeRequestPage(items: summaries)
    }

    /// Extra fields every pull request listing asks for, so a listed object can replace the detail request during
    /// hydration (reviewers, participants with approval state, description). Bitbucket documents `fields` for every
    /// endpoint; that the workspace listing honours `+values.participants` is inferred and needs one live check
    /// (when a listing comes back without participants, hydration reads the detail as before).
    static let listingFields = "+values.participants,+values.reviewers,+values.summary"

    /// `GET /workspaces/{workspace}/pullrequests/{user}?state=OPEN` (every repository of the workspace).
    func workspacePullRequests(_ workspace: String, user: ProviderUser) async throws -> [BBPullRequest] {
        try await collect(
            "/workspaces/\(BitbucketIdentifiers.segment(workspace))/pullrequests/\(BitbucketIdentifiers.segment(user.remoteID))",
            query: [
                URLQueryItem(name: "state", value: "OPEN"), URLQueryItem(name: "fields", value: Self.listingFields),
                URLQueryItem(name: "pagelen", value: "50"),
            ],
            limit: limits.maxPullRequestsPerListing
        )
    }

    /// Workspace slugs to query: the selection, or every workspace of the user.
    func selectedWorkspaces(_ namespaces: [String]) async throws -> [String] {
        let selected = namespaces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !selected.isEmpty {
            var unique: [String] = []
            for slug in selected where !unique.contains(slug) { unique.append(slug) }
            return unique
        }
        return try await listNamespaces().map(\.path)
    }

    /// Repositories the reviewer/involved listings query one by one: the watched repositories (all of them), else
    /// the given ones (bounded by `limits.maxReviewerRepositories`), else the most recently updated member
    /// repositories of the selected workspaces (bounded, cached per provider for `BitbucketSessionState.ttl`, so a
    /// sync cycle does not list repositories again).
    func reviewerRepositories(_ query: ChangeRequestQuery) async throws -> [Repository] {
        let explicit = query.repositories.filter { $0.key.kind == .bitbucketCloud }
        if query.restrictToRepositories { return explicit }
        if !explicit.isEmpty { return Array(explicit.prefix(limits.maxReviewerRepositories)) }
        let cacheKey = query.namespaces.sorted().joined(separator: ",")
        if let cached = session.cachedFallbackRepositories(cacheKey, now: clock.now) { return cached }
        var result: [Repository] = []
        for workspace in try await selectedWorkspaces(query.namespaces) {
            let remaining = limits.maxReviewerRepositories - result.count
            guard remaining > 0 else { break }
            result += try await repositories(inWorkspace: workspace, limit: remaining, recentFirst: true)
        }
        let bounded = Array(result.prefix(limits.maxReviewerRepositories))
        session.storeFallbackRepositories(bounded, key: cacheKey, at: clock.now)
        return bounded
    }
}
