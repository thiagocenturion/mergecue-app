import AgentHandoff
import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueRuntime

// Every `AppCommand` → the matching engine / runtime call (Sources/MergeCueEngine/README.md "UI command mapping").

extension EngineBackend {
    public func perform(_ command: AppCommand) async throws -> AppCommandResult {
        do {
            return try await execute(command)
        } catch {
            throw Self.backendError(error)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func execute(_ command: AppCommand) async throws -> AppCommandResult {
        let engine = runtime.engine
        switch command {
        // MARK: Attention
        case .markRead(let id, let read):
            try await engine.markAttentionRead(id, read: read)
            return .none
        case .acknowledge(let id):
            try await engine.acknowledgeAttention(id)
            return AppCommandResult(message: "Acknowledged")
        case .snooze(let id, let until):
            try await engine.snoozeAttention(id, until: until)
            return AppCommandResult(message: "Snoozed until \(UIFormat.dateTime(until))")
        case .dismissAttention(let id):
            try await engine.dismissAttention(id)
            return AppCommandResult(message: "Dismissed")

        // MARK: Tasks
        case .createTask(let attentionID, let type):
            let task = try await engine.createTask(fromAttention: attentionID, type: type)
            return AppCommandResult(message: "Task \(task.id) created — task ready to start, awaiting agent connection",
                                    createdTaskID: task.id)
        case .cancelTask(let id):
            _ = try await engine.cancelTask(id)
            return AppCommandResult(message: "Task \(id) cancelled; any agent lease was released")
        case .retryTask(let id):
            _ = try await engine.retryTask(id)
            return AppCommandResult(message: "Task \(id) is ready to start again")
        case .reopenTask(let id):
            _ = try await engine.reopenTask(id)
            return AppCommandResult(message: "Task \(id) reopened")
        case .dismissTask(let id):
            _ = try await engine.dismissTask(id)
            return AppCommandResult(message: "Task \(id) dismissed")
        case .unblockTask(let id):
            _ = try await engine.unblockTask(id)
            return AppCommandResult(message: "Task \(id) unblocked")
        case .markTaskDone(let id):
            _ = try await engine.markTaskDone(id)
            return AppCommandResult(message: "Task \(id) marked done (nothing was written anywhere)")
        case .rejectResult(let id, let note):
            _ = try await engine.rejectResult(id, note: note)
            return AppCommandResult(message: "Result discarded — task \(id) is ready to start again")

        // MARK: Review gate
        case .requestActionPreview(let id, let kind):
            let preview = try await engine.previewAction(id, kind)
            return AppCommandResult(preview: Self.actionPreview(preview))
        case .approvePreview(let preview):
            let outcome = try await engine.perform(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint))
            return Self.result(of: outcome, action: preview.action, simulated: preview.isSimulated)
        case .declinePreview(let preview):
            try await engine.declinePreview(previewID: preview.id, approval: PreviewApproval(fingerprint: preview.fingerprint))
            return AppCommandResult(message: "Declined — nothing was written")

        // MARK: Sync and notifications
        case .refresh(let account):
            await runtime.refresh(account: account)
            return .none
        case .pauseNotifications(let until):
            try await engine.setNotificationsPaused(until: until)
            return AppCommandResult(message: until.map { "Notifications paused until \(UIFormat.dateTime($0))" } ?? "Notifications resumed")
        case .setQuietHours(let hours):
            try await engine.setQuietHours(hours)
            return AppCommandResult(message: hours == nil ? "Quiet hours off" : "Quiet hours saved")
        case .cleanUpWorktrees(let ids):
            let result = try await engine.cleanUpWorktrees(ids)
            let skipped = result.skipped.isEmpty ? "" : " (\(result.skipped.count) skipped)"
            return AppCommandResult(message: "Removed \(result.removed.count) task worktree\(result.removed.count == 1 ? "" : "s")\(skipped). Your checkouts were not touched.")
        case .setNotificationCategory(let category, let enabled):
            let current = await engine.notificationPreferences()
            try await engine.setNotificationPreferences(current.setting(category, enabled: enabled))
            return .none

        // MARK: Rules
        case .saveRule(let rule):
            let saved = try await engine.saveRule(rule)
            return AppCommandResult(message: "Rule “\(saved.name)” saved")
        case .deleteRule(let id):
            try await engine.deleteRule(id: id)
            return AppCommandResult(message: "Rule deleted")
        case .activateRule(let id, let active):
            let rule = try await engine.setRuleActive(id: id, active: active)
            return AppCommandResult(message: "“\(rule.name)” \(active ? "activated" : "turned off")")

        // MARK: Accounts
        case .connectAccount(let request):
            let account = try await connect(request)
            let demoNote = mode == .demo ? " (demo — fixture account, nothing left this Mac)" : ""
            return AppCommandResult(message: "Connected \(account.kind.displayName) · \(account.displayLabel). Remote writes stay off until you turn them on.\(demoNote)",
                                    tone: .success)
        case .disconnectAccount(let key):
            try await engine.disconnectAccount(key)
            return AppCommandResult(message: "Disconnected \(key.kind.displayName). The token was removed from your Keychain — revoke it on \(key.kind.displayName) too if you no longer need it.")
        case .setWritesEnabled(let key, let enabled):
            try await engine.setWritesEnabled(key, enabled)
            return AppCommandResult(message: enabled
                ? "Remote writes on for \(key.kind.displayName). Every reply or resolve still needs your approval of an exact preview."
                : "Remote writes off for \(key.kind.displayName)")

        // MARK: Mappings
        case .addMapping(let repo, let path, let checkoutPath):
            let mapping = try await engine.addMapping(repo: repo, repoFullPath: path, checkoutPath: checkoutPath)
            let confirmation = mapping.isConfirmed ? "confirmed (exact remote match)" : "\(mapping.confidence.rawValue) match — confirm it to use it"
            return AppCommandResult(message: "Mapped \(path) to \(UIFormat.abbreviatedPath(checkoutPath)): \(confirmation)")
        case .confirmMapping(let id):
            _ = try await engine.confirmMapping(id: id)
            return AppCommandResult(message: "Mapping confirmed")
        case .removeMapping(let id):
            try await engine.removeMapping(id: id)
            return AppCommandResult(message: "Mapping removed")
        case .findCheckouts(let repo):
            let suggestions = try await engine.mappingSuggestions(for: repo)
            return AppCommandResult(message: suggestions.isEmpty ? "No matching checkout found in the usual folders. Choose one yourself." : nil,
                                    mappingSuggestions: suggestions)
        case .loadRepositories(let key, let force):
            startRepositoryListing(key, forceRefresh: force)
            return .none
        case .scanCheckouts(let repos):
            return startCheckoutScan(repos) ? .none : AppCommandResult(message: "A checkout search is already running.")

        // MARK: Handoff and links
        case .copyHandoffCommand(let id, let agent):
            let handoff = try await engine.handoff(for: id)
            try await engine.recordHandoffCopied(id, agentName: agent?.displayName)
            let target = agent?.displayName ?? "your agent"
            return AppCommandResult(message: "Command copied — paste it into \(target). The task stays “\(handoff.statusText)” until the agent claims it.",
                                    handoffCommand: handoff.command)
        case .openInAgent(let id, let kind):
            let agent = try detected(kind)
            let handoff = try await engine.handoff(for: id)
            _ = try await runtime.openInAgent(taskID: id, agent: agent)
            let place = handoff.workingDirectory.map(UIFormat.abbreviatedPath) ?? "the task checkout"
            return AppCommandResult(message: "Opened \(kind.displayName) in a new Terminal window at \(place). The task stays “Task ready to start” until the agent claims it.",
                                    tone: .success)
        case .loadCheckLog(let check):
            return AppCommandResult(logExcerpt: try await engine.loadCheckLog(check))
        case .openURL(let url):
            if mode == .demo, Self.isFixtureLink(url) {
                return AppCommandResult(message: "Demo data — \(url.host() ?? "this link") has no such repository, so the link wasn't opened.")
            }
            return AppCommandResult(urlToOpen: url)

        // MARK: Agent setup
        case .refreshAgents:
            await reloadAgents()
            return AppCommandResult(message: detectedAgents.isEmpty ? "No supported agent found on this Mac" : "Agents checked")
        case .prepareAgentRegistration(let kind, let action):
            let plan = try runtime.registrationPlan(for: try detected(kind), action: action)
            return AppCommandResult(registrationPlan: plan)
        case .applyAgentRegistration(let plan, let consent):
            return try await applyRegistration(plan, consent: consent)
        case .verifyAgent(let kind):
            return try await verify(kind)

        // MARK: App and data
        case .setLaunchAtLogin(let enabled):
            let status = try runtime.setLaunchAtLogin(enabled)
            notifyLocalChange()
            let message = switch status {
            case .enabled: "MergeCue opens at login"
            case .disabled: "MergeCue no longer opens at login"
            case .requiresApproval: "Approve MergeCue in System Settings › General › Login Items to finish"
            case .unavailable: "Launch at login is available only in the installed app"
            }
            return AppCommandResult(message: message, tone: status == .requiresApproval ? .attention : nil)
        case .requestNotificationPermission:
            let granted = await options.requestNotificationAuthorization()
            return AppCommandResult(message: granted
                ? "Notifications allowed. One grouped notification per PR/MR."
                : "Notifications are off. You can allow them later in System Settings › Notifications › MergeCue.",
                                    tone: granted ? .success : .attention)
        case .exportDatabase(let url):
            try await engine.exportDatabase(to: MergeCuePaths.fileSystemPath(url))
            return AppCommandResult(message: "Database exported to \(UIFormat.abbreviatedPath(MergeCuePaths.fileSystemPath(url))) (no credentials inside)",
                                    tone: .success)
        case .resetAllData:
            try await engine.resetAllData()
            let note = mode == .demo ? " Relaunch MergeCue to load the demo data again." : ""
            return AppCommandResult(message: "All local data and stored tokens were deleted.\(note)", tone: .success)
        }
    }

    // MARK: Accounts

    private func connect(_ request: ConnectAccountRequest) async throws -> Account {
        let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.method {
        case .githubCLIImport:
            guard request.kind == .github else { throw AppBackendError.invalidInput("The GitHub CLI can only connect GitHub.") }
            return try await runtime.connectGitHubFromCLI(label: label)
        case .oauthDeviceFlow:
            throw AppBackendError.unsupported("Signing in with the browser isn't available yet. Paste a token instead.")
        case .personalAccessToken, .bitbucketAccessToken, .bitbucketAPIToken:
            guard let token = request.token, !token.isEmpty else {
                throw AppBackendError.invalidInput("Paste a token to connect \(request.kind.displayName).")
            }
            let credential: Credential
            if request.method == .bitbucketAPIToken {
                let email = (request.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard email.contains("@") else {
                    throw AppBackendError.invalidInput("Atlassian API tokens are used with your Atlassian account email — enter it too.")
                }
                credential = .basic(username: email, password: token.exposeForCredentialStore())
            } else {
                credential = .bearer(token.exposeForCredentialStore())
            }
            return try await runtime.engine.connectAccount(AccountConnectionRequest(
                instance: request.instance, method: request.method, credential: credential, label: label
            ))
        }
    }

    // MARK: Review gate

    nonisolated static func result(of outcome: ActionOutcome, action: RemoteActionKind, simulated: Bool) -> AppCommandResult {
        let demo = simulated ? " (demo fixture — nothing reached a real provider)" : ""
        switch outcome {
        case .performed(let state, let message):
            let next = state == .done ? "" : " Review the next action when you're ready."
            return AppCommandResult(message: "\(action.displayName) done\(demo). \(message)\(next)", tone: .success)
        case .alreadyPerformed(let message):
            return AppCommandResult(message: message, tone: .neutral)
        case .blocked(let reason):
            return AppCommandResult(message: "Nothing was written: \(reason)", tone: .critical)
        case .failed(let error):
            return AppCommandResult(message: "\(action.displayName) failed: \(error.message)", tone: .critical)
        }
    }

    /// Links into the demo fixtures' repositories (they don't exist on the real providers).
    nonisolated static func isFixtureLink(_ url: URL) -> Bool {
        let hosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org"]
        guard let host = url.host()?.lowercased(), hosts.contains(host) else { return false }
        let path = url.path(percentEncoded: false)
        return !(path.hasPrefix("/settings") || path.hasPrefix("/-/"))
    }

    // MARK: Agent setup

    private func applyRegistration(_ plan: MCPRegistrationPlan, consent: RegistrationConsent) async throws -> AppCommandResult {
        let outcome = try await runtime.applyRegistration(plan, consent: consent)
        registrations[plan.agent] = outcome.status
        clearVerification(plan.agent)
        notifyLocalChange()
        let name = plan.agent.displayName
        guard outcome.changed else {
            return AppCommandResult(message: plan.action == .register
                ? "\(name) already had MergeCue registered — nothing was changed. Verify the connection next."
                : "\(name) had no MergeCue registration — nothing was changed.")
        }
        let backup = outcome.backup.map { " Backup: \(UIFormat.abbreviatedPath(MergeCuePaths.fileSystemPath($0.directory)))." } ?? ""
        return AppCommandResult(message: plan.action == .register
            ? "Registered MergeCue with \(name).\(backup) Verify the connection next."
            : "Removed MergeCue from \(name).\(backup)", tone: .success)
    }

    private func verify(_ kind: AgentKind) async throws -> AppCommandResult {
        let agent = try detected(kind)
        registrations[kind] = await options.registrationStatus(runtime, agent)
        guard let helper = runtime.mcpHelperURL else { throw RuntimeError.helperNotFound }
        let report = try await runtime.verifyMCPHelper(probe: .listAttention)
        let roundTrip: String = switch report.readOnlyRoundTrip {
        case .ok(let tool)?: "\(tool) answered (read-only)"
        case .toolError(let tool, let code, let message, _)? where code == "app_unavailable": "\(tool): MergeCue isn't reachable (\(message))"
        case .toolError(let tool, _, let message, _)?: "\(tool) returned an error: \(SecretRedactor.redact(message))"
        case .failed(let tool, let message)?: "\(tool) failed: \(SecretRedactor.redact(message))"
        case nil: "No round trip made"
        }
        let registered = registrations[kind]?.isRegistered(helper: helper) ?? false
        let succeeded = report.looksLikeMergeCue && (report.readOnlyRoundTrip?.isOK ?? false)
        let now = Date()
        if succeeded && registered {
            recordVerification(kind, helper: helper, at: now)
        } else {
            clearVerification(kind)
        }
        notifyLocalChange()
        let verification = AgentVerification(agent: kind, succeeded: succeeded && registered, toolCount: report.toolNames.count,
                                             missingTools: report.missingTools, roundTrip: roundTrip, checkedAt: now)
        let message: String
        if succeeded && registered {
            message = "\(kind.displayName) is connected: \(report.toolNames.count) MergeCue tools listed and a read-only call succeeded."
        } else if succeeded {
            message = "The helper works, but \(kind.displayName) isn't registered with it yet. Register first."
        } else {
            message = "Verification failed: \(roundTrip)\(report.missingTools.isEmpty ? "" : "; missing tools: \(report.missingTools.joined(separator: ", "))")"
        }
        return AppCommandResult(message: message, verification: verification, tone: succeeded && registered ? .success : .critical)
    }
}
