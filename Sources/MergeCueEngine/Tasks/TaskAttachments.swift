import Foundation
import MergeCueCore
import MergeCueStore

// "Add to Task", "Remove from Task" and "Merge into…" (DECISIONS D38): one task can cover several inbox items of
// the same change request. The origin item stays the task's main item; attached items add context only.

extension MergeCueEngine {
    /// Adds inbox items to an active task on the same change request. Each item's comment(s) / CI excerpt is
    /// captured now (bounded, redacted) and the item is linked to the task.
    ///
    /// - An item attached to another active task moves here. An item that started another active task is refused:
    ///   merge that task instead.
    /// - Items already covered by this task are skipped. Refused while an approved action runs, or for finished tasks.
    /// - The version bump makes a working agent's next write fail with `version_conflict`, so it re-reads `get_task`
    ///   and sees the new items.
    @discardableResult
    public func attachToTask(_ taskID: TaskID, attentionIDs: [String]) async throws(EngineError) -> MCTask {
        try await uiCall {
            var task = try await requireTask(taskID)
            try requireAcceptsAttachments(task)
            var added: [TaskAttachment] = []
            for attentionID in attentionIDs where !task.coveredAttentionIDs.contains(attentionID) && !added.contains(where: { $0.id == attentionID }) {
                guard let item = try await database.attentionItem(id: attentionID) else {
                    throw EngineError.notFound("Attention item \(attentionID)")
                }
                guard item.changeRequest == task.origin.changeRequest else {
                    throw EngineError.invalidInput("Only items from the same \(task.origin.providerKind.changeRequestNoun) can be added to this task.")
                }
                if let other = try await activeTask(forAttention: item), other.id != task.id {
                    guard other.origin.attentionItemID != item.id else {
                        throw EngineError.invalidTransition("This item started task \(other.id.rawValue). Merge that task into this one instead.")
                    }
                    try await removeAttachment(item.id, from: other, message: "Moved to task \(task.id.rawValue).")
                }
                added.append(try await makeAttachment(for: item))
            }
            guard !added.isEmpty else { return task }
            guard task.attachments.count + added.count <= TaskMerging.maxAttachments else {
                throw EngineError.invalidInput("A task can cover at most \(TaskMerging.maxAttachments + 1) items.")
            }
            task = try await persistUpdate(task) { $0.attachments += added }
            for attachment in added {
                try await database.linkAttention(id: attachment.attentionItemID, taskID: task.id)
            }
            await recordActivity(
                task.id, actor: .user, kind: .note,
                message: Self.attachMessage(added, task: task),
                data: ["attached_items": added.map(\.attentionItemID).joined(separator: ",")]
            )
            emit(.attention)
            return task
        }
    }

    /// Removes an attached item from a task; the item returns to the inbox without a task. The task's origin item
    /// cannot be removed.
    @discardableResult
    public func detachFromTask(_ taskID: TaskID, attentionID: String) async throws(EngineError) -> MCTask {
        try await uiCall {
            let task = try await requireTask(taskID)
            guard task.origin.attentionItemID != attentionID else {
                throw EngineError.invalidInput("This item started the task and cannot be removed from it.")
            }
            guard task.attachment(for: attentionID) != nil else { return task }
            guard task.state != .approvedAction else {
                throw EngineError.invalidTransition("An approved action is running on this task. Try again when it finishes.")
            }
            let updated = try await removeAttachment(attentionID, from: task, message: "Removed from this task by you.")
            emit(.attention)
            return updated
        }
    }

    /// Merges `sourceID` into `targetID` (same change request): the source's main item and attached items move to
    /// the target with the context captured for the source, and the source is dismissed ("Merged into …").
    /// Only sources with no agent work in flight and no result waiting can be merged (`TaskMerging.canMergeAway`).
    @discardableResult
    public func mergeTask(_ sourceID: TaskID, into targetID: TaskID) async throws(EngineError) -> MCTask {
        try await uiCall {
            guard sourceID != targetID else { throw EngineError.invalidInput("A task cannot be merged into itself.") }
            let source = try await requireTask(sourceID)
            var target = try await requireTask(targetID)
            guard source.origin.changeRequest == target.origin.changeRequest else {
                throw EngineError.invalidInput("Only tasks on the same \(target.origin.providerKind.changeRequestNoun) can be merged.")
            }
            if let refusal = TaskMerging.mergeAwayRefusal(source.state) { throw EngineError.invalidTransition(refusal) }
            try requireAcceptsAttachments(target)

            var moved: [TaskAttachment] = []
            if let originID = source.origin.attentionItemID, !target.coveredAttentionIDs.contains(originID) {
                let reason = try await database.attentionItem(id: originID)?.reason
                moved.append(TaskAttachment(
                    attentionItemID: originID, reason: reason, thread: source.origin.thread, check: source.origin.check,
                    attachedAt: now, headSHA: source.trigger.headSHA, quoted: source.trigger.quoted,
                    anchor: source.trigger.anchor, mergedFromTaskID: source.id
                ))
            }
            for var attachment in source.attachments where !target.coveredAttentionIDs.contains(attachment.attentionItemID) {
                attachment.mergedFromTaskID = attachment.mergedFromTaskID ?? source.id
                moved.append(attachment)
            }
            guard target.attachments.count + moved.count <= TaskMerging.maxAttachments else {
                throw EngineError.invalidInput("A task can cover at most \(TaskMerging.maxAttachments + 1) items.")
            }
            target = try await persistUpdate(target) { $0.attachments += moved }
            try await transition(source, on: .dismiss, by: .user, message: "Merged into task \(target.id.rawValue) by you.",
                                 data: ["merged_into": target.id.rawValue]) { $0.lease = nil }
            forgetPreviews(for: source.id)
            for attachment in moved {
                try await database.linkAttention(id: attachment.attentionItemID, taskID: target.id)
            }
            let count = moved.count
            await recordActivity(
                target.id, actor: .user, kind: .note,
                message: "Task \(source.id.rawValue) merged into this one by you: \(count) item\(count == 1 ? "" : "s") added. "
                    + "This task now covers \(target.coveredAttentionIDs.count) items.",
                data: ["merged_from": source.id.rawValue]
            )
            emit(.attention)
            return target
        }
    }

    // MARK: Helpers

    private func requireAcceptsAttachments(_ task: MCTask) throws {
        guard TaskMerging.acceptsAttachments(task.state) else {
            throw EngineError.invalidTransition(
                task.isTerminal
                    ? "Task \(task.id.rawValue) is \(task.state.displayName.lowercased()). Reopen it first."
                    : "An approved action is running on task \(task.id.rawValue). Try again when it finishes."
            )
        }
    }

    /// Captures an item's context the same way task creation does.
    private func makeAttachment(for item: AttentionItem) async throws -> TaskAttachment {
        guard let snapshot = try await database.snapshot(item.changeRequest) else {
            throw EngineError.notFound("Change request \(item.changeRequestRef.string)")
        }
        let log = await captureLog(check: item.check, snapshot: snapshot)
        let built = TriggerSnapshotBuilder.build(
            snapshot: snapshot, thread: item.thread, check: item.check, reason: item.reason, eventType: nil, log: log, now: now
        )
        return TaskAttachment(
            attentionItemID: item.id, reason: item.reason, thread: item.thread, check: item.check, attachedAt: now,
            headSHA: built.headSHA, quoted: built.quoted, anchor: built.anchor
        )
    }

    @discardableResult
    private func removeAttachment(_ attentionID: String, from task: MCTask, message: String) async throws -> MCTask {
        let updated = try await persistUpdate(task) { $0.attachments.removeAll { $0.attentionItemID == attentionID } }
        if let item = try await database.attentionItem(id: attentionID), item.linkedTaskID == task.id {
            try await database.linkAttention(id: attentionID, taskID: nil)
        }
        await recordActivity(task.id, actor: .user, kind: .note, message: message, data: ["detached_item": attentionID])
        return updated
    }

    /// "Added 1 item to this task (CI failure). It now covers 2 items." Only MergeCue-controlled values.
    static func attachMessage(_ added: [TaskAttachment], task: MCTask) -> String {
        let reasons = added.compactMap { $0.reason?.displayName }
        let unique = reasons.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let count = added.count
        var message = "Added \(count) item\(count == 1 ? "" : "s") to this task"
        if !unique.isEmpty { message += " (\(unique.joined(separator: ", ")))" }
        message += ". It now covers \(task.coveredAttentionIDs.count) items."
        if task.state == .readyForReview {
            message += " The result was produced before these items were added."
        }
        return message
    }
}
