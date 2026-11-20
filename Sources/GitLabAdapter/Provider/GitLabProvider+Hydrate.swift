import Foundation
import MergeCueCore
import MergeCueNetworking

extension GitLabProvider {
    /// Page limits for hydration (bounded work per merge request).
    enum HydrationLimits {
        static let discussionPages = 20
        static let commitPages = 3
        static let diffPages = 3
        static let versionPages = 2
        static let jobPages = 5
    }

    /// Fetches the merge request detail (`diff_refs`, `head_pipeline`, `detailed_merge_status`, …), the target
    /// project (clone URLs) and — for cross-project MRs — the source project, discussions, approvals, reviewers,
    /// head pipeline jobs, commits, changed files and diff versions.
    public func hydrate(_ summary: ChangeRequestSummary) async throws -> ChangeRequestSnapshot {
        try await hydrate(summary, previous: nil)
    }

    /// Incremental hydration (DECISIONS D36). The merge request detail is always read; with the stored `previous`
    /// snapshot of the same merge request:
    /// - the target (and source) project is taken from `previous`;
    /// - `/discussions` is skipped while `user_notes_count`, `updated_at` and the head are unchanged;
    /// - `/approvals` and `/reviewers` while `updated_at` and the head are unchanged;
    /// - pipeline jobs while the head pipeline (id and status) is unchanged and no check was pending;
    /// - `/commits`, `/diffs` and `/versions` while the head, base and start commits are unchanged.
    /// Skipped parts are taken from `previous`, so the snapshot equals a full hydration.
    public func hydrate(_ summary: ChangeRequestSummary, previous: ChangeRequestSnapshot?) async throws -> ChangeRequestSnapshot {
        let key = summary.key
        let projectID = key.repo.remoteRepoID
        let mrPath = GitLabAPI.mergeRequest(key)
        let api = self.api

        let mr = try await api.get(GLMergeRequest.self, mrPath)
        let reuse = previous.flatMap { GitLabReuse(previous: $0, mr: mr) }
        let targetProjectID = mr.targetProjectId ?? mr.projectId
        let sourceProjectID = mr.sourceProjectId ?? targetProjectID
        let isCrossProject = sourceProjectID != targetProjectID

        let needProject = reuse?.repository == nil
        let needDiscussions = reuse?.threads == nil
        let needApprovals = reuse?.review == nil
        let needContent = reuse?.content == nil
        let needJobs = reuse?.checks == nil
        let needSource = isCrossProject && reuse?.source == nil

        async let projectTask: GLProject?? = needProject
            ? Self.tolerant { try await api.get(GLProject.self, GitLabAPI.project(projectID)) } : nil
        async let discussionsTask: GitLabAPI.Paged<GLDiscussion>? = needDiscussions
            ? api.getAll(GLDiscussion.self, mrPath + "/discussions", maxPages: HydrationLimits.discussionPages) : nil
        async let approvalsTask: GLApprovals?? = needApprovals
            ? Self.tolerant { try await api.get(GLApprovals.self, mrPath + "/approvals") } : nil
        async let reviewersTask: [GLReviewerEntry]?? = needApprovals
            ? Self.tolerant { try await api.get([GLReviewerEntry].self, mrPath + "/reviewers") } : nil
        async let commitsTask: GitLabAPI.Paged<GLCommit>? = needContent
            ? api.getAll(GLCommit.self, mrPath + "/commits", maxPages: HydrationLimits.commitPages) : nil
        async let diffsTask: GitLabAPI.Paged<GLDiffFile>? = needContent
            ? api.getAll(GLDiffFile.self, mrPath + "/diffs", maxPages: HydrationLimits.diffPages) : nil
        async let versionsTask: [GLVersion]?? = needContent
            ? Self.tolerant { try await api.getAll(GLVersion.self, mrPath + "/versions", maxPages: HydrationLimits.versionPages).items }
            : nil
        async let sourceProjectTask: GLProject? = needSource ? Self.sourceProject(sourceProjectID, api: api) : nil
        async let jobsTask: [GLJob]? = needJobs ? Self.jobs(for: mr.headPipeline, fallbackProjectID: projectID, api: api) : nil

        let project = try await projectTask
        let discussions = try await discussionsTask
        let approvals = try await approvalsTask
        let reviewerEntries = try await reviewersTask
        let commits = try await commitsTask
        let diffs = try await diffsTask
        let fetchedVersions = try await versionsTask
        let versions = fetchedVersions.map { $0 ?? [] } ?? reuse?.content?.versions ?? []
        let sourceProject = try await sourceProjectTask
        let jobs = try await jobsTask

        // Repository: full project details when readable, else what the list item carried.
        var repository = reuse?.repository ?? summary.repository
        if let project = project ?? nil {
            repository = GitLabMapping.repository(project, account: key.repo.account)
        }
        let fresh = GitLabMapping.summary(
            mr,
            repository: repository,
            involvement: summary.involvement,
            currentUserID: session.user.map { String($0.id) } ?? key.repo.account.remoteUserID
        )

        let headSHA = GitLabMapping.headSHA(mr)
        let webURL = URL(string: mr.webUrl)
        GitLabLinkCache.remember(changeRequest: fresh.key, webURL: fresh.webURL, projectWebURL: repository.webURL)

        let threads: [ReviewThread]
        if let discussions {
            threads = GitLabThreadMapping.threads(
                discussions.items,
                context: GitLabThreadContext(changeRequest: fresh.key, webURL: webURL, currentHeadSHA: headSHA, versions: versions)
            )
        } else {
            threads = reuse?.threads ?? []
        }
        for thread in threads {
            if let root = thread.rootComment {
                GitLabLinkCache.remember(thread: thread.key, rootNoteID: root.id)
            }
        }

        let checks = jobs.map { GitLabCheckMapping.checks(pipeline: mr.headPipeline, jobs: $0, changeRequest: fresh.key, headSHA: headSHA) }
            ?? reuse?.checks ?? []
        for check in checks {
            if let url = check.detailsURL { GitLabLinkCache.remember(check: check.key, webURL: url) }
        }

        let reviewers: [Reviewer]
        let reviews: [Review]
        let approvalStatus: ApprovalStatus
        if let reused = reuse?.review {
            (reviewers, reviews, approvalStatus) = (reused.reviewers, reused.reviews, reused.approvals)
        } else {
            let entries = reviewerEntries ?? nil
            reviewers = entries.map(GitLabMapping.reviewers)
                ?? (mr.reviewers ?? []).map { Reviewer(person: GitLabMapping.person($0), state: .pending) }
            reviews = GitLabMapping.reviews(approvals: approvals ?? nil, reviewers: entries ?? [], headSHA: headSHA)
            approvalStatus = GitLabMapping.approvals(approvals ?? nil)
        }

        let source: SourceRepositoryInfo
        if isCrossProject {
            if let reused = reuse?.source {
                source = reused
            } else {
                source = SourceRepositoryInfo(
                    fullPath: sourceProject?.pathWithNamespace ?? "",
                    cloneURLs: sourceProject.map { GitLabMapping.repository($0, account: key.repo.account).cloneURLs } ?? [],
                    remoteID: String(sourceProjectID),
                    isFork: true
                )
            }
        } else {
            source = SourceRepositoryInfo(
                fullPath: repository.fullPath,
                cloneURLs: repository.cloneURLs,
                remoteID: String(sourceProjectID),
                isFork: false
            )
        }

        var nativeRefs: [String: String] = [
            "project_id": String(targetProjectID),
            "source_project_id": String(sourceProjectID),
            "target_project_id": String(targetProjectID),
            "merge_request_id": String(mr.id),
            "merge_request_iid": String(mr.iid),
            "api_url": (try? api.client.url(for: mrPath).absoluteString) ?? mrPath,
            "web_url": mr.webUrl,
        ]
        nativeRefs["detailed_merge_status"] = mr.detailedMergeStatus
        nativeRefs["merge_status"] = mr.mergeStatus
        nativeRefs["head_pipeline_id"] = mr.headPipeline.map { String($0.id) }
        nativeRefs["head_pipeline_project_id"] = mr.headPipeline?.projectId.map(String.init)
        nativeRefs["start_sha"] = mr.diffRefs?.startSha
        nativeRefs["latest_diff_version_id"] = versions.max { $0.id < $1.id }.map { String($0.id) }
        // Change indicators for the next incremental hydration.
        nativeRefs[GitLabReuse.Key.updatedAt] = mr.updatedAt
        nativeRefs[GitLabReuse.Key.notesCount] = mr.userNotesCount.map(String.init)
        nativeRefs[GitLabReuse.Key.headSHA] = headSHA
        nativeRefs[GitLabReuse.Key.baseSHA] = mr.diffRefs?.baseSha
        nativeRefs[GitLabReuse.Key.pipelineStatus] = mr.headPipeline?.status
        nativeRefs[GitLabReuse.Key.versions] = GitLabReuse.encode(versions)
        if let diffs, diffs.truncated { nativeRefs["changed_files_truncated"] = "true" }
        if let commits, commits.truncated { nativeRefs["commits_truncated"] = "true" }
        if let discussions, discussions.truncated { nativeRefs["discussions_truncated"] = "true" }
        for key in ["changed_files_truncated", "commits_truncated"] where commits == nil {
            nativeRefs[key] = previous?.nativeRefs[key]
        }
        if discussions == nil { nativeRefs["discussions_truncated"] = previous?.nativeRefs["discussions_truncated"] }

        return ChangeRequestSnapshot(
            summary: fresh,
            description: mr.description,
            source: source,
            baseSHA: mr.diffRefs?.baseSha,
            reviewers: reviewers,
            reviews: reviews,
            approvals: approvalStatus,
            threads: threads,
            checks: checks,
            commits: commits.map { $0.items.map(GitLabMapping.commit) } ?? reuse?.content?.commits ?? [],
            changedFiles: diffs.map { $0.items.map(GitLabMapping.changedFile) } ?? reuse?.content?.files ?? [],
            readiness: GitLabCheckMapping.readiness(mr),
            fetchedAt: clock.now,
            nativeRefs: nativeRefs
        )
    }

    /// The source project of a cross-project (fork) merge request; nil when not cross-project or not readable.
    static func sourceProject(_ projectID: Int?, api: GitLabAPI) async throws -> GLProject? {
        guard let projectID else { return nil }
        return try await tolerant { try await api.get(GLProject.self, GitLabAPI.project(String(projectID))) }
    }

    /// Jobs of the head pipeline. The pipeline may live in the **source** project (fork pipelines), so the
    /// pipeline's own `project_id` is used.
    static func jobs(for pipeline: GLPipeline?, fallbackProjectID: String, api: GitLabAPI) async throws -> [GLJob] {
        guard let pipeline else { return [] }
        let projectID = pipeline.projectId.map(String.init) ?? fallbackProjectID
        let path = "\(GitLabAPI.project(projectID))/pipelines/\(pipeline.id)/jobs"
        return try await tolerant { try await api.getAll(GLJob.self, path, maxPages: HydrationLimits.jobPages).items } ?? []
    }

    /// Runs `operation`, mapping "not available to this user/instance" (`404`, `403`) to nil. Other failures
    /// (auth, rate limits, outages) still throw.
    static func tolerant<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T? {
        do {
            return try await operation()
        } catch let error as ProviderError {
            switch error {
            case .notFound, .forbidden: return nil
            default: throw error
            }
        }
    }

    /// Fresh state of one discussion (before a reply/resolve), mapped like `hydrate` does.
    public func thread(_ key: ThreadKey) async throws -> ReviewThread {
        let mrPath = GitLabAPI.mergeRequest(key.changeRequest)
        let api = self.api
        async let discussionTask = api.get(GLDiscussion.self, GitLabAPI.discussion(key))
        async let mrTask = api.get(GLMergeRequest.self, mrPath)
        async let versionsTask = Self.tolerant {
            try await api.getAll(GLVersion.self, mrPath + "/versions", maxPages: HydrationLimits.versionPages).items
        }
        let discussion = try await discussionTask
        let mr = try await mrTask
        let versions = try await versionsTask ?? []
        let context = GitLabThreadContext(
            changeRequest: key.changeRequest,
            webURL: URL(string: mr.webUrl),
            currentHeadSHA: GitLabMapping.headSHA(mr),
            versions: versions
        )
        guard var thread = GitLabThreadMapping.thread(discussion, context: context) else {
            throw ProviderError.notFound("Discussion \(key.remoteID) has no notes.")
        }
        // Keep the caller's identity (the id includes the thread kind).
        thread.key = key
        if let root = thread.comments.first {
            GitLabLinkCache.remember(thread: key, rootNoteID: root.id)
        }
        if let webURL = URL(string: mr.webUrl) {
            GitLabLinkCache.remember(changeRequest: key.changeRequest, webURL: webURL, projectWebURL: GitLabMapping.projectWebURL(of: mr))
        }
        return thread
    }
}

/// What an incremental GitLab hydration may take from the previous snapshot (nil member = fetch it again).
struct GitLabReuse {
    enum Key {
        static let updatedAt = "updated_at"
        static let notesCount = "user_notes_count"
        static let headSHA = "head_sha"
        static let baseSHA = "base_sha"
        static let pipelineStatus = "head_pipeline_status"
        static let versions = "diff_versions"
    }

    struct Review {
        var reviewers: [Reviewer]
        var reviews: [MergeCueCore.Review]
        var approvals: ApprovalStatus
    }

    struct Content {
        var commits: [CommitInfo]
        var files: [ChangedFile]
        var versions: [GLVersion]
    }

    var repository: Repository?
    var source: SourceRepositoryInfo?
    var threads: [ReviewThread]?
    var review: Review?
    var checks: [CheckRun]?
    var content: Content?

    /// nil when `previous` is another merge request or predates the change indicators.
    init?(previous: ChangeRequestSnapshot, mr: GLMergeRequest) {
        let refs = previous.nativeRefs
        guard refs["merge_request_id"] == String(mr.id), let storedUpdatedAt = refs[Key.updatedAt] else { return nil }
        let head = GitLabMapping.headSHA(mr)
        let headUnchanged = head != nil && refs[Key.headSHA] == head
        let sameUpdate = storedUpdatedAt == mr.updatedAt
        repository = previous.summary.repository
        if refs["source_project_id"] == String(mr.sourceProjectId ?? mr.targetProjectId ?? mr.projectId) {
            source = previous.source
        }
        if headUnchanged, sameUpdate, let count = mr.userNotesCount, refs[Key.notesCount] == String(count) {
            threads = previous.threads
        }
        if headUnchanged, sameUpdate {
            review = Review(reviewers: previous.reviewers, reviews: previous.reviews, approvals: previous.approvals)
        }
        let pipelineUnchanged = refs["head_pipeline_id"] == mr.headPipeline.map { String($0.id) }
            && refs[Key.pipelineStatus] == mr.headPipeline?.status
        if headUnchanged, pipelineUnchanged, !previous.checks.contains(where: { !$0.status.isTerminal }) {
            checks = previous.checks
        }
        if headUnchanged, refs[Key.baseSHA] == mr.diffRefs?.baseSha, refs["start_sha"] == mr.diffRefs?.startSha,
           let versions = refs[Key.versions].flatMap(Self.decode) {
            content = Content(commits: previous.commits, files: previous.changedFiles, versions: versions)
        }
    }

    private struct StoredVersion: Codable {
        var id: Int
        var head: String?
        var base: String?
        var start: String?
        var created: Double?
    }

    static func encode(_ versions: [GLVersion]) -> String? {
        let stored = versions.map {
            StoredVersion(id: $0.id, head: $0.headCommitSha, base: $0.baseCommitSha, start: $0.startCommitSha, created: $0.createdAt?.timeIntervalSince1970)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) -> [GLVersion]? {
        guard let stored = try? JSONDecoder().decode([StoredVersion].self, from: Data(text.utf8)) else { return nil }
        return stored.map {
            GLVersion(id: $0.id, headCommitSha: $0.head, baseCommitSha: $0.base, startCommitSha: $0.start,
                      createdAt: $0.created.map(Date.init(timeIntervalSince1970:)))
        }
    }
}
