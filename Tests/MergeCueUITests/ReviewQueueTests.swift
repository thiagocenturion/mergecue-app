import Foundation
import MergeCueCore
import Testing
@testable import MergeCueUI

/// The Reviews screen's lanes over the preview data (D53).
@MainActor
@Suite("Reviews screen")
struct ReviewQueueTests {
    func entry(_ queue: ReviewQueue, _ kind: ProviderKind, _ number: Int) -> ReviewEntry? {
        queue.all.first { $0.key.kind == kind && $0.key.number == number }
    }

    @Test func previewPullRequestsLandInTheirLanes() throws {
        let queue = ReviewQueue.run(state: previewState(), filter: ChangeRequestFilter(), now: testNow)
        #expect(queue.toReview.first?.key.number == 12, "a lost approval comes first")
        #expect(try #require(entry(queue, .bitbucketCloud, 12)).status.needsReapproval)
        #expect(entry(queue, .gitlab, 322)?.lane == .toReview, "new commits since your review")
        #expect(entry(queue, .github, 318)?.status.isRequested == true)
        #expect(entry(queue, .github, 64)?.lane == .waitingOnAuthor)
        #expect(entry(queue, .bitbucketCloud, 133)?.lane == .approved)
        #expect(entry(queue, .github, 310)?.lane == .approved)
        #expect(!queue.all.contains { $0.snapshot.summary.involvement.contains(.authored) }, "your own PRs are not reviews")
    }

    @Test func chipsAndNotes() throws {
        let queue = ReviewQueue.run(state: previewState(), filter: ChangeRequestFilter(), now: testNow)
        #expect(ReviewText.chip(try #require(entry(queue, .bitbucketCloud, 12))).text == "Re-approval needed")
        #expect(ReviewText.chip(try #require(entry(queue, .gitlab, 322))).text == "1 new commit")
        #expect(ReviewText.chip(try #require(entry(queue, .github, 64))).text == "Asked for changes")
        #expect(ReviewText.chip(try #require(entry(queue, .github, 310))).text == "Approved by you")
        #expect(ReviewText.note(try #require(entry(queue, .bitbucketCloud, 133))) == "1 new commit since your approval")
        #expect(ReviewText.summaryLine(queue) == "\(queue.toReview.count) to review · 1 waiting · 2 approved")
        for text in queue.all.map({ ReviewText.chip($0).text }) + [ReviewText.summaryLine(queue)] {
            #expect(!text.contains("\u{2014}"), "no em dashes in UI copy")
        }
    }

    @Test func repliesFromTheAuthorMoveAWaitingReviewBack() throws {
        var state = previewState()
        let pr = try #require(state.changeRequests.first { $0.key.kind == .github && $0.key.number == 64 })
        let thread = ThreadKey(changeRequest: pr.key, remoteID: "t64", kind: .diffThread)
        state.attention.append(AttentionItem(
            dedupeKey: AttentionItem.dedupeKey(thread: thread), changeRequest: pr.key, repoFullPath: pr.summary.repository.fullPath,
            title: pr.summary.title, reason: .reply, summary: "Added the test", thread: thread, eventIDs: ["e"],
            createdAt: testNow, updatedAt: testNow, isUnread: true
        ))
        let queue = ReviewQueue.run(state: state, filter: ChangeRequestFilter(), now: testNow)
        let moved = try #require(entry(queue, .github, 64))
        #expect(moved.lane == .toReview)
        #expect(ReviewText.chip(moved).text == "1 new reply")
    }

    @Test func filtersApply() {
        let state = previewState()
        let bitbucket = ReviewQueue.run(state: state, filter: ChangeRequestFilter(provider: .bitbucketCloud), now: testNow)
        #expect(!bitbucket.isEmpty)
        #expect(bitbucket.all.allSatisfy { $0.key.kind == .bitbucketCloud })
        let search = ReviewQueue.run(state: state, filter: ChangeRequestFilter(searchText: "#322"), now: testNow)
        #expect(search.all.map(\.key.number) == [322])
    }

    @Test func reviewsScreenIsSecondWithItsShortcut() {
        #expect(MainScreen.allCases.firstIndex(of: .reviews) == 1)
        #expect(MainScreen.reviews.shortcutDigit == "2")
        #expect(Set(MainScreen.allCases.map(\.shortcutDigit)).count == MainScreen.allCases.count)
    }
}
