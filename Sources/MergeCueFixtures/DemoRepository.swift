import Foundation
import MergeCueCore

/// The synthetic local git setup behind demo mode (**demo data, never live**):
///
/// - `remotes/acme-payments-api.git` — a bare repository standing in for the three hosted remotes. It serves
///   `main`, the change request head as `refs/pull/42/head` (GitHub), `refs/merge-requests/42/head` (GitLab) and
///   the source branches `feature/charge-retries`, `feature/retry-backoff`, `feature/refund-guard` (Bitbucket).
/// - `checkouts/payments-api` — the "user's checkout": remotes `origin` (github.com), `gitlab` and `bitbucket`
///   carry the real provider URLs, and `url.<bare>.insteadOf` entries **in this checkout's own config only** (never
///   the global config) route every fetch to the bare repository. It is clean and on `feature/charge-retries`.
///
/// Commits use fixed author/committer identities and dates with a hermetic git environment
/// (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`), so the SHAs are identical on every machine.
public struct DemoRepository: Sendable, Hashable {
    public let bareRepository: URL
    public let checkout: URL
    /// `main`.
    public let baseSHA: String
    /// The change request head (#42 / !42 on every provider).
    public let headSHA: String

    public static let fullPath = "acme/payments-api"
    public static let checkoutBranch = "feature/charge-retries"
    /// Source branches of #42 on GitHub, GitLab and Bitbucket.
    public static let sourceBranches = ["feature/charge-retries", "feature/retry-backoff", "feature/refund-guard"]
    /// Provider remote URLs rewritten to the bare repository (clone URLs the fixtures report).
    public static let rewrittenURLs = [
        "https://github.com/acme/payments-api.git",
        "git@github.com:acme/payments-api.git",
        "https://gitlab.com/acme/payments-api.git",
        "git@gitlab.com:acme/payments-api.git",
        "https://bitbucket.org/acme/payments-api.git",
        "https://mona-dev@bitbucket.org/acme/payments-api.git",
        "git@bitbucket.org:acme/payments-api.git",
    ]
    static let remotes: [(name: String, url: String)] = [
        ("origin", "https://github.com/acme/payments-api.git"),
        ("gitlab", "https://gitlab.com/acme/payments-api.git"),
        ("bitbucket", "https://bitbucket.org/acme/payments-api.git"),
    ]

    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case gitFailed(command: String, status: Int32, output: String)

        public var errorDescription: String? {
            switch self {
            case .gitFailed(let command, let status, let output):
                "Demo repository: git \(command) failed (\(status)): \(output)"
            }
        }
    }

    /// Creates the repositories under `directory` (or reuses them when they already exist).
    public static func prepare(in directory: URL, git: URL = URL(filePath: "/usr/bin/git")) throws -> DemoRepository {
        let runner = Git(executable: git, home: directory)
        let bare = directory.appending(path: "remotes/acme-payments-api.git", directoryHint: .isDirectory)
        let checkout = directory.appending(path: "checkouts/payments-api", directoryHint: .isDirectory)
        let barePath = MergeCuePaths.fileSystemPath(bare)
        let checkoutPath = MergeCuePaths.fileSystemPath(checkout)
        let fm = FileManager.default

        if fm.fileExists(atPath: barePath + "/HEAD"), fm.fileExists(atPath: checkoutPath + "/.git") {
            let base = try runner.run(["rev-parse", "refs/heads/main"], in: barePath)
            let head = try runner.run(["rev-parse", "refs/pull/42/head"], in: barePath)
            return DemoRepository(bareRepository: bare, checkout: checkout, baseSHA: base, headSHA: head)
        }
        // A half-created setup (crash during creation) is rebuilt from scratch.
        try? fm.removeItem(at: bare)
        try? fm.removeItem(at: checkout)
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        try fm.createDirectory(at: bare.deletingLastPathComponent(), withIntermediateDirectories: true)

        // The checkout's history: base on main, the PR head on the feature branch.
        try runner.run(["init", "--quiet", "--initial-branch=main"], in: checkoutPath)
        try runner.run(["config", "user.name", "Mona Dev"], in: checkoutPath)
        try runner.run(["config", "user.email", "mona-dev@example.com"], in: checkoutPath)
        try runner.run(["config", "commit.gpgsign", "false"], in: checkoutPath)
        try write(DemoRepositoryFiles.base, into: checkout)
        try runner.run(["add", "--all"], in: checkoutPath)
        try runner.commit("Initial payments service", date: "2026-09-01T09:00:00Z", in: checkoutPath)
        let base = try runner.run(["rev-parse", "HEAD"], in: checkoutPath)
        try runner.run(["checkout", "--quiet", "-b", checkoutBranch], in: checkoutPath)
        try write(DemoRepositoryFiles.head, into: checkout)
        try runner.run(["add", "--all"], in: checkoutPath)
        try runner.commit("Retry gateway timeouts when charging cards", date: "2026-09-18T10:00:00Z", in: checkoutPath)
        let head = try runner.run(["rev-parse", "HEAD"], in: checkoutPath)

        // The "hosted" remote.
        try runner.run(["init", "--quiet", "--bare", "--initial-branch=main", barePath], in: checkoutPath)
        var refspecs = ["refs/heads/main:refs/heads/main"]
        refspecs += sourceBranches.map { "\(head):refs/heads/\($0)" }
        refspecs += ["\(head):refs/pull/42/head", "\(head):refs/merge-requests/42/head"]
        try runner.run(["push", "--quiet", barePath] + refspecs, in: checkoutPath)

        // Provider remotes, rewritten to the bare repository in this checkout's config only.
        for remote in remotes {
            try runner.run(["remote", "add", remote.name, remote.url], in: checkoutPath)
        }
        for url in rewrittenURLs {
            try runner.run(["config", "--local", "--add", "url.\(barePath).insteadOf", url], in: checkoutPath)
        }
        try runner.run(["fetch", "--quiet", "origin"], in: checkoutPath)
        try runner.run(["branch", "--quiet", "--set-upstream-to=origin/\(checkoutBranch)"], in: checkoutPath)
        return DemoRepository(bareRepository: bare, checkout: checkout, baseSHA: base, headSHA: head)
    }

    /// Simulates a force-push on the hosted side: a new commit on top of the head, published under `refs`
    /// (e.g. `refs/pull/42/head`). Returns the new head SHA. The user's checkout is not touched.
    public func pushNewHead(refs: [String], message: String, git: URL = URL(filePath: "/usr/bin/git")) throws -> String {
        let runner = Git(executable: git, home: bareRepository.deletingLastPathComponent().deletingLastPathComponent())
        let barePath = MergeCuePaths.fileSystemPath(bareRepository)
        let parent = try runner.run(["rev-parse", refs.first ?? "refs/pull/42/head"], in: barePath)
        let tree = try runner.run(["rev-parse", "\(parent)^{tree}"], in: barePath)
        let commit = try runner.run(["commit-tree", tree, "-p", parent, "-m", message], in: barePath, date: "2026-09-19T08:00:00Z")
        for ref in refs {
            try runner.run(["update-ref", ref, commit], in: barePath)
        }
        return commit
    }

    private static func write(_ files: [String: String], into root: URL) throws {
        for (relative, contents) in files {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
    }
}

/// Minimal hermetic git runner for the demo setup.
private struct Git {
    let executable: URL
    let home: URL

    @discardableResult
    func run(_ arguments: [String], in directory: String, date: String = "2026-09-01T09:00:00Z") throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = URL(filePath: directory, directoryHint: .isDirectory)
        var environment: [String: String] = [:]
        let inherited = ProcessInfo.processInfo.environment
        environment["PATH"] = inherited["PATH"] ?? "/usr/bin:/bin"
        environment["HOME"] = MergeCuePaths.fileSystemPath(home)
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        environment["GIT_AUTHOR_NAME"] = "Mona Dev"
        environment["GIT_AUTHOR_EMAIL"] = "mona-dev@example.com"
        environment["GIT_COMMITTER_NAME"] = "Mona Dev"
        environment["GIT_COMMITTER_EMAIL"] = "mona-dev@example.com"
        environment["GIT_AUTHOR_DATE"] = date
        environment["GIT_COMMITTER_DATE"] = date
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw DemoRepository.Failure.gitFailed(
                command: arguments.prefix(2).joined(separator: " "), status: process.terminationStatus,
                output: String(text.prefix(600))
            )
        }
        return text
    }

    func commit(_ message: String, date: String, in directory: String) throws {
        try run(["commit", "--quiet", "--no-verify", "-m", message], in: directory, date: date)
    }
}
