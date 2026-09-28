import Foundation
import MergeCueCore
import MergeCueNetworking

extension BitbucketCloudProvider {
    // MARK: Threads

    /// Fresh state of one thread (root comment + every reply), rebuilt from the pull request's comments.
    public func thread(_ key: ThreadKey) async throws -> ReviewThread {
        let (path, pr) = try await fetchPullRequest(key.changeRequest)
        let mapper = try await mapper()
        let user = try await me()
        let comments: [BBComment] = try await collect(
            "\(path.pullRequestPath(pr.id))/comments", query: pageSize(100), limit: limits.maxComments
        )
        let summary = try mapper.summary(pr, currentUserUUID: user.remoteID)
        let threads = BitbucketThreadBuilder(
            mapper: mapper, changeRequest: key.changeRequest, pullRequestURL: summary.webURL, headSHA: summary.headSHA
        ).build(comments)
        guard let thread = threads.first(where: { $0.key.remoteID == key.remoteID }) else {
            throw ProviderError.notFound("Bitbucket comment thread \(key.remoteID) no longer exists.")
        }
        return thread
    }

    func rootCommentID(_ key: ThreadKey) throws -> Int {
        guard let id = Int(key.remoteID) else {
            throw ProviderError.invalidRequest("Invalid Bitbucket comment id \(key.remoteID).")
        }
        return id
    }

    // MARK: Logs and diffs

    /// Pipelines step log (`…/pipelines/{uuid}/steps/{step uuid}/log`, tail fetched with a `Range` request; the
    /// endpoint may redirect to log storage on another host, where the transport drops credentials). Commit
    /// statuses from other CI systems have no log API: the excerpt then carries only the details URL.
    public func failureLog(for check: CheckRun, maxBytes: Int) async throws -> LogExcerpt {
        typealias Locator = BitbucketChecksMapper.Locator
        guard check.key.source == .bitbucketPipelineStep,
              let pipelineUUID = check.logLocator[Locator.pipelineUUID],
              let stepUUID = check.logLocator[Locator.stepUUID]
        else {
            return LogExcerpt(
                text: "Bitbucket exposes no log for \"\(check.name)\"; open the details link for its output.",
                truncated: false,
                fullLogURL: check.detailsURL,
                totalBytes: nil
            )
        }
        let path: BitbucketRepoPath
        if let fullName = check.logLocator[Locator.repository], let parsed = BitbucketRepoPath(fullName: fullName) {
            path = parsed
        } else {
            path = try await repoPath(for: check.key.changeRequest.repo)
        }
        let fetchBytes = max(limits.maxLogFetchBytes, maxBytes)
        let response = try await client.get(
            "\(path.apiPath)/pipelines/\(BitbucketIdentifiers.segment(pipelineUUID))/steps/\(BitbucketIdentifiers.segment(stepUUID))/log",
            headers: ["Accept": "text/plain, application/octet-stream, */*", "Range": "bytes=-\(fetchBytes)"]
        )
        var excerpt = LogExcerpt.make(rawLog: response.bodyText, maxBytes: maxBytes, fullLogURL: check.detailsURL)
        if response.status == 206 {
            if let total = Self.totalLength(contentRange: response.header("content-range")) {
                excerpt.totalBytes = total
                if total > response.body.count { excerpt.truncated = true }
            } else {
                excerpt.totalBytes = nil
            }
        }
        return excerpt
    }

    /// Total length from `Content-Range: bytes 100-199/2048`.
    static func totalLength(contentRange: String?) -> Int? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// Unified diff of the pull request (`…/pullrequests/{id}/diff`, which redirects to the repository diff on the
    /// same host), bounded to `maxBytes`, with the diffstat file list.
    public func diff(for changeRequest: ChangeRequestKey, maxBytes: Int) async throws -> DiffPayload {
        let (path, pr) = try await fetchPullRequest(changeRequest)
        let mapper = try await mapper()
        let prPath = path.pullRequestPath(pr.id)
        let response = try await client.get("\(prPath)/diff", headers: ["Accept": "text/plain"])
        let bounded = BoundedText.truncate(response.bodyText, maxBytes: max(0, maxBytes))
        let stats: [BBDiffStat] = try await collect("\(prPath)/diffstat", query: pageSize(500), limit: limits.maxFiles)
        return DiffPayload(
            unifiedDiff: bounded.text,
            files: stats.compactMap(mapper.changedFile),
            truncated: bounded.isTruncated,
            baseSHA: pr.destination?.commit?.hash,
            headSHA: pr.source?.commit?.hash
        )
    }

    // MARK: Writes

    /// `POST …/comments` with `{"content": {"raw": body}, "parent": {"id": <root>}}`.
    public func createReply(to thread: ThreadKey, body: String) async throws -> ReviewComment {
        let path = try await repoPath(for: thread.changeRequest.repo)
        let prID = try pullRequestID(thread.changeRequest)
        let payload = BBCommentBody(content: .init(raw: body), parent: .init(id: try rootCommentID(thread)))
        let comment = try await client.sendJSON(
            BBComment.self, "POST", "\(path.pullRequestPath(prID))/comments", json: payload
        )
        let mapper = try await mapper()
        let prURL = pullRequestWebURL(thread.changeRequest)
        return ReviewComment(
            id: String(comment.id),
            author: mapper.person(comment.user),
            body: comment.content?.raw ?? body,
            createdAt: comment.createdOn,
            updatedAt: comment.updatedOn,
            webURL: comment.links?.html?.href.flatMap(URL.init(string:)) ?? prURL?.withFragment("comment-\(comment.id)"),
            kind: CommentKind.classify(body: comment.content?.raw ?? body),
            inReplyToID: comment.parent?.id.map(String.init) ?? thread.remoteID
        )
    }

    /// `POST …/comments/{root}/resolve` to resolve, `DELETE` to reopen. Bitbucket answers 409 when the thread is
    /// already in the requested state (→ `ProviderError.conflict`).
    public func resolveThread(_ thread: ThreadKey, resolved: Bool) async throws {
        let path = try await repoPath(for: thread.changeRequest.repo)
        let prID = try pullRequestID(thread.changeRequest)
        let resolvePath = "\(path.pullRequestPath(prID))/comments/\(try rootCommentID(thread))/resolve"
        _ = try await client.send(resolved ? "POST" : "DELETE", resolvePath)
    }

    /// `POST …/request-changes` (Bitbucket's endpoint takes no message). A non-empty `body` is then posted as a
    /// general pull request comment so the reviewer's reasoning is visible.
    public func requestChanges(on changeRequest: ChangeRequestKey, body: String) async throws {
        let path = try await repoPath(for: changeRequest.repo)
        let prPath = path.pullRequestPath(try pullRequestID(changeRequest))
        _ = try await client.send("POST", "\(prPath)/request-changes")
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try await client.send("POST", "\(prPath)/comments", json: BBCommentBody(content: .init(raw: body), parent: nil))
    }

    /// Merges with the repository's default strategy (`POST …/merge`).
    ///
    /// Bitbucket's merge endpoint accepts no expected head commit, so the head is re-read immediately before the
    /// merge and a mismatch (or a non-open / draft pull request) throws `conflict` without merging. **Race:** a push
    /// that lands between that check and the merge request is merged anyway; the window is one round trip.
    public func merge(_ changeRequest: ChangeRequestKey, expectedHeadSHA: String) async throws {
        let (path, pr) = try await fetchPullRequest(changeRequest)
        let head = try await mapper().headInfo(pr)
        guard head.state == .open else {
            throw ProviderError.conflict("The pull request is \(head.state.rawValue), not open.")
        }
        guard !head.isDraft else {
            throw ProviderError.conflict("Draft pull requests cannot be merged.")
        }
        guard BitbucketIdentifiers.sameCommit(head.headSHA, expectedHeadSHA) else {
            throw ProviderError.conflict("The pull request head changed since it was reviewed.")
        }
        _ = try await client.send("POST", "\(path.pullRequestPath(pr.id))/merge")
    }
}
