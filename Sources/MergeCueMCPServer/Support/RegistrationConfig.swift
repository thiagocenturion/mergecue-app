import Foundation
import MergeCueCore

/// Agents `mergecue-mcp --print-config` knows how to register with.
public enum MCPAgentKind: String, CaseIterable, Sendable {
    case claude
    case codex
}

/// Renders the registration command and config snippet for a `mergecue-mcp` binary (printed, never applied: changing
/// an agent's configuration needs the owner's consent, which `AgentHandoff` handles in the app).
public enum RegistrationConfig {
    /// MCP server name used in agent configurations.
    public static let serverName = "mergecue"

    /// Environment variables worth carrying into the agent's config (a non-default data root).
    public static let forwardedEnvironmentKeys = [MergeCuePaths.homeEnvironmentKey, MergeCuePaths.socketEnvironmentKey]

    public static func render(agent: MCPAgentKind, executablePath: String, environment: [String: String] = [:]) -> String {
        let env = forwardedEnvironmentKeys.compactMap { key -> (String, String)? in
            guard let value = environment[key], !value.isEmpty else { return nil }
            return (key, value)
        }
        switch agent {
        case .claude:
            return claude(executablePath: executablePath, env: env)
        case .codex:
            return codex(executablePath: executablePath, env: env)
        }
    }

    private static func claude(executablePath: String, env: [(String, String)]) -> String {
        let envFlags = env.map { " --env \(shellQuote("\($0.0)=\($0.1)"))" }.joined()
        var server: [String: Any] = ["type": "stdio", "command": executablePath, "args": [String]()]
        if !env.isEmpty {
            server["env"] = Dictionary(uniqueKeysWithValues: env)
        }
        let json = jsonText(["mcpServers": [serverName: server]])
        return """
            # Claude Code: register MergeCue for your user (run once), then verify with `claude mcp list`.
            claude mcp add --transport stdio --scope user\(envFlags) \(serverName) -- \(shellQuote(executablePath))

            # Or add it to a project's .mcp.json:
            \(json)

            """
    }

    private static func codex(executablePath: String, env: [(String, String)]) -> String {
        let envFlags = env.map { " --env \(shellQuote("\($0.0)=\($0.1)"))" }.joined()
        var toml = """
            [mcp_servers.\(serverName)]
            command = \(tomlString(executablePath))
            args = []
            """
        if !env.isEmpty {
            toml += "\nenv = { " + env.map { "\($0.0) = \(tomlString($0.1))" }.joined(separator: ", ") + " }"
        }
        return """
            # Codex CLI: register MergeCue (run once), then verify with `codex mcp list`.
            codex mcp add \(serverName)\(envFlags) -- \(shellQuote(executablePath))

            # Or add it to ~/.codex/config.toml:
            \(toml)

            """
    }

    /// POSIX shell single-quoting (bare when the value only contains safe characters).
    public static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:@%+,")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// TOML basic string.
    static func tomlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            case "\r": escaped += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"" + escaped + "\""
    }

    private static func jsonText(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
