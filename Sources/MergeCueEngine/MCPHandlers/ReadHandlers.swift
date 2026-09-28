import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore

// Read-only MCP methods and propose_rule. Context comes from stored snapshots; CI logs and diffs are fetched on
// demand through the providers, bounded and redacted. Reviewer/PR/CI text is always returned as `UntrustedText`.

extension MergeCueEngine {
    // MARK: list_attention / list_tasks

    func listAttention(_ params: ListAttentionParams) async throws -> ListAttentionResult {
        let handles = await accountHandles()
        var items = try await database.attentionItems(includeInactive: false, now: now)
        if let provider = params.provider {
            items = items.filter { $0.providerKind == provider }
        }
        if let account = params.account?.lowercased() {
            items = items.filter { handle(for: $0.account, in: handles).lowercased() == account }
        }
        if let repo = params.repo?.lowercased() {
            items = items.filter { $0.repoFullPath.lowercased() == repo }
        }
        if !params.resolvedIncludeRead {
            items = items.filter(\.isUnread)
        }
        let page = items.prefix(params.resolvedLimit).map { AttentionItemDTO($0, account: handle(for: $0.account, in: handles)) }
        return ListAttentionResult(items: Array(page), total: items.count)
    }

    func listTasks(_ params: ListTasksParams) async throws -> ListTasksResult {
        let handles = await accountHandles()
        let states: Set<TaskState> = (params.states?.isEmpty ?? true) ? TaskState.active : Set(params.states ?? [])
        let tasks = try await database.tasks(states: states).prefix(params.resolvedLimit)
        return ListTasksResult(tasks: tasks.map { TaskSummaryDTO($0, account: handle(for: $0.origin.account, in: handles)) })
    }

    // MARK: get_task

    func getTask(_ params: GetTaskParams) async throws -> TaskContextDTO {
        let task = try await requireTaskForAgent(params.taskID)
        let handles = await accountHandles()
        let artifacts = try await database.artifacts(task: task.id)
        return TaskContextDTO(
            task,
            account: handle(for: task.origin.account, in: handles),
            instructions: TaskContextBuilder.instructions(for: task, leaseDuration: env.leaseDuration, heartbeatInterval: heartbeatInterval),
            nextSteps: TaskContextBuilder.nextSteps(for: task),
            artifacts: artifacts,
            isDemo: env.isDemo
        )
    }

    // MARK: get_change_context / get_thread / get_ci_failure

    func getChangeContext(_ params: GetChangeContextParams) async throws -> ChangeContextResult {
        let snapshot = try await resolveChangeRef(params.changeRef, scope: nil)
        return ChangeContextResult(snapshot, includeFiles: params.resolvedIncludeFiles, maxFiles: params.resolvedMaxFiles)
    }

    func getThread(_ params: GetThreadParams) async throws -> ThreadDTO {
        guard case let (thread, snapshot)? = try await findThread(shortID: params.threadID) else {
            throw IPCError(code: .notFound, message: "No review thread \(params.threadID.prefix(64)).")
        }
        return ThreadDTO(thread, changeRef: snapshot.summary.ref)
    }

    func getCIFailure(_ params: GetCIFailureParams) async throws -> CIFailureResult {
        guard case let (check, _)? = try await findCheck(shortID: params.checkID) else {
            throw IPCError(code: .notFound, message: "No CI check \(params.checkID.prefix(64)).")
        }
        let provider = try await provider(for: check.key.changeRequest.account)
        let log = try await provider.failureLog(for: check, maxBytes: params.resolvedMaxBytes)
        return CIFailureResult(check, log: log, maxBytes: params.resolvedMaxBytes)
    }

    // MARK: get_diff

    func getDiff(_ params: GetDiffParams) async throws -> GetDiffResult {
        let maxBytes = params.resolvedMaxBytes
        if let taskID = params.taskID {
            let task = try await requireTaskForAgent(taskID)
            if let ref = params.changeRef, !ref.matches(task.origin.changeRequestRef) {
                throw IPCError(
                    code: .crossScopeReference,
                    message: "change_ref \(ref.string) does not belong to task \(task.id.rawValue) (\(task.origin.changeRequestRef.string))."
                )
            }
            if let checkout = task.checkout, checkout.policy == .isolatedWorktree,
               let worktree = checkout.worktreePath, let base = checkout.baseSHA
            {
                let changes = try await env.workspace.changes(inWorktree: worktree, since: base, maxBytes: maxBytes)
                return Self.redacted(GetDiffResult(changes, baseSHA: base), maxBytes: maxBytes)
            }
            return try await providerDiff(task.origin.changeRequest, maxBytes: maxBytes)
        }
        guard let ref = params.changeRef else {
            throw IPCError.invalidParams("Provide 'task_id' or 'change_ref'.")
        }
        let snapshot = try await resolveChangeRef(ref, scope: nil)
        return try await providerDiff(snapshot.key, maxBytes: maxBytes)
    }

    private func providerDiff(_ key: ChangeRequestKey, maxBytes: Int) async throws -> GetDiffResult {
        let provider = try await provider(for: key.account)
        let payload = try await provider.diff(for: key, maxBytes: maxBytes)
        return Self.redacted(GetDiffResult(payload), maxBytes: maxBytes)
    }

    static func redacted(_ result: GetDiffResult, maxBytes: Int) -> GetDiffResult {
        var result = result
        let bounded = BoundedText.truncate(SecretRedactor.redact(result.unifiedDiff), maxBytes: maxBytes)
        result.unifiedDiff = bounded.text
        result.truncated = result.truncated || bounded.isTruncated
        return result
    }

    // MARK: propose_rule

    func proposeRule(_ params: ProposeRuleParams, client: IPCClientInfo) async throws -> ProposeRuleResult {
        guard let action = params.ruleAction else {
            throw IPCError.invalidParams("'task_type' is required when 'action' is \(params.action.rawValue).")
        }
        let rule = Rule(
            id: ids.ruleID(),
            name: params.name.trimmingCharacters(in: .whitespacesAndNewlines),
            isActive: false,
            origin: .agentProposal,
            providerKinds: Set(params.providers ?? []),
            eventTypes: Set(params.eventTypes),
            repoInclude: params.repoInclude ?? [],
            repoExclude: params.repoExclude ?? [],
            action: action,
            maxFiresPerHour: params.maxFiresPerHour ?? 10,
            quietHours: params.quietHours?.quietHours,
            createdAt: now
        )
        try await database.upsertRule(rule)
        emit(.rules)
        let preview = RulePreview.describe(rule)
        await appendAudit(actor: "agent:\(client.name)", action: IPCMethod.proposeRule.rawValue, target: rule.id, outcome: .succeeded, detail: preview)
        return ProposeRuleResult(ruleID: rule.id, preview: preview)
    }
}
