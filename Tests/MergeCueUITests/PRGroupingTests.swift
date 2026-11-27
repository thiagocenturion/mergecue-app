import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@Suite("Grouping by pull/merge request (D46)")
@MainActor
struct PRGroupingTests {
    @Test func inboxGroupsArePerChangeRequestAndExpandedByDefault() async throws {
        let model = await makeModel()
        let result = InboxQuery.run(state: model.state, filter: model.inboxFilter, now: testNow)
        let groups = result.prGroups(now: testNow)
        #expect(!groups.isEmpty)
        #expect(Set(groups.map(\.changeRequest)).count == groups.count)
        for group in groups { #expect(group.items.allSatisfy { $0.changeRequest == group.changeRequest }) }
        #expect(groups.allSatisfy { !model.isInboxGroupCollapsed($0.changeRequest) })
        // Groups with something to do come first.
        let active = groups.map { $0.items.contains { $0.isUnread || $0.isActionable(now: testNow) } }
        #expect(active == active.sorted { $0 && !$1 })
    }

    @Test func collapsingHidesRowsFromKeyboardAndShowingAnItemReopensIt() async throws {
        let model = await makeModel()
        let item = try #require(model.state.attention(.github, number: 42, reason: .changesRequested))
        #expect(model.inboxKeyboardOrder.contains(item.id))
        model.toggleInboxGroup(item.changeRequest)
        #expect(model.isInboxGroupCollapsed(item.changeRequest))
        #expect(!model.inboxKeyboardOrder.contains(item.id))
        model.showAttention(item.id)
        #expect(!model.isInboxGroupCollapsed(item.changeRequest))
        #expect(model.inboxKeyboardOrder.contains(item.id))
    }

    @Test func popoverGroupsKeepSectionOrderAndCollapse() async throws {
        let model = await makeModel()
        let groups = model.popoverGroups(.needsYou)
        let flattened = groups.flatMap(\.items).map(\.id)
        #expect(flattened == model.sections.items(.needsYou).prefix(AppModel.popoverRowLimit).map(\.id))
        let first = try #require(groups.first)
        model.togglePopoverGroup(first)
        #expect(model.isPopoverGroupCollapsed(first))
        #expect(!model.popoverRows.contains { row in first.items.contains { $0.id == row.id } })
        model.togglePopoverGroup(first)
        #expect(model.popoverRows.contains { $0.id == first.items[0].id })
    }
}

@Suite("Approval highlights (D47)")
@MainActor
struct ApprovalHighlightTests {
    @Test func existingApprovalsStartSeenAndNewOnesLightUpUntilSeen() async throws {
        let model = await makeModel()
        // Preview data loads with its approvals baselined: nothing is highlighted.
        #expect(model.approvalHighlights.isEmpty)
        let approved = try #require(model.state.changeRequests.first {
            $0.summary.state == .open && $0.summary.involvement.contains(.authored) && !ApprovalDerivation.approvers($0).people.isEmpty
        })
        // Forget them: they are new again.
        model.seenApprovals[approved.key.id] = []
        let highlight = try #require(model.approvalHighlights.first { $0.changeRequest == approved.key })
        #expect(highlight.headline.hasPrefix("Approved by "))
        #expect(model.approvalSummary(approved.key)?.isNew == true)
        model.markApprovalsSeen(approved.key)
        #expect(!model.approvalHighlights.contains { $0.changeRequest == approved.key })
        #expect(model.approvalSummary(approved.key)?.isNew == false)
    }

    @Test func aLaterChangeRequestReviewWithdrawsTheApproval() throws {
        let base = try #require(previewState().changeRequests.first)
        var snapshot = base
        let reviewer = Person(remoteID: "r9", username: "rev")
        snapshot.reviews = [
            Review(remoteID: "1", author: reviewer, state: .approved, submittedAt: testNow.addingTimeInterval(-600)),
            Review(remoteID: "2", author: reviewer, state: .changesRequested, submittedAt: testNow),
        ]
        snapshot.reviewers = []
        snapshot.approvals = ApprovalStatus(approvedBy: [reviewer])
        #expect(ApprovalDerivation.approvers(snapshot).people.isEmpty)
    }
}
