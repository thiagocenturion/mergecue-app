import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore
import Testing
@testable import MergeCueEngine

@Suite("MCP reads, proposals and rules")
struct ReadAndRuleTests {
    @Test("ping")
    func ping() async throws {
        let h = try await Harness.make(.init(isDemo: true))
        let pong = try await h.ok(PingParams())
        #expect(pong.appVersion == "1.2.3-test")
        #expect(pong.protocolVersion == IPCProtocol.version)
        #expect(pong.isDemo)
    }

    @Test("list_attention filters, include_read and total; list_tasks defaults to active tasks")
    func lists() async throws {
        let h = try await Harness.make()
        try await h.engine.setAgentReadAccess(.allInbox)
        try await h.seed(Fixture.gitlab)
        var all = try await h.ok(ListAttentionParams())
        #expect(all.total == 4)
        #expect(Set(all.items.map(\.provider)) == [.github, .gitlab])
        #expect(all.items.allSatisfy { $0.account == "mona-dev@\($0.changeRef.host)" })

        let gitlab = try await h.ok(ListAttentionParams(provider: .gitlab))
        #expect(gitlab.total == 2)
        #expect(gitlab.items.allSatisfy { $0.changeRef.string == "gitlab:gitlab.com/acme/payments-api!42" })
        #expect(try await h.ok(ListAttentionParams(account: "mona-dev@github.com", limit: 1)).items.count == 1)
        #expect(try await h.ok(ListAttentionParams(repo: "ACME/payments-api")).total == 4)

        try await h.engine.markAttentionRead(h.threadItemID)
        all = try await h.ok(ListAttentionParams())
        #expect(all.total == 3)
        #expect(try await h.ok(ListAttentionParams(includeRead: true)).total == 4)

        let task = try await h.engine.createTask(fromAttention: h.checkItemID)
        _ = try await h.engine.dismissTask(task.id)
        let other = try await h.engine.createTask(fromAttention: h.threadItemID)
        let active = try await h.ok(ListTasksParams())
        #expect(active.tasks.map(\.taskID) == [other.id])
        #expect(active.tasks.first?.account == "mona-dev@github.com")
        #expect(try await h.ok(ListTasksParams(states: [.dismissed])).tasks.map(\.taskID) == [task.id])
    }

    @Test("get_change_context resolves refs case-insensitively; ambiguity across accounts is invalid_params")
    func changeContext() async throws {
        let h = try await Harness.make()
        try await h.engine.setAgentReadAccess(.allInbox)
        let ref = try #require(ChangeRequestRef(string: "github:github.com/ACME/Payments-API#42"))
        let context = try await h.ok(GetChangeContextParams(changeRef: ref, maxFiles: 1))
        #expect(context.number == 42)
        #expect(context.changedFiles?.count == 1)
        #expect(context.description?.text.contains(Fixture.token) == false)
        #expect(context.threads.first?.threadID == Fixture.thread().shortID)

        // A second GitHub account that sees the same PR makes an unscoped ref ambiguous.
        let second = AccountKey(kind: .github, host: "github.com", remoteUserID: "3003")
        try await h.seed(second)
        #expect(await h.errorCode(GetChangeContextParams(changeRef: ref)) == .invalidParams)
    }

    @Test("get_ci_failure fetches a bounded, redacted excerpt on demand")
    func ciFailure() async throws {
        let h = try await Harness.make()
        try await h.engine.setAgentReadAccess(.allInbox)
        let result = try await h.ok(GetCIFailureParams(checkID: Fixture.check().shortID, maxBytes: 1024))
        #expect(result.name == "build")
        #expect(result.status == .failure)
        #expect(result.excerpt.source == UntrustedText.Source.ciLog)
        #expect(result.excerpt.text.contains("error: test failed"))
        #expect(!result.excerpt.text.contains(Fixture.token))
        #expect(result.excerpt.text.utf8.count <= 1024)
    }

    @Test("get_diff: provider diff by ref, worktree diff by task (both redacted)")
    func diffs() async throws {
        let h = try await Harness.make()
        try await h.engine.setAgentReadAccess(.allInbox)
        let ref = try #require(ChangeRequestRef(string: "github:github.com/acme/payments-api#42"))
        let provider = try await h.ok(GetDiffParams(changeRef: ref))
        #expect(provider.source == .provider)
        #expect(!provider.unifiedDiff.contains(Fixture.token))

        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        h.workspace.setChanges(["a.swift"], diff: "diff --git a/a.swift b/a.swift\n+let key = \"\(Fixture.token)\"\n")
        let worktree = try await h.ok(GetDiffParams(taskID: task.id, changeRef: ref, maxBytes: 4096))
        #expect(worktree.source == .worktree)
        #expect(worktree.baseSHA == Fixture.base)
        #expect(worktree.files.map(\.path) == ["a.swift"])
        #expect(!worktree.unifiedDiff.contains(Fixture.token))
    }

    @Test("propose_rule stores an inactive pending rule; only the user activates it")
    func proposeRule() async throws {
        let h = try await Harness.make()
        let proposal = try await h.ok(ProposeRuleParams(
            name: "Fix failing CI", providers: [.github], eventTypes: [.ciFailed], repoInclude: ["acme/*"],
            action: .createTask, taskType: .investigateCI,
            quietHours: QuietHoursDTO(start: "22:00", end: "07:00", timeZone: "Europe/Lisbon"), maxFiresPerHour: 5
        ))
        #expect(proposal.status == .pendingActivation)
        #expect(proposal.preview.contains("Inactive until you activate it"))
        var rule = try #require(try await h.db.rule(id: proposal.ruleID))
        #expect(!rule.isActive)
        #expect(rule.origin == .agentProposal)
        #expect(rule.quietHours?.startMinute == 22 * 60)

        let listed = try await h.ok(ListRulesParams())
        #expect(listed.rules.map(\.ruleID) == [proposal.ruleID])
        #expect(listed.rules.first?.active == false)

        // The proposal does not fire.
        await h.engine.handleNewEvents([Fixture.event(type: .ciFailed, version: "2")])
        #expect(try await h.db.tasks(states: nil).isEmpty)

        rule = try await h.engine.setRuleActive(id: proposal.ruleID, active: true)
        #expect(rule.isActive)
        #expect(rule.origin == .agentProposal)
        #expect(await h.errorCode(ProposeRuleParams(name: "x", eventTypes: [.ciFailed], action: .createTask)) == .invalidParams)
    }

    @Test("propose_rule is rate-limited")
    func proposeRuleRateLimit() async throws {
        let h = try await Harness.make()
        for index in 0..<MergeCueEngine.maxProposalsPerMinute {
            _ = try await h.ok(ProposeRuleParams(name: "Rule \(index)", eventTypes: [.ciFailed], action: .notify))
        }
        #expect(await h.errorCode(ProposeRuleParams(name: "One more", eventTypes: [.ciFailed], action: .notify)) == .rateLimited)
        #expect(try await h.db.rules().count == MergeCueEngine.maxProposalsPerMinute)
        #expect(try await h.db.rules().allSatisfy { !$0.isActive })
        h.clock.advance(by: 61)
        _ = try await h.ok(ProposeRuleParams(name: "Later", eventTypes: [.ciFailed], action: .notify))
    }

    // MARK: Rule evaluation

    private func activeRule(_ h: Harness, _ action: RuleAction, events: Set<ChangeEventType> = [.reviewComment], quiet: QuietHours? = nil, max: Int = 10) async throws -> Rule {
        try await h.engine.saveRule(Rule(
            id: "", name: "Rule \(action.name)", isActive: true, origin: .user, eventTypes: events,
            action: action, maxFiresPerHour: max, quietHours: quiet, createdAt: Fixture.start
        ))
    }

    @Test("A rule fires at most once per event, and one event creates at most one task across rules")
    func ruleIdempotency() async throws {
        let h = try await Harness.make()
        _ = try await activeRule(h, .createTask(.fixReview))
        _ = try await activeRule(h, .createTask(.draftReply))
        let event = Fixture.event()
        await h.engine.handleNewEvents([event])
        await h.engine.handleNewEvents([event])
        let tasks = try await h.db.tasks(states: nil)
        #expect(tasks.count == 1)
        #expect(tasks.first?.state == .waitingForAgent)
        #expect(tasks.first?.origin.ruleID != nil)
        #expect(tasks.first?.origin.attentionItemID == h.threadItemID)
        #expect(try await h.db.ruleFiringCount(ruleID: try await h.engine.rules()[0].id, since: .distantPast) == 1)
        #expect(h.world.writes.isEmpty)
    }

    @Test("Identical #42 / !42 across providers: separate events, separate tasks")
    func identicalNumbersAcrossProviders() async throws {
        let h = try await Harness.make()
        try await h.seed(Fixture.gitlab)
        _ = try await activeRule(h, .createTask(.fixReview))
        let githubEvent = Fixture.event(Fixture.cr(Fixture.github))
        let gitlabEvent = Fixture.event(Fixture.cr(Fixture.gitlab))
        #expect(githubEvent.id != gitlabEvent.id)
        await h.engine.handleNewEvents([githubEvent, gitlabEvent, githubEvent])
        let tasks = try await h.db.tasks(states: nil)
        #expect(tasks.count == 2)
        #expect(Set(tasks.map(\.origin.providerKind)) == [.github, .gitlab])
        #expect(Set(tasks.map(\.origin.changeRequestRef.string)) == ["github:github.com/acme/payments-api#42", "gitlab:gitlab.com/acme/payments-api!42"])
    }

    @Test("request_execution degrades to a waiting task with an honest note")
    func requestExecutionDegrades() async throws {
        let h = try await Harness.make()
        _ = try await activeRule(h, .requestExecution(.investigateCI), events: [.ciFailed])
        await h.engine.handleNewEvents([Fixture.event(type: .ciFailed)])
        let task = try #require(try await h.db.tasks(states: nil).first)
        #expect(task.state == .waitingForAgent)
        #expect(task.type == .investigateCI)
        #expect(task.origin.attentionItemID == h.checkItemID)
        #expect(task.trigger.quoted.first?.source == UntrustedText.Source.ciLog)
        #expect(task.trigger.quoted.first?.text.contains(Fixture.token) == false)
        #expect(try await h.activities(task.id).contains { $0.kind == .note && $0.message == "Unattended execution not available — task ready to start" })
    }

    @Test("Quiet hours, max fires per hour, baseline events and inactive rules")
    func ruleGuards() async throws {
        let h = try await Harness.make()
        // 00:00 UTC is inside 23:00–01:00.
        let quiet = try await activeRule(h, .createTask(.fixReview), quiet: QuietHours(startMinute: 23 * 60, endMinute: 60, timeZoneID: "UTC"))
        await h.engine.handleNewEvents([Fixture.event()])
        #expect(try await h.db.tasks(states: nil).isEmpty)
        try await h.engine.deleteRule(id: quiet.id)

        _ = try await activeRule(h, .notify, max: 1)
        await h.engine.handleNewEvents([Fixture.event(version: "a"), Fixture.event(version: "b")])
        let notifyRule = try await h.engine.rules()[0]
        #expect(try await h.db.ruleFiringCount(ruleID: notifyRule.id, since: .distantPast) == 1)

        var baseline = Fixture.event(version: "c")
        baseline.isBaseline = true
        _ = try await h.engine.setRuleActive(id: notifyRule.id, active: false)
        _ = try await activeRule(h, .createTask(.fixReview))
        await h.engine.handleNewEvents([baseline])
        #expect(try await h.db.tasks(states: nil).isEmpty)
    }

    @Test("Rules CRUD and templates")
    func ruleCRUD() async throws {
        let h = try await Harness.make()
        #expect(h.engine.ruleTemplates.count == 4)
        let rule = try await h.engine.addRule(fromTemplate: "tpl_failed_ci")
        #expect(!rule.isActive)
        #expect(rule.origin == .template)
        var edited = rule
        edited.name = "Renamed"
        edited.origin = .user
        let saved = try await h.engine.saveRule(edited)
        #expect(saved.name == "Renamed")
        #expect(saved.origin == .template, "origin is kept")
        try await h.engine.deleteRule(id: rule.id)
        #expect(try await h.engine.rules().isEmpty)
        await #expect(throws: EngineError.self) { try await h.engine.deleteRule(id: rule.id) }
    }
}
