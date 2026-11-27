import Foundation
import MergeCueCore

/// A self-contained prompt handed to an agent without MergeCue MCP (D60): `cd '<directory>' && <agent> '<prompt>'`.
/// Used by "Without MCP" handoffs (a task's context written out in full) and by "Review with AI" (no task at all).
public struct PromptHandoffCommand: Sendable, Hashable {
    public var agent: AgentKind
    /// Names the launch script: a task id (`mc_abc123`) or `review-cr_0123456789`.
    public var label: String
    public var directory: URL
    /// The exact prompt, passed as one single-quoted argument.
    public var prompt: String
    public var executable: String
    public var shellCommand: String
}

extension HandoffCommandBuilder {
    /// Largest prompt accepted on the command line.
    public static let maxPromptBytes = 200_000

    /// `cd '<directory>' && <executable> '<prompt>'`. The prompt is quoted as one argument, so nothing in it
    /// (review comments, logs) can become shell syntax.
    public static func promptCommand(
        agent: AgentKind,
        label: String,
        directory: URL,
        prompt: String,
        executable: String? = nil
    ) throws(AgentHandoffError) -> PromptHandoffCommand {
        let path = MergeCuePathsHelper.path(directory)
        guard directory.isFileURL, path.hasPrefix("/") else { throw .invalidPath("directory must be an absolute path") }
        guard !path.unicodeScalars.contains("\u{0}") else { throw .invalidPath("directory contains a NUL byte") }
        let labelCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        guard (1...48).contains(label.count), label.unicodeScalars.allSatisfy(labelCharacters.contains)
        else { throw .invalidPath("label must be 1 to 48 of [a-z0-9_-]") }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .invalidPath("prompt is empty") }
        guard !prompt.unicodeScalars.contains("\u{0}"), prompt.utf8.count <= maxPromptBytes
        else { throw .invalidPath("prompt contains a NUL byte or is longer than \(maxPromptBytes) bytes") }
        let executable = executable ?? agent.executableName
        guard !executable.isEmpty, !executable.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw .invalidPath("agent executable is empty or contains control characters") }
        let shell = "cd \(ShellQuoting.quote(path)) && \(ShellQuoting.quoteIfNeeded(executable)) \(ShellQuoting.quote(prompt))"
        return PromptHandoffCommand(
            agent: agent,
            label: label,
            directory: URL(filePath: path, directoryHint: .isDirectory),
            prompt: prompt,
            executable: executable,
            shellCommand: shell
        )
    }

    /// The prompt command for a detected agent (bare name when on the login `PATH`, absolute path otherwise).
    public static func promptCommand(for agent: DetectedAgent, label: String, directory: URL, prompt: String) throws(AgentHandoffError) -> PromptHandoffCommand {
        try promptCommand(agent: agent.kind, label: label, directory: directory, prompt: prompt, executable: agent.invocation)
    }
}
