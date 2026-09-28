import Foundation
import MergeCueCore
import MergeCueNetworking

extension BitbucketCloudProvider {
    /// Full pull request state: detail, comments (threads), tasks, commit statuses, Pipelines steps for the source
    /// commit, commits and diffstat. Readiness is evaluated honestly (see `BitbucketReadiness`).
    ///
    /// Tasks and Pipelines are optional data: when the token lacks their scope (403) or Pipelines is disabled (404)
    /// they are skipped and noted in `nativeRefs`. Pipelines are read from the destination repository only (fork
    /// pull requests rely on commit statuses).
    public func hydrate(_ summary: ChangeRequestSummary) async throws -> ChangeRequestSnapshot {
        directory.remember(summary.repository)
        let user = try await me()
        let mapper = try await mapper()
        let (path, pr) = try await fetchPullRequest(summary.key)
        let prPath = path.pullRequestPath(try pullRequestID(summary.key))
        var fresh = try mapper.summary(pr, knownRepository: summary.repository, currentUserUUID: user.remoteID)
        fresh.involvement.formUnion(summary.involvement)

        async let commentsTask: [BBComment] = collect("\(prPath)/comments", query: pageSize(100), limit: limits.maxComments)
        async let tasksTask: Optional<[BBTask]> = optional { try await collect("\(prPath)/tasks", query: pageSize(100), limit: 500) }
        async let statusesTask: [BBCommitStatus] = collect("\(prPath)/statuses", query: pageSize(100), limit: 200)
        async let commitsTask: [BBCommit] = collect("\(prPath)/commits", query: pageSize(100), limit: limits.maxCommits)
        async let diffstatTask: [BBDiffStat] = collect("\(prPath)/diffstat", query: pageSize(500), limit: limits.maxFiles)

        let commits = try await commitsTask
        // PR objects carry abbreviated hashes; the newest PR commit gives the full head SHA.
        if let short = fresh.headSHA, let full = commits.first(where: { BitbucketIdentifiers.sameCommit($0.hash, short) })?.hash {
            fresh.headSHA = full
        }
        let source = mapper.sourceRepository(pr)
        let isFork = source?.isFork ?? false

        var nativeRefs: [String: String] = [
            "pull_request_id": String(pr.id),
            "repository_uuid": fresh.key.repo.remoteRepoID,
            "repository": path.fullName,
            "readiness_note": "Bitbucket merge checks (branch restrictions) are not readable without admin access; "
                + "MergeCue never reports Ready to merge for Bitbucket.",
        ]
        if let api = pr.links?.api?.href { nativeRefs["api_url"] = api }
        if let hash = pr.source?.commit?.hash { nativeRefs["source_commit"] = hash }
        if let hash = pr.destination?.commit?.hash { nativeRefs["destination_commit"] = hash }

        var pipelineChecks: [CheckRun] = []
        var fetchedBuilds: Set<Int> = []
        let checksMapper = BitbucketChecksMapper(instance: instance, changeRequest: fresh.key, headSHA: fresh.headSHA)
        if !isFork, let head = fresh.headSHA {
            if let (checks, builds) = try await optional({ try await fetchPipelineChecks(path: path, commit: head, mapper: checksMapper) }) {
                pipelineChecks = checks
                fetchedBuilds = builds
            } else {
                nativeRefs["pipelines"] = "unavailable"
            }
        }

        let comments = try await commentsTask
        let tasks = try await tasksTask
        let statuses = try await statusesTask
        let diffstat = try await diffstatTask
        if tasks == nil { nativeRefs["tasks"] = "unavailable" }

        let threads = BitbucketThreadBuilder(
            mapper: mapper, changeRequest: fresh.key, pullRequestURL: fresh.webURL, headSHA: fresh.headSHA
        ).build(comments)
        let checks = checksMapper.checks(fromStatuses: statuses, fetchedPipelineBuildNumbers: fetchedBuilds) + pipelineChecks
        for check in checks { directory.recordCheckURL(check.detailsURL, for: check.key) }
        let openTasks = (tasks ?? []).filter { $0.state?.uppercased() == "UNRESOLVED" && $0.pending != true }
        nativeRefs["open_task_count"] = String(openTasks.count)

        let reviewers = mapper.reviewers(pr)
        let readiness = BitbucketReadiness.evaluate(
            state: fresh.state,
            isDraft: fresh.isDraft,
            reviewers: reviewers,
            threads: threads,
            unresolvedTaskCount: openTasks.count,
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
            commits: commits.map(mapper.commit),
            changedFiles: diffstat.compactMap(mapper.changedFile),
            readiness: readiness,
            fetchedAt: clock.now,
            nativeRefs: nativeRefs
        )
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
