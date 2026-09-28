import Foundation
import MCP
import MergeCueCore
import Testing
@testable import AgentHandoff

/// Records which tools a fake server was asked to call.
actor CallRecorder {
    private(set) var calls: [String] = []
    func record(_ name: String) { calls.append(name) }
}

/// In-process fake MergeCue MCP server over the SDK's `InMemoryTransport`.
struct FakeMergeCueServer {
    enum Mode { case appUnavailable, ok, slowToolsList }

    static let allTools = MCPVerificationReport.requiredTools

    static func start(
        name: String = "mergecue",
        tools: [String] = allTools,
        mode: Mode,
        recorder: CallRecorder
    ) async throws -> (client: InMemoryTransport, server: Server) {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: name, version: "1.2.3", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            if mode == .slowToolsList { try await Task.sleep(for: .seconds(30)) }
            return ListTools.Result(tools: tools.map { Tool(name: $0, description: $0, inputSchema: .object(["type": .string("object")])) })
        }
        await server.withMethodHandler(CallTool.self) { params in
            await recorder.record(params.name)
            switch mode {
            case .appUnavailable:
                let error: Value = .object([
                    "code": .string("app_unavailable"),
                    "message": .string("MergeCue app is not running. Open MergeCue and retry."),
                    "retryable": .bool(true),
                ])
                return try CallTool.Result(content: [.text(text: #"{"code":"app_unavailable"}"#, annotations: nil, _meta: nil)], structuredContent: Optional(error), isError: true)
            case .ok, .slowToolsList:
                return try CallTool.Result(content: [.text(text: #"{"items":[],"total":0}"#, annotations: nil, _meta: nil)], structuredContent: Optional(Value.object(["items": .array([]), "total": .int(0)])))
            }
        }
        try await server.start(transport: serverTransport)
        return (clientTransport, server)
    }
}

@Suite("MCP server verifier")
struct VerifierTests {
    @Test func reportsAppUnavailableFromListAttention() async throws {
        let recorder = CallRecorder()
        let (transport, server) = try await FakeMergeCueServer.start(mode: .appUnavailable, recorder: recorder)
        defer { Task { await server.stop() } }

        let report = try await MCPServerVerifier(timeout: 5).verify(transport: transport, probe: .listAttention)

        #expect(report.serverName == "mergecue")
        #expect(report.serverVersion == "1.2.3")
        #expect(report.toolNames == FakeMergeCueServer.allTools)
        #expect(report.missingTools.isEmpty)
        #expect(report.looksLikeMergeCue)
        let roundTrip = try #require(report.readOnlyRoundTrip)
        #expect(roundTrip.isAppUnavailable)
        #expect(roundTrip == .toolError(tool: "list_attention", code: "app_unavailable", message: "MergeCue app is not running. Open MergeCue and retry.", retryable: true))
        #expect(await recorder.calls == ["list_attention"])
    }

    @Test func getTaskRoundTripOK() async throws {
        let recorder = CallRecorder()
        let (transport, server) = try await FakeMergeCueServer.start(mode: .ok, recorder: recorder)
        defer { Task { await server.stop() } }
        let id = try #require(TaskID(rawValue: "mc_abc123"))

        let report = try await MCPServerVerifier(timeout: 5).verify(transport: transport, probe: .getTask(id))

        #expect(report.readOnlyRoundTrip == .ok(tool: "get_task"))
        #expect(await recorder.calls == ["get_task"])
    }

    @Test func noProbeCallsNothing() async throws {
        let recorder = CallRecorder()
        let (transport, server) = try await FakeMergeCueServer.start(mode: .ok, recorder: recorder)
        defer { Task { await server.stop() } }
        let report = try await MCPServerVerifier(timeout: 5).verify(transport: transport, probe: .none)
        #expect(report.readOnlyRoundTrip == nil)
        #expect(await recorder.calls.isEmpty)
    }

    @Test func missingToolIsReportedNotCalled() async throws {
        let recorder = CallRecorder()
        let (transport, server) = try await FakeMergeCueServer.start(name: "other", tools: ["claim_task", "get_task"], mode: .ok, recorder: recorder)
        defer { Task { await server.stop() } }

        let report = try await MCPServerVerifier(timeout: 5).verify(transport: transport, probe: .listAttention)

        #expect(!report.looksLikeMergeCue)
        #expect(report.missingTools.contains("list_attention"))
        #expect(report.readOnlyRoundTrip == .failed(tool: "list_attention", message: "the server does not offer list_attention"))
        #expect(await recorder.calls.isEmpty) // claim_task is listed but never called
    }

    @Test func onlyReadOnlyToolsAreAllowed() {
        #expect(MCPServerVerifier.readOnlyTools == ["list_attention", "get_task"])
        for mutating in ["claim_task", "heartbeat", "update_task", "report_changes", "report_tests", "submit_result", "fail_task", "propose_rule"] {
            #expect(!MCPServerVerifier.readOnlyTools.contains(mutating))
        }
    }

    @Test func slowServerTimesOut() async throws {
        let recorder = CallRecorder()
        let (transport, server) = try await FakeMergeCueServer.start(mode: .slowToolsList, recorder: recorder)
        defer { Task { await server.stop() } }
        let start = Date()
        await #expect(throws: MCPVerificationError.timedOut(stage: "tools/list")) {
            _ = try await MCPServerVerifier(timeout: 0.5).verify(transport: transport, probe: .listAttention)
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func interpretsTextOnlyErrors() {
        let result = CallTool.Result(
            content: [.text(text: #"{"code":"not_found","message":"No task mc_zzzzzz","retryable":false}"#, annotations: nil, _meta: nil)],
            isError: true
        )
        #expect(MCPServerVerifier.interpret(result, tool: "get_task")
            == .toolError(tool: "get_task", code: "not_found", message: "No task mc_zzzzzz", retryable: false))
        let plain = CallTool.Result(content: [.text(text: "boom", annotations: nil, _meta: nil)], isError: true)
        #expect(MCPServerVerifier.interpret(plain, tool: "get_task") == .toolError(tool: "get_task", code: nil, message: "boom", retryable: nil))
    }

    // MARK: Real subprocess over stdio

    @Test func spawnsHelperOverStdio() async throws {
        let dir = try makeTempDirectory()
        let helper = try writeScript(dir.appending(path: "mergecue-mcp"), shellMCPServer)
        let callLog = dir.appending(path: "calls.log")
        var environment = testEnvironment(home: dir)
        environment["CALL_LOG"] = MergeCuePaths.fileSystemPath(callLog)

        let report = try await MCPServerVerifier(timeout: 10).verify(helper: helper, environment: environment, probe: .listAttention)

        #expect(report.serverName == "mergecue")
        #expect(report.serverVersion == "9.9.9")
        #expect(report.toolNames == ["list_attention", "get_task", "claim_task"])
        #expect(report.readOnlyRoundTrip?.isAppUnavailable == true)
        #expect(try readText(callLog) == "list_attention\n")
    }

    @Test func helperThatExitsReportsRedactedStderr() async throws {
        let dir = try makeTempDirectory()
        let helper = try writeScript(dir.appending(path: "mergecue-mcp"), "echo 'fatal: bad token ghp_abcdefghijklmnopqrstuvwxyz0123456789' >&2; exit 4")
        do {
            _ = try await MCPServerVerifier(timeout: 5).verify(helper: helper, environment: testEnvironment(home: dir))
            Issue.record("expected failure")
        } catch {
            guard case .helperExited(let status, let stderr) = error else { Issue.record("unexpected \(error)"); return }
            #expect(status == 4)
            #expect(stderr.contains("fatal: bad token"))
            #expect(!stderr.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        }
    }

    @Test func silentHelperTimesOut() async throws {
        let dir = try makeTempDirectory()
        let helper = try writeScript(dir.appending(path: "mergecue-mcp"), "exec sleep 30")
        let start = Date()
        await #expect(throws: MCPVerificationError.timedOut(stage: "initialize")) {
            _ = try await MCPServerVerifier(timeout: 0.5).verify(helper: helper, environment: testEnvironment(home: dir))
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func missingHelperFailsToLaunch() async {
        await #expect(throws: MCPVerificationError.self) {
            _ = try await MCPServerVerifier(timeout: 1).verify(helper: URL(filePath: "/nonexistent/mergecue-mcp"))
        }
    }
}
