import Foundation
import MergeCueCore
import MergeCueStore

extension MergeCueEngine {
    // MARK: Read

    /// Tasks in `states` (every task when nil), most recently updated first.
    public func tasks(states: Set<TaskState>? = nil) async throws(EngineError) -> [MCTask] {
        try await uiCall { try await database.tasks(states: states) }
    }

    /// A task with its activities, artifacts and approvals.
    public func taskDetail(_ id: TaskID) async throws(EngineError) -> TaskDetail {
        try await uiCall { try await loadDetail(id) }
    }

    /// Every task with its history (for the Tasks view and the popover sections).
    public func taskDetails(states: Set<TaskState>? = nil) async throws(EngineError) -> [TaskDetail] {
        try await uiCall {
            var details: [TaskDetail] = []
            for task in try await database.tasks(states: states) {
                details.append(try await loadDetail(task.id, task: task))
            }
            return details
        }
    }

    func loadDetail(_ id: TaskID, task: MCTask? = nil) async throws -> TaskDetail {
        let loaded: MCTask
        if let task { loaded = task } else { loaded = try await requireTask(id) }
        return TaskDetail(
            task: loaded,
            activities: try await database.activities(task: id),
            artifacts: try await database.artifacts(task: id),
            approvals: try await database.approvals(task: id)
        )
    }

    // MARK: User transitions

    /// Cancels a non-terminal task and releases its lease.
    @discardableResult
    public func cancelTask(_ id: TaskID) async throws(EngineError) -> MCTask {
        try await userTransition(id, .cancel, message: "Cancelled by you; the agent lease was released.") { $0.lease = nil }
    }

    /// Dismisses a non-terminal task.
    @discardableResult
    public func dismissTask(_ id: TaskID) async throws(EngineError) -> MCTask {
        try await userTransition(id, .dismiss, message: "Dismissed by you.") { $0.lease = nil }
    }

    /// `failed` / `blocked` / `stale` → `waiting_for_agent` (lease cleared).
    @discardableResult
    public func retryTask(_ id: TaskID) async throws(EngineError) -> MCTask {
        try await userTransition(id, .retry, message: "Retry requested; task ready to start again.") {
            $0.lease = nil
            $0.lastError = nil
        }
    }

    /// `blocked` → `waiting_for_agent`.
    @discardableResult
    public func unblockTask(_ id: TaskID) async throws(EngineError) -> MCTask {
        try await userTransition(id, .unblock, message: "Unblocked by you; task ready to start again.") { $0.lease = nil }
    }

    /// `ready_for_review` → `done` without any remote action.
    @discardableResult
    public func markTaskDone(_ id: TaskID) async throws(EngineError) -> MCTask {
        try await userTransition(id, .markDone, message: "Marked done by you (no remote action).")
    }

    /// "Discard and retry": rejects the submitted result (`ready_for_review` → `waiting_for_agent`). Nothing is
    /// written anywhere; artifacts are kept for the history.
    @discardableResult
    public func rejectResult(_ id: TaskID, note: String? = nil) async throws(EngineError) -> MCTask {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = "Result discarded by you; nothing was written. Task ready to start again."
            + ((trimmed?.isEmpty ?? true) ? "" : " Note: \(trimmed ?? "")")
        return try await userTransition(id, .rejectResult, message: message) {
            $0.lease = nil
            $0.resultSummary = nil
            $0.proposedReply = nil
            $0.knownRisks = []
        }
    }

    /// Reopens a `done` / `cancelled` / `dismissed` task (user only). Refused while another active task exists
    /// for the same attention item (one active task per item).
    @discardableResult
    public func reopenTask(_ id: TaskID) async throws(EngineError) -> MCTask {
        try await uiCall {
            let task = try await requireTask(id)
            if let attentionID = task.origin.attentionItemID,
               let item = try await database.attentionItem(id: attentionID),
               let active = try await activeTask(forAttention: item), active.id != id
            {
                throw EngineError.invalidTransition("Task \(active.id.rawValue) is already active for this item.")
            }
            let reopened = try await transition(task, on: .reopen, by: .user, message: "Reopened by you; task ready to start.") {
                $0.lease = nil
                $0.lastError = nil
            }
            if let attentionID = task.origin.attentionItemID {
                try? await database.linkAttention(id: attentionID, taskID: id)
                emit(.attention)
            }
            return reopened
        }
    }

    /// Removes the isolated worktree of a finished task (the user's mapped checkout is never touched).
    public func cleanupWorktree(_ id: TaskID) async throws(EngineError) {
        try await uiCall {
            let task = try await requireTask(id)
            guard task.isTerminal else {
                throw EngineError.invalidTransition("Only finished tasks can be cleaned up.")
            }
            guard let checkout = task.checkout, let worktree = checkout.worktreePath, let mapped = checkout.mappedCheckoutPath else {
                return
            }
            try await env.workspace.removeWorktree(path: worktree, checkoutPath: mapped)
            await recordActivity(id, actor: .user, kind: .note, message: "Isolated worktree removed.")
            try await persistUpdate(task) { $0.checkout?.worktreePath = nil }
        }
    }

    private func userTransition(
        _ id: TaskID,
        _ trigger: TaskTrigger,
        message: String,
        mutate: (inout MCTask) -> Void = { _ in }
    ) async throws(EngineError) -> MCTask {
        try await uiCall {
            let task = try await requireTask(id)
            let updated = try await transition(task, on: trigger, by: .user, message: message, mutate: mutate)
            forgetPreviews(for: id)
            return updated
        }
    }
}
