import Foundation
import MergeCueCore

/// `git`-backed implementation of `WorkspaceInspecting`.
///
/// Safety guarantees (see `docs/ARCHITECTURE.md` §2.8 and PLAN §6):
/// - Never modifies the user's working tree, index, branches or stash. The only writes into a user's repository
///   are: objects + the private ref `refs/mergecue/tasks/<task id>` from fetching a change request head, and the
///   linked-worktree metadata `git worktree add` keeps in `.git/worktrees/<task id>`. `applyPatch` — an explicit,
///   user-approved import — writes working-tree files only (`git apply` without `--index`: nothing is staged,
///   committed or stashed), and only into a clean, non-GitButler checkout whose HEAD matches.
/// - GitButler-managed checkouts get no worktrees and no fetched refs: an independent clone is created instead.
/// - Every child runs without a shell and without a controlling terminal, with a sanitized environment (no
///   `GIT_*` leakage, prompts/askpass/pagers/editors disabled, `LC_ALL=C`, `GIT_OPTIONAL_LOCKS=0`), repository
///   hooks disabled (`core.hooksPath=/dev/null`), a timeout that kills the whole process group, and bounded output.
/// - Remote access uses the user's own credential helpers / SSH agent; MergeCue never injects tokens. Remote URLs
///   and git stderr are sanitized/redacted before they appear in results or errors.
/// - Only paths under `worktreeRoot` are ever deleted.
public struct GitWorkspaceInspector: WorkspaceInspecting {
    /// The git executable (default `/usr/bin/git`).
    public let gitExecutable: URL
    /// Root for isolated worktrees/clones (usually `MergeCuePaths.worktrees`). Destinations must be inside it.
    public let worktreeRoot: URL
    /// Timeout for local git commands.
    public let commandTimeout: TimeInterval
    /// Timeout for network operations (fetch, clone).
    public let networkTimeout: TimeInterval
    /// Maximum directory depth `suggestMappings` descends below each search root.
    public let maxSearchDepth: Int

    let environment: [String: String]

    /// - Parameters:
    ///   - environmentOverrides: applied after sanitizing (tests set a hermetic `HOME`, `GIT_CONFIG_GLOBAL`, …).
    ///   - inheritedEnvironment: the base environment before sanitizing (defaults to this process's).
    public init(
        gitExecutable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        worktreeRoot: URL,
        environmentOverrides: [String: String] = [:],
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        commandTimeout: TimeInterval = 60,
        networkTimeout: TimeInterval = 600,
        maxSearchDepth: Int = 4
    ) {
        self.gitExecutable = gitExecutable
        self.worktreeRoot = worktreeRoot
        self.commandTimeout = commandTimeout
        self.networkTimeout = networkTimeout
        self.maxSearchDepth = maxSearchDepth
        self.environment = SanitizedEnvironment.make(inherited: inheritedEnvironment, overrides: environmentOverrides)
    }

    /// Convenience: worktrees under `MergeCuePaths.worktrees`.
    public init(paths: MergeCuePaths) {
        self.init(worktreeRoot: paths.worktrees)
    }

    // MARK: Limits

    static let defaultMaxOutput = 8 * 1024 * 1024
    static let maxDirtyPaths = 500
    static let maxErrorBytes = 2_000

    /// `-c` options prepended to every git invocation.
    static let safetyConfig: [String] = [
        "core.hooksPath=/dev/null",       // never run repository hooks (post-checkout etc.)
        "core.fsmonitor=false",           // never start an fsmonitor daemon / configured command
        "core.pager=cat",
        "color.ui=false",
        "core.quotePath=false",
        "gc.auto=0",                      // no auto-gc in the user's repository
        "maintenance.auto=false",
        "fetch.writeCommitGraph=false",
        "advice.detachedHead=false",
        "protocol.ext.allow=never",       // no `ext::` transports (arbitrary commands)
        "submodule.recurse=false",
    ]
}

// MARK: - Running git

struct GitOutput: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var stdoutTruncated: Bool
    var succeeded: Bool { exitCode == 0 }
    var trimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension GitWorkspaceInspector {
    /// Runs `git <safety -c options> <arguments>` in `directory`. Throws `timedOut`, `gitUnavailable` or
    /// `CancellationError`; a non-zero exit is returned, not thrown (see `gitChecked`).
    func git(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval? = nil,
        stdin: Data? = nil,
        extraEnvironment: [String: String] = [:],
        maxOutputBytes: Int = defaultMaxOutput
    ) async throws -> GitOutput {
        var env = environment
        for (key, value) in extraEnvironment { env[key] = value }
        let config = Self.safetyConfig.flatMap { ["-c", $0] }
        let spec = ProcessSpec(
            executable: gitExecutable.path,
            arguments: ["--no-pager"] + config + arguments,
            workingDirectory: directory,
            environment: env,
            stdin: stdin,
            timeout: timeout ?? commandTimeout,
            maxOutputBytes: maxOutputBytes
        )
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(spec)
        } catch ProcessRunnerError.spawnFailed(_, let code) where code == ENOENT || code == EACCES {
            throw WorkspaceError.gitUnavailable
        } catch let error as ProcessRunnerError {
            throw WorkspaceError.gitFailed(command: Self.describe(arguments), exitCode: -1, stderr: "\(error)")
        }
        try Task.checkCancellation()
        if output.timedOut {
            throw WorkspaceError.timedOut(command: "git " + Self.describe(arguments))
        }
        return GitOutput(
            exitCode: output.exitCode,
            stdout: output.stdoutText,
            stderr: output.stderrText,
            stdoutTruncated: output.stdoutTruncated
        )
    }

    /// Like `git(_:in:)` but throws `WorkspaceError.gitFailed` (with redacted, bounded stderr) on a non-zero exit.
    @discardableResult
    func gitChecked(
        _ arguments: [String],
        in directory: String,
        timeout: TimeInterval? = nil,
        stdin: Data? = nil,
        extraEnvironment: [String: String] = [:],
        maxOutputBytes: Int = defaultMaxOutput
    ) async throws -> GitOutput {
        let output = try await git(
            arguments, in: directory, timeout: timeout, stdin: stdin,
            extraEnvironment: extraEnvironment, maxOutputBytes: maxOutputBytes
        )
        guard output.succeeded else {
            throw WorkspaceError.gitFailed(
                command: Self.describe(arguments),
                exitCode: output.exitCode,
                stderr: Self.cleanMessage(output.stderr)
            )
        }
        return output
    }

    /// The subcommand plus its non-URL arguments, for error messages (URLs are sanitized).
    static func describe(_ arguments: [String]) -> String {
        arguments.prefix(4).map { argument in
            argument.contains("://") || argument.contains("@") ? CanonicalRemote.sanitizedURL(argument) : argument
        }.joined(separator: " ")
    }

    /// Redacts secrets (URLs with userinfo, tokens) and bounds git's stderr for display.
    static func cleanMessage(_ text: String, maxBytes: Int = maxErrorBytes) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { line -> String in
            line.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
                word.contains("://") ? CanonicalRemote.sanitizedURL(String(word)) : String(word)
            }.joined(separator: " ")
        }
        let redacted = SecretRedactor.redact(lines.joined(separator: "\n"))
        return BoundedText.truncate(redacted, maxBytes: maxBytes).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Paths

extension GitWorkspaceInspector {
    /// Expands `~`, makes `path` absolute and removes `.`/`..`/empty components lexically. Unlike
    /// `NSString.standardizingPath` it never rewrites `/private/var` to `/var`, and it resolves no symlinks.
    static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : FileManager.default.currentDirectoryPath + "/" + expanded
        var components: [Substring] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// `realpath(3)` of the longest existing prefix of `path`, with the remaining components appended.
    /// (Foundation's `resolvingSymlinksInPath` strips `/private`, which breaks comparisons with git's output.)
    static func canonicalPath(_ path: String) -> String {
        var existing = absolutePath(path)
        var remainder: [String] = []
        while true {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                var result = String(cString: resolved)
                for component in remainder.reversed() {
                    result = (result as NSString).appendingPathComponent(component)
                }
                return result
            }
            let parent = (existing as NSString).deletingLastPathComponent
            if parent == existing || parent.isEmpty { return absolutePath(path) }
            remainder.append((existing as NSString).lastPathComponent)
            existing = parent
        }
    }

    /// Whether `path` is strictly inside `root` (after resolving symlinks).
    static func isStrictlyInside(_ path: String, root: String) -> Bool {
        let child = canonicalPath(path)
        let parent = canonicalPath(root)
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(prefix) && child.count > prefix.count
    }

    static func isInsideOrEqual(_ path: String, root: String) -> Bool {
        canonicalPath(path) == canonicalPath(root) || isStrictlyInside(path, root: root)
    }

    enum PathKind { case missing, file, directory }

    static func pathKind(_ path: String) -> PathKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? .directory : .file
    }

    /// Full 40/64-hex object ids (or abbreviations of at least 7).
    static func isHexObjectID(_ value: String) -> Bool {
        (7...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }

    static func sameCommit(_ a: String, _ b: String) -> Bool {
        let lhs = a.lowercased(), rhs = b.lowercased()
        return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }
}
