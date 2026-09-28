import AgentHandoff
import Darwin
import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueRuntime
import Testing
@testable import MergeCueUI

/// A demo `EngineBackend` in a short private `MERGECUE_HOME` (no IPC server, no real agents, no Keychain).
struct DemoBackendHarness {
    let root: URL
    let backend: EngineBackend
    static let fakeHelper = URL(filePath: "/tmp/mergecue-test-helper/mergecue-mcp")
    static let fakeAgent = DetectedAgent(kind: .claudeCode, executableURL: URL(filePath: "/usr/bin/true"), version: "9.9.9",
                                         source: .knownLocation)

    static func start(registration: AgentRegistrationStatus = .notRegistered, ipc: Bool = false) async throws -> DemoBackendHarness {
        var template = Array("/tmp/mcui-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
        let path = String(cString: created)
        let resolved = realpath(path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? path
        let root = URL(filePath: resolved, directoryHint: .isDirectory)
        let paths = MergeCuePaths(root: root, fallbackSocketParent: root)
        let runtimeOptions = RuntimeOptions(
            notifier: SilentNotifier(), startsIPCServer: ipc, peerValidation: .disabled, mcpHelperOverride: fakeHelper,
            mappingSearchRoots: []
        )
        let options = EngineBackend.Options(
            detectAgents: { _ in [fakeAgent] },
            registrationStatus: { _, _ in registration },
            requestNotificationAuthorization: { false }
        )
        let backend = try await EngineBackend.launch(mode: .demo, paths: paths, appVersion: "0.0.0-test",
                                                     runtimeOptions: runtimeOptions, options: options)
        await backend.reloadAgents()
        return DemoBackendHarness(root: root, backend: backend)
    }

    func stop() async {
        await backend.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    func state() async -> AppState { await backend.loadState() }
}

final class SilentNotifier: NotificationDelivering {
    func deliver(_ notification: GroupedNotification) async {}
}

@Suite("EngineBackend (demo runtime)", .serialized)
struct EngineBackendTests {
    @Test func snapshotMapsToAppState() async throws {
        let harness = try await DemoBackendHarness.start()
        defer { Task { await harness.stop() } }
        let backend = harness.backend
        #expect(backend.mode == .demo)
        let state = await harness.state()
        let snapshot = try await backend.runtime.engine.snapshot()

        #expect(state.accounts.count == 3)
        #expect(state.accounts.allSatisfy { $0.account.isDemo })
        #expect(Set(state.accounts.map(\.kind)) == Set(ProviderKind.allCases))
        #expect(state.attention.map(\.id) == snapshot.attention.map(\.id))
        #expect(state.changeRequests.map(\.id) == snapshot.changeRequests.map(\.id))
        #expect(!state.changeRequests.isEmpty)
        #expect(state.tasks.count == snapshot.tasks.count)
        #expect(state.rules.map(\.id) == snapshot.rules.map(\.id))
        #expect(!state.mappings.isEmpty && state.mappings.allSatisfy(\.isConfirmed))
        // Every mapped checkout was checked for instruction files (existence only).
        for mapping in state.mappings {
            #expect(state.instructionFiles[mapping.checkoutPath] != nil)
        }
        // Agents come from AgentHandoff's detection.
        #expect(state.agents.map(\.kind) == [.claudeCode])
        #expect(state.agents.first?.version == "9.9.9")
        #expect(state.agents.first?.mcpRegistration == .notRegistered)
        // Demo data lives in <root>/demo; the helper keeps using the base socket.
        let info = try #require(state.runtime)
        #expect(info.dataRoot.hasSuffix("/demo"))
        #expect(info.helperPath == MergeCuePaths.fileSystemPath(DemoBackendHarness.fakeHelper))
        #expect(info.ipcRunning == false)
    }

    @Test func attentionAndTaskCommands() async throws {
        let harness = try await DemoBackendHarness.start()
        defer { Task { await harness.stop() } }
        let backend = harness.backend
        var state = await harness.state()
        let item = try #require(state.attention.first { $0.thread != nil && $0.linkedTaskID == nil })

        _ = try await backend.perform(.markRead(attentionID: item.id, read: false))
        state = await harness.state()
        #expect(state.attention.first { $0.id == item.id }?.isUnread == true)
        _ = try await backend.perform(.markRead(attentionID: item.id, read: true))
        state = await harness.state()
        #expect(state.attention.first { $0.id == item.id }?.isUnread == false)

        // Fix with AI → a real task, only "ready to start" (no fake claim).
        let created = try await backend.perform(.createTask(attentionID: item.id, type: .fixReview))
        let taskID = try #require(created.createdTaskID)
        state = await harness.state()
        let record = try #require(state.tasks.first { $0.id == taskID })
        #expect(record.state == .waitingForAgent)
        #expect(!record.hasRealClaim)
        #expect(Presentation.handoffStep(record) == .waiting)

        let copied = try await backend.perform(.copyHandoffCommand(taskID, agent: .claudeCode))
        #expect(copied.handoffCommand == TaskHandoff.command(for: taskID, handoffCode: record.task.handoffCode))
        #expect(record.task.handoffCode.map { copied.handoffCommand?.contains("(handoff code: \($0))") == true } == true)
        #expect(copied.message?.contains("Task ready to start") == true)
        state = await harness.state()
        #expect(state.tasks.first { $0.id == taskID }?.state == .waitingForAgent)

        // Review gate: only in ready_for_review, and the policy hides merge/push/request changes.
        await #expect(throws: AppBackendError.self) { try await backend.perform(.requestActionPreview(taskID, .postReply)) }
        do {
            _ = try await backend.perform(.requestActionPreview(taskID, .merge))
            Issue.record("merge preview should be refused")
        } catch let error as AppBackendError {
            #expect(error == .disabledByPolicy(.merge))
        }
        let bogus = ActionPreview(id: "pv_unknown", taskID: taskID, action: .postReply, title: "", target: "", body: "",
                                  fingerprint: "x", createdAt: Date(), isSimulated: true)
        do {
            _ = try await backend.perform(.approvePreview(bogus))
            Issue.record("unknown preview should be refused")
        } catch let error as AppBackendError {
            #expect(error == .previewExpired)
        }

        _ = try await backend.perform(.cancelTask(taskID))
        #expect(await harness.state().tasks.first { $0.id == taskID }?.state == .cancelled)
        _ = try await backend.perform(.reopenTask(taskID))
        #expect(await harness.state().tasks.first { $0.id == taskID }?.state == .waitingForAgent)
        _ = try await backend.perform(.dismissTask(taskID))
        #expect(await harness.state().tasks.first { $0.id == taskID }?.state == .dismissed)

        let other = try #require(state.attention.first { $0.id != item.id && $0.linkedTaskID == nil })
        _ = try await backend.perform(.snooze(attentionID: other.id, until: Date().addingTimeInterval(3_600)))
        state = await harness.state()
        if case .snoozed = state.attention.first(where: { $0.id == other.id })?.disposition {} else {
            Issue.record("expected snoozed")
        }
        _ = try await backend.perform(.acknowledge(attentionID: other.id))
        state = await harness.state()
        #expect(state.attention.first { $0.id == other.id }?.disposition == .acknowledged)
    }

    @Test func accountsRulesMappingsAndSettings() async throws {
        let harness = try await DemoBackendHarness.start()
        defer { Task { await harness.stop() } }
        let backend = harness.backend
        var state = await harness.state()
        let github = try #require(state.accounts.first { $0.kind == .github })

        _ = try await backend.perform(.setWritesEnabled(github.id, true))
        #expect(await harness.state().accounts.first { $0.id == github.id }?.account.writesEnabled == true)
        _ = try await backend.perform(.setWritesEnabled(github.id, false))
        #expect(await harness.state().accounts.first { $0.id == github.id }?.account.writesEnabled == false)

        // Connect validation happens before anything is stored; no token is ever echoed.
        let empty = ConnectAccountRequest(kind: .gitlab, method: .personalAccessToken, token: SecretValue("  "))
        await #expect(throws: AppBackendError.self) { try await backend.perform(.connectAccount(empty)) }
        let noEmail = ConnectAccountRequest(kind: .bitbucketCloud, method: .bitbucketAPIToken, token: SecretValue("secret-value"))
        do {
            _ = try await backend.perform(.connectAccount(noEmail))
            Issue.record("missing email should be refused")
        } catch let error as AppBackendError {
            #expect(!(error.errorDescription ?? "").contains("secret-value"))
        }

        // Rules: save from a template (inactive), activate, delete.
        let template = try #require(RuleTemplates.all.first)
        let rule = RuleTemplates.instantiate(template, id: IDGenerator.ruleID(), now: Date())
        _ = try await backend.perform(.saveRule(rule))
        #expect(await harness.state().rules.contains { $0.id == rule.id && !$0.isActive })
        _ = try await backend.perform(.activateRule(id: rule.id, active: true))
        #expect(await harness.state().rules.first { $0.id == rule.id }?.isActive == true)
        _ = try await backend.perform(.deleteRule(id: rule.id))
        #expect(await harness.state().rules.contains { $0.id == rule.id } == false)

        // Mappings: remove and map the synthetic checkout again (exact remote match → confirmed).
        let mapping = try #require(state.mappings.first)
        _ = try await backend.perform(.removeMapping(id: mapping.id))
        #expect(await harness.state().mappings.contains { $0.id == mapping.id } == false)
        let found = try await backend.perform(.findCheckouts(mapping.repo))
        #expect(found.mappingSuggestions == [])
        _ = try await backend.perform(.addMapping(repo: mapping.repo, repoFullPath: mapping.repoFullPath, checkoutPath: mapping.checkoutPath))
        state = await harness.state()
        #expect(state.mappings.contains { $0.repo == mapping.repo && $0.checkoutPath == mapping.checkoutPath })

        // Notifications and quiet hours.
        let until = Date().addingTimeInterval(3_600)
        _ = try await backend.perform(.pauseNotifications(until: until))
        let paused = try #require(await harness.state().notificationsPausedUntil)
        #expect(abs(paused.timeIntervalSince(until)) < 1)
        _ = try await backend.perform(.pauseNotifications(until: nil))
        #expect(await harness.state().notificationsPausedUntil == nil)
        let quiet = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60, timeZoneID: "Europe/Lisbon")
        _ = try await backend.perform(.setQuietHours(quiet))
        #expect(await harness.state().quietHours == quiet)
        // "Notify me about" switches are engine settings (persisted, forwarded to Sync), not UI-only preferences.
        _ = try await backend.perform(.setNotificationCategory(.ciFailures, enabled: false))
        _ = try await backend.perform(.setNotificationCategory(.agentResults, enabled: false))
        #expect(await harness.state().notificationPreferences == NotificationPreferences(disabled: [.ciFailures, .agentResults]))
        _ = try await backend.perform(.setNotificationCategory(.ciFailures, enabled: true))
        #expect(await harness.state().notificationPreferences == NotificationPreferences(disabled: [.agentResults]))
        #expect(await backend.runtime.sync.notificationPreferences() == NotificationPreferences(disabled: [.agentResults]))
        // "Agent read access" is an engine setting (default: only their tasks).
        #expect(await harness.state().agentReadAccess == .tasksOnly)
        _ = try await backend.perform(.setAgentReadAccess(.allInbox))
        #expect(await harness.state().agentReadAccess == .allInbox)
        #expect(await backend.runtime.engine.agentReadAccess() == .allInbox)

        // Fixture links are not opened in demo mode; other links are.
        let fixture = try await backend.perform(.openURL(URL(string: "https://github.com/acme/payments-api/pull/42")!))
        #expect(fixture.urlToOpen == nil)
        let tokens = try await backend.perform(.openURL(URL(string: "https://github.com/settings/tokens/new")!))
        #expect(tokens.urlToOpen != nil)

        // Export writes a file; disconnect removes the account and its data.
        let export = harness.root.appending(path: "export.sqlite")
        _ = try await backend.perform(.exportDatabase(to: export))
        #expect(FileManager.default.fileExists(atPath: MergeCuePaths.fileSystemPath(export)))
        _ = try await backend.perform(.disconnectAccount(github.id))
        state = await harness.state()
        #expect(!state.accounts.contains { $0.id == github.id })
        #expect(!state.changeRequests.contains { $0.key.account == github.id })

        let permission = try await backend.perform(.requestNotificationPermission)
        #expect(permission.tone == .attention)
    }

    @Test func refreshAdvancesTheDemoAndChangesAreStreamed() async throws {
        let harness = try await DemoBackendHarness.start()
        defer { Task { await harness.stop() } }
        let backend = harness.backend
        let demo = try #require(backend.runtime.demo)
        let before = demo.steps

        let stream = backend.changes()
        let received = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        _ = try await backend.perform(.refresh(account: nil))
        #expect(demo.steps.values.allSatisfy { $0 >= 1 })
        #expect(demo.steps != before)
        #expect(await received.value)
        let state = await harness.state()
        #expect(state.lastRefreshAt != nil)
        #expect(state.accounts.allSatisfy { $0.status.lastSuccessAt != nil })
    }

    @Test func shutdownStopsTheRuntimeAndRemovesTheSocket() async throws {
        let harness = try await DemoBackendHarness.start(ipc: true)
        let socket = await harness.backend.runtime.ipcStatus().socketPath
        #expect(FileManager.default.fileExists(atPath: socket))
        let stream = harness.backend.changes()
        let consumer = Task { for await _ in stream {} }
        let started = Date()
        await harness.backend.shutdown()
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!FileManager.default.fileExists(atPath: socket))
        #expect(await harness.backend.runtime.isRunning == false)
        consumer.cancel()
        try? FileManager.default.removeItem(at: harness.root)
    }

    @Test func agentRegistrationStates() async throws {
        let helper = DemoBackendHarness.fakeHelper
        let matching = try await DemoBackendHarness.start(registration: .registered(RegisteredMCPServer(command: MergeCuePaths.fileSystemPath(helper))))
        defer { Task { await matching.stop() } }
        #expect(await matching.state().agents.first?.mcpRegistration == .registered(verifiedAt: nil))
        // The wizard's plan: exact command, config snippet and backup under the data root.
        let prepared = try await matching.backend.perform(.prepareAgentRegistration(.claudeCode, .register))
        let plan = try #require(prepared.registrationPlan)
        #expect(plan.displayCommand.contains("mcp add --scope user mergecue"))
        #expect(plan.displayCommand.contains(MergeCuePaths.fileSystemPath(helper)))
        #expect(MergeCuePaths.fileSystemPath(plan.backupDirectory).contains("\(matching.root.lastPathComponent)/demo/backups/claude-"))
        // Codex isn't detected here.
        await #expect(throws: AppBackendError.self) { try await matching.backend.perform(.prepareAgentRegistration(.codex, .register)) }

        let other = try await DemoBackendHarness.start(registration: .registered(RegisteredMCPServer(command: "/somewhere/else/mergecue-mcp")))
        defer { Task { await other.stop() } }
        let state = await other.state()
        if case .needsAttention = state.agents.first?.mcpRegistration {} else {
            Issue.record("a registration with another command must need attention, got \(String(describing: state.agents.first?.mcpRegistration))")
        }
        #expect(state.agents.first?.mcpRegistration.isVerified == false)
    }
}

@Suite("EngineBackend mapping")
struct EngineBackendMappingTests {
    @Test func engineErrorsBecomeUserFacingErrors() {
        #expect(EngineBackend.backendError(EngineError.previewExpired) == .previewExpired)
        #expect(EngineBackend.backendError(EngineError.writesDisabled(account: "mona")) == .writesDisabled(account: "mona"))
        #expect(EngineBackend.backendError(EngineError.disabledByPolicy(.merge)) == .disabledByPolicy(.merge))
        #expect(EngineBackend.backendError(EngineError.notFound("Task x")) == .notFound("Task x"))
        let provider = EngineBackend.backendError(EngineError.provider(.forbidden(missingScope: "api", message: "no")))
        #expect(provider.errorDescription?.contains("api scope") == true)
        let leaked = EngineBackend.backendError(RuntimeError.failed("token ghp_abcdefghijklmnopqrstuvwxyz0123456789 rejected"))
        #expect(!(leaked.errorDescription ?? "").contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    @Test func approvalOutcomesUseTones() {
        let blocked = EngineBackend.result(of: .blocked(reason: "head moved"), action: .postReply, simulated: false)
        #expect(blocked.tone == .critical)
        #expect(blocked.message?.contains("Nothing was written") == true)
        let done = EngineBackend.result(of: .performed(taskState: .done, message: "Posted."), action: .postReply, simulated: true)
        #expect(done.tone == .success)
        #expect(done.message?.contains("demo fixture") == true)
    }

    @Test func fixtureLinks() {
        #expect(EngineBackend.isFixtureLink(URL(string: "https://gitlab.com/acme/payments-api/-/merge_requests/42")!))
        #expect(!EngineBackend.isFixtureLink(URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens")!))
        #expect(!EngineBackend.isFixtureLink(URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!))
    }

    @Test func instructionFilesAreDetectedByExistenceOnly() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mcui-instr-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appending(path: "CLAUDE.md"))
        try FileManager.default.createDirectory(at: root.appending(path: "AGENTS.md", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let path = MergeCuePaths.fileSystemPath(root)
        let found = EngineBackend.instructionFiles(in: [path, "/nonexistent/checkout"], names: ["AGENTS.md", "CLAUDE.md"], fileManager: .default)
        #expect(found[path] == ["CLAUDE.md"])
        #expect(found["/nonexistent/checkout"] == nil)
    }

    @Test func gitlabInstanceURLs() {
        #expect(ConnectGuide.gitlabInstance(from: "https://gitlab.com/") == .gitlabCom)
        #expect(ConnectGuide.gitlabInstance(from: "https://gitlab.example.com")?.apiURL.absoluteString == "https://gitlab.example.com/api/v4")
        #expect(ConnectGuide.gitlabInstance(from: "http://gitlab.example.com") == nil)
        #expect(ConnectGuide.gitlabInstance(from: "https://user:pw@gitlab.example.com") == nil)
        #expect(ConnectGuide.tokenPage(for: .gitlab, method: .personalAccessToken, wantsWrites: false)?.absoluteString.contains("scopes=read_api") == true)
        #expect(ConnectGuide.tokenPage(for: .github, method: .personalAccessToken)?.absoluteString
            == "https://github.com/settings/tokens/new?scopes=repo,read:org&description=MergeCue")
    }
}
