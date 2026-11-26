import Foundation
import MergeCueCore
import Testing
@testable import MergeCueSync

/// The user's own review of others' change requests (D53): verdicts, the memory Sync carries forward, the Reviews
/// lanes, and the re-approval / "updated since your review" items and notifications.
@Suite("Viewer review (Reviews screen, D53)")
struct ViewerReviewTests {
    typealias F = SyncFixture
    let cr = F.crKey(F.bitbucket, number: 12)

    /// Alice's PR with the user as reviewer in `state` at `head`.
    func pr(_ state: ReviewState, head: String = "aaaa1111", commits: [String]? = nil, at seconds: TimeInterval = 0,
            involvement: Set<Involvement> = [.reviewRequested]) -> ChangeRequestSnapshot {
        F.snapshot(cr, author: F.alice, involvement: involvement, headSHA: head, updatedAt: F.at(seconds),
                   reviewers: [Reviewer(person: F.mona, state: state)], commits: commits)
    }

    /// Runs the memory forward like Sync does.
    func step(_ previous: ChangeRequestSnapshot?, _ current: ChangeRequestSnapshot, at seconds: TimeInterval = 0) -> ChangeRequestSnapshot {
        var next = current
        next.viewerReview = ViewerReview.nextMemory(previous: previous, current: current, userID: F.me, now: F.at(seconds))
        return next
    }

    // MARK: Verdicts and lanes

    @Test func verdictFollowsTheReviewerEntryThenReviewsThenApprovalsThenComments() {
        #expect(ViewerReview.currentVerdict(pr(.pending), userID: F.me) == nil)
        #expect(ViewerReview.currentVerdict(pr(.dismissed), userID: F.me) == .commented, "a dismissed review is stale, not gone")
        #expect(ViewerReview.currentVerdict(pr(.approved), userID: F.me) == .approved)

        var reviewed = F.snapshot(cr, author: F.alice, involvement: [.participated], reviews: [F.review("r1", by: F.mona, .changesRequested)])
        #expect(ViewerReview.currentVerdict(reviewed, userID: F.me) == .changesRequested)
        reviewed.reviews = []
        reviewed.approvals = ApprovalStatus(approvedBy: [F.mona])
        #expect(ViewerReview.currentVerdict(reviewed, userID: F.me) == .approved)

        let thread = F.thread(F.threadKey(cr), comments: [F.comment("c1", by: F.mona)])
        let commented = F.snapshot(cr, author: F.alice, involvement: [.participated], threads: [thread])
        #expect(ViewerReview.currentVerdict(commented, userID: F.me) == .commented)
        let requested = F.snapshot(cr, author: F.alice, involvement: [.reviewRequested], threads: [thread])
        #expect(ViewerReview.currentVerdict(requested, userID: F.me) == nil, "a comment alone does not answer a pending request")
    }

    @Test func ownAndMentionOnlyChangeRequestsAreNotReviews() {
        let mine = F.snapshot(cr, author: F.mona, involvement: [.authored], reviewers: [Reviewer(person: F.mona, state: .approved)])
        #expect(ViewerReview.status(of: mine, userID: F.me) == nil)
        #expect(ViewerReview.nextMemory(previous: nil, current: mine, userID: F.me, now: F.start) == nil)
        let mentioned = F.snapshot(cr, author: F.alice, involvement: [.mentioned])
        #expect(ViewerReview.status(of: mentioned, userID: F.me) == nil)
    }

    @Test func lanes() throws {
        #expect(ViewerReview.status(of: step(nil, pr(.pending)), userID: F.me)?.lane == .toReview)
        #expect(ViewerReview.status(of: step(nil, pr(.approved)), userID: F.me)?.lane == .approved)
        #expect(ViewerReview.status(of: step(nil, pr(.changesRequested)), userID: F.me)?.lane == .changesRequested)
        var merged = step(nil, pr(.approved))
        merged.summary.state = .merged
        #expect(ViewerReview.status(of: merged, userID: F.me)?.lane == .closed)
    }

    // MARK: Lost approvals

    @Test func approvalResetByAPushNeedsReapprovalUntilApprovedAgain() throws {
        let approved = step(nil, pr(.approved, head: "aaaa1111"))
        // Bitbucket resets approvals on push: the participant keeps `participated_on` (commented) without approval.
        let reset = step(approved, pr(.commented, head: "bbbb2222", commits: ["aaaa1111", "bbbb2222"], at: 60), at: 60)
        let memory = try #require(reset.viewerReview)
        #expect(memory.lostApprovalAt == F.at(60))
        #expect(memory.lostApprovalHeadSHA == "bbbb2222")
        let status = try #require(ViewerReview.status(of: reset, userID: F.me))
        #expect(status.lane == .toReview)
        #expect(status.needsReapproval)

        let reapproved = step(reset, pr(.approved, head: "bbbb2222", at: 120), at: 120)
        #expect(reapproved.viewerReview?.lostApprovalAt == nil)
        #expect(ViewerReview.status(of: reapproved, userID: F.me)?.lane == .approved)
    }

    @Test func unapprovingWithoutAPushIsNotALostApproval() throws {
        let approved = step(nil, pr(.approved))
        let unapproved = step(approved, pr(.commented, at: 60), at: 60)
        #expect(unapproved.viewerReview?.lostApprovalAt == nil)
        #expect(ViewerReview.status(of: unapproved, userID: F.me)?.lane == .changesRequested)
    }

    @Test func newCommitsAfterApprovalStayApprovedWithANote() throws {
        let approved = step(nil, pr(.approved, head: "aaaa1111"))
        var pushed = pr(.approved, head: "bbbb2222", at: 60)
        pushed.commits = [
            CommitInfo(sha: "aaaa1111", title: "a", authoredAt: F.at(0)),
            CommitInfo(sha: "bbbb2222", title: "b", authoredAt: F.at(50)),
        ]
        let status = try #require(ViewerReview.status(of: step(approved, pushed, at: 60), userID: F.me))
        #expect(status.lane == .approved)
        #expect(status.headMovedSinceVerdict)
        #expect(status.commitsSinceVerdict == 1)
    }

    // MARK: Updated since your review

    @Test func newCommitsAfterARequestForChangesAreFlaggedUntilReviewedAgain() throws {
        let asked = step(nil, pr(.changesRequested, head: "aaaa1111"))
        let pushed = step(asked, pr(.changesRequested, head: "bbbb2222", commits: ["bbbb2222"], at: 60), at: 60)
        let status = try #require(ViewerReview.status(of: pushed, userID: F.me))
        #expect(status.lane == .changesRequested, "author updates stay with your request (D56)")
        #expect(status.headMovedSinceVerdict)
        #expect(status.rebasedSinceVerdict, "the reviewed head is gone from the commit list")

        // The user comments again (same verdict): it now applies to the new head.
        var again = pr(.changesRequested, head: "bbbb2222", at: 120)
        again.threads = [F.thread(F.threadKey(cr), comments: [F.comment("c2", by: F.mona, at: 110)])]
        let reviewedAgain = step(pushed, again, at: 120)
        #expect(reviewedAgain.viewerReview?.verdictHeadSHA == "bbbb2222")
        let settled = try #require(ViewerReview.status(of: reviewedAgain, userID: F.me))
        #expect(settled.lane == .changesRequested)
        #expect(!settled.headMovedSinceVerdict)
    }

    // MARK: Events, attention, notifications (end to end through Sync)

    @Test func syncRaisesReapprovalAndResolvesTheRequestOnceReviewed() async throws {
        let h = try await SyncHarness(accounts: [F.bitbucket])
        let remote = h.remote(F.bitbucket)
        remote.put(pr(.pending))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await h.activeItems().map(\.reason) == [.reviewRequested])

        remote.update(cr) { $0 = $0.touched(60); $0.reviewers = [Reviewer(person: F.mona, state: .approved)] }
        await h.advance(900)
        #expect(try await h.activeItems().isEmpty, "approving answers the review request")

        // Alice pushes; the repository resets approvals.
        remote.update(cr) {
            $0 = $0.touched(1_000)
            $0.summary.headSHA = "bbbb2222"
            $0.commits = [CommitInfo(sha: "aaaa1111", title: "a"), CommitInfo(sha: "bbbb2222", title: "b")]
            $0.reviewers = [Reviewer(person: F.mona, state: .commented)]
        }
        await h.advance(900)
        let active = try await h.activeItems()
        #expect(active.map(\.reason) == [.reapprovalNeeded])
        #expect(try await h.events(cr).contains { $0.type == .approvalReset && !$0.isFromCurrentUser })
        let notification = try #require(h.notifier.delivered.last)
        #expect(notification.body.contains("Re-approval needed"))

        remote.update(cr) { $0 = $0.touched(2_000); $0.reviewers = [Reviewer(person: F.mona, state: .approved)] }
        await h.advance(900)
        await coordinator.stop()
        #expect(try await h.activeItems().isEmpty, "approving again resolves it")
    }

    @Test func pushAfterChangesRequestedRaisesUpdatedSinceReview() async throws {
        let h = try await SyncHarness(accounts: [F.bitbucket])
        let remote = h.remote(F.bitbucket)
        remote.put(pr(.changesRequested))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await h.activeItems().isEmpty)

        remote.update(cr) { $0 = $0.touched(60); $0.summary.headSHA = "bbbb2222" }
        await h.advance(900)
        let items = try await h.activeItems()
        #expect(items.map(\.reason) == [.updatedSinceReview])
        #expect(items.first?.summary == "New commits since you requested changes")
        await coordinator.stop()
    }

    @Test func updatesFollowTheirSwitch() async throws {
        let h = try await SyncHarness(accounts: [F.bitbucket])
        let remote = h.remote(F.bitbucket)
        remote.put(pr(.changesRequested))
        let coordinator = await h.makeCoordinator()
        await coordinator.setNotificationPreferences(NotificationPreferences(disabled: [.reviewUpdates]))
        await h.start(coordinator)
        remote.update(cr) { $0 = $0.touched(60); $0.summary.headSHA = "bbbb2222" }
        await h.advance(900)
        await coordinator.stop()
        #expect(try await h.activeItems().map(\.reason) == [.updatedSinceReview], "the item exists either way")
        #expect(h.notifier.delivered.isEmpty)
    }

    // MARK: Merge notifications (opt-in)

    @Test func mergeOfAReviewedChangeRequestNotifiesOnlyWhenSwitchedOn() {
        let before = step(nil, pr(.approved))
        var after = pr(.approved, at: 60)
        after.summary.state = .merged
        after = step(before, after, at: 60)
        let events = EventDeriver.derive(previous: before, current: after, currentUserID: F.me, isBaseline: false, now: F.at(60))
        #expect(events.map(\.type).contains(.merged))
        func notify(_ preferences: NotificationPreferences) -> [GroupedNotification] {
            NotificationGrouper.group(newEvents: events, attentionUpserts: [], existing: [:], snapshots: [after.key: after],
                                      account: F.account(F.bitbucket), preferences: preferences, now: F.at(60))
        }
        #expect(notify(.allEnabled).isEmpty, "off by default")
        let on = NotificationPreferences.allEnabled.setting(.reviewedMerged, enabled: true)
        let notification = notify(on)
        #expect(notification.count == 1)
        #expect(notification.first?.title.hasPrefix("Merged · ") == true)
    }

    @Test func optInCategoriesEncodeOnlyWhenEnabled() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let defaults = NotificationPreferences.allEnabled
        #expect(!defaults.isEnabled(.reviewedMerged))
        #expect(defaults.isEnabled(.reviewUpdates))
        #expect(String(decoding: try encoder.encode(defaults), as: UTF8.self) == #"{"disabled":[]}"#)
        let on = defaults.setting(.reviewedMerged, enabled: true)
        let data = try encoder.encode(on)
        #expect(String(decoding: data, as: UTF8.self) == #"{"disabled":[],"enabled":["reviewed_merged"]}"#)
        #expect(try JSONDecoder().decode(NotificationPreferences.self, from: data) == on)
        #expect(!on.setting(.reviewedMerged, enabled: false).isEnabled(.reviewedMerged))
    }
}
