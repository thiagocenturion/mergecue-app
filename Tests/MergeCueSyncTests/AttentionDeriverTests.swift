import Foundation
import MergeCueCore
import Testing
@testable import MergeCueSync

@Suite("AttentionDeriver")
struct AttentionDeriverTests {
    typealias F = SyncFixture
    let cr = F.crKey()
    var t1: ThreadKey { F.threadKey(cr, "T1") }
    let account = F.account(F.github)
    let now = F.at(100)

    /// Derives events previous → current, then attention against `existing`.
    func items(
        _ previous: ChangeRequestSnapshot?, _ current: ChangeRequestSnapshot, existing: [AttentionItem] = [],
        baseline: Bool = false, knownFailing: Set<String> = []
    ) -> (events: [ChangeEvent], items: [AttentionItem]) {
        let events = EventDeriver.derive(
            previous: previous, current: current, currentUserID: F.me, isBaseline: baseline, now: now,
            knownFailingCheckNames: knownFailing
        )
        return (events, AttentionDeriver.apply(events: events, snapshot: current, existing: existing, account: account, now: now))
    }

    // MARK: Threads

    @Test func reviewerCommentOnMyCRCreatesThreadItem() throws {
        let current = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        let (events, result) = items(F.snapshot(cr), current)
        let item = try #require(result.first)
        #expect(result.count == 1)
        #expect(item.dedupeKey == AttentionItem.dedupeKey(thread: t1))
        #expect(item.id == AttentionItem.makeID(dedupeKey: item.dedupeKey))
        #expect(item.reason == .reviewComment)
        #expect(item.priority == .normal)
        #expect(item.thread == t1)
        #expect(item.eventIDs == events.map(\.id))
        #expect(item.isUnread)
        #expect(item.disposition == .open)
        #expect(item.updatedAt == F.at(10))
        #expect(item.createdAt == now)
        #expect(item.summary == "Sources/Retry.swift:12 Alice: Please add a backoff cap.")
        #expect(item.suggestedActions == AttentionReason.reviewComment.defaultSuggestedActions)
        #expect(item.title == "Add retries")
        #expect(item.repoFullPath == "acme/payments-api")
    }

    @Test func threadReasons() {
        func reason(_ comments: [ReviewComment]) -> AttentionReason {
            AttentionDeriver.threadReason(F.thread(t1, comments: comments), userID: F.me)
        }
        #expect(reason([F.comment("1", "Fix this")]) == .reviewComment)
        #expect(reason([F.comment("1", "Why this?")]) == .reviewerQuestion)
        #expect(reason([F.comment("1", "```suggestion\nx\n```")]) == .codeSuggestion)
        #expect(reason([F.comment("1", "```suggestion\nx\n```"), F.comment("2", "Also why?", at: 20)]) == .codeSuggestion)
        #expect(reason([F.comment("1", by: F.mona, "Note to self"), F.comment("2", "I disagree", at: 20)]) == .reply)
        #expect(reason([F.comment("1", "Why?"), F.comment("2", "Never mind, fine.", at: 20)]) == .reviewComment)
    }

    @Test func ownCommentsNeverCreateItems() {
        let current = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1", by: F.mona, "Heads-up")])])
        #expect(items(F.snapshot(cr), current).items.isEmpty)
    }

    @Test func threadWhoseLastCommentIsMineCreatesNothing() {
        // Reviewer commented and the user already replied between two polls.
        let current = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1"), F.comment("c2", by: F.mona, "Done", at: 20)])])
        #expect(items(F.snapshot(cr), current).items.isEmpty)
    }

    @Test func ownReplyLeavesExistingItemUntouched() {
        let first = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        let existing = items(F.snapshot(cr), first).items
        let replied = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1"), F.comment("c2", by: F.mona, "Done", at: 20)])])
        #expect(items(first, replied, existing: existing).items.isEmpty)
    }

    @Test func newReplyUpdatesSameItem() throws {
        let first = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        var existing = try #require(items(F.snapshot(cr), first).items.first)
        existing.isUnread = false
        existing.disposition = .acknowledged
        let second = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1"), F.comment("c2", by: F.bob, "Any update?", at: 40)])])
        let (events, result) = items(first, second, existing: [existing])
        let item = try #require(result.first)
        #expect(result.count == 1)
        #expect(item.id == existing.id)
        #expect(item.dedupeKey == existing.dedupeKey)
        #expect(item.eventIDs == events.map(\.id))
        #expect(item.updatedAt == F.at(40))
        #expect(item.reason == .reviewerQuestion)
        #expect(item.createdAt == existing.createdAt)
        // Incoming state is always open+unread; the store decides using its merge policy.
        #expect(item.disposition == .open)
        #expect(item.isUnread)
    }

    @Test func newActivityIsAlwaysNewerThanStoredItem() throws {
        let first = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1", at: 50)])])
        var existing = try #require(items(F.snapshot(cr), first).items.first)
        existing.updatedAt = F.at(60)
        // A reply whose provider timestamp is older than the stored activity time (clock skew).
        let second = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1", at: 50), F.comment("c2", at: 55)])])
        let item = try #require(items(first, second, existing: [existing]).items.first)
        #expect(item.updatedAt > existing.updatedAt)
    }

    @Test func threadsOnOthersCRsNeedParticipation() {
        let theirs: (ReviewThread) -> ChangeRequestSnapshot = {
            F.snapshot(self.cr, author: F.alice, involvement: [.reviewRequested], threads: [$0])
        }
        let foreign = F.thread(t1, comments: [F.comment("c1", by: F.bob, "Nit")])
        let base = F.snapshot(cr, author: F.alice, involvement: [.reviewRequested])
        #expect(items(base, theirs(foreign)).items.filter { $0.thread != nil }.isEmpty)
        let participated = F.thread(t1, comments: [F.comment("c1", by: F.mona, "Is this safe?"), F.comment("c2", by: F.alice, "Yes", at: 20)])
        let result = items(base, theirs(participated)).items.filter { $0.thread != nil }
        #expect(result.count == 1)
        #expect(result.first?.reason == .reply)
    }

    @Test func botCommentsAreLowPriority() {
        let current = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1", by: F.bot, "Coverage dropped")], resolved: nil)])
        #expect(items(F.snapshot(cr), current).items.first?.priority == .low)
    }

    @Test func resolvedThreadResolvesItem() throws {
        let open = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        let existing = items(F.snapshot(cr), open).items
        let resolved = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")], resolved: true)])
        let (events, result) = items(open, resolved, existing: existing)
        let item = try #require(result.first)
        #expect(item.disposition == .resolved)
        #expect(item.eventIDs.contains(try #require(events.first { $0.type == .threadResolved }).id))
        // Already resolved: nothing to write.
        #expect(items(resolved, resolved, existing: [item]).items.isEmpty)
    }

    @Test func commentOnAlreadyResolvedThreadCreatesNothing() {
        let current = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")], resolved: true)])
        #expect(items(F.snapshot(cr), current).items.isEmpty)
    }

    @Test func deletedThreadResolvesItem() {
        let open = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        let existing = items(F.snapshot(cr), open).items
        #expect(items(open, F.snapshot(cr), existing: existing).items.map(\.disposition) == [.resolved])
    }

    @Test func dismissedItemsAreNotReconciled() {
        let open = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        var existing = items(F.snapshot(cr), open).items
        existing[0].disposition = .dismissed
        let resolved = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")], resolved: true)])
        #expect(items(open, resolved, existing: existing).items.isEmpty)
    }

    @Test func outdatedAnchorRefreshesSummaryWithoutActivity() throws {
        let open = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        let existing = items(F.snapshot(cr), open).items
        let pushed = F.snapshot(cr, headSHA: "bbbb2222", threads: [F.thread(t1, comments: [F.comment("c1")], outdated: true)], commits: ["bbbb2222"])
        let item = try #require(items(open, pushed, existing: existing).items.first)
        #expect(item.summary.hasPrefix("[outdated] "))
        #expect(item.eventIDs == existing[0].eventIDs)
        #expect(item.updatedAt == existing[0].updatedAt)
    }

    // MARK: Checks

    @Test func failingCheckOnMyCRCreatesItem() throws {
        let current = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure)])
        let item = try #require(items(F.snapshot(cr), current).items.first)
        #expect(item.reason == .ciFailed)
        #expect(item.priority == .high)
        #expect(item.dedupeKey == AttentionItem.dedupeKey(changeRequest: cr, checkName: "build"))
        #expect(item.check == F.checkKey(cr, "1"))
        #expect(item.summary == "build: failed on aaaa111")
        #expect(item.suggestedActions.first == .investigateWithAI)
    }

    @Test func optionalCheckIsNormalPriority() {
        let current = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure, required: false)])
        #expect(items(F.snapshot(cr), current).items.first?.priority == .normal)
    }

    @Test func failingChecksOnOthersCRsAreIgnored() {
        let current = F.snapshot(cr, author: F.alice, involvement: [.reviewRequested], checks: [F.check(cr, id: "1", status: .failure)])
        #expect(items(F.snapshot(cr, author: F.alice, involvement: [.reviewRequested]), current).items.allSatisfy { $0.reason != .ciFailed })
    }

    @Test func retryFailureUpdatesSameItem() throws {
        let first = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure)])
        let existing = items(F.snapshot(cr), first).items
        let second = F.snapshot(cr, checks: [F.check(cr, id: "2", status: .failure, at: 80)])
        let item = try #require(items(first, second, existing: existing).items.first)
        #expect(item.id == existing[0].id)
        #expect(item.check == F.checkKey(cr, "2"))
        #expect(item.updatedAt == F.at(80))
    }

    @Test func recoveryResolvesCheckItem() throws {
        let failing = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure)])
        let existing = items(F.snapshot(cr), failing).items
        let green = F.snapshot(cr, checks: [F.check(cr, id: "2", status: .success, at: 80)])
        let (events, result) = items(failing, green, existing: existing)
        let item = try #require(result.first)
        #expect(result.count == 1)
        #expect(item.disposition == .resolved)
        #expect(item.eventIDs.last == events.first { $0.type == .ciRecovered }?.id)
    }

    @Test func vanishedCheckResolvesItem() {
        let failing = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure)])
        let existing = items(F.snapshot(cr), failing).items
        #expect(items(failing, F.snapshot(cr), existing: existing).items.map(\.disposition) == [.resolved])
    }

    @Test func pendingRerunKeepsItemOpen() {
        let failing = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure)])
        let existing = items(F.snapshot(cr), failing).items
        let pending = F.snapshot(cr, checks: [F.check(cr, id: "2", status: .inProgress, at: 80)])
        #expect(items(failing, pending, existing: existing).items.isEmpty)
    }

    // MARK: CR-level reasons

    @Test func changesRequestedUntilApproved() throws {
        let requested = F.snapshot(cr, reviews: [F.review("r1", .changesRequested, body: "Needs tests")])
        let (_, created) = items(F.snapshot(cr), requested)
        let item = try #require(created.first)
        #expect(item.reason == .changesRequested)
        #expect(item.priority == .high)
        #expect(item.summary == "Alice requested changes")
        #expect(item.dedupeKey == AttentionItem.dedupeKey(changeRequest: cr, reason: .changesRequested))
        let approved = F.snapshot(cr, reviews: [F.review("r1", .changesRequested), F.review("r2", .approved, at: 90)])
        let result = items(requested, approved, existing: created).items
        #expect(result.map(\.disposition) == [.resolved])
    }

    @Test func reviewerListVerdictOverridesOlderReview() {
        let snapshot = F.snapshot(cr, reviews: [F.review("r1", .changesRequested)], reviewers: [Reviewer(person: F.alice, state: .approved)])
        #expect(AttentionDeriver.outstandingChangeRequesters(snapshot, userID: F.me).isEmpty)
        let still = F.snapshot(cr, reviews: [F.review("r1", .changesRequested)], reviewers: [Reviewer(person: F.alice, state: .pending)])
        #expect(AttentionDeriver.outstandingChangeRequesters(still, userID: F.me) == [F.alice])
    }

    @Test func reviewRequestedCreatesAndResolves() throws {
        let base = F.snapshot(cr, author: F.alice, involvement: [])
        let requested = F.snapshot(cr, author: F.alice, involvement: [.reviewRequested])
        let created = items(base, requested).items
        let item = try #require(created.first)
        #expect(item.reason == .reviewRequested)
        #expect(item.summary == "Alice requested your review")
        #expect(items(requested, base, existing: created).items.map(\.disposition) == [.resolved])
    }

    @Test func readyToMergeCreatesLowPriorityItem() throws {
        let ready = F.snapshot(cr, readiness: .readyToMerge)
        let created = items(F.snapshot(cr), ready).items
        let item = try #require(created.first)
        #expect(item.reason == .readyToMerge)
        #expect(item.priority == .low)
        #expect(items(ready, F.snapshot(cr, readiness: .blocked(reasons: ["new thread"])), existing: created).items.map(\.disposition) == [.resolved])
    }

    @Test func mergedOrClosedResolvesEverything() {
        let open = F.snapshot(
            cr, threads: [F.thread(t1, comments: [F.comment("c1")])], checks: [F.check(cr, id: "1", status: .failure)]
        )
        let existing = items(F.snapshot(cr), open).items
        #expect(existing.count == 2)
        for state in [ChangeRequestState.merged, .closed] {
            var closed = open
            closed.summary.state = state
            let (events, result) = items(open, closed, existing: existing)
            #expect(result.count == 2)
            #expect(result.allSatisfy { $0.disposition == .resolved })
            let lifecycle = events.first { $0.type == .merged || $0.type == .closedWithoutMerge }
            #expect(result.allSatisfy { $0.eventIDs.contains(lifecycle?.id ?? "") })
        }
    }

    @Test func resolveAllForDepartedCR() {
        let open = F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])])
        var existing = items(F.snapshot(cr), open).items
        existing.append(AttentionItem(
            dedupeKey: "x", changeRequest: cr, repoFullPath: "acme/payments-api", title: "t", reason: .ciFailed, summary: "s",
            createdAt: now, updatedAt: now, disposition: .dismissed
        ))
        let resolved = AttentionDeriver.resolveAll(existing: existing, events: [])
        #expect(resolved.count == 1)
        #expect(resolved[0].disposition == .resolved)
    }

    // MARK: Baseline

    @Test func baselineCreatesItemsForActionableStateOnly() {
        let other = F.crKey(number: 7)
        let mine = F.snapshot(
            cr,
            threads: [
                F.thread(F.threadKey(cr, "open"), comments: [F.comment("c1")]),
                F.thread(F.threadKey(cr, "resolved"), comments: [F.comment("c2")], resolved: true),
                F.thread(F.threadKey(cr, "answered"), comments: [F.comment("c3"), F.comment("c4", by: F.mona, "Done", at: 20)]),
            ],
            checks: [F.check(cr, id: "1", status: .failure), F.check(cr, id: "2", name: "lint", status: .success)]
        )
        let (events, result) = items(nil, mine, baseline: true)
        #expect(events.allSatisfy { $0.isBaseline })
        #expect(Set(result.map(\.reason)) == [.reviewComment, .ciFailed])
        #expect(result.first { $0.thread != nil }?.thread == F.threadKey(cr, "open"))

        let requested = F.snapshot(other, author: F.alice, involvement: [.reviewRequested])
        let events2 = EventDeriver.derive(previous: nil, current: requested, currentUserID: F.me, isBaseline: true, now: now)
        let result2 = AttentionDeriver.apply(events: events2, snapshot: requested, existing: [], account: account, now: now)
        #expect(result2.map(\.reason) == [.reviewRequested])
    }

    @Test func itemsOfOtherChangeRequestsAreIgnored() {
        let otherCR = F.crKey(number: 7)
        let foreignItem = AttentionItem(
            dedupeKey: AttentionItem.dedupeKey(thread: F.threadKey(otherCR)), changeRequest: otherCR,
            repoFullPath: "acme/payments-api", title: "t", reason: .reviewComment, summary: "s",
            thread: F.threadKey(otherCR), createdAt: now, updatedAt: now
        )
        #expect(items(F.snapshot(cr), F.snapshot(cr), existing: [foreignItem]).items.isEmpty)
    }
}
