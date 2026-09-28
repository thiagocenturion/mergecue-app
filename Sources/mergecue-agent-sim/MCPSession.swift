import Darwin
import Foundation
import MCP
import MergeCueCore
import System

/// Outcome of one `tools/call` as an agent sees it.
enum ToolOutcome: Sendable {
    /// `isError` false: the structured result.
    case success(JSONValue)
    /// `isError` true: MergeCue's `{code, message, retryable}`.
    case toolError(code: String, message: String, retryable: Bool)
    /// JSON-RPC error (unknown tool, transport failure…).
    case protocolError(String)

    var value: JSONValue? {
        if case .success(let value) = self { return value }
        return nil
    }

    var errorCode: String? {
        if case .toolError(let code, _, _) = self { return code }
        return nil
    }

    var isRejected: Bool {
        if case .success = self { return false }
        return true
    }

    /// One-line description for the report.
    var summary: String {
        switch self {
        case .success(let value):
            let text = value.jsonString()
            return text.count > 300 ? String(text.prefix(300)) + "…" : text
        case .toolError(let code, let message, let retryable):
            return "isError \(code): \(message)\(retryable ? " (retryable)" : "")"
        case .protocolError(let message):
            return "protocol error: \(message)"
        }
    }
}

/// A real MCP client session with a spawned `mergecue-mcp` over stdio pipes.
final class MCPSession: @unchecked Sendable {
    let client: Client
    let process: Process
    let label: String
    private let toChild: Pipe
    private let fromChild: Pipe
    private(set) var initializeResult: Initialize.Result?

    /// Spawns `executable` (inheriting the environment, so `MERGECUE_HOME` reaches it) and connects.
    static func start(executable: String, label: String, clientName: String) async throws -> MCPSession {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = []
        process.environment = ProcessInfo.processInfo.environment
        let toChild = Pipe()
        let fromChild = Pipe()
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = FileHandle.standardError
        try process.run()

        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromChild.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toChild.fileHandleForWriting.fileDescriptor)
        )
        let client = Client(name: clientName, version: "1.0")
        let session = MCPSession(client: client, process: process, label: label, toChild: toChild, fromChild: fromChild)
        session.initializeResult = try await client.connect(transport: transport)
        return session
    }

    private init(client: Client, process: Process, label: String, toChild: Pipe, fromChild: Pipe) {
        self.client = client
        self.process = process
        self.label = label
        self.toChild = toChild
        self.fromChild = fromChild
    }

    /// `tools/list` names.
    func toolNames() async throws -> [String] {
        try await client.listTools().tools.map(\.name)
    }

    /// `tools/call`, keeping `structuredContent` (the SDK's convenience API drops it).
    func call(_ name: String, _ arguments: [String: Value]) async -> ToolOutcome {
        do {
            let context = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
            let result = try await context.value
            let structured = result.structuredContent.flatMap(Self.json)
            if result.isError == true {
                let code = structured?["code"]?.stringValue ?? "unknown"
                let message = structured?["message"]?.stringValue ?? Self.text(of: result.content)
                return .toolError(code: code, message: message, retryable: structured?["retryable"]?.boolValue ?? false)
            }
            guard let structured else {
                return .protocolError("Tool \(name) returned no structuredContent.")
            }
            return .success(structured)
        } catch {
            return .protocolError(String(describing: error))
        }
    }

    /// Closes stdin (clean EOF shutdown) and waits for the child to exit.
    func close() async {
        await client.disconnect()
        try? toChild.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            process.terminate()
        }
    }

    /// Simulates an agent crash: the MCP server process is killed without any further call.
    func crash() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func json(_ value: Value) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func text(of content: [Tool.Content]) -> String {
        content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }.joined(separator: "\n")
    }
}
