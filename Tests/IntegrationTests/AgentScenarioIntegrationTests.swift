import AgentHandoff
import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueFixtures
import MergeCueIPC
import MergeCueRuntime
import Testing

/// PLAN §11 agent rows against the real engine, through `mergecue-agent-sim` → `mergecue-mcp` → IPC.
@Suite("Agent scenarios against the real engine")
struct AgentScenarioIntegrationTests {
    @Test func crashAfterClaimTurnsStaleAfterTheLease() async throws {
        let h = try await DemoHarness.start(ipc: true, leaseDuration: 600)
        defer { h.home.remove() }
        let task = try await FullLoopIntegrationTests.blockingCommentTask(h)
        let (report, output) = try await h.runAgentSim(scenario: "crash-after-claim", taskID: task.id)
        #expect(report["passed"]?.boolValue == true, "\(report.failedSimSteps) \(output.stderr.suffix(1500))")

        var current = try await h.engine.taskDetail(task.id).task
        #expect(current.state == .working)
        #expect(try await h.engine.handoff(for: task.id).statusText.contains("is working"))
        // Before the lease expires nothing changes.
        h.clock.advance(by: 300)
        #expect(await h.engine.sweepExpiredLeases().isEmpty)
        #expect(try await h.engine.taskDetail(task.id).task.state == .working)
        // After it: stale (never done), with an explanation, and it can be retried.
        h.clock.advance(by: 301)
        // (The engine's own monitor may win the race; either way the task is stale exactly once.)
        _ = await h.engine.sweepExpiredLeases()
        let detail = try await h.engine.taskDetail(task.id)
        current = detail.task
        #expect(current.state == .stale)
        #expect(detail.activities.filter { $0.kind == .stale && $0.message.contains("No heartbeat") }.count == 1)
        #expect(try await h.engine.retryTask(task.id).state == .waitingForAgent)
        #expect(h.scenario.providerWrites(.github).isEmpty)
        await h.runtime.stop()
    }

    @Test func doubleClaimYieldsOneLease() async throws {
        let h = try await DemoHarness.start(ipc: true)
        defer { h.home.remove() }
        let task = try await FullLoopIntegrationTests.blockingCommentTask(h)
        let (report, output) = try await h.runAgentSim(scenario: "double-claim", taskID: task.id)
        #expect(report["passed"]?.boolValue == true, "\(report.failedSimSteps) \(output.stderr.suffix(1500))")
        let detail = try await h.engine.taskDetail(task.id)
        #expect(detail.activities.filter { $0.kind == .claimed }.count == 1)
        #expect(detail.activities.contains { $0.kind == .rejectedCall })
        await h.runtime.stop()
    }

    @Test func hostileCommentStaysQuotedData() async throws {
        let h = try await DemoHarness.start(ipc: true)
        defer { h.home.remove() }
        let item = try #require(try await h.threadItem(.github, threadRemoteID: GitHubFixtures.IDs.hostileThread))
        let task = try await h.engine.createTask(fromAttention: item.id)
        let (report, output) = try await h.runAgentSim(scenario: "hostile", taskID: task.id)
        #expect(report["passed"]?.boolValue == true, "\(report.failedSimSteps) \(output.stderr.suffix(1500))")
        for kind in ProviderKind.allCases {
            #expect(h.scenario.providerWrites(kind).isEmpty)
        }
        #expect(try await h.engine.taskDetail(task.id).task.state == .waitingForAgent)
        await h.runtime.stop()
    }

    @Test func invalidCallsAreRejectedWithCodes() async throws {
        let h = try await DemoHarness.start(ipc: true)
        defer { h.home.remove() }
        // A terminal task for the resurrection check.
        let other = try #require(try await h.threadItem(.gitlab, threadRemoteID: GitLabFixtures.IDs.questionDiscussion))
        let terminal = try await h.engine.createTask(fromAttention: other.id)
        _ = try await h.engine.cancelTask(terminal.id)
        let task = try await FullLoopIntegrationTests.blockingCommentTask(h)
        let (report, output) = try await h.runAgentSim(scenario: "invalid", taskID: task.id)
        #expect(report["passed"]?.boolValue == true, "\(report.failedSimSteps) \(output.stderr.suffix(1500))")
        #expect((report["skipped"]?.arrayValue ?? []).isEmpty, "\(report["skipped"]?.jsonString() ?? "")")
        let detail = try await h.engine.taskDetail(task.id)
        #expect(detail.activities.filter { $0.kind == .rejectedCall }.count >= 4)
        #expect(h.scenario.providerWrites(.github).isEmpty)
        await h.runtime.stop()
    }

    @Test func helperReportsAppUnavailableWhenTheAppIsNotRunning() async throws {
        let mcp = try #require(BuiltProducts.mcp, "mergecue-mcp is not built")
        let home = try TestHome.make()
        defer { home.remove() }

        // Nothing running at all.
        let verifier = MCPServerVerifier(timeout: 20)
        let before = try await verifier.verify(helper: mcp, environment: home.environment, probe: .listAttention)
        #expect(before.looksLikeMergeCue)
        #expect(before.readOnlyRoundTrip?.isAppUnavailable == true, "\(String(describing: before.readOnlyRoundTrip))")
        let (sim, _) = try await DemoHarness.simReport(home: home, scenario: "happy")
        #expect(sim["passed"]?.boolValue == false)
        #expect((sim["steps"]?.arrayValue ?? []).contains { $0["code"]?.stringValue == "app_unavailable" }, "\(sim.jsonString())")

        // Running: the same helper reaches the demo runtime (is_demo) through the socket.
        let h = try await DemoHarness.start(home: home, ipc: true)
        let running = try await h.runtime.verifyMCPHelper()
        #expect(running.readOnlyRoundTrip?.isOK == true, "\(String(describing: running.readOnlyRoundTrip))")
        let socket = h.runtime.paths.socketPath
        #expect(FileManager.default.fileExists(atPath: socket))

        // Stopped: socket removed, the helper answers app_unavailable again (no fabricated state).
        await h.runtime.stop()
        #expect(!FileManager.default.fileExists(atPath: socket))
        let after = try await verifier.verify(helper: mcp, environment: home.environment, probe: .listAttention)
        #expect(after.readOnlyRoundTrip?.isAppUnavailable == true, "\(String(describing: after.readOnlyRoundTrip))")
    }
}

extension DemoHarness {
    /// Runs the simulator against `home` without a runtime.
    static func simReport(home: TestHome, scenario: String) async throws -> (JSONValue, ProcessOutput) {
        let sim = try #require(BuiltProducts.agentSim)
        let mcp = try #require(BuiltProducts.mcp)
        let output = try await runProcess(
            sim, ["--mcp", MergeCuePaths.fileSystemPath(mcp), "--scenario", scenario, "--timeout", "30"],
            environment: home.environment, timeout: 45
        )
        return (try JSONValue.defaultDecoder().decode(JSONValue.self, from: Data(output.stdout.utf8)), output)
    }
}
