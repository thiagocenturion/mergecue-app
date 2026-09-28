import Foundation
import MergeCueCore
import MergeCueNetworking

extension GitHubProvider {
    /// One `MergeCuePullRequest` query, then cursor pages for review threads, long threads' comments, issue
    /// comments, reviews and check contexts when a first page is full.
    public func hydrate(_ summary: ChangeRequestSummary) async throws -> ChangeRequestSnapshot {
        let fullPath = summary.repository.fullPath
        let parts = GitHubMapping.splitFullPath(fullPath)
        let base: [String: JSONValue] = [
            "owner": .string(parts.owner),
            "name": .string(parts.name),
            "number": .number(Double(summary.key.number)),
        ]
        let data = try await graphQL.execute(.pullRequest, variables: base, as: GQLPullRequestData.self)
        guard let pr = data.repository?.pullRequest else {
            throw ProviderError.notFound("Pull request \(fullPath)#\(summary.key.number) was not found.")
        }

        // Complete every paginated connection.
        var rawThreads = pr.reviewThreads?.items ?? []
        var cursor = pr.reviewThreads?.nextCursor
        var pages = 0
        while let after = cursor, pages < Self.maxPages {
            let page = try await pullRequestPage(.reviewThreadsPage, base: base, after: after)
            rawThreads += page?.reviewThreads?.items ?? []
            cursor = page?.reviewThreads?.nextCursor
            pages += 1
        }
        var issueComments = pr.comments?.items ?? []
        cursor = pr.comments?.nextCursor
        pages = 0
        while let after = cursor, pages < Self.maxPages {
            let page = try await pullRequestPage(.issueCommentsPage, base: base, after: after)
            issueComments += page?.comments?.items ?? []
            cursor = page?.comments?.nextCursor
            pages += 1
        }
        var reviews = pr.reviews?.items ?? []
        cursor = pr.reviews?.nextCursor
        pages = 0
        while let after = cursor, pages < Self.maxPages {
            let page = try await pullRequestPage(.reviewsPage, base: base, after: after)
            reviews += page?.reviews?.items ?? []
            cursor = page?.reviews?.nextCursor
            pages += 1
        }
        let headCommit = pr.headCommitNode
        var contexts = headCommit?.statusCheckRollup?.contexts?.items ?? []
        cursor = headCommit?.statusCheckRollup?.contexts?.nextCursor
        pages = 0
        while let after = cursor, pages < Self.maxPages {
            let page = try await pullRequestPage(.checkContextsPage, base: base, after: after)
            let rollup = page?.headCommit?.items.last?.commit.statusCheckRollup
            contexts += rollup?.contexts?.items ?? []
            cursor = rollup?.contexts?.nextCursor
            pages += 1
        }

        // Summary (fresh values, caller's involvement).
        var fresh = try GitHubMapping.summary(pr, account: summary.key.account, instance: instance, involvement: summary.involvement)
        if fresh.involvement.isEmpty { fresh.involvement = summary.involvement }
        register(fresh.repository)
        let key = fresh.key

        // Threads: diff threads, then issue comments, then review bodies.
        var threads: [ReviewThread] = []
        for raw in rawThreads {
            let comments = try await allComments(of: raw)
            let thread = GitHubMapping.diffThread(raw, comments: comments, changeRequest: key)
            if let root = thread.rootComment { links.registerThreadRoot(thread.key, commentID: root.id) }
            threads.append(thread)
        }
        threads += issueComments.compactMap { GitHubMapping.issueCommentThread($0, changeRequest: key) }
            .sorted { $0.lastActivityAt < $1.lastActivityAt }
        threads += reviews.compactMap { GitHubMapping.reviewSummaryThread($0, changeRequest: key) }
            .sorted { $0.lastActivityAt < $1.lastActivityAt }

        let checks = GitHubChecks.checks(contexts, changeRequest: key, headSHA: headCommit?.oid ?? pr.headRefOid, repoFullPath: fresh.repository.fullPath)
        for check in checks {
            if let url = check.detailsURL { links.registerCheckURL(check.key, url: url) }
        }
        let aggregate = AggregateCheckState.aggregate(checks)
        let latest = pr.latestReviews?.items ?? []
        let unresolved = threads.filter(\.isUnresolved).count
        let readiness = GitHubReadiness.evaluate(
            state: fresh.state,
            isDraft: fresh.isDraft,
            mergeStateStatus: pr.mergeStateStatus,
            mergeable: pr.mergeable,
            reviewDecision: pr.reviewDecision,
            unresolvedThreads: unresolved,
            checks: aggregate
        )

        let source: SourceRepositoryInfo? = pr.headRepository.map { head in
            let web = head.url ?? GitHubMapping.webURL(instance: instance, path: head.nameWithOwner)
            return SourceRepositoryInfo(
                fullPath: head.nameWithOwner,
                cloneURLs: GitHubMapping.cloneURLs(web: web, ssh: head.sshUrl),
                remoteID: head.databaseId?.value,
                isFork: pr.isCrossRepository ?? (head.databaseId?.value != fresh.key.repo.remoteRepoID)
            )
        }

        var nativeRefs: [String: String] = [
            "node_id": pr.id,
            "api_url": (try? client.url(for: "\(Self.repoAPIPath(fresh.repository.fullPath))/pulls/\(pr.number)").absoluteString) ?? "",
            "is_cross_repository": String(pr.isCrossRepository ?? false),
        ]
        nativeRefs["merge_state_status"] = pr.mergeStateStatus
        nativeRefs["mergeable"] = pr.mergeable
        nativeRefs["review_decision"] = pr.reviewDecision
        nativeRefs["status_check_rollup"] = headCommit?.statusCheckRollup?.state
        nativeRefs["head_repository"] = pr.headRepository?.nameWithOwner
        if let total = pr.files?.totalCount, total > (pr.files?.items.count ?? 0) {
            nativeRefs["changed_files_total"] = String(total)
        }

        return ChangeRequestSnapshot(
            summary: fresh,
            description: pr.body.flatMap { $0.isEmpty ? nil : $0 },
            source: source,
            baseSHA: pr.baseRefOid,
            reviewers: GitHubMapping.reviewers(latest: latest, requests: pr.reviewRequests?.items ?? []),
            reviews: reviews.compactMap(GitHubMapping.review),
            approvals: GitHubMapping.approvals(latest: latest, reviewDecision: pr.reviewDecision, mergeStateStatus: pr.mergeStateStatus),
            threads: threads,
            checks: checks,
            aggregateCheckState: aggregate,
            commits: (pr.commits?.items ?? []).map(GitHubMapping.commit),
            changedFiles: (pr.files?.items ?? []).map(GitHubMapping.changedFile),
            readiness: readiness,
            fetchedAt: clock.now,
            nativeRefs: nativeRefs
        )
    }

    // MARK: Fresh state before writes

    /// `GET /repos/{o}/{r}/pulls/{n}`.
    public func headInfo(for changeRequest: ChangeRequestKey) async throws -> HeadInfo {
        let pull = try await restPull(changeRequest)
        let state: ChangeRequestState = pull.merged == true || pull.mergedAt != nil ? .merged : (pull.state == "closed" ? .closed : .open)
        return HeadInfo(headSHA: pull.head.sha, state: state, isDraft: pull.draft ?? false, updatedAt: pull.updatedAt)
    }

    /// Diff threads via the GraphQL node (all comments); issue comments and review bodies via REST.
    public func thread(_ key: ThreadKey) async throws -> ReviewThread {
        switch key.kind {
        case .diffThread:
            let raw = try await graphQLThread(key)
            let thread = GitHubMapping.diffThread(raw, comments: try await allComments(of: raw), changeRequest: key.changeRequest)
            if let root = thread.rootComment { links.registerThreadRoot(thread.key, commentID: root.id) }
            return thread
        case .conversation:
            let commentID = try Self.suffix(of: key, prefix: ThreadKey.githubIssueCommentPrefix)
            let repo = try Self.repoAPIPath(try await repositoryPath(key.changeRequest.repo))
            let comment = try await client.getJSON(RESTIssueComment.self, "\(repo)/issues/comments/\(Self.segment(commentID))")
            return GitHubMapping.issueCommentThread(comment, changeRequest: key.changeRequest)
        case .reviewSummary:
            let reviewID = try Self.suffix(of: key, prefix: ThreadKey.githubReviewSummaryPrefix)
            let repo = try Self.repoAPIPath(try await repositoryPath(key.changeRequest.repo))
            let review = try await client.getJSON(
                RESTReview.self, "\(repo)/pulls/\(key.changeRequest.number)/reviews/\(Self.segment(reviewID))"
            )
            return GitHubMapping.reviewSummaryThread(review, changeRequest: key.changeRequest)
        }
    }

    // MARK: Helpers

    func restPull(_ changeRequest: ChangeRequestKey) async throws -> RESTPullRequest {
        let repo = try Self.repoAPIPath(try await repositoryPath(changeRequest.repo))
        return try await client.getJSON(RESTPullRequest.self, "\(repo)/pulls/\(changeRequest.number)")
    }

    /// The `PRRT_…` node, checked to belong to the key's pull request.
    func graphQLThread(_ key: ThreadKey) async throws -> GQLThread {
        let data = try await graphQL.execute(.thread, variables: ["id": .string(key.remoteID)], as: GQLThreadNodeData.self)
        guard let thread = data.node else {
            throw ProviderError.notFound("Review thread \(key.remoteID) was not found.")
        }
        if let number = thread.pullRequest?.number, number != key.changeRequest.number {
            throw ProviderError.notFound("Review thread \(key.remoteID) belongs to another pull request.")
        }
        if let repoID = thread.repository?.databaseId?.value, repoID != key.changeRequest.repo.remoteRepoID {
            throw ProviderError.notFound("Review thread \(key.remoteID) belongs to another repository.")
        }
        if let fullPath = thread.repository?.nameWithOwner {
            links.registerRepository(host: instance.host, remoteRepoID: key.changeRequest.repo.remoteRepoID, fullPath: fullPath)
        }
        return thread
    }

    /// First page from the thread plus `MergeCueThreadCommentsPage` pages.
    func allComments(of thread: GQLThread) async throws -> [GQLReviewComment] {
        var comments = thread.comments?.items ?? []
        var cursor = thread.comments?.nextCursor
        var pages = 0
        while let after = cursor, pages < Self.maxPages {
            let data = try await graphQL.execute(
                .threadCommentsPage,
                variables: ["id": .string(thread.id), "after": .string(after)],
                as: GQLThreadCommentsData.self
            )
            comments += data.node?.comments?.items ?? []
            cursor = data.node?.comments?.nextCursor
            pages += 1
        }
        var seen = Set<String>()
        return comments.filter { seen.insert($0.id).inserted }
    }

    private func pullRequestPage(_ query: GitHubQuery, base: [String: JSONValue], after: String) async throws -> GQLPullRequestPage? {
        var variables = base
        variables["after"] = .string(after)
        return try await graphQL.execute(query, variables: variables, as: GQLPullRequestPageData.self).repository?.pullRequest
    }

    static func suffix(of key: ThreadKey, prefix: String) throws -> String {
        guard key.remoteID.hasPrefix(prefix) else {
            throw ProviderError.invalidRequest("Thread id \(key.remoteID) is not a GitHub \(key.kind.rawValue) thread.")
        }
        let id = String(key.remoteID.dropFirst(prefix.count))
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else {
            throw ProviderError.invalidRequest("Thread id \(key.remoteID) is malformed.")
        }
        return id
    }
}
