import Foundation
import MergeCueCore

/// "Add to Task", "Move to Task", "Remove from Task" and "Merge into…" (D38): one task can cover several inbox
/// items of the same change request. These helpers decide what the menus and banners offer.
extension AppModel {
    /// Active tasks on the item's change request that can take it (newest activity first), excluding the task
    /// that already covers it.
    public func attachableTasks(for item: AttentionItem) -> [TaskRecord] {
        let current = activeConversationTask(for: item)?.id
        return state.tasks
            .filter { $0.task.origin.changeRequest == item.changeRequest && $0.id != current && TaskMerging.acceptsAttachments($0.state) }
            .sorted { $0.task.updatedAt > $1.task.updatedAt }
    }

    /// The task the item's conversation is attached to (not the one it started), if any.
    public func attachingTask(for item: AttentionItem) -> TaskRecord? {
        guard let task = activeConversationTask(for: item) else { return nil }
        let ids = Set(conversationItems(for: item).map(\.id))
        return task.task.attachments.contains { ids.contains($0.attentionItemID) } && !ids.contains(task.task.origin.attentionItemID ?? "")
            ? task : nil
    }

    /// Adds (or moves) every item of the item's conversation to `task`.
    public func addConversation(_ item: AttentionItem, to task: TaskID) async {
        let ids = conversationItems(for: item).map(\.id)
        await send(.attachToTask(task, attentionIDs: ids))
    }

    /// Removes every attached item of the item's conversation from its task.
    public func removeConversationFromTask(_ item: AttentionItem) async {
        guard let task = attachingTask(for: item) else { return }
        for member in conversationItems(for: item) where task.task.attachment(for: member.id) != nil {
            await send(.detachFromTask(task.id, attentionID: member.id))
        }
    }

    /// Other active tasks on the same change request that `record` can be merged into.
    public func mergeTargets(for record: TaskRecord) -> [TaskRecord] {
        state.tasks
            .filter { $0.id != record.id && $0.task.origin.changeRequest == record.task.origin.changeRequest && TaskMerging.acceptsAttachments($0.state) }
            .sorted { $0.task.updatedAt > $1.task.updatedAt }
    }

    /// Open items on the task's change request that no active task covers yet (one per conversation).
    public func addableItems(for record: TaskRecord) -> [AttentionItem] {
        let candidates = state.attention.filter { item in
            item.changeRequest == record.task.origin.changeRequest && item.disposition != .dismissed
                && item.isActionable(now: now) && activeTask(for: item) == nil
        }
        let key = record.task.origin.changeRequest
        let snapshots = snapshot(key).map { [key: $0] } ?? [:]
        let groups = ConversationGrouping.group(candidates, snapshots: snapshots, order: { $0.updatedAt > $1.updatedAt })
        return groups.compactMap(\.first)
    }

    /// The items a task covers, origin first. Items no longer in the inbox are skipped.
    public func coveredItems(for record: TaskRecord) -> [AttentionItem] {
        record.task.coveredAttentionIDs.compactMap { id in state.attention.first { $0.id == id } }
    }

    /// "Investigate CI failure · Working" for menus.
    public func taskMenuTitle(_ record: TaskRecord) -> String {
        "\(Presentation.taskTitle(record, snapshot: snapshot(record.task.origin.changeRequest))) · \(TaskStateStyle.label(record))"
    }
}
