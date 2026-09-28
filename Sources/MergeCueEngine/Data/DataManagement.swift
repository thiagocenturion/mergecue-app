import Foundation
import MergeCueCore
import MergeCueStore

// Data management (export, reset, retention), notification settings, handoff metadata and the one-shot state
// snapshot for the UI.

extension MergeCueEngine {
    // MARK: Export / reset / prune

    /// Writes a consistent copy of the database to `path` (mode 0600). Contains no credentials.
    public func exportDatabase(to path: String) async throws(EngineError) {
        try await uiCall {
            try await database.exportCopy(to: path)
            await appendAudit(actor: "user", action: "export_database", target: (path as NSString).lastPathComponent, outcome: .succeeded)
        }
    }

    /// Deletes every account credential and every stored record, then recreates an empty database.
    public func resetAllData() async throws(EngineError) {
        try await uiCall {
            for account in (try? await database.accounts()) ?? [] {
                try? env.credentials.delete(for: account.id)
            }
            previews.removeAll()
            writeAttempts.removeAll()
            try await database.resetAll()
            await env.sync.accountsDidChange()
            for change in [EngineChange.accounts, .syncStatus, .attention, .changeRequests, .tasks(nil), .rules, .mappings, .audit] {
                emit(change)
            }
        }
    }

    /// Retention: removes history older than `date` (never anything of a non-terminal task). Returns rows removed.
    @discardableResult
    public func pruneHistory(olderThan date: Date) async throws(EngineError) -> Int {
        try await uiCall {
            let removed = try await database.pruneHistory(olderThan: date)
            emit(.audit)
            return removed
        }
    }

    // MARK: Notification settings

    /// Pauses notifications until `until` (nil resumes). Persisted and forwarded to Sync.
    public func setNotificationsPaused(until: Date?) async throws(EngineError) {
        try await uiCall {
            try await database.setSetting(SettingsKey.notificationsPausedUntil, until)
            await env.sync.setNotificationsPaused(until: until)
            emit(.syncStatus)
        }
    }

    public func notificationsPausedUntil() async -> Date? {
        guard let until = try? await database.setting(SettingsKey.notificationsPausedUntil, as: Date.self), until > now else {
            return nil
        }
        return until
    }

    /// Global quiet hours (persisted; rules carry their own quiet hours).
    public func setQuietHours(_ quietHours: QuietHours?) async throws(EngineError) {
        try await uiCall {
            try await database.setSetting(SettingsKey.quietHours, quietHours)
            emit(.rules)
        }
    }

    public func quietHours() async -> QuietHours? {
        try? await database.setting(SettingsKey.quietHours, as: QuietHours.self)
    }

    // MARK: Handoff

    /// Handoff metadata for a task: the canonical prompt, the folder to open, and an honest status text.
    /// Building or copying it never changes the task and never writes anywhere.
    public func handoff(for taskID: TaskID) async throws(EngineError) -> TaskHandoff {
        try await uiCall {
            let task = try await requireTask(taskID)
            let status: String = switch task.state {
            case .waitingForAgent, .stale: "Task ready to start"
            case .working: task.lease.map { "\($0.agentName) is working" } ?? "Task ready to start"
            default: task.state.displayName
            }
            return TaskHandoff(
                taskID: task.id,
                command: TaskHandoff.command(for: task.id),
                workingDirectory: task.checkout?.worktreePath ?? (task.checkout?.policy == .readOnly ? task.checkout?.mappedCheckoutPath : nil),
                checkoutPolicy: task.checkout?.policy,
                blockedReason: task.checkout?.blockedReason,
                statusText: status
            )
        }
    }

    /// Records that the owner copied the handoff command (history only; the state stays unchanged until a real
    /// `claim_task` arrives).
    public func recordHandoffCopied(_ taskID: TaskID, agentName: String? = nil) async throws(EngineError) {
        try await uiCall {
            let task = try await requireTask(taskID)
            await recordActivity(
                task.id, actor: .user, kind: .note,
                message: "Handoff command copied\(agentName.map { " for \($0)" } ?? ""). Waiting for an agent to claim the task."
            )
            emit(.tasks(task.id))
        }
    }

    // MARK: Snapshot

    /// One consistent read of everything the UI shows.
    public func snapshot() async throws(EngineError) -> EngineSnapshot {
        let accounts = try await accountStates()
        let attention = try await attentionItems(AttentionQuery(status: .all))
        let tasks = try await taskDetails()
        let changeRequests = try await changeRequests()
        let rules = try await rules()
        let mappings = try await mappings()
        let lastRefresh = try? await database.setting(SettingsKey.lastRefreshAt, as: Date.self)
        return EngineSnapshot(
            accounts: accounts,
            attention: attention,
            tasks: tasks,
            changeRequests: changeRequests,
            rules: rules,
            mappings: mappings,
            notificationsPausedUntil: await notificationsPausedUntil(),
            quietHours: await quietHours(),
            lastRefreshAt: lastRefresh ?? nil,
            isDemo: env.isDemo
        )
    }
}
