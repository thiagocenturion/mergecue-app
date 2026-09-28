import Darwin
import Foundation
import MCP
import MergeCueCore
import MergeCueIPC
import System
import Testing

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// A private, SHORT temporary `MERGECUE_HOME` under `/tmp` (`sun_path` is limited to 104 bytes).
struct TestHome: Sendable {
    let root: String
    let paths: MergeCuePaths

    static func make() throws -> TestHome {
        var template = Array("/tmp/mcmcp-XXXXXX".utf8CString)
        let created: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(validatingCString: base)
        }
        guard let root = created else { throw TestFailure("mkdtemp failed") }
        return TestHome(root: root, paths: MergeCuePaths(root: URL(filePath: root, directoryHint: .isDirectory), fallbackSocketParent: URL(filePath: root)))
    }

    var worktrees: String { root + "/worktrees" }

    /// Environment for child processes: this home, no inherited socket override.
    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[MergeCuePaths.homeEnvironmentKey] = root
        environment[MergeCuePaths.socketEnvironmentKey] = nil
        environment[MergeCueMCPServerTestsConstants.versionKey] = nil
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

enum MergeCueMCPServerTestsConstants {
    static let versionKey = "MERGECUE_VERSION"
}

/// Runs `body` with a fresh home and a running IPC server backed by a `FakeEngine`.
func withFakeApp<T>(_ body: (TestHome, FakeEngine) async throws -> T) async throws -> T {
    let home = try TestHome.make()
    defer { home.remove() }
    let engine = await FakeEngine(worktreeRoot: home.worktrees)
    let server = IPCServer(paths: home.paths, handler: engine, peerValidator: nil)
    try await server.start()
    do {
        let value = try await body(home, engine)
        await server.stop()
        return value
    } catch {
        await server.stop()
        throw error
    }
}

/// Runs `body` with a fresh home and NO app listening.
func withoutApp<T>(_ body: (TestHome) async throws -> T) async throws -> T {
    let home = try TestHome.make()
    defer { home.remove() }
    return try await body(home)
}

// MARK: - Built products

enum BuiltProducts {
    /// Directory holding the built executables (next to the test bundle).
    static let directory: URL? = {
        if let override = ProcessInfo.processInfo.environment["MERGECUE_BIN_DIR"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return packageRoot.appending(path: ".build/debug", directoryHint: .isDirectory)
    }()

    static func path(_ name: String) throws -> String {
        guard let directory else { throw TestFailure("Cannot locate the build products directory.") }
        let path = directory.appending(path: name).path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw TestFailure("\(name) is not built at \(path); run `swift build` first.")
        }
        return path
    }

    static func mcp() throws -> String { try path("mergecue-mcp") }
    static func agentSim() throws -> String { try path("mergecue-agent-sim") }
}

// MARK: - Processes

struct ProcessOutput: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs an executable to completion (stdin closed or fed `input`), capturing both streams.
func runProcess(_ executable: String, _ arguments: [String], environment: [String: String], input: Data? = nil, timeout: TimeInterval = 60) async throws -> ProcessOutput {
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    process.environment = environment
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()

    let stdoutTask = Task.detached { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }
    let stderrTask = Task.detached { stderrPipe.fileHandleForReading.readDataToEndOfFile() }
    if let input {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
    }
    try? stdinPipe.fileHandleForWriting.close()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    if process.isRunning {
        process.terminate()
        throw TestFailure("\(executable) \(arguments) did not exit within \(timeout) s")
    }
    let out = await stdoutTask.value
    let err = await stderrTask.value
    return ProcessOutput(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
}

/// An SDK `Client` connected to a spawned `mergecue-mcp` over stdio pipes.
final class SpawnedMCP: @unchecked Sendable {
    let process: Process
    let client: Client
    let initialize: Initialize.Result
    private let toChild: Pipe
    private let fromChild: Pipe
    private let errorPipe: Pipe
    private let stderrTask: Task<Data, Never>

    static func start(home: TestHome, extraEnvironment: [String: String] = [:], clientName: String = "mcp-tests") async throws -> SpawnedMCP {
        let process = Process()
        process.executableURL = URL(filePath: try BuiltProducts.mcp())
        process.environment = home.environment(extraEnvironment)
        let toChild = Pipe()
        let fromChild = Pipe()
        let errorPipe = Pipe()
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = errorPipe
        try process.run()
        let stderrTask = Task.detached { errorPipe.fileHandleForReading.readDataToEndOfFile() }
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromChild.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toChild.fileHandleForWriting.fileDescriptor)
        )
        let client = Client(name: clientName, version: "1.0")
        let initialize = try await client.connect(transport: transport)
        return SpawnedMCP(process: process, client: client, initialize: initialize, toChild: toChild, fromChild: fromChild, errorPipe: errorPipe, stderrTask: stderrTask)
    }

    private init(process: Process, client: Client, initialize: Initialize.Result, toChild: Pipe, fromChild: Pipe, errorPipe: Pipe, stderrTask: Task<Data, Never>) {
        self.process = process
        self.client = client
        self.initialize = initialize
        self.toChild = toChild
        self.fromChild = fromChild
        self.errorPipe = errorPipe
        self.stderrTask = stderrTask
    }

    /// Full `tools/call` result (with `structuredContent`).
    func call(_ name: String, _ arguments: [String: Value]) async throws -> CallTool.Result {
        let context = try await client.send(CallTool.request(.init(name: name, arguments: arguments)))
        return try await context.value
    }

    /// Closes stdin and waits for a clean exit; returns the exit status and stderr.
    @discardableResult
    func close(timeout: TimeInterval = 20) async throws -> (status: Int32, stderr: String) {
        await client.disconnect()
        try? toChild.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            process.terminate()
            throw TestFailure("mergecue-mcp did not exit after stdin EOF")
        }
        let stderr = String(decoding: await stderrTask.value, as: UTF8.self)
        return (process.terminationStatus, stderr)
    }
}

// MARK: - JSON helpers

extension Value {
    /// The same JSON as `JSONValue` (via the wire bytes, exactly as a client would see it).
    var json: JSONValue {
        get throws {
            let data = try JSONEncoder().encode(self)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
    }
}

extension CallTool.Result {
    var text: String {
        content.compactMap { item -> String? in
            if case .text(let text, _, _) = item { return text }
            return nil
        }.joined()
    }

    /// `structuredContent` as `JSONValue`.
    var structured: JSONValue? {
        get throws { try structuredContent?.json }
    }

    /// The text content parsed as JSON.
    var textJSON: JSONValue {
        get throws { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    }
}

/// Tool arguments as the `JSONValue` the app should receive.
func jsonArguments(_ arguments: [String: Value]) throws -> JSONValue {
    try Value.object(arguments).json
}
