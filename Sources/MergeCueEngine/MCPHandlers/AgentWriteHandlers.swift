import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore

// Agent writes (claim_task … fail_task). Check order for lease-holding writes: task exists → not terminal
// (`terminal_state`) → lease token (`lease_invalid` / `lease_expired`) → `expected_version` (`version_conflict`)
// → allowed transition (`invalid_transition`) → method-specific validation → compare-and-swap persist.
// None of these calls ever writes to a provider or to the user's checkout.

extension MergeCueEngine {
    /// Largest diff recomputed from a worktree for `report_changes` and stored as an artifact.
    static let maxDiffArtifactBytes = 256 * 1024

    // MARK: claim_task

    func claimTask(_ params: ClaimTaskParams) async throws -> ClaimTaskResult {
        let task = try await requireTaskForAgent(params.taskID)
        if task.isTerminal { throw Self.terminal(task) }
        try Self.checkHandoffCode(params.handoffCode, for: task)
        guard params.expectedVersion == task.version else {
            throw Self.versionConflict(expected: params.expectedVersion, current: task.version)
        }
        let lease = newLease(agentName: params.agentName, runID: params.runID)
        let reclaim = task.state == .stale
        let updated = try await transition(
            task, on: .claim, by: .agent, actorName: params.agentName,
            message: "\(reclaim ? "Re-claimed" : "Claimed") by \(params.agentName); lease expires at \(Self.wireDate(lease.expiresAt)).",
            data: ["agent_name": params.agentName, "run_id": params.runID ?? "", "lease_expires_at": Self.wireDate(lease.expiresAt)]
        ) {
            $0.lease = lease
            $0.agentLabel = params.agentName
            $0.agentSessionID = params.runID
        }
        await appendAudit(actor: "agent:\(params.agentName)", action: IPCMethod.claimTask.rawValue, target: task.id.rawValue, outcome: .succeeded, taskID: task.id)
        return ClaimTaskResult(
            taskID: updated.id,
            state: updated.state,
            version: updated.version,
            leaseID: lease.leaseID,
            leaseExpiresAt: lease.expiresAt,
            heartbeatIntervalSeconds: heartbeatInterval,
            checkout: updated.checkout.map(TaskCheckoutDTO.init)
        )
    }

    /// S7: a task created with a handoff code can only be claimed by an agent that got the owner's handoff prompt.
    static func checkHandoffCode(_ presented: String?, for task: MCTask) throws(IPCError) {
        guard let expected = task.handoffCode, !expected.isEmpty else { return }
        guard let presented, !presented.isEmpty else {
            throw IPCError.validationFailed(
                "Task \(task.id.rawValue) requires the handoff code from the owner's handoff prompt — the text "
                    + "\"(handoff code: …)\" next to the task id. Pass it as handoff_code. MergeCue never reveals it "
                    + "through get_task; ask the owner for the handoff prompt if you do not have it."
            )
        }
        guard HandoffCode.matches(presented: presented, expected: expected) else {
            throw IPCError.validationFailed(
                "handoff_code does not match task \(task.id.rawValue). Use the code from the owner's handoff prompt."
            )
        }
    }

    // MARK: heartbeat / update_task

    func heartbeat(_ params: HeartbeatParams) async throws -> LeaseRenewalResult {
        let (task, lease) = try await loadForAgentWrite(params.taskID, leaseID: params.leaseID, expectedVersion: nil)
        let renewedLease = renewed(lease)
        let updated = try await transition(
            task, on: .heartbeat, by: .agent, actorName: lease.agentName,
            message: "Heartbeat from \(lease.agentName); lease renewed until \(Self.wireDate(renewedLease.expiresAt))."
        ) { $0.lease = renewedLease }
        return LeaseRenewalResult(version: updated.version, leaseExpiresAt: renewedLease.expiresAt)
    }

    func updateTask(_ params: UpdateTaskParams) async throws -> LeaseRenewalResult {
        let (task, lease) = try await loadForAgentWrite(params.taskID, leaseID: params.leaseID, expectedVersion: params.expectedVersion)
        let renewedLease = renewed(lease)
        let updated = try await transition(
            task, on: .progress, by: .agent, actorName: lease.agentName,
            message: params.message.trimmingCharacters(in: .whitespacesAndNewlines),
            data: ["phase": params.phase.rawValue]
        ) { $0.lease = renewedLease }
        return LeaseRenewalResult(version: updated.version, leaseExpiresAt: renewedLease.expiresAt)
    }

    // MARK: report_changes

    func reportChanges(_ params: ReportChangesParams) async throws -> ReportChangesResult {
        let (task, lease) = try await loadForAgentWrite(params.taskID, leaseID: params.leaseID, expectedVersion: params.expectedVersion)
        try requireTransition(task, .reportChanges)
        guard let checkout = task.checkout, checkout.policy == .isolatedWorktree, let worktree = checkout.worktreePath else {
            throw IPCError(
                code: .pathOutsideCheckout,
                message: "Task \(task.id.rawValue) has no isolated worktree (checkout policy \(task.checkout?.policy.rawValue ?? "none")). "
                    + "Blocked: map a safe checkout — code edits are not accepted for this task."
            )
        }
        guard PathConfinement.isSameDirectory(params.worktreePath, as: worktree) else {
            throw IPCError(
                code: .pathOutsideCheckout,
                message: "worktree_path must be the task's isolated worktree (\(worktree)); edits elsewhere are not accepted."
            )
        }
        guard let base = checkout.baseSHA, base.caseInsensitiveCompare(params.baseSHA) == .orderedSame else {
            throw IPCError.validationFailed(
                "base_sha \(params.baseSHA.prefix(64)) does not match the recorded base \(checkout.baseSHA ?? "(none)") of the worktree."
            )
        }
        var reported: [String] = []
        for path in params.changedPaths {
            guard let relative = PathConfinement.relativeChangedPath(path, worktree: worktree) else {
                throw IPCError(code: .pathOutsideCheckout, message: "Changed path '\(path.prefix(200))' is outside the task worktree.")
            }
            reported.append(relative)
        }
        let changes: WorkspaceChanges
        do {
            changes = try await worktreeChanges(checkout, worktree: worktree, base: base, maxBytes: Self.maxDiffArtifactBytes)
        } catch WorkspaceError.worktreeGitDirChanged {
            throw IPCError.validationFailed(
                "The worktree's .git no longer points to the git directory MergeCue created for it. MergeCue refuses to run "
                    + "git there; report_changes is rejected. Do not modify .git — the owner must recreate the worktree."
            )
        } catch {
            throw IPCError.internalError(
                "MergeCue could not recompute the diff of the worktree: \(SecretRedactor.redact((error as? LocalizedError)?.errorDescription ?? "\(error)"))",
                retryable: true
            )
        }
        let actual = Set(changes.changedPaths.map(\.path))
        let reportedSet = Set(reported)
        let verified = reportedSet.intersection(actual).sorted()
        let unexpected = actual.subtracting(reportedSet).sorted()
        let missing = reportedSet.subtracting(actual).sorted()

        var metadata: [String: String] = [
            "base_sha": base,
            "changed_count": String(actual.count),
            "changed_paths": Self.boundedList(actual.sorted()),
            "unexpected_paths": Self.boundedList(unexpected),
            "missing_paths": Self.boundedList(missing),
            "truncated": String(changes.truncated),
            "has_uncommitted_changes": String(changes.hasUncommittedChanges),
            "source": "worktree",
        ]
        if let head = changes.headSHA { metadata["head_sha"] = head }
        if let agentHead = params.headSHA { metadata["agent_head_sha"] = String(agentHead.prefix(128)) }
        if let note = params.note { metadata["note"] = String(note.prefix(1000)) }
        let artifact = Artifact(
            id: ids.artifactID(),
            taskID: task.id,
            kind: .diff,
            createdAt: now,
            title: "Diff recomputed by MergeCue: \(actual.count) file\(actual.count == 1 ? "" : "s") changed",
            content: BoundedText.truncate(SecretRedactor.redact(changes.unifiedDiff), maxBytes: Self.maxDiffArtifactBytes).text,
            metadata: metadata,
            reportedBy: .system
        )
        try await database.insertArtifact(artifact)
        let renewedLease = renewed(lease)
        var message = "Changes reported by \(lease.agentName): \(actual.count) file(s) in the recomputed diff "
            + "(\(verified.count) verified, \(unexpected.count) unexpected, \(missing.count) missing)."
        if let agentHead = params.headSHA, let head = changes.headSHA, agentHead.caseInsensitiveCompare(head) != .orderedSame {
            message += " Reported head \(agentHead.prefix(12)) differs from the worktree head \(head.prefix(12))."
        }
        let updated = try await transition(
            task, on: .reportChanges, by: .agent, actorName: lease.agentName, message: message,
            data: ["artifact_id": artifact.id, "unexpected_count": String(unexpected.count), "missing_count": String(missing.count)]
        ) {
            $0.artifactIDs.append(artifact.id)
            $0.lease = renewedLease
        }
        await appendAudit(actor: "agent:\(lease.agentName)", action: IPCMethod.reportChanges.rawValue, target: task.id.rawValue, outcome: .succeeded, detail: message, taskID: task.id)
        return ReportChangesResult(
            artifactID: artifact.id, version: updated.version, verifiedChangedPaths: verified,
            unexpectedPaths: unexpected, missingPaths: missing
        )
    }

    // MARK: report_tests

    func reportTests(_ params: ReportTestsParams) async throws -> ReportTestsResult {
        let (task, lease) = try await loadForAgentWrite(params.taskID, leaseID: params.leaseID, expectedVersion: params.expectedVersion)
        try requireTransition(task, .reportTests)
        // Belt and braces (validate() already enforces it): a failed command never reports passing tests.
        if params.status == .passed, params.exitCode != 0 || (params.failed ?? 0) > 0 {
            throw IPCError.validationFailed("Tests cannot be reported as passed with a non-zero exit code or failing tests.")
        }
        let command = SecretRedactor.redact(params.command)
        let output = UntrustedText.bounded(source: "test_output", text: params.output, maxBytes: IPCLimits.maxTestOutputBytes).text
        var metadata: [String: String] = [
            "command": String(command.prefix(1000)),
            "exit_code": String(params.exitCode),
            "status": params.status.rawValue,
        ]
        if let passed = params.passed { metadata["passed"] = String(passed) }
        if let failed = params.failed { metadata["failed"] = String(failed) }
        if let skipped = params.skipped { metadata["skipped"] = String(skipped) }
        if let duration = params.durationMs { metadata["duration_ms"] = String(duration) }
        let artifact = Artifact(
            id: ids.artifactID(), taskID: task.id, kind: .testRun, createdAt: now,
            title: "Tests \(params.status.rawValue) (exit \(params.exitCode)): \(command.prefix(120))",
            content: output, metadata: metadata, reportedBy: .agent
        )
        try await database.insertArtifact(artifact)
        let renewedLease = renewed(lease)
        let message = "Test run reported by \(lease.agentName): \(params.status.rawValue), exit code \(params.exitCode)."
        let updated = try await transition(
            task, on: .reportTests, by: .agent, actorName: lease.agentName, message: message,
            data: ["artifact_id": artifact.id, "status": params.status.rawValue, "exit_code": String(params.exitCode)]
        ) {
            $0.artifactIDs.append(artifact.id)
            $0.lease = renewedLease
        }
        await appendAudit(actor: "agent:\(lease.agentName)", action: IPCMethod.reportTests.rawValue, target: task.id.rawValue, outcome: .succeeded, detail: message, taskID: task.id)
        return ReportTestsResult(artifactID: artifact.id, version: updated.version)
    }

    // MARK: submit_result

    func submitResult(_ params: SubmitResultParams) async throws -> TaskStateResult {
        let (task, lease) = try await loadForAgentWrite(params.taskID, leaseID: params.leaseID, expectedVersion: params.expectedVersion)
        try requireTransition(task, .submitResult)
        let taskArtifacts = try await database.artifacts(task: task.id)
        let owned = Set(taskArtifacts.map(\.id))
        for id in params.artifactIDs where !owned.contains(id) {
            throw IPCError(
                code: .crossScopeReference,
                message: "Artifact '\(id.prefix(64))' does not belong to task \(task.id.rawValue)."
            )
        }
        let noChangesReason = params.noChangesReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.type.isCodeTask {
            let hasDiff = taskArtifacts.contains { $0.kind == .diff && (Int($0.metadata["changed_count"] ?? "") ?? 0) > 0 }
            if !hasDiff, (noChangesReason ?? "").isEmpty {
                throw IPCError.validationFailed(
                    "\(task.type.displayName) tasks need a diff artifact (call report_changes first) or a no_changes_reason."
                )
            }
        }
        let reply = params.proposedReply.map(SecretRedactor.redact)
        if task.type == .draftReply, (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IPCError.validationFailed("draft_reply tasks need a proposed_reply.")
        }
        var newArtifacts: [Artifact] = []
        let summary = SecretRedactor.redact(params.summary)
        var summaryMetadata: [String: String] = [:]
        if let noChangesReason, !noChangesReason.isEmpty { summaryMetadata["no_changes_reason"] = String(noChangesReason.prefix(4000)) }
        newArtifacts.append(Artifact(
            id: ids.artifactID(), taskID: task.id, kind: .summary, createdAt: now, title: "Result summary",
            content: summary, metadata: summaryMetadata, reportedBy: .agent
        ))
        if let reply {
            newArtifacts.append(Artifact(
                id: ids.artifactID(), taskID: task.id, kind: .proposedReply, createdAt: now, title: "Proposed reply (not posted)",
                content: reply, metadata: ["thread_id": task.origin.thread?.shortID ?? ""], reportedBy: .agent
            ))
        }
        for artifact in newArtifacts {
            try await database.insertArtifact(artifact)
        }
        let risks = (params.knownRisks ?? []).map { SecretRedactor.redact($0) }
        let updated = try await transition(
            task, on: .submitResult, by: .agent, actorName: lease.agentName,
            message: "Result submitted by \(lease.agentName); ready for your review. Nothing was published.",
            data: ["artifact_ids": (params.artifactIDs + newArtifacts.map(\.id)).joined(separator: ",")]
        ) {
            $0.resultSummary = summary
            $0.proposedReply = reply
            $0.knownRisks = risks
            $0.artifactIDs.append(contentsOf: newArtifacts.map(\.id))
            $0.lease = nil
        }
        await appendAudit(actor: "agent:\(lease.agentName)", action: IPCMethod.submitResult.rawValue, target: task.id.rawValue, outcome: .succeeded, taskID: task.id)
        await notifyResultReady(updated, agentName: lease.agentName)
        return TaskStateResult(version: updated.version, state: updated.state)
    }

    /// "Agent result ready for review" alert (Settings ▸ Notifications ▸ Agent results), after the state is committed.
    /// Honours the switch, pause and quiet hours. The body is the task's title only — never the agent's text.
    func notifyResultReady(_ task: MCTask, agentName: String) async {
        guard let notifier = env.notifier, await allowsNotification(.agentResults) else { return }
        let key = task.origin.changeRequest
        let notification = GroupedNotification(
            id: "ntf_task_" + ContentDigest.sha256Hex("\(task.id.rawValue)|\(task.version)").prefix(24),
            threadIdentifier: key.id,
            title: "\(task.origin.changeRequestRef.repoFullPath) \(key.kind.formattedNumber(key.number))",
            subtitle: "Ready for review · \(task.type.displayName)",
            body: "\(agentName) submitted a result for task \(task.id.rawValue). Review it in MergeCue — nothing was published.",
            changeRequest: key,
            attentionItemIDs: task.origin.attentionItemID.map { [$0] } ?? [],
            isUrgent: false
        )
        await notifier.deliver(notification)
    }

    // MARK: fail_task

    func failTask(_ params: FailTaskParams) async throws -> TaskStateResult {
        let (task, lease) = try await loadForAgentWrite(params.taskID, leaseID: params.leaseID, expectedVersion: params.expectedVersion)
        let reason = SecretRedactor.redact(params.reason)
        let blocked = params.blocked == true
        let updated = try await transition(
            task, on: params.trigger, by: .agent, actorName: lease.agentName,
            message: "\(blocked ? "Blocked" : "Failed") by \(lease.agentName): \(reason)",
            data: ["retryable": String(params.retryable)]
        ) {
            $0.lastError = TaskErrorInfo(code: blocked ? "agent_blocked" : "agent_failed", message: reason, retryable: params.retryable, at: now)
            $0.lease = nil
        }
        await appendAudit(actor: "agent:\(lease.agentName)", action: IPCMethod.failTask.rawValue, target: task.id.rawValue, outcome: .succeeded, detail: reason, taskID: task.id)
        return TaskStateResult(version: updated.version, state: updated.state)
    }

    // MARK: Helpers

    /// Loads a task for a lease-holding write and runs the shared checks (see the file header for the order).
    /// An expired lease on a `working` task turns it `stale` right away.
    func loadForAgentWrite(_ id: TaskID, leaseID: String, expectedVersion: Int?) async throws -> (MCTask, AgentLease) {
        let task = try await requireTaskForAgent(id)
        if task.isTerminal { throw Self.terminal(task) }
        let lease: AgentLease
        do {
            lease = try requireValidLease(task, leaseID: leaseID)
        } catch {
            if error.code == .leaseExpired, task.state == .working, let current = task.lease {
                _ = await expireLease(task, lease: current)
            }
            throw error
        }
        if let expectedVersion, expectedVersion != task.version {
            throw Self.versionConflict(expected: expectedVersion, current: task.version)
        }
        return (task, lease)
    }

    /// Throws the IPC form of `TaskTransitionError` when `trigger` is not allowed for an agent now.
    func requireTransition(_ task: MCTask, _ trigger: TaskTrigger) throws(IPCError) {
        do {
            _ = try TaskStateMachine.next(from: task.state, on: trigger, by: .agent)
        } catch {
            throw EngineErrorMapping.ipcError(from: error)
        }
    }

    static func boundedList(_ values: [String]) -> String {
        BoundedText.truncate(values.joined(separator: "\n"), maxBytes: 4096).text
    }
}
