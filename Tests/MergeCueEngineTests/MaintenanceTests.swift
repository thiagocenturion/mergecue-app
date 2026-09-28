import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore
import Testing
@testable import MergeCueEngine

@Suite("Scheduled retention and worktree cleanup")
struct EngineMaintenanceTests {
    static let day: TimeInterval = 86_400

    @Test("runMaintenanceIfDue prunes 90-day history once a day and records a report")
    func scheduledRetention() async throws {
        let h = try await Harness.make()
        #expect(await h.engine.lastMaintenance() == nil)
        // Old history of a finished task: an audit entry 100 days back.
        try await h.db.appendAudit(AuditEntry(
            id: "aud_old", at: Fixture.start.addingTimeInterval(-100 * Self.day), actor: "user", action: "x", target: "y", outcome: .succeeded
        ))
        let first = try #require(await h.engine.runMaintenanceIfDue())
        #expect(first.removedRows == 1)
        #expect(first.cutoff == Fixture.start.addingTimeInterval(-90 * Self.day))
        #expect(await h.engine.lastMaintenance() == first)
        #expect(try await h.db.auditEntries(limit: 50).contains { $0.action == "prune_history" })

        // Not due again within a day, due after it.
        h.clock.advance(by: Self.day - 60)
        #expect(await h.engine.runMaintenanceIfDue() == nil)
        h.clock.advance(by: 120)
        #expect(await h.engine.runMaintenanceIfDue() != nil)
        #expect(try await h.engine.snapshot().lastMaintenance?.at == h.clock.now)
    }

    @Test("the stale-lease monitor runs due maintenance without its own timer")
    func monitorRunsMaintenance() async throws {
        let h = try await Harness.make()
        await h.engine.start()
        await h.clock.waitForSleepers(count: 1)
        h.clock.advance(by: 31)
        for _ in 0..<400 where await h.engine.lastMaintenance() == nil { try? await Task.sleep(for: .milliseconds(5)) }
        await h.engine.stop()
        #expect(await h.engine.lastMaintenance() != nil)
    }

    @Test("maintenance can be switched off")
    func disabled() async throws {
        let h = try await Harness.make()
        let engine = MergeCueEngine(environment: EngineEnvironment(
            database: h.db, credentials: h.credentials, providers: FakeProviderFactory(world: h.world), sync: h.sync,
            workspace: h.workspace, clock: h.clock, paths: MergeCuePaths(root: h.root), maintenanceInterval: nil
        ))
        #expect(await engine.runMaintenanceIfDue() == nil)
    }

    @Test("worktrees of finished tasks are listed after 14 days and removed only on request")
    func worktreeCleanup() async throws {
        let h = try await Harness.make()
        let finished = try await h.submittedTask()
        let worktree = try #require(finished.checkout?.worktreePath)
        _ = try await h.engine.markTaskDone(finished.id)
        #expect(try await h.engine.worktreeCleanupCandidates().isEmpty, "too recent")

        h.clock.advance(by: 15 * Self.day)
        // Maintenance never removes worktrees on its own.
        _ = try await h.engine.runMaintenance()
        #expect(h.workspace.state.get().removedWorktrees.isEmpty)
        let candidates = try await h.engine.worktreeCleanupCandidates()
        #expect(candidates.map(\.taskID) == [finished.id])
        #expect(candidates.first?.worktreePath == worktree)
        #expect(try await h.engine.snapshot().worktreeCleanupCandidates.map(\.taskID) == [finished.id])

        // An active task is never a candidate, even if asked for explicitly.
        let bogus = TaskID(rawValue: "mc_zzzzzz")!
        let result = try await h.engine.cleanUpWorktrees([finished.id, bogus])
        #expect(result.removed == [finished.id])
        #expect(result.skipped[bogus] != nil)
        #expect(h.workspace.state.get().removedWorktrees == [worktree])
        #expect(try await h.task(finished.id).checkout?.worktreePath == nil)
        #expect(try await h.engine.worktreeCleanupCandidates().isEmpty)
        #expect(try await h.db.auditEntries(limit: 50).contains { $0.action == "cleanup_worktrees" })
    }

    @Test("a working task's worktree is never offered")
    func activeTaskNotOffered() async throws {
        let h = try await Harness.make()
        let (task, _) = try await h.claimedTask()
        h.clock.advance(by: 30 * Self.day)
        #expect(try await h.engine.worktreeCleanupCandidates().isEmpty)
        let result = try await h.engine.cleanUpWorktrees([task.id])
        #expect(result.removed.isEmpty)
        #expect(h.workspace.state.get().removedWorktrees.isEmpty)
    }
}
