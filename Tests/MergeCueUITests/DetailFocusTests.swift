import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@Suite("Opening details at a thread or the approvals (D51)")
@MainActor
struct DetailFocusTests {
    @Test func selectingAnInboxItemAsksToScrollToItsConversation() async throws {
        let model = await makeModel()
        let item = try #require(model.state.attention.first { $0.thread != nil && $0.disposition == .open })
        model.selectedAttentionID = item.id
        let request = try #require(model.detailFocusRequest)
        #expect(request.changeRequestID == item.changeRequest.id)
        #expect(request.target == .thread(try #require(item.thread)))
    }

    @Test func showPRDetailsFromAnItemScrollsToItsThread() async throws {
        let model = await makeModel()
        let item = try #require(model.state.attention.first { $0.thread != nil })
        model.showChangeRequest(item.changeRequest, thread: item.thread)
        #expect(model.screen == .changeRequests)
        #expect(model.selectedChangeRequestID == item.changeRequest.id)
        #expect(model.detailFocusRequest?.target == .thread(try #require(item.thread)))
    }

    @Test func approvalCardsOpenThePRAtItsApprovalsAndMarkThemSeen() async throws {
        let model = await makeModel()
        let approved = try #require(model.state.changeRequests.first {
            $0.summary.state == .open && $0.summary.involvement.contains(.authored) && !ApprovalDerivation.approvers($0).people.isEmpty
        })
        model.seenApprovals[approved.key.id] = []
        #expect(model.approvalHighlights.contains { $0.changeRequest == approved.key })
        model.showApprovals(approved.key)
        #expect(model.screen == .changeRequests)
        #expect(model.selectedChangeRequestID == approved.key.id)
        #expect(model.detailFocusRequest?.target == .reviewers)
        #expect(!model.approvalHighlights.contains { $0.changeRequest == approved.key })
    }

    @Test func anApprovalNotificationOpensTheApprovals() async throws {
        let model = await makeModel()
        let approved = try #require(model.state.changeRequests.first {
            $0.summary.state == .open && $0.summary.involvement.contains(.authored) && !ApprovalDerivation.approvers($0).people.isEmpty
        })
        model.seenApprovals[approved.key.id] = []
        model.openNotification(changeRequestID: approved.key.id, attentionIDs: [])
        #expect(model.detailFocusRequest?.target == .reviewers)
    }
}
