import Darwin
import Foundation
import MergeCueCore

/// A config file copied before a change.
public struct BackedUpFile: Sendable, Hashable, Codable {
    public var original: URL
    /// The copy, nil when the original did not exist yet.
    public var copy: URL?
    public var existed: Bool

    public init(original: URL, copy: URL?, existed: Bool) {
        self.original = original
        self.copy = copy
        self.existed = existed
    }
}

/// Where a plan's files were backed up (`manifest.json` describes the change).
public struct RegistrationBackup: Sendable, Hashable, Codable {
    public var directory: URL
    public var files: [BackedUpFile]
    public var manifest: URL
}

/// Result of `register` / `unregister`.
public struct RegistrationOutcome: Sendable, Hashable {
    public var plan: MCPRegistrationPlan
    /// False when the agent was already in the requested state (nothing was run or backed up).
    public var changed: Bool
    public var backup: RegistrationBackup?
    /// Verified status after the change.
    public var status: AgentRegistrationStatus
    /// Redacted CLI output.
    public var commandOutput: String
}

/// Errors from `AgentRegistrar`.
public enum AgentRegistrarError: Error, Sendable, Equatable, LocalizedError {
    case consentDoesNotMatchPlan
    case consentExpired
    case consentAlreadyUsed
    case wrongAction(expected: RegistrationAction)
    case statusUnavailable(String)
    /// Another `mergecue` entry exists with a different command; unregister it first.
    case conflictingRegistration(RegisteredMCPServer)
    case backupFailed(String)
    case commandFailed(exitCode: Int32, output: String)
    case commandTimedOut
    case verificationFailed(AgentRegistrationStatus)

    public var errorDescription: String? {
        switch self {
        case .consentDoesNotMatchPlan: "The confirmation does not match this change. Review it again."
        case .consentExpired: "The confirmation expired. Review the change again."
        case .consentAlreadyUsed: "This confirmation was already used."
        case .wrongAction(let expected): "This plan is not a \(expected.rawValue) plan."
        case .statusUnavailable(let detail): "Could not read the current MCP configuration: \(detail)"
        case .conflictingRegistration(let server): "A different “mergecue” MCP server is already configured (\(server.command))."
        case .backupFailed(let detail): "Backup failed, nothing was changed: \(detail)"
        case .commandFailed(let code, let output): "The agent CLI exited with \(code). \(output)"
        case .commandTimedOut: "The agent CLI did not finish in time."
        case .verificationFailed: "The change could not be verified."
        }
    }
}

/// Applies user-approved MCP registration plans through each agent's own CLI, after backing up the config
/// files; reads registration status without modifying anything.
public actor AgentRegistrar {
    public struct Configuration: Sendable {
        /// Base environment for CLI runs (plan `configEnvironment` is applied on top).
        public var environment: [String: String]
        public var commandTimeout: TimeInterval
        /// `claude mcp get` health-checks the server, so allow a little longer.
        public var statusTimeout: TimeInterval

        public init(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            commandTimeout: TimeInterval = 30,
            statusTimeout: TimeInterval = 45
        ) {
            self.environment = environment
            self.commandTimeout = commandTimeout
            self.statusTimeout = statusTimeout
        }
    }

    private let paths: MergeCuePaths
    private let configuration: Configuration
    private let runner: any ProcessRunning
    private let now: @Sendable () -> Date
    private var usedConsents = Set<UUID>()

    public init(
        paths: MergeCuePaths,
        configuration: Configuration = Configuration(),
        runner: any ProcessRunning = ProcessRunner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.configuration = configuration
        self.runner = runner
        self.now = now
    }

    // MARK: Status (read-only)

    /// `claude mcp get mergecue` / `codex mcp get mergecue --json`. Never modifies configuration (Claude's `get`
    /// health-checks the server by launching it).
    public func registrationStatus(_ agent: AgentKind, executable: URL, configEnvironment: [String: String] = [:]) async -> AgentRegistrationStatus {
        let arguments = Self.statusArguments(for: agent)
        do {
            let result = try await runner.run(
                executable,
                arguments: arguments,
                environment: environment(for: executable, overrides: configEnvironment),
                currentDirectory: homeDirectory(overrides: configEnvironment),
                timeout: configuration.statusTimeout
            )
            return RegistrationStatusParser.parse(agent: agent, result: result)
        } catch {
            return .unknown(SecretRedactor.redact(error.localizedDescription))
        }
    }

    public func registrationStatus(_ agent: DetectedAgent) async -> AgentRegistrationStatus {
        await registrationStatus(agent.kind, executable: agent.executableURL)
    }

    /// Arguments after the executable for the status query.
    public static func statusArguments(for agent: AgentKind) -> [String] {
        switch agent {
        case .claudeCode: ["mcp", "get", MCPRegistrationPlan.serverName]
        case .codex: ["mcp", "get", MCPRegistrationPlan.serverName, "--json"]
        }
    }

    // MARK: Changes (consent + backup)

    /// Registers the helper: validates consent, skips if already registered to the same helper, refuses to
    /// overwrite a different `mergecue` entry, backs up the config file(s), runs the CLI and verifies via status.
    public func register(_ plan: MCPRegistrationPlan, consent: RegistrationConsent) async throws(AgentRegistrarError) -> RegistrationOutcome {
        guard plan.action == .register else { throw .wrongAction(expected: .register) }
        try consume(consent, for: plan)

        let before = await registrationStatus(plan.agent, executable: plan.executable, configEnvironment: plan.configEnvironment)
        switch before {
        case .registered(let server) where server.matches(helper: plan.helper, arguments: plan.helperArguments):
            return RegistrationOutcome(plan: plan, changed: false, backup: nil, status: before, commandOutput: "")
        case .registered(let server):
            throw .conflictingRegistration(server)
        case .unknown(let detail):
            throw .statusUnavailable(detail)
        case .notRegistered:
            break
        }

        let (backup, output) = try await apply(plan)
        let after = await registrationStatus(plan.agent, executable: plan.executable, configEnvironment: plan.configEnvironment)
        guard after.isRegistered(helper: plan.helper, arguments: plan.helperArguments) else { throw .verificationFailed(after) }
        return RegistrationOutcome(plan: plan, changed: true, backup: backup, status: after, commandOutput: output)
    }

    /// Removes the `mergecue` entry (consent + backup + verification). No-op when it is not registered.
    public func unregister(_ plan: MCPRegistrationPlan, consent: RegistrationConsent) async throws(AgentRegistrarError) -> RegistrationOutcome {
        guard plan.action == .unregister else { throw .wrongAction(expected: .unregister) }
        try consume(consent, for: plan)

        let before = await registrationStatus(plan.agent, executable: plan.executable, configEnvironment: plan.configEnvironment)
        switch before {
        case .notRegistered:
            return RegistrationOutcome(plan: plan, changed: false, backup: nil, status: before, commandOutput: "")
        case .unknown(let detail):
            throw .statusUnavailable(detail)
        case .registered:
            break
        }

        let (backup, output) = try await apply(plan)
        let after = await registrationStatus(plan.agent, executable: plan.executable, configEnvironment: plan.configEnvironment)
        guard after == .notRegistered else { throw .verificationFailed(after) }
        return RegistrationOutcome(plan: plan, changed: true, backup: backup, status: after, commandOutput: output)
    }

    /// Temporary, non-persistent agent arguments (see `SessionOnlyMCPConfig`).
    public nonisolated static func sessionOnlyConfig(
        agent: AgentKind,
        helper: URL,
        helperArguments: [String] = [],
        directory: URL
    ) throws(AgentHandoffError) -> SessionOnlyMCPConfig {
        try SessionOnlyMCPConfig.make(agent: agent, helper: helper, helperArguments: helperArguments, directory: directory)
    }

    // MARK: Internals

    private func consume(_ consent: RegistrationConsent, for plan: MCPRegistrationPlan) throws(AgentRegistrarError) {
        guard !usedConsents.contains(consent.id) else { throw .consentAlreadyUsed }
        guard consent.planDigest == plan.digest, consent.action == plan.action, consent.agent == plan.agent else {
            throw .consentDoesNotMatchPlan
        }
        guard consent.covers(plan, now: now()) else { throw .consentExpired }
        usedConsents.insert(consent.id)
    }

    private func apply(_ plan: MCPRegistrationPlan) async throws(AgentRegistrarError) -> (RegistrationBackup, String) {
        let backup = try makeBackup(for: plan)
        let result: ProcessResult
        do {
            result = try await runner.run(
                plan.executable,
                arguments: plan.arguments,
                environment: environment(for: plan.executable, overrides: plan.configEnvironment),
                currentDirectory: homeDirectory(overrides: plan.configEnvironment),
                timeout: configuration.commandTimeout
            )
        } catch {
            throw .commandFailed(exitCode: -1, output: SecretRedactor.redact(error.localizedDescription))
        }
        let output = BoundedText.truncate(
            SecretRedactor.redact((result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)),
            maxBytes: 4096
        ).text
        if result.timedOut { throw .commandTimedOut }
        guard result.exitCode == 0 else { throw .commandFailed(exitCode: result.exitCode, output: output) }
        return (backup, output)
    }

    /// Copies every touched file (following symlinks) into a fresh 0700 backup directory with a manifest.
    private func makeBackup(for plan: MCPRegistrationPlan) throws(AgentRegistrarError) -> RegistrationBackup {
        do {
            let directory = try createUniqueDirectory(plan.backupDirectory)
            var files: [BackedUpFile] = []
            for (index, original) in plan.filesTouched.enumerated() {
                let path = MergeCuePaths.fileSystemPath(original)
                guard FileManager.default.fileExists(atPath: path) else {
                    files.append(BackedUpFile(original: original, copy: nil, existed: false))
                    continue
                }
                let data = try Data(contentsOf: URL(filePath: path).resolvingSymlinksInPath())
                let copy = directory.appending(path: "\(index)-\(original.lastPathComponent)")
                try writePrivate(data, to: copy)
                files.append(BackedUpFile(original: original, copy: copy, existed: true))
            }
            let manifest = directory.appending(path: "manifest.json")
            let record = BackupManifest(
                agent: plan.agent,
                action: plan.action,
                command: plan.argv,
                createdAt: now(),
                files: files
            )
            try writePrivate(try MergeCueCoding.wireEncoder().encode(record), to: manifest)
            return RegistrationBackup(directory: directory, files: files, manifest: manifest)
        } catch let error as AgentRegistrarError {
            throw error
        } catch {
            throw .backupFailed(SecretRedactor.redact(error.localizedDescription))
        }
    }

    private func createUniqueDirectory(_ preferred: URL) throws -> URL {
        let parent = MergeCuePaths.fileSystemPath(preferred.deletingLastPathComponent())
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(parent, 0o700)
        let base = MergeCuePaths.fileSystemPath(preferred)
        for attempt in 0..<1000 {
            let candidate = attempt == 0 ? base : "\(base)-\(attempt)"
            if mkdir(candidate, 0o700) == 0 { return URL(filePath: candidate, directoryHint: .isDirectory) }
            guard errno == EEXIST else { throw AgentRegistrarError.backupFailed(String(cString: strerror(errno))) }
        }
        throw AgentRegistrarError.backupFailed("could not create a unique backup directory")
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let path = MergeCuePaths.fileSystemPath(url)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentRegistrarError.backupFailed(String(cString: strerror(errno))) }
        defer { close(fd) }
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { throw AgentRegistrarError.backupFailed(String(cString: strerror(errno))) }
            offset += written
        }
        guard fsync(fd) == 0 else { throw AgentRegistrarError.backupFailed(String(cString: strerror(errno))) }
    }

    private func environment(for executable: URL, overrides: [String: String]) -> [String: String] {
        AgentDetector.environment(configuration.environment.merging(overrides) { $1 }, prependingDirectoryOf: executable)
    }

    private func homeDirectory(overrides: [String: String]) -> URL {
        MCPRegistrationPlan.homeDirectory(configuration.environment.merging(overrides) { $1 })
    }
}

private struct BackupManifest: Encodable {
    var agent: AgentKind
    var action: RegistrationAction
    var command: [String]
    var createdAt: Date
    var files: [BackedUpFile]

    enum CodingKeys: String, CodingKey {
        case agent, action, command, files
        case createdAt = "created_at"
    }
}
