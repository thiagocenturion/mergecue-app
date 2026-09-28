import Darwin
import Foundation
import MCP
import MergeCueCore
import MergeCueIPC
import Testing
@testable import MergeCueMCPServer

/// Protocol-level tests: the BUILT `mergecue-mcp` binary, spawned with `MERGECUE_HOME`, talking to an in-process
/// `IPCServer` backed by `FakeEngine`, driven by the SDK `Client` over stdio pipes.
@Suite("mergecue-mcp over stdio", .timeLimit(.minutes(2)))
struct StdioProtocolTests {
    @Test func initializeNegotiatesAndReportsServerInfo() async throws {
        try await withFakeApp { home, _ in
            let mcp = try await SpawnedMCP.start(home: home, extraEnvironment: ["MERGECUE_VERSION": "4.5.6"])
            #expect(mcp.initialize.serverInfo.name == "mergecue")
            #expect(mcp.initialize.serverInfo.version == "4.5.6")
            #expect(mcp.initialize.serverInfo.title == "MergeCue")
            #expect(mcp.initialize.protocolVersion == Version.latest)
            #expect(mcp.initialize.protocolVersion == "2025-11-25")
            #expect(mcp.initialize.capabilities.tools != nil)
            #expect(mcp.initialize.capabilities.resources != nil)
            #expect(mcp.initialize.capabilities.prompts != nil)
            #expect(mcp.initialize.instructions?.contains("untrusted data") == true)
            let (status, stderr) = try await mcp.close()
            #expect(status == 0)
            #expect(stderr.contains("stopped (eof)"))
        }
    }

    @Test func toolsListExposesEveryToolWithRequiredFields() async throws {
        try await withFakeApp { home, _ in
            let mcp = try await SpawnedMCP.start(home: home)
            let tools = try await mcp.client.listTools().tools
            #expect(tools.map(\.name) == MergeCueToolCatalog.all.map(\.name))
            for tool in tools {
                let required = tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
                #expect(required == ToolCatalogTests.expectedRequired[tool.name], "\(tool.name)")
                #expect(tool.annotations.destructiveHint == false)
                #expect(tool.description?.contains("Never publish") == true)
            }
            try await mcp.close()
        }
    }

    /// Calls every tool once in a realistic order; each call's arguments reach the app exactly and each result is
    /// the app's JSON, as text and as structuredContent.
    @Test func everyToolForwardsExactlyAndReturnsStructuredResults() async throws {
        try await withFakeApp { home, engine in
            let mcp = try await SpawnedMCP.start(home: home)
            let worktree = home.worktrees + "/mc_happy1"
            let base = FakeEngine.baseSHA
            let steps: [(String, [String: Value])] = [
                ("list_attention", ["provider": "github", "limit": 5, "include_read": true]),
                ("list_tasks", ["states": ["waiting_for_agent", "done"], "limit": 10]),
                ("get_task", ["task_id": "mc_happy1"]),
                ("get_change_context", ["change_ref": "github:github.com/acme/payments-api#42", "include_files": false, "max_files": 10]),
                ("get_thread", ["thread_id": .string(FakeEngine.threadID)]),
                ("get_ci_failure", ["check_id": .string(FakeEngine.checkID), "max_bytes": 1024]),
                ("get_diff", ["task_id": "mc_happy1", "max_bytes": 2048]),
                ("claim_task", ["task_id": "mc_happy1", "agent_name": "Claude Code", "run_id": "run-1", "expected_version": 3]),
                ("heartbeat", ["task_id": "mc_happy1", "lease_id": "lease_1"]),
                ("update_task", ["task_id": "mc_happy1", "lease_id": "lease_1", "expected_version": 4, "phase": "editing", "message": "Editing Money.swift"]),
                ("report_changes", ["task_id": "mc_happy1", "lease_id": "lease_1", "expected_version": 5, "worktree_path": .string(worktree), "base_sha": .string(base), "changed_paths": ["Sources/Money.swift"], "note": "rounding"]),
                ("report_tests", ["task_id": "mc_happy1", "lease_id": "lease_1", "expected_version": 6, "command": "swift test", "exit_code": 0, "status": "passed", "passed": 12, "failed": 0, "skipped": 1, "duration_ms": 900, "output": "ok"]),
                ("submit_result", ["task_id": "mc_happy1", "lease_id": "lease_1", "expected_version": 7, "summary": "Fixed rounding.", "proposed_reply": "Done, thanks!", "artifact_ids": ["art_0000000001", "art_0000000002"], "known_risks": ["none"]]),
                ("claim_task", ["task_id": "mc_other1", "agent_name": "Codex", "expected_version": 1]),
                ("fail_task", ["task_id": "mc_other1", "lease_id": "lease_2", "expected_version": 2, "reason": "Needs access", "retryable": false, "blocked": true]),
                ("propose_rule", ["name": "CI", "providers": ["github"], "event_types": ["ci_failed"], "repo_include": ["acme/*"], "action": "create_task", "task_type": "investigate_ci", "quiet_hours": ["start": "22:00", "end": "07:00", "time_zone": "Europe/Lisbon"], "max_fires_per_hour": 3]),
                ("list_rules", [:]),
            ]
            for (index, (tool, arguments)) in steps.enumerated() {
                let result = try await mcp.call(tool, arguments)
                let recorded = await engine.calls
                let call = try #require(recorded.last, "\(tool) never reached the app")
                #expect(recorded.count == index + 1, "\(tool)")
                #expect(call.method.rawValue == tool)
                #expect(call.params == (try jsonArguments(arguments)), "\(tool) params were not forwarded exactly")
                let appResult = try call.result.get()
                #expect(result.isError == false, "\(tool): \(result.text)")
                #expect(try result.structured == appResult, "\(tool)")
                #expect(try result.textJSON == appResult, "\(tool)")
            }
            let covered = Set(steps.map(\.0))
            #expect(covered == Set(MergeCueToolCatalog.all.map(\.name)))
            #expect(await engine.calls(.submitResult).first.map { (try? $0.result.get())?["state"] } == .some("ready_for_review"))
            try await mcp.close()
        }
    }

    @Test func appErrorsMapToIsErrorResultsWithCodes() async throws {
        try await withFakeApp { home, engine in
            let mcp = try await SpawnedMCP.start(home: home)
            let conflict = try await mcp.call("claim_task", ["task_id": "mc_happy1", "agent_name": "a", "expected_version": 1])
            #expect(conflict.isError == true)
            let structured = try #require(try conflict.structured)
            #expect(structured["code"] == "version_conflict")
            #expect(structured["retryable"] == true)
            #expect(structured["data"]?["current_version"] == 3)
            #expect(structured["message"]?.stringValue?.isEmpty == false)
            #expect(try conflict.textJSON == structured)

            let cases: [(String, [String: Value], String)] = [
                ("get_task", ["task_id": "mc_zzzzzz"], "not_found"),
                ("claim_task", ["task_id": "mc_done01", "agent_name": "a", "expected_version": 9], "terminal_state"),
                ("heartbeat", ["task_id": "mc_happy1", "lease_id": "forged"], "lease_invalid"),
                ("get_task", ["task_id": "oops"], "invalid_params"),
            ]
            for (tool, arguments, code) in cases {
                let result = try await mcp.call(tool, arguments)
                #expect(result.isError == true)
                #expect(try result.structured?["code"] == .string(code), "\(tool) → \(result.text)")
            }
            // The malformed id was rejected locally and never reached the app.
            #expect(await engine.calls.count == 4)
            try await mcp.close()
        }
    }

    @Test func everyToolReportsAppUnavailableWhenTheAppIsNotRunning() async throws {
        try await withoutApp { home in
            let mcp = try await SpawnedMCP.start(home: home)
            let minimal: [String: [String: Value]] = [
                "list_attention": [:], "list_tasks": [:], "get_task": ["task_id": "mc_abc123"],
                "get_change_context": ["change_ref": "github:github.com/acme/api#1"], "get_thread": ["thread_id": "thr_0123456789"],
                "get_ci_failure": ["check_id": "chk_0123456789"], "get_diff": ["task_id": "mc_abc123"],
                "claim_task": ["task_id": "mc_abc123", "agent_name": "a", "expected_version": 1],
                "heartbeat": ["task_id": "mc_abc123", "lease_id": "l"],
                "update_task": ["task_id": "mc_abc123", "lease_id": "l", "expected_version": 1, "phase": "planning", "message": "m"],
                "report_changes": ["task_id": "mc_abc123", "lease_id": "l", "expected_version": 1, "worktree_path": "/w", "base_sha": "a", "changed_paths": []],
                "report_tests": ["task_id": "mc_abc123", "lease_id": "l", "expected_version": 1, "command": "t", "exit_code": 0, "status": "passed", "output": ""],
                "submit_result": ["task_id": "mc_abc123", "lease_id": "l", "expected_version": 1, "summary": "s", "artifact_ids": []],
                "fail_task": ["task_id": "mc_abc123", "lease_id": "l", "expected_version": 1, "reason": "r", "retryable": true],
                "propose_rule": ["name": "n", "event_types": ["ci_failed"], "action": "notify"],
                "list_rules": [:],
            ]
            #expect(Set(minimal.keys) == Set(MergeCueToolCatalog.all.map(\.name)))
            for (tool, arguments) in minimal {
                let result = try await mcp.call(tool, arguments)
                #expect(result.isError == true, "\(tool)")
                let structured = try result.structured
                #expect(structured?["code"] == "app_unavailable", "\(tool): \(result.text)")
                #expect(structured?["retryable"] == true)
                #expect(structured?["message"] == .string(IPCError.appUnavailableMessage))
            }
            await #expect(throws: MCPError.self) { try await mcp.client.listResources() }
            try await mcp.close()
        }
    }

    @Test func resourcesAndPromptOverStdio() async throws {
        try await withFakeApp { home, _ in
            let mcp = try await SpawnedMCP.start(home: home)
            let resources = try await mcp.client.listResources().resources
            #expect(Set(resources.map(\.uri)) == ["mergecue://tasks/mc_happy1", "mergecue://tasks/mc_other1"])
            let task = try await mcp.client.readResource(uri: "mergecue://tasks/mc_happy1")
            let json = try JSONDecoder().decode(JSONValue.self, from: Data((task.first?.text ?? "").utf8))
            #expect(json["trigger"]?["untrusted_content"]?[0]?["text"] == .string(FakeEngine.hostileText))
            #expect(json["trigger"]?["untrusted_content"]?[0]?["source"] == "review_comment")
            let log = try await mcp.client.readResource(uri: "mergecue://checks/\(FakeEngine.checkID)/log")
            #expect(log.first?.text?.contains("ci_log") == true)
            let prompt = try await mcp.client.getPrompt(name: "work_on_task", arguments: ["task_id": "mc_happy1"])
            #expect(prompt.messages.count == 1)
            try await mcp.close()
        }
    }

    /// Raw pipes: every stdout line is a JSON-RPC 2.0 message answering a request we sent; logs go to stderr.
    @Test func stdoutCarriesOnlyJSONRPCFrames() async throws {
        try await withFakeApp { home, _ in
            let requests: [String] = [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"raw","version":"1"}}}"#,
                #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_task","arguments":{"task_id":"mc_happy1"}}}"#,
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_task","arguments":{"task_id":"bad"}}}"#,
                #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}"#,
                #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#,
                #"{"jsonrpc":"2.0","id":7,"method":"prompts/get","params":{"name":"work_on_task","arguments":{"task_id":"mc_happy1"}}}"#,
                #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#,
            ]
            let input = Data((requests.joined(separator: "\n") + "\n").utf8)
            let output = try await runProcess(try BuiltProducts.mcp(), [], environment: home.environment(), input: input)
            #expect(output.status == 0)
            let lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: true)
            var responses: [Int: JSONValue] = [:]
            for line in lines {
                let message = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                #expect(message["jsonrpc"] == "2.0", "not JSON-RPC: \(line.prefix(200))")
                #expect(message["result"] != nil || message["error"] != nil)
                if let id = message["id"]?.intValue { responses[id] = message }
            }
            // Requests are served concurrently, so responses may arrive in any order.
            #expect(Set(responses.keys) == Set(1...8), "stdout: \(output.stdout.prefix(500))")
            #expect(lines.count == 8)
            #expect(output.stderr.contains("serving MCP on stdio"))
            #expect(responses[1]?["result"]?["protocolVersion"] == "2025-06-18")
            #expect(responses[3]?["result"]?["isError"] == false)
            #expect(responses[4]?["result"]?["isError"] == true)
            #expect(responses[5]?["error"]?["code"] == -32602)
        }
    }

    @Test func sigtermStopsTheServerCleanly() async throws {
        try await withoutApp { home in
            let mcp = try await SpawnedMCP.start(home: home)
            kill(mcp.process.processIdentifier, SIGTERM)
            let deadline = Date().addingTimeInterval(10)
            while mcp.process.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!mcp.process.isRunning)
            #expect(mcp.process.terminationStatus == 0)
            #expect(mcp.process.terminationReason == .exit)
        }
    }
}

@Suite("mergecue-mcp command line", .timeLimit(.minutes(1)))
struct CommandLineTests {
    @Test func versionFlag() async throws {
        let output = try await runProcess(try BuiltProducts.mcp(), ["--version"], environment: ["MERGECUE_VERSION": "3.2.1"])
        #expect(output.status == 0)
        #expect(output.stdout.hasPrefix("mergecue-mcp 3.2.1 "))
        #expect(output.stdout.contains("MCP protocol 2025-11-25"))
    }

    @Test func selfTestSucceedsAgainstARunningApp() async throws {
        try await withFakeApp { home, engine in
            let output = try await runProcess(try BuiltProducts.mcp(), ["--self-test"], environment: home.environment())
            #expect(output.status == 0, "\(output.stderr)")
            #expect(output.stdout.isEmpty)
            #expect(output.stderr.contains("self-test: OK"))
            #expect(output.stderr.contains("MergeCue 9.9.9-test"))
            #expect(await engine.calls.map(\.method) == [.ping])
        }
    }

    @Test func selfTestFailsWithoutTheApp() async throws {
        try await withoutApp { home in
            let output = try await runProcess(try BuiltProducts.mcp(), ["--self-test"], environment: home.environment())
            #expect(output.status == 1)
            #expect(output.stdout.isEmpty)
            #expect(output.stderr.contains("self-test: FAILED"))
            #expect(output.stderr.contains("app_unavailable"))
        }
    }

    @Test func printConfigUsesThisBinarysAbsolutePath() async throws {
        let binary = try BuiltProducts.mcp()
        let resolved = URL(filePath: binary).resolvingSymlinksInPath().path(percentEncoded: false)
        for agent in ["claude", "codex"] {
            let output = try await runProcess(binary, ["--print-config", agent], environment: [:])
            #expect(output.status == 0)
            #expect(output.stdout.contains(resolved), "\(output.stdout)")
            #expect(output.stdout.contains(agent == "claude" ? "claude mcp add --transport stdio --scope user mergecue --" : "codex mcp add mergecue --"))
        }
        let bad = try await runProcess(binary, ["--print-config", "cursor"], environment: [:])
        #expect(bad.status == 64)
        #expect(bad.stdout.isEmpty)
        let unknown = try await runProcess(binary, ["--frobnicate"], environment: [:])
        #expect(unknown.status == 64)
        #expect(unknown.stdout.isEmpty)
    }
}
