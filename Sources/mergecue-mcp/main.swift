// mergecue-mcp — MergeCue's bundled stdio MCP server (a thin client of the running app's private IPC socket).
//
// stdout carries MCP protocol messages only (in server mode); every diagnostic goes to stderr.

import Darwin
import Dispatch
import Foundation
import MCP
import MergeCueCore
import MergeCueIPC
import MergeCueMCPServer

// MARK: - Diagnostics (stderr only)

/// Writes one redacted line to stderr with `write(2)` (tolerates a non-blocking descriptor; never touches stdout).
func logError(_ message: String) {
    let line = MCLog.standardErrorLine(message, category: "mergecue-mcp")
    var bytes = Array(line.utf8)
    if bytes.isEmpty { return }
    var offset = 0
    var attempts = 0
    while offset < bytes.count, attempts < 200 {
        let written = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return write(STDERR_FILENO, base.advanced(by: offset), buffer.count - offset)
        }
        if written > 0 {
            offset += written
        } else if written < 0, errno == EAGAIN || errno == EINTR {
            attempts += 1
            usleep(1000)
        } else {
            return
        }
    }
}

/// Plain stdout output for the non-server modes (`--version`, `--print-config`, `--help`).
func printOut(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

// MARK: - Paths

/// Absolute, symlink-resolved path of this executable.
func executablePath() -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    if _NSGetExecutablePath(&buffer, &size) == 0 {
        let raw = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if let resolved = realpath(raw, nil) {
            defer { free(resolved) }
            return String(validatingCString: resolved) ?? raw
        }
        return URL(filePath: raw).standardizedFileURL.path(percentEncoded: false)
    }
    return Bundle.main.executableURL?.resolvingSymlinksInPath().path(percentEncoded: false) ?? CommandLine.arguments[0]
}

// MARK: - Modes

let usage = """
    Usage: mergecue-mcp [--version | --self-test | --print-config claude|codex | --help]

      (no option)             Serve MCP over stdio (started by Claude Code, Codex or another MCP client).
      --version               Print the version.
      --self-test             Connect to the running MergeCue app and ping it (exit 0 = OK, 1 = failure).
      --print-config AGENT    Print the command/config that registers this binary with AGENT (claude or codex).

    Environment: MERGECUE_HOME (data root), MERGECUE_SOCKET (IPC socket override).

    """

let environment = ProcessInfo.processInfo.environment
let version = MergeCueMCPServerInfo.version(environment: environment)

func runSelfTest() async -> Int32 {
    let client = IPCClient.mergeCueMCP(environment: environment, version: version, timeout: 5)
    do {
        let pong = try await client.ping()
        guard pong.protocolVersion == IPCProtocol.version else {
            logError("self-test: FAILED — MergeCue \(pong.appVersion) speaks IPC protocol \(pong.protocolVersion), this mergecue-mcp speaks \(IPCProtocol.version). Use the mergecue-mcp bundled with the app.")
            return 1
        }
        let data = pong.isDemo ? "demo data" : "live data"
        logError("self-test: OK — mergecue-mcp \(version) connected to MergeCue \(pong.appVersion) (IPC protocol \(pong.protocolVersion), \(data)) at \(client.paths.socketPath).")
        return 0
    } catch {
        logError("self-test: FAILED — [\(error.code.rawValue)] \(error.message) (socket: \(client.paths.socketPath))")
        return 1
    }
}

/// Serves MCP over stdio until stdin reaches EOF or SIGTERM/SIGINT arrives.
func runServer() async -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    let service = MergeCueMCPService.live(environment: environment)
    let server = await service.makeServer()

    let (events, continuation) = AsyncStream<String>.makeStream()
    var signalSources: [DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        let name = signalNumber == SIGTERM ? "SIGTERM" : "SIGINT"
        source.setEventHandler { continuation.yield(name) }
        source.resume()
        signalSources.append(source)
    }

    do {
        try await server.start(transport: StdioTransport())
    } catch {
        logError("could not start the stdio transport: \(error)")
        return 1
    }
    logError("mergecue-mcp \(version) serving MCP on stdio (IPC socket: \(MergeCuePaths(environment: environment).socketPath)).")

    let waiter = Task {
        await server.waitUntilCompleted()
        continuation.yield("eof")
    }
    var reason = "eof"
    for await event in events {
        reason = event
        break
    }
    // On EOF let answered-but-unsent calls finish (IPC calls time out after 15 s); on a signal, stop promptly.
    var drained = await service.drain(timeout: reason == "eof" ? .seconds(16) : .seconds(2))
    if reason == "eof" {
        // Requests read just before EOF may not have started (or finished writing their reply) yet: give them a
        // short grace period, then drain again.
        try? await Task.sleep(for: .milliseconds(150))
        drained = await service.drain(timeout: .seconds(16))
    }
    if !drained {
        logError("stopping with \(await service.requestsInFlight()) request(s) still in flight.")
    }
    waiter.cancel()
    await server.stop()
    signalSources.forEach { $0.cancel() }
    logError("mergecue-mcp stopped (\(reason)).")
    return 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
let status: Int32
switch arguments.first {
case nil:
    status = await runServer()
case "--version", "-v":
    printOut("mergecue-mcp \(version) (MCP server \"\(MergeCueMCPServerInfo.name)\", MCP protocol \(Version.latest), IPC protocol \(IPCProtocol.version))\n")
    status = 0
case "--self-test":
    status = arguments.count == 1 ? await runSelfTest() : 64
    if arguments.count != 1 { logError("--self-test takes no arguments.\n\(usage)") }
case "--print-config":
    if arguments.count == 2, let agent = MCPAgentKind(rawValue: arguments[1].lowercased()) {
        printOut(RegistrationConfig.render(agent: agent, executablePath: executablePath(), environment: environment))
        status = 0
    } else {
        logError("--print-config needs one agent: claude or codex.\n\(usage)")
        status = 64
    }
case "--help", "-h":
    printOut(usage)
    status = 0
default:
    logError("unknown option \(String(arguments[0].prefix(64))).\n\(usage)")
    status = 64
}
exit(status)
