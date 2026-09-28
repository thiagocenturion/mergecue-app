import CryptoKit
import Foundation
import MergeCueCore
@testable import WorkspaceInspector

/// A hermetic playground of real git repositories in a temp directory.
///
/// `HOME`, `GIT_CONFIG_GLOBAL` and `XDG_CONFIG_HOME` point into the sandbox, system config is disabled, and the
/// global config maps the "provider" URLs used by the tests (`https://github.com/acme/payments-api.git`, …) onto
/// local bare repositories with `url.<base>.insteadOf`, so the real fetch/clone code paths run without network.
final class GitSandbox: @unchecked Sendable {
    let root: URL
    let home: URL
    let worktreeRoot: URL
    let environment: [String: String]

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "mergecue-ws-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: GitWorkspaceInspector.canonicalPath(base.path))
        home = root.appending(path: "home")
        worktreeRoot = root.appending(path: "mergecue/worktrees")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = [
            "HOME": home.path,
            "GIT_CONFIG_GLOBAL": home.appending(path: ".gitconfig").path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "XDG_CONFIG_HOME": home.appending(path: ".config").path,
        ]
        try """
        [user]
        \tname = Sandbox User
        \temail = sandbox@example.invalid
        [init]
        \tdefaultBranch = main
        [advice]
        \tdetachedHead = false
        [protocol "file"]
        \tallow = always

        """.write(to: home.appending(path: ".gitconfig"), atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func inspector(timeout: TimeInterval = 60) -> GitWorkspaceInspector {
        GitWorkspaceInspector(
            worktreeRoot: worktreeRoot,
            environmentOverrides: environment,
            commandTimeout: timeout,
            networkTimeout: timeout
        )
    }

    func url(_ relative: String) -> URL { root.appending(path: relative) }

    // MARK: Git

    @discardableResult
    func git(_ arguments: [String], in directory: URL, allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",  // the helpers themselves must never refresh an index
        ].merging(environment) { $1 }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: stdout, as: UTF8.self)
        if process.terminationStatus != 0 && !allowFailure {
            throw SandboxError.git(arguments.joined(separator: " "), String(decoding: stderr, as: UTF8.self))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func mapURL(_ url: String, to bare: URL) throws {
        try git(["config", "--global", "--add", "url.file://\(bare.path).insteadOf", url], in: root)
    }

    func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func read(_ file: URL) throws -> String {
        String(decoding: try Data(contentsOf: file), as: UTF8.self)
    }

    func initRepo(_ relative: String, remote: String? = nil) throws -> URL {
        let directory = url(relative)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q"], in: directory)
        try configureIdentity(directory)
        if let remote { try git(["remote", "add", "origin", remote], in: directory) }
        return directory
    }

    func configureIdentity(_ repo: URL) throws {
        try git(["config", "user.name", "Sandbox User"], in: repo)
        try git(["config", "user.email", "sandbox@example.invalid"], in: repo)
    }

    func commitAll(_ repo: URL, _ message: String) throws -> String {
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", message], in: repo)
        return try git(["rev-parse", "HEAD"], in: repo)
    }
}

enum SandboxError: Error {
    case git(String, String)
}

/// The provider side of the scenario: a bare "origin" with PR/MR refs, and a fork.
struct RemoteScenario {
    static let originHTTPS = "https://github.com/acme/payments-api.git"
    static let originSSH = "git@github.com:acme/payments-api.git"
    static let forkHTTPS = "https://github.com/contrib/payments-api.git"
    static let goneHTTPS = "https://github.com/acme/gone.git"

    let sandbox: GitSandbox
    let bare: URL
    let forkBare: URL
    /// main
    let baseSHA: String
    /// refs/pull/42/head
    let pullSHA: String
    /// refs/merge-requests/7/head
    let mergeRequestSHA: String
    /// fork refs/heads/feature-x
    let forkSHA: String

    static let appBase = "line1\nline2\nline3\nline4\nline5\n"
    static let appPull = "line1\nline2 from PR\nline3\nline4\nline5\n"

    init(sandbox: GitSandbox) throws {
        self.sandbox = sandbox
        bare = sandbox.url("remotes/payments-api.git")
        forkBare = sandbox.url("remotes/contrib-payments-api.git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: forkBare, withIntermediateDirectories: true)
        try sandbox.git(["init", "-q", "--bare"], in: bare)
        try sandbox.git(["init", "-q", "--bare"], in: forkBare)

        let seed = try sandbox.initRepo("seed")
        try sandbox.git(["remote", "add", "origin", bare.path], in: seed)
        try sandbox.write("# Payments\n", to: seed.appending(path: "README.md"))
        try sandbox.write(Self.appBase, to: seed.appending(path: "src/app.txt"))
        baseSHA = try sandbox.commitAll(seed, "Initial")
        try sandbox.git(["push", "-q", "origin", "HEAD:refs/heads/main"], in: seed)

        try sandbox.write(Self.appPull, to: seed.appending(path: "src/app.txt"))
        pullSHA = try sandbox.commitAll(seed, "PR 42")
        try sandbox.git(["push", "-q", "origin", "HEAD:refs/pull/42/head"], in: seed)

        try sandbox.git(["checkout", "-q", "--detach", baseSHA], in: seed)
        try sandbox.write("merge request\n", to: seed.appending(path: "docs/mr.md"))
        mergeRequestSHA = try sandbox.commitAll(seed, "MR 7")
        try sandbox.git(["push", "-q", "origin", "HEAD:refs/merge-requests/7/head"], in: seed)

        try sandbox.git(["checkout", "-q", "--detach", baseSHA], in: seed)
        try sandbox.write("from the fork\n", to: seed.appending(path: "fork.txt"))
        forkSHA = try sandbox.commitAll(seed, "Fork feature")
        try sandbox.git(["push", "-q", forkBare.path, "HEAD:refs/heads/feature-x"], in: seed)

        try sandbox.mapURL(Self.originHTTPS, to: bare)
        try sandbox.mapURL(Self.originSSH, to: bare)
        try sandbox.mapURL(Self.forkHTTPS, to: forkBare)
        try sandbox.mapURL(Self.goneHTTPS, to: sandbox.url("remotes/does-not-exist.git"))
    }

    /// The user's own clone (origin = the https provider URL).
    func userCheckout(_ relative: String = "work/payments-api") throws -> URL {
        let checkout = sandbox.url(relative)
        try FileManager.default.createDirectory(at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sandbox.git(["clone", "-q", Self.originHTTPS, checkout.path], in: sandbox.root)
        try sandbox.configureIdentity(checkout)
        return checkout
    }

    /// Turns `checkout` into a simulated GitButler workspace.
    func makeGitButlerWorkspace(_ checkout: URL) throws {
        try sandbox.git(["checkout", "-q", "-b", "gitbutler/workspace"], in: checkout)
        try FileManager.default.createDirectory(at: checkout.appending(path: ".git/gitbutler"), withIntermediateDirectories: true)
        try sandbox.write("{}", to: checkout.appending(path: ".git/gitbutler/virtual_branches.toml"))
    }

    static let repository = Repository(
        key: RepoKey(account: AccountKey(kind: .github, host: "github.com", remoteUserID: "1"), remoteRepoID: "456"),
        namespacePath: "acme",
        name: "payments-api",
        fullPath: "acme/payments-api",
        webURL: URL(string: "https://github.com/acme/payments-api")!,
        cloneURLs: [originHTTPS, originSSH],
        defaultBranch: "main"
    )
}

/// Everything about a checkout MergeCue promises not to change.
struct CheckoutSnapshot: Equatable, CustomStringConvertible {
    var files: [String: String]
    var status: String
    var refs: String
    var head: String
    var index: String
    var stash: String

    init(_ checkout: URL, sandbox: GitSandbox) throws {
        files = try Self.hashTree(checkout)
        status = try sandbox.git(["status", "--porcelain=v1", "--untracked-files=all"], in: checkout)
        refs = try sandbox.git(["for-each-ref", "--format=%(objectname) %(refname)"], in: checkout)
            .split(separator: "\n").filter { !$0.contains(" refs/mergecue/") }.joined(separator: "\n")
        head = try sandbox.read(checkout.appending(path: ".git/HEAD"))
        let indexFile = checkout.appending(path: ".git/index")
        index = (try? Data(contentsOf: indexFile)).map(Self.sha256) ?? "none"
        stash = try sandbox.git(["stash", "list"], in: checkout)
    }

    var description: String { "files=\(files.count) status=[\(status)] head=\(head)" }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hashTree(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let base = directory.path
        guard let enumerator = FileManager.default.enumerator(atPath: base) else { return result }
        while let relative = enumerator.nextObject() as? String {
            if relative == ".git" || relative.hasPrefix(".git/") {
                enumerator.skipDescendants()
                continue
            }
            let full = (base as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue {
                result[relative] = sha256(try Data(contentsOf: URL(fileURLWithPath: full)))
            }
        }
        return result
    }
}

extension TaskID {
    static func sample(_ suffix: String) -> TaskID { TaskID(rawValue: "mc_\(suffix)")! }
}
