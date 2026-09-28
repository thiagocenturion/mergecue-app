import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@Suite("Popover section derivation")
struct SectionDerivationTests {
    @Test func standardPreviewCounts() {
        let sections = PopoverDerivation.derive(from: previewState(), now: testNow)
        #expect(sections.count(.needsYou) == 7)
        #expect(sections.count(.waitingForAgent) == 2)
        #expect(sections.count(.aiWorking) == 1)
        #expect(sections.count(.ready) == 1)
        #expect(sections.hasUrgent)
    }

    @Test func aiWorkingContainsOnlyTasksWithARealClaim() throws {
        var state = previewState()
        let claimed = try #require(state.task(in: .working))
        // A task that says "working" without an agent lease must never show as AI working.
        var unclaimed = claimed
        unclaimed.task.id = try #require(TaskID(rawValue: "mc_nolea5"))
        unclaimed.task.lease = nil
        state.tasks.append(unclaimed)

        let sections = PopoverDerivation.derive(from: state, now: testNow)
        #expect(sections.aiWorking.map(\.taskID) == [claimed.id])
        #expect(sections.aiWorking.allSatisfy { item in
            state.tasks.first { $0.id == item.taskID }.map { $0.task.state == .working && $0.task.lease != nil } ?? false
        })
        let fallback = try #require(sections.waitingForAgent.first { $0.taskID == unclaimed.id })
        #expect(fallback.reason == "Task ready to start")
    }

    @Test func waitingTasksNeverShowAsWorking() {
        let state = previewState()
        let sections = PopoverDerivation.derive(from: state, now: testNow)
        let waitingIDs = Set(state.tasks.filter { $0.task.state == .waitingForAgent }.map(\.id))
        #expect(!waitingIDs.isEmpty)
        #expect(sections.aiWorking.allSatisfy { !waitingIDs.contains($0.taskID ?? TaskID.generate()) })
        #expect(sections.waitingForAgent.contains { waitingIDs.contains($0.taskID ?? TaskID.generate()) })
    }

    @Test func needsYouExcludesItemsWithActiveTasks() throws {
        let state = previewState()
        let sections = PopoverDerivation.derive(from: state, now: testNow)
        let activeTaskIDs = Set(state.tasks.filter { !$0.task.isTerminal }.map(\.id))
        let linkedToActive = state.attention.filter { $0.linkedTaskID.map(activeTaskIDs.contains) ?? false }
        #expect(linkedToActive.count >= 5)
        let needsYouAttention = Set(sections.needsYou.compactMap(\.attentionID))
        for item in linkedToActive {
            #expect(!needsYouAttention.contains(item.id), "\(item.summary) has an active task")
        }
        // Tasks that wait for a user decision are listed instead of their items.
        let decisionTasks = Set(sections.needsYou.compactMap(\.taskID))
        #expect(decisionTasks == Set(state.tasks.filter { [.blocked, .failed].contains($0.task.state) }.map(\.id)))
    }

    @Test func itemReturnsToNeedsYouWhenItsTaskEnds() throws {
        var state = previewState()
        let item = try #require(state.attention(.bitbucketCloud, number: 128, reason: .reviewComment))
        let taskIndex = try #require(state.tasks.firstIndex { $0.id == item.linkedTaskID })
        #expect(!PopoverDerivation.derive(from: state, now: testNow).needsYou.contains { $0.attentionID == item.id })

        state.tasks[taskIndex].task.state = .cancelled
        #expect(PopoverDerivation.derive(from: state, now: testNow).needsYou.contains { $0.attentionID == item.id })
    }

    @Test func snoozedItemsComeBackWhenTheSnoozeExpires() throws {
        let state = previewState()
        let snoozed = try #require(state.attention.first { if case .snoozed = $0.disposition { true } else { false } })
        #expect(!PopoverDerivation.derive(from: state, now: testNow).needsYou.contains { $0.attentionID == snoozed.id })
        let later = testNow.addingTimeInterval(3 * 86_400)
        #expect(PopoverDerivation.derive(from: state, now: later).needsYou.contains { $0.attentionID == snoozed.id })
    }

    @Test func topRowsShowTheSameNumberOnAllThreeProvidersDistinctly() {
        let sections = PopoverDerivation.derive(from: previewState(), now: testNow)
        let top = Array(sections.needsYou.prefix(3))
        #expect(top.allSatisfy { $0.number == 42 && $0.repoFullPath == "acme/payments-api" })
        #expect(Set(top.map(\.providerKind)) == Set(ProviderKind.allCases))
        #expect(Set(top.map(\.changeRequest)).count == 3)
        #expect(Set(top.map(\.refText)) == ["acme/payments-api #42", "acme/payments-api !42"])
    }

    @Test func primaryActionsFollowTheReason() throws {
        let state = previewState()
        let sections = PopoverDerivation.derive(from: state, now: testNow)
        func action(_ kind: ProviderKind, _ number: Int, _ reason: AttentionReason) throws -> PrimaryAction {
            let item = try #require(state.attention(kind, number: number, reason: reason))
            return try #require(sections.needsYou.first { $0.attentionID == item.id }).primaryAction
        }
        #expect(try action(.github, 42, .changesRequested).title == "Fix with AI")
        #expect(try action(.gitlab, 42, .ciFailed).title == "Investigate with AI")
        #expect(try action(.bitbucketCloud, 42, .reviewerQuestion).title == "Draft reply")
        #expect(try action(.github, 318, .reviewRequested).title == "Review")
        #expect(sections.waitingForAgent.first { $0.reason == "Awaiting agent connection" }?.primaryAction.title == "Copy command")
        #expect(sections.ready.first?.primaryAction.title == "Review")
        #expect(PopoverDerivation.primaryAction(for: AttentionItem(
            dedupeKey: "x", changeRequest: try #require(state.attention.first).changeRequest, repoFullPath: "acme/x", title: "t",
            reason: .codeSuggestion, summary: "s", createdAt: testNow, updatedAt: testNow)).title == "Address with AI")
    }

    @Test func emptyAndErrorVariants() {
        let empty = PopoverDerivation.derive(from: previewState(.allCaughtUp), now: testNow)
        #expect(empty.isEmpty)
        #expect(!empty.hasUrgent)
        let noAccounts = previewState(.noAccounts)
        #expect(noAccounts.accounts.isEmpty)
        let errors = previewState(.authExpired)
        #expect(errors.accounts.contains { $0.status.state == .authExpired })
        #expect(errors.accounts.contains { $0.status.state == .offline })
        #expect(errors.accounts.contains { $0.status.state == .ok })
    }
}
