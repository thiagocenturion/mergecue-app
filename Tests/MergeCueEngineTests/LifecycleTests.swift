import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore
import Testing
@testable import MergeCueEngine

@Suite("Task lifecycle")
struct LifecycleTests {
    @Test("create → claim → update → report_changes → report_tests → submit → preview → approve → perform → done")
    func fullLifecycle() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        let engine = h.engine

        // Create (waiting_for_agent only), isolated worktree prepared at the PR head, user checkout untouched.
        let created = try await engine.createTask(fromAttention: h.threadItemID)
        #expect(created.state == .waitingForAgent)
        #expect(created.type == .fixReview)
        let checkout = try #require(created.checkout)
        #expect(checkout.policy == .isolatedWorktree)
        #expect(checkout.baseSHA == Fixture.base)
        #expect(checkout.mappedCheckoutPath == Fixture.checkoutPath)
        #expect(h.workspace.state.get().prepared.count == 1)
        #expect(h.workspace.appliedPatches.isEmpty)
        #expect(try await h.db.attentionItem(id: h.threadItemID)?.linkedTaskID == created.id)

        // get_task
        let context = try await h.ok(GetTaskParams(taskID: created.id))
        #expect(context.state == .waitingForAgent)
        #expect(context.nextSteps.first?.contains("claim_task") == true)

        // claim
        let claim = try await h.ok(ClaimTaskParams(taskID: created.id, agentName: "claude-code", runID: "run-1", expectedVersion: context.version))
        #expect(claim.state == .working)
        #expect(claim.leaseID.hasPrefix("lease_"))
        #expect(claim.leaseExpiresAt == Fixture.start.addingTimeInterval(600))
        #expect(claim.checkout?.worktreePath == checkout.worktreePath)

        // update_task
        h.clock.advance(by: 60)
        let update = try await h.ok(UpdateTaskParams(taskID: created.id, leaseID: claim.leaseID, expectedVersion: claim.version, phase: .editing, message: "Adding a cap"))
        #expect(update.leaseExpiresAt == Fixture.start.addingTimeInterval(660))

        // report_changes: the app recomputes the diff and compares paths.
        h.workspace.setChanges(["Sources/Retry.swift", "Sources/Other.swift"])
        let changes = try await h.ok(ReportChangesParams(
            taskID: created.id, leaseID: claim.leaseID, expectedVersion: update.version,
            worktreePath: try #require(checkout.worktreePath), baseSHA: Fixture.base, headSHA: "wt222",
            changedPaths: ["./Sources/Retry.swift", "Sources/Missing.swift"]
        ))
        #expect(changes.verifiedChangedPaths == ["Sources/Retry.swift"])
        #expect(changes.unexpectedPaths == ["Sources/Other.swift"])
        #expect(changes.missingPaths == ["Sources/Missing.swift"])
        let diffArtifact = try #require(try await h.db.artifact(id: changes.artifactID))
        #expect(diffArtifact.kind == .diff)
        #expect(diffArtifact.reportedBy == .system)
        #expect(diffArtifact.metadata["changed_count"] == "2")

        // report_tests
        let tests = try await h.ok(ReportTestsParams(
            taskID: created.id, leaseID: claim.leaseID, expectedVersion: changes.version, command: "swift test",
            exitCode: 0, status: .passed, passed: 10, failed: 0, output: "ok"
        ))

        // submit_result
        let submitted = try await h.ok(SubmitResultParams(
            taskID: created.id, leaseID: claim.leaseID, expectedVersion: tests.version, summary: "Capped the backoff.",
            proposedReply: "Done — capped at 30 s.", artifactIDs: [changes.artifactID, tests.artifactID], knownRisks: ["none"]
        ))
        #expect(submitted.state == .readyForReview)
        var task = try await h.task(created.id)
        #expect(task.lease == nil)
        #expect(task.proposedReply == "Done — capped at 30 s.")
        #expect(h.world.writes.isEmpty, "claiming and submitting never write to the provider")

        // Review gate: apply patch first (more actions remain → back to ready_for_review).
        let patchPreview = try await engine.previewAction(created.id, .applyPatch)
        #expect(patchPreview.canApprove)
        #expect(patchPreview.target == Fixture.checkoutPath)
        let patchOutcome = try await engine.perform(previewID: patchPreview.id, approval: PreviewApproval(fingerprint: patchPreview.fingerprint))
        guard case .performed(let stateAfterPatch, _) = patchOutcome else {
            Issue.record("unexpected outcome \(patchOutcome)")
            return
        }
        #expect(stateAfterPatch == .readyForReview)
        #expect(h.workspace.appliedPatches == [Fixture.checkoutPath])

        // Then post the reply (last action → done).
        let replyPreview = try await engine.previewAction(created.id, .postReply)
        #expect(replyPreview.claimant == "claude-code (run run-1)")
        #expect(replyPreview.canApprove)
        #expect(replyPreview.body == "Done — capped at 30 s.")
        let replyOutcome = try await engine.perform(previewID: replyPreview.id, approval: PreviewApproval(fingerprint: replyPreview.fingerprint))
        guard case .performed(let finalState, _) = replyOutcome else {
            Issue.record("unexpected outcome \(replyOutcome)")
            return
        }
        #expect(finalState == .done)
        #expect(h.world.writes.map(\.kind) == ["reply"])
        #expect(h.world.writes.first?.body == "Done — capped at 30 s.")

        task = try await h.task(created.id)
        #expect(task.state == .done)
        #expect(task.approvals.map(\.decision) == [.approved, .approved])

        // Append-only history of every transition.
        let kinds = try await h.activities(created.id).map(\.kind)
        for expected: ActivityKind in [.created, .claimed, .progress, .changesReported, .testsReported, .resultSubmitted, .approved, .actionSucceeded, .completed] {
            #expect(kinds.contains(expected), "missing \(expected)")
        }
        let audit = try await h.db.auditEntries(limit: 100, taskID: created.id)
        #expect(audit.contains { $0.action == "post_reply" && $0.outcome == .attempted })
        #expect(audit.contains { $0.action == "post_reply" && $0.outcome == .succeeded })
        #expect(audit.contains { $0.action == "apply_patch" && $0.outcome == .succeeded })

        // Idempotency: the same fingerprint is never performed twice.
        let again = try? await engine.perform(previewID: replyPreview.id, approval: PreviewApproval(fingerprint: replyPreview.fingerprint))
        #expect(again == nil)
        #expect(h.world.writes.count == 1)
    }

    /// S7: only an agent holding the handoff prompt's code can claim; reads never reveal it.
    @Test("claim_task requires the handoff code; get_task and list_tasks never reveal it")
    func handoffCodeGatesClaims() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        let code = try #require(task.handoffCode)

        let context = try await h.ok(GetTaskParams(taskID: task.id))
        #expect(!(try IPCCoding.encodeValue(context).jsonString()).contains(code))
        #expect(context.nextSteps.contains { $0.contains("handoff_code") })
        let listed = try await h.ok(ListTasksParams())
        #expect(!(try IPCCoding.encodeValue(listed).jsonString()).contains(code))

        let missing = await h.callVerbatim(ClaimTaskParams(taskID: task.id, agentName: "intruder", expectedVersion: context.version))
        guard case .failure(let missingError) = missing else { Issue.record("claim without code succeeded"); return }
        #expect(missingError.code == .validationFailed)
        #expect(missingError.message.contains("handoff code"))
        let wrong = await h.callVerbatim(ClaimTaskParams(taskID: task.id, agentName: "intruder", expectedVersion: context.version, handoffCode: "WRONG000"))
        guard case .failure(let wrongError) = wrong else { Issue.record("claim with a wrong code succeeded"); return }
        #expect(wrongError.code == .validationFailed)
        #expect(try await h.task(task.id).state == .waitingForAgent)
        let history = try await h.engine.taskDetail(task.id).activities
        #expect(history.filter { $0.kind == .rejectedCall }.count == 2)

        // Codes are compared case-insensitively and ignore dashes (agents retype them).
        let loose = String(code.prefix(4)).lowercased() + "-" + String(code.dropFirst(4)).lowercased()
        let claim = await h.callVerbatim(ClaimTaskParams(taskID: task.id, agentName: "Claude Code", runID: "run-42", expectedVersion: context.version, handoffCode: loose))
        guard case .success(let claimed) = claim else { Issue.record("claim with the right code failed: \(claim)"); return }
        #expect(claimed.state == .working)
    }

    /// S2: the engine records the worktree's git dirs, pins every recomputation to them, and rejects report_changes
    /// when the agent repointed the worktree's .git.
    @Test("report_changes is rejected when the worktree's .git was repointed")
    func repointedGitDirRejectsReportChanges() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        let checkout = try #require(task.checkout)
        let pin = try #require(checkout.gitDirs)
        #expect(pin.gitDir.hasSuffix("/.git/worktrees/\(task.id.rawValue)"))
        let claim = try await h.ok(ClaimTaskParams(taskID: task.id, agentName: "codex", expectedVersion: task.version))
        h.workspace.setChanges(["a.swift"])
        h.workspace.state.update { $0.gitDirTampered = true }
        let rejected = await h.call(ReportChangesParams(
            taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version,
            worktreePath: try #require(checkout.worktreePath), baseSHA: try #require(checkout.baseSHA), changedPaths: ["a.swift"]
        ))
        guard case .failure(let error) = rejected else { Issue.record("report_changes accepted a tampered worktree"); return }
        #expect(error.code == .validationFailed)
        #expect(error.message.contains(".git"))
        #expect(h.workspace.state.get().pinnedCalls.last?.gitDirs == pin)
        #expect(try await h.engine.taskDetail(task.id).activities.contains { $0.kind == .rejectedCall })
        #expect(try await h.task(task.id).artifactIDs.isEmpty)
    }

    /// S11: a reply with zero-width / invisible characters is shown and posted without them, and the fingerprint
    /// covers exactly the posted bytes.
    @Test("Invisible characters are stripped from the reply preview and the posted reply")
    func invisibleCharactersAreStrippedBeforeApproval() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        let task = try await h.submittedTask(reply: "Fixed\u{200B} the cap.\u{2060}\u{E0041}")
        let preview = try await h.engine.previewAction(task.id, .postReply)
        #expect(preview.body == "Fixed the cap.")
        #expect(preview.contentDigest == ContentDigest.sha256Hex("Fixed the cap."))
        #expect(preview.warnings.contains { $0.contains("invisible") && $0.contains("U+200B") })
        let outcome = try await h.engine.perform(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint))
        guard case .performed = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(h.world.writes.first?.body == "Fixed the cap.")
    }

    @Test("Tasks created before handoff codes existed can still be claimed without one")
    func legacyTaskNeedsNoCode() async throws {
        let h = try await Harness.make()
        var task = try await h.engine.createTask(fromAttention: h.threadItemID)
        task.handoffCode = nil
        task.version += 1
        try await h.db.updateTask(task, expectedVersion: task.version - 1)
        let claim = await h.callVerbatim(ClaimTaskParams(taskID: task.id, agentName: "codex", expectedVersion: task.version))
        guard case .success = claim else { Issue.record("legacy claim failed: \(claim)"); return }
    }

    @Test("Handoff command copied but never executed: task stays waiting_for_agent")
    func copiedCommandStaysWaiting() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        let handoff = try await h.engine.handoff(for: task.id)
        let code = try #require(task.handoffCode)
        #expect(code.count == HandoffCode.length)
        #expect(handoff.handoffCode == code)
        #expect(handoff.command == "Work on MergeCue task \(task.id.rawValue) (handoff code: \(code)). Use MergeCue MCP for context and status updates. Work only in the designated checkout. Stop before publishing anything.")
        #expect(handoff.statusText == "Task ready to start")
        #expect(handoff.workingDirectory == task.checkout?.worktreePath)
        try await h.engine.recordHandoffCopied(task.id, agentName: "Claude Code")

        h.clock.advance(by: 6 * 3600)
        let expired = await h.engine.sweepExpiredLeases()
        #expect(expired.isEmpty)
        let after = try await h.task(task.id)
        #expect(after.state == .waitingForAgent)
        #expect(after.lease == nil)
        #expect(h.world.writes.isEmpty)
        #expect(try await h.activities(task.id).contains { $0.kind == .note && $0.message.contains("Handoff command copied") })
    }

    @Test("Agent claims, then crashes: working → stale after lease expiry (never done), retry and re-claim work")
    func crashAfterClaimBecomesStale() async throws {
        let h = try await Harness.make()
        let (task, claim) = try await h.claimedTask(agent: "codex")

        h.clock.advance(by: 599)
        #expect(await h.engine.sweepExpiredLeases().isEmpty)
        #expect(try await h.task(task.id).state == .working)

        h.clock.advance(by: 2)
        #expect(await h.engine.sweepExpiredLeases() == [task.id])
        let stale = try await h.task(task.id)
        #expect(stale.state == .stale)
        let activity = try #require(try await h.activities(task.id).last { $0.kind == .stale })
        #expect(activity.message.contains("No heartbeat from codex since 2026-01-01T00:00:00Z"))
        #expect(activity.actor == .system)

        // The old lease is dead.
        #expect(await h.errorCode(HeartbeatParams(taskID: task.id, leaseID: claim.leaseID)) == .leaseExpired)

        // Re-claim from stale with a new lease…
        let reclaim = try await h.ok(ClaimTaskParams(taskID: task.id, agentName: "codex", expectedVersion: stale.version))
        #expect(reclaim.state == .working)
        #expect(reclaim.leaseID != claim.leaseID)

        // …or the owner retries.
        h.clock.advance(by: 601)
        await h.engine.sweepExpiredLeases()
        let retried = try await h.engine.retryTask(task.id)
        #expect(retried.state == .waitingForAgent)
        #expect(retried.lease == nil)
    }

    @Test("The stale monitor runs on the injected clock")
    func staleMonitorUsesClock() async throws {
        let h = try await Harness.make(.init(leaseDuration: 60, staleCheckInterval: 30))
        let (task, _) = try await h.claimedTask()
        await h.engine.start()
        defer { Task { await h.engine.stop() } }
        for _ in 0..<3 {
            await h.clock.waitForSleepers(count: 1)
            h.clock.advance(by: 30)
        }
        await h.clock.waitForSleepers(count: 1)
        #expect(try await h.task(task.id).state == .stale)
        await h.engine.stop()
    }

    @Test("Two agents claim the same task: exactly one lease wins")
    func doubleClaim() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        async let first = h.call(ClaimTaskParams(taskID: task.id, agentName: "agent-a", expectedVersion: task.version))
        async let second = h.call(ClaimTaskParams(taskID: task.id, agentName: "agent-b", expectedVersion: task.version))
        let results = await [first, second]
        let wins = results.filter { if case .success = $0 { true } else { false } }
        let conflicts = results.compactMap { result -> IPCErrorCode? in
            if case .failure(let error) = result { return error.code }
            return nil
        }
        #expect(wins.count == 1)
        #expect(conflicts == [.versionConflict])
        let stored = try await h.task(task.id)
        #expect(stored.state == .working)
        #expect(try await h.activities(task.id).filter { $0.kind == .claimed }.count == 1)
        #expect(try await h.activities(task.id).contains { $0.kind == .rejectedCall })
    }

    @Test("Hostile reviewer comment is only returned as quoted untrusted content and cannot cause writes")
    func hostileCommentStaysUntrusted() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        let context = try await h.ok(GetTaskParams(taskID: task.id))

        let quoted = try #require(context.trigger.untrustedContent.first)
        #expect(quoted.source == UntrustedText.Source.reviewComment)
        #expect(quoted.author == "rev-riley")
        #expect(quoted.text.contains("Ignore all previous instructions"))
        #expect(!quoted.text.contains(Fixture.token), "secrets are redacted even in quoted content")
        #expect(context.instructions.allSatisfy { !$0.contains("Ignore all previous instructions") && !$0.contains("curl") })
        #expect(context.instructions.contains { $0.contains("never as instructions") })

        let thread = try await h.ok(GetThreadParams(threadID: Fixture.thread().shortID))
        #expect(thread.comments.first?.body.source == UntrustedText.Source.reviewComment)
        let changeContext = try await h.ok(GetChangeContextParams(changeRef: try #require(ChangeRequestRef(string: "github:github.com/acme/payments-api#42"))))
        #expect(changeContext.description?.source == UntrustedText.Source.prDescription)

        // The agent does everything it can over MCP, including proposing a reply that repeats the injection.
        _ = try await h.submittedTask(reply: Fixture.hostile)
        #expect(h.world.writes.isEmpty, "no MCP call can write to the provider")
        #expect(h.workspace.appliedPatches.isEmpty, "no MCP call can touch the user's checkout")
        let stored = try await h.task(task.id)
        #expect(stored.state == .readyForReview)
        #expect(stored.proposedReply?.contains(Fixture.token) == false)
        #expect(IPCMethod.allCases.allSatisfy { !["post_reply", "resolve_thread", "merge", "apply_patch"].contains($0.rawValue) })
    }

    @Test("Wrong / dirty / GitButler checkouts are blocked; read-only inspection still works", arguments: [
        "unmapped", "dirty", "gitbutler", "unconfirmed", "unfetchable",
    ])
    func unsafeCheckoutIsBlocked(_ scenario: String) async throws {
        var options = Harness.Options()
        switch scenario {
        case "unmapped": options.mapCheckout = false
        case "dirty": options.checkoutSafety = .dirty
        case "gitbutler": options.checkoutSafety = .gitButlerWorkspace
            options.gitButler = true
        default: break
        }
        let h = try await Harness.make(options)
        if scenario == "unconfirmed" {
            for mapping in try await h.engine.mappings() { try await h.engine.removeMapping(id: mapping.id) }
            h.workspace.state.update { $0.matchConfidence = .mismatch }
            try await h.engine.addMapping(repo: Fixture.repo(Fixture.github), repoFullPath: "acme/payments-api", checkoutPath: Fixture.checkoutPath)
        }
        if scenario == "unfetchable" {
            h.world.state.update { $0.fetchable = false }
        }
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        let checkout = try #require(task.checkout)
        #expect(checkout.policy == .blocked)
        #expect(checkout.blockedReason?.hasPrefix("Blocked: map a safe checkout") == true)
        #expect(checkout.worktreePath == nil)
        #expect(checkout.isGitButlerManaged == (scenario == "gitbutler"))
        #expect(h.workspace.state.get().prepared.isEmpty)
        #expect(h.workspace.appliedPatches.isEmpty)

        // Read-only inspection and drafting still possible.
        let context = try await h.ok(GetTaskParams(taskID: task.id))
        #expect(context.checkout?.policy == .blocked)
        #expect(context.instructions.contains { $0.contains("Blocked: map a safe checkout") })
        // S6: the (possibly git-stderr-derived) reason travels in checkout.blocked_reason, never in trusted text.
        let reasonDetail = try #require(checkout.blockedReason?.replacingOccurrences(of: "Blocked: map a safe checkout", with: ""))
        if reasonDetail.count > 8 {
            #expect(!context.instructions.joined(separator: "\n").contains(reasonDetail))
        }
        #expect(context.checkout?.blockedReason != nil)
        #expect(context.untrustedFields?.contains("checkout.blocked_reason") == true)
        let claim = try await h.ok(ClaimTaskParams(taskID: task.id, agentName: "codex", expectedVersion: context.version))
        let edit = await h.call(ReportChangesParams(
            taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, worktreePath: Fixture.checkoutPath,
            baseSHA: Fixture.base, changedPaths: ["README.md"]
        ))
        guard case .failure(let error) = edit else {
            Issue.record("edits must be refused")
            return
        }
        #expect(error.code == .pathOutsideCheckout)
        let submitted = try await h.ok(SubmitResultParams(
            taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, summary: "Investigated only.",
            noChangesReason: "No safe checkout is mapped."
        ))
        #expect(submitted.state == .readyForReview)
        await #expect(throws: EngineError.self) { try await h.engine.previewAction(task.id, .applyPatch) }
    }

    @Test("Owner declines a preview or discards the result: no provider write, history records the rejection")
    func ownerRejects() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        let task = try await h.submittedTask()
        let preview = try await h.engine.previewAction(task.id, .postReply)
        try await h.engine.declinePreview(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint, note: "Tone"))
        #expect(h.world.writes.isEmpty)

        var stored = try await h.task(task.id)
        #expect(stored.state == .readyForReview)
        #expect(stored.approvals.last?.decision == .rejected)
        #expect(try await h.db.approvals(task: task.id).last?.decision == .rejected)
        #expect(try await h.activities(task.id).contains { $0.kind == .rejected && $0.message.contains("nothing was written") })
        #expect(try await h.db.auditEntries(limit: 50, taskID: task.id).contains { $0.action == "post_reply" && $0.outcome == .rejected })
        // A declined preview cannot be performed afterwards.
        await #expect(throws: EngineError.previewExpired) {
            try await h.engine.perform(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint))
        }

        // "Discard and retry"
        stored = try await h.engine.rejectResult(task.id, note: "Wrong approach")
        #expect(stored.state == .waitingForAgent)
        #expect(stored.proposedReply == nil)
        #expect(try await h.activities(task.id).last?.kind == .rejected)
        #expect(!(try await h.db.artifacts(task: task.id)).isEmpty, "artifacts are kept")
        #expect(h.world.writes.isEmpty)
    }

    @Test("Head moved after the preview: the write is blocked, nothing is posted")
    func staleHeadBlocksWrite() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        let task = try await h.submittedTask()
        let preview = try await h.engine.previewAction(task.id, .postReply)
        h.world.setHead(Fixture.cr(), sha: "forcepushed999", at: Fixture.start)

        let outcome = try await h.engine.perform(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint))
        guard case .blocked(let reason) = outcome else {
            Issue.record("expected blocked, got \(outcome)")
            return
        }
        #expect(reason.contains("head moved"))
        #expect(h.world.writes.isEmpty)
        let stored = try await h.task(task.id)
        #expect(stored.state == .blocked)
        #expect(stored.lastError?.code == "stale_state")
        #expect(try await h.activities(task.id).contains { $0.kind == .actionBlocked })
        let audit = try await h.db.auditEntries(limit: 50, taskID: task.id)
        #expect(audit.contains { $0.outcome == .attempted })
        #expect(audit.contains { $0.outcome == .rejected && $0.detail.contains("blocked") })
    }

    @Test("Thread changed after the preview: resolve is blocked")
    func changedThreadBlocksWrite() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        let task = try await h.submittedTask()
        let preview = try await h.engine.previewAction(task.id, .resolveThread)
        #expect(preview.canApprove)
        h.world.setThread(Fixture.reviewThread(Fixture.cr(), extraComments: [
            ReviewComment(id: "c2", author: Fixture.reviewer, body: "Wait, one more thing", createdAt: Fixture.start.addingTimeInterval(5)),
        ]))
        let outcome = try await h.engine.perform(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint))
        guard case .blocked = outcome else {
            Issue.record("expected blocked, got \(outcome)")
            return
        }
        #expect(h.world.writes.isEmpty)
        #expect(try await h.task(task.id).state == .blocked)
    }

    @Test("Stale head also blocks applying the patch to the user's checkout")
    func staleHeadBlocksPatch() async throws {
        let h = try await Harness.make()
        let task = try await h.submittedTask()
        let preview = try await h.engine.previewAction(task.id, .applyPatch)
        h.world.setHead(Fixture.cr(), sha: "forcepushed999", at: Fixture.start)
        let outcome = try await h.engine.perform(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint))
        guard case .blocked = outcome else {
            Issue.record("expected blocked, got \(outcome)")
            return
        }
        #expect(h.workspace.appliedPatches.isEmpty)
    }
}
