import Foundation
import MergeCueCore
import MergeCueNetworking

/// Remote writes. They are never retried automatically (APIClient) and are only reached after the engine's
/// approval gate; each re-reads the minimum fresh state it needs.
extension GitHubProvider {
    /// - Diff thread: re-reads the thread node (root comment id, PR number, repository), then
    ///   `POST /repos/{o}/{r}/pulls/{n}/comments/{root_comment_id}/replies`.
    /// - Issue comment or review body: GitHub has no threaded replies there, so the reply is a new conversation
    ///   comment, `POST /repos/{o}/{r}/issues/{n}/comments`.
    public func createReply(to thread: ThreadKey, body: String) async throws -> ReviewComment {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidRequest("A reply cannot be empty.")
        }
        let changeRequest = thread.changeRequest
        switch thread.kind {
        case .diffThread:
            let node = try await graphQLThread(thread)
            guard let root = (node.comments?.items ?? []).min(by: { $0.createdAt < $1.createdAt }),
                  let rootID = root.fullDatabaseId?.value
            else {
                throw ProviderError.notFound("Review thread \(thread.remoteID) has no comments to reply to.")
            }
            let fullPath: String = if let known = node.repository?.nameWithOwner { known } else { try await repositoryPath(changeRequest.repo) }
            let number = node.pullRequest?.number ?? changeRequest.number
            let path = "\(try Self.repoAPIPath(fullPath))/pulls/\(number)/comments/\(Self.segment(rootID))/replies"
            let created = try await client.sendJSON(RESTReviewComment.self, "POST", path, json: RESTBodyPayload(body: body))
            links.registerThreadRoot(thread, commentID: rootID)
            return GitHubMapping.replyComment(created)
        case .conversation, .reviewSummary:
            let repo = try Self.repoAPIPath(try await repositoryPath(changeRequest.repo))
            let created = try await client.sendJSON(
                RESTIssueComment.self, "POST", "\(repo)/issues/\(changeRequest.number)/comments", json: RESTBodyPayload(body: body)
            )
            return GitHubMapping.replyComment(created)
        }
    }

    /// GraphQL `resolveReviewThread` / `unresolveReviewThread`. Only diff threads can be resolved on GitHub.
    public func resolveThread(_ thread: ThreadKey, resolved: Bool) async throws {
        guard thread.kind == .diffThread else {
            throw ProviderError.unsupported(
                .resolveThread, reason: "GitHub can only resolve review threads, not conversation comments or review bodies."
            )
        }
        let data = try await graphQL.execute(
            resolved ? .resolveThread : .unresolveThread,
            variables: ["id": .string(thread.remoteID)],
            as: GQLResolveData.self
        )
        let payload = resolved ? data.resolveReviewThread : data.unresolveReviewThread
        guard let state = payload?.thread else {
            throw ProviderError.notFound("Review thread \(thread.remoteID) was not found.")
        }
        guard state.isResolved == resolved else {
            throw ProviderError.conflict("GitHub reports the thread as \(state.isResolved ? "resolved" : "unresolved").")
        }
    }

    /// `POST /repos/{o}/{r}/pulls/{n}/reviews` with `event: REQUEST_CHANGES`.
    public func requestChanges(on changeRequest: ChangeRequestKey, body: String) async throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidRequest("A change request needs a comment.")
        }
        let repo = try Self.repoAPIPath(try await repositoryPath(changeRequest.repo))
        _ = try await client.send(
            "POST", "\(repo)/pulls/\(changeRequest.number)/reviews",
            json: RESTReviewPayload(body: body, event: "REQUEST_CHANGES")
        )
    }

    /// `PUT /repos/{o}/{r}/pulls/{n}/merge` with `sha` = `expectedHeadSHA`; GitHub answers 409 when the head moved
    /// (→ `ProviderError.conflict`).
    public func merge(_ changeRequest: ChangeRequestKey, expectedHeadSHA: String) async throws {
        guard !expectedHeadSHA.isEmpty else {
            throw ProviderError.invalidRequest("Merging needs the expected head SHA.")
        }
        let repo = try Self.repoAPIPath(try await repositoryPath(changeRequest.repo))
        _ = try await client.send(
            "PUT", "\(repo)/pulls/\(changeRequest.number)/merge", json: RESTMergePayload(sha: expectedHeadSHA)
        )
    }
}
