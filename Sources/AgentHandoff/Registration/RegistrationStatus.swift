import Foundation
import MergeCueCore

/// The `mergecue` entry as reported by `claude mcp get mergecue` / `codex mcp get mergecue`.
public struct RegisteredMCPServer: Sendable, Hashable, Codable {
    public var command: String
    public var arguments: [String]
    /// Claude: `User config (available in all your projects)`, `Local config …`, `Project config …`; Codex: nil.
    public var scope: String?
    /// Codex `enabled`; nil when the CLI does not report it.
    public var enabled: Bool?
    /// Claude's health-check line (`✔ Connected`, `✘ Failed to connect`); nil for Codex.
    public var health: String?

    public init(command: String, arguments: [String] = [], scope: String? = nil, enabled: Bool? = nil, health: String? = nil) {
        self.command = command
        self.arguments = arguments
        self.scope = scope
        self.enabled = enabled
        self.health = health
    }

    /// Whether this entry launches `helper` with `arguments`.
    public func matches(helper: URL, arguments expected: [String] = []) -> Bool {
        command == MergeCuePaths.fileSystemPath(helper) && arguments == expected
    }

    /// Claude reports user scope as `User config …`.
    public var isUserScope: Bool { scope.map { $0.lowercased().hasPrefix("user") } ?? true }
}

/// Registration state of the MergeCue MCP server in one agent (read-only query).
public enum AgentRegistrationStatus: Sendable, Hashable, Codable {
    case notRegistered
    case registered(RegisteredMCPServer)
    /// The CLI failed, timed out or printed something unrecognised (message is redacted).
    case unknown(String)

    public var server: RegisteredMCPServer? {
        if case .registered(let server) = self { return server }
        return nil
    }

    /// Registered and pointing at `helper`.
    public func isRegistered(helper: URL, arguments: [String] = []) -> Bool {
        server?.matches(helper: helper, arguments: arguments) ?? false
    }
}

/// Parses `mcp get` output of both CLIs (recorded samples live in the tests).
public enum RegistrationStatusParser {
    public static func parse(agent: AgentKind, result: ProcessResult) -> AgentRegistrationStatus {
        switch agent {
        case .claudeCode: parseClaude(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr, timedOut: result.timedOut)
        case .codex: parseCodex(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr, timedOut: result.timedOut)
        }
    }

    /// `claude mcp get mergecue` (v2.1):
    /// ```
    /// mergecue:
    ///   Scope: User config (available in all your projects)
    ///   Status: ✔ Connected
    ///   Type: stdio
    ///   Command: /path/to/mergecue-mcp
    ///   Args:
    ///   Environment:
    /// ```
    /// Missing: exit 1, `No MCP server named "mergecue". …`.
    public static func parseClaude(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) -> AgentRegistrationStatus {
        if timedOut { return .unknown("claude mcp get timed out") }
        let combined = stdout + "\n" + stderr
        if combined.contains("No MCP server named") { return .notRegistered }
        var fields: [String: String] = [:]
        for line in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].lowercased()
            guard ["scope", "status", "type", "command", "args", "url"].contains(key), fields[key] == nil else { continue }
            fields[key] = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard exitCode == 0, let command = fields["command"], !command.isEmpty else {
            return .unknown(summary("claude mcp get", exitCode: exitCode, stdout: stdout, stderr: stderr))
        }
        let args = (fields["args"] ?? "").split(separator: " ").map(String.init)
        return .registered(RegisteredMCPServer(command: command, arguments: args, scope: fields["scope"], health: fields["status"]))
    }

    /// `codex mcp get mergecue --json` (v0.153) — `{"name","enabled","transport":{"type","command","args",…}}` —
    /// or its text form (`  command: …`, `  args: a b` / `-`). Missing: exit 1,
    /// `Error: No MCP server named 'mergecue' found.`.
    public static func parseCodex(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) -> AgentRegistrationStatus {
        if timedOut { return .unknown("codex mcp get timed out") }
        let combined = stdout + "\n" + stderr
        if combined.contains("No MCP server named") { return .notRegistered }
        if exitCode == 0,
           let object = try? JSONDecoder().decode(JSONValue.self, from: Data(stdout.utf8)),
           case .object(let root) = object {
            if case .object(let transport)? = root["transport"], case .string(let command)? = transport["command"] {
                var args: [String] = []
                if case .array(let values)? = transport["args"] {
                    args = values.compactMap { if case .string(let s) = $0 { s } else { nil } }
                }
                var enabled: Bool?
                if case .bool(let flag)? = root["enabled"] { enabled = flag }
                return .registered(RegisteredMCPServer(command: command, arguments: args, enabled: enabled))
            }
            return .unknown("codex mcp get returned a non-stdio server entry")
        }
        var fields: [String: String] = [:]
        for line in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].lowercased()
            guard ["enabled", "command", "args", "transport"].contains(key), fields[key] == nil else { continue }
            fields[key] = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard exitCode == 0, let command = fields["command"], !command.isEmpty, command != "-" else {
            return .unknown(summary("codex mcp get", exitCode: exitCode, stdout: stdout, stderr: stderr))
        }
        let rawArgs = fields["args"] ?? "-"
        let args = rawArgs == "-" ? [] : rawArgs.split(separator: " ").map(String.init)
        return .registered(RegisteredMCPServer(command: command, arguments: args, enabled: fields["enabled"].map { $0 == "true" }))
    }

    static func summary(_ what: String, exitCode: Int32, stdout: String, stderr: String) -> String {
        let detail = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = BoundedText.truncate(SecretRedactor.redact(detail), maxBytes: 600).text
        return "\(what) exited with \(exitCode)" + (bounded.isEmpty ? "" : ": \(bounded)")
    }
}
