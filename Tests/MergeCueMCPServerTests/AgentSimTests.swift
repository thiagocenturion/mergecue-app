import Foundation
import MergeCueCore
import MergeCueIPC
import Testing

/// Runs the BUILT `mergecue-agent-sim` (which spawns the built `mergecue-mcp`) against the fake app for every
/// scenario and checks both its JSON report and the calls the app actually received.
@Suite("mergecue-agent-sim scenarios", .timeLimit(.minutes(2)))
struct AgentSimTests {
    struct Run {
        var output: ProcessOutput
        var report: JSONValue
    }

    func runSim(_ home: TestHome, _ arguments: [String]) async throws -> Run {
        let output = try await runProcess(
            try BuiltProducts.agentSim(),
            ["--mcp", try BuiltProducts.mcp(), "--timeout", "60"] + arguments,
            environment: home.environment()
        )
        let report = try JSONDecoder().decode(JSONValue.self, from: Data(output.stdout.utf8))
        return Run(output: output, report: report)
    }

    func failedSteps(_ report: JSONValue) -> String {
        (report["steps"]?.arrayValue ?? []).filter { $0["ok"] != true }.map { $0.jsonString() }.joined(separator: "\n")
    }

    @Test func happyPath() async throws {
        try await withFakeApp { home, engine in
            let run = try await runSim(home, ["--scenario", "happy", "--agent-name", "Sim Agent"])
            #expect(run.output.status == 0, "\(failedSteps(run.report))\n\(run.output.stderr)")
            #expect(run.report["passed"] == true)
            #expect(run.report["task_id"] == "mc_happy1")
            #expect(run.report["server"]?["name"] == "mergecue")
            #expect(run.report["server"]?["protocol_version"] == "2025-11-25")
            let methods = await engine.calls.map(\.method)
            #expect(methods == [.listTasks, .getTask, .claimTask, .updateTask, .reportChanges, .reportTests, .submitResult])
            let edited = try String(contentsOfFile: home.worktrees + "/mc_happy1/mergecue-agent-sim.txt", encoding: .utf8)
            #expect(edited.contains("Edited by Sim Agent"))
            let submit = try #require(await engine.calls(.submitResult).first)
            #expect(submit.params["proposed_reply"]?.stringValue?.isEmpty == false)
            #expect(submit.params["artifact_ids"] == ["art_0000000001", "art_0000000002"])
            #expect((try? submit.result.get())?["state"] == "ready_for_review")
            let tests = try #require(await engine.calls(.reportTests).first)
            #expect(tests.params["exit_code"] == 0)
            #expect(tests.params["status"] == "passed")
        }
    }

    @Test func crashAfterClaimLeavesTheTaskWorkingWithoutFurtherCalls() async throws {
        try await withFakeApp { home, engine in
            let run = try await runSim(home, ["--scenario", "crash-after-claim", "--task", "mc_happy1"])
            #expect(run.output.status == 0, "\(failedSteps(run.report))")
            #expect(await engine.calls.map(\.method) == [.getTask, .claimTask])
            #expect(await engine.state.task(TaskID(rawValue: "mc_happy1")!)?.state == .working)
        }
    }

    @Test func doubleClaimYieldsOneLeaseAndOneVersionConflict() async throws {
        try await withFakeApp { home, engine in
            let run = try await runSim(home, ["--scenario", "double-claim", "--task", "mc_happy1"])
            #expect(run.output.status == 0, "\(failedSteps(run.report))")
            let claims = await engine.calls(.claimTask)
            #expect(claims.count == 2)
            #expect(claims.filter { (try? $0.result.get()) != nil }.count == 1)
            #expect(claims.compactMap(\.errorCode) == [.versionConflict])
            #expect(await engine.state.task(TaskID(rawValue: "mc_happy1")!)?.state == .failed)
        }
    }

    @Test func hostileCommentStaysDataAndForbiddenActionsAreRejected() async throws {
        try await withFakeApp { home, engine in
            let run = try await runSim(home, ["--scenario", "hostile", "--task", "mc_happy1"])
            #expect(run.output.status == 0, "\(failedSteps(run.report))")
            let names = (run.report["steps"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
            #expect(names.contains("hostile text is quoted untrusted content"))
            #expect(names.contains("forbidden tool merge_change_request rejected"))
            // The unknown tool never reached the app; the forged write was refused there.
            #expect(await engine.calls.map(\.method) == [.getTask, .submitResult])
            let forged = try #require(await engine.calls(.submitResult).first)
            if case .failure(let error) = forged.result { #expect(error.code == .leaseInvalid) } else { Issue.record("forged write succeeded") }
            #expect(await engine.state.task(TaskID(rawValue: "mc_happy1")!)?.state == .waitingForAgent)
        }
    }

    @Test func invalidCallsAreRejectedWithTheirCodes() async throws {
        try await withFakeApp { home, engine in
            let run = try await runSim(home, ["--scenario", "invalid", "--task", "mc_happy1"])
            #expect(run.output.status == 0, "\(failedSteps(run.report))")
            #expect(run.report["skipped"] == [])
            let codes = await engine.calls.compactMap { call -> String? in
                if case .failure(let error) = call.result { return "\(call.method.rawValue):\(error.code.rawValue)" }
                return nil
            }
            #expect(codes == [
                "heartbeat:lease_invalid",
                "update_task:version_conflict",
                "report_changes:path_outside_checkout",
                "report_changes:path_outside_checkout",
                "report_tests:validation_failed",
                "claim_task:terminal_state",
            ])
            #expect(await engine.state.task(TaskID(rawValue: "mc_done01")!)?.state == .done)
        }
    }

    @Test func failingScenarioExitsNonZero() async throws {
        try await withoutApp { home in
            let run = try await runSim(home, ["--scenario", "happy", "--task", "mc_happy1"])
            #expect(run.output.status == 1)
            #expect(run.report["passed"] == false)
            #expect(run.output.stdout.contains("app_unavailable"))
        }
    }

    @Test func usageErrors() async throws {
        let output = try await runProcess(try BuiltProducts.agentSim(), ["--scenario", "nope"], environment: [:])
        #expect(output.status == 64)
        #expect(output.stdout.isEmpty)
    }
}
