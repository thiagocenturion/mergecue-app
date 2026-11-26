import Foundation
import MergeCueCore

extension Presentation {
    /// The person an attention item is about, the one its headline names (D58): the thread's root author for
    /// review comments, questions, suggestions and requested changes, the latest commenter for replies and the
    /// PR/MR author for review requests and updates. nil for CI, merge state and other items nobody "did".
    public static func actor(_ item: AttentionItem, snapshot: ChangeRequestSnapshot?) -> Person? {
        let thread = item.thread.flatMap { snapshot?.thread($0) }
        switch item.reason {
        case .changesRequested, .reviewComment, .reviewerQuestion, .codeSuggestion:
            return thread?.rootComment?.author
        case .reply:
            return thread?.latestComment?.author
        case .reviewRequested, .updatedSinceReview:
            return snapshot?.summary.author
        case .ciFailed, .readyToMerge, .mergeConflict, .reapprovalNeeded:
            return nil
        }
    }

    /// Who asked for a task's change: the root author of its thread (CI tasks have nobody).
    public static func requester(_ record: TaskRecord, snapshot: ChangeRequestSnapshot?) -> Person? {
        record.task.origin.thread.flatMap { snapshot?.thread($0) }?.rootComment?.author
    }
}

extension AppModel {
    /// The person a popover row is about (its avatar), nil for rows about checks or merge state.
    func person(for item: PopoverItem) -> Person? {
        let snapshot = snapshot(item.changeRequest)
        switch item.source {
        case .attention(let id):
            return attentionItem(id).flatMap { Presentation.actor($0, snapshot: snapshot) }
        case .task(let id):
            return task(id).flatMap { Presentation.requester($0, snapshot: snapshot) }
        }
    }
}
