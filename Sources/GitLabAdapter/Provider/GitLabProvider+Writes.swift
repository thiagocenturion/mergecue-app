import Foundation
import MergeCueCore
import MergeCueNetworking

/// Remote writes. Callers (Engine) gate them behind `Account.writesEnabled` + explicit approval and fetch fresh
/// state (`headInfo`, `thread`) first. GitLab needs a token with the `api` scope for all of them. Writes are never
/// retried automatically.
extension GitLabProvider {
    /// `POST /projects/:id/merge_requests/:iid/discussions/:discussion_id/notes` (`{"body": …}`). Also turns an
    /// individual comment into a thread.
    public func createReply(to thread: ThreadKey, body: String) async throws -> ReviewComment {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidRequest("The reply is empty.")
        }
        let note = try await api.send(GLNote.self, "POST", GitLabAPI.discussion(thread) + "/notes", json: GLNoteBody(body: body))
        let rootID = GitLabLinkCache.rootNoteID(thread)
        return GitLabThreadMapping.comment(
            note,
            rootID: rootID == String(note.id) ? nil : rootID,
            webURL: mergeRequestWebURL(thread.changeRequest)
        )
    }

    /// `PUT /projects/:id/merge_requests/:iid/discussions/:discussion_id` with `{"resolved": true|false}`.
    public func resolveThread(_ thread: ThreadKey, resolved: Bool) async throws {
        _ = try await api.send("PUT", GitLabAPI.discussion(thread), json: GLResolveBody(resolved: resolved))
    }

    /// GitLab has no "submit review" object in REST; the documented path is
    /// `POST …/draft_notes/bulk_publish` with `note` + `reviewer_state: requested_changes`, which publishes a
    /// summary comment and sets the caller's reviewer state. Because bulk publish would also post every pending
    /// draft comment of the user, it is refused while drafts exist. The reviewer state is verified afterwards
    /// (the endpoint answers 204 even when the state could not be set).
    public func requestChanges(on changeRequest: ChangeRequestKey, body: String) async throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.invalidRequest("The review summary is empty.")
        }
        let mrPath = GitLabAPI.mergeRequest(changeRequest)
        let me = try await cachedUser()
        let reviewers = try await api.get([GLReviewerEntry].self, mrPath + "/reviewers")
        guard reviewers.contains(where: { $0.user.id == me.id }) else {
            throw ProviderError.invalidRequest(
                "GitLab records “changes requested” only for reviewers of the merge request. Add yourself as a reviewer in GitLab first."
            )
        }
        let drafts = try await api.getAll(GLDraftNote.self, mrPath + "/draft_notes", maxPages: 1)
        guard drafts.items.isEmpty else {
            throw ProviderError.conflict(
                "You have \(drafts.items.count) unpublished draft comment(s) on this merge request; publishing a review would post them too. Publish or discard them in GitLab first."
            )
        }
        do {
            _ = try await api.send(
                "POST", mrPath + "/draft_notes/bulk_publish",
                json: GLBulkPublishBody(note: body, reviewerState: "requested_changes")
            )
        } catch ProviderError.notFound {
            throw ProviderError.unsupported(
                .requestChanges,
                reason: "This GitLab instance has no draft_notes/bulk_publish endpoint. Request changes in GitLab."
            )
        }
        let after = try await api.get([GLReviewerEntry].self, mrPath + "/reviewers")
        guard after.first(where: { $0.user.id == me.id })?.state == "requested_changes" else {
            throw ProviderError.unsupported(
                .requestChanges,
                reason: "The summary comment was posted, but GitLab did not record the “changes requested” state (not available on this instance or tier). Request changes in GitLab."
            )
        }
    }

    /// `PUT /projects/:id/merge_requests/:iid/merge` with `{"sha": expectedHeadSHA}`. GitLab answers `409` when
    /// the head moved (→ `.conflict`), `405`/`422` when the MR cannot be merged (→ `.conflict`), and `401` when
    /// the user may not merge (→ `.forbidden`, not a credential failure).
    public func merge(_ changeRequest: ChangeRequestKey, expectedHeadSHA: String) async throws {
        let sha = expectedHeadSHA.trimmingCharacters(in: .whitespaces)
        guard !sha.isEmpty else {
            throw ProviderError.invalidRequest("A head SHA is required to merge.")
        }
        do {
            _ = try await api.send("PUT", GitLabAPI.mergeRequest(changeRequest) + "/merge", json: GLMergeBody(sha: sha))
        } catch let error as ProviderError {
            switch error {
            case .unauthorized:
                throw ProviderError.forbidden(missingScope: nil, message: "GitLab refused the merge: you are not allowed to merge this merge request.")
            case .invalidRequest(let message):
                throw ProviderError.conflict("GitLab could not merge the merge request. \(message)")
            default:
                throw error
            }
        }
    }
}
