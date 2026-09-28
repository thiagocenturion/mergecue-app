import Foundation
import MergeCueCore
import MergeCueStore

// Rules (PLAN §8): user-authored records (or agent proposals, stored inactive), activated only by the user, and
// evaluated on every batch of new (non-baseline, deduped) events from Sync with `RuleEvaluator.decide` and
// per-(rule, event) idempotency (`recordRuleFiring`). A `create_task` action creates at most one task per event
// (also across rules), and `request_execution` degrades to `create_task` plus the note "Unattended execution not
// available — task ready to start". Rules never write to a provider.

extension MergeCueEngine {
    public static let unattendedExecutionNote = "Unattended execution not available — task ready to start"

    // MARK: CRUD

    public func rules() async throws(EngineError) -> [Rule] {
        try await uiCall { try await database.rules() }
    }

    /// The built-in templates (inactive), to instantiate with `addRule(fromTemplate:)`.
    public nonisolated var ruleTemplates: [Rule] { RuleTemplates.all }

    /// Creates or updates a rule authored in the app (the user may set `isActive`).
    @discardableResult
    public func saveRule(_ rule: Rule) async throws(EngineError) -> Rule {
        try await uiCall {
            var rule = rule
            rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.name.isEmpty else { throw EngineError.invalidInput("Give the rule a name.") }
            if rule.id.isEmpty { rule.id = ids.ruleID() }
            if let existing = try await database.rule(id: rule.id) {
                rule.createdAt = existing.createdAt
                rule.origin = existing.origin
            } else {
                rule.createdAt = now
            }
            rule.updatedAt = now
            try await database.upsertRule(rule)
            await appendAudit(actor: "user", action: "save_rule", target: rule.id, outcome: .succeeded, detail: RulePreview.describe(rule))
            emit(.rules)
            return rule
        }
    }

    /// Copies a template into a new, inactive rule.
    @discardableResult
    public func addRule(fromTemplate templateID: String) async throws(EngineError) -> Rule {
        try await uiCall {
            guard let template = RuleTemplates.template(id: templateID) else {
                throw EngineError.notFound("Rule template \(templateID)")
            }
            let rule = RuleTemplates.instantiate(template, id: ids.ruleID(), now: now)
            try await database.upsertRule(rule)
            emit(.rules)
            return rule
        }
    }

    public func deleteRule(id: String) async throws(EngineError) {
        try await uiCall {
            guard try await database.deleteRule(id: id) else { throw EngineError.notFound("Rule \(id)") }
            await appendAudit(actor: "user", action: "delete_rule", target: id, outcome: .succeeded)
            emit(.rules)
        }
    }

    /// Activation is a user-only operation (agent proposals stay pending until then).
    @discardableResult
    public func setRuleActive(id: String, active: Bool) async throws(EngineError) -> Rule {
        try await uiCall {
            guard var rule = try await database.rule(id: id) else { throw EngineError.notFound("Rule \(id)") }
            rule.isActive = active
            rule.updatedAt = now
            try await database.upsertRule(rule)
            await appendAudit(actor: "user", action: active ? "activate_rule" : "deactivate_rule", target: id, outcome: .succeeded)
            emit(.rules)
            return rule
        }
    }

    /// Human-readable description of a rule.
    public nonisolated func describe(_ rule: Rule) -> String {
        RulePreview.describe(rule)
    }

    // MARK: Evaluation

    /// Sync's event handler: evaluates active rules on new events. Also callable directly (tests, replays);
    /// idempotent per (rule, event).
    public func handleNewEvents(_ events: [ChangeEvent]) async {
        guard !events.isEmpty else { return }
        let active = ((try? await database.rules()) ?? []).filter(\.isActive)
        guard !active.isEmpty else { return }
        var fired = false
        for event in events {
            let snapshot = try? await database.snapshot(event.changeRequest)
            let involvement = snapshot?.summary.involvement ?? []
            for rule in active {
                let recent = (try? await database.ruleFiringCount(ruleID: rule.id, since: now.addingTimeInterval(-3600))) ?? 0
                guard case .fire = RuleEvaluator.decide(rule, event: event, involvement: involvement, now: now, firesInLastHour: recent) else {
                    continue
                }
                guard (try? await database.recordRuleFiring(ruleID: rule.id, eventID: event.id, at: now)) == true else {
                    continue
                }
                fired = true
                await applyRuleAction(rule, event: event)
            }
        }
        if fired { emit(.rules) }
    }

    private func applyRuleAction(_ rule: Rule, event: ChangeEvent) async {
        switch rule.action {
        case .notify:
            await appendAudit(actor: "rule:\(rule.id)", action: "rule_fired", target: event.changeRequestRef.string, outcome: .succeeded, detail: "notify: \(event.type.displayName)")
        case .createTask(let type):
            _ = await createTaskForRule(rule, event: event, type: type, requestedExecution: false)
        case .requestExecution(let type):
            _ = await createTaskForRule(rule, event: event, type: type, requestedExecution: true)
        }
    }

    /// At most one task per event (across rules and relaunches), and one active task per attention item.
    private func createTaskForRule(_ rule: Rule, event: ChangeEvent, type: TaskType, requestedExecution: Bool) async -> TaskID? {
        let key = SettingsKey.eventTask(event.id)
        if let existing = try? await database.setting(key, as: TaskID.self) {
            return existing
        }
        do {
            let task: MCTask
            if let item = try await attentionItem(for: event) {
                task = try await createTask(attentionID: item.id, type: type, ruleID: rule.id)
            } else {
                task = try await createTaskWithoutAttention(event: event, type: type, ruleID: rule.id)
            }
            try await database.setSetting(key, task.id)
            if requestedExecution {
                await recordActivity(task.id, actor: .system, kind: .note, message: Self.unattendedExecutionNote, data: ["rule_id": rule.id])
            }
            await appendAudit(
                actor: "rule:\(rule.id)", action: "rule_fired", target: event.changeRequestRef.string, outcome: .succeeded,
                detail: "\(requestedExecution ? "request_execution" : "create_task"): \(type.rawValue) → \(task.id.rawValue)", taskID: task.id
            )
            return task.id
        } catch {
            await appendAudit(actor: "rule:\(rule.id)", action: "rule_fired", target: event.changeRequestRef.string, outcome: .failed, detail: "\(error)")
            return nil
        }
    }

    /// The attention item that carries `event` (by event id, else by the event's thread/check/reason key).
    private func attentionItem(for event: ChangeEvent) async throws -> AttentionItem? {
        let items = try await database.attentionItems(changeRequest: event.changeRequest)
        if let exact = items.first(where: { $0.eventIDs.contains(event.id) }) { return exact }
        if let thread = event.thread, let item = items.first(where: { $0.thread == thread }) { return item }
        if let check = event.check, let item = items.first(where: { $0.check == check }) { return item }
        return nil
    }

    private func createTaskWithoutAttention(event: ChangeEvent, type: TaskType, ruleID: String) async throws -> MCTask {
        guard let snapshot = try await database.snapshot(event.changeRequest) else {
            throw EngineError.notFound("Change request \(event.changeRequestRef.string)")
        }
        let log = await captureLog(check: event.check, snapshot: snapshot)
        let trigger = TriggerSnapshotBuilder.build(
            snapshot: snapshot, thread: event.thread, check: event.check, reason: nil, eventType: event.type, log: log, now: now
        )
        let origin = TaskOrigin(
            ruleID: ruleID, changeRequest: snapshot.summary.key, changeRequestRef: snapshot.summary.ref,
            title: snapshot.summary.title, webURL: snapshot.summary.webURL, thread: event.thread, check: event.check
        )
        let task = try await insertCreatedTask(type: type, origin: origin, trigger: trigger, ruleID: ruleID, reason: event.type.displayName)
        await prepareCheckoutQuietly(task.id)
        return task
    }
}
