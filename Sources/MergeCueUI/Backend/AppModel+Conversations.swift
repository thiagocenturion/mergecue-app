import Foundation
import MergeCueCore

/// Conversation-level reads and actions: an Inbox card stands for every attention item of one conversation
/// (`ConversationGrouping`), so marking it read, acknowledging, snoozing or dismissing it applies to all of them.
extension AppModel {
    /// Attention items in the same conversation as `item` (itself first), dismissed ones excluded.
    public func conversationItems(for item: AttentionItem) -> [AttentionItem] {
        guard item.thread != nil else { return [item] }
        let snapshot = snapshot(item.changeRequest)
        let target = ConversationGrouping.key(item, snapshot: snapshot)
        let others = state.attention.filter { other in
            other.id != item.id && other.changeRequest == item.changeRequest && other.disposition != .dismissed
                && ConversationGrouping.key(other, snapshot: snapshot) == target
        }
        return [item] + others.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The thread to show for `item`: every comment of its conversation in time order.
    public func conversationThread(for item: AttentionItem) -> ReviewThread? {
        guard let key = item.thread, let snapshot = snapshot(item.changeRequest), let thread = snapshot.thread(key) else {
            return nil
        }
        return ConversationGrouping.merged(ConversationGrouping.threads(inConversationOf: thread, snapshot: snapshot))
    }

    /// Marks every item of the conversation read (or unread: only the representing item, so the card turns unread).
    public func markConversation(_ item: AttentionItem, read: Bool) async {
        let targets = read ? conversationItems(for: item).filter(\.isUnread) : [item]
        for target in targets {
            await send(.markRead(attentionID: target.id, read: read))
        }
    }

    /// Acknowledges every actionable item of the conversation and marks the rest read, so nothing of it is left
    /// unread behind the card (D55).
    public func acknowledgeConversation(_ item: AttentionItem) async {
        let members = conversationItems(for: item)
        for target in members where target.isActionable(now: now) {
            await send(.acknowledge(attentionID: target.id))
        }
        await markReadLeftovers(of: members)
    }

    public func snoozeConversation(_ item: AttentionItem, until: Date) async {
        let members = conversationItems(for: item)
        for target in members where target.isActionable(now: now) {
            await send(.snooze(attentionID: target.id, until: until))
        }
        await markReadLeftovers(of: members)
    }

    /// Marks read the members an acknowledge or snooze did not touch (resolved or snoozed while unread).
    private func markReadLeftovers(of members: [AttentionItem]) async {
        for target in members where target.isUnread && !target.isActionable(now: now) {
            await send(.markRead(attentionID: target.id, read: true))
        }
    }

    public func dismissConversation(_ item: AttentionItem) async {
        for target in conversationItems(for: item) {
            await send(.dismissAttention(attentionID: target.id))
        }
    }

    /// Whether any item of the conversation is unread.
    public func conversationIsUnread(_ item: AttentionItem) -> Bool {
        conversationItems(for: item).contains(where: \.isUnread)
    }
}

extension AppModel {
    /// The non-terminal task linked to any item of the conversation, if one exists.
    public func activeConversationTask(for item: AttentionItem) -> TaskRecord? {
        if let task = activeTask(for: item) { return task }
        return conversationItems(for: item).dropFirst().lazy.compactMap { self.activeTask(for: $0) }.first
    }

    /// Provider link of the conversation's latest comment, else its thread, else the change request.
    public func providerURL(for item: AttentionItem) -> URL? {
        if let thread = conversationThread(for: item) {
            if let url = thread.latestComment?.webURL ?? thread.webURL { return url }
        }
        return snapshot(item.changeRequest)?.summary.webURL
    }
}
