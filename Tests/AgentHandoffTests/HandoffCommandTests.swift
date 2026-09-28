import Foundation
import MergeCueCore
import Testing
@testable import AgentHandoff

@Suite("Handoff command")
struct HandoffCommandTests {
    let taskID = TaskID(rawValue: "mc_8421ab")!

    @Test func exactPrompt() {
        #expect(HandoffCommandBuilder.prompt(for: taskID)
            == "Work on MergeCue task mc_8421ab. Use MergeCue MCP for context and status updates. Work only in the designated checkout. Stop before publishing anything.")
    }

    @Test func commandsPerAgent() throws {
        let worktree = URL(filePath: "/Users/tester/Library/Application Support/MergeCue/worktrees/mc_8421ab")
        let prompt = "'Work on MergeCue task mc_8421ab. Use MergeCue MCP for context and status updates. Work only in the designated checkout. Stop before publishing anything.'"
        let claude = try HandoffCommandBuilder.command(agent: .claudeCode, taskID: taskID, worktree: worktree)
        #expect(claude.shellCommand == "cd '/Users/tester/Library/Application Support/MergeCue/worktrees/mc_8421ab' && claude \(prompt)")
        let codex = try HandoffCommandBuilder.command(agent: .codex, taskID: taskID, worktree: worktree)
        #expect(codex.shellCommand == "cd '/Users/tester/Library/Application Support/MergeCue/worktrees/mc_8421ab' && codex \(prompt)")
        let absolute = try HandoffCommandBuilder.command(
            agent: .codex, taskID: taskID, worktree: worktree, executable: "/Applications/ChatGPT.app/Contents/Resources/codex"
        )
        #expect(absolute.shellCommand.contains("&& /Applications/ChatGPT.app/Contents/Resources/codex '"))
        let spaced = try HandoffCommandBuilder.command(agent: .claudeCode, taskID: taskID, worktree: worktree, executable: "/Users/a b/claude")
        #expect(spaced.shellCommand.contains("&& '/Users/a b/claude' '"))
    }

    @Test func detectedAgentInvocation() throws {
        let worktree = URL(filePath: "/tmp/wt")
        let onPath = DetectedAgent(kind: .claudeCode, executableURL: URL(filePath: "/Users/t/.local/bin/claude"), version: "2.1.0", source: .loginShellPath)
        #expect(try HandoffCommandBuilder.command(for: onPath, taskID: taskID, worktree: worktree).shellCommand.hasPrefix("cd '/tmp/wt' && claude '"))
        let bundled = DetectedAgent(kind: .codex, executableURL: URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex"), version: nil, source: .knownLocation)
        #expect(try HandoffCommandBuilder.command(for: bundled, taskID: taskID, worktree: worktree).shellCommand
            .hasPrefix("cd '/tmp/wt' && /Applications/ChatGPT.app/Contents/Resources/codex '"))
    }

    @Test(arguments: ["", "mc_", "mc_abc12", "mc_abc1234", "mc_ABC123", "MC_abc123", "mc_abc12'", "mc_abc 12", "mc_abc123; rm -rf ~", "../mc_abc123", "mc_ab\n123"])
    func invalidTaskIDsAreRejected(raw: String) {
        #expect(throws: AgentHandoffError.invalidTaskID(raw)) {
            _ = try HandoffCommandBuilder.command(agent: .claudeCode, rawTaskID: raw, worktree: URL(filePath: "/tmp"))
        }
    }

    @Test func validRawTaskID() throws {
        let command = try HandoffCommandBuilder.command(agent: .codex, rawTaskID: "mc_0z9y8x", worktree: URL(filePath: "/tmp"))
        #expect(command.taskID.rawValue == "mc_0z9y8x")
    }

    @Test func relativeWorktreeIsRejected() {
        #expect(throws: AgentHandoffError.self) {
            _ = try HandoffCommandBuilder.command(agent: .codex, taskID: taskID, worktree: URL(string: "https://example.com/x")!)
        }
        #expect(throws: AgentHandoffError.self) {
            _ = try HandoffCommandBuilder.command(agent: .codex, taskID: taskID, worktree: URL(filePath: "/tmp"), executable: "evil\nrm -rf ~")
        }
    }

    @Test func quoting() {
        #expect(ShellQuoting.quote("") == "''")
        #expect(ShellQuoting.quote("a'b") == #"'a'\''b'"#)
        #expect(ShellQuoting.quote("'") == #"''\'''"#)
        #expect(ShellQuoting.quoteIfNeeded("/usr/bin/claude") == "/usr/bin/claude")
        #expect(ShellQuoting.quoteIfNeeded("FOO=bar") == "'FOO=bar'")
        #expect(ShellQuoting.quoteIfNeeded("~/x") == "'~/x'")
        #expect(ShellQuoting.join(["a b", "c"]) == "'a b' c")
    }

    /// Runs the generated command through real shells with a fake agent that prints its working directory and
    /// argv, in directories with hostile names. Nothing may be interpreted.
    @Test(arguments: ["/bin/sh", "/bin/zsh", "/bin/bash"])
    func adversarialWorktreePathsSurviveRealShells(shell: String) async throws {
        let root = try makeTempDirectory("adversarial")
        let agent = try writeScript(root.appending(path: "bin/fake agent"), #"""
            pwd > "$OUT"
            printf '%s' "$1" > "$OUT.arg"
            printf '%s' "$#" > "$OUT.count"
            """#)
        let names = [
            "it's here",
            "'; touch PWNED; echo '",
            "$(touch PWNED)",
            "`touch PWNED`",
            "a\\b\\\\c",
            "dollar $HOME and !bang",
            "new\nline",
            "semi;colon && pipe | amp &",
            "quote\"double\"",
            "émoji 🚀 ünïcode",
            "-dash-start",
            "''''",
        ]
        for (index, name) in names.enumerated() {
            let worktree = root.appending(path: "\(index)-\(name)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            let command = try HandoffCommandBuilder.command(
                agent: .claudeCode, taskID: taskID, worktree: worktree, executable: MergeCuePaths.fileSystemPath(agent)
            )
            let out = root.appending(path: "out-\(index)")
            let result = try await ProcessRunner().run(
                URL(filePath: shell),
                arguments: ["-c", command.shellCommand],
                environment: ["PATH": "/usr/bin:/bin", "OUT": MergeCuePaths.fileSystemPath(out), "HOME": MergeCuePaths.fileSystemPath(root)],
                currentDirectory: root,
                timeout: 10
            )
            #expect(result.exitCode == 0, "shell \(shell) failed for \(name.debugDescription): \(result.stderr)")
            let pwd = try readText(out).trimmingCharacters(in: .newlines)
            #expect(pwd == MergeCuePaths.fileSystemPath(worktree), "wrong cwd for \(name.debugDescription)")
            #expect(try readText(URL(filePath: MergeCuePaths.fileSystemPath(out) + ".arg")) == HandoffCommandBuilder.prompt(for: taskID))
            #expect(try readText(URL(filePath: MergeCuePaths.fileSystemPath(out) + ".count")) == "1")
        }
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: MergeCuePaths.fileSystemPath(root))
        #expect(!leftovers.contains { $0.hasSuffix("PWNED") })
    }
}
