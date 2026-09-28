import Foundation
import MergeCueCore
import MergeCueStore

extension MergeCueEngine {
    // MARK: Create

    /// "Fix with AI" / "Investigate with AI" / "Draft reply" / "Address with AI": creates a task in
    /// `waiting_for_agent` (the only creation state) from an attention item.
    ///
    /// - `type` overrides `TaskType.inferred(from: item.reason)`.
    /// - Idempotent: while the item has an active (non-terminal) task, that task is returned instead.
    /// - The trigger snapshot quotes the exact comment(s) / CI excerpt as bounded, redacted `UntrustedText`.
    /// - Code tasks get an isolated worktree prepared right away when a safe checkout is mapped (otherwise the
    ///   checkout policy is `blocked` with "Blocked: map a safe checkout"); this never touches the user's checkout.
    public func createTask(fromAttention attentionID: String, type: TaskType? = nil) async throws(EngineError) -> MCTask {
        try await uiCall {
            try await createTask(attentionID: attentionID, type: type, ruleID: nil)
        }
    }

    func createTask(attentionID: String, type: TaskType?, ruleID: String?) async throws -> MCTask {
        if let pending = pendingCreations[attentionID] {
            return try await requireTask(try await pending.value)
        }
        let work = Task { try await self.performCreate(attentionID: attentionID, type: type, ruleID: ruleID) }
        pendingCreations[attentionID] = work
        defer { pendingCreations[attentionID] = nil }
        let id = try await work.value
        return try await requireTask(id)
    }

    private func performCreate(attentionID: String, type: TaskType?, ruleID: String?) async throws -> TaskID {
        guard let item = try await database.attentionItem(id: attentionID) else {
            throw EngineError.notFound("Attention item \(attentionID)")
        }
        guard let taskType = type ?? TaskType.inferred(from: item.reason) else {
            throw EngineError.invalidInput("\(item.reason.displayName) items have no agent task. Choose a task type explicitly.")
        }
        if let existing = try await activeTask(forAttention: item) {
            return existing.id
        }
        guard let snapshot = try await database.snapshot(item.changeRequest) else {
            throw EngineError.notFound("Change request \(item.changeRequestRef.string)")
        }
        var eventType: ChangeEventType?
        if let lastEventID = item.eventIDs.last {
            eventType = try await database.event(id: lastEventID)?.type
        }
        let log = await captureLog(check: item.check, snapshot: snapshot)
        let trigger = TriggerSnapshotBuilder.build(
            snapshot: snapshot, thread: item.thread, check: item.check, reason: item.reason, eventType: eventType,
            log: log, now: now
        )
        let origin = TaskOrigin(
            attentionItemID: item.id,
            ruleID: ruleID,
            changeRequest: snapshot.summary.key,
            changeRequestRef: snapshot.summary.ref,
            title: snapshot.summary.title,
            webURL: snapshot.summary.webURL,
            thread: item.thread,
            check: item.check
        )
        let task = try await insertCreatedTask(type: taskType, origin: origin, trigger: trigger, ruleID: ruleID, reason: item.reason.displayName)
        try await database.linkAttention(id: item.id, taskID: task.id)
        emit(.attention)
        await prepareCheckoutQuietly(task.id)
        return task.id
    }

    /// Inserts a new `waiting_for_agent` task and records the `created` activity.
    func insertCreatedTask(type: TaskType, origin: TaskOrigin, trigger: TaskTriggerSnapshot, ruleID: String?, reason: String) async throws -> MCTask {
        let createdAt = now
        let task = try await insertNewTask { id in
            MCTask(id: id, type: type, state: TaskStateMachine.initialState, createdAt: createdAt, origin: origin, trigger: trigger,
                   handoffCode: HandoffCode.generate(using: self.ids))
        }
        let by = ruleID == nil ? "you" : "rule \(ruleID ?? "")"
        await recordActivity(
            task.id, actor: ruleID == nil ? .user : .system, kind: .created,
            message: "\(type.displayName) task created by \(by) from \(reason) on \(origin.changeRequestRef.string). Task ready to start — waiting for an agent to claim it.",
            to: task.state,
            data: ruleID.map { ["rule_id": $0] } ?? [:]
        )
        emit(.tasks(task.id))
        return task
    }

    /// The item's active task, if any (via the link, or any non-terminal task created from the item).
    func activeTask(forAttention item: AttentionItem) async throws -> MCTask? {
        if let linked = item.linkedTaskID, let task = try await database.task(linked), !task.isTerminal {
            return task
        }
        return try await database.tasks(states: TaskState.active).first { $0.origin.attentionItemID == item.id }
    }

    /// Best-effort bounded CI log for a failing check (never fails task creation).
    func captureLog(check: CheckKey?, snapshot: ChangeRequestSnapshot) async -> LogExcerpt? {
        guard let check, let run = snapshot.check(check), run.status.isFailing else { return nil }
        do {
            let provider = try await provider(for: check.changeRequest.account)
            return try await provider.failureLog(for: run, maxBytes: TriggerSnapshotBuilder.maxLogBytes)
        } catch {
            log.info("CI log not captured at task creation: \(error)")
            return nil
        }
    }
}
