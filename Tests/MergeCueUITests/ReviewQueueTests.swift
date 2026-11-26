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
        let updated = try #require(entry(queue, .gitlab, 322))
        #expect(updated.lane == .changesRequested && updated.hasUpdates, "new commits since your review stay with your request")
        #expect(queue.changesRequested.first?.key.number == 322, "author updates come first")
        #expect(entry(queue, .github, 318)?.status.isRequested == true)
        #expect(entry(queue, .github, 64)?.lane == .changesRequested)
        #expect(entry(queue, .github, 64)?.hasUpdates == false)
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
        #expect(ReviewText.summaryLine(queue) == "\(queue.toReview.count) to review · 2 changes requested · 2 approved")
        #expect(queue.needsYouCount == queue.toReview.count + 1)
        for text in queue.all.map({ ReviewText.chip($0).text }) + [ReviewText.summaryLine(queue)] {
            #expect(!text.contains("\u{2014}"), "no em dashes in UI copy")
        }
    }

    @Test func repliesFromTheAuthorFlagTheRequestedChanges() throws {
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
        #expect(moved.lane == .changesRequested && moved.hasUpdates)
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

    // MARK: D54: mine vs others

    @Test func popoverScopeFiltersRowsButNotCounts() async {
        let model = await makeModel()
        let total = model.sections.count(.needsYou)
        model.inboxFilter.scope = .mine
        let mine = model.popoverSections.items(.needsYou)
        #expect(!mine.isEmpty && mine.count < total)
        let involvement = Dictionary(model.state.changeRequests.map { ($0.key, $0.summary.involvement) }, uniquingKeysWith: { a, _ in a })
        #expect(mine.allSatisfy { involvement[$0.changeRequest]?.contains(.authored) == true })
        #expect(model.sections.count(.needsYou) == total, "the badge keeps counting everything")
        #expect(model.needsYouCount == total)
        model.inboxFilter.scope = .all
        #expect(model.popoverSections == model.sections)
    }

    @Test func othersPullRequestsOpenInReviews() async throws {
        let model = await makeModel()
        let theirs = try #require(model.state.changeRequests.first { $0.key.kind == .bitbucketCloud && $0.key.number == 12 })
        model.showChangeRequest(theirs.key)
        #expect(model.screen == .reviews)
        #expect(model.selectedChangeRequestID == theirs.id)
        let mine = try #require(model.state.changeRequests.first { $0.summary.involvement.contains(.authored) })
        model.showChangeRequest(mine.key)
        #expect(model.screen == .changeRequests)
    }

    @Test func pullRequestsScreenListsOnlyYourOwn() async {
        let model = await makeModel()
        let items = ChangeRequestQueryUI.run(state: model.state, filter: model.changeRequestFilter).flatMap(\.items)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.summary.involvement.contains(.authored) })
    }

    // MARK: D56: Ready and the Reviews filter

    @Test func readyToMergeIsReadyNotNeedsYou() throws {
        var state = previewState()
        let index = try #require(state.attention.firstIndex { $0.reason == .readyToMerge })
        state.attention[index].disposition = .open
        let item = state.attention[index]
        let sections = PopoverDerivation.derive(from: state, now: testNow)
        #expect(sections.ready.contains { $0.source == .attention(item.id) && $0.section == .ready })
        #expect(!sections.needsYou.contains { $0.source == .attention(item.id) })
        let needsAction = InboxQuery.run(state: state, filter: InboxFilter(status: .needsAction, collapseRead: false), now: testNow)
        #expect(!needsAction.visibleItems.contains { $0.id == item.id }, "the Needs you filter matches the Needs you count")
    }

    @Test func viewAllReadyOpensYourReadyPullRequest() async throws {
        let model = await makeModel()
        let ready = try #require(model.sections.ready.first { if case .attention = $0.source { true } else { false } })
        model.showAll(.ready)
        #expect(model.screen == .changeRequests)
        #expect(model.selectedChangeRequestID == ready.changeRequest.id)
    }

    @Test func inboxReviewsFilterShowsTheReviewLanes() async {
        let model = await makeModel()
        #expect(!model.popoverShowsReviewLanes)
        model.inboxFilter.scope = .reviewing
        #expect(model.popoverShowsReviewLanes)
        #expect(model.popoverRows.isEmpty, "the lanes replace the section rows")
        #expect(model.inboxReviewQueue.all.map(\.id) == model.reviewQueue.all.map(\.id))
        model.inboxFilter.provider = .gitlab
        #expect(!model.inboxReviewQueue.isEmpty)
        #expect(model.inboxReviewQueue.all.allSatisfy { $0.key.kind == .gitlab })
        for lane in ReviewQueue.lanes {
            #expect(!lane.title.contains("\u{2014}"))
        }
    }
}
