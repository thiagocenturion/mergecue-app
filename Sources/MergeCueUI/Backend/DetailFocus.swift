import Foundation
import MergeCueCore

/// Where the detail panel should scroll when it opens (D51): a review thread (the conversation it belongs to) or the
/// reviewers card (approvals). The panel scrolls there, highlights it for about a second and clears the request.
public nonisolated struct DetailFocusRequest: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        case thread(ThreadKey)
        case reviewers
    }

    public var changeRequestID: String
    public var target: Target
    /// New for every request, so asking again for the same target scrolls again.
    public var token = UUID()
}

extension AppModel {
    /// Opens a change request on the Pull requests screen, scrolled to `thread` or to its approvals.
    public func showChangeRequest(_ key: ChangeRequestKey, thread: ThreadKey?) {
        detailFocusRequest = thread.map { DetailFocusRequest(changeRequestID: key.id, target: .thread($0)) }
        showChangeRequest(key)
    }

    /// Opens a change request scrolled to its reviewers and approvals (approval cards and notifications).
    public func showApprovals(_ key: ChangeRequestKey) {
        markApprovalsSeen(key)
        detailFocusRequest = DetailFocusRequest(changeRequestID: key.id, target: .reviewers)
        showChangeRequest(key)
    }

    /// Asks the Inbox detail to scroll to and highlight the item's conversation.
    func focusInboxItem(_ item: AttentionItem) {
        guard let thread = item.thread else { return }
        detailFocusRequest = DetailFocusRequest(changeRequestID: item.changeRequest.id, target: .thread(thread))
    }
}
