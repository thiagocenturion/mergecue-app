import Darwin
import Foundation
import MCP
import MergeCueCore
import MergeCueIPC
import System

/// Which read-only call to make after `tools/list`.
public enum ReadOnlyProbe: Sendable, Hashable {
    case none
    /// `list_attention {limit: 1}`.
    case listAttention
    /// `get_task {task_id}`.
    case getTask(TaskID)

    var toolName: String? {
        switch self {
        case .none: nil
        case .listAttention: "list_attention"
        case .getTask: "get_task"
        }
    }

    var arguments: [String: Value] {
        switch self {
        case .none: [:]
        case .listAttention: ["limit": .int(1)]
        case .getTask(let id): ["task_id": .string(id.rawValue)]
        }
    }
}

/// Outcome of the read-only tool call.
public enum ReadOnlyRoundTrip: Sendable, Hashable, Codable {
    /// The tool returned a non-error result.
    case ok(tool: String)
    /// The tool returned `isError: true` with MergeCue's structured error (`app_unavailable`, `not_found`, …).
    case toolError(tool: String, code: String?, message: String, retryable: Bool?)
    /// The call could not be made (tool not offered, transport/protocol failure, timeout).
    case failed(tool: String, message: String)

    public var isOK: Bool { if case .ok = self { true } else { false } }

    /// The MergeCue app is not running (the server itself works).
    public var isAppUnavailable: Bool {
        if case .toolError(_, let code, _, _) = self { return code == IPCErrorCode.appUnavailable.rawValue }
        return false
    }
}

/// What the verifier learned from the server.
public struct MCPVerificationReport: Sendable, Hashable, Codable {
    public var serverName: String
    public var serverVersion: String
    public var protocolVersion: String
    public var toolNames: [String]
    /// nil when no probe was requested.
    public var readOnlyRoundTrip: ReadOnlyRoundTrip?

    /// Tools every MergeCue server must offer (PLAN §7).
    public static let requiredTools: [String] = [
        "list_attention", "get_task", "get_change_context", "get_thread", "get_ci_failure",
        "claim_task", "update_task", "report_changes", "report_tests", "submit_result", "fail_task",
    ]

    public var missingTools: [String] { Self.requiredTools.filter { !toolNames.contains($0) } }

    /// Server name is `mergecue` and all required tools are listed.
    public var looksLikeMergeCue: Bool { serverName == MCPRegistrationPlan.serverName && missingTools.isEmpty }
}

/// Why verification could not complete.
public enum MCPVerificationError: Error, Sendable, Equatable, LocalizedError {
    case launchFailed(String)
    case timedOut(stage: String)
    /// The helper exited during verification (status, redacted stderr tail).
    case helperExited(status: Int32, stderr: String)
    case protocolError(stage: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): "Could not start the MergeCue MCP helper: \(detail)"
        case .timedOut(let stage): "The MergeCue MCP helper did not answer \(stage) in time."
        case .helperExited(let status, let stderr): "The MergeCue MCP helper exited (\(status)).\(stderr.isEmpty ? "" : " \(stderr)")"
        case .protocolError(let stage, let message): "MCP \(stage) failed: \(message)"
        }
    }
}

/// Speaks MCP to the helper like an agent would: initialize → tools/list → optional read-only call.
/// Only tools in `readOnlyTools` are ever called.
public struct MCPServerVerifier: Sendable {
    /// Tools the verifier may call. Mutating tools (`claim_task`, `update_task`, …) are never called.
    public static let readOnlyTools: Set<String> = ["list_attention", "get_task"]

    public var timeout: TimeInterval
    public var clientName: String
    public var clientVersion: String

    public init(timeout: TimeInterval = 10, clientName: String = "mergecue-verifier", clientVersion: String = "1") {
        self.timeout = timeout
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    /// Spawns `helper` over stdio (stdout = MCP, stderr captured and redacted) and verifies it. The helper is
    /// terminated afterwards.
    public func verify(
        helper: URL,
        arguments: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        probe: ReadOnlyProbe = .listAttention
    ) async throws(MCPVerificationError) -> MCPVerificationReport {
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.environment = environment
        let toChild = Pipe()
        let fromChild = Pipe()
        let errors = Pipe()
        // A helper that exits before reading its stdin must yield EPIPE (→ `helperExited`), never a SIGPIPE that
        // kills the verifying process (the app).
        _ = fcntl(toChild.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = errors

        let stderrTail = StderrTail()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { stderrTail.append(data) }
        }
        let exitStatus = Locked<Int32?>(nil)
        let client = Client(name: clientName, version: clientVersion)
        process.terminationHandler = { finished in
            exitStatus.value = finished.terminationStatus
            Task { await client.disconnect() }
        }

        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            throw .launchFailed(SecretRedactor.redact(error.localizedDescription))
        }

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromChild.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toChild.fileHandleForWriting.fileDescriptor)
        )
        let outcome: Result<MCPVerificationReport, MCPVerificationError>
        do {
            outcome = .success(try await run(client: client, transport: transport, probe: probe))
        } catch {
            outcome = .failure(error)
        }
        // Only an exit that happened before the failure explains it (we stop the helper ourselves below).
        let exitedEarly = exitStatus.value

        await client.disconnect()
        try? toChild.fileHandleForWriting.close()
        await Self.stop(process)
        errors.fileHandleForReading.readabilityHandler = nil
        try? fromChild.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()

        switch outcome {
        case .success(let report):
            return report
        case .failure(let error):
            if let status = exitedEarly {
                switch error {
                case .protocolError, .timedOut: throw .helperExited(status: status, stderr: stderrTail.redactedTail)
                case .launchFailed, .helperExited: break
                }
            }
            throw error
        }
    }

    /// Verifies a server reachable through `transport` (tests use the SDK's `InMemoryTransport`).
    public func verify(transport: any Transport, probe: ReadOnlyProbe = .listAttention) async throws(MCPVerificationError) -> MCPVerificationReport {
        let client = Client(name: clientName, version: clientVersion)
        let outcome: Result<MCPVerificationReport, MCPVerificationError>
        do {
            outcome = .success(try await run(client: client, transport: transport, probe: probe))
        } catch {
            outcome = .failure(error)
        }
        await client.disconnect()
        return try outcome.get()
    }

    // MARK: Protocol steps

    private func run(client: Client, transport: any Transport, probe: ReadOnlyProbe) async throws(MCPVerificationError) -> MCPVerificationReport {
        let initialize = try await step("initialize", client: client) {
            try await client.connect(transport: transport)
        }
        let tools = try await step("tools/list", client: client) {
            var names: [String] = []
            var cursor: String?
            repeat {
                let page = try await client.listTools(cursor: cursor)
                names += page.tools.map(\.name)
                cursor = page.nextCursor
            } while cursor != nil && names.count < 1000
            return names
        }
        var report = MCPVerificationReport(
            serverName: initialize.serverInfo.name,
            serverVersion: initialize.serverInfo.version,
            protocolVersion: initialize.protocolVersion,
            toolNames: tools,
            readOnlyRoundTrip: nil
        )
        guard let tool = probe.toolName else { return report }
        guard Self.readOnlyTools.contains(tool) else {
            report.readOnlyRoundTrip = .failed(tool: tool, message: "refusing to call a non-read-only tool")
            return report
        }
        guard tools.contains(tool) else {
            report.readOnlyRoundTrip = .failed(tool: tool, message: "the server does not offer \(tool)")
            return report
        }
        do {
            let result = try await step("tools/call \(tool)", client: client) {
                let context: RequestContext<CallTool.Result> = try await client.callTool(name: tool, arguments: probe.arguments)
                return try await context.value
            }
            report.readOnlyRoundTrip = Self.interpret(result, tool: tool)
        } catch {
            report.readOnlyRoundTrip = .failed(tool: tool, message: error.localizedDescription)
        }
        return report
    }

    /// Maps a tool result to a round-trip outcome; MergeCue errors carry `{code, message, retryable}` in
    /// `structuredContent` and/or as JSON text content.
    static func interpret(_ result: CallTool.Result, tool: String) -> ReadOnlyRoundTrip {
        guard result.isError == true else { return .ok(tool: tool) }
        var fields: [String: Value] = [:]
        if case .object(let object)? = result.structuredContent {
            fields = object
            if case .object(let nested)? = object["error"] { fields = nested }
        }
        var text = ""
        for content in result.content {
            if case .text(let value, _, _) = content { text += value }
        }
        if fields["code"] == nil,
           let decoded = try? JSONDecoder().decode(Value.self, from: Data(text.utf8)),
           case .object(let object) = decoded {
            fields = object
            if case .object(let nested)? = object["error"] { fields = nested }
        }
        let message = fields["message"]?.stringValue ?? text
        return .toolError(
            tool: tool,
            code: fields["code"]?.stringValue,
            message: BoundedText.truncate(SecretRedactor.redact(message), maxBytes: 1000).text,
            retryable: fields["retryable"]?.boolValue
        )
    }

    /// Runs one protocol step with a deadline. On timeout the client is disconnected, which fails any pending
    /// request so the step returns promptly.
    private func step<T: Sendable>(
        _ stage: String,
        client: Client,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws(MCPVerificationError) -> T {
        let deadline = timeout
        let timedOut = Locked(false)
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: .seconds(deadline))
                    timedOut.value = true
                    await client.disconnect()
                    throw MCPVerificationError.timedOut(stage: stage)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw MCPVerificationError.timedOut(stage: stage) }
                return first
            }
        } catch let error as MCPVerificationError {
            throw error
        } catch {
            if timedOut.value { throw .timedOut(stage: stage) }
            throw .protocolError(stage: stage, message: SecretRedactor.redact(String(describing: error)))
        }
    }

    private static func stop(_ process: Process) async {
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning { process.terminate() }
        for _ in 0..<40 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

/// Keeps the last 4 KiB of the helper's stderr.
private final class StderrTail: Sendable {
    private let buffer = Locked(Data())

    func append(_ data: Data) {
        buffer.mutate { stored in
            stored.append(data)
            if stored.count > 4096 { stored = stored.suffix(4096) }
        }
    }

    var redactedTail: String {
        let text = String(decoding: buffer.value, as: UTF8.self)
        return BoundedText.truncate(SecretRedactor.redact(text.trimmingCharacters(in: .whitespacesAndNewlines)), maxBytes: 1000, keepTail: true).text
    }
}
