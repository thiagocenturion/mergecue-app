import Foundation

/// Finds installed agent CLIs: first through the user's login shell (`/bin/zsh -lc 'command -v <name>'`, which
/// sees the `PATH` set up in `.zprofile`/`.zshrc` — GUI apps do not inherit it), then in well-known install
/// locations. Every probe is bounded by a timeout; nothing is modified.
public struct AgentDetector: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Home directory used to expand known locations (`~/.local/bin`, …).
        public var homeDirectory: URL
        /// Shell used for the login-shell lookup; nil skips it.
        public var loginShell: URL?
        public var loginShellTimeout: TimeInterval
        public var versionTimeout: TimeInterval
        /// Environment passed to the probes.
        public var environment: [String: String]
        /// Replaces the built-in known locations (tests).
        public var knownLocationsOverride: [AgentKind: [URL]]?
        /// Directories scanned for `<dir>/<version>/bin/<name>` (nvm-style installs).
        public var versionedNodeDirectories: [URL]

        public init(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            loginShell: URL? = URL(filePath: "/bin/zsh"),
            loginShellTimeout: TimeInterval = 5,
            versionTimeout: TimeInterval = 5,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            knownLocationsOverride: [AgentKind: [URL]]? = nil,
            versionedNodeDirectories: [URL]? = nil
        ) {
            self.homeDirectory = homeDirectory
            self.loginShell = loginShell
            self.loginShellTimeout = loginShellTimeout
            self.versionTimeout = versionTimeout
            self.environment = environment
            self.knownLocationsOverride = knownLocationsOverride
            self.versionedNodeDirectories = versionedNodeDirectories
                ?? [homeDirectory.appending(path: ".nvm/versions/node", directoryHint: .isDirectory)]
        }
    }

    public let configuration: Configuration
    private let runner: any ProcessRunning

    public init(configuration: Configuration = Configuration(), runner: any ProcessRunning = ProcessRunner()) {
        self.configuration = configuration
        self.runner = runner
    }

    /// Detects every supported agent; missing ones are omitted.
    public func detectAll() async -> [DetectedAgent] {
        var found: [DetectedAgent] = []
        for kind in AgentKind.allCases {
            if let agent = await detect(kind) { found.append(agent) }
        }
        return found
    }

    /// The preferred installation of `kind`: the login shell's resolution first, then known locations in order.
    public func detect(_ kind: AgentKind) async -> DetectedAgent? {
        guard let (url, source) = await candidates(for: kind).first else { return nil }
        let version = await version(of: url)
        return DetectedAgent(kind: kind, executableURL: url, version: version, source: source)
    }

    /// Every distinct executable for `kind` (deduplicated by resolved path), in preference order.
    public func candidates(for kind: AgentKind) async -> [(URL, AgentDetectionSource)] {
        var result: [(URL, AgentDetectionSource)] = []
        var seen = Set<String>()
        func add(_ url: URL, _ source: AgentDetectionSource) {
            guard Self.isExecutableFile(url) else { return }
            let resolved = MergeCuePathsHelper.path(url.resolvingSymlinksInPath())
            guard seen.insert(resolved).inserted else { return }
            result.append((url, source))
        }
        if let shellHit = await loginShellLookup(kind.executableName) {
            add(shellHit, .loginShellPath)
        }
        for url in knownLocations(for: kind) {
            add(url, .knownLocation)
        }
        return result
    }

    /// `command -v <name>` in the login shell; nil on timeout, failure, alias/function hits or non-executables.
    public func loginShellLookup(_ name: String) async -> URL? {
        guard let shell = configuration.loginShell,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        guard let result = try? await runner.run(
            shell,
            arguments: ["-lc", "command -v \(name)"],
            environment: configuration.environment,
            currentDirectory: configuration.homeDirectory,
            timeout: configuration.loginShellTimeout
        ), result.succeeded else { return nil }
        return Self.parseCommandV(result.stdout)
    }

    /// Picks the last absolute-path line (profiles may print banners before it).
    static func parseCommandV(_ output: String) -> URL? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
            .map { URL(filePath: $0) }
            .flatMap { isExecutableFile($0) ? $0 : nil }
    }

    /// Runs `<executable> --version` and extracts the first dotted version number.
    public func version(of executable: URL) async -> String? {
        guard let result = try? await runner.run(
            executable,
            arguments: ["--version"],
            environment: Self.environment(configuration.environment, prependingDirectoryOf: executable),
            currentDirectory: configuration.homeDirectory,
            timeout: configuration.versionTimeout
        ), result.succeeded else { return nil }
        return Self.parseVersion(result.stdout.isEmpty ? result.stderr : result.stdout)
    }

    /// `2.1.283 (Claude Code)` → `2.1.283`; `codex-cli 0.153.4` → `0.153.4`.
    static func parseVersion(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) })
        else { return nil }
        let pattern = /(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.\-]+)?)/
        return line.firstMatch(of: pattern).map { String($0.output.1) }
    }

    // MARK: Known locations

    /// Well-known install locations, most specific first.
    public func knownLocations(for kind: AgentKind) -> [URL] {
        if let override = configuration.knownLocationsOverride { return override[kind] ?? [] }
        let home = configuration.homeDirectory
        let name = kind.executableName
        var urls: [URL] = []
        switch kind {
        case .claudeCode:
            urls.append(home.appending(path: ".local/bin/claude"))
            urls.append(home.appending(path: ".claude/local/claude"))
        case .codex:
            urls.append(home.appending(path: ".local/bin/codex"))
        }
        urls += [
            URL(filePath: "/opt/homebrew/bin/\(name)"),
            URL(filePath: "/usr/local/bin/\(name)"),
            home.appending(path: ".npm-global/bin/\(name)"),
            home.appending(path: ".volta/bin/\(name)"),
            home.appending(path: ".bun/bin/\(name)"),
        ]
        urls += versionedNodeBinaries(named: name)
        if kind == .codex {
            for applications in [URL(filePath: "/Applications"), home.appending(path: "Applications")] {
                urls.append(applications.appending(path: "ChatGPT.app/Contents/Resources/codex"))
                urls.append(applications.appending(path: "Codex.app/Contents/Resources/codex"))
                urls.append(applications.appending(path: "Codex.app/Contents/MacOS/codex"))
            }
        }
        return urls
    }

    /// `<dir>/<version>/bin/<name>` for nvm-style trees, newest version name first.
    private func versionedNodeBinaries(named name: String) -> [URL] {
        configuration.versionedNodeDirectories.flatMap { directory -> [URL] in
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: MergeCuePathsHelper.path(directory))) ?? []
            return versions
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { directory.appending(path: "\($0)/bin/\(name)") }
        }
    }

    // MARK: Helpers

    /// A regular file (after resolving symlinks) with the executable bit for this user.
    static func isExecutableFile(_ url: URL) -> Bool {
        let path = MergeCuePathsHelper.path(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// `environment` with the executable's directory (and common tool directories) on `PATH`, so npm-installed
    /// CLIs (`#!/usr/bin/env node`) work from a GUI app whose `PATH` is minimal.
    public static func environment(_ environment: [String: String], prependingDirectoryOf executable: URL) -> [String: String] {
        var result = environment
        let directory = MergeCuePathsHelper.path(executable.deletingLastPathComponent())
        let current = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var entries = [directory]
        for entry in current + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        where !entries.contains(entry) {
            entries.append(entry)
        }
        result["PATH"] = entries.joined(separator: ":")
        return result
    }
}
