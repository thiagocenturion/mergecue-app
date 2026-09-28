import Foundation
import Testing
@testable import AgentHandoff

/// Outputs recorded from Claude Code 2.1.283 and Codex CLI 0.153.4 against temporary HOME / CODEX_HOME dirs.
@Suite("Registration status parsing")
struct StatusParsingTests {
    // MARK: Claude Code

    static let claudeConnected = """
        mergecue:
          Scope: User config (available in all your projects)
          Status: ✔ Connected
          Type: stdio
          Command: /Applications/MergeCue.app/Contents/MacOS/mergecue-mcp
          Args:
          Environment:

        To remove this server, run: claude mcp remove mergecue -s user

        """

    static let claudeFailedWithArgs = """
        mergecue:
          Scope: User config (available in all your projects)
          Status: ✘ Failed to connect
          Issue: CONNECTION_CLOSED: Connection closed
          Type: stdio
          Command: /tmp/dir with 'q/helper
          Args: --flag
          Environment:

        To remove this server, run: claude mcp remove mergecue -s user

        """

    static let claudeMissing = "No MCP server named \"mergecue\". Run `claude mcp add` to add one.\n"

    @Test func claudeConnected() {
        let status = RegistrationStatusParser.parseClaude(exitCode: 0, stdout: Self.claudeConnected, stderr: "")
        let server = status.server
        #expect(server?.command == "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp")
        #expect(server?.arguments == [])
        #expect(server?.scope == "User config (available in all your projects)")
        #expect(server?.isUserScope == true)
        #expect(server?.health == "✔ Connected")
        #expect(status.isRegistered(helper: URL(filePath: "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp")))
        #expect(!status.isRegistered(helper: URL(filePath: "/Other/mergecue-mcp")))
    }

    @Test func claudeFailedHealthCheckIsStillRegistered() {
        let status = RegistrationStatusParser.parseClaude(exitCode: 0, stdout: Self.claudeFailedWithArgs, stderr: "")
        #expect(status.server?.command == "/tmp/dir with 'q/helper")
        #expect(status.server?.arguments == ["--flag"])
        #expect(status.server?.health == "✘ Failed to connect")
    }

    @Test func claudeMissing() {
        #expect(RegistrationStatusParser.parseClaude(exitCode: 1, stdout: Self.claudeMissing, stderr: "") == .notRegistered)
        #expect(RegistrationStatusParser.parseClaude(exitCode: 1, stdout: "", stderr: Self.claudeMissing) == .notRegistered)
    }

    @Test func claudeUnexpectedOutputIsUnknownAndRedacted() {
        let status = RegistrationStatusParser.parseClaude(exitCode: 2, stdout: "", stderr: "fatal: token ghp_abcdefghijklmnopqrstuvwxyz0123456789 rejected")
        guard case .unknown(let message) = status else {
            Issue.record("expected unknown, got \(status)")
            return
        }
        #expect(message.contains("exited with 2"))
        #expect(!message.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(RegistrationStatusParser.parseClaude(exitCode: 0, stdout: "", stderr: "", timedOut: true) == .unknown("claude mcp get timed out"))
    }

    // MARK: Codex

    static let codexJSON = """
        {
          "name": "mergecue",
          "enabled": true,
          "disabled_reason": null,
          "transport": {
            "type": "stdio",
            "command": "/tmp/dir with 'q/helper",
            "args": [
              "--flag"
            ],
            "env": null,
            "env_vars": [],
            "cwd": null
          },
          "enabled_tools": null,
          "disabled_tools": null,
          "startup_timeout_sec": null,
          "tool_timeout_sec": null
        }

        """

    static let codexText = """
        mergecue
          enabled: true
          transport: stdio
          command: /Applications/MergeCue.app/Contents/MacOS/mergecue-mcp
          args: -
          cwd: -
          env: -
          remove: codex mcp remove mergecue

        """

    static let codexMissing = "Error: No MCP server named 'mergecue' found.\n"

    @Test func codexJSON() {
        let status = RegistrationStatusParser.parseCodex(exitCode: 0, stdout: Self.codexJSON, stderr: "")
        #expect(status == .registered(RegisteredMCPServer(command: "/tmp/dir with 'q/helper", arguments: ["--flag"], enabled: true)))
        #expect(status.isRegistered(helper: URL(filePath: "/tmp/dir with 'q/helper"), arguments: ["--flag"]))
    }

    @Test func codexTextFallback() {
        let status = RegistrationStatusParser.parseCodex(exitCode: 0, stdout: Self.codexText, stderr: "")
        #expect(status == .registered(RegisteredMCPServer(
            command: "/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp", arguments: [], enabled: true
        )))
    }

    @Test func codexMissing() {
        #expect(RegistrationStatusParser.parseCodex(exitCode: 1, stdout: "", stderr: Self.codexMissing) == .notRegistered)
    }

    @Test func codexHTTPEntryIsUnknown() {
        let json = #"{"name":"mergecue","enabled":true,"transport":{"type":"streamable_http","url":"https://x"}}"#
        if case .unknown = RegistrationStatusParser.parseCodex(exitCode: 0, stdout: json, stderr: "") {} else {
            Issue.record("expected unknown for a non-stdio entry")
        }
    }

    @Test func statusCommandsAreReadOnly() {
        #expect(AgentRegistrar.statusArguments(for: .claudeCode) == ["mcp", "get", "mergecue"])
        #expect(AgentRegistrar.statusArguments(for: .codex) == ["mcp", "get", "mergecue", "--json"])
    }
}
