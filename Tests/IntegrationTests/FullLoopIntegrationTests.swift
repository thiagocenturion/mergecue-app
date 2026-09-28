import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueFixtures
import MergeCueIPC
import MergeCueRuntime
import MergeCueStore
import Testing

/// The Phase 3/4 gates over real processes: demo runtime + IPC server ← `mergecue-mcp` ← `mergecue-agent-sim`.
@Suite("Full loop over real processes")
struct FullLoopIntegrationTests {
    /// Creates a task from the step-1 GitHub blocking comment and checks its isolated worktree.
    static func blockingCommentTask(_ h: DemoHarness) async throws -> MCTask {
        await h.runtime.refresh()
        let item = try #require(try await h.threadItem(.github, threadRemoteID: GitHubFixtures.IDs.blockingThread))
        let task = try await h.engine.createTask(fromAttention: item.id)
        #expect(task.state == .waitingForAgent)
        let detail = try await h.engine.taskDetail(task.id)
        let checkout = try #require(detail.task.checkout, "checkout not planned")
        #expect(checkout.policy == .isolatedWorktree, "\(checkout.blockedReason ?? "")")
        #expect(checkout.baseSHA == h.scenario.repository.headSHA)
        let worktree = try #require(checkout.worktreePath)
        #expect(FileManager.default.fileExists(atPath: worktree + "/Sources/Payments/ChargeService.swift"))
        return detail.task
    }

    @Test func agentLoopThenReviewGate() async throws {
        let h = try await DemoHarness.start(ipc: true)
        defer { h.home.remove() }
        let task = try await Self.blockingCommentTask(h)

        // Copying the handoff command changes nothing remotely and keeps the task waiting.
        let handoff = try await h.engine.handoff(for: task.id)
        #expect(handoff.statusText == "Task ready to start")
        try await h.engine.recordHandoffCopied(task.id, agentName: "Claude Code")
        #expect(try await h.engine.taskDetail(task.id).task.state == .waitingForAgent)
        #expect(h.scenario.providerWrites(.github).isEmpty)

        // A real agent client: mergecue-agent-sim → mergecue-mcp → IPC → engine.
        let (report, output) = try await h.runAgentSim(scenario: "happy", taskID: task.id)
        #expect(report["passed"]?.boolValue == true, "\(report.failedSimSteps) stderr: \(output.stderr.suffix(2000))")

        var detail = try await h.engine.taskDetail(task.id)
        #expect(detail.task.state == .readyForReview)
        #expect(detail.task.proposedReply?.isEmpty == false)
        let diff = try #require(detail.artifacts.first { $0.kind == .diff })
        #expect(diff.reportedBy == .system)
        #expect(diff.content.contains("mergecue-agent-sim.txt"))
        #expect(detail.artifacts.contains { $0.kind == .testRun })
        #expect(detail.activities.contains { $0.kind == .claimed })
        // Claim / reports / submit never wrote to a provider.
        for kind in ProviderKind.allCases {
            #expect(h.scenario.providerWrites(kind).isEmpty, "\(kind): \(h.scenario.providerWrites(kind))")
        }

        // Review changes = diff recomputed by the app from the worktree.
        let review = try await h.engine.reviewChanges(task.id)
        #expect(review.changedPaths.map(\.path).contains("mergecue-agent-sim.txt"))

        // Apply patch: preview + approve → patch lands in the demo checkout (nothing committed or pushed).
        let checkoutPath = MergeCuePaths.fileSystemPath(h.scenario.repository.checkout)
        let patchPreview = try await h.engine.previewAction(task.id, .applyPatch)
        #expect(patchPreview.canApprove, "\(patchPreview.blockedReason ?? "")")
        #expect(patchPreview.isSimulated)
        let applied = try await h.engine.perform(previewID: patchPreview.id, approval: PreviewApproval(fingerprint: patchPreview.fingerprint))
        guard case .performed(let stateAfterPatch, _) = applied else {
            Issue.record("apply patch: \(applied)")
            return
        }
        #expect(stateAfterPatch == .readyForReview)
        #expect(FileManager.default.fileExists(atPath: checkoutPath + "/mergecue-agent-sim.txt"))

        // Reply with remote writes off: previewed but not approvable; performing is refused, nothing posted.
        let blockedReply = try await h.engine.previewAction(task.id, .postReply)
        #expect(!blockedReply.canApprove)
        await #expect(throws: EngineError.writesDisabled(account: "GitHub (demo)")) {
            _ = try await h.engine.perform(previewID: blockedReply.id, approval: PreviewApproval(fingerprint: blockedReply.fingerprint))
        }
        #expect(h.scenario.providerWrites(.github).isEmpty)

        // Owner enables writes for the GitHub demo account → resolve, then reply.
        try await h.engine.setWritesEnabled(GitHubFixtures.accountKey, true)
        let resolvePreview = try await h.engine.previewAction(task.id, .resolveThread)
        #expect(resolvePreview.canApprove, "\(resolvePreview.blockedReason ?? "")")
        let resolved = try await h.engine.perform(previewID: resolvePreview.id, approval: PreviewApproval(fingerprint: resolvePreview.fingerprint))
        guard case .performed(.readyForReview, _) = resolved else {
            Issue.record("resolve: \(resolved)")
            return
        }
        let replyPreview = try await h.engine.previewAction(task.id, .postReply)
        #expect(replyPreview.canApprove, "\(replyPreview.blockedReason ?? "")")
        let replied = try await h.engine.perform(previewID: replyPreview.id, approval: PreviewApproval(fingerprint: replyPreview.fingerprint))
        guard case .performed(.done, _) = replied else {
            Issue.record("reply: \(replied)")
            return
        }

        // Exactly the approved writes reached the (stub) provider.
        let writes = h.scenario.providerWrites(.github)
        #expect(writes.count == 2, "\(writes.map { "\($0.method) \($0.url.path)" })")
        let replyRequest = try #require(writes.first { $0.url.path.hasSuffix("/replies") })
        #expect(replyRequest.url.path.contains("/repos/acme/payments-api/pulls/42/comments/"))
        #expect(replyRequest.jsonBody?["body"]?.stringValue == detail.task.proposedReply)
        #expect(writes.contains { $0.url.path.hasSuffix("/graphql") && String(decoding: $0.body ?? Data(), as: UTF8.self).contains("MergeCueResolveThread") })
        #expect(h.scenario.providerWrites(.gitlab).isEmpty && h.scenario.providerWrites(.bitbucketCloud).isEmpty)

        // Audit trail: every attempt, refusal and success.
        let audit = try await h.engine.auditLog(taskID: task.id)
        func has(_ action: String, _ outcome: AuditEntry.Outcome) -> Bool {
            audit.contains { $0.action == action && $0.outcome == outcome }
        }
        #expect(has("apply_patch", .succeeded))
        #expect(has("post_reply", .rejected))
        #expect(has("resolve_thread", .succeeded))
        #expect(has("post_reply", .succeeded))
        detail = try await h.engine.taskDetail(task.id)
        #expect(detail.task.state == .done)
        await h.runtime.stop()
    }

    @Test func staleHeadBlocksTheWrite() async throws {
        let h = try await DemoHarness.start(ipc: true)
        defer { h.home.remove() }
        let task = try await Self.blockingCommentTask(h)
        var (report, output) = try await h.runAgentSim(scenario: "happy", taskID: task.id)
        #expect(report["passed"]?.boolValue == true, "\(report.failedSimSteps) \(output.stderr.suffix(1500))")
        try await h.engine.setWritesEnabled(GitHubFixtures.accountKey, true)
        let checkoutFile = MergeCuePaths.fileSystemPath(h.scenario.repository.checkout) + "/mergecue-agent-sim.txt"

        // The PR is force-pushed after the patch preview: applying is blocked, nothing lands in the checkout.
        let patch = try await h.engine.previewAction(task.id, .applyPatch)
        #expect(patch.canApprove, "\(patch.blockedReason ?? "")")
        let newHead = try h.scenario.simulateForcePush(.github)
        #expect(newHead != h.scenario.repository.headSHA)
        let applied = try await h.engine.perform(previewID: patch.id, approval: PreviewApproval(fingerprint: patch.fingerprint))
        guard case .blocked(let patchReason) = applied else {
            Issue.record("expected a blocked patch, got \(applied)")
            return
        }
        #expect(patchReason.contains("head moved"))
        #expect(!FileManager.default.fileExists(atPath: checkoutFile))
        #expect(try await h.engine.taskDetail(task.id).task.state == .blocked)

        // Back to the agent; the reply previewed against the old head is blocked the same way, nothing posted.
        _ = try await h.engine.unblockTask(task.id)
        (report, output) = try await h.runAgentSim(scenario: "happy", taskID: task.id)
        #expect(report["passed"]?.boolValue == true, "\(report.failedSimSteps) \(output.stderr.suffix(1500))")
        let reply = try await h.engine.previewAction(task.id, .postReply)
        #expect(reply.canApprove, "\(reply.blockedReason ?? "")")
        let outcome = try await h.engine.perform(previewID: reply.id, approval: PreviewApproval(fingerprint: reply.fingerprint))
        guard case .blocked(let reason) = outcome else {
            Issue.record("expected blocked, got \(outcome)")
            return
        }
        #expect(reason.contains("head moved"))
        #expect(h.scenario.providerWrites(.github).isEmpty)
        #expect(try await h.engine.taskDetail(task.id).task.state == .blocked)
        let audit = try await h.engine.auditLog(taskID: task.id)
        #expect(audit.filter { $0.outcome == .rejected && $0.detail.hasPrefix("blocked:") }.count == 2)
        await h.runtime.stop()
    }
}
