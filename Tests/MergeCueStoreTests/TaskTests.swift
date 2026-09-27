import Foundation
import MergeCueCore
import Testing
@testable import MergeCueStore

@Suite("Tasks, activities, artifacts, approvals")
struct TaskTests {
    // MARK: Tasks

    @Test func taskRoundTripsLosslessly() async throws {
        let database = try await StoreFixture.database()
        let task = StoreFixture.task()
        try await database.insertTask(task)
        #expect(try await database.task(task.id) == task)
        #expect(try await database.task(TaskID(rawValue: "mc_zzzzzz")!) == nil)
        #expect(try await database.taskIDs() == [task.id])
    }

    @Test func tasksAreFilteredByStateAndOrderedByUpdate() async throws {
        let database = try await StoreFixture.database()
        let waiting = StoreFixture.task("mc_aaaaaa", state: .waitingForAgent, updatedAt: StoreFixture.at(1))
        let working = StoreFixture.task("mc_bbbbbb", state: .working, updatedAt: StoreFixture.at(3))
        let done = StoreFixture.task("mc_cccccc", state: .done, updatedAt: StoreFixture.at(2))
        for task in [waiting, working, done] {
            try await database.insertTask(task)
        }
        #expect(try await database.tasks(states: nil) == [working, done, waiting])
        #expect(try await database.tasks(states: TaskState.active) == [working, waiting])
        #expect(try await database.tasks(states: [.done]) == [done])
        #expect(try await database.tasks(states: []).isEmpty)
    }

    @Test func duplicateTaskIDIsAUniqueViolation() async throws {
        let database = try await StoreFixture.database()
        try await database.insertTask(StoreFixture.task())
        do {
            try await database.insertTask(StoreFixture.task())
            Issue.record("expected a unique constraint violation")
        } catch let error as StoreError {
            #expect(error.isUniqueConstraintViolation)
            #expect(error.isConstraintViolation)
        }
    }

    @Test func taskRequiresItsAccount() async throws {
        let database = try MergeCueDatabase.inMemory()
        await #expect(throws: StoreError.notFound) {
            try await database.insertTask(StoreFixture.task())
        }
    }

    @Test func updateTaskIsACompareAndSwapOnVersion() async throws {
        let database = try await StoreFixture.database()
        let original = StoreFixture.task()
        try await database.insertTask(original)

        var claimed = original
        claimed.state = .working
        claimed.version = 2
        claimed.updatedAt = StoreFixture.at(10)
        try await database.updateTask(claimed, expectedVersion: 1)
        #expect(try await database.task(original.id) == claimed)
        #expect(try await database.tasks(states: [.working]) == [claimed])

        // A writer that still believes the task is at version 1 loses.
        var stale = original
        stale.state = .cancelled
        stale.version = 2
        await #expect(throws: StoreError.versionConflict(current: 2)) {
            try await database.updateTask(stale, expectedVersion: 1)
        }
        #expect(try await database.task(original.id) == claimed)
    }

    @Test func updateTaskValidatesVersionAndExistence() async throws {
        let database = try await StoreFixture.database()
        let task = StoreFixture.task()
        try await database.insertTask(task)
        await #expect(throws: StoreError.self) {
            try await database.updateTask(task, expectedVersion: 1) // version not bumped
        }
        var ghost = StoreFixture.task("mc_ghost1")
        ghost.version = 2
        await #expect(throws: StoreError.notFound) {
            try await database.updateTask(ghost, expectedVersion: 1)
        }
    }

    @Test func concurrentUpdatesThroughOneActorHaveExactlyOneWinner() async throws {
        let database = try await StoreFixture.database()
        let task = StoreFixture.task()
        try await database.insertTask(task)
        let outcomes = await race(count: 16) { index in
            var update = task
            update.version = 2
            update.resultSummary = "writer \(index)"
            try await database.updateTask(update, expectedVersion: 1)
        }
        #expect(outcomes.successes == 1)
        #expect(outcomes.conflicts == 15)
        #expect(outcomes.other == 0)
        #expect(try await database.task(task.id)?.version == 2)
    }

    @Test func concurrentUpdatesFromTwoConnectionsHaveExactlyOneWinner() async throws {
        let path = try StoreFixture.temporaryDatabasePath("race")
        let first = try MergeCueDatabase(path: path)
        let second = try MergeCueDatabase(path: path)
        try await first.upsertAccount(StoreFixture.account())
        let task = StoreFixture.task()
        try await first.insertTask(task)

        for round in 1...5 {
            let outcomes = await race(count: 2) { index in
                var update = task
                update.version = round + 1
                update.resultSummary = "connection \(index) round \(round)"
                try await (index == 0 ? first : second).updateTask(update, expectedVersion: round)
            }
            #expect(outcomes.successes == 1, "round \(round)")
            #expect(outcomes.conflicts == 1, "round \(round)")
            #expect(try await first.task(task.id)?.version == round + 1)
            #expect(try await second.task(task.id)?.version == round + 1)
        }
    }

    private struct RaceOutcome {
        var successes = 0
        var conflicts = 0
        var other = 0
    }

    private func race(count: Int, _ attempt: @escaping @Sendable (Int) async throws -> Void) async -> RaceOutcome {
        await withTaskGroup(of: Int.self) { group in
            for index in 0..<count {
                group.addTask {
                    do {
                        try await attempt(index)
                        return 0
                    } catch StoreError.versionConflict {
                        return 1
                    } catch {
                        return 2
                    }
                }
            }
            var outcome = RaceOutcome()
            for await result in group {
                switch result {
                case 0: outcome.successes += 1
                case 1: outcome.conflicts += 1
                default: outcome.other += 1
                }
            }
            return outcome
        }
    }

    // MARK: Activities

    @Test func activitiesAreAppendOnlyAndOrdered() async throws {
        let database = try await StoreFixture.database()
        let task = StoreFixture.task()
        try await database.insertTask(task)
        let second = StoreFixture.activity("act_2", at: 10, message: "Progress")
        let first = StoreFixture.activity("act_1", at: 0)
        try await database.appendActivity(second)
        try await database.appendActivity(first)
        #expect(try await database.activities(task: task.id) == [first, second])

        // Same id twice is refused; rows can be neither updated nor deleted.
        await #expect(throws: StoreError.self) { try await database.appendActivity(first) }
        await #expect(throws: StoreError.self) {
            try await database.executeForTesting("UPDATE task_activities SET kind = 'note'")
        }
        await #expect(throws: StoreError.self) {
            try await database.executeForTesting("DELETE FROM task_activities")
        }
        #expect(try await database.activities(task: task.id) == [first, second])
    }

    @Test func activityForAMissingTaskIsNotFound() async throws {
        let database = try await StoreFixture.database()
        await #expect(throws: StoreError.notFound) {
            try await database.appendActivity(StoreFixture.activity())
        }
    }

    // MARK: Artifacts and approvals

    @Test func artifactsRoundTrip() async throws {
        let database = try await StoreFixture.database()
        let task = StoreFixture.task()
        try await database.insertTask(task)
        let diff = Artifact(
            id: "art_0000000001", taskID: task.id, kind: .diff, createdAt: StoreFixture.at(1), title: "Diff",
            content: "--- a/x\n+++ b/x\n", metadata: ["files": "1"], reportedBy: .system
        )
        let tests = Artifact(
            id: "art_0000000002", taskID: task.id, kind: .testRun, createdAt: StoreFixture.at(2), title: "swift test",
            content: "All tests passed", reportedBy: .agent
        )
        try await database.insertArtifact(tests)
        try await database.insertArtifact(diff)
        #expect(try await database.artifact(id: diff.id) == diff)
        #expect(try await database.artifacts(task: task.id) == [diff, tests])
        #expect(try await database.artifact(id: "art_missing000") == nil)

        let orphan = Artifact(id: "art_0000000003", taskID: TaskID(rawValue: "mc_zzzzzz")!, kind: .summary, createdAt: StoreFixture.date, title: "x", content: "y", reportedBy: .agent)
        await #expect(throws: StoreError.notFound) { try await database.insertArtifact(orphan) }
    }

    @Test func approvalsRoundTrip() async throws {
        let database = try await StoreFixture.database()
        let task = StoreFixture.task()
        try await database.insertTask(task)
        let approved = ApprovalRecord(
            id: "apr_1", taskID: task.id, action: .postReply, decision: .approved, decidedAt: StoreFixture.at(1),
            previewFingerprint: "fp1", note: "LGTM"
        )
        let rejected = ApprovalRecord(
            id: "apr_2", taskID: task.id, action: .resolveThread, decision: .rejected, decidedAt: StoreFixture.at(2),
            previewFingerprint: "fp2"
        )
        try await database.insertApproval(rejected)
        try await database.insertApproval(approved)
        #expect(try await database.approvals(task: task.id) == [approved, rejected])
        #expect(try await database.approvals(previewFingerprint: "fp1") == [approved])
        #expect(try await database.approvals(previewFingerprint: "nope").isEmpty)
    }
}
