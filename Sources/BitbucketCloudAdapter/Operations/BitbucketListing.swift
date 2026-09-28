import Foundation
import MergeCueCore
import MergeCueNetworking

extension BitbucketCloudProvider {
    /// Lists open pull requests.
    ///
    /// - `.authored`: `GET /workspaces/{workspace}/pullrequests/{user uuid}?state=OPEN` for every workspace in
    ///   `query.namespaces` (empty = all of the user's workspaces).
    /// - `.reviewRequested`: per-repository BBQL `reviewers.uuid="{uuid}" AND state="OPEN"` over
    ///   `query.repositories`; when none are given, over the most recently updated member repositories of the
    ///   selected workspaces (bounded by `limits.maxReviewerRepositories`).
    ///
    /// `updatedSince` filters client-side on `updated_on`. The result is complete (never `notModified`).
    public func listChangeRequests(_ query: ChangeRequestQuery) async throws -> ChangeRequestPage {
        let user = try await me()
        let mapper = try await mapper()
        var summaries: [ChangeRequestSummary] = []
        var seen: Set<String> = []

        func add(_ prs: [BBPullRequest], repository: Repository?) throws {
            for pr in prs {
                recordRepositories(of: pr)
                var summary = try mapper.summary(pr, knownRepository: repository, currentUserUUID: user.remoteID)
                summary.involvement.insert(query.scope.involvement)
                if let since = query.updatedSince, summary.updatedAt < since { continue }
                guard seen.insert(summary.key.id).inserted else { continue }
                summaries.append(summary)
            }
        }

        switch query.scope {
        case .authored:
            let workspaces = try await selectedWorkspaces(query.namespaces)
            let userSegment = BitbucketIdentifiers.segment(user.remoteID)
            for workspace in workspaces {
                let prs: [BBPullRequest] = try await collect(
                    "/workspaces/\(BitbucketIdentifiers.segment(workspace))/pullrequests/\(userSegment)",
                    query: [URLQueryItem(name: "state", value: "OPEN"), URLQueryItem(name: "pagelen", value: "50")],
                    limit: limits.maxPullRequestsPerListing
                )
                try add(prs, repository: nil)
            }
        case .reviewRequested:
            let bbql = BitbucketIdentifiers.reviewerQuery(userUUID: user.remoteID)
            for repository in try await reviewerRepositories(query) {
                guard let path = BitbucketRepoPath(fullName: repository.fullPath) else { continue }
                directory.remember(repository)
                let prs: [BBPullRequest] = try await collect(
                    "\(path.apiPath)/pullrequests",
                    query: [URLQueryItem(name: "q", value: bbql), URLQueryItem(name: "pagelen", value: "50")],
                    limit: limits.maxPullRequestsPerListing
                )
                try add(prs, repository: repository)
            }
        }
        summaries.sort { ($0.updatedAt, $0.key.id) > ($1.updatedAt, $1.key.id) }
        return ChangeRequestPage(items: summaries)
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

    func reviewerRepositories(_ query: ChangeRequestQuery) async throws -> [Repository] {
        let explicit = query.repositories.filter { $0.key.kind == .bitbucketCloud }
        if !explicit.isEmpty { return explicit }
        var result: [Repository] = []
        for workspace in try await selectedWorkspaces(query.namespaces) {
            let remaining = limits.maxReviewerRepositories - result.count
            guard remaining > 0 else { break }
            result += try await repositories(inWorkspace: workspace, limit: remaining, recentFirst: true)
        }
        return Array(result.prefix(limits.maxReviewerRepositories))
    }
}
