import Foundation
import MergeCueCore

extension GitWorkspaceInspector {
    /// Maximum captured bytes per stream for `runCommand`.
    public static let commandOutputLimit = 1024 * 1024
    static let maxCommandTimeout: TimeInterval = 4 * 60 * 60

    /// Runs `argv` (no shell) in `directory` with the sanitized environment, no controlling terminal and stdin
    /// from `/dev/null`. Output is bounded to `commandOutputLimit` bytes per stream (a truncation marker is
    /// appended) and redacted with `SecretRedactor`. On timeout the whole process group is terminated and
    /// `WorkspaceError.timedOut` is thrown. Callers run this only after explicit user approval.
    public func runCommand(_ argv: [String], in directory: String, timeout: TimeInterval) async throws -> CommandResult {
        guard let command = argv.first, !command.isEmpty else {
            throw WorkspaceError.invalidRequest("empty command")
        }
        let workingDirectory = Self.absolutePath(directory)
        guard Self.pathKind(workingDirectory) == .directory else {
            throw WorkspaceError.missingPath(workingDirectory)
        }
        guard let executable = resolveExecutable(command) else {
            throw WorkspaceError.invalidRequest("command not found: \(command)")
        }
        let effectiveTimeout = timeout.isFinite && timeout > 0 ? min(timeout, Self.maxCommandTimeout) : commandTimeout
        let spec = ProcessSpec(
            executable: executable,
            arguments: Array(argv.dropFirst()),
            workingDirectory: workingDirectory,
            environment: environment,
            stdin: nil,
            timeout: effectiveTimeout,
            maxOutputBytes: Self.commandOutputLimit
        )
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(spec)
        } catch {
            throw WorkspaceError.invalidRequest("could not start \(command): \(error)")
        }
        try Task.checkCancellation()
        if output.timedOut {
            throw WorkspaceError.timedOut(command: (command as NSString).lastPathComponent)
        }
        let marker = "\n… [output truncated]"
        return CommandResult(
            exitCode: output.exitCode,
            stdout: SecretRedactor.redact(output.stdoutText) + (output.stdoutTruncated ? marker : ""),
            stderr: SecretRedactor.redact(output.stderrText) + (output.stderrTruncated ? marker : ""),
            durationMs: output.durationMs
        )
    }

    /// An absolute/relative path is used as given; a bare name is searched in the sanitized `PATH`.
    func resolveExecutable(_ command: String) -> String? {
        let fileManager = FileManager.default
        if command.contains("/") {
            let path = Self.absolutePath(command)
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }
        let searchPath = environment["PATH"] ?? SanitizedEnvironment.defaultPath
        for directory in searchPath.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = (String(directory) as NSString).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate), Self.pathKind(candidate) == .file {
                return candidate
            }
        }
        return nil
    }
}
