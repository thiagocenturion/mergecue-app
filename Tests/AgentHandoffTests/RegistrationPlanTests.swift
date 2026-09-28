import Foundation
import MergeCueCore
import Testing
@testable import AgentHandoff

@Suite("MCP registration plans")
struct RegistrationPlanTests {
    let paths = MergeCuePaths(root: URL(filePath: "/tmp/mc-home", directoryHint: .isDirectory))
    let helper = URL(filePath: "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp")
    let claude = URL(filePath: "/Users/tester/.local/bin/claude")
    let codex = URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex")
    let env = ["HOME": "/Users/tester", "PATH": "/usr/bin", "SECRET_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789"]

    @Test func claudeRegistrationArgvSnippetFilesAndBackup() throws {
        let plan = try MCPRegistrationPlan.register(agent: .claudeCode, executable: claude, helper: helper, paths: paths, environment: env, now: fixedNow)
        #expect(plan.action == .register)
        #expect(plan.argv == [
            "/Users/tester/.local/bin/claude", "mcp", "add", "--scope", "user", "mergecue", "--",
            "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp",
        ])
        #expect(plan.displayCommand == "/Users/tester/.local/bin/claude mcp add --scope user mergecue -- /Applications/MergeCue.app/Contents/MacOS/mergecue-mcp")
        #expect(plan.filesTouched.map(MergeCuePaths.fileSystemPath) == ["/Users/tester/.claude.json"])
        #expect(MergeCuePaths.fileSystemPath(plan.backupDirectory) == "/tmp/mc-home/backups/claude-20260304T050607Z")
        #expect(plan.configSnippet == """
            {
              "mcpServers": {
                "mergecue": {
                  "type": "stdio",
                  "command": "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp",
                  "args": [],
                  "env": {}
                }
              }
            }
            """)
        _ = try JSONDecoder().decode(JSONValue.self, from: Data(plan.configSnippet.utf8))
        // Only config-location variables travel with the plan — never the rest of the environment.
        #expect(plan.configEnvironment == ["HOME": "/Users/tester"])
    }

    @Test func codexRegistrationArgvSnippetAndFiles() throws {
        let plan = try MCPRegistrationPlan.register(agent: .codex, executable: codex, helper: helper, paths: paths, environment: env, now: fixedNow)
        #expect(plan.arguments == ["mcp", "add", "mergecue", "--", "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp"])
        #expect(plan.filesTouched.map(MergeCuePaths.fileSystemPath) == ["/Users/tester/.codex/config.toml"])
        #expect(plan.configSnippet == """
            [mcp_servers.mergecue]
            command = "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp"
            """)
        #expect(MergeCuePaths.fileSystemPath(plan.backupDirectory) == "/tmp/mc-home/backups/codex-20260304T050607Z")
    }

    @Test func configDirectoryOverridesAreHonoured() throws {
        let custom = env.merging(["CLAUDE_CONFIG_DIR": "/tmp/claude-cfg", "CODEX_HOME": "/tmp/codex-home"]) { $1 }
        let claudePlan = try MCPRegistrationPlan.register(agent: .claudeCode, executable: claude, helper: helper, paths: paths, environment: custom)
        #expect(claudePlan.filesTouched.map(MergeCuePaths.fileSystemPath) == ["/tmp/claude-cfg/.claude.json"])
        #expect(claudePlan.configEnvironment == ["HOME": "/Users/tester", "CLAUDE_CONFIG_DIR": "/tmp/claude-cfg"])
        let codexPlan = try MCPRegistrationPlan.register(agent: .codex, executable: codex, helper: helper, paths: paths, environment: custom)
        #expect(codexPlan.filesTouched.map(MergeCuePaths.fileSystemPath) == ["/tmp/codex-home/config.toml"])
        #expect(codexPlan.configEnvironment == ["HOME": "/Users/tester", "CODEX_HOME": "/tmp/codex-home"])
    }

    @Test func unregisterArgv() throws {
        let claudePlan = try MCPRegistrationPlan.unregister(agent: .claudeCode, executable: claude, helper: helper, paths: paths, environment: env)
        #expect(claudePlan.action == .unregister)
        #expect(claudePlan.arguments == ["mcp", "remove", "--scope", "user", "mergecue"])
        let codexPlan = try MCPRegistrationPlan.unregister(agent: .codex, executable: codex, helper: helper, paths: paths, environment: env)
        #expect(codexPlan.arguments == ["mcp", "remove", "mergecue"])
        #expect(codexPlan.filesTouched == (try MCPRegistrationPlan.register(agent: .codex, executable: codex, helper: helper, paths: paths, environment: env)).filesTouched)
    }

    @Test func helperPathWithSpacesAndQuotesIsOneArgument() throws {
        let odd = URL(filePath: "/Users/tester/My Apps/Merge'Cue \"β\".app/Contents/MacOS/mergecue-mcp")
        let plan = try MCPRegistrationPlan.register(agent: .codex, executable: codex, helper: odd, paths: paths, environment: env)
        #expect(plan.arguments.last == "/Users/tester/My Apps/Merge'Cue \"β\".app/Contents/MacOS/mergecue-mcp")
        #expect(plan.displayCommand.hasSuffix(#"-- '/Users/tester/My Apps/Merge'\''Cue "β".app/Contents/MacOS/mergecue-mcp'"#))
        #expect(plan.configSnippet.contains(#"command = "/Users/tester/My Apps/Merge'Cue \"β\".app/Contents/MacOS/mergecue-mcp""#))
    }

    @Test func invalidHelperPathsAreRejected() {
        #expect(throws: AgentHandoffError.self) {
            _ = try MCPRegistrationPlan.register(agent: .claudeCode, executable: claude, helper: URL(string: "relative/mergecue-mcp")!, paths: paths, environment: env)
        }
        #expect(throws: AgentHandoffError.self) {
            _ = try MCPRegistrationPlan.register(agent: .claudeCode, executable: claude, helper: URL(filePath: "/tmp/evil\nname"), paths: paths, environment: env)
        }
        #expect(throws: AgentHandoffError.self) {
            _ = try MCPRegistrationPlan.register(agent: .claudeCode, executable: claude, helper: URL(string: "https://example.com/mcp")!, paths: paths, environment: env)
        }
    }

    @Test func digestBindsEveryReviewedDetail() throws {
        let base = try MCPRegistrationPlan.register(agent: .claudeCode, executable: claude, helper: helper, paths: paths, environment: env, now: fixedNow)
        let same = try MCPRegistrationPlan.register(agent: .claudeCode, executable: claude, helper: helper, paths: paths, environment: env, now: fixedNow)
        #expect(base.digest == same.digest)
        let otherHelper = try MCPRegistrationPlan.register(agent: .claudeCode, executable: claude, helper: URL(filePath: "/tmp/other"), paths: paths, environment: env, now: fixedNow)
        #expect(base.digest != otherHelper.digest)
        let removal = try MCPRegistrationPlan.unregister(agent: .claudeCode, executable: claude, helper: helper, paths: paths, environment: env, now: fixedNow)
        #expect(base.digest != removal.digest)
    }

    @Test func tomlEscaping() {
        #expect(TOML.basicString(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(TOML.basicString("x\ny\u{1}") == #""x\ny\u0001""#)
        #expect(TOML.array(["--a", "b c"]) == #"["--a", "b c"]"#)
    }
}

@Suite("Session-only MCP config")
struct SessionOnlyConfigTests {
    @Test func claudeUsesStrictMCPConfigFile() throws {
        let dir = try makeTempDirectory()
        let helper = URL(filePath: "/Apps/Merge Cue.app/Contents/MacOS/mergecue-mcp")
        let config = try AgentRegistrar.sessionOnlyConfig(agent: .claudeCode, helper: helper, directory: dir)
        let file = try #require(config.configFile)
        #expect(config.arguments == ["--mcp-config", MergeCuePaths.fileSystemPath(file), "--strict-mcp-config"])
        try config.write()
        #expect(try posixPermissions(file) == 0o600)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        #expect(json == .object(["mcpServers": .object(["mergecue": .object([
            "type": .string("stdio"),
            "command": .string("/Apps/Merge Cue.app/Contents/MacOS/mergecue-mcp"),
            "args": .array([]),
        ])])]))
        // Rewriting replaces the earlier session file.
        try config.write()
        #expect(config.argv(executable: URL(filePath: "/bin/claude"), then: ["-p", "hi"]).suffix(2) == ["-p", "hi"])
    }

    @Test func codexUsesConfigOverridesOnly() throws {
        let dir = try makeTempDirectory()
        let helper = URL(filePath: #"/Apps/Merge "Cue".app/mergecue-mcp"#)
        let config = try AgentRegistrar.sessionOnlyConfig(agent: .codex, helper: helper, helperArguments: ["--stdio"], directory: dir)
        #expect(config.configFile == nil)
        #expect(config.arguments == [
            "-c", #"mcp_servers.mergecue.command="/Apps/Merge \"Cue\".app/mergecue-mcp""#,
            "-c", #"mcp_servers.mergecue.args=["--stdio"]"#,
        ])
        try config.write() // no-op
        #expect(try FileManager.default.contentsOfDirectory(atPath: MergeCuePaths.fileSystemPath(dir)).isEmpty)
    }
}
