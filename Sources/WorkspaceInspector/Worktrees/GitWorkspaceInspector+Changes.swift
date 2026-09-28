import Foundation
import MergeCueCore

// Recomputing a task worktree's changes (S2). The worktree is agent-writable, so nothing in it is trusted:
// - git runs pinned to the git directories recorded when MergeCue created the worktree (`GIT_DIR` /
//   `GIT_WORK_TREE`), after checking that the worktree's `.git` still points there;
// - no repository filter, textconv or external diff driver ever runs: attributes are read from the empty tree
//   (`GIT_ATTR_SOURCE`), `core.attributesFile` is `/dev/null`, every `filter.<name>` found in the (pinned,
//   MergeCue-controlled) repository config is disabled with `-c`, and `--no-ext-diff --no-textconv` are passed;
// - system and global git config are not read (`GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_GLOBAL=/dev/null`).

extension GitWorkspaceInspector {
    /// Legacy entry point without a recorded pin: the git dir comes from the worktree itself (use the pinned
    /// variant for anything an agent can write to). Filters, textconv and external diff drivers are still disabled.
    public func changes(inWorktree path: String, since baseSHA: String, maxBytes: Int) async throws -> WorkspaceChanges {
        let absolute = Self.absolutePath(path)
        guard Self.pathKind(absolute) == .directory else { throw WorkspaceError.missingPath(absolute) }
        // `rev-parse` only (no `inspect`: `git status` there would run the worktree's filters).
        let noUserConfig = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        let dirs = try await git(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"],
            in: absolute, extraEnvironment: noUserConfig
        )
        let lines = dirs.stdout.split(separator: "\n").map(String.init)
        guard dirs.succeeded, lines.count >= 3 else { throw WorkspaceError.notARepository(path: absolute) }
        let pin = WorktreeGitDirs(gitDir: lines[1], commonDir: lines[2])
        return try await pinnedChanges(worktree: lines[0], pin: pin, baseSHA: baseSHA, maxBytes: maxBytes)
    }

    /// Changes of `path` since `baseSHA`, pinned to `gitDirs` (or, when nil, to the git dir under which
    /// `checkoutPath` registered this worktree). Refuses with `worktreeGitDirChanged` when the worktree's `.git`
    /// points anywhere else.
    ///
    /// Untracked files are included by marking them intent-to-add in a **temporary copy** of the worktree's index
    /// (`GIT_INDEX_FILE`), so neither the worktree's real index nor anything else is modified. The unified diff
    /// always uses `a/`/`b/` prefixes and is cut to `maxBytes` UTF-8 bytes on a character boundary.
    public func changes(
        inWorktree path: String, gitDirs: WorktreeGitDirs?, checkoutPath: String?, since baseSHA: String, maxBytes: Int
    ) async throws -> WorkspaceChanges {
        let worktree = Self.absolutePath(path)
        guard Self.pathKind(worktree) == .directory else { throw WorkspaceError.missingPath(worktree) }
        let pin: WorktreeGitDirs
        if let gitDirs {
            pin = gitDirs
        } else if let checkoutPath {
            pin = try await registeredGitDirs(worktree: worktree, checkoutPath: checkoutPath)
        } else {
            throw WorkspaceError.invalidRequest("no recorded git directory for \(worktree)")
        }
        try Self.verifyGitLink(worktree: worktree, pin: pin)
        return try await pinnedChanges(worktree: worktree, pin: pin, baseSHA: baseSHA, maxBytes: maxBytes)
    }

    // MARK: Pin verification

    /// Throws `worktreeGitDirChanged` unless `<worktree>/.git` is a regular file whose `gitdir:` resolves to
    /// `pin.gitDir` (linked worktree) or is the directory `pin.gitDir` itself (independent clone). Symlinks are refused.
    static func verifyGitLink(worktree: String, pin: WorktreeGitDirs) throws {
        let link = (worktree as NSString).appendingPathComponent(".git")
        var info = stat()
        guard lstat(link, &info) == 0 else { throw WorkspaceError.worktreeGitDirChanged(path: worktree) }
        let expected = canonicalPath(pin.gitDir)
        guard pathKind(expected) == .directory else { throw WorkspaceError.worktreeGitDirChanged(path: worktree) }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            guard info.st_size < 4096, let data = FileManager.default.contents(atPath: link),
                  let text = String(data: data, encoding: .utf8)
            else { throw WorkspaceError.worktreeGitDirChanged(path: worktree) }
            let lines = text.split(whereSeparator: \.isNewline)
            guard lines.count == 1, lines[0].hasPrefix("gitdir: ") else { throw WorkspaceError.worktreeGitDirChanged(path: worktree) }
            var target = String(lines[0].dropFirst("gitdir: ".count))
            if !target.hasPrefix("/") { target = (worktree as NSString).appendingPathComponent(target) }
            guard canonicalPath(target) == expected else { throw WorkspaceError.worktreeGitDirChanged(path: worktree) }
        case S_IFDIR:
            guard canonicalPath(link) == expected else { throw WorkspaceError.worktreeGitDirChanged(path: worktree) }
        default:
            throw WorkspaceError.worktreeGitDirChanged(path: worktree)
        }
    }

    /// The git dir under which the (trusted) mapped checkout registered `worktree`: the entry of
    /// `<common dir>/worktrees/*` whose `gitdir` file points back to `<worktree>/.git`.
    func registeredGitDirs(worktree: String, checkoutPath: String) async throws -> WorktreeGitDirs {
        let context: RepoContext
        switch try await inspectContext(path: checkoutPath) {
        case .success(let value): context = value
        case .failure(let info): throw WorkspaceError.notARepository(path: info.path)
        }
        let common = Self.canonicalPath(context.commonDir)
        let registry = (common as NSString).appendingPathComponent("worktrees")
        let expectedLink = Self.canonicalPath((worktree as NSString).appendingPathComponent(".git"))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: registry)) ?? []
        for name in names.sorted() {
            let entry = (registry as NSString).appendingPathComponent(name)
            let back = (entry as NSString).appendingPathComponent("gitdir")
            guard let data = FileManager.default.contents(atPath: back),
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  Self.canonicalPath(text) == expectedLink
            else { continue }
            return WorktreeGitDirs(gitDir: entry, commonDir: common)
        }
        throw WorkspaceError.worktreeGitDirChanged(path: worktree)
    }

    // MARK: Pinned, filter-free git

    /// Environment + `-c` options that pin git to `pin` and keep it from running repository-defined commands.
    func hardenedGitSettings(worktree: String, pin: WorktreeGitDirs) async throws -> (environment: [String: String], config: [String]) {
        var env: [String: String] = [
            "GIT_DIR": pin.gitDir,
            "GIT_WORK_TREE": worktree,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        ]
        let emptyTree = try await gitChecked(["hash-object", "--no-filters", "-t", "tree", "/dev/null"], in: worktree, extraEnvironment: env).trimmed
        guard Self.isHexObjectID(emptyTree) else {
            throw WorkspaceError.gitFailed(command: "hash-object", exitCode: 0, stderr: "unexpected empty tree id")
        }
        env["GIT_ATTR_SOURCE"] = emptyTree
        var config = ["core.attributesFile=/dev/null"]
        let filters = try await git(["config", "--name-only", "--get-regexp", #"^filter\."#], in: worktree, extraEnvironment: env)
        var names = Set<String>()
        for line in filters.stdout.split(separator: "\n") {
            let key = String(line)
            guard key.hasPrefix("filter."), let lastDot = key.lastIndex(of: "."), lastDot > key.index(key.startIndex, offsetBy: 6) else { continue }
            names.insert(String(key[key.index(key.startIndex, offsetBy: 7)..<lastDot]))
        }
        for name in names.sorted() {
            // A name git's `-c` parser cannot address cannot be neutralized: refuse rather than run it.
            guard !name.isEmpty, !name.contains("="), !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw WorkspaceError.invalidRequest("the repository defines a filter driver MergeCue cannot disable")
            }
            config += ["filter.\(name).clean=", "filter.\(name).smudge=", "filter.\(name).process=", "filter.\(name).required=false"]
        }
        return (env, config)
    }

    func pinnedChanges(worktree: String, pin: WorktreeGitDirs, baseSHA: String, maxBytes: Int) async throws -> WorkspaceChanges {
        guard Self.isHexObjectID(baseSHA) else {
            throw WorkspaceError.invalidRequest("base '\(baseSHA)' is not a commit id")
        }
        let (env, config) = try await hardenedGitSettings(worktree: worktree, pin: pin)
        func run(_ arguments: [String], index: [String: String] = [:], limit: Int = GitWorkspaceInspector.defaultMaxOutput) async throws -> GitOutput {
            try await git(arguments, in: worktree, extraEnvironment: env.merging(index) { $1 }, extraConfig: config, maxOutputBytes: limit)
        }
        func checked(_ arguments: [String], index: [String: String] = [:], limit: Int = GitWorkspaceInspector.defaultMaxOutput) async throws -> GitOutput {
            try await gitChecked(arguments, in: worktree, extraEnvironment: env.merging(index) { $1 }, extraConfig: config, maxOutputBytes: limit)
        }

        let base = try await run(["rev-parse", "-q", "--verify", "\(baseSHA)^{commit}"])
        guard base.succeeded, !base.trimmed.isEmpty else {
            throw WorkspaceError.invalidRequest("base commit \(baseSHA) is not present in \(worktree)")
        }
        let baseCommit = base.trimmed

        let indexPath = try await checked(["rev-parse", "--path-format=absolute", "--git-path", "index"]).trimmed
        let scratch = FileManager.default.temporaryDirectory.appending(path: "mergecue-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temporaryIndex = scratch.appending(path: "index").path
        if Self.pathKind(indexPath) == .file {
            try FileManager.default.copyItem(atPath: indexPath, toPath: temporaryIndex)
        }
        let indexEnvironment = ["GIT_INDEX_FILE": temporaryIndex]

        try await checked(["add", "--intent-to-add", "--", "."], index: indexEnvironment)

        let diffOptions = [
            "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames", "--no-relative",
            "--src-prefix=a/", "--dst-prefix=b/", "--ignore-submodules=none",
        ]
        let names = try await checked(["diff", "--name-status", "-z"] + diffOptions + [baseCommit, "--"], index: indexEnvironment)
        let limit = max(0, maxBytes)
        let diff = try await checked(["diff"] + diffOptions + [baseCommit, "--"], index: indexEnvironment, limit: limit + 16)
        let bounded = BoundedText.truncate(diff.stdout, maxBytes: limit)

        let head = try await run(["rev-parse", "-q", "--verify", "HEAD^{commit}"])
        let status = try await checked(["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none"])

        return WorkspaceChanges(
            changedPaths: GitOutputParsing.nameStatus(names.stdout),
            unifiedDiff: bounded.text,
            truncated: bounded.isTruncated || diff.stdoutTruncated,
            headSHA: head.succeeded && !head.trimmed.isEmpty ? head.trimmed : nil,
            hasUncommittedChanges: !status.stdout.isEmpty
        )
    }
}
