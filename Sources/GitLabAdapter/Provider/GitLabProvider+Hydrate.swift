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
        let key = summary.key
        let projectID = key.repo.remoteRepoID
        let mrPath = GitLabAPI.mergeRequest(key)
        let api = self.api

        async let mrTask = api.get(GLMergeRequest.self, mrPath)
        async let projectTask = Self.tolerant { try await api.get(GLProject.self, GitLabAPI.project(projectID)) }
        async let discussionsTask = api.getAll(GLDiscussion.self, mrPath + "/discussions", maxPages: HydrationLimits.discussionPages)
        async let approvalsTask = Self.tolerant { try await api.get(GLApprovals.self, mrPath + "/approvals") }
        async let reviewersTask = Self.tolerant { try await api.get([GLReviewerEntry].self, mrPath + "/reviewers") }
        async let commitsTask = api.getAll(GLCommit.self, mrPath + "/commits", maxPages: HydrationLimits.commitPages)
        async let diffsTask = api.getAll(GLDiffFile.self, mrPath + "/diffs", maxPages: HydrationLimits.diffPages)
        async let versionsTask = Self.tolerant {
            try await api.getAll(GLVersion.self, mrPath + "/versions", maxPages: HydrationLimits.versionPages).items
        }

        let mr = try await mrTask
        let targetProjectID = mr.targetProjectId ?? mr.projectId
        let sourceProjectID = mr.sourceProjectId ?? targetProjectID
        let isCrossProject = sourceProjectID != targetProjectID

        async let sourceProjectTask = Self.sourceProject(isCrossProject ? sourceProjectID : nil, api: api)
        async let jobsTask: [GLJob] = Self.jobs(for: mr.headPipeline, fallbackProjectID: projectID, api: api)

        let project = try await projectTask
        let discussions = try await discussionsTask
        let approvals = try await approvalsTask
        let reviewerEntries = try await reviewersTask
        let commits = try await commitsTask
        let diffs = try await diffsTask
        let versions = try await versionsTask ?? []
        let sourceProject = try await sourceProjectTask
        let jobs = try await jobsTask

        // Repository: full project details when readable, else what the list item carried.
        var repository = summary.repository
        if let project {
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

        let threads = GitLabThreadMapping.threads(
            discussions.items,
            context: GitLabThreadContext(changeRequest: fresh.key, webURL: webURL, currentHeadSHA: headSHA, versions: versions)
        )
        for thread in threads {
            if let root = thread.rootComment {
                GitLabLinkCache.remember(thread: thread.key, rootNoteID: root.id)
            }
        }

        let checks = GitLabCheckMapping.checks(pipeline: mr.headPipeline, jobs: jobs, changeRequest: fresh.key, headSHA: headSHA)
        for check in checks {
            if let url = check.detailsURL { GitLabLinkCache.remember(check: check.key, webURL: url) }
        }

        let reviewers = reviewerEntries.map(GitLabMapping.reviewers)
            ?? (mr.reviewers ?? []).map { Reviewer(person: GitLabMapping.person($0), state: .pending) }

        let source: SourceRepositoryInfo
        if isCrossProject {
            source = SourceRepositoryInfo(
                fullPath: sourceProject?.pathWithNamespace ?? "",
                cloneURLs: sourceProject.map { GitLabMapping.repository($0, account: key.repo.account).cloneURLs } ?? [],
                remoteID: String(sourceProjectID),
                isFork: true
            )
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
        if diffs.truncated { nativeRefs["changed_files_truncated"] = "true" }
        if commits.truncated { nativeRefs["commits_truncated"] = "true" }
        if discussions.truncated { nativeRefs["discussions_truncated"] = "true" }

        return ChangeRequestSnapshot(
            summary: fresh,
            description: mr.description,
            source: source,
            baseSHA: mr.diffRefs?.baseSha,
            reviewers: reviewers,
            reviews: GitLabMapping.reviews(approvals: approvals, reviewers: reviewerEntries ?? [], headSHA: headSHA),
            approvals: GitLabMapping.approvals(approvals),
            threads: threads,
            checks: checks,
            commits: commits.items.map(GitLabMapping.commit),
            changedFiles: diffs.items.map(GitLabMapping.changedFile),
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
