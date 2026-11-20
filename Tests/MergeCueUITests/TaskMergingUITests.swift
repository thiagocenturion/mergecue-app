import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@Suite("Add to Task / Merge into (D38)")
@MainActor
struct TaskMergingUITests {
    /// GitHub #42 (demo data): a CI failure with a task, and a "changes requested" review without one.
    private func scenario(_ model: AppModel) throws -> (review: AttentionItem, ciTask: TaskRecord) {
        let review = try #require(model.state.attention(.github, number: 42, reason: .changesRequested))
        let ci = try #require(model.state.attention(.github, number: 42, reason: .ciFailed))
        let task = try #require(model.activeTask(for: ci))
        #expect(model.activeTask(for: review) == nil)
        return (review, task)
    }

    private func startTask(_ model: AppModel, _ item: AttentionItem) async throws -> TaskID {
        let type = TaskType.inferred(from: item.reason) ?? .fixReview
        let result = try #require(await model.send(.createTask(attentionID: item.id, type: type)))
        return try #require(result.createdTaskID)
    }

    @Test func addRemoveAndMenus() async throws {
        let model = await makeModel()
        let (second, ciTask) = try scenario(model)
        let taskID = ciTask.id
        let first = try #require(model.state.attention.first { $0.id == ciTask.task.origin.attentionItemID })

        // The second item's change request has an open task: offered as a target, nothing attached yet.
        #expect(model.attachableTasks(for: second).map(\.id) == [taskID])
        #expect(model.attachingTask(for: second) == nil)

        await model.addConversation(second, to: taskID)
        let record = try #require(model.task(taskID))
        #expect(record.task.coveredAttentionIDs.contains(second.id))
        #expect(model.activeConversationTask(for: second)?.id == taskID)
        #expect(model.attachingTask(for: second)?.id == taskID)
        #expect(model.attachableTasks(for: second).isEmpty)
        #expect(model.coveredItems(for: record).map(\.id).first == first.id)
        // The main item is not "attached": no Remove from Task for it.
        #expect(model.attachingTask(for: first) == nil)

        await model.removeConversationFromTask(second)
        #expect(model.task(taskID)?.task.attachments.isEmpty == true)
        #expect(model.activeConversationTask(for: second) == nil)
        #expect(model.addableItems(for: try #require(model.task(taskID))).contains { $0.id == second.id })
    }

    @Test func mergeTwoTasks() async throws {
        let model = await makeModel()
        let (second, ciTask) = try scenario(model)
        let target = ciTask.id
        let source = try await startTask(model, second)
        let sourceRecord = try #require(model.task(source))
        #expect(model.mergeTargets(for: sourceRecord).map(\.id) == [target])

        _ = await model.send(.mergeTask(source, into: target))
        #expect(model.task(source)?.state == .dismissed)
        let merged = try #require(model.task(target))
        #expect(merged.task.attachment(for: second.id)?.mergedFromTaskID == source)
        #expect(model.activeConversationTask(for: second)?.id == target)
    }

    @Test func coveredTitleUsesFileAndLine() {
        let anchor = DiffAnchor(path: "src/refund/refund.ts", line: 48)
        #expect(CoveredItemsCard.title(reason: .reviewComment, thread: nil, check: nil, anchor: anchor, snapshot: nil)
            == "\(AttentionReason.reviewComment.displayName) · refund.ts:48")
        #expect(!CoveredItemsCard.title(reason: .ciFailed, thread: nil, check: nil, anchor: nil, snapshot: nil).contains("—"))
    }
}
