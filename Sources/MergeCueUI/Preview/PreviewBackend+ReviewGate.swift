import Foundation
import MergeCueCore

/// Remote actions the owner's policy allows (ARCHITECTURE §10): replies, thread resolution and the local patch import.
nonisolated enum WritePolicy {
    static let allowed: Set<RemoteActionKind> = [.applyPatch, .postReply, .resolveThread]
}

extension PreviewBackend {
    private nonisolated struct FingerprintInput: Encodable {
        var taskID: String
        var action: String
        var body: String
        var headSHA: String?
        var version: Int
    }

    /// Actions the review gate offers for a task (all of them must be approved one by one).
    static func plannedActions(for record: TaskRecord) -> [RemoteActionKind] {
        var actions: [RemoteActionKind] = []
        if record.task.type.isCodeTask, record.artifact(.diff) != nil { actions.append(.applyPatch) }
        if record.task.proposedReply != nil, record.task.origin.thread != nil { actions.append(.postReply) }
        return actions
    }

    func makePreview(taskID: TaskID, kind: RemoteActionKind) throws -> ActionPreview {
        guard WritePolicy.allowed.contains(kind) else { throw AppBackendError.disabledByPolicy(kind) }
        guard let record = state.tasks.first(where: { $0.id == taskID }) else { throw AppBackendError.notFound("Task \(taskID)") }
        let task = record.task
        guard task.state == .readyForReview else {
            throw AppBackendError.invalidTransition("Actions can be approved only while the task is ready for review.")
        }
        let account = state.accounts.first { $0.id == task.origin.account }
        let snapshot = state.changeRequests.first { $0.key == task.origin.changeRequest }
        let ref = "\(task.origin.changeRequestRef.repoFullPath) \(task.origin.providerKind.formattedNumber(task.origin.changeRequest.number))"
        let accountName = account.map { "\($0.kind.displayName) · \($0.account.displayLabel)" } ?? task.origin.providerKind.displayName
        let threadLocation = task.trigger.anchor.map { " · \($0.path)\($0.line.map { ":\($0)" } ?? "")" } ?? ""

        var title = "\(kind.displayName) · \(ref)"
        var target = ""
        var body = ""
        var warnings: [String] = []
        var blocked: String?

        switch kind {
        case .applyPatch:
            guard let diff = record.artifact(.diff) else { throw AppBackendError.invalidInput("The agent reported no diff to apply.") }
            let checkout = task.checkout
            title = "Apply patch to \(checkout?.mappedCheckoutPath ?? "the mapped checkout")"
            target = "\(checkout?.mappedCheckoutPath ?? "—") · branch \(checkout?.sourceBranch ?? "—") · base \(UIFormat.shortSHA(checkout?.baseSHA))"
            body = diff.content
            if checkout?.isGitButlerManaged == true {
                blocked = "The target is a GitButler workspace. Apply the patch through GitButler or to a separate clone."
            } else {
                warnings.append("MergeCue checks for a clean state and conflicts right before applying.")
            }
        case .postReply, .resolveThread:
            guard task.origin.thread != nil else { throw AppBackendError.invalidInput("This task has no review thread to act on.") }
            if kind == .postReply {
                guard let reply = task.proposedReply else { throw AppBackendError.invalidInput("The agent did not propose a reply.") }
                body = reply
                title = "Post reply on \(ref)"
            } else {
                body = "Mark the thread as resolved."
                title = "Resolve thread on \(ref)"
            }
            target = "\(accountName) · thread\(threadLocation)"
            if let capability = kind.requiredCapability, let support = account?.capabilities.support(for: capability) {
                switch support {
                case .supported, .partial: break
                case .requiresWriteAccess(let scope):
                    blocked = "The \(accountName) token lacks the \(scope) scope. Reconnect with write access to post."
                case .unsupported(let reason):
                    blocked = reason
                }
            }
            if account?.account.writesEnabled != true {
                blocked = blocked ?? "Remote writes are off for \(accountName). Turn them on in Settings › Accounts to post or resolve."
            }
            if let head = snapshot?.summary.headSHA, head != task.trigger.headSHA {
                warnings.append("The \(task.origin.providerKind.changeRequestAbbreviation) head moved since the task started; MergeCue re-checks before posting.")
            }
        case .requestChanges, .commitAndPush, .merge:
            throw AppBackendError.disabledByPolicy(kind)
        }
        warnings.append("Preview data: approving records your decision, but nothing is written or posted.")

        let fingerprint = (try? MergeCueCoding.digest(FingerprintInput(taskID: taskID.rawValue, action: kind.rawValue, body: body,
                                                                        headSHA: task.trigger.headSHA, version: task.version)))
            ?? UUID().uuidString
        let preview = ActionPreview(id: IDGenerator.previewID(), taskID: taskID, action: kind, title: title, target: target, body: body,
                                    headSHA: task.trigger.headSHA, fingerprint: fingerprint, warnings: warnings,
                                    canApprove: blocked == nil, blockedReason: blocked, createdAt: now, isSimulated: true)
        previews[preview.id] = preview
        return preview
    }

    func approve(_ preview: ActionPreview) throws -> AppCommandResult {
        guard let stored = previews[preview.id], stored.fingerprint == preview.fingerprint else { throw AppBackendError.previewExpired }
        guard stored.canApprove else {
            throw AppBackendError.invalidInput(stored.blockedReason ?? "This action can't be approved.")
        }
        guard let index = state.tasks.firstIndex(where: { $0.id == preview.taskID }) else { throw AppBackendError.notFound("Task \(preview.taskID)") }
        guard state.tasks[index].task.state == .readyForReview else { throw AppBackendError.previewExpired }

        try transition(preview.taskID, .approveAction(preview.action), .approved, "Approved \(preview.action.displayName)")
        try record(preview, decision: .approved)
        appendActivity(preview.taskID, .system, nil, .actionAttempted, "\(preview.action.displayName): preview data — nothing was written")

        completedActions[preview.taskID, default: []].insert(preview.action)
        let remaining = Self.plannedActions(for: state.tasks[index]).filter { !(completedActions[preview.taskID]?.contains($0) ?? false) }
        let trigger = TaskStateMachine.triggerAfterSuccessfulAction(moreActionsRemain: !remaining.isEmpty)
        var task = state.tasks[index].task
        let from = task.state
        let next = (try? TaskStateMachine.next(from: from, on: trigger, by: .system)) ?? from
        task.state = next
        task.version += 1
        task.updatedAt = now
        state.tasks[index].task = task
        appendActivity(preview.taskID, .system, nil, next == .done ? .completed : .actionSucceeded,
                       next == .done ? "All approved actions finished (simulated)" : "\(preview.action.displayName) finished (simulated)",
                       from: from, to: next)
        if next == .done { resolveAttention(forTask: preview.taskID) }
        previews[preview.id] = nil
        let followUp = remaining.first.map { " Next: \($0.displayName)." } ?? ""
        return AppCommandResult(message: "Approved \(preview.action.displayName) — preview data, nothing was changed or posted.\(followUp)")
    }

    func record(_ preview: ActionPreview, decision: ApprovalDecision) throws {
        guard let index = state.tasks.firstIndex(where: { $0.id == preview.taskID }) else { throw AppBackendError.notFound("Task \(preview.taskID)") }
        state.tasks[index].task.approvals.append(ApprovalRecord(id: IDGenerator.approvalID(), taskID: preview.taskID, action: preview.action,
                                                                decision: decision, decidedAt: now, previewFingerprint: preview.fingerprint))
    }
}
