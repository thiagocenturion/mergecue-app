import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore
import Testing
@testable import MergeCueEngine

@Suite("One task for several items (D38)")
struct TaskMergingTests {
    @Test("a CI failure added to a review task is linked, quoted and listed in get_task")
    func attachCIFailureToReviewTask() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        let updated = try await h.engine.attachToTask(task.id, attentionIDs: [h.checkItemID])

        #expect(updated.version == task.version + 1)
        #expect(updated.coveredAttentionIDs == [h.threadItemID, h.checkItemID])
        let attachment = try #require(updated.attachment(for: h.checkItemID))
        #expect(attachment.reason == .ciFailed)
        #expect(attachment.check != nil)
        #expect(try await h.db.attentionItem(id: h.checkItemID)?.linkedTaskID == task.id)

        // Starting a task on the attached item returns the same task (one active task per item).
        let again = try await h.engine.createTask(fromAttention: h.checkItemID)
        #expect(again.id == task.id)

        let context = try await h.ok(GetTaskParams(taskID: task.id))
        let items = try #require(context.attachedItems)
        #expect(items.map(\.attentionID) == [h.checkItemID])
        #expect(items.first?.checkID != nil)
        #expect(context.instructions.contains { $0.contains("attached_items") })
        #expect(context.untrustedFields?.contains("attached_items[].untrusted_content") == true)

        let notes = try await h.db.activities(task: task.id).filter { $0.kind == .note }
        #expect(notes.contains { $0.message.contains("It now covers 2 items") })
    }

    @Test("adding to a working task bumps the version so the agent re-reads get_task")
    func attachWhileWorking() async throws {
        let h = try await Harness.make()
        let (task, claim) = try await h.claimedTask()
        _ = try await h.engine.attachToTask(task.id, attentionIDs: [h.checkItemID])
        let code = await h.errorCode(UpdateTaskParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version,
                                                      phase: .editing, message: "Still working"))
        #expect(code == .versionConflict)
        let reread = try await h.ok(GetTaskParams(taskID: task.id))
        #expect(reread.state == .working)
        #expect(reread.attachedItems?.count == 1)
    }

    @Test("items from another change request are refused; repeats are no-ops")
    func sameChangeRequestOnly() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        let other = try await h.seed(Fixture.github, number: 43)
        await #expect(throws: EngineError.self) {
            try await h.engine.attachToTask(task.id, attentionIDs: [other.check.id])
        }
        let same = try await h.engine.attachToTask(task.id, attentionIDs: [h.threadItemID])
        #expect(same.version == task.version)
        #expect(same.attachments.isEmpty)
    }

    @Test("an item that started another active task is refused until that task ends")
    func originItemsStayWithTheirTask() async throws {
        let h = try await Harness.make()
        let review = try await h.engine.createTask(fromAttention: h.threadItemID)
        let ci = try await h.engine.createTask(fromAttention: h.checkItemID)
        await #expect(throws: EngineError.self) {
            try await h.engine.attachToTask(review.id, attentionIDs: [h.checkItemID])
        }
        _ = try await h.engine.cancelTask(ci.id)
        let updated = try await h.engine.attachToTask(review.id, attentionIDs: [h.checkItemID])
        #expect(updated.attachments.count == 1)
        #expect(try await h.db.attentionItem(id: h.checkItemID)?.linkedTaskID == review.id)
    }

    @Test("finished tasks take no items")
    func finishedTasksRefuse() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        _ = try await h.engine.cancelTask(task.id)
        await #expect(throws: EngineError.self) {
            try await h.engine.attachToTask(task.id, attentionIDs: [h.checkItemID])
        }
    }

    @Test("remove from task unlinks the item; the main item cannot be removed")
    func detach() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        _ = try await h.engine.attachToTask(task.id, attentionIDs: [h.checkItemID])
        let detached = try await h.engine.detachFromTask(task.id, attentionID: h.checkItemID)
        #expect(detached.attachments.isEmpty)
        #expect(try await h.db.attentionItem(id: h.checkItemID)?.linkedTaskID == nil)
        await #expect(throws: EngineError.self) {
            try await h.engine.detachFromTask(task.id, attentionID: h.threadItemID)
        }
    }

    @Test("merging a waiting task moves its items with their captured context and dismisses it")
    func mergeTasks() async throws {
        let h = try await Harness.make()
        let review = try await h.engine.createTask(fromAttention: h.threadItemID)
        let ci = try await h.engine.createTask(fromAttention: h.checkItemID)
        let merged = try await h.engine.mergeTask(ci.id, into: review.id)

        #expect(merged.coveredAttentionIDs == [h.threadItemID, h.checkItemID])
        let moved = try #require(merged.attachment(for: h.checkItemID))
        #expect(moved.mergedFromTaskID == ci.id)
        #expect(moved.quoted == ci.trigger.quoted)
        #expect(try await h.task(ci.id).state == .dismissed)
        #expect(try await h.db.attentionItem(id: h.checkItemID)?.linkedTaskID == review.id)
        let dismissal = try await h.db.activities(task: ci.id).last
        #expect(dismissal?.kind == .dismissed)
        #expect(dismissal?.data["merged_into"] == review.id.rawValue)
    }

    @Test("a task an agent is working on cannot be merged away, but can receive a merge")
    func mergeRefusedWhileWorking() async throws {
        let h = try await Harness.make()
        let (working, _) = try await h.claimedTask()
        let ci = try await h.engine.createTask(fromAttention: h.checkItemID)
        await #expect(throws: EngineError.self) {
            try await h.engine.mergeTask(working.id, into: ci.id)
        }
        let target = try await h.engine.mergeTask(ci.id, into: working.id)
        #expect(target.state == .working)
        #expect(target.coveredAttentionIDs.count == 2)
    }

    @Test("tasks stored before D38 decode with no attachments")
    func decodesLegacyTasks() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        let encoder = JSONEncoder()
        var json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(task)) as? [String: Any])
        #expect(json["attachments"] != nil)
        json["attachments"] = nil
        let legacy = try JSONDecoder().decode(MCTask.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.attachments.isEmpty)
        #expect(legacy.id == task.id)
    }
}

@Suite("Status set by hand (D40)")
struct ManualStatusTests {
    @Test("in progress by hand has no lease and never goes stale; done acknowledges the items")
    func manualProgressAndDone() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        let working = try await h.engine.startTaskManually(task.id)
        #expect(working.state == .working)
        #expect(working.lease == nil)
        #expect(try await h.db.activities(task: task.id).last?.kind == .startedManually)

        h.clock.advance(by: 3_600)
        _ = await h.engine.sweepExpiredLeases()
        #expect(try await h.task(task.id).state == .working)

        let done = try await h.engine.markTaskDone(task.id)
        #expect(done.state == .done)
        let item = try #require(try await h.db.attentionItem(id: h.threadItemID))
        #expect(!item.isActionable(now: h.clock.now))
    }

    @Test("a waiting task can be marked done directly, and a working one sent back to waiting")
    func directTransitions() async throws {
        let h = try await Harness.make()
        let waiting = try await h.engine.createTask(fromAttention: h.checkItemID)
        #expect(try await h.engine.markTaskDone(waiting.id).state == .done)
        let (claimed, _) = try await h.claimedTask()
        let back = try await h.engine.retryTask(claimed.id)
        #expect(back.state == .waitingForAgent)
        #expect(back.lease == nil)
    }
}
