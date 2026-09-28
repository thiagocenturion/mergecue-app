import Foundation
import MergeCueCore

/// When notifications may be delivered at all.
public struct NotificationPolicy: Sendable, Hashable {
    public var pausedUntil: Date?
    public var quietHours: QuietHours?

    public init(pausedUntil: Date? = nil, quietHours: QuietHours? = nil) {
        self.pausedUntil = pausedUntil
        self.quietHours = quietHours
    }

    /// False while paused or inside quiet hours.
    public func allowsDelivery(at now: Date) -> Bool {
        if let pausedUntil, now < pausedUntil { return false }
        if let quietHours, quietHours.contains(now) { return false }
        return true
    }
}

/// Groups one cycle's committed changes into **one** semantic notification per change request.
///
/// A change request is notified when at least one *newly inserted*, non-baseline event not authored by the user
/// fed an attention item that ends up actionable (not resolved, not dismissed, not in an active snooze), or when
/// such an event has an informational type (default: approval) on the user's own change request. Everything else
/// (own replies, green re-runs, CI recoveries, baseline) stays silent.
public enum NotificationGrouper {
    /// Maximum summary lines in a notification body.
    public static let maxBodyLines = 3

    public static func group(
        newEvents: [ChangeEvent],
        attentionUpserts: [AttentionItem],
        existing: [String: AttentionItem],
        snapshots: [ChangeRequestKey: ChangeRequestSnapshot],
        account: Account,
        informationalTypes: Set<ChangeEventType> = [.approval],
        now: Date
    ) -> [GroupedNotification] {
        let candidates = newEvents.filter { !$0.isBaseline && !$0.isFromCurrentUser && $0.account == account.id }
        guard !candidates.isEmpty else { return [] }
        let candidateIDs = Set(candidates.map(\.id))

        var order: [ChangeRequestKey] = []
        for event in candidates where !order.contains(event.changeRequest) { order.append(event.changeRequest) }

        return order.compactMap { key -> GroupedNotification? in
            let items = attentionUpserts.filter { item in
                item.changeRequest == key
                    && item.eventIDs.contains(where: candidateIDs.contains)
                    && isNotifiable(item, stored: existing[item.dedupeKey], now: now)
            }
            .sorted { ($0.priority, $0.updatedAt) > ($1.priority, $1.updatedAt) }
            let snapshot = snapshots[key]
            let isMine = snapshot.map { AttentionDeriver.isAuthoredByUser($0, userID: account.id.remoteUserID) } ?? false
            let itemEventIDs = Set(items.flatMap(\.eventIDs))
            let informational = candidates.filter {
                $0.changeRequest == key && isMine && informationalTypes.contains($0.type) && !itemEventIDs.contains($0.id)
            }
            guard !items.isEmpty || !informational.isEmpty else { return nil }
            let groupEvents = candidates.filter { $0.changeRequest == key }
            return makeNotification(
                key: key, items: items, informational: informational, events: groupEvents, snapshot: snapshot
            )
        }
    }

    /// Whether an upserted item (merged over `stored`) is something to interrupt the user for.
    static func isNotifiable(_ incoming: AttentionItem, stored: AttentionItem?, now: Date) -> Bool {
        guard incoming.disposition != .resolved else { return false }
        switch stored?.disposition {
        case .dismissed: return false
        case .snoozed(let until): return now >= until
        case nil, .open, .acknowledged, .resolved: return true
        }
    }

    private static func makeNotification(
        key: ChangeRequestKey,
        items: [AttentionItem],
        informational: [ChangeEvent],
        events: [ChangeEvent],
        snapshot: ChangeRequestSnapshot?
    ) -> GroupedNotification {
        let sample = events[0]
        let kind = key.kind
        let title = "\(sample.repoFullPath) \(kind.formattedNumber(key.number))"
        let crTitle = snapshot?.summary.title ?? sample.title
        let subtitle = "\(kind.displayName) · \(crTitle)"

        var lines = items.map { "\($0.reason.displayName): \($0.summary)" }
        lines += informational.map(\.summary)
        var body = lines.prefix(maxBodyLines).joined(separator: "\n")
        if lines.count > maxBodyLines { body += "\n+\(lines.count - maxBodyLines) more" }

        var webURL = snapshot?.summary.webURL
        if items.count == 1, let threadKey = items[0].thread, let thread = snapshot?.thread(threadKey) {
            webURL = thread.latestComment?.webURL ?? thread.webURL ?? webURL
        } else if items.count == 1, let checkKey = items[0].check, let url = snapshot?.check(checkKey)?.detailsURL {
            webURL = url
        }
        let fingerprint = ([key.id] + events.map(\.id).sorted()).joined(separator: "\n")
        return GroupedNotification(
            id: "ntf_" + ContentDigest.sha256Hex(fingerprint).prefix(24),
            threadIdentifier: key.id,
            title: title,
            subtitle: subtitle,
            body: body,
            changeRequest: key,
            attentionItemIDs: items.map(\.id),
            isUrgent: items.contains { $0.priority >= .high },
            webURL: webURL
        )
    }
}
