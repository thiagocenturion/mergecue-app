import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore
import Testing
@testable import MergeCueEngine

@Suite("Accounts, inbox, gate policy, redaction and data")
struct AccountsInboxDataTests {
    // MARK: Accounts

    @Test("connect probes currentUser, stores the credential first, writes stay off, Sync is told")
    func connect() async throws {
        let h = try await Harness.make()
        h.world.state.update { $0.users["gitlab"] = ProviderUser(remoteID: "2002", username: "mona", displayName: "Mona", grantedScopes: ["read_api"]) }
        let account = try await h.engine.connectAccount(AccountConnectionRequest(
            instance: .gitlabCom, method: .personalAccessToken, credential: .bearer("glpat-secretsecretsecret1234"), label: "Work"
        ))
        #expect(account.id == Fixture.gitlab)
        #expect(!account.writesEnabled)
        #expect(account.label == "Work")
        #expect(try h.credentials.load(for: Fixture.gitlab) != nil)
        #expect(try await h.db.account(Fixture.gitlab) != nil)
        #expect(await h.sync.accountsDidChangeCount == 1)
        let states = try await h.engine.accountStates()
        #expect(states.map(\.account.id).contains(Fixture.gitlab))
        #expect(states.first { $0.id == Fixture.gitlab }?.capabilities.provider == .gitlab)

        try await h.engine.setWritesEnabled(Fixture.gitlab, true)
        #expect(try await h.db.account(Fixture.gitlab)?.writesEnabled == true)
        try await h.engine.setAccountLabel(Fixture.gitlab, label: "  ")
        #expect(try await h.db.account(Fixture.gitlab)?.label == nil)
        try await h.engine.setSelectedNamespaces(Fixture.gitlab, ["acme"])
        #expect(try await h.db.account(Fixture.gitlab)?.selectedNamespaces == ["acme"])
        // Reconnecting keeps the owner's writes choice.
        let again = try await h.engine.connectAccount(AccountConnectionRequest(instance: .gitlabCom, method: .personalAccessToken, credential: .bearer("glpat-other")))
        #expect(again.writesEnabled)
        #expect(try await h.db.auditEntries(limit: 20).allSatisfy { !$0.detail.contains("glpat-secret") })
    }

    @Test("connect: a failed probe or credential store stores nothing")
    func connectFailures() async throws {
        let h = try await Harness.make()
        h.world.state.update { $0.probeError = .unauthorized("bad token") }
        await #expect(throws: EngineError.provider(.unauthorized("bad token"))) {
            try await h.engine.connectAccount(AccountConnectionRequest(instance: .gitlabCom, method: .personalAccessToken, credential: .bearer("x")))
        }
        #expect(try h.credentials.load(for: Fixture.gitlab) == nil)
        #expect(try await h.db.account(Fixture.gitlab) == nil)

        h.world.state.update {
            $0.probeError = nil
            $0.users["gitlab"] = ProviderUser(remoteID: "2002", username: "mona")
        }
        h.credentials.state.update { $0.failSaves = true }
        await #expect(throws: EngineError.self) {
            try await h.engine.connectAccount(AccountConnectionRequest(instance: .gitlabCom, method: .personalAccessToken, credential: .bearer("x")))
        }
        #expect(try await h.db.account(Fixture.gitlab) == nil, "no account without a stored credential")
    }

    @Test("disconnect deletes the credential and data but keeps the audit log")
    func disconnect() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        _ = task
        try await h.engine.disconnectAccount(Fixture.github)
        #expect(try h.credentials.load(for: Fixture.github) == nil)
        #expect(try await h.db.account(Fixture.github) == nil)
        #expect(try await h.db.tasks(states: nil).isEmpty)
        #expect(try await h.db.attentionItems(includeInactive: true).isEmpty)
        #expect(try await h.db.auditEntries(limit: 10).contains { $0.action == "disconnect_account" })
    }

    // MARK: Inbox

    @Test("Inbox filters (mine/reviewing, provider, repo, status) and user state")
    func inbox() async throws {
        let h = try await Harness.make()
        let second = AccountKey(kind: .github, host: "github.com", remoteUserID: "3003")
        try await h.db.upsertAccount(Fixture.account(second))
        let reviewCR = Fixture.cr(second, number: 7)
        try await h.db.applySyncBatch(SyncBatch(
            account: second, snapshots: [Fixture.snapshot(reviewCR, involvement: [.reviewRequested])],
            attentionUpserts: [Fixture.threadItem(reviewCR, eventIDs: ["e1"])], syncedAt: Fixture.start
        ))
        let all = try await h.engine.attentionItems()
        #expect(all.count == 3)
        #expect(all.first?.reason == .ciFailed, "high priority first")
        #expect(try await h.engine.attentionItems(AttentionQuery(scope: .mine)).count == 2)
        #expect(try await h.engine.attentionItems(AttentionQuery(scope: .reviewing)).map(\.changeRequest) == [reviewCR])
        #expect(try await h.engine.attentionItems(AttentionQuery(account: second)).count == 1)
        #expect(try await h.engine.attentionItems(AttentionQuery(repo: Fixture.repo(Fixture.github))).count == 2)
        #expect(try await h.engine.attentionItems(AttentionQuery(provider: .gitlab)).isEmpty)

        try await h.engine.acknowledgeAttention(h.checkItemID)
        #expect(try await h.engine.attentionItems(AttentionQuery(status: .done)).map(\.id) == [h.checkItemID])
        try await h.engine.snoozeAttention(h.threadItemID, until: Fixture.start.addingTimeInterval(3600))
        #expect(try await h.engine.attentionItems(AttentionQuery(status: .snoozed)).map(\.id) == [h.threadItemID])
        #expect(try await h.engine.attentionItems(AttentionQuery(status: .needsAction)).count == 1)
        await #expect(throws: EngineError.self) { try await h.engine.snoozeAttention(h.threadItemID, until: Fixture.start) }
        try await h.engine.dismissAttention(h.threadItemID)
        #expect(try await h.engine.attentionItems().map(\.id).contains(h.threadItemID) == false)

        _ = try await h.engine.createTask(fromAttention: h.checkItemID)
        #expect(try await h.engine.attentionItems(AttentionQuery(status: .withTask)).map(\.id) == [h.checkItemID])
    }

    @Test("One active task per attention item, also under concurrent requests; type override")
    func oneActiveTaskPerItem() async throws {
        let h = try await Harness.make()
        async let a = h.engine.createTask(fromAttention: h.threadItemID)
        async let b = h.engine.createTask(fromAttention: h.threadItemID, type: .draftReply)
        let (first, second) = try await (a, b)
        #expect(first.id == second.id)
        #expect(try await h.db.tasks(states: nil).count == 1)
        _ = try await h.engine.cancelTask(first.id)
        let replacement = try await h.engine.createTask(fromAttention: h.threadItemID, type: .draftReply)
        #expect(replacement.id != first.id)
        #expect(replacement.type == .draftReply)
        // The cancelled task cannot be reopened while the replacement is active.
        await #expect(throws: EngineError.self) { try await h.engine.reopenTask(first.id) }
    }

    @Test("Trigger snapshot quotes the exact comments, bounded")
    func triggerSnapshot() async throws {
        let h = try await Harness.make()
        let long = String(repeating: "é", count: 10_000)
        let cr = Fixture.cr(Fixture.github, number: 43)
        try await h.db.applySyncBatch(SyncBatch(
            account: Fixture.github, snapshots: [Fixture.snapshot(cr, threadBody: long)],
            attentionUpserts: [Fixture.threadItem(cr, eventIDs: [])], syncedAt: Fixture.start
        ))
        let task = try await h.engine.createTask(fromAttention: AttentionItem.makeID(dedupeKey: AttentionItem.dedupeKey(thread: Fixture.thread(cr))))
        let quoted = try #require(task.trigger.quoted.first)
        #expect(quoted.text.utf8.count <= TriggerSnapshotBuilder.maxCommentBytes)
        #expect(quoted.text.hasSuffix(UntrustedText.truncationMarker))
        #expect(task.trigger.anchor?.path == "Sources/Retry.swift")
        #expect(task.trigger.headSHA == Fixture.base)
        #expect(task.origin.changeRequestRef.number == 43)
    }

    // MARK: Gate policy

    @Test("Writes require writesEnabled, capability support and the owner's policy")
    func gatePolicy() async throws {
        let h = try await Harness.make(.init(writesEnabled: false))
        let task = try await h.submittedTask()
        for action in [RemoteActionKind.requestChanges, .commitAndPush, .merge] {
            await #expect(throws: EngineError.disabledByPolicy(action)) { try await h.engine.previewAction(task.id, action) }
        }
        let preview = try await h.engine.previewAction(task.id, .postReply)
        #expect(!preview.canApprove)
        #expect(preview.blockedReason?.contains("turned off") == true)
        await #expect(throws: EngineError.writesDisabled(account: "mona-dev")) {
            try await h.engine.perform(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint))
        }
        try await h.engine.setWritesEnabled(Fixture.github, true)
        h.world.state.update { $0.capabilityOverrides[.github] = [.createReply: .unsupported(reason: "fixture")] }
        let unsupported = try await h.engine.previewAction(task.id, .postReply)
        #expect(!unsupported.canApprove)
        await #expect(throws: EngineError.self) {
            try await h.engine.perform(previewID: unsupported.id, approval: PreviewApproval(fingerprint: unsupported.fingerprint))
        }
        h.world.state.update { $0.capabilityOverrides = [:] }
        let good = try await h.engine.previewAction(task.id, .postReply)
        // A tampered approval (fingerprint mismatch) is refused.
        await #expect(throws: EngineError.previewExpired) {
            try await h.engine.perform(previewID: good.id, approval: PreviewApproval(fingerprint: "tampered"))
        }
        // An expired preview is refused.
        h.clock.advance(by: 601)
        await #expect(throws: EngineError.previewExpired) {
            try await h.engine.perform(previewID: good.id, approval: PreviewApproval(fingerprint: good.fingerprint))
        }
        #expect(h.world.writes.isEmpty)
        #expect(try await h.task(task.id).state == .readyForReview)
    }

    @Test("Never double-post: an identical reply already on the thread counts as performed")
    func noDoublePost() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        let task = try await h.submittedTask(reply: "Thanks, fixed.")
        let preview = try await h.engine.previewAction(task.id, .postReply)
        // The reply landed earlier (e.g. the app crashed right after posting).
        h.world.setThread(Fixture.reviewThread(Fixture.cr(), extraComments: [
            ReviewComment(id: "mine", author: Person(remoteID: Fixture.github.remoteUserID, username: "mona-dev"), body: "Thanks, fixed.", createdAt: Fixture.start),
        ]))
        let outcome = try await h.engine.perform(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint))
        guard case .alreadyPerformed = outcome else {
            Issue.record("expected alreadyPerformed, got \(outcome)")
            return
        }
        #expect(h.world.writes.isEmpty)
    }

    @Test("A failed write returns the task to review with the error; a conflict blocks it")
    func writeFailures() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        let task = try await h.submittedTask()
        h.world.state.update { $0.writeError = .server(status: 503, message: "unavailable") }
        let preview = try await h.engine.previewAction(task.id, .postReply)
        let outcome = try await h.engine.perform(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint))
        guard case .failed(let info) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(info.code == "server_error")
        #expect(info.retryable)
        #expect(try await h.task(task.id).state == .readyForReview)
        #expect(try await h.db.auditEntries(limit: 20, taskID: task.id).contains { $0.outcome == .failed })

        h.world.state.update { $0.writeError = .conflict("thread locked") }
        let retry = try await h.engine.previewAction(task.id, .postReply)
        let conflict = try await h.engine.perform(previewID: retry.id, approval: PreviewApproval(fingerprint: retry.fingerprint))
        guard case .blocked = conflict else {
            Issue.record("expected blocked, got \(conflict)")
            return
        }
        #expect(try await h.task(task.id).state == .blocked)
    }

    // MARK: Redaction

    @Test("Agent-supplied outputs are bounded and redacted before storage")
    func redaction() async throws {
        let h = try await Harness.make()
        let (task, claim) = try await h.claimedTask()
        let output = "PASS\nexport GITHUB_TOKEN=\(Fixture.token)\n" + String(repeating: "x", count: 15_000)
        let tests = try await h.ok(ReportTestsParams(
            taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, command: "TOKEN=\(Fixture.token) swift test",
            exitCode: 1, status: .failed, failed: 1, output: output
        ))
        let artifact = try #require(try await h.db.artifact(id: tests.artifactID))
        #expect(!artifact.content.contains(Fixture.token))
        #expect(artifact.content.utf8.count <= IPCLimits.maxTestOutputBytes)
        #expect(artifact.metadata["command"]?.contains(Fixture.token) == false)
        #expect(!artifact.title.contains(Fixture.token))

        let failed = try await h.ok(FailTaskParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: tests.version, reason: "Auth failed with \(Fixture.token)", retryable: true))
        #expect(failed.state == .failed)
        let stored = try await h.task(task.id)
        #expect(stored.lastError?.message.contains(Fixture.token) == false)
        #expect(stored.lastError?.code == "agent_failed")
        #expect(try await h.activities(task.id).allSatisfy { !$0.message.contains(Fixture.token) })
    }

    @Test("fail_task with blocked: true → blocked; owner unblocks")
    func failBlocked() async throws {
        let h = try await Harness.make()
        let (task, claim) = try await h.claimedTask()
        let result = try await h.ok(FailTaskParams(taskID: task.id, leaseID: claim.leaseID, expectedVersion: claim.version, reason: "Need credentials for the staging DB", retryable: false, blocked: true))
        #expect(result.state == .blocked)
        let unblocked = try await h.engine.unblockTask(task.id)
        #expect(unblocked.state == .waitingForAgent)
        #expect(try await h.activities(task.id).last?.kind == .unblocked)
    }

    // MARK: Data

    @Test("Export, prune, settings, snapshot and change stream")
    func dataManagement() async throws {
        let h = try await Harness.make()
        let stream = await h.engine.changes()
        var iterator = stream.makeAsyncIterator()
        _ = try await h.engine.createTask(fromAttention: h.threadItemID)
        let first = await iterator.next()
        #expect(first != nil)

        try await h.engine.setNotificationsPaused(until: Fixture.start.addingTimeInterval(3600))
        #expect(await h.sync.pausedUntil == Fixture.start.addingTimeInterval(3600))
        #expect(await h.engine.notificationsPausedUntil() == Fixture.start.addingTimeInterval(3600))
        let quiet = QuietHours(startMinute: 1320, endMinute: 420, timeZoneID: "UTC")
        try await h.engine.setQuietHours(quiet)
        #expect(await h.engine.quietHours() == quiet)

        let snapshot = try await h.engine.snapshot()
        #expect(snapshot.tasks.count == 1)
        #expect(snapshot.attention.count == 2)
        #expect(snapshot.changeRequests.count == 1)
        #expect(snapshot.mappings.count == 1)
        #expect(snapshot.quietHours == quiet)

        try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let exportPath = h.root.appending(path: "export.sqlite").path
        try await h.engine.exportDatabase(to: exportPath)
        #expect(FileManager.default.fileExists(atPath: exportPath))
        _ = try await h.engine.pruneHistory(olderThan: Fixture.start.addingTimeInterval(-86_400))

        await h.engine.refresh(account: Fixture.github)
        #expect(await h.sync.refreshed == [Fixture.github])
        try await h.engine.resetAllData()
        #expect(try await h.db.accounts().isEmpty)
        #expect(try h.credentials.load(for: Fixture.github) == nil)
    }

    @Test("Mappings CRUD and suggestions")
    func mappings() async throws {
        let h = try await Harness.make(.init(mapCheckout: false))
        h.workspace.state.update { $0.matchConfidence = .probable }
        let mapping = try await h.engine.addMapping(repo: Fixture.repo(Fixture.github), repoFullPath: "acme/payments-api", checkoutPath: Fixture.checkoutPath + "/")
        #expect(mapping.checkoutPath == Fixture.checkoutPath)
        #expect(!mapping.isConfirmed, "probable matches need confirmation")
        let confirmed = try await h.engine.confirmMapping(id: mapping.id)
        #expect(confirmed.isConfirmed)
        let suggestions = try await h.engine.mappingSuggestions(for: Fixture.repo(Fixture.github), searchRoots: ["/tmp/code"])
        #expect(suggestions.first?.checkoutPath == "/tmp/code/payments-api")
        await #expect(throws: EngineError.self) {
            try await h.engine.addMapping(repo: Fixture.repo(Fixture.github), repoFullPath: "acme/payments-api", checkoutPath: "relative")
        }
        try await h.engine.removeMapping(id: mapping.id)
        #expect(try await h.engine.mappings().isEmpty)
    }
}
