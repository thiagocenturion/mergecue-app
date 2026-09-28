import Foundation
import MergeCueCore

/// Everything `inspect` learned, including internal details (raw remotes, git dirs) public results omit.
struct RepoContext: Sendable {
    var info: CheckoutInfo
    var topLevel: String
    var gitDir: String
    var commonDir: String
    var rawRemotes: [RawRemote]
}

extension GitWorkspaceInspector {
    public func inspect(path: String) async throws -> CheckoutInfo {
        switch try await inspectContext(path: path) {
        case .success(let context): context.info
        case .failure(let info): info
        }
    }

    enum InspectOutcome: Sendable {
        case success(RepoContext)
        /// Missing path or not a (non-bare) repository.
        case failure(CheckoutInfo)
    }

    /// Read-only inspection. Every command runs with `GIT_OPTIONAL_LOCKS=0`, so not even the index stat cache
    /// is refreshed.
    func inspectContext(path: String) async throws -> InspectOutcome {
        let absolute = Self.absolutePath(path)
        switch Self.pathKind(absolute) {
        case .missing:
            return .failure(CheckoutInfo(path: absolute, isRepository: false, safety: .missing))
        case .file:
            return .failure(CheckoutInfo(path: absolute, isRepository: false, safety: .notARepository))
        case .directory:
            break
        }

        let inside = try await git(["rev-parse", "--is-inside-work-tree"], in: absolute)
        guard inside.succeeded, inside.trimmed == "true" else {
            return .failure(CheckoutInfo(path: absolute, isRepository: false, safety: .notARepository))
        }
        let dirs = try await gitChecked(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"],
            in: absolute
        )
        let lines = dirs.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3 else {
            throw WorkspaceError.gitFailed(command: "rev-parse", exitCode: 0, stderr: "unexpected output")
        }
        let topLevel = lines[0], gitDir = lines[1], commonDir = lines[2]

        let remotesOutput = try await git(
            ["config", "-z", "--get-regexp", #"^remote\..*\.(url|pushurl)$"#], in: topLevel
        )
        let rawRemotes = remotesOutput.succeeded ? GitOutputParsing.remotes(fromConfigZ: remotesOutput.stdout) : []

        let symbolic = try await git(["symbolic-ref", "-q", "HEAD"], in: topLevel)
        let headRef: String? = symbolic.succeeded ? symbolic.trimmed : nil
        let currentBranch = headRef.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }

        let head = try await git(["rev-parse", "-q", "--verify", "HEAD^{commit}"], in: topLevel)
        let headSHA: String? = head.succeeded && !head.trimmed.isEmpty ? head.trimmed : nil

        let status = try await gitChecked(
            ["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none"],
            in: topLevel
        )
        let allDirty = GitOutputParsing.porcelainPaths(status.stdout)
        let isDirty = !allDirty.isEmpty || status.stdoutTruncated

        let worktreeList = try await git(["worktree", "list", "--porcelain", "-z"], in: topLevel)
        let worktrees = worktreeList.succeeded ? GitOutputParsing.worktreePaths(worktreeList.stdout) : [topLevel]

        let gitButler = try await detectGitButler(topLevel: topLevel, commonDir: commonDir, headRef: headRef)

        let safety: CheckoutSafety
        if gitButler.isManaged {
            safety = .gitButlerWorkspace
        } else if isDirty {
            safety = .dirty
        } else if headRef == nil, headSHA != nil {
            safety = .detached
        } else {
            safety = .safe
        }

        let info = CheckoutInfo(
            path: absolute,
            isRepository: true,
            topLevel: topLevel,
            remotes: rawRemotes.map(\.publicRemote),
            currentBranch: currentBranch,
            headSHA: headSHA,
            isDirty: isDirty,
            dirtyPaths: Array(allDirty.prefix(Self.maxDirtyPaths)),
            worktrees: worktrees,
            gitButler: gitButler,
            safety: safety
        )
        return .success(RepoContext(
            info: info, topLevel: topLevel, gitDir: gitDir, commonDir: commonDir, rawRemotes: rawRemotes
        ))
    }

    /// GitButler signals. **Any** signal marks the checkout as managed: a false positive only routes work through
    /// an independent clone and blocks direct patch import, while a false negative could let MergeCue write into a
    /// mixed virtual-branch workspace.
    func detectGitButler(topLevel: String, commonDir: String, headRef: String?) async throws -> GitButlerStatus {
        var evidence: [String] = []
        var workspaceBranch: String?

        let gitButlerHeads = ["refs/heads/gitbutler/workspace", "refs/heads/gitbutler/integration"]
        if let headRef, headRef.hasPrefix("refs/heads/gitbutler/") {
            workspaceBranch = String(headRef.dropFirst("refs/heads/".count))
            evidence.append("HEAD is on the GitButler branch \(workspaceBranch ?? headRef)")
        }

        let dataDirectory = (commonDir as NSString).appendingPathComponent("gitbutler")
        if Self.pathKind(dataDirectory) == .directory {
            evidence.append(".git/gitbutler directory exists")
        }

        let refs = try await git(
            ["for-each-ref", "--format=%(refname)", "--count=50", "refs/heads/gitbutler/"], in: topLevel
        )
        let branchRefs = refs.succeeded
            ? refs.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            : []
        if !branchRefs.isEmpty {
            let names = branchRefs.prefix(3).map { $0.replacingOccurrences(of: "refs/heads/", with: "") }
            evidence.append("GitButler branches present: \(names.joined(separator: ", "))\(branchRefs.count > 3 ? ", …" : "")")
            if workspaceBranch == nil, let known = gitButlerHeads.first(where: branchRefs.contains) {
                workspaceBranch = String(known.dropFirst("refs/heads/".count))
            }
        }

        let config = try await git(["config", "--name-only", "--get-regexp", #"^gitbutler\."#], in: topLevel)
        if config.succeeded, !config.trimmed.isEmpty {
            let keys = config.trimmed.split(separator: "\n").prefix(3).joined(separator: ", ")
            evidence.append("gitbutler.* configuration present (\(keys))")
        }

        return GitButlerStatus(isManaged: !evidence.isEmpty, workspaceBranch: workspaceBranch, evidence: evidence)
    }
}
