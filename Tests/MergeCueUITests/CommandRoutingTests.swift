import Foundation
import MergeCueCore
import MergeCueEngine
@testable import MergeCueUI
import Testing

@Suite("Command routing against the preview backend")
@MainActor
struct CommandRoutingTests {
    @Test func previewModeIsNeverLive() async {
        let model = await makeModel()
        #expect(model.mode == .preview)
        #expect(model.modeBadge == "Preview data")
        #expect(model.menuBarAccessibilityLabel == "MergeCue (preview data), 7 need you, 1 in progress, 1 ready")
        #expect(model.menuBarToolTip == "Needs you: 7 · Waiting for agent: 2 · AI working: 1 · Ready: 1")
        #expect(model.state.accounts.allSatisfy { $0.account.isDemo })
    }

    @Test func fixWithAICreatesAWaitingTaskAndNeverFakesAClaim() async throws {
        let recorder = EnvironmentRecorder()
        let model = await makeModel(recorder: recorder)
        let item = try #require(model.state.attention(.github, number: 42, reason: .changesRequested))
        let before = model.sections

        let result = try #require(await model.send(.createTask(attentionID: item.id, type: .fixReview)))
        let taskID = try #require(result.createdTaskID)
        let record = try #require(model.task(taskID))
        #expect(record.task.state == .waitingForAgent)
        #expect(record.task.lease == nil)
        #expect(record.task.origin.attentionItemID == item.id)
        #expect(record.task.origin.providerKind == .github)
        #expect(record.task.trigger.quoted.first?.text.contains("double-refunds") == true)
        #expect(model.handoffOffer == HandoffOffer(taskID: taskID))
        #expect(model.sections.count(.needsYou) == before.count(.needsYou) - 1)
        #expect(model.sections.count(.waitingForAgent) == before.count(.waitingForAgent) + 1)
        #expect(model.sections.count(.aiWorking) == before.count(.aiWorking))
        let row = try #require(model.sections.waitingForAgent.first { $0.taskID == taskID })
        #expect(row.reason == "Awaiting agent connection")

        // Copying the command is read-only: exact text on the pasteboard, still waiting for an agent.
        await model.perform(row.primaryAction)
        #expect(recorder.copied == [
            "Work on MergeCue task \(taskID.rawValue). Use MergeCue MCP for context and status updates. Work only in the designated checkout. Stop before publishing anything.",
        ])
        #expect(model.task(taskID)?.task.state == .waitingForAgent)

        // A second task for the same item is refused.
        #expect(await model.send(.createTask(attentionID: item.id, type: .fixReview)) == nil)
        #expect(model.banners.last?.tone == .critical)
    }

    @Test func handoffTextFormat() throws {
        let id = try #require(TaskID(rawValue: "mc_8421ab"))
        #expect(HandoffText.command(for: id)
            == "Work on MergeCue task mc_8421ab. Use MergeCue MCP for context and status updates. Work only in the designated checkout. Stop before publishing anything.")
    }

    @Test func attentionActions() async throws {
        let model = await makeModel()
        let question = try #require(model.state.attention(.bitbucketCloud, number: 42, reason: .reviewerQuestion))
        await model.send(.markRead(attentionID: question.id, read: true))
        #expect(model.attentionItem(question.id)?.isUnread == false)

        await model.send(.acknowledge(attentionID: question.id))
        #expect(model.attentionItem(question.id)?.disposition == .acknowledged)
        #expect(!model.sections.needsYou.contains { $0.attentionID == question.id })

        let review = try #require(model.state.attention(.github, number: 318, reason: .reviewRequested))
        let until = testNow.addingTimeInterval(3_600)
        await model.send(.snooze(attentionID: review.id, until: until))
        #expect(model.attentionItem(review.id)?.disposition == .snoozed(until: until))
        await model.send(.dismissAttention(attentionID: review.id))
        #expect(model.attentionItem(review.id)?.disposition == .dismissed)
        #expect(model.sections.count(.needsYou) == 5)
    }

    @Test func reviewGateRespectsWritePolicyAndApprovals() async throws {
        let model = await makeModel()
        let ready = try #require(model.state.task(in: .readyForReview))

        // Posting needs remote writes, which are off by default.
        let reply = try #require(await model.send(.requestActionPreview(ready.id, .postReply))?.preview)
        #expect(model.pendingPreview == reply)
        #expect(!reply.canApprove)
        #expect(reply.blockedReason?.contains("Remote writes are off") == true)
        #expect(reply.body == ready.task.proposedReply)
        #expect(reply.isSimulated)
        #expect(await model.send(.approvePreview(reply)) == nil)
        #expect(model.task(ready.id)?.task.state == .readyForReview)

        // Merge and push are hidden by the owner's policy.
        #expect(await model.send(.requestActionPreview(ready.id, .merge)) == nil)
        #expect(await model.send(.requestActionPreview(ready.id, .commitAndPush)) == nil)

        // Apply the patch (more actions remain → back to ready), then post the reply (last action → done).
        let patch = try #require(await model.send(.requestActionPreview(ready.id, .applyPatch))?.preview)
        #expect(patch.canApprove)
        #expect(patch.body.contains("RetryPolicy.swift"))
        await model.send(.approvePreview(patch))
        #expect(model.pendingPreview == nil)
        #expect(model.task(ready.id)?.task.state == .readyForReview)
        #expect(model.task(ready.id)?.task.approvals.map(\.action) == [.applyPatch])

        await model.send(.setWritesEnabled(ready.task.origin.account, true))
        #expect(model.account(ready.task.origin.account)?.account.writesEnabled == true)
        let approvable = try #require(await model.send(.requestActionPreview(ready.id, .postReply))?.preview)
        #expect(approvable.canApprove)
        await model.send(.approvePreview(approvable))
        let done = try #require(model.task(ready.id))
        #expect(done.task.state == .done)
        #expect(done.activities.contains { $0.kind == .completed })
        #expect(model.attentionItem(ready.task.origin.attentionItemID)?.disposition == .resolved)
        #expect(model.sections.count(.ready) == 0)
    }

    @Test func staleApprovalsAreRejected() async throws {
        let model = await makeModel()
        let ready = try #require(model.state.task(in: .readyForReview))
        var patch = try #require(await model.send(.requestActionPreview(ready.id, .applyPatch))?.preview)
        patch.fingerprint = "tampered"
        #expect(await model.send(.approvePreview(patch)) == nil)
        #expect(model.task(ready.id)?.task.state == .readyForReview)
    }

    @Test func taskLifecycleCommands() async throws {
        let model = await makeModel()
        let ready = try #require(model.state.task(in: .readyForReview))
        await model.send(.rejectResult(ready.id, note: "Keep the old API"))
        #expect(model.task(ready.id)?.task.state == .waitingForAgent)
        #expect(model.task(ready.id)?.activities.last?.kind == .rejected)

        let failed = try #require(model.state.task(in: .failed))
        await model.send(.retryTask(failed.id))
        #expect(model.task(failed.id)?.task.state == .waitingForAgent)
        #expect(model.task(failed.id)?.task.lastError == nil)

        let blocked = try #require(model.state.task(in: .blocked))
        await model.send(.cancelTask(blocked.id))
        #expect(model.task(blocked.id)?.task.state == .cancelled)
        await model.send(.reopenTask(blocked.id))
        #expect(model.task(blocked.id)?.task.state == .waitingForAgent)

        let done = try #require(model.state.task(in: .done))
        #expect(await model.send(.cancelTask(done.id)) == nil, "terminal tasks can only be reopened")
        #expect(model.task(done.id)?.task.state == .done)
    }

    @Test func rulesNotificationsAndMappings() async throws {
        let model = await makeModel()
        let proposal = try #require(model.pendingRuleProposals.first)
        #expect(!proposal.isActive)
        await model.send(.activateRule(id: proposal.id, active: true))
        #expect(model.state.rules.first { $0.id == proposal.id }?.isActive == true)
        #expect(model.pendingRuleProposals.isEmpty)
        #expect(await model.send(.deleteRule(id: RuleTemplates.all[0].id)) == nil)

        let until = testNow.addingTimeInterval(3_600)
        await model.send(.pauseNotifications(until: until))
        #expect(model.notificationsPaused)
        await model.send(.pauseNotifications(until: nil))
        #expect(!model.notificationsPaused)
        // Worktree cleanup is an explicit command; the preview never removes anything.
        await model.send(.cleanUpWorktrees([]))
        #expect(model.state.worktreeCleanupCandidates.isEmpty)
        #expect(HousekeepingCard.retentionText(nil).hasSuffix("Not run yet."))
        let report = MaintenanceReport(at: testNow, removedRows: 12, cutoff: testNow.addingTimeInterval(-90 * 86_400), databaseBytes: 2_048_000)
        #expect(HousekeepingCard.retentionText(report).contains("12 rows removed"))
        #expect(HousekeepingCard.retentionText(report).contains("90 days"))
        await model.send(.setNotificationCategory(.reviewRequests, enabled: false))
        #expect(!model.state.notificationPreferences.isEnabled(.reviewRequests))
        #expect(model.state.notificationPreferences.isEnabled(.ciFailures))

        let repo = try #require(model.knownRepositories.first { model.mapping(for: $0.key) == nil })
        await model.send(.addMapping(repo: repo.key, repoFullPath: repo.fullPath, checkoutPath: "/tmp/checkout"))
        let mapping = try #require(model.mapping(for: repo.key))
        await model.send(.removeMapping(id: mapping.id))
        #expect(model.mapping(for: repo.key) == nil)
    }

    @Test func connectingDiscardsTheTokenAndNeverPrintsIt() async throws {
        let model = await makeModel(.authExpired)
        let token = "glpat-" + String(repeating: "x", count: 20)
        let request = ConnectAccountRequest(kind: .gitlab, method: .personalAccessToken, token: SecretValue(token))
        #expect(!String(describing: request).contains(token))
        #expect(!String(describing: AppCommand.connectAccount(request)).contains(token))
        #expect(!String(reflecting: SecretValue(token)).contains(token))
        #expect(!"\(Mirror(reflecting: SecretValue(token)).children.map { "\($0.value)" })".contains(token))

        let result = await model.send(.connectAccount(request))
        #expect(result?.message?.contains(token) == false)
        #expect(model.state.accounts.first { $0.kind == .gitlab }?.status.state == .ok)

        // A token method without a token is refused.
        #expect(await model.send(.connectAccount(ConnectAccountRequest(kind: .bitbucketCloud, method: .bitbucketAPIToken))) == nil)
    }

    @Test func linksIntoSyntheticReposAreNotOpened() async throws {
        let recorder = EnvironmentRecorder()
        let model = await makeModel(recorder: recorder)
        let synthetic = try #require(model.state.changeRequests.first).summary.webURL
        await model.send(.openURL(synthetic))
        #expect(recorder.opened.isEmpty)
        let tokenPage = try #require(URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens"))
        await model.send(.openURL(tokenPage))
        #expect(recorder.opened == [tokenPage])
    }

    @Test func checkLogsLoadOnDemand() async throws {
        let model = await makeModel()
        let item = try #require(model.state.attention(.gitlab, number: 42, reason: .ciFailed))
        let check = try #require(item.check)
        await model.loadLog(for: check)
        #expect(model.logExcerpts[check.id]?.text.contains("TestBatchWriterIntegration") == true)
    }

    @Test func backendNotifiesObserversAfterMutations() async throws {
        let backend = MergeCuePreview.makeBackend(variant: .standard, now: testNow)
        var iterator = backend.changes().makeAsyncIterator()
        let state = await backend.loadState()
        let item = try #require(state.attention.first)
        _ = try await backend.perform(.markRead(attentionID: item.id, read: false))
        let signal: Void? = await iterator.next()
        #expect(signal != nil)
    }

    @Test func popoverKeyboardNavigation() async throws {
        let model = await makeModel()
        #expect(model.popoverSelection == nil)
        model.movePopoverSelection(by: 1)
        let first = try #require(model.popoverRows.first)
        #expect(model.popoverSelection == first.id)
        model.movePopoverSelection(by: -1)
        #expect(model.popoverSelection == first.id)
        model.movePopoverSelection(by: 100)
        #expect(model.popoverSelection == model.popoverRows.last?.id)
        let visibleRows = 7 // 3 needs you + 2 waiting + 1 working + 1 ready
        #expect(model.popoverRows.count == visibleRows)

        // Return on the first row ("Fix with AI") creates a task.
        model.popoverSelection = first.id
        await model.activatePopoverSelection()
        #expect(model.handoffOffer != nil)
    }

    @Test func navigationReachesEveryItemInOneStep() async throws {
        let model = await makeModel()
        var opened = 0
        model.openMainWindowHandler = { opened += 1 }
        for row in model.popoverRows {
            model.open(row)
            switch row.source {
            case .attention(let id):
                #expect(model.screen == .inbox)
                #expect(model.selectedAttentionID == id)
            case .task(let id):
                #expect(model.screen == .tasks)
                #expect(model.selectedTaskID == id)
            }
        }
        #expect(opened == model.popoverRows.count)
        model.showAll(.ready)
        #expect(model.screen == .tasks)
        model.showSettings(.agents)
        #expect(model.screen == .settings && model.settingsTab == .agents)
    }
}

@Suite("Link opening choke point (S1) and display redaction (S9)")
@MainActor
struct LinkSafetyTests {
    @Test func nonWebLinksAreNeverOpened() async throws {
        let recorder = EnvironmentRecorder()
        let model = await makeModel(recorder: recorder)
        model.openLink(try #require(URL(string: "file:///Applications/Calculator.app")))
        model.openLink(try #require(URL(string: "javascript:alert(1)")))
        #expect(recorder.opened.isEmpty)
        #expect(model.pendingLinkConfirmation == nil)
        #expect(model.banners.last?.tone == .attention)
    }

    @Test func providerHostsOpenAndOtherHostsNeedConfirmation() async throws {
        let recorder = EnvironmentRecorder()
        let model = await makeModel(recorder: recorder)
        let github = try #require(URL(string: "https://github.com/acme/payments-api/pull/42"))
        model.openLink(github)
        #expect(recorder.opened == [github])

        let other = try #require(URL(string: "https://ci.unknown.example/job/1"))
        model.openLink(other)
        #expect(recorder.opened == [github])
        #expect(model.pendingLinkConfirmation == LinkConfirmation(url: other, host: "ci.unknown.example"))
        model.cancelPendingLink()
        #expect(recorder.opened == [github])

        model.openLink(other)
        model.confirmPendingLink()
        #expect(recorder.opened == [github, other])
        #expect(model.pendingLinkConfirmation == nil)
    }

    @Test func commentTextIsRedactedForDisplay() {
        let body = "use \u{1B}[1mghp_1234567890abcdefghijABCDEFGHIJ1234\u{1B}[0m here"
        #expect(UIFormat.untrustedDisplay(body) == "use ghp_[REDACTED] here")
        #expect(Presentation.firstLine("token=supersecretvalue\nmore", limit: 90) == "token=[REDACTED]")
    }
}

@Suite("Agent read access setting (S3)")
@MainActor
struct AgentReadAccessSettingTests {
    @Test func defaultsToTasksOnlyAndCanBeWidened() async {
        let model = await makeModel()
        #expect(model.state.agentReadAccess == .tasksOnly)
        await model.send(.setAgentReadAccess(.allInbox))
        #expect(model.state.agentReadAccess == .allInbox)
        await model.send(.setAgentReadAccess(.tasksOnly))
        #expect(model.state.agentReadAccess == .tasksOnly)
    }
}

@Suite("Agent config backups command (S10)")
@MainActor
struct AgentBackupsCommandTests {
    @Test func deleteBackupsIsRoutedAndNeverFakesWork() async throws {
        let model = await makeModel()
        let result = try #require(await model.send(.deleteAgentConfigBackups))
        #expect(result.message?.contains("nothing was deleted") == true)
    }
}
