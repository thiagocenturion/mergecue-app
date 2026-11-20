import Foundation
import MergeCueCore

// Preview versions of "Add to Task", "Remove from Task" and "Merge into…" with the engine's rules (D38).
extension PreviewBackend {
    func attach(_ attentionIDs: [String], to taskID: TaskID) throws -> AppCommandResult {
        guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { throw AppBackendError.notFound("Task \(taskID)") }
        let task = state.tasks[index].task
        guard TaskMerging.acceptsAttachments(task.state) else {
            throw AppBackendError.invalidTransition("Task \(taskID) can't take more items right now.")
        }
        var added: [TaskAttachment] = []
        for attentionID in attentionIDs where !task.coveredAttentionIDs.contains(attentionID) && !added.contains(where: { $0.id == attentionID }) {
            guard let item = state.attention.first(where: { $0.id == attentionID }) else { throw AppBackendError.notFound("The item") }
            guard item.changeRequest == task.origin.changeRequest else {
                throw AppBackendError.invalidTransition("Only items from the same \(task.origin.providerKind.changeRequestNoun) can be added.")
            }
            if let other = state.tasks.first(where: { !$0.task.isTerminal && $0.id != taskID && $0.task.coveredAttentionIDs.contains(attentionID) }) {
                guard other.task.origin.attentionItemID != attentionID else {
                    throw AppBackendError.invalidTransition("This item started task \(other.id). Merge that task instead.")
                }
                removeAttachment(attentionID, from: other.id, message: "Moved to task \(taskID)")
            }
            added.append(attachment(for: item))
        }
        guard !added.isEmpty else { return AppCommandResult(message: "Already part of task \(taskID)") }
        state.tasks[index].task.attachments += added
        state.tasks[index].task.version += 1
        state.tasks[index].task.updatedAt = now
        for attachment in added { link(attachment.attentionItemID, to: taskID) }
        let count = state.tasks[index].task.coveredAttentionIDs.count
        appendActivity(taskID, .user, "mona-dev", .note, "Added \(added.count) item\(added.count == 1 ? "" : "s") to this task. It now covers \(count) items.")
        return AppCommandResult(message: "Added to task \(taskID). It now covers \(count) items.")
    }

    func detach(_ attentionID: String, from taskID: TaskID) throws -> AppCommandResult {
        guard let task = state.tasks.first(where: { $0.id == taskID })?.task else { throw AppBackendError.notFound("Task \(taskID)") }
        guard task.origin.attentionItemID != attentionID else {
            throw AppBackendError.invalidTransition("This item started the task and can't be removed from it.")
        }
        removeAttachment(attentionID, from: taskID, message: "Removed from this task by you")
        return AppCommandResult(message: "Removed from task \(taskID)")
    }

    func merge(_ sourceID: TaskID, into targetID: TaskID) throws -> AppCommandResult {
        guard let source = state.tasks.first(where: { $0.id == sourceID })?.task,
              let targetIndex = state.tasks.firstIndex(where: { $0.id == targetID })
        else { throw AppBackendError.notFound("The task") }
        let target = state.tasks[targetIndex].task
        guard sourceID != targetID, source.origin.changeRequest == target.origin.changeRequest else {
            throw AppBackendError.invalidTransition("Only tasks on the same \(target.origin.providerKind.changeRequestNoun) can be merged.")
        }
        if let refusal = TaskMerging.mergeAwayRefusal(source.state) { throw AppBackendError.invalidTransition(refusal) }
        guard TaskMerging.acceptsAttachments(target.state) else {
            throw AppBackendError.invalidTransition("Task \(targetID) can't take more items right now.")
        }
        var moved: [TaskAttachment] = []
        if let originID = source.origin.attentionItemID, !target.coveredAttentionIDs.contains(originID) {
            moved.append(TaskAttachment(
                attentionItemID: originID, reason: state.attention.first { $0.id == originID }?.reason, thread: source.origin.thread,
                check: source.origin.check, attachedAt: now, headSHA: source.trigger.headSHA, quoted: source.trigger.quoted,
                anchor: source.trigger.anchor, mergedFromTaskID: sourceID
            ))
        }
        for var attachment in source.attachments where !target.coveredAttentionIDs.contains(attachment.attentionItemID) {
            attachment.mergedFromTaskID = attachment.mergedFromTaskID ?? sourceID
            moved.append(attachment)
        }
        state.tasks[targetIndex].task.attachments += moved
        state.tasks[targetIndex].task.version += 1
        state.tasks[targetIndex].task.updatedAt = now
        try transition(sourceID, .dismiss, .dismissed, "Merged into task \(targetID) by you")
        for attachment in moved { link(attachment.attentionItemID, to: targetID) }
        appendActivity(targetID, .user, "mona-dev", .note,
                       "Task \(sourceID) merged into this one: \(moved.count) item\(moved.count == 1 ? "" : "s") added")
        return AppCommandResult(message: "Task \(sourceID) merged into \(targetID)")
    }

    private func attachment(for item: AttentionItem) -> TaskAttachment {
        let snapshot = state.changeRequests.first { $0.key == item.changeRequest }
        let thread = item.thread.flatMap { snapshot?.thread($0) }
        var quoted: [UntrustedText] = (thread?.comments ?? []).filter { $0.kind != .system }.suffix(10).map {
            .bounded(source: UntrustedText.Source.reviewComment, author: $0.author.username, createdAt: $0.createdAt, text: $0.body, maxBytes: 4_096)
        }
        if let check = item.check.flatMap({ snapshot?.check($0) }) {
            let text = logs[check.key.id]?.text ?? check.summary ?? ""
            if !text.isEmpty { quoted.append(.bounded(source: UntrustedText.Source.ciLog, createdAt: check.completedAt, text: text, maxBytes: 4_096)) }
        }
        return TaskAttachment(attentionItemID: item.id, reason: item.reason, thread: item.thread, check: item.check, attachedAt: now,
                              headSHA: snapshot?.summary.headSHA, quoted: quoted, anchor: thread?.anchor)
    }

    private func removeAttachment(_ attentionID: String, from taskID: TaskID, message: String) {
        guard let index = state.tasks.firstIndex(where: { $0.id == taskID }),
              state.tasks[index].task.attachment(for: attentionID) != nil else { return }
        state.tasks[index].task.attachments.removeAll { $0.attentionItemID == attentionID }
        state.tasks[index].task.version += 1
        state.tasks[index].task.updatedAt = now
        if let item = state.attention.firstIndex(where: { $0.id == attentionID }), state.attention[item].linkedTaskID == taskID {
            state.attention[item].linkedTaskID = nil
        }
        appendActivity(taskID, .user, "mona-dev", .note, message)
    }

    private func link(_ attentionID: String, to taskID: TaskID) {
        guard let index = state.attention.firstIndex(where: { $0.id == attentionID }) else { return }
        state.attention[index].linkedTaskID = taskID
        state.attention[index].isUnread = false
    }
}
