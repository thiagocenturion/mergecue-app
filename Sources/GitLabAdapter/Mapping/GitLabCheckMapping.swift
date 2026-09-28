import Foundation
import MergeCueCore

/// GitLab pipelines/jobs → `CheckRun`s, and merge readiness.
enum GitLabCheckMapping {
    /// `logLocator` keys.
    enum LocatorKey {
        static let projectID = "project_id"
        static let jobID = "job_id"
        static let pipelineID = "pipeline_id"
        /// On the pipeline aggregate: the first failed (not allowed-to-fail) job, for `failureLog`.
        static let failedJobID = "failed_job_id"
    }

    // MARK: Status

    /// Job status (https://docs.gitlab.com/api/jobs/#job-status-values). A failed job with `allow_failure` is
    /// `.neutral` (GitLab shows a warning; the pipeline still passes). A blocking `manual` job needs an action.
    static func jobStatus(_ status: String, allowFailure: Bool) -> CheckStatus {
        switch status {
        case "created", "pending", "waiting_for_resource", "preparing", "scheduled", "waiting_for_callback": .queued
        case "running", "canceling": .inProgress
        case "success": .success
        case "failed": allowFailure ? .neutral : .failure
        case "canceled": .cancelled
        case "skipped": .skipped
        case "manual": allowFailure ? .skipped : .actionRequired
        default: .unknown
        }
    }

    /// Pipeline status (same vocabulary; `manual` = blocked on a manual job).
    static func pipelineStatus(_ status: String) -> CheckStatus {
        switch status {
        case "manual": .actionRequired
        default: jobStatus(status, allowFailure: false)
        }
    }

    // MARK: Checks

    static func checks(pipeline: GLPipeline?, jobs: [GLJob], changeRequest: ChangeRequestKey, headSHA: String?) -> [CheckRun] {
        guard let pipeline else { return [] }
        let projectID = pipeline.projectId.map(String.init) ?? changeRequest.repo.remoteRepoID
        let jobChecks = jobs.map { job in
            let allowFailure = job.allowFailure ?? false
            var locator = [LocatorKey.projectID: job.pipeline?.projectId.map(String.init) ?? projectID, LocatorKey.jobID: String(job.id)]
            locator[LocatorKey.pipelineID] = String(job.pipeline?.id ?? pipeline.id)
            var summary: String? = job.stage.map { "Stage: \($0)" }
            if job.status == "failed" {
                let reason = job.failureReason.map { " (\($0.replacingOccurrences(of: "_", with: " ")))" } ?? ""
                summary = [summary, allowFailure ? "Failed, allowed to fail\(reason)" : "Failed\(reason)"]
                    .compactMap { $0 }.joined(separator: " · ")
            }
            return CheckRun(
                key: CheckKey(changeRequest: changeRequest, source: .gitlabJob, remoteID: String(job.id)),
                name: job.name,
                status: jobStatus(job.status, allowFailure: allowFailure),
                isRequired: allowFailure ? false : nil,
                startedAt: job.startedAt,
                completedAt: job.finishedAt,
                detailsURL: job.webUrl.flatMap(URL.init(string:)),
                commitSHA: job.pipeline?.sha ?? pipeline.sha,
                summary: summary,
                logLocator: locator
            )
        }
        var pipelineLocator = [LocatorKey.projectID: projectID, LocatorKey.pipelineID: String(pipeline.id)]
        if let failed = jobs.first(where: { $0.status == "failed" && $0.allowFailure != true }) {
            pipelineLocator[LocatorKey.failedJobID] = String(failed.id)
        }
        var status = pipelineStatus(pipeline.status)
        if let headSHA, let sha = pipeline.sha, sha != headSHA, status.isTerminal {
            status = .stale
        }
        let aggregate = CheckRun(
            key: CheckKey(changeRequest: changeRequest, source: .gitlabPipeline, remoteID: String(pipeline.id)),
            name: "Pipeline #\(pipeline.id)",
            status: status,
            startedAt: pipeline.startedAt ?? pipeline.createdAt,
            completedAt: pipeline.finishedAt,
            detailsURL: pipeline.webUrl.flatMap(URL.init(string:)),
            commitSHA: pipeline.sha,
            summary: "Pipeline \(pipeline.status.replacingOccurrences(of: "_", with: " "))",
            logLocator: pipelineLocator
        )
        return [aggregate] + jobChecks
    }

    // MARK: Readiness

    /// Human reasons for `detailed_merge_status` values that block a merge
    /// (https://docs.gitlab.com/api/merge_requests/#merge-status).
    static let blockingReasons: [String: String] = [
        "approvals_syncing": "Approvals are syncing",
        "ci_must_pass": "A pipeline must succeed before merge",
        "ci_still_running": "Pipeline still running",
        "commits_status": "Source branch is missing or has no commits",
        "conflict": "Merge conflicts",
        "discussions_not_resolved": "Unresolved threads",
        "draft_status": "Draft",
        "jira_association_missing": "Jira issue reference required",
        "merge_request_blocked": "Blocked by another merge request",
        "merge_time": "Merge not allowed before the scheduled time",
        "need_rebase": "Needs rebase",
        "not_approved": "Approval required",
        "not_open": "Not open",
        "requested_changes": "Changes requested",
        "security_policy_pipeline_check": "Security policy pipelines must succeed",
        "security_policy_violations": "Security policy violations",
        "status_checks_must_pass": "External status checks must pass",
        "external_status_checks": "External status checks must pass",
        "locked_paths": "Locked paths",
        "locked_lfs_files": "Locked LFS files",
        "title_regex": "Title does not match the required pattern",
        "blocked_status": "Blocked",
        "broken_status": "Source branch is broken",
    ]

    /// Mergeability that GitLab is still computing: nothing is known yet.
    static let transientStatuses: Set<String> = ["checking", "unchecked", "preparing", "approvals_syncing"]

    /// - `readyToMerge`: `detailed_merge_status == "mergeable"`, blocking discussions resolved, and the head
    ///   pipeline succeeded on the current head SHA.
    /// - `checksGreen`: the head pipeline succeeded but GitLab has not finished computing mergeability.
    /// - `blocked(reasons)`: anything GitLab reports as blocking (plus pipeline/threads/conflicts/draft).
    /// - `unknown`: mergeable with no pipeline on the current head (MergeCue cannot confirm checks).
    /// - Merged/closed MRs are `blocked` with an explicit reason; their state is preserved on the summary.
    static func readiness(_ mr: GLMergeRequest) -> MergeReadiness {
        switch GitLabMapping.state(mr.state) {
        case .merged: return .blocked(reasons: ["Already merged"])
        case .closed: return .blocked(reasons: ["Closed without merge"])
        case .open: break
        }
        let head = GitLabMapping.headSHA(mr)
        let pipeline = mr.headPipeline
        let pipelineOnHead = pipeline.map { $0.sha == nil || head == nil || $0.sha == head } ?? false
        let pipelineSucceeded = pipeline?.status == "success" && pipelineOnHead
        let detailed = mr.detailedMergeStatus
        let discussionsResolved = mr.blockingDiscussionsResolved ?? (detailed != "discussions_not_resolved")
        let isDraft = GitLabMapping.isDraft(mr)
        let hasConflicts = mr.hasConflicts == true

        if detailed == "mergeable", discussionsResolved, !hasConflicts, !isDraft {
            if pipelineSucceeded { return .readyToMerge }
            if pipeline == nil { return .unknown }
        }
        if pipelineSucceeded, detailed == nil || transientStatuses.contains(detailed ?? "") {
            return .checksGreen
        }

        var reasons: [String] = []
        func add(_ reason: String) {
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        if let detailed, detailed != "mergeable", !transientStatuses.contains(detailed) {
            add(blockingReasons[detailed] ?? "Not mergeable (\(detailed.replacingOccurrences(of: "_", with: " ")))")
        }
        if isDraft { add("Draft") }
        if hasConflicts { add("Merge conflicts") }
        if !discussionsResolved { add("Unresolved threads") }
        if let pipeline {
            if !pipelineOnHead {
                add("Pipeline has not run on the current head")
            } else {
                switch pipelineStatus(pipeline.status) {
                case .success, .skipped, .neutral: break
                case .queued, .inProgress: add("Pipeline still running")
                case .failure, .timedOut: add("Pipeline failed")
                case .actionRequired: add("Pipeline waiting for a manual action")
                case .cancelled: add("Pipeline cancelled")
                case .stale, .unknown: add("Pipeline status unknown")
                }
            }
        }
        if reasons.isEmpty {
            // Mergeability still being computed and no successful pipeline to vouch for the head.
            return .unknown
        }
        return .blocked(reasons: reasons)
    }
}
