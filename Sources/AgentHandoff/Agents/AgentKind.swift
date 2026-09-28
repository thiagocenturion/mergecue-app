import Foundation
import MergeCueCore

/// Coding agents MergeCue can hand tasks to.
public enum AgentKind: String, Sendable, Hashable, Codable, CaseIterable {
    case claudeCode = "claude_code"
    case codex

    /// User-facing product name.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        }
    }

    /// Name of the CLI executable on `PATH`.
    public var executableName: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    /// Short slug used in file names (backups, handoff scripts).
    public var slug: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }
}

/// Where an agent executable was found.
public enum AgentDetectionSource: String, Sendable, Hashable, Codable {
    /// `command -v <name>` in the user's login shell — the binary the user gets when typing the name in Terminal.
    case loginShellPath = "login_shell_path"
    /// A well-known install location that is not necessarily on the login shell's `PATH`.
    case knownLocation = "known_location"
}

/// An agent CLI found on this Mac.
public struct DetectedAgent: Sendable, Hashable, Codable {
    public var kind: AgentKind
    /// The executable as found (not symlink-resolved), e.g. `~/.local/bin/claude`.
    public var executableURL: URL
    /// Parsed from `<executable> --version` (`2.1.283`, `0.153.4`), nil when it could not be determined.
    public var version: String?
    public var source: AgentDetectionSource

    public init(kind: AgentKind, executableURL: URL, version: String?, source: AgentDetectionSource) {
        self.kind = kind
        self.executableURL = executableURL
        self.version = version
        self.source = source
    }

    /// POSIX path of the executable.
    public var executablePath: String { MergeCuePathsHelper.path(executableURL) }

    /// How a Terminal command should invoke the agent: the bare name when the login shell resolves it,
    /// otherwise the absolute path.
    public var invocation: String {
        source == .loginShellPath ? kind.executableName : executablePath
    }
}

/// Errors shared by the handoff module.
public enum AgentHandoffError: Error, Sendable, Equatable, LocalizedError {
    case invalidTaskID(String)
    case invalidPath(String)
    case agentNotFound(AgentKind)

    public var errorDescription: String? {
        switch self {
        case .invalidTaskID(let raw): "“\(raw)” is not a valid MergeCue task id."
        case .invalidPath(let detail): "Invalid path: \(detail)."
        case .agentNotFound(let kind): "\(kind.displayName) was not found on this Mac."
        }
    }
}

enum MergeCuePathsHelper {
    /// POSIX path without trailing slash.
    static func path(_ url: URL) -> String {
        MergeCuePaths.fileSystemPath(url)
    }

    /// Validates an absolute path with no control characters (NUL, newline, …) — used for paths we embed in
    /// agent configuration.
    static func validatedAbsolutePath(_ url: URL, what: String) throws(AgentHandoffError) -> String {
        guard url.isFileURL else { throw .invalidPath("\(what) must be a file URL") }
        let path = path(url)
        guard path.hasPrefix("/") else { throw .invalidPath("\(what) must be absolute") }
        guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw .invalidPath("\(what) contains control characters")
        }
        return path
    }
}
