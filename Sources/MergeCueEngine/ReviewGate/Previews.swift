import Foundation
import MergeCueCore
import MergeCueStore

// The review gate, part 1: action previews. A preview is the exact content the owner approves (reply text,
// resolution, or the patch recomputed from the task worktree), fingerprinted with `MergeCueCoding.digest` over
// the task version, target, content digest, change request head and thread state. It expires after
// `previewLifetime` and is single-use.

/// What a preview fingerprint covers.
struct PreviewFingerprintInput: Codable, Hashable {
    var taskID: TaskID
    var taskVersion: Int
    var action: RemoteActionKind
    var target: String
    var contentDigest: String
    var headSHA: String?
    var threadVersion: String?
    var checkoutHeadSHA: String?
}

extension MergeCueEngine {
    /// Largest patch MergeCue previews/applies.
    static let maxPatchBytes = 1024 * 1024

    /// Builds the preview of `action` for a task in `ready_for_review`. Throws `disabledByPolicy` for
    /// `request_changes` / `commit_and_push` / `merge`. A preview that cannot be approved (writes off, capability
    /// missing, unsafe checkout, patch conflicts) is still returned with `canApprove == false` and the reason.
    public func previewAction(_ taskID: TaskID, _ action: RemoteActionKind) async throws(EngineError) -> ReviewPreview {
        try await uiCall {
            guard RemoteWritePolicy.isEnabled(action) else { throw EngineError.disabledByPolicy(action) }
            let task = try await requireTask(taskID)
            guard task.state == .readyForReview else {
                throw EngineError.invalidTransition("Previews are available when the task is ready for review (it is \(task.state.displayName.lowercased())).")
            }
            let preview = switch action {
            case .applyPatch: try await previewApplyPatch(task)
            case .postReply: try await previewPostReply(task)
            case .resolveThread: try await previewResolveThread(task)
            case .requestChanges, .commitAndPush, .merge: throw EngineError.disabledByPolicy(action)
            }
            previews[preview.id] = preview
            return preview
        }
    }

    /// Previews currently awaiting a decision for a task.
    public func pendingPreviews(for taskID: TaskID) -> [ReviewPreview] {
        previews.values.filter { $0.taskID == taskID && $0.expiresAt >= now }.sorted { $0.createdAt < $1.createdAt }
    }

    func forgetPreviews(for taskID: TaskID) {
        previews = previews.filter { $0.value.taskID != taskID }
    }

    // MARK: Builders

    private func previewPostReply(_ task: MCTask) async throws -> ReviewPreview {
        guard let reply = task.proposedReply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.unsupported("The agent did not propose a reply for this task.")
        }
        guard let threadKey = task.origin.thread else {
            throw EngineError.unsupported("This task has no review thread to reply to.")
        }
        let snapshot = try await database.snapshot(task.origin.changeRequest)
        let thread = snapshot?.thread(threadKey)
        var (canApprove, reason) = try await remoteGate(task, capability: .createReply)
        if thread == nil, canApprove {
            canApprove = false
            reason = "The review thread is no longer in the latest sync."
        }
        return try makePreview(
            task: task, action: .postReply,
            title: "Post reply on \(task.origin.changeRequestRef.shortLabel)",
            target: Self.threadTarget(threadKey, thread: thread, ref: task.origin.changeRequestRef),
            body: reply, rawContent: reply,
            headSHA: snapshot?.summary.headSHA ?? task.trigger.headSHA,
            threadVersion: thread.map(Self.threadVersion),
            warnings: thread?.isOutdated == true ? ["The comment's diff position is outdated (the code moved since it was written)."] : [],
            canApprove: canApprove, blockedReason: reason
        )
    }

    private func previewResolveThread(_ task: MCTask) async throws -> ReviewPreview {
        guard let threadKey = task.origin.thread else {
            throw EngineError.unsupported("This task has no review thread to resolve.")
        }
        let snapshot = try await database.snapshot(task.origin.changeRequest)
        let thread = snapshot?.thread(threadKey)
        var (canApprove, reason) = try await remoteGate(task, capability: .resolveThread)
        if canApprove {
            if thread == nil {
                (canApprove, reason) = (false, "The review thread is no longer in the latest sync.")
            } else if thread?.isResolvable == false {
                (canApprove, reason) = (false, "This thread cannot be resolved on \(task.origin.providerKind.displayName).")
            } else if thread?.isResolved == true {
                (canApprove, reason) = (false, "The thread is already resolved.")
            }
        }
        let body = "Mark the thread as resolved."
        return try makePreview(
            task: task, action: .resolveThread,
            title: "Resolve thread on \(task.origin.changeRequestRef.shortLabel)",
            target: Self.threadTarget(threadKey, thread: thread, ref: task.origin.changeRequestRef),
            body: body, rawContent: "resolve:\(threadKey.id)",
            headSHA: snapshot?.summary.headSHA ?? task.trigger.headSHA,
            threadVersion: thread.map(Self.threadVersion),
            warnings: [], canApprove: canApprove, blockedReason: reason
        )
    }

    private func previewApplyPatch(_ task: MCTask) async throws -> ReviewPreview {
        guard task.type.isCodeTask, let checkout = task.checkout, checkout.policy == .isolatedWorktree,
              let worktree = checkout.worktreePath, let base = checkout.baseSHA, let mapped = checkout.mappedCheckoutPath
        else {
            throw EngineError.unsupported("This task has no isolated worktree; there is no patch to apply.")
        }
        let changes = try await env.workspace.changes(inWorktree: worktree, since: base, maxBytes: Self.maxPatchBytes)
        var warnings: [String] = []
        var canApprove = true
        var reason: String?
        if changes.unifiedDiff.isEmpty {
            (canApprove, reason) = (false, "The worktree has no changes to apply.")
        } else if changes.truncated {
            (canApprove, reason) = (false, "The patch is too large to preview completely; apply it manually.")
        }
        let latestDiff = try await database.artifacts(task: task.id).last { $0.kind == .diff }
        if let latestDiff, latestDiff.content != BoundedText.truncate(SecretRedactor.redact(changes.unifiedDiff), maxBytes: Self.maxDiffArtifactBytes).text {
            warnings.append("The worktree changed since the agent's last report_changes.")
        }
        var checkoutHead: String?
        if canApprove {
            let check = try await env.workspace.checkPatch(changes.unifiedDiff, into: mapped, expectedHeadSHA: nil)
            checkoutHead = check.targetHeadSHA
            if check.targetSafety != .safe {
                (canApprove, reason) = (false, "\(Self.blockedCheckoutPrefix) — \(mapped): \(check.targetSafety.displayName.lowercased()).")
            } else if !check.canApply {
                (canApprove, reason) = (false, "The patch does not apply cleanly: \(check.problems.joined(separator: "; "))")
            }
        }
        let snapshot = try await database.snapshot(task.origin.changeRequest)
        if let head = snapshot?.summary.headSHA, head.caseInsensitiveCompare(base) != .orderedSame {
            warnings.append("The \(task.origin.providerKind.changeRequestAbbreviation) head moved since the worktree was prepared (\(base.prefix(12)) → \(head.prefix(12))).")
        }
        return try makePreview(
            task: task, action: .applyPatch,
            title: "Apply patch to \(mapped)",
            target: mapped,
            body: SecretRedactor.redact(changes.unifiedDiff), rawContent: changes.unifiedDiff,
            headSHA: base, threadVersion: nil, checkoutHeadSHA: checkoutHead,
            warnings: warnings, canApprove: canApprove, blockedReason: reason
        )
    }

    // MARK: Helpers

    /// Account writes toggle + provider capability + (for remote writes) a stored credential.
    func remoteGate(_ task: MCTask, capability: Capability) async throws -> (Bool, String?) {
        let account = try await requireAccount(task.origin.account)
        guard account.writesEnabled else {
            return (false, EngineError.writesDisabled(account: account.displayLabel).errorDescription)
        }
        let support = env.providers.capabilities(for: account).support(for: capability)
        guard support.isUsable else {
            return (false, "\(capability.displayName): \(support.userFacingDescription)")
        }
        return (true, nil)
    }

    private func makePreview(
        task: MCTask,
        action: RemoteActionKind,
        title: String,
        target: String,
        body: String,
        rawContent: String,
        headSHA: String?,
        threadVersion: String?,
        checkoutHeadSHA: String? = nil,
        warnings: [String],
        canApprove: Bool,
        blockedReason: String?
    ) throws -> ReviewPreview {
        let contentDigest = ContentDigest.sha256Hex(rawContent)
        let fingerprint = try MergeCueCoding.digest(PreviewFingerprintInput(
            taskID: task.id, taskVersion: task.version, action: action, target: target, contentDigest: contentDigest,
            headSHA: headSHA, threadVersion: threadVersion, checkoutHeadSHA: checkoutHeadSHA
        ))
        let createdAt = now
        return ReviewPreview(
            id: ids.previewID(), taskID: task.id, taskVersion: task.version, action: action, title: title,
            target: target, body: body, headSHA: headSHA, threadVersion: threadVersion, checkoutHeadSHA: checkoutHeadSHA,
            contentDigest: contentDigest, fingerprint: fingerprint, warnings: warnings, canApprove: canApprove,
            blockedReason: blockedReason, createdAt: createdAt, expiresAt: createdAt.addingTimeInterval(env.previewLifetime),
            isSimulated: env.isDemo
        )
    }

    /// Resolution + the ordered comment ids/edit times: any new reply, edit or (un)resolution changes it.
    static func threadVersion(_ thread: ReviewThread) -> String {
        let resolved = thread.isResolved.map { $0 ? "resolved" : "open" } ?? "n/a"
        let comments = thread.comments.map { "\($0.id)@\(($0.updatedAt ?? $0.createdAt).timeIntervalSinceReferenceDate)" }
        return ContentDigest.sha256Hex("\(resolved)|\(comments.joined(separator: ","))")
    }

    static func threadTarget(_ key: ThreadKey, thread: ReviewThread?, ref: ChangeRequestRef) -> String {
        var target = "Thread \(key.shortID) on \(ref.string)"
        if let anchor = thread?.anchor {
            target += " (\(anchor.path)\(anchor.line.map { ":\($0)" } ?? ""))"
        }
        return target
    }
}
