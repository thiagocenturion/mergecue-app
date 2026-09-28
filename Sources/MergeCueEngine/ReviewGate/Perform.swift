import Foundation
import MergeCueCore
import MergeCueStore

// The review gate, part 2: performing an approved preview. Requirements for any write: the owner's policy
// enables the action, the preview is live and its fingerprint matches the approval, the task did not change since
// the preview, and — for provider writes — `Account.writesEnabled` and the adapter capability. Right before
// writing, fresh remote state (`headInfo`, `thread`) and local state (checkout head/safety, worktree diff) are
// re-read; any change blocks the task and nothing is written. Every attempt/success/failure/refusal is audited,
// and a fingerprint is performed at most once (persisted marker + in-flight guard).

/// Persisted idempotency marker of a performed fingerprint.
struct PerformedActionRecord: Codable, Hashable {
    var taskID: TaskID
    var action: RemoteActionKind
    var at: Date
}

/// Result of the fresh-state check + write.
enum GateWriteResult {
    case written(String)
    /// The exact content is already there (e.g. the identical reply was posted before); nothing written.
    case alreadyPresent(String)
    /// Fresh state differs from the preview; nothing written.
    case stale(String)
}

extension MergeCueEngine {
    /// Approves exactly the previewed content and performs it. See the file header for the guarantees.
    /// Throws `previewExpired` (unknown/expired/mismatched/outdated preview), `writesDisabled`,
    /// `disabledByPolicy`, `unsupported` or `invalidInput` (preview not approvable) without writing anything.
    public func perform(previewID: String, approval: PreviewApproval) async throws(EngineError) -> ActionOutcome {
        try await uiCall { try await performApproved(previewID: previewID, approval: approval) }
    }

    /// Declines a preview: nothing is written; the decision is recorded (approval record, activity, audit).
    public func declinePreview(previewID: String, approval: PreviewApproval) async throws(EngineError) {
        try await uiCall {
            guard let preview = previews[previewID], constantTimeEquals(preview.fingerprint, approval.fingerprint) else {
                throw EngineError.previewExpired
            }
            previews[previewID] = nil
            let task = try await requireTask(preview.taskID)
            let record = ApprovalRecord(
                id: ids.approvalID(), taskID: task.id, action: preview.action, decision: .rejected, decidedAt: now,
                previewFingerprint: preview.fingerprint, note: approval.note
            )
            try await database.insertApproval(record)
            try await persistUpdate(task) { $0.approvals.append(record) }
            await recordActivity(
                task.id, actor: .user, kind: .rejected,
                message: "You declined \(preview.action.displayName); nothing was written.\(approval.note.map { " Note: \($0)" } ?? "")",
                data: ["action": preview.action.rawValue, "decision": "declined_preview", "preview_id": preview.id]
            )
            await appendAudit(
                actor: "user", action: preview.action.rawValue, target: preview.target, outcome: .rejected,
                detail: "Owner declined the preview; nothing was written.", taskID: task.id
            )
        }
    }

    private func performApproved(previewID: String, approval: PreviewApproval) async throws -> ActionOutcome {
        guard let preview = previews[previewID] else { throw EngineError.previewExpired }
        guard constantTimeEquals(preview.fingerprint, approval.fingerprint) else {
            await appendAudit(
                actor: "user", action: preview.action.rawValue, target: preview.target, outcome: .rejected,
                detail: "Approval does not match the previewed content; nothing was written.", taskID: preview.taskID
            )
            throw EngineError.previewExpired
        }
        let markerKey = SettingsKey.performedAction(preview.fingerprint)
        if let done = try await database.setting(markerKey, as: PerformedActionRecord.self) {
            previews[previewID] = nil
            return .alreadyPerformed(message: "\(done.action.displayName) was already performed at \(Self.wireDate(done.at)); nothing was written again.")
        }
        guard !inFlightFingerprints.contains(preview.fingerprint) else {
            throw EngineError.conflict("This action is already being performed.")
        }
        guard now <= preview.expiresAt else {
            previews[previewID] = nil
            throw EngineError.previewExpired
        }
        guard RemoteWritePolicy.isEnabled(preview.action) else {
            throw EngineError.disabledByPolicy(preview.action)
        }
        let task = try await requireTask(preview.taskID)
        guard task.version == preview.taskVersion, task.state == .readyForReview else {
            previews[previewID] = nil
            throw EngineError.previewExpired
        }
        let account = try await requireAccount(task.origin.account)
        if let capability = preview.action.requiredCapability {
            guard account.writesEnabled else {
                await appendAudit(actor: "user", action: preview.action.rawValue, target: preview.target, outcome: .rejected, detail: "Writes are disabled for the account.", taskID: task.id)
                throw EngineError.writesDisabled(account: account.displayLabel)
            }
            let support = env.providers.capabilities(for: account).support(for: capability)
            guard support.isUsable else {
                await appendAudit(actor: "user", action: preview.action.rawValue, target: preview.target, outcome: .rejected, detail: support.userFacingDescription, taskID: task.id)
                throw EngineError.unsupported("\(capability.displayName): \(support.userFacingDescription)")
            }
        }
        guard preview.canApprove else {
            throw EngineError.invalidInput(preview.blockedReason ?? "This preview cannot be approved.")
        }

        inFlightFingerprints.insert(preview.fingerprint)
        defer { inFlightFingerprints.remove(preview.fingerprint) }
        previews[previewID] = nil

        // 1. Record the owner's decision (approval record + ready_for_review → approved_action).
        let record = ApprovalRecord(
            id: ids.approvalID(), taskID: task.id, action: preview.action, decision: .approved, decidedAt: now,
            previewFingerprint: preview.fingerprint, note: approval.note
        )
        let approved = try await transition(
            task, on: .approveAction(preview.action), by: .user,
            message: "You approved \(preview.action.displayName): \(preview.target).",
            data: ["action": preview.action.rawValue, "preview_id": preview.id]
        ) { $0.approvals.append(record) }
        try await database.insertApproval(record)
        await appendAudit(actor: "user", action: preview.action.rawValue, target: preview.target, outcome: .attempted, detail: "Approved preview \(preview.id).", taskID: task.id)

        // 2. Fresh state + write.
        let result: GateWriteResult
        do {
            result = try await freshCheckAndWrite(preview, task: approved, account: account)
        } catch {
            return await recordWriteFailure(error, preview: preview, task: approved)
        }

        // 3. Outcome.
        switch result {
        case .stale(let reason):
            let message = "Blocked before writing: \(reason) Nothing was written; review the change request again."
            let latest = try await requireTask(task.id)
            try await transition(latest, on: .actionBlocked, by: .system, message: message, data: ["action": preview.action.rawValue]) {
                $0.lastError = TaskErrorInfo(code: "stale_state", message: reason, retryable: false, at: now)
            }
            await appendAudit(actor: "system", action: preview.action.rawValue, target: preview.target, outcome: .rejected, detail: "blocked: \(reason)", taskID: task.id)
            return .blocked(reason: reason)
        case .written(let detail), .alreadyPresent(let detail):
            try? await database.setSetting(markerKey, PerformedActionRecord(taskID: task.id, action: preview.action, at: now))
            let latest = try await requireTask(task.id)
            let remaining = try await remainingActions(for: latest, after: preview.action)
            let trigger = TaskStateMachine.triggerAfterSuccessfulAction(moreActionsRemain: !remaining.isEmpty)
            let suffix = remaining.isEmpty
                ? " Task done."
                : " Remaining: \(remaining.map(\.displayName).joined(separator: ", "))."
            let final = try await transition(
                latest, on: trigger, by: .system, message: detail + suffix,
                data: ["performed_action": preview.action.rawValue, "preview_id": preview.id]
            ) { $0.lastError = nil }
            await appendAudit(actor: "system", action: preview.action.rawValue, target: preview.target, outcome: .succeeded, detail: detail, taskID: task.id)
            if case .alreadyPresent = result {
                return .alreadyPerformed(message: detail)
            }
            return .performed(taskState: final.state, message: detail + suffix)
        }
    }

    // MARK: Fresh state + writes

    private func freshCheckAndWrite(_ preview: ReviewPreview, task: MCTask, account: Account) async throws -> GateWriteResult {
        switch preview.action {
        case .postReply, .resolveThread:
            guard let threadKey = task.origin.thread else { return .stale("The task has no review thread.") }
            let provider = try await provider(for: account.id)
            let head = try await provider.headInfo(for: task.origin.changeRequest)
            if head.state != .open {
                return .stale("The \(task.origin.providerKind.changeRequestAbbreviation) is \(head.state.rawValue).")
            }
            if let expected = preview.headSHA, let current = head.headSHA, expected.caseInsensitiveCompare(current) != .orderedSame {
                return .stale("The head moved from \(expected.prefix(12)) to \(current.prefix(12)) since the preview.")
            }
            let fresh = try await provider.thread(threadKey)
            if preview.action == .postReply {
                let body = (task.proposedReply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard ContentDigest.sha256Hex(task.proposedReply ?? "") == preview.contentDigest else {
                    return .stale("The proposed reply changed since the preview.")
                }
                if fresh.comments.contains(where: { $0.author.remoteID == account.id.remoteUserID && $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == body }) {
                    return .alreadyPresent("The identical reply is already on the thread; it was not posted again.")
                }
                if Self.threadVersion(fresh) != preview.threadVersion {
                    return .stale("The thread changed since the preview (new reply, edit or resolution).")
                }
                let comment = try await provider.createReply(to: threadKey, body: task.proposedReply ?? "")
                return .written("Reply posted on \(threadKey.shortID) (comment \(comment.id)).")
            } else {
                if fresh.isResolved == true {
                    return .alreadyPresent("The thread is already resolved; nothing was changed.")
                }
                if Self.threadVersion(fresh) != preview.threadVersion {
                    return .stale("The thread changed since the preview (new reply, edit or resolution).")
                }
                try await provider.resolveThread(threadKey, resolved: true)
                return .written("Thread \(threadKey.shortID) resolved.")
            }
        case .applyPatch:
            guard let checkout = task.checkout, let worktree = checkout.worktreePath, let base = checkout.baseSHA,
                  let mapped = checkout.mappedCheckoutPath
            else { return .stale("The task no longer has an isolated worktree.") }
            let provider = try await provider(for: account.id)
            let head = try await provider.headInfo(for: task.origin.changeRequest)
            if let current = head.headSHA, current.caseInsensitiveCompare(base) != .orderedSame {
                return .stale("The \(task.origin.providerKind.changeRequestAbbreviation) head moved from \(base.prefix(12)) to \(current.prefix(12)) since the worktree was prepared; the patch may be outdated.")
            }
            let info = try await env.workspace.inspect(path: mapped)
            if info.gitButler.isManaged || info.safety != .safe {
                return .stale("\(Self.blockedCheckoutPrefix) — \(mapped): \(info.safety.displayName.lowercased()).")
            }
            if let expected = preview.checkoutHeadSHA, info.headSHA != expected {
                return .stale("Your checkout moved since the preview.")
            }
            let changes = try await worktreeChanges(checkout, worktree: worktree, base: base, maxBytes: Self.maxPatchBytes)
            guard ContentDigest.sha256Hex(changes.unifiedDiff) == preview.contentDigest else {
                return .stale("The worktree changed since the preview.")
            }
            let applied = try await env.workspace.applyPatch(changes.unifiedDiff, into: mapped, expectedHeadSHA: preview.checkoutHeadSHA)
            guard applied.canApply else {
                return .stale("The patch no longer applies cleanly: \(applied.problems.joined(separator: "; "))")
            }
            return .written("Patch applied to \(mapped) (\(changes.changedPaths.count) file(s)). Nothing was committed or pushed.")
        case .requestChanges, .commitAndPush, .merge:
            throw EngineError.disabledByPolicy(preview.action)
        }
    }

    /// A failed write: `approved_action` → `ready_for_review` (or `blocked` on a remote conflict) with the error.
    private func recordWriteFailure(_ error: any Error, preview: ReviewPreview, task: MCTask) async -> ActionOutcome {
        let info: TaskErrorInfo
        var isConflict = false
        if let workspaceError = error as? WorkspaceError {
            switch workspaceError {
            case .headMismatch, .unsafeCheckout: isConflict = true
            default: break
            }
            info = TaskErrorInfo(code: "workspace_error", message: workspaceError.errorDescription ?? "Workspace error.", retryable: !isConflict, at: now)
        } else if let providerError = ProviderError.classify(error) {
            if case .conflict = providerError { isConflict = true }
            info = TaskErrorInfo(providerError: providerError, at: now)
        } else {
            info = TaskErrorInfo(code: "cancelled", message: "The action was cancelled; its outcome is unknown. Check the provider before retrying.", retryable: true, at: now)
        }
        let latest = (try? await requireTask(task.id)) ?? task
        let trigger: TaskTrigger = isConflict ? .actionBlocked : .actionFailed
        _ = try? await transition(
            latest, on: trigger, by: .system,
            message: "\(preview.action.displayName) \(isConflict ? "blocked" : "failed"): \(info.message)",
            data: ["action": preview.action.rawValue, "code": info.code]
        ) { $0.lastError = info }
        await appendAudit(actor: "system", action: preview.action.rawValue, target: preview.target, outcome: .failed, detail: "\(info.code): \(info.message)", taskID: task.id)
        return isConflict ? .blocked(reason: info.message) : .failed(info)
    }

    /// Actions the task's result still calls for after `performed`: `apply_patch` when a non-empty diff was
    /// reported and `post_reply` when a reply was proposed, minus those already performed.
    func remainingActions(for task: MCTask, after performed: RemoteActionKind) async throws -> [RemoteActionKind] {
        var plan: [RemoteActionKind] = []
        let artifacts = try await database.artifacts(task: task.id)
        if task.type.isCodeTask, task.checkout?.policy == .isolatedWorktree,
           artifacts.contains(where: { $0.kind == .diff && (Int($0.metadata["changed_count"] ?? "") ?? 0) > 0 })
        {
            plan.append(.applyPatch)
        }
        if task.proposedReply != nil, task.origin.thread != nil {
            plan.append(.postReply)
        }
        let done = Set(try await database.activities(task: task.id).compactMap { $0.data["performed_action"].flatMap(RemoteActionKind.init(rawValue:)) })
        return plan.filter { $0 != performed && !done.contains($0) }
    }
}
