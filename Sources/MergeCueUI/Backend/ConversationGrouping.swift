import Foundation
import MergeCueCore

/// Groups review threads (and the attention items that point at them) into the conversations a person reads as
/// one thread, so the Inbox shows one card per conversation and the detail shows every comment in order.
///
/// Providers already return a reply chain as a single `ReviewThread`. Two more cases read as one thread:
/// - separate threads on the same line of the same file (a reviewer starting a new thread instead of replying);
/// - top-level comments without a reply chain of their own (GitHub conversation comments and review bodies,
///   Bitbucket general comments, GitLab individual notes): the change request's main conversation.
///
/// Resolvable threads without an anchor (GitLab discussions) stay on their own: they resolve independently.
public nonisolated enum ConversationGrouping {
    /// Key shared by every thread of one conversation.
    public static func key(_ thread: ReviewThread) -> String {
        let changeRequest = thread.key.changeRequest.id
        if let anchor = thread.anchor {
            // Outdated anchors point into an older revision, so they never share a line with current ones.
            let line = anchor.line.map(String.init) ?? "file"
            let state = anchor.isOutdated ? "outdated" : "current"
            return "\(changeRequest)|code|\(anchor.path)|\(anchor.side.rawValue)|\(line)|\(state)"
        }
        if !thread.isResolvable { return "\(changeRequest)|conversation" }
        return thread.key.id
    }

    /// Conversation key of an attention item. Items without a thread (CI, review requested, …) are their own group.
    public static func key(_ item: AttentionItem, snapshot: ChangeRequestSnapshot?) -> String {
        guard let threadKey = item.thread else { return "item|" + item.id }
        guard let thread = snapshot?.thread(threadKey) else { return threadKey.id }
        return key(thread)
    }

    /// Threads of `snapshot` in the same conversation as `thread`, oldest first.
    public static func threads(inConversationOf thread: ReviewThread, snapshot: ChangeRequestSnapshot) -> [ReviewThread] {
        let target = key(thread)
        let matching = snapshot.threads.filter { key($0) == target }
        return (matching.isEmpty ? [thread] : matching).sorted(by: oldestFirst)
    }

    /// Every thread of `snapshot`, grouped by conversation (each group oldest first, groups in first-seen order).
    public static func conversations(_ snapshot: ChangeRequestSnapshot) -> [[ReviewThread]] {
        var order: [String] = []
        var groups: [String: [ReviewThread]] = [:]
        for thread in snapshot.threads {
            let groupKey = key(thread)
            if groups[groupKey] == nil { order.append(groupKey) }
            groups[groupKey, default: []].append(thread)
        }
        return order.compactMap { groups[$0]?.sorted(by: oldestFirst) }
    }

    /// One thread that presents every comment of `threads` in time order. The key, links and resolution concept
    /// come from the oldest thread; the anchor prefers one that carries code context. Resolved only when every
    /// thread is resolved. nil for an empty list.
    public static func merged(_ threads: [ReviewThread]) -> ReviewThread? {
        let sorted = threads.sorted(by: oldestFirst)
        guard let first = sorted.first else { return nil }
        guard sorted.count > 1 else { return first }
        var seen: Set<String> = []
        let comments = sorted.flatMap(\.comments)
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        let resolutions = sorted.compactMap(\.isResolved)
        let isResolved: Bool? = resolutions.isEmpty ? nil : resolutions.allSatisfy { $0 }
        return ReviewThread(
            key: first.key,
            anchor: sorted.first { $0.anchor?.diffHunk != nil }?.anchor ?? first.anchor,
            isResolved: isResolved,
            isResolvable: sorted.contains(where: \.isResolvable),
            comments: comments,
            webURL: first.webURL,
            lastActivityAt: sorted.map(\.lastActivityAt).max() ?? first.lastActivityAt
        )
    }

    /// Groups `items` by conversation. Each group keeps its items in `order`; the first one represents the group.
    /// Groups come back in the order their first item appears.
    public static func group(
        _ items: [AttentionItem],
        snapshots: [ChangeRequestKey: ChangeRequestSnapshot],
        order: (AttentionItem, AttentionItem) -> Bool
    ) -> [[AttentionItem]] {
        var keys: [String] = []
        var groups: [String: [AttentionItem]] = [:]
        for item in items {
            let groupKey = key(item, snapshot: snapshots[item.changeRequest])
            if groups[groupKey] == nil { keys.append(groupKey) }
            groups[groupKey, default: []].append(item)
        }
        return keys.compactMap { groups[$0]?.sorted(by: order) }
    }

    private static func oldestFirst(_ lhs: ReviewThread, _ rhs: ReviewThread) -> Bool {
        let left = lhs.rootComment?.createdAt ?? lhs.lastActivityAt
        let right = rhs.rootComment?.createdAt ?? rhs.lastActivityAt
        return (left, lhs.key.id) < (right, rhs.key.id)
    }
}
