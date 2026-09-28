import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore

extension MergeCueEngine {
    /// Serves every IPC/MCP method of ARCHITECTURE §5.
    ///
    /// Guarantees: params are decoded **and** validated here (so rejections are recorded); mutating calls are
    /// rate-limited per task (`rate_limited` beyond `maxWritesPerTaskPerMinute`); every rejected call that names
    /// an existing task appends a `rejected_call` activity, and every rejected mutating call is audited.
    public func handle(method: IPCMethod, params: JSONValue, client: IPCClientInfo) async -> Result<JSONValue, IPCError> {
        let taskID = params["task_id"]?.stringValue.flatMap(TaskID.init(rawValue:))
        do {
            if method.isMutating, let taskID {
                try checkRateLimit(taskID)
            } else if method == .proposeRule {
                try checkProposalRateLimit()
            }
            return .success(try await dispatch(method, params: params, client: client))
        } catch {
            let ipcError = EngineErrorMapping.ipcError(from: error)
            await recordRejectedCall(method: method, error: ipcError, taskID: taskID, params: params, client: client)
            return .failure(ipcError)
        }
    }

    private func dispatch(_ method: IPCMethod, params: JSONValue, client: IPCClientInfo) async throws -> JSONValue {
        switch method {
        case .ping:
            _ = try IPCCoding.decodeValidatedParams(PingParams.self, from: params)
            return try IPCCoding.encodeValue(PingResult(appVersion: env.appVersion, isDemo: env.isDemo))
        case .listAttention:
            return try IPCCoding.encodeValue(try await listAttention(try IPCCoding.decodeValidatedParams(ListAttentionParams.self, from: params)))
        case .listTasks:
            return try IPCCoding.encodeValue(try await listTasks(try IPCCoding.decodeValidatedParams(ListTasksParams.self, from: params)))
        case .getTask:
            return try IPCCoding.encodeValue(try await getTask(try IPCCoding.decodeValidatedParams(GetTaskParams.self, from: params)))
        case .getChangeContext:
            return try IPCCoding.encodeValue(try await getChangeContext(try IPCCoding.decodeValidatedParams(GetChangeContextParams.self, from: params)))
        case .getThread:
            return try IPCCoding.encodeValue(try await getThread(try IPCCoding.decodeValidatedParams(GetThreadParams.self, from: params)))
        case .getCIFailure:
            return try IPCCoding.encodeValue(try await getCIFailure(try IPCCoding.decodeValidatedParams(GetCIFailureParams.self, from: params)))
        case .getDiff:
            return try IPCCoding.encodeValue(try await getDiff(try IPCCoding.decodeValidatedParams(GetDiffParams.self, from: params)))
        case .claimTask:
            return try IPCCoding.encodeValue(try await claimTask(try IPCCoding.decodeValidatedParams(ClaimTaskParams.self, from: params)))
        case .heartbeat:
            return try IPCCoding.encodeValue(try await heartbeat(try IPCCoding.decodeValidatedParams(HeartbeatParams.self, from: params)))
        case .updateTask:
            return try IPCCoding.encodeValue(try await updateTask(try IPCCoding.decodeValidatedParams(UpdateTaskParams.self, from: params)))
        case .reportChanges:
            return try IPCCoding.encodeValue(try await reportChanges(try IPCCoding.decodeValidatedParams(ReportChangesParams.self, from: params)))
        case .reportTests:
            return try IPCCoding.encodeValue(try await reportTests(try IPCCoding.decodeValidatedParams(ReportTestsParams.self, from: params)))
        case .submitResult:
            return try IPCCoding.encodeValue(try await submitResult(try IPCCoding.decodeValidatedParams(SubmitResultParams.self, from: params)))
        case .failTask:
            return try IPCCoding.encodeValue(try await failTask(try IPCCoding.decodeValidatedParams(FailTaskParams.self, from: params)))
        case .proposeRule:
            return try IPCCoding.encodeValue(try await proposeRule(try IPCCoding.decodeValidatedParams(ProposeRuleParams.self, from: params), client: client))
        case .listRules:
            _ = try IPCCoding.decodeValidatedParams(ListRulesParams.self, from: params)
            return try IPCCoding.encodeValue(ListRulesResult(rules: try await database.rules().map(RuleSummaryDTO.init)))
        }
    }

    // MARK: Rate limit

    /// Sliding one-minute window of write attempts per task (accepted and rejected attempts both count).
    func checkRateLimit(_ taskID: TaskID) throws(IPCError) {
        let windowStart = now.addingTimeInterval(-60)
        var attempts = (writeAttempts[taskID] ?? []).filter { $0 > windowStart }
        if attempts.count >= env.maxWritesPerTaskPerMinute {
            writeAttempts[taskID] = attempts
            let retryAfter = attempts.first.map { max(1, Int(($0.timeIntervalSince(windowStart)).rounded(.up))) } ?? 60
            throw IPCError(
                code: .rateLimited,
                message: "Too many writes for task \(taskID.rawValue) (limit \(env.maxWritesPerTaskPerMinute) per minute). Slow down status updates.",
                retryable: true,
                data: ["retry_after_seconds": .number(Double(retryAfter))]
            )
        }
        attempts.append(now)
        writeAttempts[taskID] = attempts
    }

    /// Agents may propose at most 10 rules per minute.
    func checkProposalRateLimit() throws(IPCError) {
        let windowStart = now.addingTimeInterval(-60)
        proposalAttempts = proposalAttempts.filter { $0 > windowStart }
        guard proposalAttempts.count < Self.maxProposalsPerMinute else {
            throw IPCError(code: .rateLimited, message: "Too many rule proposals; try again in a minute.", retryable: true)
        }
        proposalAttempts.append(now)
    }

    static let maxProposalsPerMinute = 10

    // MARK: Rejections

    private func recordRejectedCall(method: IPCMethod, error: IPCError, taskID: TaskID?, params: JSONValue, client: IPCClientInfo) async {
        guard method != .ping else { return }
        var existing: MCTask?
        if let taskID {
            existing = try? await database.task(taskID)
        }
        let agent = params["agent_name"]?.stringValue ?? existing?.lease?.agentName ?? client.name
        let summary = "\(method.rawValue) rejected (\(error.code.rawValue)): \(error.message)"
        if let task = existing {
            await recordActivity(
                task.id, actor: .agent, actorName: agent, kind: .rejectedCall, message: summary, from: task.state,
                data: ["method": method.rawValue, "code": error.code.rawValue, "client": client.name]
            )
            emit(.tasks(task.id))
        }
        if method.isMutating || existing != nil {
            await appendAudit(
                actor: "agent:\(agent)", action: method.rawValue, target: taskID?.rawValue ?? "-", outcome: .rejected,
                detail: "\(error.code.rawValue): \(error.message)", taskID: existing?.id
            )
        }
    }

    // MARK: Shared lookups

    func requireTaskForAgent(_ id: TaskID) async throws -> MCTask {
        guard let task = try await database.task(id) else {
            throw IPCError(code: .notFound, message: "No task \(id.rawValue). Call list_tasks to see active tasks.")
        }
        return task
    }

    static func versionConflict(expected: Int, current: Int) -> IPCError {
        IPCError(
            code: .versionConflict,
            message: "expected_version \(expected) does not match the task's current version \(current). Call get_task and retry.",
            retryable: true,
            data: ["current_version": .number(Double(current))]
        )
    }

    static func terminal(_ task: MCTask) -> IPCError {
        IPCError(
            code: .terminalState,
            message: "Task \(task.id.rawValue) is \(task.state.rawValue); finished tasks cannot be changed by an agent (only the owner can reopen it).",
            data: ["state": .string(task.state.rawValue)]
        )
    }
}
