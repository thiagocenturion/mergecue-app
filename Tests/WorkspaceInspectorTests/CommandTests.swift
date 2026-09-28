import Foundation
import MergeCueCore
import Testing
@testable import WorkspaceInspector

@Suite("Commands")
struct CommandTests {
    @Test func runsWithoutShellAndReportsExitCode() async throws {
        let sandbox = try GitSandbox()
        let inspector = sandbox.inspector()
        let echo = try await inspector.runCommand(["echo", "hello world"], in: sandbox.root.path, timeout: 10)
        #expect(echo.exitCode == 0)
        #expect(echo.stdout == "hello world\n")
        #expect(echo.durationMs >= 0)
        let failing = try await inspector.runCommand(["/bin/sh", "-c", "echo oops >&2; exit 3"], in: sandbox.root.path, timeout: 10)
        #expect(failing.exitCode == 3)
        #expect(failing.stderr == "oops\n")
        let pwd = try await inspector.runCommand(["/bin/pwd"], in: sandbox.root.path, timeout: 10)
        #expect(pwd.stdout.trimmingCharacters(in: .newlines) == sandbox.root.path)
    }

    @Test func timeoutKillsTheWholeProcessGroup() async throws {
        let sandbox = try GitSandbox()
        let started = Date()
        await #expect(throws: WorkspaceError.timedOut(command: "sh")) {
            // The background grandchild keeps the output pipe open; the group kill must take it down too.
            try await sandbox.inspector().runCommand(["/bin/sh", "-c", "sleep 30 & sleep 30"], in: sandbox.root.path, timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test func gitCommandTimeoutIsReported() async throws {
        let sandbox = try GitSandbox()
        let repo = try sandbox.initRepo("slow")
        // An upload-pack that hangs: `git fetch` from this repo never completes.
        let hanging = sandbox.url("hang.sh")
        try sandbox.write("#!/bin/sh\nsleep 30\n", to: hanging)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hanging.path)
        try sandbox.git(["config", "--global", "remote.hang.uploadpack", hanging.path], in: sandbox.root)
        let bare = sandbox.url("remotes-hang.git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try sandbox.git(["init", "-q", "--bare"], in: bare)
        try sandbox.git(["remote", "add", "hang", bare.path], in: repo)
        let inspector = sandbox.inspector(timeout: 1)
        let started = Date()
        do {
            _ = try await inspector.fetchHead(
                sources: [.init(remoteName: "hang", url: "hang")], refspec: "refs/heads/main",
                localRef: "refs/mergecue/tasks/mc_hang00", in: repo.path
            )
            Issue.record("expected a timeout")
        } catch let error as WorkspaceError {
            if case .timedOut(let command) = error {
                #expect(command.hasPrefix("git fetch"))
            } else {
                Issue.record("unexpected \(error)")
            }
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func outputIsBounded() async throws {
        let sandbox = try GitSandbox()
        let result = try await sandbox.inspector().runCommand(
            ["/bin/sh", "-c", "head -c 3000000 /dev/zero | tr '\\\\0' a"], in: sandbox.root.path, timeout: 30
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.hasSuffix("[output truncated]"))
        #expect(result.stdout.utf8.count < GitWorkspaceInspector.commandOutputLimit + 100)
    }

    @Test func environmentIsSanitizedAndNonInteractive() async throws {
        let sandbox = try GitSandbox()
        var inherited = ProcessInfo.processInfo.environment
        inherited["GIT_DIR"] = "/evil/.git"
        inherited["GIT_WORK_TREE"] = "/evil"
        inherited["GIT_ASKPASS"] = "/evil/askpass"
        inherited["SSH_ASKPASS"] = "/evil/askpass"
        let inspector = GitWorkspaceInspector(
            worktreeRoot: sandbox.worktreeRoot, environmentOverrides: sandbox.environment, inheritedEnvironment: inherited
        )
        let env = try await inspector.runCommand(["/usr/bin/env"], in: sandbox.root.path, timeout: 10).stdout
        let lines = Set(env.split(separator: "\n").map(String.init))
        #expect(!env.contains("/evil"))
        #expect(lines.contains("GIT_TERMINAL_PROMPT=0"))
        #expect(lines.contains("GIT_ASKPASS="))
        #expect(lines.contains("LC_ALL=C"))
        #expect(lines.contains("GIT_PAGER=cat"))
        #expect(lines.contains("GIT_OPTIONAL_LOCKS=0"))
        #expect(lines.contains("HOME=\(sandbox.home.path)"))

        let tty = try await inspector.runCommand(
            ["/bin/sh", "-c", "if (exec 3</dev/tty) 2>/dev/null; then echo tty; else echo notty; fi; read line; echo \"stdin=[$line]\""],
            in: sandbox.root.path, timeout: 10
        )
        #expect(tty.stdout == "notty\nstdin=[]\n")
    }

    @Test func secretsInOutputAreRedacted() async throws {
        let sandbox = try GitSandbox()
        let result = try await sandbox.inspector().runCommand(
            ["echo", "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"], in: sandbox.root.path, timeout: 10
        )
        #expect(!result.stdout.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    @Test func invalidCommandsAreRejected() async throws {
        let sandbox = try GitSandbox()
        let inspector = sandbox.inspector()
        await #expect(throws: WorkspaceError.self) { try await inspector.runCommand([], in: sandbox.root.path, timeout: 1) }
        await #expect(throws: WorkspaceError.self) {
            try await inspector.runCommand(["definitely-not-a-command-xyz"], in: sandbox.root.path, timeout: 1)
        }
        await #expect(throws: WorkspaceError.missingPath(sandbox.url("nope").path)) {
            try await inspector.runCommand(["echo"], in: sandbox.url("nope").path, timeout: 1)
        }
    }

    @Test func missingGitIsReported() async throws {
        let sandbox = try GitSandbox()
        let inspector = GitWorkspaceInspector(
            gitExecutable: URL(fileURLWithPath: "/nonexistent/git"), worktreeRoot: sandbox.worktreeRoot,
            environmentOverrides: sandbox.environment
        )
        await #expect(throws: WorkspaceError.gitUnavailable) {
            try await inspector.inspect(path: sandbox.root.path)
        }
    }
}
