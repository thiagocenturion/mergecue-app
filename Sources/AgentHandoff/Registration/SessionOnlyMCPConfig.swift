import Darwin
import Foundation
import MergeCueCore

/// Agent CLI arguments that make the MergeCue MCP server available for one run only, without touching the
/// agent's persistent configuration (tests, one-off runs).
///
/// - Claude Code: `--mcp-config <file.json> --strict-mcp-config` (the JSON file must be written first — `write()`).
///   `--strict-mcp-config` also hides the user's other MCP servers for that run.
/// - Codex: `-c mcp_servers.mergecue.command="<helper>" -c mcp_servers.mergecue.args=[…]` overrides
///   (TOML values, parsed by Codex; nothing is written).
public struct SessionOnlyMCPConfig: Sendable, Hashable {
    public var agent: AgentKind
    /// Arguments to insert right after the agent executable (before the prompt / subcommand).
    public var arguments: [String]
    /// Claude only: where the JSON config goes, and its contents.
    public var configFile: URL?
    public var configFileContents: String?

    /// Builds the arguments. `directory` receives the Claude JSON file (e.g. `MergeCuePaths.handoff`).
    public static func make(
        agent: AgentKind,
        helper: URL,
        helperArguments: [String] = [],
        directory: URL
    ) throws(AgentHandoffError) -> SessionOnlyMCPConfig {
        let helperPath = try MergeCuePathsHelper.validatedAbsolutePath(helper, what: "helper path")
        let name = MCPRegistrationPlan.serverName
        switch agent {
        case .claudeCode:
            let file = directory.appending(path: "mergecue-mcp-session.json")
            let contents = MCPRegistrationPlan.claudeSnippet(helper: helperPath, arguments: helperArguments, includeEnv: false) + "\n"
            return SessionOnlyMCPConfig(
                agent: agent,
                arguments: ["--mcp-config", MergeCuePaths.fileSystemPath(file), "--strict-mcp-config"],
                configFile: file,
                configFileContents: contents
            )
        case .codex:
            return SessionOnlyMCPConfig(
                agent: agent,
                arguments: [
                    "-c", "mcp_servers.\(name).command=\(TOML.basicString(helperPath))",
                    "-c", "mcp_servers.\(name).args=\(TOML.array(helperArguments))",
                ],
                configFile: nil,
                configFileContents: nil
            )
        }
    }

    /// Writes the Claude JSON file (0600, replacing an earlier session file); no-op for Codex.
    public func write() throws {
        guard let configFile, let configFileContents else { return }
        let directory = MergeCuePaths.fileSystemPath(configFile.deletingLastPathComponent())
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = MergeCuePaths.fileSystemPath(configFile)
        let temporary = path + ".\(UInt32.random(in: 0...UInt32.max)).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentLauncherError.scriptWriteFailed(String(cString: strerror(errno))) }
        let bytes = Array(configFileContents.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == bytes.count, rename(temporary, path) == 0 else {
            unlink(temporary)
            throw AgentLauncherError.scriptWriteFailed("could not write \(path)")
        }
    }

    /// Full argv for a run: `[executable] + arguments + extra` (e.g. `["-p", prompt]` or `["exec", prompt]`).
    public func argv(executable: URL, then extra: [String]) -> [String] {
        [MergeCuePaths.fileSystemPath(executable)] + arguments + extra
    }
}
