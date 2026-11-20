import Foundation
import MergeCueCore

// Grouping by pull/merge request (D46): the Inbox and the menu bar popover show their rows under one collapsible
// header per change request. Groups start expanded; collapsing one keeps a summary visible (count, unread, reasons).

extension InboxResult {
    /// The Inbox's change request groups in display order: groups with something unread or actionable first, then
    /// by latest activity. Items keep `InboxQuery`'s order inside each group.
    public func prGroups(now: Date) -> [InboxGroup] {
        func isActive(_ group: InboxGroup) -> Bool { group.items.contains { $0.isUnread || $0.isActionable(now: now) } }
        func latest(_ group: InboxGroup) -> Date { group.items.map(\.updatedAt).max() ?? .distantPast }
        return groups.filter { !$0.items.isEmpty }.sorted { lhs, rhs in
            let (left, right) = (isActive(lhs), isActive(rhs))
            if left != right { return left }
            return latest(lhs) > latest(rhs)
        }
    }
}

/// The popover rows of one section under one change request, in the order the section lists them.
public nonisolated struct PopoverPRGroup: Sendable, Hashable, Identifiable {
    public var section: PopoverSection
    public var changeRequest: ChangeRequestKey
    public var items: [PopoverItem]

    /// Unique per section, so the same PR can appear in two sections.
    public var id: String { "\(section.rawValue)|\(changeRequest.id)" }
    public var first: PopoverItem? { items.first }

    /// Groups `items` by change request, keeping the order in which each change request first appears.
    public static func make(_ items: [PopoverItem], section: PopoverSection) -> [PopoverPRGroup] {
        var order: [ChangeRequestKey] = []
        var buckets: [ChangeRequestKey: [PopoverItem]] = [:]
        for item in items {
            if buckets[item.changeRequest] == nil { order.append(item.changeRequest) }
            buckets[item.changeRequest, default: []].append(item)
        }
        return order.map { PopoverPRGroup(section: section, changeRequest: $0, items: buckets[$0] ?? []) }
    }
}

extension AppModel {
    // MARK: Collapse state (expanded by default)

    public func isInboxGroupCollapsed(_ changeRequest: ChangeRequestKey) -> Bool {
        collapsedInboxGroups.contains(changeRequest.id)
    }

    public func toggleInboxGroup(_ changeRequest: ChangeRequestKey) {
        if collapsedInboxGroups.contains(changeRequest.id) {
            collapsedInboxGroups.remove(changeRequest.id)
        } else {
            collapsedInboxGroups.insert(changeRequest.id)
            // Keep the keyboard selection on something visible.
            if let selected = attentionItem(selectedAttentionID), selected.changeRequest == changeRequest { selectedAttentionID = nil }
        }
    }

    public func isPopoverGroupCollapsed(_ group: PopoverPRGroup) -> Bool {
        collapsedPopoverGroups.contains(group.id)
    }

    public func togglePopoverGroup(_ group: PopoverPRGroup) {
        if collapsedPopoverGroups.contains(group.id) {
            collapsedPopoverGroups.remove(group.id)
        } else {
            collapsedPopoverGroups.insert(group.id)
            if let selection = popoverSelection, group.items.contains(where: { $0.id == selection }) { popoverSelection = nil }
        }
    }

    /// The popover rows of `section` shown (up to `popoverRowLimit`), grouped by change request.
    public func popoverGroups(_ section: PopoverSection) -> [PopoverPRGroup] {
        PopoverPRGroup.make(Array(sections.items(section).prefix(Self.popoverRowLimit)), section: section)
    }
}
