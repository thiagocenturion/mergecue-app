import Foundation
import MergeCueCore

/// One pull/merge request on the Reviews screen (D53): the snapshot, the user's review state and the lane it is in.
public nonisolated struct ReviewEntry: Sendable, Hashable, Identifiable {
    public var snapshot: ChangeRequestSnapshot
    public var status: ViewerReviewStatus
    /// The lane shown: `status.lane`, except that replies awaiting the user move "Waiting on author" to "To review".
    public var lane: ReviewLane
    /// Open threads where someone answered the user (actionable Inbox thread items).
    public var newReplies: Int
    public var id: String { snapshot.id }
    public var key: ChangeRequestKey { snapshot.key }
}

/// The Reviews screen's lanes after filtering.
public nonisolated struct ReviewQueue: Sendable, Hashable {
    public var toReview: [ReviewEntry] = []
    public var waitingOnAuthor: [ReviewEntry] = []
    public var approved: [ReviewEntry] = []

    public var all: [ReviewEntry] { toReview + waitingOnAuthor + approved }
    public var isEmpty: Bool { toReview.isEmpty && waitingOnAuthor.isEmpty && approved.isEmpty }

    public func entries(_ lane: ReviewLane) -> [ReviewEntry] {
        switch lane {
        case .toReview: toReview
        case .waitingOnAuthor: waitingOnAuthor
        case .approved: approved
        case .closed: []
        }
    }

    /// Open change requests of others the user reviews, sorted into lanes. "To review" puts lost approvals first,
    /// then the oldest request (it has waited longest); the other lanes show the latest activity first.
    public static func run(state: AppState, filter: ChangeRequestFilter, now: Date) -> ReviewQueue {
        let actionable = state.attention.filter { $0.isActionable(now: now) && $0.thread != nil }
        var replies: [String: Int] = [:]
        for item in actionable { replies[item.changeRequest.id, default: 0] += 1 }

        var queue = ReviewQueue()
        for snapshot in state.changeRequests where matches(snapshot, filter: filter) {
            guard let entry = entry(snapshot, replies: replies[snapshot.id] ?? 0) else { continue }
            switch entry.lane {
            case .toReview: queue.toReview.append(entry)
            case .waitingOnAuthor: queue.waitingOnAuthor.append(entry)
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
        queue.waitingOnAuthor.sort(by: latestFirst)
        queue.approved.sort(by: latestFirst)
        return queue
    }

    /// The entry of one change request, or nil when it is not one the user reviews.
    public static func entry(_ snapshot: ChangeRequestSnapshot, replies: Int) -> ReviewEntry? {
        guard let status = ViewerReview.status(of: snapshot, userID: snapshot.key.account.remoteUserID) else { return nil }
        var lane = status.lane
        if lane == .waitingOnAuthor, replies > 0 { lane = .toReview }
        return ReviewEntry(snapshot: snapshot, status: status, lane: lane, newReplies: replies)
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
        if entry.lane == .toReview, status.headMovedSinceVerdict { return (updates(status), "arrow.triangle.2.circlepath", .progress) }
        if entry.lane == .toReview, entry.newReplies > 0 {
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

    /// One line for the popover summary: "3 to review · 2 waiting · 4 approved".
    public static func summaryLine(_ queue: ReviewQueue) -> String {
        "\(queue.toReview.count) to review · \(queue.waitingOnAuthor.count) waiting · \(queue.approved.count) approved"
    }
}

extension AppModel {
    /// The Reviews screen's lanes with the current filters (D53).
    public var reviewQueue: ReviewQueue {
        ReviewQueue.run(state: state, filter: reviewFilter, now: now)
    }

    /// The user's review entry of one change request (chips on the Pull requests list), nil for their own.
    public func reviewEntry(_ snapshot: ChangeRequestSnapshot) -> ReviewEntry? {
        let replies = state.attention.filter {
            $0.changeRequest == snapshot.key && $0.thread != nil && $0.isActionable(now: now)
        }.count
        return ReviewQueue.entry(snapshot, replies: replies)
    }
}
