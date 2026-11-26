import Foundation
import MergeCueCore
@testable import MergeCueEngine
import MergeCueStore
import Testing

/// The owner approves a PR/MR from the app (D59): only with writes on and a usable capability, always audited, and
/// only for the head MergeCue showed.
@Suite("Approve from the app")
struct DirectApprovalTests {
    @Test func refusedWhileWritesAreOff() async throws {
        let h = try await Harness.make()
        defer { Task { await h.engine.stop() } }
        #expect(await h.engine.canApproveInApp(Fixture.cr()) == false)
        await #expect(throws: EngineError.self) { try await h.engine.approveChangeRequest(Fixture.cr()) }
        #expect(h.world.writes.isEmpty, "nothing reaches the provider")
        let audit = try await h.db.auditEntries(limit: 20)
        #expect(audit.contains { $0.action == "approve" && $0.outcome == .rejected })
    }

    @Test func approvesTheHeadMergeCueShowedWhenWritesAreOn() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        defer { Task { await h.engine.stop() } }
        #expect(await h.engine.canApproveInApp(Fixture.cr()))
        try await h.engine.approveChangeRequest(Fixture.cr())
        #expect(h.world.writes == [FakeWorld.Write(kind: "approve", target: Fixture.cr().id, body: Fixture.base)])
        let outcomes = try await h.db.auditEntries(limit: 20).filter { $0.action == "approve" }.map(\.outcome)
        #expect(Set(outcomes) == [.attempted, .succeeded])
    }

    @Test func aTokenWithoutTheScopeIsRefused() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        defer { Task { await h.engine.stop() } }
        h.world.state.update { $0.capabilityOverrides[.github] = [.approve: .requiresWriteAccess(scope: "repo")] }
        #expect(await h.engine.canApproveInApp(Fixture.cr()) == false)
        await #expect(throws: EngineError.self) { try await h.engine.approveChangeRequest(Fixture.cr()) }
        #expect(h.world.writes.isEmpty)
    }

    @Test func aMovedHeadIsReportedNotApproved() async throws {
        let h = try await Harness.make(.init(writesEnabled: true))
        defer { Task { await h.engine.stop() } }
        h.world.state.update { $0.writeError = .conflict("The pull request changed since you looked at it.") }
        await #expect(throws: EngineError.self) { try await h.engine.approveChangeRequest(Fixture.cr()) }
        #expect(h.world.writes.isEmpty)
        let outcomes = try await h.db.auditEntries(limit: 20).filter { $0.action == "approve" }.map(\.outcome)
        #expect(outcomes.contains(.failed))
    }
}
