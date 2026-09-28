import Foundation
import MergeCueCore
import Testing
@testable import AgentHandoff

@Suite("Agent detection")
struct DetectionTests {
    private func detector(
        home: URL,
        shell: URL? = nil,
        shellTimeout: TimeInterval = 5,
        known: [AgentKind: [URL]]
    ) -> AgentDetector {
        AgentDetector(configuration: .init(
            homeDirectory: home,
            loginShell: shell,
            loginShellTimeout: shellTimeout,
            versionTimeout: 5,
            environment: testEnvironment(home: home),
            knownLocationsOverride: known,
            versionedNodeDirectories: []
        ))
    }

    @Test func findsKnownLocationAndParsesVersion() async throws {
        let home = try makeTempDirectory()
        let claude = try writeScript(home.appending(path: ".local/bin/claude"), "echo '2.1.283 (Claude Code)'")
        let codex = try writeScript(home.appending(path: "Apps/Codex.app/Contents/Resources/codex"), "echo 'codex-cli 0.153.4'")
        let sut = detector(home: home, known: [.claudeCode: [claude], .codex: [codex]])

        let agents = await sut.detectAll()
        #expect(agents.count == 2)
        let foundClaude = try #require(agents.first { $0.kind == .claudeCode })
        #expect(foundClaude.executableURL == claude)
        #expect(foundClaude.version == "2.1.283")
        #expect(foundClaude.source == .knownLocation)
        #expect(foundClaude.invocation == MergeCuePaths.fileSystemPath(claude))
        let foundCodex = try #require(agents.first { $0.kind == .codex })
        #expect(foundCodex.version == "0.153.4")
    }

    @Test func skipsMissingNonExecutableAndDirectoryCandidates() async throws {
        let home = try makeTempDirectory()
        let missing = home.appending(path: "nope/claude")
        let plain = home.appending(path: "plain/claude")
        try FileManager.default.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 1.0.0\n".utf8).write(to: plain) // not executable
        let directory = home.appending(path: "dir/claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = try writeScript(home.appending(path: "good/claude"), "echo 3.0.0")

        let sut = detector(home: home, known: [.claudeCode: [missing, plain, directory, good]])
        let agent = try #require(await sut.detect(.claudeCode))
        #expect(agent.executableURL == good)
        #expect(agent.version == "3.0.0")
        #expect(await sut.detect(.codex) == nil)
    }

    @Test func deduplicatesSymlinksToTheSameBinary() async throws {
        let home = try makeTempDirectory()
        let real = try writeScript(home.appending(path: "real/claude"), "echo 1.2.3")
        let link = home.appending(path: "bin/claude")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let sut = detector(home: home, known: [.claudeCode: [link, real]])
        let candidates = await sut.candidates(for: .claudeCode)
        #expect(candidates.count == 1)
        #expect(candidates.first?.0 == link)
    }

    @Test func loginShellResultWinsAndIgnoresProfileNoise() async throws {
        let home = try makeTempDirectory()
        let onPath = try writeScript(home.appending(path: "shell-path/claude"), "echo '2.0.0 (Claude Code)'")
        let known = try writeScript(home.appending(path: "known/claude"), "echo 1.0.0")
        // A fake login shell: prints a banner (like a noisy .zprofile), then the resolved path.
        let shell = try writeScript(home.appending(path: "fake-zsh"), """
            [ "$1" = "-lc" ] || exit 9
            echo "Welcome back!"
            case "$2" in
              "command -v claude") echo '\(MergeCuePaths.fileSystemPath(onPath))' ;;
              *) exit 1 ;;
            esac
            """)
        let sut = detector(home: home, shell: shell, known: [.claudeCode: [known]])

        let agent = try #require(await sut.detect(.claudeCode))
        #expect(agent.executableURL == onPath)
        #expect(agent.source == .loginShellPath)
        #expect(agent.version == "2.0.0")
        #expect(agent.invocation == "claude")
        let all = await sut.candidates(for: .claudeCode)
        #expect(all.map(\.1) == [.loginShellPath, .knownLocation])
        // codex: shell exits 1 and there are no known locations.
        #expect(await sut.detect(.codex) == nil)
    }

    @Test func hangingLoginShellTimesOutAndFallsBack() async throws {
        let home = try makeTempDirectory()
        let known = try writeScript(home.appending(path: "known/codex"), "echo 'codex-cli 0.1.0'")
        let shell = try writeScript(home.appending(path: "slow-zsh"), "sleep 30")
        let sut = detector(home: home, shell: shell, shellTimeout: 0.5, known: [.codex: [known]])

        let start = Date()
        let agent = try #require(await sut.detect(.codex))
        #expect(Date().timeIntervalSince(start) < 20)  // hangs for 30 s; 20 s still proves the timeout under heavy machine load
        #expect(agent.source == .knownLocation)
        #expect(agent.version == "0.1.0")
    }

    @Test func aliasOrFunctionOutputIsNotAPath() {
        #expect(AgentDetector.parseCommandV("alias claude='npx claude'\n") == nil)
        #expect(AgentDetector.parseCommandV("claude\n") == nil)
        #expect(AgentDetector.parseCommandV("") == nil)
        #expect(AgentDetector.parseCommandV("/definitely/not/here/claude\n") == nil)
    }

    @Test func versionParsing() {
        #expect(AgentDetector.parseVersion("2.1.283 (Claude Code)\n") == "2.1.283")
        #expect(AgentDetector.parseVersion("codex-cli 0.153.4\n") == "0.153.4")
        #expect(AgentDetector.parseVersion("\n  tool 1.2.0-beta.3 build\n") == "1.2.0-beta.3")
        #expect(AgentDetector.parseVersion("no version here") == nil)
    }

    @Test func builtInKnownLocationsCoverDocumentedPaths() {
        let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
        let sut = AgentDetector(configuration: .init(homeDirectory: home, loginShell: nil, versionedNodeDirectories: []))
        let claude = sut.knownLocations(for: .claudeCode).map(MergeCuePaths.fileSystemPath)
        #expect(claude.contains("/Users/tester/.local/bin/claude"))
        #expect(claude.contains("/Users/tester/.claude/local/claude"))
        #expect(claude.contains("/opt/homebrew/bin/claude"))
        #expect(claude.contains("/usr/local/bin/claude"))
        #expect(claude.contains("/Users/tester/.npm-global/bin/claude"))
        let codex = sut.knownLocations(for: .codex).map(MergeCuePaths.fileSystemPath)
        #expect(codex.contains("/Applications/ChatGPT.app/Contents/Resources/codex"))
        #expect(codex.contains("/Applications/Codex.app/Contents/Resources/codex"))
        #expect(codex.contains("/opt/homebrew/bin/codex"))
    }

    @Test func nvmStyleDirectoriesAreScannedNewestFirst() throws {
        let home = try makeTempDirectory()
        let nvm = home.appending(path: ".nvm/versions/node", directoryHint: .isDirectory)
        for version in ["v18.2.0", "v20.11.1", "v9.0.0"] {
            try FileManager.default.createDirectory(at: nvm.appending(path: "\(version)/bin"), withIntermediateDirectories: true)
        }
        let sut = AgentDetector(configuration: .init(homeDirectory: home, loginShell: nil, versionedNodeDirectories: [nvm]))
        let paths = sut.knownLocations(for: .claudeCode).map(\.lastPathComponent)
        #expect(paths.contains("claude"))
        let nvmPaths = sut.knownLocations(for: .claudeCode)
            .map(MergeCuePaths.fileSystemPath)
            .filter { $0.contains(".nvm") }
        #expect(nvmPaths.map { URL(filePath: $0).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }
            == ["v20.11.1", "v18.2.0", "v9.0.0"])
    }

    @Test func pathAugmentationPrependsExecutableDirectory() {
        let env = AgentDetector.environment(["PATH": "/usr/bin:/bin", "X": "1"], prependingDirectoryOf: URL(filePath: "/opt/tools/bin/claude"))
        let path = env["PATH"]
        #expect(path?.hasPrefix("/opt/tools/bin:/usr/bin:/bin") == true)
        #expect(path?.contains("/opt/homebrew/bin") == true)
        #expect(env["X"] == "1")
    }
}

@Suite("Process runner")
struct ProcessRunnerTests {
    @Test func capturesOutputExitCodeEnvironmentAndDirectory() async throws {
        let dir = try makeTempDirectory()
        let result = try await ProcessRunner().run(
            URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err >&2; echo \"$FOO\"; pwd; exit 7"],
            environment: ["FOO": "bar baz", "PATH": "/usr/bin:/bin"],
            currentDirectory: dir,
            timeout: 10
        )
        #expect(result.exitCode == 7)
        #expect(result.stdout == "out\nbar baz\n\(MergeCuePaths.fileSystemPath(dir))\n")
        #expect(result.stderr == "err\n")
        #expect(!result.timedOut)
    }

    @Test func timeoutKillsTheProcessGroup() async throws {
        let start = Date()
        let result = try await ProcessRunner().run(
            URL(filePath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & sleep 30; echo never"],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: nil,
            timeout: 0.3
        )
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(!result.stdout.contains("never"))
        #expect(Date().timeIntervalSince(start) < 20)  // hangs for 30 s; 20 s still proves the timeout under heavy machine load
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner().run(URL(filePath: "/nonexistent/tool"), arguments: [], environment: [:], currentDirectory: nil, timeout: 1)
        }
    }
}
