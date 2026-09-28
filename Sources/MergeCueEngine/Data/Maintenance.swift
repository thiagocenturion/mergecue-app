import Foundation
import MergeCueCore
import MergeCueStore

/// Result of one housekeeping run (persisted as `engine.last_maintenance`).
public struct MaintenanceReport: Codable, Sendable, Hashable {
    public var at: Date
    /// Rows removed by retention (`MergeCueDatabase.pruneHistory`).
    public var removedRows: Int
    /// History older than this was pruned.
    public var cutoff: Date
    /// Database + WAL size after the run (0 in memory).
    public var databaseBytes: Int

    public init(at: Date, removedRows: Int, cutoff: Date, databaseBytes: Int) {
        self.at = at
        self.removedRows = removedRows
        self.cutoff = cutoff
        self.databaseBytes = databaseBytes
    }
}

/// An isolated task worktree that may be removed: its task is finished (`done`, `cancelled`, `dismissed`) and has
/// not changed for at least `EngineEnvironment.worktreeCleanupAge`. MergeCue only **lists** these; removing one
/// always needs the owner's click (Settings ▸ Data ▸ Clean up).
public struct WorktreeCleanupCandidate: Sendable, Hashable, Identifiable {
    public var taskID: TaskID
    public var id: TaskID { taskID }
    public var title: String
    public var repoFullPath: String
    public var state: TaskState
    public var finishedAt: Date
    public var worktreePath: String

    public init(taskID: TaskID, title: String, repoFullPath: String, state: TaskState, finishedAt: Date, worktreePath: String) {
        self.taskID = taskID
        self.title = title
        self.repoFullPath = repoFullPath
        self.state = state
        self.finishedAt = finishedAt
        self.worktreePath = worktreePath
    }
}

/// What a confirmed cleanup did.
public struct WorktreeCleanupResult: Sendable, Hashable {
    public var removed: [TaskID]
    /// Task id → reason (not a candidate any more, or git refused).
    public var skipped: [TaskID: String]

    public init(removed: [TaskID] = [], skipped: [TaskID: String] = [:]) {
        self.removed = removed
        self.skipped = skipped
    }
}

extension MergeCueEngine {
    // MARK: Scheduled retention

    /// Runs housekeeping when `maintenanceInterval` has passed since the last run (checked by the stale-lease
    /// monitor, so it needs no timer of its own; a relaunch picks up where the last run left off). Returns the
    /// report when it ran.
    @discardableResult
    public func runMaintenanceIfDue() async -> MaintenanceReport? {
        guard let interval = env.maintenanceInterval, interval > 0 else { return nil }
        if let last = await lastMaintenance(), now.timeIntervalSince(last.at) < interval, last.at <= now { return nil }
        return try? await runMaintenance()
    }

    /// Prunes history older than `historyRetention` (events, activities and audit of finished tasks, stale rule
    /// firings, resolved items of untracked change requests — never anything of an active task), then truncates the
    /// WAL. Worktrees are **not** removed here (see `worktreeCleanupCandidates()`).
    @discardableResult
    public func runMaintenance() async throws(EngineError) -> MaintenanceReport {
        try await uiCall {
            let cutoff = now.addingTimeInterval(-max(0, env.historyRetention))
            let removed = try await database.pruneHistory(olderThan: cutoff)
            try? await database.checkpointAndOptimize()
            let report = MaintenanceReport(at: now, removedRows: removed, cutoff: cutoff, databaseBytes: await database.fileSizes())
            try await database.setSetting(SettingsKey.lastMaintenance, report)
            if removed > 0 {
                await appendAudit(actor: "system", action: "prune_history", target: "\(removed) rows", outcome: .succeeded)
                emit(.attention)
                emit(.tasks(nil))
            }
            log.info("maintenance: pruned \(removed) rows older than \(cutoff)")
            return report
        }
    }

    /// The last housekeeping run, if any.
    public func lastMaintenance() async -> MaintenanceReport? {
        try? await database.setting(SettingsKey.lastMaintenance, as: MaintenanceReport.self)
    }

    // MARK: Worktrees of finished tasks

    /// Finished tasks whose isolated worktree still exists and that have not changed for `worktreeCleanupAge`,
    /// oldest first.
    public func worktreeCleanupCandidates() async throws(EngineError) -> [WorktreeCleanupCandidate] {
        try await uiCall {
            let cutoff = now.addingTimeInterval(-max(0, env.worktreeCleanupAge))
            let finished = try await database.tasks(states: Set(TaskState.allCases.filter(\.isTerminal)))
            return finished.compactMap { task -> WorktreeCleanupCandidate? in
                guard task.isTerminal, task.updatedAt <= cutoff, let path = task.checkout?.worktreePath,
                      task.checkout?.mappedCheckoutPath != nil else { return nil }
                return WorktreeCleanupCandidate(
                    taskID: task.id, title: task.origin.title, repoFullPath: task.origin.changeRequestRef.repoFullPath,
                    state: task.state, finishedAt: task.updatedAt, worktreePath: path
                )
            }
            .sorted { ($0.finishedAt, $0.taskID.rawValue) < ($1.finishedAt, $1.taskID.rawValue) }
        }
    }

    /// Removes the worktrees of `ids` after the owner confirmed it. Each id must still be a cleanup candidate
    /// (finished, old enough, worktree present); anything else is skipped. The mapped checkout is never touched.
    public func cleanUpWorktrees(_ ids: [TaskID]) async throws(EngineError) -> WorktreeCleanupResult {
        let candidates = Set(try await worktreeCleanupCandidates().map(\.taskID))
        var result = WorktreeCleanupResult()
        for id in ids {
            guard candidates.contains(id) else {
                result.skipped[id] = "Not a finished task with an old worktree."
                continue
            }
            do {
                try await cleanupWorktree(id)
                result.removed.append(id)
            } catch {
                result.skipped[id] = error.localizedDescription
            }
        }
        if !result.removed.isEmpty {
            await appendAudit(actor: "user", action: "cleanup_worktrees", target: "\(result.removed.count) worktrees", outcome: .succeeded)
            emit(.tasks(nil))
        }
        return result
    }
}
