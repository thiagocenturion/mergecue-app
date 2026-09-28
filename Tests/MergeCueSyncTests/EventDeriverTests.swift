import Foundation
import MergeCueCore
import Testing
@testable import MergeCueSync

@Suite("EventDeriver")
struct EventDeriverTests {
    typealias F = SyncFixture
    let cr = F.crKey()
    var t1: ThreadKey { F.threadKey(cr, "T1") }
    let now = F.at(100)

    func derive(
        _ previous: ChangeRequestSnapshot?, _ current: ChangeRequestSnapshot, baseline: Bool = false,
        knownFailing: Set<String> = []
    ) -> [ChangeEvent] {
        EventDeriver.derive(
            previous: previous, current: current, currentUserID: F.me, isBaseline: baseline, now: now,
            knownFailingCheckNames: knownFailing
        )
    }

    func types(_ events: [ChangeEvent]) -> [ChangeEventType] { events.map(\.type) }

    // MARK: Comments

    @Test func newRootCommentIsReviewComment() throws {
        let before = F.snapshot(cr)
        let after = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        let events = derive(before, after)
        let event = try #require(events.first)
        #expect(events.count == 1)
        #expect(event.type == .reviewComment)
        #expect(event.thread == t1)
        #expect(event.commentID == "c1")
        #expect(event.objectID == ChangeEvent.commentObjectID(thread: t1, commentID: "c1"))
        #expect(event.actor == F.alice)
        #expect(!event.isFromCurrentUser)
        #expect(!event.isBaseline)
        #expect(event.occurredAt == F.at(10))
        #expect(event.detectedAt == now)
        #expect(event.commentKind == .comment)
        #expect(event.summary.hasPrefix("Alice commented:"))
        #expect(event.nativeRefs["path"] == "Sources/Retry.swift")
        #expect(event.id == ChangeEvent.makeID(account: cr.account, changeRequest: cr, type: .reviewComment, objectID: event.objectID, objectVersion: event.objectVersion))
    }

    @Test func newCommentInExistingThreadIsReply() {
        let before = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        let after = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1"), F.comment("c2", by: F.bob, "Agreed", at: 20, replyTo: "c1")])])
        let events = derive(before, after)
        #expect(types(events) == [.reply])
        #expect(events.first?.thread == t1)
        #expect(events.first?.commentID == "c2")
    }

    @Test func unchangedSnapshotProducesNothing() {
        let snapshot = F.snapshot(
            cr, threads: [F.thread(t1, comments: [F.comment("c1")])],
            checks: [F.check(cr, id: "1", status: .failure)], reviews: [F.review("r1", .changesRequested)],
            readiness: .readyToMerge
        )
        #expect(derive(snapshot, snapshot).isEmpty)
    }

    @Test func editedCommentDoesNotDuplicate() {
        var edited = F.comment("c1", "Please add a backoff cap. (edited)")
        edited.updatedAt = F.at(50)
        let before = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        let after = F.snapshot(cr, threads: [F.thread(t1, comments: [edited])])
        #expect(derive(before, after).isEmpty)
        // Re-deriving from scratch yields the same id as the original event.
        let original = derive(nil, before)[0]
        let rederived = derive(nil, after)[0]
        #expect(original.id == rederived.id)
    }

    @Test func eventIDsAreStableAcrossDerivations() {
        let before = F.snapshot(cr)
        let after = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        #expect(derive(before, after).map(\.id) == derive(before, after).map(\.id))
        #expect(derive(before, after).map(\.id) == derive(nil, after).map(\.id))
    }

    @Test func ownCommentsAreFlagged() {
        let before = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        let after = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1"), F.comment("c2", by: F.mona, "Done", at: 20)])])
        let events = derive(before, after)
        #expect(types(events) == [.reply])
        #expect(events[0].isFromCurrentUser)
    }

    @Test func systemCommentsAreSkipped() {
        let after = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("s1", "added 1 commit", kind: .system)])])
        #expect(derive(F.snapshot(cr), after).isEmpty)
    }

    @Test func commentKindsAreClassified() {
        let after = F.snapshot(cr, threads: [
            F.thread(F.threadKey(cr, "A"), comments: [F.comment("q", "Why not reuse the helper?")]),
            F.thread(F.threadKey(cr, "B"), comments: [F.comment("s", "```suggestion\nlet x = 1\n```")]),
            F.thread(F.threadKey(cr, "C"), comments: [F.comment("c", "Looks fine.")]),
            F.thread(F.threadKey(cr, "D"), comments: [F.comment("k", "Plain", kind: .question)]),
        ])
        let kinds = Dictionary(uniqueKeysWithValues: derive(F.snapshot(cr), after).map { ($0.commentID ?? "", $0.commentKind) })
        #expect(kinds["q"] == .question)
        #expect(kinds["s"] == .suggestion)
        #expect(kinds["c"] == .comment)
        #expect(kinds["k"] == .question)
    }

    @Test func issueAndReviewCommentsWithSameIDDoNotCollide() {
        let issueThread = ThreadKey.githubIssueComment(changeRequest: cr, commentID: "77")
        let diffThread = F.threadKey(cr, "PRRT_77")
        let after = F.snapshot(cr, threads: [
            F.thread(issueThread, comments: [F.comment("77")], resolved: nil),
            F.thread(diffThread, comments: [F.comment("77")]),
        ])
        let events = derive(F.snapshot(cr), after)
        #expect(events.count == 2)
        #expect(Set(events.map(\.id)).count == 2)
    }

    @Test func reviewSummaryThreadCoveredByVerdictIsNotAComment() {
        let summaryThread = ThreadKey.githubReviewSummary(changeRequest: cr, reviewID: "r1")
        let after = F.snapshot(
            cr, threads: [F.thread(summaryThread, comments: [F.comment("rv-body", "Please fix the retry loop")], resolved: nil)],
            reviews: [F.review("r1", .changesRequested, body: "Please fix the retry loop")]
        )
        #expect(types(derive(F.snapshot(cr), after)) == [.changeRequested])
        // A plain "commented" review body stays a review comment.
        let commented = F.snapshot(
            cr, threads: [F.thread(summaryThread, comments: [F.comment("rv-body", "Nice")], resolved: nil)],
            reviews: [F.review("r1", .commented)]
        )
        #expect(types(derive(F.snapshot(cr), commented)) == [.reviewComment])
    }

    // MARK: Threads

    @Test func threadResolutionTransition() {
        let open = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")], resolved: false)])
        let resolved = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")], resolved: true)])
        let events = derive(open, resolved)
        #expect(types(events) == [.threadResolved])
        #expect(events[0].thread == t1)
        #expect(!events[0].isFromCurrentUser)
        #expect(derive(resolved, resolved).isEmpty)
        #expect(derive(nil, resolved).map(\.type) == [.reviewComment])
    }

    // MARK: Reviews

    @Test func approvalAndChangeRequestFromReviews() {
        let before = F.snapshot(cr)
        let after = F.snapshot(cr, reviews: [
            F.review("r1", .changesRequested, body: "Needs tests"),
            F.review("r2", by: F.bob, .approved),
            F.review("r3", by: F.bob, .commented),
        ])
        let events = derive(before, after)
        #expect(types(events) == [.changeRequested, .approval])
        #expect(events[0].objectID == ChangeEvent.reviewObjectID("r1"))
        #expect(events[0].summary == "Alice requested changes: Needs tests")
        #expect(events[1].actor == F.bob)
        #expect(derive(after, after).isEmpty)
    }

    @Test func reviewStateChangeOnSameReviewEmits() {
        let pending = F.snapshot(cr, reviews: [F.review("r1", .pending)])
        let approved = F.snapshot(cr, reviews: [F.review("r1", .approved)])
        #expect(types(derive(pending, approved)) == [.approval])
    }

    @Test func ownReviewIsFlagged() {
        let after = F.snapshot(cr, author: F.alice, involvement: [.reviewRequested], reviews: [F.review("r9", by: F.mona, .approved)])
        let events = derive(F.snapshot(cr, author: F.alice, involvement: [.reviewRequested]), after)
        #expect(types(events) == [.approval])
        #expect(events[0].isFromCurrentUser)
    }

    @Test func reviewerVerdictsWithoutReviewObjects() {
        let before = F.snapshot(cr, reviewers: [Reviewer(person: F.alice, state: .pending)])
        let after = F.snapshot(cr, reviewers: [Reviewer(person: F.alice, state: .changesRequested)])
        let events = derive(before, after)
        #expect(types(events) == [.changeRequested])
        #expect(events[0].objectID == ChangeEvent.reviewObjectID("reviewer:2001"))
        // Backed by a review object → reported once (by the review).
        let backed = F.snapshot(cr, reviews: [F.review("r1", .changesRequested)], reviewers: [Reviewer(person: F.alice, state: .changesRequested)])
        #expect(types(derive(before, backed)) == [.changeRequested])
    }

    // MARK: Checks

    @Test func checkTransitionIntoFailure() {
        let before = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .inProgress)])
        let after = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure, required: true)])
        let events = derive(before, after)
        #expect(types(events) == [.ciFailed])
        #expect(events[0].check == F.checkKey(cr, "1"))
        #expect(events[0].objectID == ChangeEvent.checkObjectID(F.checkKey(cr, "1")))
        #expect(events[0].nativeRefs["check_name"] == "build")
        #expect(events[0].summary == "build failed on aaaa111")
        #expect(events[0].occurredAt == F.at(20))
    }

    @Test func sameFailingRunDoesNotRepeat() {
        let failing = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure)])
        #expect(derive(failing, failing).isEmpty)
    }

    @Test func retryThatFailsAgainEmitsNewEvent() {
        let first = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure)])
        let second = F.snapshot(cr, checks: [F.check(cr, id: "2", status: .failure, at: 60)])
        let events = derive(first, second)
        #expect(types(events) == [.ciFailed])
        #expect(events[0].id != derive(nil, first)[0].id)
    }

    @Test func failureThenSuccessRecovers() {
        let failing = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure)])
        let green = F.snapshot(cr, checks: [F.check(cr, id: "2", status: .success, at: 60)])
        let events = derive(failing, green)
        #expect(types(events) == [.ciRecovered])
        #expect(events[0].summary.contains("passed again"))
    }

    @Test func failurePendingSuccessRecoversWithHistory() {
        let pending = F.snapshot(cr, checks: [F.check(cr, id: "2", status: .inProgress, at: 50)])
        let green = F.snapshot(cr, checks: [F.check(cr, id: "2", status: .success, at: 60)])
        #expect(derive(pending, green).isEmpty)
        #expect(types(derive(pending, green, knownFailing: ["build"])) == [.ciRecovered])
        // Known failing but already green before: no duplicate recovery.
        #expect(derive(green, green, knownFailing: ["build"]).isEmpty)
    }

    @Test func greenRerunsProduceNothing() {
        let green = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .success)])
        let rerunning = F.snapshot(cr, checks: [F.check(cr, id: "2", status: .queued, at: 40)])
        let greenAgain = F.snapshot(cr, checks: [F.check(cr, id: "2", status: .success, at: 60)])
        #expect(derive(green, rerunning).isEmpty)
        #expect(derive(rerunning, greenAgain).isEmpty)
        #expect(derive(green, greenAgain).isEmpty)
    }

    @Test func checksAreComparedPerName() {
        let before = F.snapshot(cr, checks: [
            F.check(cr, id: "1", name: "build", status: .failure),
            F.check(cr, id: "2", name: "lint", status: .success),
        ])
        let after = F.snapshot(cr, checks: [
            F.check(cr, id: "1", name: "build", status: .failure),
            F.check(cr, id: "3", name: "lint", status: .timedOut, at: 70),
            F.check(cr, id: "4", name: "test", status: .cancelled, at: 70),
        ])
        let events = derive(before, after)
        #expect(types(events) == [.ciFailed])
        #expect(events[0].nativeRefs["check_name"] == "lint")
    }

    @Test func latestRunPerNameWins() {
        let after = F.snapshot(cr, checks: [
            F.check(cr, id: "old", status: .failure, at: 10),
            F.check(cr, id: "new", status: .success, at: 60),
        ])
        #expect(derive(nil, after).isEmpty)
        #expect(EventDeriver.latestChecksByName(after.checks)["build"]?.key.remoteID == "new")
    }

    // MARK: Head / lifecycle / involvement

    @Test func forcePushIsReported() {
        let before = F.snapshot(cr, headSHA: "aaaa1111", threads: [F.thread(t1, comments: [F.comment("c1")])])
        let after = F.snapshot(
            cr, headSHA: "bbbb2222", threads: [F.thread(t1, comments: [F.comment("c1")], outdated: true)], commits: ["cccc3333", "bbbb2222"]
        )
        let events = derive(before, after)
        #expect(types(events) == [.headChanged])
        let event = events[0]
        #expect(event.objectID == ChangeEvent.headObjectID(sha: "bbbb2222"))
        #expect(event.nativeRefs["force_push"] == "true")
        #expect(event.nativeRefs["previous_head"] == "aaaa1111")
        #expect(event.nativeRefs["outdated_threads"] == "1")
        #expect(event.summary == "Force-pushed aaaa111 → bbbb222; 1 comment thread now outdated")
        #expect(event.isFromCurrentUser, "head changes on the user's own CR are attributed to the user")
    }

    @Test func newCommitsAreNotForcePush() {
        let before = F.snapshot(cr, headSHA: "aaaa1111")
        let after = F.snapshot(cr, author: F.mona, headSHA: "bbbb2222", commits: ["aaaa1111", "bbbb2222"])
        let event = derive(before, after)[0]
        #expect(event.type == .headChanged)
        #expect(event.nativeRefs["force_push"] == "false")
        let theirs = derive(F.snapshot(cr, author: F.alice, headSHA: "aaaa1111"), F.snapshot(cr, author: F.alice, headSHA: "bbbb2222"))
        #expect(theirs.first?.isFromCurrentUser == false)
    }

    @Test func mergedAndClosed() {
        let open = F.snapshot(cr)
        let merged = derive(open, F.snapshot(cr, state: .merged, updatedAt: F.at(90)))
        #expect(types(merged) == [.merged])
        #expect(merged[0].occurredAt == F.at(90))
        #expect(types(derive(open, F.snapshot(cr, state: .closed))) == [.closedWithoutMerge])
        #expect(derive(F.snapshot(cr, state: .merged), F.snapshot(cr, state: .merged)).isEmpty)
    }

    @Test func reviewRequested() {
        let before = F.snapshot(cr, author: F.alice, involvement: [])
        let after = F.snapshot(cr, author: F.alice, involvement: [.reviewRequested])
        let events = derive(before, after)
        #expect(types(events) == [.reviewRequested])
        #expect(!events[0].isFromCurrentUser)
        #expect(events[0].summary == "Alice requested your review")
        #expect(derive(after, after).isEmpty)
        #expect(types(derive(nil, after)) == [.reviewRequested])
    }

    @Test func readyToMerge() {
        let before = F.snapshot(cr, readiness: .checksGreen)
        let after = F.snapshot(cr, readiness: .readyToMerge)
        #expect(types(derive(before, after)) == [.readyToMerge])
        #expect(derive(after, after).isEmpty)
        #expect(derive(before, F.snapshot(cr, state: .merged, readiness: .readyToMerge)).map(\.type) == [.merged])
    }

    // MARK: Baseline

    @Test func baselineReportsCurrentStateFlagged() {
        let current = F.snapshot(
            cr,
            threads: [F.thread(t1, comments: [F.comment("c1"), F.comment("c2", by: F.mona, "ok", at: 20)])],
            checks: [F.check(cr, id: "1", status: .failure), F.check(cr, id: "2", name: "lint", status: .success)],
            reviews: [F.review("r1", .approved)],
            readiness: .readyToMerge
        )
        let events = derive(nil, current, baseline: true)
        #expect(types(events) == [.reviewComment, .reply, .approval, .ciFailed, .readyToMerge])
        #expect(events.allSatisfy { $0.isBaseline })
        #expect(events.filter(\.isFromCurrentUser).map(\.commentID) == ["c2"])
    }

    @Test func excerptIsRedactedAndBounded() {
        let token = "ghp_" + String(repeating: "a", count: 36)
        let body = "Use token \(token)\n" + String(repeating: "x", count: 500)
        let after = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1", body)])])
        let summary = derive(F.snapshot(cr), after)[0].summary
        #expect(!summary.contains(token))
        #expect(summary.utf8.count < 200)
        #expect(summary.hasSuffix("…"))
    }

    @Test func eventsCarryChangeRequestIdentity() {
        let gitlabCR = F.crKey(F.gitlab)
        let after = F.snapshot(gitlabCR, threads: [F.thread(F.threadKey(gitlabCR), comments: [F.comment("c1")])])
        let event = EventDeriver.derive(previous: nil, current: after, currentUserID: F.me, isBaseline: false, now: now)[0]
        #expect(event.providerKind == .gitlab)
        #expect(event.account == F.gitlab)
        #expect(event.repoFullPath == "acme/payments-api")
        #expect(event.number == 42)
        #expect(event.title == "Add retries")
    }
}
