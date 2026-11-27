import Foundation
import MergeCueCore

/// "Review with AI" on someone else's pull/merge request (D60): which one and what to look for.
public nonisolated struct ReviewHandoffRequest: Sendable, Hashable {
    public var changeRequestID: String
    public var focus: ReviewFocus

    public init(changeRequestID: String, focus: ReviewFocus) {
        self.changeRequestID = changeRequestID
        self.focus = focus
    }
}

extension AppModel {
    /// Opens "Review with AI" for `key` on the Reviews screen (no task is created; the agent reports in its own
    /// session).
    public func startReview(_ key: ChangeRequestKey, focus: ReviewFocus = .full) {
        screen = .reviews
        selectedChangeRequestID = key.id
        reviewHandoff = ReviewHandoffRequest(changeRequestID: key.id, focus: focus)
        openMainWindow()
    }

    /// "Review with AI" fits open pull/merge requests someone else authored.
    public func showsReviewWithAI(_ key: ChangeRequestKey) -> Bool {
        guard let snapshot = snapshot(key), snapshot.summary.state == .open else { return false }
        return !ViewerReview.isAuthored(snapshot, userID: key.account.remoteUserID)
    }

    /// The mapped local checkout of a change request's repository, if any (the review prompt names it).
    func checkoutPath(for key: ChangeRequestKey) -> String? {
        state.mappings.first { $0.repo == key.repo }?.checkoutPath
    }

    /// The prompt a task's handoff copies or opens in `mode`.
    func taskPrompt(_ record: TaskRecord, mode: AgentPromptMode) -> String {
        switch mode {
        case .mcp: HandoffText.command(for: record.id, handoffCode: record.task.handoffCode)
        case .standalone: AgentPrompts.investigate(record, snapshot: snapshot(record.task.origin.changeRequest))
        }
    }

    /// The prompt "Review with AI" copies or opens in `mode`.
    func reviewPrompt(_ snapshot: ChangeRequestSnapshot, focus: ReviewFocus, mode: AgentPromptMode) -> String {
        switch mode {
        case .mcp: AgentPrompts.reviewWithMCP(snapshot, focus: focus)
        case .standalone: AgentPrompts.review(snapshot, focus: focus, checkoutPath: checkoutPath(for: snapshot.key))
        }
    }

    /// MergeCue MCP can read a change request without a task only with whole-inbox read access.
    var mcpCanReadAnyChangeRequest: Bool { state.agentReadAccess == .allInbox }
}
