import AgentHandoff
import Foundation
import MergeCueCore

/// "Import from GitHub CLI" (DECISIONS D8): an **explicit user action** that runs `gh auth token --hostname <host>`
/// (no shell, stdin `/dev/null`, bounded by a timeout) and returns the token as a bearer `Credential`.
///
/// The token is never logged, printed or persisted here — the caller hands it to `MergeCueEngine.connectAccount`,
/// which validates it and stores it in the Keychain. Error messages are redacted.
public struct GitHubCLITokenImporter: Sendable {
    public enum ImportError: Error, Sendable, Equatable, LocalizedError {
        case ghNotFound
        case notLoggedIn(String)
        case timedOut
        case invalidToken
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .ghNotFound:
                "The GitHub CLI (gh) was not found. Install it (brew install gh) and run gh auth login, or paste a token."
            case .notLoggedIn(let detail):
                "The GitHub CLI is not logged in to github.com (\(detail)). Run gh auth login first."
            case .timedOut:
                "The GitHub CLI did not answer in time."
            case .invalidToken:
                "The GitHub CLI returned something that is not a token."
            case .failed(let detail):
                "The GitHub CLI failed: \(detail)"
            }
        }
    }

    public var timeout: TimeInterval
    public var environment: [String: String]
    /// Explicit `gh` location (tests); nil = well-known locations, then the login shell's `PATH`.
    public var executableOverride: URL?
    private let runner: any ProcessRunning

    public init(
        timeout: TimeInterval = 15,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableOverride: URL? = nil,
        runner: any ProcessRunning = ProcessRunner(maxOutputBytes: 64 * 1024)
    ) {
        self.timeout = timeout
        self.environment = environment
        self.executableOverride = executableOverride
        self.runner = runner
    }

    public static let knownLocations = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    /// Finds `gh`: override → Homebrew/system locations → `~/.local/bin` → the login shell (`command -v gh`).
    public func locate() async -> URL? {
        if let executableOverride { return executableOverride }
        let home = environment["HOME"] ?? NSHomeDirectory()
        for path in Self.knownLocations + ["\(home)/.local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        let detector = AgentDetector(configuration: .init(environment: environment), runner: runner)
        return await detector.loginShellLookup("gh")
    }

    /// Runs `gh auth token --hostname <hostname>` and returns the token.
    public func importToken(hostname: String = "github.com") async throws(ImportError) -> Credential {
        guard hostname.range(of: #"^[A-Za-z0-9.-]{1,253}$"#, options: .regularExpression) != nil else {
            throw .failed("invalid host name")
        }
        guard let gh = await locate() else { throw .ghNotFound }
        var childEnvironment = environment
        childEnvironment["GH_PROMPT_DISABLED"] = "1"
        childEnvironment["GH_NO_UPDATE_NOTIFIER"] = "1"
        childEnvironment["NO_COLOR"] = "1"
        let result: ProcessResult
        do {
            result = try await runner.run(
                gh, arguments: ["auth", "token", "--hostname", hostname], environment: childEnvironment,
                currentDirectory: nil, timeout: timeout
            )
        } catch {
            throw .failed(SecretRedactor.redact(error.localizedDescription))
        }
        if result.timedOut { throw .timedOut }
        guard result.exitCode == 0 else {
            let detail = SecretRedactor.redact(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            throw .notLoggedIn(String(detail.prefix(200)))
        }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeToken(token) else { throw .invalidToken }
        return .bearer(token)
    }

    /// A single line of token characters (`ghp_…`, `gho_…`, `github_pat_…`, or a 40-hex legacy token).
    static func looksLikeToken(_ value: String) -> Bool {
        guard (20...512).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
            && value.unicodeScalars.allSatisfy(\.isASCII)
    }
}
