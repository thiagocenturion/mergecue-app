import CryptoKit
import Foundation
import MergeCueCore

/// What a registration plan does to the agent's configuration.
public enum RegistrationAction: String, Sendable, Hashable, Codable {
    /// `… mcp add …`
    case register
    /// `… mcp remove …`
    case unregister
}

/// The exact, user-reviewable change MergeCue proposes to an agent's MCP configuration: the argv it will run,
/// the resulting config snippet, the files the CLI touches and where they are backed up first.
public struct MCPRegistrationPlan: Sendable, Hashable, Codable {
    /// MCP server name used in every agent config.
    public static let serverName = "mergecue"

    public var action: RegistrationAction
    public var agent: AgentKind
    /// The agent CLI (`claude`, `codex`).
    public var executable: URL
    /// The bundled `mergecue-mcp` helper.
    public var helper: URL
    public var helperArguments: [String]
    /// Arguments after the executable, e.g. `["mcp", "add", "--scope", "user", "mergecue", "--", helper]`.
    public var arguments: [String]
    /// Configuration that results from the change (for `register`) or is removed (for `unregister`).
    public var configSnippet: String
    /// Config files the CLI is expected to modify.
    public var filesTouched: [URL]
    /// `<MergeCuePaths.root>/backups/<agent>-<timestamp>/` (a numeric suffix is added if it already exists).
    public var backupDirectory: URL
    /// Only the variables that decide which config file the CLI edits (`HOME`, `CLAUDE_CONFIG_DIR`,
    /// `CODEX_HOME`); applied on top of the registrar's environment so the plan and the run agree.
    public var configEnvironment: [String: String]

    /// Full argv (`[executable] + arguments`).
    public var argv: [String] { [MergeCuePaths.fileSystemPath(executable)] + arguments }

    /// Copy-pasteable command line.
    public var displayCommand: String { ShellQuoting.join(argv) }

    /// Stable fingerprint of everything the user reviewed; consent is bound to it.
    public var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data(displayCommand.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Factories

    /// Plan to register `helper` with the agent at `executable`.
    ///
    /// - Claude Code: `claude mcp add --scope user mergecue -- <helper>` → `~/.claude.json`
    ///   (`$CLAUDE_CONFIG_DIR/.claude.json` when set) gains `mcpServers.mergecue`.
    /// - Codex: `codex mcp add mergecue -- <helper>` → `~/.codex/config.toml` (`$CODEX_HOME/config.toml`) gains
    ///   `[mcp_servers.mergecue]`.
    public static func register(
        agent: AgentKind,
        executable: URL,
        helper: URL,
        helperArguments: [String] = [],
        paths: MergeCuePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) throws(AgentHandoffError) -> MCPRegistrationPlan {
        let helperPath = try MergeCuePathsHelper.validatedAbsolutePath(helper, what: "helper path")
        _ = try MergeCuePathsHelper.validatedAbsolutePath(executable, what: "agent executable")
        for argument in helperArguments where argument.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw .invalidPath("helper arguments contain control characters")
        }
        let arguments: [String]
        let snippet: String
        switch agent {
        case .claudeCode:
            arguments = ["mcp", "add", "--scope", "user", serverName, "--", helperPath] + helperArguments
            snippet = claudeSnippet(helper: helperPath, arguments: helperArguments)
        case .codex:
            arguments = ["mcp", "add", serverName, "--", helperPath] + helperArguments
            snippet = codexSnippet(helper: helperPath, arguments: helperArguments)
        }
        return MCPRegistrationPlan(
            action: .register,
            agent: agent,
            executable: executable,
            helper: URL(filePath: helperPath),
            helperArguments: helperArguments,
            arguments: arguments,
            configSnippet: snippet,
            filesTouched: configFiles(for: agent, environment: environment),
            backupDirectory: backupDirectory(for: agent, paths: paths, now: now),
            configEnvironment: configEnvironment(for: agent, environment: environment)
        )
    }

    /// Plan to remove the `mergecue` server (`claude mcp remove --scope user mergecue`, `codex mcp remove mergecue`).
    public static func unregister(
        agent: AgentKind,
        executable: URL,
        helper: URL,
        paths: MergeCuePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) throws(AgentHandoffError) -> MCPRegistrationPlan {
        var plan = try register(agent: agent, executable: executable, helper: helper, paths: paths, environment: environment, now: now)
        plan.action = .unregister
        switch agent {
        case .claudeCode: plan.arguments = ["mcp", "remove", "--scope", "user", serverName]
        case .codex: plan.arguments = ["mcp", "remove", serverName]
        }
        return plan
    }

    /// Convenience for a detected agent.
    public static func register(
        _ agent: DetectedAgent,
        helper: URL,
        paths: MergeCuePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) throws(AgentHandoffError) -> MCPRegistrationPlan {
        try register(agent: agent.kind, executable: agent.executableURL, helper: helper, paths: paths, environment: environment, now: now)
    }

    // MARK: Config locations

    /// The files each CLI edits for user-scope MCP servers.
    public static func configFiles(for agent: AgentKind, environment: [String: String]) -> [URL] {
        let home = homeDirectory(environment)
        switch agent {
        case .claudeCode:
            if let dir = nonEmpty(environment["CLAUDE_CONFIG_DIR"]) {
                return [URL(filePath: dir, directoryHint: .isDirectory).appending(path: ".claude.json")]
            }
            return [home.appending(path: ".claude.json")]
        case .codex:
            if let dir = nonEmpty(environment["CODEX_HOME"]) {
                return [URL(filePath: dir, directoryHint: .isDirectory).appending(path: "config.toml")]
            }
            return [home.appending(path: ".codex/config.toml")]
        }
    }

    static func configEnvironment(for agent: AgentKind, environment: [String: String]) -> [String: String] {
        let keys = agent == .claudeCode ? ["HOME", "CLAUDE_CONFIG_DIR"] : ["HOME", "CODEX_HOME"]
        var result: [String: String] = [:]
        for key in keys { if let value = nonEmpty(environment[key]) { result[key] = value } }
        return result
    }

    static func homeDirectory(_ environment: [String: String]) -> URL {
        if let home = nonEmpty(environment["HOME"]) { return URL(filePath: home, directoryHint: .isDirectory) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func backupDirectory(for agent: AgentKind, paths: MergeCuePaths, now: Date) -> URL {
        paths.root
            .appending(path: "backups", directoryHint: .isDirectory)
            .appending(path: "\(agent.slug)-\(AgentLauncher.timestamp(now))", directoryHint: .isDirectory)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: Snippets

    /// `mcpServers.mergecue` as written by `claude mcp add` (`type`, `command`, `args`, `env`).
    static func claudeSnippet(helper: String, arguments: [String], includeEnv: Bool = true) -> String {
        var lines = [
            "{",
            "  \"mcpServers\": {",
            "    \"\(serverName)\": {",
            "      \"type\": \"stdio\",",
            "      \"command\": \(jsonString(helper)),",
            "      \"args\": [\(arguments.map(jsonString).joined(separator: ", "))]" + (includeEnv ? "," : ""),
        ]
        if includeEnv { lines.append("      \"env\": {}") }
        lines += ["    }", "  }", "}"]
        return lines.joined(separator: "\n")
    }

    /// A JSON string literal.
    static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    /// `[mcp_servers.mergecue]` table (as written by `codex mcp add`).
    static func codexSnippet(helper: String, arguments: [String]) -> String {
        var lines = ["[mcp_servers.\(serverName)]", "command = \(TOML.basicString(helper))"]
        if !arguments.isEmpty { lines.append("args = \(TOML.array(arguments))") }
        return lines.joined(separator: "\n")
    }
}

/// Minimal TOML string encoding for config snippets and `-c key=value` overrides.
enum TOML {
    /// A TOML basic string (`"…"`) with `\`, `"` and control characters escaped.
    static func basicString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// `["a", "b"]`.
    static func array(_ values: [String]) -> String {
        "[" + values.map(basicString).joined(separator: ", ") + "]"
    }
}
