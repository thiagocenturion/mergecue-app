import Foundation
import MergeCueCore

/// Pure derivation of attention-item upserts for one change request from this cycle's events and its current
/// snapshot. The store merges the result with the stored items (`AttentionMergePolicy`: Sync owns content, the user
/// owns state), so this returns *incoming* items only — at most one per dedupe key.
///
/// Rules:
/// - Own events never create or refresh items.
/// - Threads (`review_comment` / `reply`): one item per thread, created or refreshed only while the thread is open,
///   relevant to the user (their CR, or a thread they took part in) and **awaiting them** (not resolved, latest
///   comment not theirs). New activity on an existing item carries the new event ids and a newer `updatedAt`, so
///   the store marks it unread and reopens it if it was resolved/acknowledged.
///   Reason: any ```suggestion → `codeSuggestion`; latest reviewer comment is a question → `reviewerQuestion`;
///   thread started by the user → `reply`; else `reviewComment`.
/// - `ci_failed`: one item per check name on the user's own CR while that check is still failing
///   (`high`, or `normal` for checks the provider marks as not required).
/// - `change_requested` on the user's CR while a reviewer's latest verdict is still "changes requested".
/// - `review_requested` while the review is still requested; `ready_to_merge` on the user's CR while ready.
/// - Resolution (`disposition = .resolved`): thread resolved or gone, check recovered/passing/gone, no outstanding
///   change request, review no longer requested, readiness lost, and every item once the CR is merged/closed.
/// - Baseline events follow the same rules, so the first sync creates items for currently actionable state only.
public enum AttentionDeriver {
    public static func apply(
        events: [ChangeEvent],
        snapshot: ChangeRequestSnapshot,
        existing: [AttentionItem],
        account: Account,
        now: Date
    ) -> [AttentionItem] {
        var context = Context(snapshot: snapshot, existing: existing, me: account.id.remoteUserID, now: now)
        let foreign = events.filter { !$0.isFromCurrentUser && $0.changeRequest == snapshot.key }
        context.deriveThreads(foreign)
        context.deriveChecks(foreign)
        context.deriveReasonItems(foreign)
        context.reconcile(events: events.filter { $0.changeRequest == snapshot.key })
        return context.orderedResult
    }

    /// Resolves every open item of a change request that left the user's lists (reviewed, unassigned, deleted, …).
    /// `events` (e.g. `merged`) are attached to the resolved items for traceability.
    public static func resolveAll(existing: [AttentionItem], events: [ChangeEvent]) -> [AttentionItem] {
        existing.compactMap { item in
            guard item.disposition != .resolved, item.disposition != .dismissed else { return nil }
            var resolved = item
            resolved.disposition = .resolved
            resolved.eventIDs = item.eventIDs + events.filter { $0.changeRequest == item.changeRequest }.map(\.id)
            return resolved
        }
    }

    // MARK: Shared predicates

    /// Whether the change request was authored by the user.
    public static func isAuthoredByUser(_ snapshot: ChangeRequestSnapshot, userID: String) -> Bool {
        snapshot.summary.author.remoteID == userID || snapshot.summary.involvement.contains(.authored)
    }

    /// The thread's latest non-system comment is not the user's and the thread is not resolved.
    public static func threadAwaitsUser(_ thread: ReviewThread, userID: String) -> Bool {
        guard thread.isResolved != true else { return false }
        guard let latest = thread.comments.last(where: { EventDeriver.effectiveKind($0) != .system }) else { return false }
        return latest.author.remoteID != userID
    }

    /// The user's CR, or a thread the user commented in.
    public static func threadIsRelevant(_ thread: ReviewThread, snapshot: ChangeRequestSnapshot, userID: String) -> Bool {
        isAuthoredByUser(snapshot, userID: userID) || thread.comments.contains { $0.author.remoteID == userID }
    }

    /// Reviewers (not the user) whose latest verdict is "changes requested". Verdicts come from submitted reviews
    /// (newest per author wins) and are overridden by the provider's current reviewer list when it states one.
    public static func outstandingChangeRequesters(_ snapshot: ChangeRequestSnapshot, userID: String) -> [Person] {
        let verdicts: Set<ReviewState> = [.approved, .changesRequested, .dismissed]
        var latest: [String: (person: Person, state: ReviewState)] = [:]
        let reviews = snapshot.reviews
            .filter { verdicts.contains($0.state) }
            .enumerated()
            .sorted { ($0.element.submittedAt ?? .distantPast, $0.offset) < ($1.element.submittedAt ?? .distantPast, $1.offset) }
            .map(\.element)
        for review in reviews { latest[review.author.remoteID] = (review.author, review.state) }
        for reviewer in snapshot.reviewers where verdicts.contains(reviewer.state) {
            latest[reviewer.person.remoteID] = (reviewer.person, reviewer.state)
        }
        return latest.values
            .filter { $0.state == .changesRequested && $0.person.remoteID != userID }
            .map(\.person)
            .sorted { $0.username < $1.username }
    }

    /// Reason of a thread item (see type docs).
    public static func threadReason(_ thread: ReviewThread, userID: String) -> AttentionReason {
        let foreign = thread.comments.filter { $0.author.remoteID != userID && EventDeriver.effectiveKind($0) != .system }
        if foreign.contains(where: { EventDeriver.effectiveKind($0) == .suggestion }) { return .codeSuggestion }
        if let latest = foreign.last, EventDeriver.effectiveKind(latest) == .question { return .reviewerQuestion }
        if thread.rootComment?.author.remoteID == userID { return .reply }
        return .reviewComment
    }

    // MARK: Derivation state

    private struct Context {
        let snapshot: ChangeRequestSnapshot
        let existingByKey: [String: AttentionItem]
        let existing: [AttentionItem]
        let me: String
        let now: Date
        let isOpen: Bool
        let isMine: Bool
        private(set) var result: [String: AttentionItem] = [:]
        private(set) var order: [String] = []

        init(snapshot: ChangeRequestSnapshot, existing: [AttentionItem], me: String, now: Date) {
            self.snapshot = snapshot
            self.existing = existing.filter { $0.changeRequest == snapshot.key }
            self.existingByKey = Dictionary(self.existing.map { ($0.dedupeKey, $0) }, uniquingKeysWith: { first, _ in first })
            self.me = me
            self.now = now
            self.isOpen = snapshot.summary.state == .open
            self.isMine = AttentionDeriver.isAuthoredByUser(snapshot, userID: me)
        }

        var orderedResult: [AttentionItem] { order.compactMap { result[$0] } }

        private mutating func put(_ item: AttentionItem) {
            if result[item.dedupeKey] == nil { order.append(item.dedupeKey) }
            result[item.dedupeKey] = item
        }

        // MARK: Threads

        mutating func deriveThreads(_ events: [ChangeEvent]) {
            let threadEvents = events.filter { $0.type == .reviewComment || $0.type == .reply }
            var grouped: [ThreadKey: [ChangeEvent]] = [:]
            var keys: [ThreadKey] = []
            for event in threadEvents {
                guard let key = event.thread else { continue }
                if grouped[key] == nil { keys.append(key) }
                grouped[key, default: []].append(event)
            }
            for key in keys {
                guard isOpen, let thread = snapshot.thread(key), let events = grouped[key],
                      AttentionDeriver.threadIsRelevant(thread, snapshot: snapshot, userID: me),
                      AttentionDeriver.threadAwaitsUser(thread, userID: me) else { continue }
                put(threadItem(thread, events: events))
            }
        }

        private func threadItem(_ thread: ReviewThread, events: [ChangeEvent]) -> AttentionItem {
            let dedupeKey = AttentionItem.dedupeKey(thread: thread.key)
            let reason = AttentionDeriver.threadReason(thread, userID: me)
            let latest = thread.comments.last { $0.author.remoteID != me && EventDeriver.effectiveKind($0) != .system }
            let priority: AttentionPriority = latest?.author.isBot == true ? .low : reason.defaultPriority
            return item(
                dedupeKey: dedupeKey, reason: reason, priority: priority, summary: threadSummary(thread),
                thread: thread.key, events: events
            )
        }

        func threadSummary(_ thread: ReviewThread) -> String {
            let latest = thread.comments.last { $0.author.remoteID != me && EventDeriver.effectiveKind($0) != .system }
                ?? thread.comments.last
            var parts: [String] = []
            if thread.isOutdated { parts.append("[outdated]") }
            if let anchor = thread.anchor {
                parts.append(anchor.line.map { "\(anchor.path):\($0)" } ?? anchor.path)
            }
            if let latest {
                parts.append("\(latest.author.displayLabel): \(EventDeriver.excerpt(latest.body))")
            }
            return parts.joined(separator: " ")
        }

        // MARK: Checks

        mutating func deriveChecks(_ events: [ChangeEvent]) {
            let latestByName = EventDeriver.latestChecksByName(snapshot.checks)
            for event in events where event.type == .ciFailed {
                guard isOpen, isMine, let name = checkName(event), let check = latestByName[name], check.status.isFailing
                else { continue }
                let dedupeKey = AttentionItem.dedupeKey(changeRequest: snapshot.key, checkName: name)
                let previous = result[dedupeKey]?.eventIDs ?? []
                let priority: AttentionPriority = check.isRequired == false ? .normal : AttentionReason.ciFailed.defaultPriority
                var built = item(
                    dedupeKey: dedupeKey, reason: .ciFailed, priority: priority,
                    summary: checkSummary(check), check: check.key, events: [event]
                )
                built.eventIDs = previous + built.eventIDs
                put(built)
            }
            for event in events where event.type == .ciRecovered {
                guard let name = checkName(event) else { continue }
                let dedupeKey = AttentionItem.dedupeKey(changeRequest: snapshot.key, checkName: name)
                guard let stored = existingByKey[dedupeKey], result[dedupeKey] == nil else { continue }
                var resolved = stored
                resolved.disposition = .resolved
                resolved.check = event.check ?? stored.check
                resolved.summary = event.summary
                resolved.eventIDs = stored.eventIDs + [event.id]
                put(resolved)
            }
        }

        private func checkName(_ event: ChangeEvent) -> String? {
            if let name = event.nativeRefs["check_name"] { return name }
            return event.check.flatMap { snapshot.check($0)?.name }
        }

        private func checkSummary(_ check: CheckRun) -> String {
            let at = check.commitSHA.map { " on \(EventDeriver.short($0))" } ?? ""
            var text = "\(check.name): \(check.status.displayName.lowercased())\(at)"
            if let summary = check.summary, !summary.isEmpty { text += " — " + EventDeriver.excerpt(summary, maxBytes: 120) }
            return text
        }

        // MARK: CR-level reasons

        mutating func deriveReasonItems(_ events: [ChangeEvent]) {
            guard isOpen else { return }
            let changeEvents = events.filter { $0.type == .changeRequested }
            let requesters = AttentionDeriver.outstandingChangeRequesters(snapshot, userID: me)
            if isMine, !changeEvents.isEmpty, !requesters.isEmpty {
                let names = requesters.map(\.displayLabel).joined(separator: ", ")
                put(item(
                    dedupeKey: AttentionItem.dedupeKey(changeRequest: snapshot.key, reason: .changesRequested),
                    reason: .changesRequested, summary: "\(names) requested changes", events: changeEvents
                ))
            }
            let requestEvents = events.filter { $0.type == .reviewRequested }
            if !requestEvents.isEmpty, snapshot.summary.involvement.contains(.reviewRequested) {
                put(item(
                    dedupeKey: AttentionItem.dedupeKey(changeRequest: snapshot.key, reason: .reviewRequested),
                    reason: .reviewRequested,
                    summary: "\(snapshot.summary.author.displayLabel) requested your review",
                    events: requestEvents
                ))
            }
            let readyEvents = events.filter { $0.type == .readyToMerge }
            if isMine, !readyEvents.isEmpty, snapshot.readiness == .readyToMerge {
                put(item(
                    dedupeKey: AttentionItem.dedupeKey(changeRequest: snapshot.key, reason: .readyToMerge),
                    reason: .readyToMerge, summary: "Ready to merge", events: readyEvents
                ))
            }
        }

        // MARK: Resolution / content refresh of stored items

        mutating func reconcile(events: [ChangeEvent]) {
            let latestByName = EventDeriver.latestChecksByName(snapshot.checks)
            let resolvingEvents = events.filter {
                [.threadResolved, .ciRecovered, .merged, .closedWithoutMerge].contains($0.type)
            }
            for stored in existing where result[stored.dedupeKey] == nil {
                guard stored.disposition != .dismissed else { continue }
                if shouldResolve(stored, latestByName: latestByName) {
                    guard stored.disposition != .resolved else { continue }
                    var resolved = stored
                    resolved.disposition = .resolved
                    let related = resolvingEvents.filter { event in
                        event.type == .merged || event.type == .closedWithoutMerge
                            || (event.thread != nil && event.thread == stored.thread)
                    }
                    resolved.eventIDs = stored.eventIDs + related.map(\.id)
                    put(resolved)
                } else if stored.disposition != .resolved, let thread = stored.thread.flatMap(snapshot.thread) {
                    // Content refresh without new activity (e.g. the anchor became outdated after a force-push).
                    let summary = threadSummary(thread)
                    guard summary != stored.summary else { continue }
                    var refreshed = stored
                    refreshed.summary = summary
                    put(refreshed)
                }
            }
        }

        private func shouldResolve(_ stored: AttentionItem, latestByName: [String: CheckRun]) -> Bool {
            guard isOpen else { return true }
            if let key = stored.thread {
                guard let thread = snapshot.thread(key) else { return true }
                return thread.isResolved == true
            }
            switch stored.reason {
            case .ciFailed:
                let name = latestByName.keys.first {
                    AttentionItem.dedupeKey(changeRequest: snapshot.key, checkName: $0) == stored.dedupeKey
                }
                guard let name, let check = latestByName[name] else { return true }
                return check.status.isPassing
            case .changesRequested:
                return AttentionDeriver.outstandingChangeRequesters(snapshot, userID: me).isEmpty
            case .reviewRequested:
                return !snapshot.summary.involvement.contains(.reviewRequested)
            case .readyToMerge:
                return snapshot.readiness != .readyToMerge
            case .reviewComment, .reviewerQuestion, .codeSuggestion, .reply, .mergeConflict:
                return false
            }
        }

        // MARK: Item construction

        private func item(
            dedupeKey: String,
            reason: AttentionReason,
            priority: AttentionPriority? = nil,
            summary: String,
            thread: ThreadKey? = nil,
            check: CheckKey? = nil,
            events: [ChangeEvent]
        ) -> AttentionItem {
            let stored = existingByKey[dedupeKey]
            let eventIDs = events.map(\.id)
            let latest = events.map(\.occurredAt).max() ?? now
            var updatedAt = max(latest, stored?.updatedAt ?? .distantPast)
            if let stored, !Set(eventIDs).isSubset(of: Set(stored.eventIDs)), updatedAt <= stored.updatedAt {
                // Genuinely new activity must read as newer than the stored item so the store reopens/marks unread.
                updatedAt = stored.updatedAt.addingTimeInterval(0.001)
            }
            return AttentionItem(
                dedupeKey: dedupeKey,
                changeRequest: snapshot.key,
                repoFullPath: snapshot.summary.repository.fullPath,
                title: snapshot.summary.title,
                reason: reason,
                priority: priority,
                summary: summary,
                thread: thread,
                check: check,
                eventIDs: eventIDs,
                createdAt: stored?.createdAt ?? now,
                updatedAt: updatedAt,
                // Incoming state is always "open + unread"; the store keeps the user's state unless this is new
                // activity (never pass a stored `.resolved` back in: it would re-resolve the item).
                isUnread: true,
                disposition: .open,
                linkedTaskID: stored?.linkedTaskID
            )
        }
    }
}
