import Foundation
import MergeCueCore
import Testing
@testable import AgentHandoff

/// Opt-in smoke test against the real agent CLIs (`MERGECUE_REAL_AGENT_CLI=1 swift test --filter RealCLISmoke`).
/// Every run uses a throwaway HOME / CLAUDE_CONFIG_DIR / CODEX_HOME, so the user's real configuration is never
/// read or written. Skipped by default (CI and normal runs must not depend on installed agents).
@Suite("Real agent CLI smoke", .enabled(if: ProcessInfo.processInfo.environment["MERGECUE_REAL_AGENT_CLI"] == "1"))
struct RealCLISmokeTests {
    static let claude = URL(filePath: NSString(string: "~/.local/bin/claude").expandingTildeInPath)
    static let codex = URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex")

    private func sandbox(_ label: String) throws -> (root: URL, paths: MergeCuePaths, helper: URL, env: [String: String]) {
        let root = try makeTempDirectory(label)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let helper = try writeScript(root.appending(path: "Merge Cue.app/mergecue-mcp"), shellMCPServer)
        let env = testEnvironment(home: home, extra: [
            "CLAUDE_CONFIG_DIR": MergeCuePaths.fileSystemPath(home.appending(path: ".claude")),
            "CODEX_HOME": MergeCuePaths.fileSystemPath(home.appending(path: ".codex")),
        ])
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        return (root, MergeCuePaths(root: root.appending(path: "mc", directoryHint: .isDirectory)), helper, env)
    }

    @Test(arguments: [AgentKind.claudeCode, .codex])
    func registerStatusUnregister(agent: AgentKind) async throws {
        let executable = agent == .claudeCode ? Self.claude : Self.codex
        try #require(FileManager.default.isExecutableFile(atPath: MergeCuePaths.fileSystemPath(executable)))
        let box = try sandbox("real-\(agent.slug)")
        let registrar = AgentRegistrar(paths: box.paths, configuration: .init(environment: box.env, commandTimeout: 60, statusTimeout: 60))

        let plan = try MCPRegistrationPlan.register(agent: agent, executable: executable, helper: box.helper, paths: box.paths, environment: box.env)
        #expect(plan.filesTouched.allSatisfy { MergeCuePaths.fileSystemPath($0).hasPrefix(MergeCuePaths.fileSystemPath(box.root)) })
        #expect(await registrar.registrationStatus(agent, executable: executable, configEnvironment: plan.configEnvironment) == .notRegistered)

        let outcome = try await registrar.register(plan, consent: await RegistrationConsent.userConfirmed(plan))
        #expect(outcome.changed)
        #expect(outcome.status.isRegistered(helper: box.helper))
        if agent == .claudeCode { #expect(outcome.status.server?.health == "✔ Connected") }
        let written = try readText(try #require(plan.filesTouched.first))
        #expect(written.contains(MergeCuePaths.fileSystemPath(box.helper)))

        let removal = try MCPRegistrationPlan.unregister(agent: agent, executable: executable, helper: box.helper, paths: box.paths, environment: box.env)
        let removed = try await registrar.unregister(removal, consent: await RegistrationConsent.userConfirmed(removal))
        #expect(removed.status == .notRegistered)
    }

    @Test func codexSessionOverridesAreUnderstood() async throws {
        let box = try sandbox("real-codex-session")
        let session = try SessionOnlyMCPConfig.make(agent: .codex, helper: box.helper, helperArguments: ["--x"], directory: box.root)
        let result = try await ProcessRunner().run(
            Self.codex,
            arguments: session.arguments + ["mcp", "get", "mergecue", "--json"],
            environment: box.env,
            currentDirectory: box.root,
            timeout: 60
        )
        let status = RegistrationStatusParser.parseCodex(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        #expect(status.isRegistered(helper: box.helper, arguments: ["--x"]))
        #expect(!FileManager.default.fileExists(atPath: MergeCuePaths.fileSystemPath(box.root) + "/home/.codex/config.toml"))
    }

}
