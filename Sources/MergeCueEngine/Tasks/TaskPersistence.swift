import Foundation
import MergeCueCore
import MergeCueStore

// Persistence primitives for tasks: every change is a compare-and-swap on `MCTask.version`, and every state
// transition appends exactly one activity of the kind mapped from its trigger (ARCHITECTURE §2.6).

extension MergeCueEngine {
    /// The activity recorded for a transition (never `note`).
    static func activityKind(for trigger: TaskTrigger) -> ActivityKind {
        switch trigger {
        case .claim: .claimed
        case .heartbeat: .heartbeat
        case .progress: .progress
        case .reportChanges: .changesReported
        case .reportTests: .testsReported
        case .submitResult: .resultSubmitted
        case .fail: .failed
        case .agentBlocked, .block: .blocked
        case .leaseExpired: .stale
        case .approveAction: .approved
        case .rejectResult: .rejected
        case .actionSucceeded: .actionSucceeded
        case .actionBlocked: .actionBlocked
        case .actionFailed: .actionFailed
        case .markDone: .completed
        case .cancel: .cancelled
        case .dismiss: .dismissed
        case .retry: .retried
        case .reopen: .reopened
        case .unblock: .unblocked
        }
    }

    /// Applies a legal state-machine transition (throws `TaskTransitionError` otherwise), persists it with CAS
    /// against `task.version` (throws `StoreError.versionConflict`) and appends the transition activity.
    @discardableResult
    func transition(
        _ task: MCTask,
        on trigger: TaskTrigger,
        by actor: TransitionActor,
        actorName: String? = nil,
        message: String,
        data: [String: String] = [:],
        mutate: (inout MCTask) -> Void = { _ in }
    ) async throws -> MCTask {
        let next = try TaskStateMachine.next(from: task.state, on: trigger, by: actor)
        var updated = task
        mutate(&updated)
        updated.state = next
        updated.version = task.version + 1
        updated.updatedAt = now
        try await database.updateTask(updated, expectedVersion: task.version)
        await recordActivity(
            updated.id, actor: actor, actorName: actorName, kind: Self.activityKind(for: trigger), message: message,
            from: task.state, to: next, data: data
        )
        emit(.tasks(task.id))
        return updated
    }

    /// Persists a change that is not a state transition (checkout prepared, artifact attached, …) with CAS.
    @discardableResult
    func persistUpdate(_ task: MCTask, mutate: (inout MCTask) -> Void) async throws -> MCTask {
        var updated = task
        mutate(&updated)
        updated.state = task.state
        updated.version = task.version + 1
        updated.updatedAt = now
        try await database.updateTask(updated, expectedVersion: task.version)
        emit(.tasks(task.id))
        return updated
    }

    /// Appends one history entry (the store redacts message and data).
    func recordActivity(
        _ taskID: TaskID,
        actor: TransitionActor,
        actorName: String? = nil,
        kind: ActivityKind,
        message: String,
        from: TaskState? = nil,
        to: TaskState? = nil,
        data: [String: String] = [:]
    ) async {
        let activity = TaskActivity(
            id: ids.activityID(), taskID: taskID, at: now, actor: actor, actorName: actorName, kind: kind,
            message: message, fromState: from, toState: to, data: data
        )
        do {
            try await database.appendActivity(activity)
        } catch {
            log.error("activity write failed for \(taskID): \(error)")
        }
    }

    /// Inserts a new task, retrying with a fresh id on a (rare) `TaskID` collision.
    func insertNewTask(_ build: (TaskID) -> MCTask) async throws -> MCTask {
        var taken = try await database.taskIDs()
        for _ in 0..<5 {
            let id = TaskID.generate(avoiding: taken)
            let task = build(id)
            do {
                try await database.insertTask(task)
                return task
            } catch let error as StoreError where error.isUniqueConstraintViolation {
                taken.insert(id)
            }
        }
        throw EngineError.failed("Could not allocate a task id.")
    }
}
