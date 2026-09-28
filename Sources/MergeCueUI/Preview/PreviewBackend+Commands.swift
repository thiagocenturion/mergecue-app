import AgentHandoff
import Foundation
import MergeCueCore

extension PreviewBackend {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func execute(_ command: AppCommand) throws -> AppCommandResult {
        switch command {
        case .markRead(let id, let read):
            try updateAttention(id) { $0.isUnread = !read }
            return .none
        case .acknowledge(let id):
            try updateAttention(id) { $0.disposition = .acknowledged; $0.isUnread = false }
            return AppCommandResult(message: "Acknowledged")
        case .snooze(let id, let until):
            try updateAttention(id) { $0.disposition = .snoozed(until: until); $0.isUnread = false }
            return AppCommandResult(message: "Snoozed until \(UIFormat.dateTime(until))")
        case .dismissAttention(let id):
            try updateAttention(id) { $0.disposition = .dismissed; $0.isUnread = false }
            return AppCommandResult(message: "Dismissed")

        case .createTask(let attentionID, let type):
            return try createTask(attentionID: attentionID, type: type)
        case .cancelTask(let id):
            try transition(id, .cancel, .cancelled, "Cancelled by you; the lease was released")
            return AppCommandResult(message: "Task \(id) cancelled")
        case .retryTask(let id):
            try transition(id, .retry, .retried, "Retry requested — waiting for an agent to claim it again") { $0.lastError = nil }
            return AppCommandResult(message: "Task \(id) is waiting for an agent again")
        case .reopenTask(let id):
            try transition(id, .reopen, .reopened, "Reopened by you")
            return AppCommandResult(message: "Task \(id) reopened")
        case .dismissTask(let id):
            try transition(id, .dismiss, .dismissed, "Dismissed by you")
            return AppCommandResult(message: "Task \(id) dismissed")
        case .unblockTask(let id):
            try transition(id, .unblock, .unblocked, "Unblocked by you") { task in
                if task.checkout?.policy == .blocked { task.checkout?.policy = .readOnly }
            }
            return AppCommandResult(message: "Task \(id) unblocked")
        case .markTaskDone(let id):
            try transition(id, .markDone, .completed, "Marked done by you (no remote action)")
            resolveAttention(forTask: id)
            return AppCommandResult(message: "Task \(id) marked done")
        case .rejectResult(let id, let note):
            try transition(id, .rejectResult, .rejected, "Discarded the result and asked for a retry" + (note.map { ": \($0)" } ?? "")) { task in
                task.resultSummary = nil
                task.proposedReply = nil
                task.knownRisks = []
            }
            return AppCommandResult(message: "Result discarded — task \(id) is waiting for an agent")

        case .requestActionPreview(let id, let kind):
            return AppCommandResult(preview: try makePreview(taskID: id, kind: kind))
        case .approvePreview(let preview):
            return try approve(preview)
        case .declinePreview(let preview):
            try record(preview, decision: .rejected)
            appendActivity(preview.taskID, .user, "mona-dev", .note, "Declined the \(preview.action.displayName) preview; nothing was written")
            previews[preview.id] = nil
            return AppCommandResult(message: "Declined — nothing was written")

        case .refresh(let account):
            simulateRefresh(account)
            return .none
        case .pauseNotifications(let until):
            state.notificationsPausedUntil = until
            return AppCommandResult(message: until.map { "Notifications paused until \(UIFormat.dateTime($0))" } ?? "Notifications resumed")
        case .setQuietHours(let hours):
            state.quietHours = hours
            return AppCommandResult(message: hours == nil ? "Quiet hours off" : "Quiet hours saved")
        case .cleanUpWorktrees(let ids):
            state.worktreeCleanupCandidates.removeAll { ids.contains($0.taskID) }
            return AppCommandResult(message: "Preview: nothing was removed")
        case .setNotificationCategory(let category, let enabled):
            state.notificationPreferences.set(category, enabled: enabled)
            return .none
        case .setTrackingPreferences(let preferences):
            state.trackingPreferences = preferences
            return .none

        case .saveRule(let rule):
            var rule = rule
            rule.updatedAt = now
            if let index = state.rules.firstIndex(where: { $0.id == rule.id }) {
                if state.rules[index].origin == .agentProposal { rule.isActive = state.rules[index].isActive }
                state.rules[index] = rule
            } else {
                state.rules.insert(rule, at: 0)
            }
            return AppCommandResult(message: "Rule “\(rule.name)” saved")
        case .deleteRule(let id):
            guard RuleTemplates.template(id: id) == nil else { throw AppBackendError.invalidInput("Built-in templates can't be deleted.") }
            state.rules.removeAll { $0.id == id }
            return AppCommandResult(message: "Rule deleted")
        case .activateRule(let id, let active):
            guard let index = state.rules.firstIndex(where: { $0.id == id }) else { throw AppBackendError.notFound("The rule") }
            state.rules[index].isActive = active
            state.rules[index].updatedAt = now
            return AppCommandResult(message: "“\(state.rules[index].name)” \(active ? "activated" : "turned off")")

        case .connectAccount(let request):
            return try connect(request)
        case .disconnectAccount(let key):
            disconnect(key)
            return AppCommandResult(message: "Disconnected \(key.kind.displayName). Preview: no credential existed to delete.")
        case .setWritesEnabled(let key, let enabled):
            guard let index = state.accounts.firstIndex(where: { $0.id == key }) else { throw AppBackendError.notFound("The account") }
            state.accounts[index].account.writesEnabled = enabled
            let name = "\(key.kind.displayName) · \(state.accounts[index].account.displayLabel)"
            return AppCommandResult(message: enabled
                ? "Remote writes on for \(name). Every reply or resolve still needs your approval."
                : "Remote writes off for \(name)")

        case .addMapping(let repo, let path, let checkoutPath):
            state.mappings.removeAll { $0.repo == repo && $0.checkoutPath == checkoutPath }
            state.mappings.append(RepoMapping(id: IDGenerator.mappingID(), repo: repo, repoFullPath: path, checkoutPath: checkoutPath,
                                              confidence: .probable, confirmedAt: now, createdAt: now))
            return AppCommandResult(message: "Mapped \(path) to \(checkoutPath). Preview: the checkout's remotes were not inspected.")
        case .confirmMapping(let id):
            guard let index = state.mappings.firstIndex(where: { $0.id == id }) else { throw AppBackendError.notFound("The mapping") }
            state.mappings[index].confirmedAt = now
            return AppCommandResult(message: "Mapping confirmed")
        case .removeMapping(let id):
            state.mappings.removeAll { $0.id == id }
            return AppCommandResult(message: "Mapping removed")

        case .copyHandoffCommand(let id, let agent):
            guard let record = state.tasks.first(where: { $0.id == id }) else { throw AppBackendError.notFound("Task \(id)") }
            guard !record.task.isTerminal else { throw AppBackendError.invalidTransition("Task \(id) is \(record.task.state.displayName.lowercased()); reopen it first.") }
            let target = agent?.displayName ?? "your agent"
            return AppCommandResult(message: "Command copied — paste it into \(target). The task stays “Waiting for agent” until the agent claims it.",
                                    handoffCommand: HandoffText.command(for: id))
        case .openInAgent(let id, let agent):
            guard let record = state.tasks.first(where: { $0.id == id }) else { throw AppBackendError.notFound("Task \(id)") }
            guard state.agents.first(where: { $0.kind == agent })?.canOpenTasks == true else {
                throw AppBackendError.unsupported("Opening tasks in \(agent.displayName) isn't verified yet — use Copy command instead.")
            }
            let place = record.task.checkout?.worktreePath ?? record.task.checkout?.mappedCheckoutPath ?? "the task checkout"
            return AppCommandResult(message: "Preview: MergeCue would open \(agent.displayName) in \(place). Nothing was launched.")
        case .loadCheckLog(let check):
            let excerpt = logs[check.id] ?? LogExcerpt(text: "No log excerpt for this check in the preview data.", truncated: false)
            return AppCommandResult(logExcerpt: excerpt)
        case .openURL(let url):
            if Self.isSynthetic(url) {
                return AppCommandResult(message: "Preview data — \(url.host() ?? "this link") has no such repository, so the link wasn't opened.")
            }
            return AppCommandResult(urlToOpen: url)

        case .refreshAgents:
            return AppCommandResult(message: "Preview data: the agents shown are synthetic; nothing was detected.")
        case .prepareAgentRegistration(let kind, let action):
            guard let agent = state.agents.first(where: { $0.kind == kind }) else {
                throw AppBackendError.unsupported("\(kind.displayName) wasn't found on this Mac.")
            }
            let helper = URL(filePath: "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp")
            let plan: MCPRegistrationPlan
            do {
                plan = action == .register
                    ? try MCPRegistrationPlan.register(agent.detected, helper: helper, paths: MergeCuePaths(), now: now)
                    : try MCPRegistrationPlan.unregister(agent: kind, executable: agent.detected.executableURL, helper: helper,
                                                         paths: MergeCuePaths(), now: now)
            } catch {
                throw AppBackendError.failed(error.localizedDescription)
            }
            return AppCommandResult(registrationPlan: plan)
        case .applyAgentRegistration(let plan, _):
            guard let index = state.agents.firstIndex(where: { $0.kind == plan.agent }) else { throw AppBackendError.notFound(plan.agent.displayName) }
            state.agents[index].mcpRegistration = plan.action == .register ? .registered(verifiedAt: nil) : .notRegistered
            return AppCommandResult(message: "Preview: \(plan.agent.displayName)'s configuration was not changed and nothing was run.")
        case .verifyAgent(let kind):
            return AppCommandResult(message: "Preview data: verification needs the real app, so nothing was checked.",
                                    verification: AgentVerification(agent: kind, succeeded: false, toolCount: 0, missingTools: [],
                                                                    roundTrip: "Not run (preview data)", checkedAt: now))
        case .findCheckouts:
            return AppCommandResult(message: "Preview data: no folders were scanned.", mappingSuggestions: [])
        case .loadRepositories(let key, _):
            state.repositoryLists[key] = .loaded(RepositoryDirectory.openRepositories(state.changeRequests, account: key),
                                                 fetchedAt: now, isTruncated: false)
            return .none
        case .scanCheckouts:
            state.checkoutScan = CheckoutScanState(finishedAt: now)
            return AppCommandResult(message: "Preview data: no folders were scanned.")
        case .setLaunchAtLogin:
            return AppCommandResult(message: "Preview data: the login item was not changed.")
        case .requestNotificationPermission:
            return AppCommandResult(message: "Preview data: macOS was not asked for notification permission.")
        case .exportDatabase, .resetAllData:
            throw AppBackendError.unsupported("Preview data: nothing is stored, so there is nothing to export or reset.")
        }
    }

    /// Links into the preview's synthetic namespaces are not opened.
    static func isSynthetic(_ url: URL) -> Bool {
        let hosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org"]
        guard let host = url.host()?.lowercased(), hosts.contains(host) else { return false }
        let path = url.path(percentEncoded: false)
        return ["/acme/", "/acme-platform/", "/mona-dev/"].contains { path.hasPrefix($0) }
    }

    // MARK: Attention

    func updateAttention(_ id: String, _ change: (inout AttentionItem) -> Void) throws {
        guard let index = state.attention.firstIndex(where: { $0.id == id }) else { throw AppBackendError.notFound("The item") }
        change(&state.attention[index])
    }

    func resolveAttention(forTask id: TaskID) {
        for index in state.attention.indices where state.attention[index].linkedTaskID == id {
            state.attention[index].disposition = .resolved
            state.attention[index].isUnread = false
        }
    }

    // MARK: Tasks

    func createTask(attentionID: String, type: TaskType) throws -> AppCommandResult {
        guard let itemIndex = state.attention.firstIndex(where: { $0.id == attentionID }) else { throw AppBackendError.notFound("The item") }
        let item = state.attention[itemIndex]
        if let existing = state.tasks.first(where: { ($0.id == item.linkedTaskID || $0.task.origin.attentionItemID == item.id) && !$0.task.isTerminal }) {
            throw AppBackendError.invalidTransition("Task \(existing.id) already handles this item.")
        }
        let snapshot = state.changeRequests.first { $0.key == item.changeRequest }
        let thread = item.thread.flatMap { snapshot?.thread($0) }
        let check = item.check.flatMap { snapshot?.check($0) }
        var quoted: [UntrustedText] = []
        if let root = thread?.rootComment {
            quoted.append(.bounded(source: UntrustedText.Source.reviewComment, author: root.author.username, createdAt: root.createdAt,
                                   text: root.body, maxBytes: 4_096))
        }
        if let latest = thread?.latestComment, latest.id != thread?.rootComment?.id {
            quoted.append(.bounded(source: UntrustedText.Source.reviewComment, author: latest.author.username, createdAt: latest.createdAt,
                                   text: latest.body, maxBytes: 4_096))
        }
        if let check, let log = logs[check.key.id] {
            quoted.append(.bounded(source: UntrustedText.Source.ciLog, text: log.text, maxBytes: 4_096))
        }
        let summary = snapshot?.summary
        let webURL = thread?.webURL ?? summary?.webURL ?? ProviderInstance.default(for: item.providerKind).webURL
        let id = TaskID.generate(avoiding: Set(state.tasks.map(\.id)))
        let task = MCTask(
            id: id, type: type, createdAt: now,
            origin: TaskOrigin(attentionItemID: item.id, changeRequest: item.changeRequest, changeRequestRef: item.changeRequestRef,
                               title: item.title, webURL: webURL, thread: item.thread, check: item.check),
            trigger: TaskTriggerSnapshot(eventType: item.reason.eventType, capturedAt: now, headSHA: summary?.headSHA,
                                         sourceBranch: summary?.sourceBranch ?? "", targetBranch: summary?.targetBranch ?? "",
                                         quoted: quoted, anchor: thread?.anchor),
            checkout: checkout(for: item, type: type, summary: summary)
        )
        state.tasks.append(TaskRecord(task: task, activities: [
            TaskActivity(id: nextActivityID(), taskID: id, at: now, actor: .user, actorName: "mona-dev", kind: .created,
                         message: "Created from \(item.reason.displayName.lowercased()) (\(type.actionTitle))", toState: .waitingForAgent),
        ]))
        state.attention[itemIndex].linkedTaskID = id
        state.attention[itemIndex].isUnread = false
        return AppCommandResult(message: "Task \(id) created — awaiting agent connection", createdTaskID: id)
    }

    func checkout(for item: AttentionItem, type: TaskType, summary: ChangeRequestSummary?) -> TaskCheckout {
        let source = summary?.sourceBranch ?? ""
        let target = summary?.targetBranch ?? ""
        guard let mapping = state.mappings.first(where: { $0.repo == item.changeRequest.repo }) else {
            return TaskCheckout(policy: .readOnly, sourceBranch: source, targetBranch: target,
                                blockedReason: type.isCodeTask ? "No checkout mapped — the agent can inspect and draft; code edits need a mapped checkout" : nil)
        }
        // The preview's GitHub acme/payments-api checkout is a GitButler workspace: never edited directly.
        if mapping.id == "map_gh_payments" {
            return TaskCheckout(policy: .readOnly, mappedCheckoutPath: mapping.checkoutPath, sourceBranch: source, targetBranch: target,
                                isGitButlerManaged: true,
                                blockedReason: type.isCodeTask ? "Code edits need a safe checkout — the mapped checkout is a GitButler workspace" : nil)
        }
        return TaskCheckout(policy: type.isCodeTask ? .isolatedWorktree : .readOnly, mappedCheckoutPath: mapping.checkoutPath,
                            baseSHA: summary?.headSHA, sourceBranch: source, targetBranch: target)
    }

    func transition(_ id: TaskID, _ trigger: TaskTrigger, _ kind: ActivityKind, _ message: String,
                    _ change: (inout MCTask) -> Void = { _ in }) throws {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw AppBackendError.notFound("Task \(id)") }
        var task = state.tasks[index].task
        let from = task.state
        let next: TaskState
        do {
            next = try TaskStateMachine.next(from: from, on: trigger, by: .user)
        } catch {
            throw AppBackendError.invalidTransition(error.errorDescription ?? "That action isn't possible now.")
        }
        task.state = next
        task.version += 1
        task.updatedAt = now
        if next == .waitingForAgent || next.isTerminal { task.lease = nil }
        change(&task)
        state.tasks[index].task = task
        state.tasks[index].activities.append(TaskActivity(id: nextActivityID(), taskID: id, at: now, actor: .user, actorName: "mona-dev",
                                                          kind: kind, message: message, fromState: from, toState: next))
    }

    func appendActivity(_ id: TaskID, _ actor: TransitionActor, _ name: String?, _ kind: ActivityKind, _ message: String,
                        from: TaskState? = nil, to: TaskState? = nil) {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[index].activities.append(TaskActivity(id: nextActivityID(), taskID: id, at: now, actor: actor, actorName: name,
                                                          kind: kind, message: message, fromState: from, toState: to))
    }

    // MARK: Sync

    func simulateRefresh(_ only: AccountKey?) {
        let now = now
        state.lastRefreshAt = now
        for index in state.accounts.indices where only == nil || state.accounts[index].id == only {
            var status = state.accounts[index].status
            status.lastAttemptAt = now
            switch status.state {
            case .authExpired, .permissionDenied:
                continue
            case .rateLimited(let until) where (until ?? now) > now:
                state.accounts[index].status = status
                continue
            default:
                status.state = .ok
                status.lastSuccessAt = now
                status.consecutiveFailures = 0
                status.message = nil
                status.nextRunAt = now.addingTimeInterval(90)
            }
            state.accounts[index].status = status
        }
    }

    // MARK: Accounts

    func connect(_ request: ConnectAccountRequest) throws -> AppCommandResult {
        let needsToken: Set<AuthMethod> = [.personalAccessToken, .bitbucketAPIToken, .bitbucketAccessToken]
        if needsToken.contains(request.method), request.token?.isEmpty ?? true {
            throw AppBackendError.invalidInput("Paste a token to connect \(request.kind.displayName).")
        }
        if request.method == .bitbucketAPIToken, (request.email ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw AppBackendError.invalidInput("Atlassian API tokens are used with your account email — enter it too.")
        }
        // The token is intentionally dropped here: the preview never stores or sends credentials.
        let now = now
        if let index = state.accounts.firstIndex(where: { $0.kind == request.kind }) {
            state.accounts[index].account.authMethod = request.method
            state.accounts[index].status = AccountSyncStatus(account: state.accounts[index].id, state: .ok, lastAttemptAt: now,
                                                             lastSuccessAt: now, nextRunAt: now.addingTimeInterval(90))
        } else {
            let key = AccountKey(instance: request.instance, remoteUserID: "preview-\(request.kind.rawValue)")
            let account = Account(id: key, instance: request.instance, username: "mona-dev", displayName: "Mona Dev",
                                  authMethod: request.method, label: request.label, connectedAt: now, isDemo: true)
            state.accounts.append(AccountState(account: account,
                                               status: AccountSyncStatus(account: key, state: .ok, lastAttemptAt: now, lastSuccessAt: now),
                                               capabilities: PreviewWorld.manifest(request.kind)))
        }
        return AppCommandResult(message: "Preview: \(request.kind.displayName) connection simulated. The token was discarded and nothing was sent.")
    }

    func disconnect(_ key: AccountKey) {
        let removedTasks = Set(state.tasks.filter { $0.task.origin.account == key }.map(\.id))
        state.accounts.removeAll { $0.id == key }
        state.changeRequests.removeAll { $0.key.account == key }
        state.attention.removeAll { $0.account == key }
        state.tasks.removeAll { removedTasks.contains($0.id) }
        state.mappings.removeAll { $0.repo.account == key }
    }
}

nonisolated extension AttentionReason {
    /// The change event type a task snapshot records for this reason.
    var eventType: ChangeEventType {
        switch self {
        case .reviewComment, .reviewerQuestion, .codeSuggestion: .reviewComment
        case .changesRequested: .changeRequested
        case .reply: .reply
        case .ciFailed: .ciFailed
        case .reviewRequested: .reviewRequested
        case .readyToMerge: .readyToMerge
        case .mergeConflict: .headChanged
        }
    }
}
