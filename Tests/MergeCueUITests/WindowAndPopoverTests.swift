import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@Suite("Detail tabs, sidebar and popover tabs (D48)")
@MainActor
struct WindowAndPopoverTests {
    @Test func tabsOpenOnSelectionAndCloseToTheirNeighbour() async throws {
        let model = await makeModel()
        let ids = model.state.attention.filter { $0.disposition == .open }.prefix(3).map(\.id)
        try #require(ids.count == 3)
        #expect(model.detailTabsEnabled == nil)
        model.selectedAttentionID = ids[0]
        #expect(model.inboxTabs.isEmpty, "No tabs until the owner turns them on")
        model.detailTabsEnabled = true
        #expect(model.inboxTabs == [ids[0]])
        model.selectedAttentionID = ids[1]
        model.selectedAttentionID = ids[2]
        model.selectedAttentionID = ids[1]
        #expect(model.inboxTabs == ids)
        model.closeInboxDetail(ids[1])
        #expect(model.inboxTabs == [ids[0], ids[2]])
        #expect(model.selectedAttentionID == ids[2])
        model.closeInboxDetail(ids[2])
        model.closeInboxDetail(ids[0])
        #expect(model.selectedAttentionID == nil)
        model.selectedAttentionID = ids[0]
        model.detailTabsEnabled = false
        #expect(model.inboxTabs.isEmpty)
        model.closeInboxDetail(ids[0])
        #expect(model.selectedAttentionID == nil)
    }

    @Test func sidebarCollapseAndTabChoiceArePersisted() async {
        let preferences = PreferenceStore.inMemory()
        var environment = AppEnvironment.fixed(now: testNow)
        environment.preferences = preferences
        let model = AppModel(backend: MergeCuePreview.makeBackend(variant: .standard, now: testNow), environment: environment)
        model.sidebarCollapsed = true
        model.detailTabsEnabled = false
        let relaunched = AppModel(backend: MergeCuePreview.makeBackend(variant: .standard, now: testNow), environment: environment)
        #expect(relaunched.sidebarCollapsed)
        #expect(relaunched.detailTabsEnabled == false)
    }

    @Test func pullRequestTabHasNoInboxRowsAndApprovalsHaveCounts() async throws {
        let model = await makeModel()
        #expect(!model.popoverRows.isEmpty)
        model.popoverTab = .pullRequests
        #expect(model.popoverRows.isEmpty)
        let approved = try #require(model.state.changeRequests.first { !ApprovalDerivation.approvers($0).people.isEmpty })
        let summary = try #require(model.approvalSummary(approved.key))
        #expect(summary.short == (approved.approvals.requiredCount.map { "\(summary.count)/\($0)" } ?? "\(summary.count)"))
    }

    @Test func ownerProfileUsesTheFirstAvatarAndInitials() async {
        let model = await makeModel()
        let profile = model.ownerProfile
        #expect(!profile.initials.isEmpty)
        #expect(profile.avatarURL == model.state.accounts.first { $0.account.avatarURL != nil }?.account.avatarURL)
    }
}

@Suite("Resizable columns (D49)")
@MainActor
struct SplitWidthTests {
    @Test func draggedWidthsArePerScreenPersistedAndResettable() {
        var environment = AppEnvironment.fixed(now: testNow)
        environment.preferences = .inMemory()
        let model = AppModel(backend: MergeCuePreview.makeBackend(variant: .standard, now: testNow), environment: environment)
        #expect(model.splitWidth("inbox") == nil)
        model.setSplitWidth("inbox", 520)
        model.setSplitWidth("pullRequests", 300)
        let relaunched = AppModel(backend: MergeCuePreview.makeBackend(variant: .standard, now: testNow), environment: environment)
        #expect(relaunched.splitWidth("inbox") == 520)
        #expect(relaunched.splitWidth("pullRequests") == 300)
        relaunched.setSplitWidth("inbox", nil)
        #expect(relaunched.splitWidth("inbox") == nil)
    }
}
