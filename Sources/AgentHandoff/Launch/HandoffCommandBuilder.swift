import Foundation
import MergeCueCore

/// POSIX shell quoting.
public enum ShellQuoting {
    /// Wraps `value` in single quotes; embedded `'` becomes `'\''`. Everything else (including `$`, backticks,
    /// `\`, `!`, newlines) is literal inside single quotes in `sh`, `bash` and `zsh`.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Quotes only when needed (for display of argv; safe characters are left bare).
    public static func quoteIfNeeded(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+:,./-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return quote(value)
    }

    /// argv joined into one shell-safe command line.
    public static func join(_ argv: [String]) -> String {
        argv.map(quoteIfNeeded).joined(separator: " ")
    }
}

/// A ready-to-run handoff: `cd '<worktree>' && <agent> '<prompt>'`.
public struct HandoffCommand: Sendable, Hashable, Codable {
    public var agent: AgentKind
    public var taskID: TaskID
    public var worktree: URL
    /// The exact prompt (PLAN §7).
    public var prompt: String
    /// How the agent is invoked (`claude`, `codex`, or an absolute path).
    public var executable: String
    /// The single shell line to paste or run.
    public var shellCommand: String

    public init(agent: AgentKind, taskID: TaskID, worktree: URL, prompt: String, executable: String, shellCommand: String) {
        self.agent = agent
        self.taskID = taskID
        self.worktree = worktree
        self.prompt = prompt
        self.executable = executable
        self.shellCommand = shellCommand
    }
}

/// Builds the agent-agnostic handoff prompt and per-agent shell commands.
public enum HandoffCommandBuilder {
    /// "Work on MergeCue task <id>. Use MergeCue MCP for context and status updates. Work only in the designated
    /// checkout. Stop before publishing anything."
    public static func prompt(for taskID: TaskID) -> String {
        "Work on MergeCue task \(taskID.rawValue). Use MergeCue MCP for context and status updates. "
            + "Work only in the designated checkout. Stop before publishing anything."
    }

    /// Validates a raw id (`mc_` + 6 × `[a-z0-9]`) before building anything from it.
    public static func validatedTaskID(_ raw: String) throws(AgentHandoffError) -> TaskID {
        guard let id = TaskID(rawValue: raw) else { throw .invalidTaskID(raw) }
        return id
    }

    /// `cd '<worktree>' && <executable> '<prompt>'`. `executable` defaults to the agent's bare CLI name; pass
    /// `DetectedAgent.invocation` to use an absolute path when the login shell does not resolve it.
    public static func command(
        agent: AgentKind,
        taskID: TaskID,
        worktree: URL,
        executable: String? = nil
    ) throws(AgentHandoffError) -> HandoffCommand {
        let path = MergeCuePathsHelper.path(worktree)
        guard worktree.isFileURL, path.hasPrefix("/") else { throw .invalidPath("worktree must be an absolute path") }
        guard !path.unicodeScalars.contains("\u{0}") else { throw .invalidPath("worktree contains a NUL byte") }
        let executable = executable ?? agent.executableName
        guard !executable.isEmpty, !executable.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw .invalidPath("agent executable is empty or contains control characters") }
        let prompt = prompt(for: taskID)
        let shell = "cd \(ShellQuoting.quote(path)) && \(ShellQuoting.quoteIfNeeded(executable)) \(ShellQuoting.quote(prompt))"
        return HandoffCommand(
            agent: agent,
            taskID: taskID,
            worktree: URL(filePath: path, directoryHint: .isDirectory),
            prompt: prompt,
            executable: executable,
            shellCommand: shell
        )
    }

    /// Validates `rawTaskID` and builds the command.
    public static func command(
        agent: AgentKind,
        rawTaskID: String,
        worktree: URL,
        executable: String? = nil
    ) throws(AgentHandoffError) -> HandoffCommand {
        try command(agent: agent, taskID: validatedTaskID(rawTaskID), worktree: worktree, executable: executable)
    }

    /// Builds the command for a detected agent (bare name when on the login `PATH`, absolute path otherwise).
    public static func command(for agent: DetectedAgent, taskID: TaskID, worktree: URL) throws(AgentHandoffError) -> HandoffCommand {
        try command(agent: agent.kind, taskID: taskID, worktree: worktree, executable: agent.invocation)
    }
}
