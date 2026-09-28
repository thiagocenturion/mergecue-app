import Foundation
import MergeCueCore
import MergeCueNetworking

extension GitHubProvider {
    // MARK: CI logs

    /// - GitHub Actions jobs: `GET /repos/{o}/{r}/actions/jobs/{job_id}/logs` (a redirect to blob storage; the
    ///   transport drops `Authorization` on the cross-origin hop). Expired/unavailable logs fall back to the check
    ///   run output.
    /// - Other check runs: `GET /repos/{o}/{r}/check-runs/{id}` output title/summary/text.
    /// - Commit statuses: no log API — an excerpt with the status description and the details URL only.
    ///
    /// The text is redacted and bounded (`LogExcerpt.make`) and remains untrusted input.
    public func failureLog(for check: CheckRun, maxBytes: Int) async throws -> LogExcerpt {
        let limit = max(0, maxBytes)
        guard check.key.source == .githubCheckRun || check.key.source == .githubActionsJob else {
            let note = check.summary.map { "Status: \($0)\n" } ?? ""
            let text = note + "Commit statuses have no log on GitHub; open the details page for the full output."
            var excerpt = LogExcerpt.make(rawLog: text, maxBytes: limit, fullLogURL: check.detailsURL)
            excerpt.totalBytes = nil
            return excerpt
        }
        let repoPath = try await checkRepositoryPath(check)
        let repo = try Self.repoAPIPath(repoPath)
        let jobID = check.logLocator["job_id"]
            ?? (check.key.source == .githubActionsJob ? check.key.remoteID : nil)
            ?? GitHubChecks.jobID(fromDetailsURL: check.detailsURL)
        if let jobID {
            do {
                let response = try await client.get("\(repo)/actions/jobs/\(Self.segment(jobID))/logs")
                return LogExcerpt.make(rawLog: response.bodyText, maxBytes: limit, fullLogURL: check.detailsURL)
            } catch let error as ProviderError {
                switch error {
                case .notFound, .forbidden, .invalidRequest:
                    break  // logs expired, deleted or not visible: fall back to the check run output
                default:
                    throw error
                }
            }
        }
        let checkRunID = check.logLocator["check_run_id"] ?? check.key.remoteID
        let run = try await client.getJSON(RESTCheckRun.self, "\(repo)/check-runs/\(Self.segment(checkRunID))")
        let parts = [run.output?.title, run.output?.summary, run.output?.text]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let text = parts.isEmpty ? (check.summary ?? "The check run has no output.") : parts.joined(separator: "\n\n")
        return LogExcerpt.make(rawLog: text, maxBytes: limit, fullLogURL: check.detailsURL ?? run.detailsURL ?? run.htmlURL)
    }

    private func checkRepositoryPath(_ check: CheckRun) async throws -> String {
        if let repo = check.logLocator["repo"], repo.contains("/") { return repo }
        return try await repositoryPath(check.key.changeRequest.repo)
    }

    // MARK: Diff

    /// `GET pulls/{n}` (SHAs), `GET pulls/{n}` with `Accept: application/vnd.github.diff` (bounded to `maxBytes`)
    /// and `GET pulls/{n}/files`. When GitHub refuses a diff that is too large, the diff is rebuilt from the
    /// per-file patches (files without a patch are listed but marked truncated).
    public func diff(for changeRequest: ChangeRequestKey, maxBytes: Int) async throws -> DiffPayload {
        let repo = try Self.repoAPIPath(try await repositoryPath(changeRequest.repo))
        let pullPath = "\(repo)/pulls/\(changeRequest.number)"
        let pull = try await client.getJSON(RESTPullRequest.self, pullPath)
        let files = try await getAllPages(RESTPullFile.self, pullPath + "/files")
        var text: String
        var incomplete = false
        do {
            text = try await client.get(pullPath, headers: ["Accept": "application/vnd.github.diff"]).bodyText
        } catch ProviderError.invalidRequest {
            (text, incomplete) = Self.synthesizeDiff(files)
        }
        let bounded = BoundedText.truncate(text, maxBytes: max(0, maxBytes))
        return DiffPayload(
            unifiedDiff: bounded.text,
            files: files.map(GitHubMapping.changedFile),
            truncated: bounded.isTruncated || incomplete,
            baseSHA: pull.base.sha,
            headSHA: pull.head.sha
        )
    }

    static func synthesizeDiff(_ files: [RESTPullFile]) -> (String, Bool) {
        var incomplete = false
        var lines: [String] = []
        for file in files {
            let old = file.previousFilename ?? file.filename
            lines.append("diff --git a/\(old) b/\(file.filename)")
            guard let patch = file.patch else {
                incomplete = true
                lines.append("# patch omitted by GitHub (binary or too large)")
                continue
            }
            lines.append(file.status == "added" ? "--- /dev/null" : "--- a/\(old)")
            lines.append(file.status == "removed" ? "+++ /dev/null" : "+++ b/\(file.filename)")
            lines.append(patch)
        }
        return (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"), incomplete)
    }

    // MARK: Local fetch and links

    /// Always the **base** repository: GitHub exposes every pull request head (forks included) as
    /// `refs/pull/<n>/head` there.
    public func fetchHeadSpec(for snapshot: ChangeRequestSnapshot) -> FetchHeadSpec? {
        let repository = snapshot.summary.repository
        let urls = repository.cloneURLs.isEmpty
            ? [GitHubMapping.webURL(instance: instance, path: repository.fullPath).absoluteString + ".git"]
            : repository.cloneURLs
        return FetchHeadSpec(
            remoteURLs: urls,
            refspec: "refs/pull/\(snapshot.summary.key.number)/head",
            expectedSHA: snapshot.summary.headSHA,
            isFork: snapshot.source?.isFork ?? false
        )
    }

    /// PR page, `#discussion_r<id>` (diff comments), `#issuecomment-<id>`, `#pullrequestreview-<id>`, check details.
    /// Needs the repository path learned from a listing/hydration (nil otherwise).
    public func deepLink(to target: DeepLinkTarget) -> URL? {
        let changeRequest = target.changeRequest
        guard let fullPath = links.repositoryPath(host: instance.host, remoteRepoID: changeRequest.repo.remoteRepoID) else {
            return nil
        }
        let repoURL = GitHubMapping.webURL(instance: instance, path: fullPath).absoluteString
        let prURL = "\(repoURL)/pull/\(changeRequest.number)"
        func anchor(_ thread: ThreadKey, commentID: String?) -> String {
            switch thread.kind {
            case .diffThread:
                guard let id = commentID ?? links.threadRoot(thread) else { return prURL + "/files" }
                return "\(prURL)#discussion_r\(id)"
            case .conversation:
                let id = commentID ?? String(thread.remoteID.dropFirst(ThreadKey.githubIssueCommentPrefix.count))
                return "\(prURL)#issuecomment-\(id)"
            case .reviewSummary:
                let id = String(thread.remoteID.dropFirst(ThreadKey.githubReviewSummaryPrefix.count))
                return "\(prURL)#pullrequestreview-\(id)"
            }
        }
        let text: String
        switch target {
        case .changeRequest:
            text = prURL
        case .thread(let thread):
            text = anchor(thread, commentID: nil)
        case .comment(let thread, let commentID):
            text = anchor(thread, commentID: Self.isNumeric(commentID) ? commentID : nil)
        case .check(let check):
            if let url = links.checkURL(check) { return url }
            switch check.source {
            case .githubCheckRun, .githubActionsJob:
                text = Self.isNumeric(check.remoteID) ? "\(repoURL)/runs/\(check.remoteID)" : "\(prURL)/checks"
            default:
                text = "\(prURL)/checks"
            }
        }
        return URL(string: text)
    }

    static func isNumeric(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
