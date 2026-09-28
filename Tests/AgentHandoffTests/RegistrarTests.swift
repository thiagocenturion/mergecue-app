import Foundation
import MergeCueCore
import Testing
@testable import AgentHandoff

/// Registrar behaviour against fake `claude` / `codex` CLIs that edit config files under a temporary HOME.
/// The real `~/.claude.json` and `~/.codex/config.toml` are never touched.
@Suite("Agent registrar")
struct RegistrarTests {
    /// Test sandbox: temp HOME, MergeCue root, fake CLIs, invocation log.
    struct Sandbox {
        let root: URL
        let home: URL
        let paths: MergeCuePaths
        let helper: URL
        let log: URL
        let claude: URL
        let codex: URL
        var environment: [String: String]

        init(name: String = #function) throws {
            root = try makeTempDirectory(name)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
            paths = MergeCuePaths(root: root.appending(path: "mergecue", directoryHint: .isDirectory))
            helper = root.appending(path: "My App/mergecue-mcp")
            log = root.appending(path: "cli.log")
            let backups = MergeCuePaths.fileSystemPath(paths.root) + "/backups"
            environment = testEnvironment(home: home, extra: ["FAKE_LOG": MergeCuePaths.fileSystemPath(log), "BACKUP_ROOT": backups])

            // Fake Claude Code CLI: `mcp get|add|remove` over "$HOME/.claude.json".
            claude = try writeScript(root.appending(path: "bin/claude"), #"""
                CONF="$HOME/.claude.json"
                echo "$*" >> "$FAKE_LOG"
                case "$1 $2" in
                "mcp get")
                  if grep -q '"mergecue"' "$CONF" 2>/dev/null; then
                    cmd=$(sed -n 's/.*"command": *"\([^"]*\)".*/\1/p' "$CONF")
                    printf 'mergecue:\n  Scope: User config (available in all your projects)\n  Status: ✔ Connected\n  Type: stdio\n  Command: %s\n  Args: \n  Environment:\n\nTo remove this server, run: claude mcp remove mergecue -s user\n' "$cmd"
                    exit 0
                  fi
                  echo 'No MCP server named "mergecue". Run `claude mcp add` to add one.'
                  exit 1;;
                "mcp add")
                  if ls "$BACKUP_ROOT"/claude-*/manifest.json >/dev/null 2>&1; then echo "backup-present" >> "$FAKE_LOG"; fi
                  if [ -n "$FAKE_FAIL" ]; then echo "boom ghp_abcdefghijklmnopqrstuvwxyz0123456789" >&2; exit 3; fi
                  if [ -n "$FAKE_NOOP" ]; then exit 0; fi
                  printf '{"numStartups": 3, "mcpServers": {"mergecue": {"type": "stdio", "command": "%s", "args": []}}}\n' "$7" > "$CONF"
                  exit 0;;
                "mcp remove")
                  if ls "$BACKUP_ROOT"/claude-*/manifest.json >/dev/null 2>&1; then echo "backup-present" >> "$FAKE_LOG"; fi
                  printf '{"numStartups": 3}\n' > "$CONF"
                  exit 0;;
                esac
                exit 64
                """#)

            // Fake Codex CLI: `mcp get --json|add|remove` over "$HOME/.codex/config.toml".
            codex = try writeScript(root.appending(path: "bin/codex"), #"""
                CONF="$HOME/.codex/config.toml"
                echo "$*" >> "$FAKE_LOG"
                case "$1 $2" in
                "mcp get")
                  if grep -q 'mcp_servers.mergecue' "$CONF" 2>/dev/null; then
                    cmd=$(sed -n 's/^command = "\(.*\)"$/\1/p' "$CONF")
                    printf '{"name":"mergecue","enabled":true,"transport":{"type":"stdio","command":"%s","args":[],"env":null}}\n' "$cmd"
                    exit 0
                  fi
                  echo "Error: No MCP server named 'mergecue' found." >&2
                  exit 1;;
                "mcp add")
                  if ls "$BACKUP_ROOT"/codex-*/manifest.json >/dev/null 2>&1; then echo "backup-present" >> "$FAKE_LOG"; fi
                  printf 'model = "o3"\n\n[mcp_servers.mergecue]\ncommand = "%s"\n' "$5" > "$CONF"
                  exit 0;;
                "mcp remove")
                  printf 'model = "o3"\n' > "$CONF"
                  exit 0;;
                esac
                exit 64
                """#)
        }

        var claudeConfig: URL { home.appending(path: ".claude.json") }
        var codexConfig: URL { home.appending(path: ".codex/config.toml") }

        func registrar(extra: [String: String] = [:], now: @escaping @Sendable () -> Date = { fixedNow }) -> AgentRegistrar {
            AgentRegistrar(
                paths: paths,
                configuration: .init(environment: environment.merging(extra) { $1 }, commandTimeout: 10, statusTimeout: 10),
                now: now
            )
        }

        func plan(_ agent: AgentKind, action: RegistrationAction = .register, helper: URL? = nil) throws -> MCPRegistrationPlan {
            let executable = agent == .claudeCode ? claude : codex
            switch action {
            case .register:
                return try MCPRegistrationPlan.register(agent: agent, executable: executable, helper: helper ?? self.helper, paths: paths, environment: environment, now: fixedNow)
            case .unregister:
                return try MCPRegistrationPlan.unregister(agent: agent, executable: executable, helper: helper ?? self.helper, paths: paths, environment: environment, now: fixedNow)
            }
        }

        func logLines() -> [String] {
            ((try? readText(log)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    // MARK: Happy paths

    @Test func claudeRegisterBacksUpBeforeRunningAndVerifies() async throws {
        let box = try Sandbox()
        let original = #"{"numStartups": 3, "userID": "keep-me"}"# + "\n"
        try Data(original.utf8).write(to: box.claudeConfig)
        let plan = try box.plan(.claudeCode)
        #expect(plan.filesTouched == [box.claudeConfig])
        let consent = await RegistrationConsent.userConfirmed(plan, at: fixedNow)

        let outcome = try await box.registrar().register(plan, consent: consent)

        #expect(outcome.changed)
        #expect(outcome.status.isRegistered(helper: box.helper))
        let helperPath = MergeCuePaths.fileSystemPath(box.helper)
        #expect(box.logLines() == [
            "mcp get mergecue",
            "mcp add --scope user mergecue -- \(helperPath)",
            "backup-present",
            "mcp get mergecue",
        ])
        // The backup holds the pre-change bytes; the live file changed.
        let backup = try #require(outcome.backup)
        #expect(MergeCuePaths.fileSystemPath(backup.directory) == MergeCuePaths.fileSystemPath(box.paths.root) + "/backups/claude-20260304T050607Z")
        let copy = try #require(backup.files.first?.copy)
        #expect(try readText(copy) == original)
        #expect(try readText(box.claudeConfig).contains("\"mergecue\""))
        #expect(try posixPermissions(backup.directory) == 0o700)
        #expect(try posixPermissions(copy) == 0o600)
        #expect(try posixPermissions(backup.manifest) == 0o600)
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: backup.manifest))
        guard case .object(let fields) = manifest else { Issue.record("manifest is not an object"); return }
        #expect(fields["agent"] == .string("claude_code"))
        #expect(fields["action"] == .string("register"))
        #expect(fields["created_at"] == .string("2026-03-04T05:06:07Z"))
    }

    @Test func codexRegisterThenUnregister() async throws {
        let box = try Sandbox()
        try Data("model = \"o3\"\n".utf8).write(to: box.codexConfig)
        let registrar = box.registrar()

        let plan = try box.plan(.codex)
        let registered = try await registrar.register(plan, consent: await RegistrationConsent.userConfirmed(plan, at: fixedNow))
        #expect(registered.changed)
        #expect(await registrar.registrationStatus(.codex, executable: box.codex, configEnvironment: plan.configEnvironment).isRegistered(helper: box.helper))
        #expect(try readText(try #require(registered.backup?.files.first?.copy)) == "model = \"o3\"\n")
        #expect(box.logLines().contains("backup-present"))

        let removal = try box.plan(.codex, action: .unregister)
        let removed = try await registrar.unregister(removal, consent: await RegistrationConsent.userConfirmed(removal, at: fixedNow))
        #expect(removed.changed)
        #expect(removed.status == .notRegistered)
        // Second backup directory gets a suffix; it holds the registered config.
        let second = try #require(removed.backup)
        #expect(second.directory.lastPathComponent == "codex-20260304T050607Z-1")
        #expect(try readText(try #require(second.files.first?.copy)).contains("[mcp_servers.mergecue]"))
        #expect(try readText(box.codexConfig) == "model = \"o3\"\n")
    }

    @Test func missingConfigFileIsRecordedAsAbsent() async throws {
        let box = try Sandbox()
        let plan = try box.plan(.claudeCode)
        let outcome = try await box.registrar().register(plan, consent: await RegistrationConsent.userConfirmed(plan, at: fixedNow))
        let file = try #require(outcome.backup?.files.first)
        #expect(!file.existed)
        #expect(file.copy == nil)
    }

    @Test func alreadyRegisteredIsANoOp() async throws {
        let box = try Sandbox()
        let helperPath = MergeCuePaths.fileSystemPath(box.helper)
        try Data(#"{"mcpServers": {"mergecue": {"command": "\#(helperPath)"}}}"#.utf8).write(to: box.claudeConfig)
        let plan = try box.plan(.claudeCode)
        let outcome = try await box.registrar().register(plan, consent: await RegistrationConsent.userConfirmed(plan, at: fixedNow))
        #expect(!outcome.changed)
        #expect(outcome.backup == nil)
        #expect(box.logLines() == ["mcp get mergecue"])
        #expect(!FileManager.default.fileExists(atPath: MergeCuePaths.fileSystemPath(box.paths.root) + "/backups"))
    }

    // MARK: Consent guard

    @Test func consentForAnotherPlanIsRejectedBeforeAnythingRuns() async throws {
        let box = try Sandbox()
        try Data("{}".utf8).write(to: box.claudeConfig)
        let reviewed = try box.plan(.claudeCode, helper: URL(filePath: "/reviewed/mergecue-mcp"))
        let actual = try box.plan(.claudeCode)
        let consent = await RegistrationConsent.userConfirmed(reviewed, at: fixedNow)

        await #expect(throws: AgentRegistrarError.consentDoesNotMatchPlan) {
            _ = try await box.registrar().register(actual, consent: consent)
        }
        #expect(box.logLines().isEmpty)
        #expect(try readText(box.claudeConfig) == "{}")
    }

    @Test func consentForRegisterCannotUnregister() async throws {
        let box = try Sandbox()
        let register = try box.plan(.claudeCode)
        let unregister = try box.plan(.claudeCode, action: .unregister)
        let consent = await RegistrationConsent.userConfirmed(register, at: fixedNow)
        await #expect(throws: AgentRegistrarError.consentDoesNotMatchPlan) {
            _ = try await box.registrar().unregister(unregister, consent: consent)
        }
        await #expect(throws: AgentRegistrarError.wrongAction(expected: .register)) {
            _ = try await box.registrar().register(unregister, consent: consent)
        }
        #expect(box.logLines().isEmpty)
    }

    @Test func expiredConsentIsRejected() async throws {
        let box = try Sandbox()
        let plan = try box.plan(.claudeCode)
        let consent = await RegistrationConsent.userConfirmed(plan, at: fixedNow)
        let later = fixedNow.addingTimeInterval(RegistrationConsent.validity + 1)
        await #expect(throws: AgentRegistrarError.consentExpired) {
            _ = try await box.registrar(now: { later }).register(plan, consent: consent)
        }
        #expect(box.logLines().isEmpty)
    }

    @Test func consentIsSingleUse() async throws {
        let box = try Sandbox()
        let plan = try box.plan(.claudeCode)
        let consent = await RegistrationConsent.userConfirmed(plan, at: fixedNow)
        let registrar = box.registrar()
        _ = try await registrar.register(plan, consent: consent)
        await #expect(throws: AgentRegistrarError.consentAlreadyUsed) {
            _ = try await registrar.register(plan, consent: consent)
        }
    }

    // MARK: Failures

    @Test func failingCLIKeepsBackupAndReportsRedactedError() async throws {
        let box = try Sandbox()
        let original = #"{"keep": true}"#
        try Data(original.utf8).write(to: box.claudeConfig)
        let plan = try box.plan(.claudeCode)
        do {
            _ = try await box.registrar(extra: ["FAKE_FAIL": "1"]).register(plan, consent: await RegistrationConsent.userConfirmed(plan, at: fixedNow))
            Issue.record("expected commandFailed")
        } catch {
            guard case .commandFailed(let code, let output) = error else { Issue.record("unexpected \(error)"); return }
            #expect(code == 3)
            #expect(output.contains("boom"))
            #expect(!output.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        }
        #expect(try readText(box.claudeConfig) == original)
        #expect(box.logLines().contains("backup-present"))
        let backupCopy = MergeCuePaths.fileSystemPath(box.paths.root) + "/backups/claude-20260304T050607Z/0-.claude.json"
        #expect(try readText(URL(filePath: backupCopy)) == original)
    }

    @Test func silentNoOpCLIFailsVerification() async throws {
        let box = try Sandbox()
        let plan = try box.plan(.claudeCode)
        await #expect(throws: AgentRegistrarError.verificationFailed(.notRegistered)) {
            _ = try await box.registrar(extra: ["FAKE_NOOP": "1"]).register(plan, consent: await RegistrationConsent.userConfirmed(plan, at: fixedNow))
        }
    }

    @Test func differentExistingEntryIsNotOverwritten() async throws {
        let box = try Sandbox()
        let existing = #"{"mcpServers": {"mergecue": {"command": "/old/place/mergecue-mcp"}}}"#
        try Data(existing.utf8).write(to: box.claudeConfig)
        let plan = try box.plan(.claudeCode)
        await #expect(throws: AgentRegistrarError.conflictingRegistration(RegisteredMCPServer(
            command: "/old/place/mergecue-mcp", scope: "User config (available in all your projects)", health: "✔ Connected"
        ))) {
            _ = try await box.registrar().register(plan, consent: await RegistrationConsent.userConfirmed(plan, at: fixedNow))
        }
        #expect(try readText(box.claudeConfig) == existing)
        #expect(box.logLines() == ["mcp get mergecue"])
    }

    @Test func statusQueryNeverModifies() async throws {
        let box = try Sandbox()
        try Data("{}".utf8).write(to: box.claudeConfig)
        let registrar = box.registrar()
        #expect(await registrar.registrationStatus(.claudeCode, executable: box.claude) == .notRegistered)
        #expect(await registrar.registrationStatus(.codex, executable: box.codex) == .notRegistered)
        #expect(box.logLines() == ["mcp get mergecue", "mcp get mergecue --json"])
        #expect(try readText(box.claudeConfig) == "{}")
        if case .unknown = await registrar.registrationStatus(.claudeCode, executable: URL(filePath: "/nonexistent/claude")) {} else {
            Issue.record("a missing CLI must report unknown")
        }
    }
}
