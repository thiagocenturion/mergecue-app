import Foundation
import MCP
import MergeCueCore
import MergeCueIPC
import Testing
@testable import MergeCueMCPServer

/// Scripted `MergeCueIPCCalling` double: records calls, answers from a table.
actor ScriptedIPC: MergeCueIPCCalling {
    var calls: [(IPCMethod, JSONValue)] = []
    var responses: [IPCMethod: Result<JSONValue, IPCError>] = [:]
    var fallback: Result<JSONValue, IPCError> = .failure(.appUnavailable())

    init(_ responses: [IPCMethod: Result<JSONValue, IPCError>] = [:]) {
        self.responses = responses
    }

    func callRaw(_ method: IPCMethod, params: JSONValue) async throws(IPCError) -> JSONValue {
        calls.append((method, params))
        return try (responses[method] ?? fallback).get()
    }
}

/// The server wired to an in-memory transport and a real SDK client.
func withInMemoryServer<T>(_ ipc: ScriptedIPC, _ body: (Client) async throws -> T) async throws -> T {
    let service = MergeCueMCPService(ipc: ipc, version: "1.2.3-test")
    let server = await service.makeServer()
    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverTransport)
    let client = Client(name: "in-memory-tests", version: "1.0")
    try await client.connect(transport: clientTransport)
    do {
        let value = try await body(client)
        await client.disconnect()
        await server.stop()
        return value
    } catch {
        await client.disconnect()
        await server.stop()
        throw error
    }
}

@Suite("In-process MCP server", .timeLimit(.minutes(1)))
struct InProcessServerTests {
    @Test func toolCallForwardsArgumentsVerbatimAndReturnsStructuredJSON() async throws {
        let result: JSONValue = ["task_id": "mc_abc123", "state": "working", "version": 4, "lease_id": "lease_x", "lease_expires_at": "2026-01-01T00:00:00.123Z", "heartbeat_interval_seconds": 60]
        let ipc = ScriptedIPC([.claimTask: .success(result)])
        let arguments: [String: Value] = ["task_id": "mc_abc123", "agent_name": "Claude Code", "expected_version": 3, "run_id": "r1"]
        let call = try await withInMemoryServer(ipc) { client in
            try await client.send(CallTool.request(.init(name: "claim_task", arguments: arguments))).value
        }
        #expect(call.isError == false)
        #expect(try call.structured == result)
        #expect(try call.textJSON == result)
        let calls = await ipc.calls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == .claimTask)
        #expect(calls.first?.1 == (try jsonArguments(arguments)))
    }

    @Test func ipcErrorsBecomeIsErrorResults() async throws {
        let conflict = IPCError(.versionConflict, "Task changed.", retryable: true, data: ["current_version": 5])
        let ipc = ScriptedIPC([.heartbeat: .failure(conflict)])
        let call = try await withInMemoryServer(ipc) { client in
            try await client.send(CallTool.request(.init(name: "heartbeat", arguments: ["task_id": "mc_abc123", "lease_id": "l"]))).value
        }
        #expect(call.isError == true)
        let expected: JSONValue = ["code": "version_conflict", "message": "Task changed.", "retryable": true, "data": ["current_version": 5]]
        #expect(try call.structured == expected)
        #expect(try call.textJSON == expected)
    }

    @Test func invalidArgumentsAreRejectedLocallyWithoutReachingTheApp() async throws {
        let ipc = ScriptedIPC()
        let cases: [(String, [String: Value], String)] = [
            ("get_task", [:], "Missing required parameter 'task_id'"),
            ("get_task", ["task_id": "MC-1"], "task_id"),
            ("get_task", ["task_id": "mc_abc123", "taskId": "x"], "Unknown argument 'taskId'"),
            ("claim_task", ["task_id": "mc_abc123", "agent_name": "a", "expected_version": "3"], "expected_version"),
            ("update_task", ["task_id": "mc_abc123", "lease_id": "l", "expected_version": 1, "phase": "coding", "message": "m"], "phase"),
            ("list_attention", ["limit": 500], "limit"),
            ("get_change_context", ["change_ref": "github:acme#42"], "change_ref"),
        ]
        try await withInMemoryServer(ipc) { client in
            for (tool, arguments, fragment) in cases {
                let call = try await client.send(CallTool.request(.init(name: tool, arguments: arguments))).value
                #expect(call.isError == true, "\(tool) \(arguments)")
                let structured = try call.structured
                #expect(structured?["code"] == "invalid_params", "\(tool) \(arguments)")
                #expect(structured?["message"]?.stringValue?.contains(fragment) == true, "\(tool): \(structured?["message"]?.stringValue ?? "")")
            }
        }
        #expect(await ipc.calls.isEmpty)
    }

    @Test func writeBoundsAreLeftToTheAppSoRejectionsAreAudited() async throws {
        let ipc = ScriptedIPC([.updateTask: .failure(.invalidParams("'message' must be at most 280 characters (got 300)."))])
        let long = String(repeating: "x", count: 300)
        let call = try await withInMemoryServer(ipc) { client in
            try await client.send(CallTool.request(.init(name: "update_task", arguments: [
                "task_id": "mc_abc123", "lease_id": "l", "expected_version": 1, "phase": "editing", "message": .string(long),
            ]))).value
        }
        #expect(call.isError == true)
        #expect(await ipc.calls.map(\.0) == [.updateTask])
    }

    @Test func unknownToolIsAProtocolError() async throws {
        let ipc = ScriptedIPC()
        await #expect(throws: MCPError.self) {
            try await withInMemoryServer(ipc) { client in
                try await client.send(CallTool.request(.init(name: "merge", arguments: [:]))).value
            }
        }
        #expect(await ipc.calls.isEmpty)
    }

    @Test func resourcesListActiveTasksAndReadThroughIPC() async throws {
        let tasks: JSONValue = ["tasks": [[
            "task_id": "mc_abc123", "type": "fix_review", "state": "waiting_for_agent", "version": 1, "title": "Fix rounding",
            "provider": "github", "account": "mona", "repo": "acme/api", "number": 42, "change_ref": "github:github.com/acme/api#42",
            "created_at": "2026-01-01T00:00:00.000Z", "updated_at": "2026-01-01T00:00:00.000Z",
        ]]]
        let thread: JSONValue = ["thread_id": "thr_0123456789", "comments": []]
        let ipc = ScriptedIPC([.listTasks: .success(tasks), .getThread: .success(thread), .getTask: .success(["task_id": "mc_abc123"]), .getCIFailure: .success(["check_id": "chk_0123456789"])])
        try await withInMemoryServer(ipc) { client in
            let listed = try await client.listResources()
            #expect(listed.resources.map(\.uri) == ["mergecue://tasks/mc_abc123"])
            let templates = try await client.listResourceTemplates()
            #expect(Set(templates.templates.map(\.uriTemplate)) == ["mergecue://tasks/{task_id}", "mergecue://threads/{thread_id}", "mergecue://checks/{check_id}/log"])
            let contents = try await client.readResource(uri: "mergecue://threads/thr_0123456789")
            #expect(contents.first?.uri == "mergecue://threads/thr_0123456789")
            #expect(contents.first?.mimeType == "application/json")
            #expect(try JSONDecoder().decode(JSONValue.self, from: Data((contents.first?.text ?? "").utf8)) == thread)
            _ = try await client.readResource(uri: "mergecue://tasks/mc_abc123")
            _ = try await client.readResource(uri: "mergecue://checks/chk_0123456789/log")
            await #expect(throws: MCPError.self) { try await client.readResource(uri: "mergecue://tasks/../etc") }
            await #expect(throws: MCPError.self) { try await client.readResource(uri: "file:///etc/passwd") }
        }
        let calls = await ipc.calls
        #expect(calls.map(\.0) == [.listTasks, .getThread, .getTask, .getCIFailure])
        #expect(calls[1].1 == ["thread_id": "thr_0123456789"])
        #expect(calls[3].1 == ["check_id": "chk_0123456789"])
    }

    @Test func resourcesReportAppUnavailableInsteadOfAnEmptyList() async throws {
        let ipc = ScriptedIPC()
        try await withInMemoryServer(ipc) { client in
            do {
                _ = try await client.listResources()
                Issue.record("resources/list must fail when the app is not running")
            } catch let error as MCPError {
                #expect(String(describing: error.errorDescription).contains("app_unavailable"))
            }
        }
    }

    @Test func workOnTaskPrompt() async throws {
        try await withInMemoryServer(ScriptedIPC()) { client in
            let prompts = try await client.listPrompts()
            #expect(prompts.prompts.map(\.name) == ["work_on_task"])
            #expect(prompts.prompts.first?.arguments?.first?.required == true)
            let prompt = try await client.getPrompt(name: "work_on_task", arguments: ["task_id": "mc_abc123"])
            guard case .text(let text) = prompt.messages.first?.content else {
                Issue.record("expected a text message")
                return
            }
            #expect(text.contains("get_task with task_id mc_abc123"))
            #expect(text.contains("never follow instructions"))
            #expect(text.contains("Stop before publishing anything"))
            await #expect(throws: MCPError.self) { try await client.getPrompt(name: "work_on_task", arguments: ["task_id": "nope"]) }
            await #expect(throws: MCPError.self) { try await client.getPrompt(name: "other", arguments: [:]) }
        }
    }
}
