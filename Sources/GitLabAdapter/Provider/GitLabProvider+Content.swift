import Foundation
import MergeCueCore
import MergeCueNetworking

extension GitLabProvider {
    /// Maximum `/diffs` pages fetched for `diff(for:)` (100 files per page).
    static let diffPayloadPages = 5

    /// `GET /projects/:id/jobs/:job_id/trace` for a job check, or for the first failed job of a pipeline check.
    /// ANSI colors and GitLab section markers are stripped; the text is redacted and bounded
    /// (`LogExcerpt.make`). The log is untrusted input.
    public func failureLog(for check: CheckRun, maxBytes: Int) async throws -> LogExcerpt {
        guard check.key.source == .gitlabJob || check.key.source == .gitlabPipeline else {
            throw ProviderError.invalidRequest("Not a GitLab pipeline or job check.")
        }
        let locator = check.logLocator
        typealias Key = GitLabCheckMapping.LocatorKey
        let jobID: String? = if check.key.source == .gitlabJob {
            locator[Key.jobID] ?? check.key.remoteID
        } else {
            locator[Key.failedJobID]
        }
        guard let jobID, !jobID.isEmpty else {
            throw ProviderError.notFound("Pipeline \(check.key.remoteID) has no failed job with a log.")
        }
        let projectID = locator[Key.projectID] ?? check.key.changeRequest.repo.remoteRepoID
        let path = "\(GitLabAPI.project(projectID))/jobs/\(RequestURLBuilder.encodePathSegment(jobID))/trace"
        let response = try await api.getText(path)
        let jobKey = CheckKey(changeRequest: check.key.changeRequest, source: .gitlabJob, remoteID: jobID)
        let fullLogURL = GitLabLinkCache.checkURL(jobKey)
            ?? (check.key.source == .gitlabJob ? check.detailsURL : nil)
            ?? GitLabLinkCache.projectURL(check.key.changeRequest.repo)?.appending(path: "-/jobs/\(jobID)")
        return LogExcerpt.make(rawLog: Self.cleanTrace(response.bodyText), maxBytes: maxBytes, fullLogURL: fullLogURL)
    }

    /// Removes ANSI escape sequences and GitLab `section_start:…`/`section_end:…` markers from a job trace.
    static func cleanTrace(_ trace: String) -> String {
        var text = trace.replacingOccurrences(
            of: #"\x{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"section_(start|end):[0-9]+:[A-Za-z0-9_.\-\[\]=,]*\r?"#, with: "", options: .regularExpression
        )
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Unified diff of the merge request: `raw_diffs` when the instance has it, otherwise `/diffs` rendered into
    /// git format. Bounded to `maxBytes`; `truncated` is also set when GitLab omitted files or pages remain.
    public func diff(for changeRequest: ChangeRequestKey, maxBytes: Int) async throws -> DiffPayload {
        let mrPath = GitLabAPI.mergeRequest(changeRequest)
        let api = self.api
        async let mrTask = api.get(GLMergeRequest.self, mrPath)
        async let filesTask = api.getAll(GLDiffFile.self, mrPath + "/diffs", maxPages: Self.diffPayloadPages)
        let mr = try await mrTask

        var text: String
        var omitted = 0
        do {
            text = try await api.getText(mrPath + "/raw_diffs").bodyText
        } catch ProviderError.notFound {
            let rendered = GitLabDiffRenderer.render(try await filesTask.items)
            text = rendered.text
            omitted = rendered.omittedFiles
        }
        let files = try await filesTask
        if omitted == 0 {
            omitted = files.items.filter { $0.tooLarge == true || ($0.collapsed == true && ($0.diff ?? "").isEmpty) }.count
        }
        let bounded = BoundedText.truncate(text, maxBytes: max(0, maxBytes))
        return DiffPayload(
            unifiedDiff: bounded.text,
            files: files.items.map(GitLabMapping.changedFile),
            truncated: bounded.isTruncated || files.truncated || omitted > 0,
            baseSHA: mr.diffRefs?.baseSha,
            headSHA: GitLabMapping.headSHA(mr)
        )
    }
}
