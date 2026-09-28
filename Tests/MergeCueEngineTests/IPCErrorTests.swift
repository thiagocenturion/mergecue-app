import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore
import Testing
@testable import MergeCueEngine

@Suite("IPC error paths")
struct IPCErrorTests {
    @Test("invalid_params: structure and bounds, recorded as rejected_call when the task exists")
    func invalidParams() async throws {
        let h = try await Harness.make()
        let (task, claim) = try await h.claimedTask()

        guard case .failure(let missing) = await h.raw(.claimTask, ["task_id": .string(task.id.rawValue)]) else {
            Issue.record("expected failure")
            return
        }
        #expect(missing.code == .invalidParams)
        guard case .failure(let badID) = await h.raw(.getTask, ["task_id": "not-a-task"]) else {
            Issue.record("expected failure")
            return
        }
        #expect(badID.code == .invalidParams)
        #expect(await h.errorCode(ListTasksParams(limit: 500)) == .invalidParams)
        let longMessage = String(repeating: "x", count: 281)
        #expect(await h.errorCode(UpdateTaskParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, phase: .editing, message: longMessage)) == .invalidParams)
        #expect(await h.errorCode(GetThreadParams(threadID: "chk_0000000000")) == .invalidParams)
        #expect(await h.errorCode(GetDiffParams()) == .invalidParams)

        let rejected = try await h.activities(task.id).filter { $0.kind == .rejectedCall }
        #expect(rejected.count == 2)
        #expect(rejected.allSatisfy { $0.actor == .agent && $0.data["code"] == "invalid_params" })
        #expect(try await h.task(task.id).state == .working, "rejected calls never change state")
    }

    @Test("not_found")
    func notFound() async throws {
        let h = try await Harness.make()
        let unknown = try #require(TaskID(rawValue: "mc_zzzzzz"))
        #expect(await h.errorCode(GetTaskParams(taskID: unknown)) == .notFound)
        #expect(await h.errorCode(ClaimTaskParams(taskID: unknown, agentName: "a", expectedVersion: 1)) == .notFound)
        #expect(await h.errorCode(GetThreadParams(threadID: "thr_0000000000")) == .notFound)
        #expect(await h.errorCode(GetCIFailureParams(checkID: "chk_0000000000")) == .notFound)
        let ref = try #require(ChangeRequestRef(string: "github:github.com/acme/other#7"))
        #expect(await h.errorCode(GetChangeContextParams(changeRef: ref)) == .notFound)
        #expect(try await h.db.auditEntries(limit: 10).contains { $0.action == "claim_task" && $0.outcome == .rejected })
    }

    @Test("version_conflict carries the current version")
    func versionConflict() async throws {
        let h = try await Harness.make()
        let (task, claim) = try await h.claimedTask()
        let result = await h.call(UpdateTaskParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version - 1, phase: .planning, message: "hi"))
        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == .versionConflict)
        #expect(error.retryable)
        #expect(error.data?["current_version"]?.intValue == claim.version)
    }

    @Test("lease_invalid and lease_expired")
    func leases() async throws {
        let h = try await Harness.make()
        let (task, claim) = try await h.claimedTask()
        #expect(await h.errorCode(HeartbeatParams(taskID: task.id, leaseID: "lease_forged")) == .leaseInvalid)
        #expect(await h.errorCode(UpdateTaskParams(taskID: task.id, leaseID: "lease_forged", expectedVersion: claim.version, phase: .testing, message: "x")) == .leaseInvalid)
        // A waiting task has no lease at all.
        let other = try await h.engine.createTask(fromAttention: h.checkItemID)
        #expect(await h.errorCode(HeartbeatParams(taskID: other.id, leaseID: claim.leaseID)) == .leaseInvalid)

        h.clock.advance(by: 700)
        #expect(await h.errorCode(HeartbeatParams(taskID: task.id, leaseID: claim.leaseID)) == .leaseExpired)
        // The expired lease turned the task stale on the spot.
        #expect(try await h.task(task.id).state == .stale)
    }

    @Test("invalid_transition")
    func invalidTransition() async throws {
        let h = try await Harness.make()
        let (task, _) = try await h.claimedTask()
        let working = try await h.task(task.id)
        // Claiming a task that is already working (with the right version) is not a legal transition.
        #expect(await h.errorCode(ClaimTaskParams(taskID: task.id, agentName: "b", expectedVersion: working.version)) == .invalidTransition)
        // User-side: markDone from working is illegal.
        await #expect(throws: EngineError.self) { try await h.engine.markTaskDone(task.id) }
    }

    @Test("terminal_state: agents can never resurrect finished tasks")
    func terminalState() async throws {
        let h = try await Harness.make()
        let (task, claim) = try await h.claimedTask()
        let cancelled = try await h.engine.cancelTask(task.id)
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.lease == nil)
        #expect(await h.errorCode(HeartbeatParams(taskID: task.id, leaseID: claim.leaseID)) == .terminalState)
        #expect(await h.errorCode(ClaimTaskParams(taskID: task.id, agentName: "a", expectedVersion: cancelled.version)) == .terminalState)
        #expect(await h.errorCode(SubmitResultParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: cancelled.version, summary: "done", noChangesReason: "n/a")) == .terminalState)
        #expect(try await h.task(task.id).state == .cancelled)
        // Only the owner can reopen.
        let reopened = try await h.engine.reopenTask(task.id)
        #expect(reopened.state == .waitingForAgent)
    }

    @Test("rate_limited: at most 30 writes per task per minute")
    func rateLimited() async throws {
        let h = try await Harness.make()
        let (task, claim) = try await h.claimedTask()
        // The claim itself counted as one write.
        for _ in 0..<29 {
            _ = try await h.ok(HeartbeatParams(taskID: task.id, leaseID: claim.leaseID))
        }
        let limited = await h.call(HeartbeatParams(taskID: task.id, leaseID: claim.leaseID))
        guard case .failure(let error) = limited else {
            Issue.record("expected rate_limited")
            return
        }
        #expect(error.code == .rateLimited)
        #expect(error.retryable)
        #expect(try await h.activities(task.id).last?.kind == .rejectedCall)
        // Reads are not rate-limited.
        _ = try await h.ok(GetTaskParams(taskID: task.id))
        h.clock.advance(by: 61)
        _ = try await h.ok(HeartbeatParams(taskID: task.id, leaseID: claim.leaseID))
    }

    @Test("cross_scope_reference: foreign artifacts and change refs")
    func crossScope() async throws {
        let h = try await Harness.make()
        let (taskA, claimA) = try await h.claimedTask()
        let taskB = try await h.engine.createTask(fromAttention: h.checkItemID)
        let claimB = try await h.ok(ClaimTaskParams(taskID: taskB.id, agentName: "b", expectedVersion: taskB.version))
        h.workspace.setChanges(["a.swift"])
        let reportB = try await h.ok(ReportChangesParams(
            taskID: taskB.id, leaseID: claimB.leaseID, expectedVersion: claimB.version,
            worktreePath: try #require(try await h.task(taskB.id).checkout?.worktreePath), baseSHA: Fixture.base, changedPaths: ["a.swift"]
        ))
        let result = await h.call(SubmitResultParams(
            taskID: taskA.id, leaseID: claimA.leaseID, expectedVersion: claimA.version, summary: "s",
            artifactIDs: [reportB.artifactID], noChangesReason: "none"
        ))
        guard case .failure(let error) = result else {
            Issue.record("expected cross_scope_reference")
            return
        }
        #expect(error.code == .crossScopeReference)
        #expect(await h.errorCode(SubmitResultParams(taskID: taskA.id, leaseID: claimA.leaseID, expectedVersion: claimA.version, summary: "s", artifactIDs: ["art_0000000000"], noChangesReason: "none")) == .crossScopeReference)

        // Same repo path and number on another provider is a different change request.
        try await h.seed(Fixture.gitlab)
        let gitlabRef = try #require(ChangeRequestRef(string: "gitlab:gitlab.com/acme/payments-api!42"))
        #expect(await h.errorCode(GetDiffParams(taskID: taskA.id, changeRef: gitlabRef)) == .crossScopeReference)
        #expect(try await h.activities(taskA.id).filter { $0.kind == .rejectedCall }.count == 3)
    }

    @Test("path_outside_checkout: other folders, ../ traversal, escaping changed paths; symlinks resolve")
    func pathConfinement() async throws {
        let h = try await Harness.make()
        // A real worktree directory and a symlink to it.
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.workspace.state.update { $0.worktreeRoot = h.root.path }
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        let worktree = try #require(task.checkout?.worktreePath)
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let link = h.root.appending(path: "wt-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: worktree)
        let claim = try await h.ok(ClaimTaskParams(taskID: task.id, agentName: "a", expectedVersion: task.version))
        h.workspace.setChanges(["Sources/Retry.swift"])

        func report(_ path: String, _ changed: [String] = ["Sources/Retry.swift"]) async -> Result<ReportChangesResult, IPCError> {
            await h.call(ReportChangesParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, worktreePath: path, baseSHA: Fixture.base, changedPaths: changed))
        }
        func code(_ result: Result<ReportChangesResult, IPCError>) -> IPCErrorCode? {
            if case .failure(let error) = result { return error.code }
            return nil
        }
        #expect(code(await report(Fixture.checkoutPath)) == .pathOutsideCheckout, "the user's checkout is never accepted")
        #expect(code(await report(worktree + "/../" + (worktree as NSString).lastPathComponent)) == .pathOutsideCheckout)
        #expect(code(await report("relative/path")) == .pathOutsideCheckout)
        #expect(code(await report(worktree, ["../../etc/passwd"])) == .pathOutsideCheckout)
        #expect(code(await report(worktree, ["/etc/passwd"])) == .pathOutsideCheckout)
        // The same directory through a symlink, and absolute changed paths inside the worktree, are accepted.
        let accepted = try await h.ok(ReportChangesParams(
            taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, worktreePath: link.path,
            baseSHA: Fixture.base, changedPaths: [worktree + "/Sources/Retry.swift"]
        ))
        #expect(accepted.verifiedChangedPaths == ["Sources/Retry.swift"])
    }

    @Test("validation_failed: self-certified tests, base mismatch, missing result requirements")
    func validationFailed() async throws {
        let h = try await Harness.make()
        let (task, claim) = try await h.claimedTask()
        let worktree = try #require(task.checkout?.worktreePath)
        #expect(await h.errorCode(ReportTestsParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, command: "swift test", exitCode: 1, status: .passed, output: "")) == .validationFailed)
        #expect(await h.errorCode(ReportTestsParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, command: "swift test", exitCode: 0, status: .passed, failed: 2, output: "")) == .validationFailed)
        #expect(await h.errorCode(ReportChangesParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, worktreePath: worktree, baseSHA: "otherbase", changedPaths: [])) == .validationFailed)
        // Code task without a diff artifact or no_changes_reason.
        #expect(await h.errorCode(SubmitResultParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, summary: "done")) == .validationFailed)
        #expect(try await h.task(task.id).state == .working)
        #expect(try await h.db.artifacts(task: task.id).isEmpty, "rejected reports store nothing")

        // draft_reply needs proposed_reply.
        let question = Fixture.questionItem()
        try await h.db.applySyncBatch(SyncBatch(account: Fixture.github, attentionUpserts: [question], syncedAt: Fixture.start))
        let draft = try await h.engine.createTask(fromAttention: question.id)
        #expect(draft.type == .draftReply)
        #expect(draft.checkout?.policy == .readOnly)
        let draftClaim = try await h.ok(ClaimTaskParams(taskID: draft.id, agentName: "a", expectedVersion: draft.version))
        #expect(await h.errorCode(SubmitResultParams(taskID: draft.id, leaseID: draftClaim.leaseID, expectedVersion: draftClaim.version, summary: "s")) == .validationFailed)
        let ok = try await h.ok(SubmitResultParams(taskID: draft.id, leaseID: draftClaim.leaseID, expectedVersion: draftClaim.version, summary: "s", proposedReply: "Because of X."))
        #expect(ok.state == .readyForReview)
    }

    @Test("unsupported / provider failures map to IPC codes")
    func providerFailures() async throws {
        let h = try await Harness.make()
        let checkID = Fixture.check().shortID
        h.world.state.update { $0.logError = .unsupported(.readFailureLog, reason: "no logs") }
        #expect(await h.errorCode(GetCIFailureParams(checkID: checkID)) == .unsupported)
        h.world.state.update { $0.logError = .rateLimited(resetAt: nil, retryAfter: 30) }
        #expect(await h.errorCode(GetCIFailureParams(checkID: checkID)) == .rateLimited)
        h.world.state.update { $0.logError = .server(status: 502, message: "bad gateway") }
        guard case .failure(let error) = await h.call(GetCIFailureParams(checkID: checkID)) else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == .internalError)
        #expect(error.retryable)
    }

    @Test("Mapping of TaskTransitionError")
    func transitionMapping() {
        let terminal = EngineErrorMapping.ipcError(from: TaskTransitionError.terminalState(.done, trigger: .claim, actor: .agent))
        #expect(terminal.code == .terminalState)
        let actor = EngineErrorMapping.ipcError(from: TaskTransitionError.actorNotPermitted(.working, trigger: .cancel, actor: .agent))
        #expect(actor.code == .invalidTransition)
        let invalid = EngineErrorMapping.ipcError(from: TaskTransitionError.invalidTransition(.waitingForAgent, trigger: .submitResult, actor: .agent))
        #expect(invalid.code == .invalidTransition)
        #expect(EngineErrorMapping.ipcError(from: StoreError.versionConflict(current: 4)).code == .versionConflict)
    }
}
