import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore
import Testing
@testable import MergeCueEngine

/// S3 (agent read scope) and S12 (read audit, provider-read rate limit and cache).
@Suite("Agent read access")
struct ReadScopeTests {
    @Test("Default tasks_only: list_attention is empty with a note until a task exists")
    func defaultIsTasksOnly() async throws {
        let h = try await Harness.make()
        #expect(await h.engine.agentReadAccess() == .tasksOnly)
        #expect(try await h.engine.snapshot().agentReadAccess == .tasksOnly)
        let none = try await h.ok(ListAttentionParams())
        #expect(none.items.isEmpty)
        #expect(none.total == 0)
        #expect(none.note?.contains("Settings ▸ Agents") == true)

        try await h.seed(Fixture.gitlab)
        _ = try await h.engine.createTask(fromAttention: h.threadItemID)
        let scoped = try await h.ok(ListAttentionParams(includeRead: true))
        #expect(!scoped.items.isEmpty)
        #expect(scoped.items.allSatisfy { $0.provider == .github && $0.number == 42 })
    }

    @Test("Reads outside open tasks are cross_scope_reference; inside they work")
    func readsAreConfinedToOpenTasks() async throws {
        let h = try await Harness.make()
        let gitlabItems = try await h.seed(Fixture.gitlab)
        let githubRef = try #require(ChangeRequestRef(string: "github:github.com/acme/payments-api#42"))
        let gitlabRef = try #require(ChangeRequestRef(string: "gitlab:gitlab.com/acme/payments-api!42"))

        // No task yet: nothing is readable, whether or not it exists.
        #expect(await h.errorCode(GetChangeContextParams(changeRef: githubRef)) == .crossScopeReference)
        #expect(await h.errorCode(GetThreadParams(threadID: Fixture.thread().shortID)) == .crossScopeReference)
        #expect(await h.errorCode(GetCIFailureParams(checkID: Fixture.check().shortID)) == .crossScopeReference)
        #expect(await h.errorCode(GetDiffParams(changeRef: githubRef)) == .crossScopeReference)
        let unknown = try #require(ChangeRequestRef(string: "github:github.com/acme/other#7"))
        #expect(await h.errorCode(GetChangeContextParams(changeRef: unknown)) == .crossScopeReference)

        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        #expect(try await h.ok(GetChangeContextParams(changeRef: githubRef)).number == 42)
        #expect(try await h.ok(GetThreadParams(threadID: Fixture.thread().shortID)).threadID == Fixture.thread().shortID)
        #expect(try await h.ok(GetCIFailureParams(checkID: Fixture.check().shortID)).name == "build")
        #expect(try await h.ok(GetDiffParams(changeRef: githubRef)).source == .provider)

        // Other accounts' change requests stay out of reach.
        guard case .failure(let error) = await h.call(GetChangeContextParams(changeRef: gitlabRef)) else {
            Issue.record("gitlab ref was readable")
            return
        }
        #expect(error.code == .crossScopeReference)
        #expect(error.message.contains("Settings ▸ Agents"))
        #expect(await h.errorCode(GetThreadParams(threadID: Fixture.thread(Fixture.cr(Fixture.gitlab)).shortID)) == .crossScopeReference)
        #expect(gitlabItems.thread.changeRequest.kind == .gitlab)

        // A finished task no longer opens anything (and its worktree diff is closed too).
        _ = try await h.engine.dismissTask(task.id)
        #expect(await h.errorCode(GetChangeContextParams(changeRef: githubRef)) == .crossScopeReference)
        #expect(await h.errorCode(GetDiffParams(taskID: task.id)) == .crossScopeReference)

        // The owner can widen access; it is audited.
        try await h.engine.setAgentReadAccess(.allInbox)
        #expect(try await h.ok(GetChangeContextParams(changeRef: gitlabRef)).provider == .gitlab)
        #expect(try await h.ok(ListAttentionParams()).note == nil)
        #expect(try await h.db.auditEntries(limit: 50).contains { $0.action == "set_agent_read_access" && $0.target == "all_inbox" })
    }

    @Test("Reads are audited per client in aggregated windows; the first denial is audited")
    func readAuditIsAggregated() async throws {
        let h = try await Harness.make()
        let task = try await h.engine.createTask(fromAttention: h.threadItemID)
        for _ in 0..<5 { _ = try await h.ok(GetTaskParams(taskID: task.id)) }
        _ = try await h.ok(ListTasksParams())
        var entries = try await h.db.auditEntries(limit: 200).filter { $0.action == "mcp_reads" }
        #expect(entries.count == 1)
        #expect(entries.first?.actor == "agent:test-agent#1")

        let ref = try #require(ChangeRequestRef(string: "gitlab:gitlab.com/acme/payments-api!42"))
        for _ in 0..<3 { _ = await h.call(GetChangeContextParams(changeRef: ref)) }
        let denials = try await h.db.auditEntries(limit: 200).filter { $0.action == "mcp_read_denied" }
        #expect(denials.count == 1)

        h.clock.advance(by: MergeCueEngine.readAuditWindow + 1)
        _ = try await h.ok(GetTaskParams(taskID: task.id))
        entries = try await h.db.auditEntries(limit: 200).filter { $0.action == "mcp_reads" }
        #expect(entries.count == 2)
        #expect(entries.contains { $0.detail.contains("Previous window: 9 read(s)") && $0.detail.contains("3 denied") })
    }

    @Test("Provider-hitting reads are cached briefly and rate limited per client")
    func providerReadsAreCachedAndLimited() async throws {
        let h = try await Harness.make()
        _ = try await h.engine.createTask(fromAttention: h.checkItemID)
        let before = h.world.state.get().logFetches
        let checkID = Fixture.check().shortID
        _ = try await h.ok(GetCIFailureParams(checkID: checkID, maxBytes: 2048))
        _ = try await h.ok(GetCIFailureParams(checkID: checkID, maxBytes: 2048))
        #expect(h.world.state.get().logFetches == before + 1)

        h.clock.advance(by: MergeCueEngine.providerReadCacheTTL + 1)
        _ = try await h.ok(GetCIFailureParams(checkID: checkID, maxBytes: 2048))
        #expect(h.world.state.get().logFetches == before + 2)

        // Distinct requests (different max_bytes) are not cached: the per-client limit applies.
        var limited: IPCError?
        for size in 1...(MergeCueEngine.maxProviderReadsPerMinute + 1) {
            if case .failure(let error) = await h.call(GetCIFailureParams(checkID: checkID, maxBytes: 4096 + size)) {
                limited = error
                break
            }
        }
        #expect(limited?.code == .rateLimited)
        #expect(limited?.retryable == true)
    }
}
