import Foundation

/// What MergeCue remembers about the current user's own review of someone else's change request (D53).
///
/// Providers report the user's *current* verdict but not which commit it applies to (Bitbucket) or whether an
/// approval was taken away by a push (approvals reset on new commits, stale approvals dismissed). Sync carries this
/// record forward from snapshot to snapshot (`ViewerReview.nextMemory`) so both can be told.
public struct ViewerReviewMemory: Codable, Sendable, Hashable {
    /// The user's verdict as last seen: `approved`, `changesRequested` or `commented`; nil = none (yet / any more).
    public var verdict: ReviewState?
    /// Head commit the verdict applies to: the review's commit when the provider records one, else the head when
    /// MergeCue first saw the verdict.
    public var verdictHeadSHA: String?
    public var verdictSeenAt: Date?
    /// Set when the user's approval disappeared after the head moved while the change request stayed open.
    /// Cleared by the user's next approval or change request.
    public var lostApprovalAt: Date?
    /// Head the lost approval was noticed at.
    public var lostApprovalHeadSHA: String?

    public init(
        verdict: ReviewState? = nil,
        verdictHeadSHA: String? = nil,
        verdictSeenAt: Date? = nil,
        lostApprovalAt: Date? = nil,
        lostApprovalHeadSHA: String? = nil
    ) {
        self.verdict = verdict
        self.verdictHeadSHA = verdictHeadSHA
        self.verdictSeenAt = verdictSeenAt
        self.lostApprovalAt = lostApprovalAt
        self.lostApprovalHeadSHA = lostApprovalHeadSHA
    }
}

/// Where a change request the user reviews stands for them.
public enum ReviewLane: String, Codable, Sendable, CaseIterable {
    /// Needs the user's first look: a pending request or a lost approval.
    case toReview = "to_review"
    /// The user asked for changes or commented. Author updates (new commits, replies) keep it here, flagged and
    /// sorted first (D56).
    case changesRequested = "changes_requested"
    /// The user's approval stands; watched until merge.
    case approved
    /// Merged or closed.
    case closed

    public var title: String {
        switch self {
        case .toReview: "To review"
        case .changesRequested: "Changes requested"
        case .approved: "Approved, watching"
        case .closed: "Closed"
        }
    }
}

/// The user's review state of one change request (`ViewerReview.status`).
public struct ViewerReviewStatus: Sendable, Hashable {
    public var lane: ReviewLane
    /// Current verdict (`approved`, `changesRequested`, `commented`) or nil.
    public var verdict: ReviewState?
    /// A review is requested from the user and they have not given a verdict.
    public var isRequested: Bool
    /// The user's approval was reset by new commits (or dismissed) and not given again.
    public var needsReapproval: Bool
    /// The head moved since the verdict.
    public var headMovedSinceVerdict: Bool
    /// The head commit is no longer in the commit list (force-push / rebase) since the verdict.
    public var rebasedSinceVerdict: Bool
    /// Commits added since the verdict, when the commit list tells.
    public var commitsSinceVerdict: Int?

    public init(
        lane: ReviewLane, verdict: ReviewState?, isRequested: Bool, needsReapproval: Bool, headMovedSinceVerdict: Bool,
        rebasedSinceVerdict: Bool = false, commitsSinceVerdict: Int? = nil
    ) {
        self.lane = lane
        self.verdict = verdict
        self.isRequested = isRequested
        self.needsReapproval = needsReapproval
        self.headMovedSinceVerdict = headMovedSinceVerdict
        self.rebasedSinceVerdict = rebasedSinceVerdict
        self.commitsSinceVerdict = commitsSinceVerdict
    }
}

/// Pure derivation of the user's own review state (D53). `userID` is the account's remote user id
/// (`AccountKey.remoteUserID`).
public enum ViewerReview {
    /// Whether the change request is the user's own (their own reviews of it are not tracked).
    public static func isAuthored(_ snapshot: ChangeRequestSnapshot, userID: String) -> Bool {
        snapshot.summary.author.remoteID == userID || snapshot.summary.involvement.contains(.authored)
    }

    /// The user's current verdict: their reviewer entry (a pending request means none, a dismissed review counts as
    /// a comment), else their latest submitted review, else the approval list, else `commented` when they wrote in
    /// a thread and no review is requested from them.
    public static func currentVerdict(_ snapshot: ChangeRequestSnapshot, userID: String) -> ReviewState? {
        if let entry = snapshot.reviewers.first(where: { $0.person.remoteID == userID }) {
            switch entry.state {
            case .approved, .changesRequested, .commented: return entry.state
            case .dismissed: return .commented
            case .pending: return nil
            }
        }
        let mine = snapshot.reviews.enumerated()
            .filter { $0.element.author.remoteID == userID }
            .max { ($0.element.submittedAt ?? .distantPast, $0.offset) < ($1.element.submittedAt ?? .distantPast, $1.offset) }?
            .element
        if let mine {
            switch mine.state {
            case .approved, .changesRequested, .commented: return mine.state
            case .dismissed: return .commented
            case .pending: break
            }
        }
        if snapshot.approvals.approvedBy.contains(where: { $0.remoteID == userID }) { return .approved }
        // A pending request stays pending until the provider records a review; a comment alone does not answer it.
        guard !snapshot.summary.involvement.contains(.reviewRequested) else { return nil }
        if snapshot.threads.contains(where: { $0.comments.contains { $0.author.remoteID == userID } }) { return .commented }
        return nil
    }

    /// The memory to store with `current`, carried forward from `previous` (D53). Nil for the user's own change
    /// requests and while they never reviewed.
    public static func nextMemory(
        previous: ChangeRequestSnapshot?, current: ChangeRequestSnapshot, userID: String, now: Date
    ) -> ViewerReviewMemory? {
        guard !isAuthored(current, userID: userID) else { return nil }
        let verdict = currentVerdict(current, userID: userID)
        let carried = previous?.viewerReview ?? previous.flatMap { initialMemory($0, userID: userID, now: now) }
        guard var memory = carried else { return initialMemory(current, userID: userID, now: now) }
        let head = current.summary.headSHA
        guard verdict != memory.verdict else {
            // Same verdict, but the user commented or reviewed again after the head moved: it now applies to the
            // new head (a Bitbucket re-review is often just another comment).
            if verdict != nil, head != nil, memory.verdictHeadSHA != head,
               let activity = latestOwnActivity(current, userID: userID), activity > (memory.verdictSeenAt ?? .distantPast)
            {
                memory.verdictHeadSHA = head
                memory.verdictSeenAt = now
            }
            return memory
        }
        let wasApproved = memory.verdict == .approved
        let headMoved = memory.verdictHeadSHA != nil && head != nil && memory.verdictHeadSHA != head
        memory.verdict = verdict
        memory.verdictHeadSHA = reviewCommit(current, verdict: verdict, userID: userID) ?? head
        memory.verdictSeenAt = now
        if verdict == .approved || verdict == .changesRequested {
            memory.lostApprovalAt = nil
            memory.lostApprovalHeadSHA = nil
        } else if wasApproved, headMoved, current.summary.state == .open {
            memory.lostApprovalAt = now
            memory.lostApprovalHeadSHA = head
        }
        if memory.verdict == nil, memory.lostApprovalAt == nil { return nil }
        return memory
    }

    /// The user's review state, or nil when the change request is not one they review (their own, or one they are
    /// only mentioned in).
    public static func status(of snapshot: ChangeRequestSnapshot, userID: String) -> ViewerReviewStatus? {
        guard !isAuthored(snapshot, userID: userID) else { return nil }
        let verdict = currentVerdict(snapshot, userID: userID)
        let memory = snapshot.viewerReview ?? initialMemory(snapshot, userID: userID, now: snapshot.fetchedAt)
        let isRequested = verdict == nil && snapshot.summary.involvement.contains(.reviewRequested)
        let needsReapproval = memory?.lostApprovalAt != nil && verdict != .approved
        guard verdict != nil || isRequested || needsReapproval else { return nil }

        let head = snapshot.summary.headSHA
        let verdictHead = memory?.verdict == verdict ? memory?.verdictHeadSHA : nil
        let headMoved = verdict != nil && verdictHead != nil && head != nil && verdictHead != head
        var rebased = false
        var commitsSince: Int?
        if headMoved, let verdictHead, !snapshot.commits.isEmpty {
            if let base = snapshot.commits.first(where: { $0.sha == verdictHead }) {
                if let baseDate = base.authoredAt {
                    commitsSince = snapshot.commits.filter { ($0.authoredAt ?? .distantPast) > baseDate }.count
                }
            } else {
                rebased = true
            }
        }

        let lane: ReviewLane
        if snapshot.summary.state != .open {
            lane = .closed
        } else if needsReapproval || isRequested {
            lane = .toReview
        } else if verdict == .approved {
            lane = .approved
        } else {
            lane = .changesRequested
        }
        return ViewerReviewStatus(
            lane: lane, verdict: verdict, isRequested: isRequested, needsReapproval: needsReapproval,
            headMovedSinceVerdict: headMoved, rebasedSinceVerdict: rebased, commitsSinceVerdict: commitsSince
        )
    }

    // MARK: Helpers

    /// Memory for a snapshot seen without history: the verdict applies to its review's commit, else the head.
    static func initialMemory(_ snapshot: ChangeRequestSnapshot, userID: String, now: Date) -> ViewerReviewMemory? {
        guard !isAuthored(snapshot, userID: userID), let verdict = currentVerdict(snapshot, userID: userID) else { return nil }
        return ViewerReviewMemory(
            verdict: verdict,
            verdictHeadSHA: reviewCommit(snapshot, verdict: verdict, userID: userID) ?? snapshot.summary.headSHA,
            verdictSeenAt: now
        )
    }

    /// The newest comment or review the user wrote on the change request.
    static func latestOwnActivity(_ snapshot: ChangeRequestSnapshot, userID: String) -> Date? {
        let comments = snapshot.threads.flatMap(\.comments).filter { $0.author.remoteID == userID }.map(\.createdAt)
        let reviews = snapshot.reviews.filter { $0.author.remoteID == userID }.compactMap(\.submittedAt)
        return (comments + reviews).max()
    }

    /// Commit of the user's latest submitted review with that verdict, when the provider records it (GitHub).
    static func reviewCommit(_ snapshot: ChangeRequestSnapshot, verdict: ReviewState?, userID: String) -> String? {
        guard let verdict else { return nil }
        return snapshot.reviews
            .filter { $0.author.remoteID == userID && $0.state == verdict && $0.commitSHA != nil }
            .max { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) }?
            .commitSHA
    }
}
