import Foundation
import MergeCueCore

/// One pull/merge request on the Reviews screen (D53): the snapshot, the user's review state and the lane it is in.
public nonisolated struct ReviewEntry: Sendable, Hashable, Identifiable {
    public var snapshot: ChangeRequestSnapshot
    public var status: ViewerReviewStatus
    /// The lane shown (`status.lane`).
    public var lane: ReviewLane
    /// Open threads where someone answered the user (actionable Inbox thread items).
    public var newReplies: Int
    public var id: String { snapshot.id }
    /// The author pushed or replied since the user asked for changes or commented (D56): the entry stays in
    /// "Changes requested", sorted first and flagged.
    public var hasUpdates: Bool { lane == .changesRequested && (status.headMovedSinceVerdict || newReplies > 0) }
    public var key: ChangeRequestKey { snapshot.key }
}

/// The Reviews screen's lanes after filtering.
public nonisolated struct ReviewQueue: Sendable, Hashable {
    public var toReview: [ReviewEntry] = []
    public var changesRequested: [ReviewEntry] = []
    public var approved: [ReviewEntry] = []

    /// The lanes in display order.
    public static let lanes: [ReviewLane] = [.toReview, .changesRequested, .approved]

    public var all: [ReviewEntry] { toReview + changesRequested + approved }
    public var isEmpty: Bool { toReview.isEmpty && changesRequested.isEmpty && approved.isEmpty }
    /// Entries that need the user: everything to review plus author updates on their requested changes.
    public var needsYouCount: Int { toReview.count + changesRequested.filter(\.hasUpdates).count }

    public func entries(_ lane: ReviewLane) -> [ReviewEntry] {
        switch lane {
        case .toReview: toReview
        case .changesRequested: changesRequested
        case .approved: approved
        case .closed: []
        }
    }

    /// Open change requests of others the user reviews, sorted into lanes. "To review" puts lost approvals first;
    /// "Changes requested" puts author updates first; then the latest activity first.
    public static func run(state: AppState, filter: ChangeRequestFilter, now: Date) -> ReviewQueue {
        let actionable = state.attention.filter { $0.isActionable(now: now) && $0.thread != nil }
        var replies: [String: Int] = [:]
        for item in actionable { replies[item.changeRequest.id, default: 0] += 1 }

        var queue = ReviewQueue()
        for snapshot in state.changeRequests where matches(snapshot, filter: filter) {
            guard let entry = entry(snapshot, replies: replies[snapshot.id] ?? 0) else { continue }
            switch entry.lane {
            case .toReview: queue.toReview.append(entry)
            case .changesRequested: queue.changesRequested.append(entry)
            case .approved: queue.approved.append(entry)
            case .closed: continue
            }
        }
        queue.toReview.sort { lhs, rhs in
            if lhs.status.needsReapproval != rhs.status.needsReapproval { return lhs.status.needsReapproval }
            return (lhs.snapshot.summary.updatedAt, lhs.id) > (rhs.snapshot.summary.updatedAt, rhs.id)
        }
        let latestFirst: (ReviewEntry, ReviewEntry) -> Bool = {
            ($0.snapshot.summary.updatedAt, $0.id) > ($1.snapshot.summary.updatedAt, $1.id)
        }
        queue.changesRequested.sort { lhs, rhs in
            if lhs.hasUpdates != rhs.hasUpdates { return lhs.hasUpdates }
            return latestFirst(lhs, rhs)
        }
        queue.approved.sort(by: latestFirst)
        return queue
    }

    /// The entry of one change request, or nil when it is not one the user reviews.
    public static func entry(_ snapshot: ChangeRequestSnapshot, replies: Int) -> ReviewEntry? {
        guard let status = ViewerReview.status(of: snapshot, userID: snapshot.key.account.remoteUserID) else { return nil }
        return ReviewEntry(snapshot: snapshot, status: status, lane: status.lane, newReplies: replies)
    }

    static func matches(_ snapshot: ChangeRequestSnapshot, filter: ChangeRequestFilter) -> Bool {
        let summary = snapshot.summary
        guard summary.state == .open else { return false }
        if let provider = filter.provider, summary.providerKind != provider { return false }
        if let account = filter.account, snapshot.key.account != account { return false }
        let query = filter.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        let number = query.hasPrefix("#") || query.hasPrefix("!") ? String(query.dropFirst()) : query
        return summary.title.lowercased().contains(query)
            || summary.repository.fullPath.lowercased().contains(query)
            || summary.author.username.lowercased().contains(query)
            || (summary.author.displayName ?? "").lowercased().contains(query)
            || String(summary.key.number) == number
    }
}

/// Copy for a review entry: the status chip and its tone.
public nonisolated enum ReviewText {
    /// "Re-approval needed", "2 new commits", "Review requested", "Asked for changes", "Approved by you", …
    public static func chip(_ entry: ReviewEntry) -> (text: String, symbol: String, tone: Tone) {
        let status = entry.status
        if status.needsReapproval { return ("Re-approval needed", "arrow.counterclockwise", .attention) }
        if status.isRequested { return ("Review requested", "eye", .progress) }
        if entry.hasUpdates, status.headMovedSinceVerdict { return (updates(status), "arrow.triangle.2.circlepath", .progress) }
        if entry.hasUpdates, entry.newReplies > 0 {
            return (entry.newReplies == 1 ? "1 new reply" : "\(entry.newReplies) new replies", "arrowshape.turn.up.left", .progress)
        }
        switch status.verdict {
        case .approved?: return ("Approved by you", "checkmark.seal", .success)
        case .changesRequested?: return ("Asked for changes", "exclamationmark.bubble", .attention)
        default: return ("You commented", "bubble.left", .neutral)
        }
    }

    /// Secondary note: what changed since the verdict on approved PRs ("1 new commit since your approval").
    public static func note(_ entry: ReviewEntry) -> String? {
        guard entry.lane == .approved, entry.status.headMovedSinceVerdict else { return nil }
        return updates(entry.status) + " since your approval"
    }

    static func updates(_ status: ViewerReviewStatus) -> String {
        if status.rebasedSinceVerdict { return "Rebased" }
        guard let count = status.commitsSinceVerdict, count > 0 else { return "New commits" }
        return count == 1 ? "1 new commit" : "\(count) new commits"
    }

    /// One line for the popover summary: "3 to review · 2 changes requested · 4 approved".
    public static func summaryLine(_ queue: ReviewQueue) -> String {
        "\(queue.toReview.count) to review · \(queue.changesRequested.count) changes requested · \(queue.approved.count) approved"
    }
}

extension AppModel {
    /// The Reviews screen's lanes with the current filters (D53).
    public var reviewQueue: ReviewQueue {
        ReviewQueue.run(state: state, filter: reviewFilter, now: now)
    }

    /// The review lanes under the Inbox's provider, account and search filters (the Inbox's Reviews filter, D56).
    public var inboxReviewQueue: ReviewQueue {
        let filter = ChangeRequestFilter(provider: inboxFilter.provider, account: inboxFilter.account, searchText: inboxFilter.searchText)
        return ReviewQueue.run(state: state, filter: filter, now: now)
    }
}
