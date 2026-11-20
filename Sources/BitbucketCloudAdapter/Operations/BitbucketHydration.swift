import Foundation
import MergeCueCore
import MergeCueNetworking

extension BitbucketCloudProvider {
    /// How long after a new head (or the last check activity) checks are re-read even when none is pending: CI
    /// may not have reported yet.
    static let recentCheckWindow: TimeInterval = 10 * 60
    /// A pull request object from a listing this recent stands in for the detail request (`GET …/pullrequests/{id}`).
    static let listedPullRequestMaxAge: TimeInterval = 60

    /// Keys of the change indicators kept in `ChangeRequestSnapshot.nativeRefs` for incremental hydration.
    enum IndicatorKey {
        static let commentCount = "comment_count"
        static let taskCount = "task_count"
        static let updatedOn = "updated_on"
        static let sourceCommit = "source_commit"
        static let destinationCommit = "destination_commit"
        static let headSeenAt = "head_seen_at"
        static let pipelineBuilds = "pipeline_builds"
        /// Pipelines-mirrored commit statuses (`build:state`, sorted) the cached step checks belong to.
        static let pipelineStatuses = "pipeline_statuses"
        static let openTaskCount = "open_task_count"
    }

    /// Full pull request state: detail, comments (threads), tasks, commit statuses, Pipelines steps, commits and
    /// diffstat. Readiness is evaluated honestly (see `BitbucketReadiness`).
    public func hydrate(_ summary: ChangeRequestSummary) async throws -> ChangeRequestSnapshot {
        try await hydrate(summary, previous: nil)
    }

    /// Incremental hydration (DECISIONS D36). Request rules, each from a provider change indicator:
    /// - the pull request object comes from the listing of the same cycle when it carried participants (no detail
    ///   request), else `GET …/pullrequests/{id}`;
    /// - `/comments` only when `comment_count` is non-zero and it, `updated_on` or the source commit changed;
    /// - `/tasks` only when `task_count` (open tasks) is non-zero and changed;
    /// - commits and diffstat only when the source or destination commit changed, read from the repository
    ///   (`/commits/{src}?exclude={dst}`, `/diffstat/{src}..{dst}?topic=true`) to avoid the pull request
    ///   endpoints' redirects (forks keep the pull request endpoints);
    /// - `/statuses` only when the head changed, a check is pending, or the head / a check changed in the last
    ///   10 minutes;
    /// - Pipelines + steps only when a Pipelines status is failed / in progress / stopped and differs from the one
    ///   the cached steps belong to (a green pipeline is reported by its commit status).
    /// Skipped parts are taken from `previous`, so the snapshot equals a full hydration.
    public func hydrate(_ summary: ChangeRequestSummary, previous: ChangeRequestSnapshot?) async throws -> ChangeRequestSnapshot {
        directory.remember(summary.repository)
        let user = try await me()
        let mapper = try await mapper()
        let now = clock.now
        let path: BitbucketRepoPath
        let pr: BBPullRequest
        if let listed = session.listedPullRequest(summary.key.id, now: now, maxAge: Self.listedPullRequestMaxAge),
           listed.participants != nil, BitbucketMapper.versionToken(listed) == summary.versionToken,
           let listedPath = directory.entry(host: instance.host, uuid: summary.key.repo.remoteRepoID)?.path
            ?? BitbucketRepoPath(fullName: summary.repository.fullPath) {
            (path, pr) = (listedPath, listed)
        } else {
            (path, pr) = try await fetchPullRequest(summary.key)
        }
        let prPath = path.pullRequestPath(try pullRequestID(summary.key))
        var fresh = try mapper.summary(pr, knownRepository: summary.repository, currentUserUUID: user.remoteID)
        fresh.involvement.formUnion(summary.involvement)

        let source = mapper.sourceRepository(pr)
        let isFork = source?.isFork ?? false
        let reuse = previous.flatMap { BitbucketReuse(previous: $0, pr: pr, now: now) }
        let needComments = reuse?.comments == nil && (pr.commentCount ?? 1) > 0
        let needTasks = reuse?.openTaskCount == nil && (pr.taskCount ?? 1) > 0
        let needCommits = reuse?.commits == nil
        let needChecks = reuse?.checks == nil
        let src = pr.source?.commit?.hash
        let dst = pr.destination?.commit?.hash
        let direct = !isFork && src != nil && dst != nil

        async let commentsTask: [BBComment]? = needComments
            ? collect("\(prPath)/comments", query: pageSize(100), limit: limits.maxComments) : nil
        async let tasksTask: TaskFetch = needTasks ? fetchTasks("\(prPath)/tasks") : .skipped
        async let statusesTask: [BBCommitStatus]? = needChecks
            ? collect("\(prPath)/statuses", query: pageSize(100), limit: 200) : nil
        async let commitsTask: [BBCommit]? = needCommits
            ? (direct
                ? collect("\(path.apiPath)/commits/\(BitbucketIdentifiers.segment(src ?? ""))",
                          query: [URLQueryItem(name: "exclude", value: dst)] + pageSize(100), limit: limits.maxCommits)
                : collect("\(prPath)/commits", query: pageSize(100), limit: limits.maxCommits))
            : nil
        async let diffstatTask: [BBDiffStat]? = needCommits
            ? (direct
                ? collect("\(path.apiPath)/diffstat/\(BitbucketIdentifiers.segment("\(src ?? "")..\(dst ?? "")"))",
                          query: [URLQueryItem(name: "topic", value: "true")] + pageSize(500), limit: limits.maxFiles)
                : collect("\(prPath)/diffstat", query: pageSize(500), limit: limits.maxFiles))
            : nil

        let commits = try await commitsTask
        // PR objects carry abbreviated hashes; the newest PR commit (or the previous snapshot's full head) gives the
        // full head SHA.
        if let short = fresh.headSHA {
            if let commits, let full = commits.first(where: { BitbucketIdentifiers.sameCommit($0.hash, short) })?.hash {
                fresh.headSHA = full
            } else if let full = reuse?.fullHeadSHA {
                fresh.headSHA = full
            }
        }

        var nativeRefs: [String: String] = [
            "pull_request_id": String(pr.id),
            "repository_uuid": fresh.key.repo.remoteRepoID,
            "repository": path.fullName,
            "readiness_note": "Bitbucket merge checks (branch restrictions) are not readable without admin access; "
                + "MergeCue never reports Ready to merge for Bitbucket.",
        ]
        if let api = pr.links?.api?.href { nativeRefs["api_url"] = api }
        if let src { nativeRefs[IndicatorKey.sourceCommit] = src }
        if let dst { nativeRefs[IndicatorKey.destinationCommit] = dst }
        if let count = pr.commentCount { nativeRefs[IndicatorKey.commentCount] = String(count) }
        if let count = pr.taskCount { nativeRefs[IndicatorKey.taskCount] = String(count) }
        if let updated = pr.updatedOn { nativeRefs[IndicatorKey.updatedOn] = updated }
        // When the current head was first seen: kept while it is unchanged; a head seen for the first time on the
        // first hydration dates from its commit (an old PR is not "recent").
        let headCommitDate = commits?.first { BitbucketIdentifiers.sameCommit($0.hash, fresh.headSHA ?? "") }?.date
        let firstSeen = previous == nil ? min(now, headCommitDate ?? now) : now
        nativeRefs[IndicatorKey.headSeenAt] = reuse?.headSeenAt ?? String(firstSeen.timeIntervalSinceReferenceDate)

        let checksMapper = BitbucketChecksMapper(instance: instance, changeRequest: fresh.key, headSHA: fresh.headSHA)
        let checks: [CheckRun]
        if let reused = reuse?.checks {
            checks = reused.runs
            nativeRefs[IndicatorKey.pipelineBuilds] = reused.pipelineBuilds
            nativeRefs[IndicatorKey.pipelineStatuses] = reused.pipelineStatuses
            if reused.pipelinesUnavailable { nativeRefs["pipelines"] = "unavailable" }
        } else {
            let statuses = try await statusesTask ?? []
            checks = try await currentChecks(
                statuses: statuses, previous: previous, reuse: reuse, isFork: isFork, path: path,
                head: fresh.headSHA, mapper: checksMapper, nativeRefs: &nativeRefs
            )
        }

        let threads: [ReviewThread]
        if let comments = try await commentsTask {
            threads = BitbucketThreadBuilder(
                mapper: mapper, changeRequest: fresh.key, pullRequestURL: fresh.webURL, headSHA: fresh.headSHA
            ).build(comments)
        } else {
            threads = reuse?.comments ?? []
        }
        let openTaskCount: Int
        switch try await tasksTask {
        case .fetched(let tasks):
            openTaskCount = tasks.filter { $0.state?.uppercased() == "UNRESOLVED" && $0.pending != true }.count
        case .unavailable:
            openTaskCount = 0
            nativeRefs["tasks"] = "unavailable"
        case .skipped:
            // Skipped: no open task, or the previous count (and availability) still holds.
            openTaskCount = needTasks ? 0 : (reuse?.openTaskCount?.count ?? 0)
            if reuse?.openTaskCount?.unavailable == true { nativeRefs["tasks"] = "unavailable" }
        }
        let diffstat = try await diffstatTask
        for check in checks { directory.recordCheckURL(check.detailsURL, for: check.key) }
        nativeRefs[IndicatorKey.openTaskCount] = String(openTaskCount)

        let reviewers = mapper.reviewers(pr)
        let readiness = BitbucketReadiness.evaluate(
            state: fresh.state,
            isDraft: fresh.isDraft,
            reviewers: reviewers,
            threads: threads,
            unresolvedTaskCount: openTaskCount,
            checks: checks
        )
        return ChangeRequestSnapshot(
            summary: fresh,
            description: pr.summary?.raw ?? pr.description,
            source: source,
            baseSHA: pr.destination?.commit?.hash,
            reviewers: reviewers,
            reviews: mapper.reviews(pr),
            approvals: mapper.approvals(pr),
            threads: threads,
            checks: checks,
            commits: commits.map { $0.map(mapper.commit) } ?? reuse?.commits?.commits ?? [],
            changedFiles: diffstat.map { $0.compactMap(mapper.changedFile) } ?? reuse?.commits?.files ?? [],
            readiness: readiness,
            fetchedAt: now,
            nativeRefs: nativeRefs
        )
    }

    /// Checks from freshly read commit statuses. Pipelines steps are read only when a Pipelines status is not green
    /// and differs from the statuses the previous snapshot's steps belong to (cached per head); otherwise the
    /// previous steps (same signature) or the plain statuses are reported.
    func currentChecks(
        statuses: [BBCommitStatus], previous: ChangeRequestSnapshot?, reuse: BitbucketReuse?, isFork: Bool,
        path: BitbucketRepoPath, head: String?, mapper: BitbucketChecksMapper, nativeRefs: inout [String: String]
    ) async throws -> [CheckRun] {
        let pipelineStatuses = statuses.filter {
            $0.url?.contains("pipelines") == true && BitbucketChecksMapper.pipelineBuildNumber(inStatusURL: $0.url) != nil
        }
        let signature = pipelineStatuses
            .map { "\(BitbucketChecksMapper.pipelineBuildNumber(inStatusURL: $0.url) ?? 0):\($0.state?.uppercased() ?? "")" }
            .sorted().joined(separator: ",")
        let notGreen = pipelineStatuses.contains { $0.state?.uppercased() != "SUCCESSFUL" }
        let previousSteps = (previous?.checks ?? []).filter { $0.key.source == .bitbucketPipelineStep }
        let headUnchanged = reuse?.fullHeadSHA != nil
        if !signature.isEmpty { nativeRefs[IndicatorKey.pipelineStatuses] = signature }

        // Same head, same Pipelines statuses: the cached steps still hold.
        if headUnchanged, !previousSteps.isEmpty, previous?.nativeRefs[IndicatorKey.pipelineStatuses] == signature {
            let builds = previous?.nativeRefs[IndicatorKey.pipelineBuilds] ?? ""
            nativeRefs[IndicatorKey.pipelineBuilds] = builds
            let buildNumbers = Set(builds.split(separator: ",").compactMap { Int($0) })
            return mapper.checks(fromStatuses: statuses, fetchedPipelineBuildNumbers: buildNumbers) + previousSteps
        }
        let stepsWereRunning = headUnchanged && previousSteps.contains { !$0.status.isTerminal }
        guard !isFork, let head, notGreen || stepsWereRunning, previous?.nativeRefs["pipelines"] != "unavailable" || !headUnchanged else {
            if previous?.nativeRefs["pipelines"] == "unavailable", headUnchanged { nativeRefs["pipelines"] = "unavailable" }
            return mapper.checks(fromStatuses: statuses, fetchedPipelineBuildNumbers: [])
        }
        if let (found, builds) = try await optional({ try await fetchPipelineChecks(path: path, commit: head, mapper: mapper) }) {
            nativeRefs[IndicatorKey.pipelineBuilds] = builds.sorted().map(String.init).joined(separator: ",")
            return mapper.checks(fromStatuses: statuses, fetchedPipelineBuildNumbers: builds) + found
        }
        nativeRefs["pipelines"] = "unavailable"
        return mapper.checks(fromStatuses: statuses, fetchedPipelineBuildNumbers: [])
    }

    /// Outcome of the optional `/tasks` read.
    enum TaskFetch: Sendable {
        case fetched([BBTask])
        /// Missing scope (403) or feature off (404).
        case unavailable
        /// Not needed (no open task, or the previous count still holds).
        case skipped
    }

    func fetchTasks(_ path: String) async throws -> TaskFetch {
        guard let tasks: [BBTask] = try await optional({ try await collect(path, query: pageSize(100), limit: 500) }) else {
            return .unavailable
        }
        return .fetched(tasks)
    }

    func pageSize(_ size: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "pagelen", value: String(size))]
    }

    /// Runs `body`; `forbidden`/`notFound` (missing scope, feature disabled) become nil, other errors propagate.
    func optional<T: Sendable>(_ body: () async throws -> T) async throws -> T? {
        do {
            return try await body()
        } catch let error as ProviderError {
            switch error {
            case .forbidden, .notFound: return nil
            default: throw error
            }
        }
    }

    /// Steps of the newest pipeline per selector that ran on `commit`, plus the build numbers of every pipeline
    /// seen (used to drop the commit statuses Pipelines mirrors for them).
    func fetchPipelineChecks(path: BitbucketRepoPath, commit: String, mapper: BitbucketChecksMapper) async throws -> ([CheckRun], Set<Int>) {
        let pipelines: [BBPipeline] = try await collect(
            "\(path.apiPath)/pipelines",
            query: [
                URLQueryItem(name: "target.commit.hash", value: commit),
                URLQueryItem(name: "sort", value: "-created_on"),
                URLQueryItem(name: "pagelen", value: "20"),
            ],
            limit: 20
        )
        let relevant = pipelines.filter { pipeline in
            guard let hash = pipeline.target?.commit?.hash else { return true }
            return BitbucketIdentifiers.sameCommit(hash, commit)
        }
        var checks: [CheckRun] = []
        for pipeline in BitbucketChecksMapper.latestPipelines(relevant) {
            let steps: [BBPipelineStep] = try await collect(
                "\(path.apiPath)/pipelines/\(BitbucketIdentifiers.segment(pipeline.uuid))/steps",
                query: pageSize(100),
                limit: 100
            )
            checks += mapper.checks(pipeline: pipeline, steps: steps, repository: path)
        }
        return (checks, Set(relevant.compactMap(\.buildNumber)))
    }
}

/// What an incremental Bitbucket hydration may take from the previous snapshot (nil member = fetch it again).
struct BitbucketReuse {
    struct Checks {
        var runs: [CheckRun]
        var pipelineBuilds: String?
        var pipelineStatuses: String?
        var pipelinesUnavailable: Bool
    }

    var comments: [ReviewThread]?
    var openTaskCount: (count: Int, unavailable: Bool)?
    var commits: (commits: [CommitInfo], files: [ChangedFile])?
    var checks: Checks?
    /// The previous full head SHA when the (abbreviated) source commit is unchanged.
    var fullHeadSHA: String?
    /// When the current head was first seen (kept while the head is unchanged).
    var headSeenAt: String?

    /// nil when `previous` is not usable at all (another pull request).
    init?(previous: ChangeRequestSnapshot, pr: BBPullRequest, now: Date) {
        let refs = previous.nativeRefs
        typealias Key = BitbucketCloudProvider.IndicatorKey
        guard refs["pull_request_id"] == String(pr.id) else { return nil }
        let head = pr.source?.commit?.hash
        let headUnchanged = head != nil && refs[Key.sourceCommit].map { BitbucketIdentifiers.sameCommit($0, head ?? "") } == true
        let baseUnchanged = refs[Key.destinationCommit] == pr.destination?.commit?.hash
        if headUnchanged {
            fullHeadSHA = previous.summary.headSHA
            headSeenAt = refs[Key.headSeenAt]
        }
        if headUnchanged, let count = pr.commentCount, refs[Key.commentCount] == String(count),
           let updated = pr.updatedOn, refs[Key.updatedOn] == updated {
            comments = previous.threads
        } else if headUnchanged, pr.commentCount == 0 {
            comments = []
        }
        if let count = pr.taskCount, refs[Key.taskCount] == String(count),
           let open = refs[Key.openTaskCount].flatMap(Int.init) {
            openTaskCount = (open, refs["tasks"] == "unavailable")
        }
        if headUnchanged, baseUnchanged {
            commits = (previous.commits, previous.changedFiles)
        }
        if headUnchanged, !Self.checksMayChange(previous, headSeenAt: headSeenAt, now: now) {
            checks = Checks(
                runs: previous.checks, pipelineBuilds: refs[Key.pipelineBuilds],
                pipelineStatuses: refs[Key.pipelineStatuses], pipelinesUnavailable: refs["pipelines"] == "unavailable"
            )
        }
    }

    /// Checks are re-read while one is pending, or while the head or any check changed within
    /// `recentCheckWindow` (CI may not have reported, or may report more).
    static func checksMayChange(_ previous: ChangeRequestSnapshot, headSeenAt: String?, now: Date) -> Bool {
        if previous.checks.contains(where: { !$0.status.isTerminal }) { return true }
        let window = BitbucketCloudProvider.recentCheckWindow
        guard let seen = headSeenAt.flatMap(TimeInterval.init).map(Date.init(timeIntervalSinceReferenceDate:)) else { return true }
        if now.timeIntervalSince(seen) < window { return true }
        let latest = previous.checks.compactMap { $0.completedAt ?? $0.startedAt }.max()
        if let latest, now.timeIntervalSince(latest) < window { return true }
        return false
    }
}
