import Foundation
import MergeCueCore

extension GitWorkspaceInspector {
    /// Name of the marker file written into the git dir of MergeCue's independent clones.
    static let cloneMarkerName = "mergecue-task"

    /// Fetches the change request head into `refs/mergecue/tasks/<task id>` and creates an isolated, detached
    /// checkout of it at `destinationRoot/<task id>`.
    ///
    /// - Regular checkouts: `git fetch` (through the configured remote whose URL matches `fetch.remoteURLs`, else
    ///   directly from those URLs, using the user's credential helpers / SSH agent) into the private ref, then
    ///   `git worktree add --detach`. The user's working tree, index, HEAD, branches, remote-tracking refs
    ///   (`--refmap=`), `FETCH_HEAD` and stash are untouched.
    /// - GitButler-managed checkouts: nothing is written into that repository. MergeCue creates an **independent
    ///   clone** instead — `git clone --no-checkout --reference-if-able <checkout's git dir> --dissociate <url>`
    ///   borrows the local objects to avoid re-downloading, then copies them so the clone never depends on the
    ///   GitButler repository — fetches the head into the clone's private ref and checks it out detached.
    ///
    /// `baseSHA` is the fetched head; `expectedSHA` (if given) must match it or `headMismatch` is thrown.
    public func prepareWorktree(_ request: WorktreeRequest) async throws -> PreparedWorktree {
        let localRef = PreparedWorktree.localRef(for: request.taskID)
        let refspec = request.fetch.refspec
        try await validateRefspec(refspec)
        if let expected = request.fetch.expectedSHA, !Self.isHexObjectID(expected) {
            throw WorkspaceError.invalidRequest("expected SHA '\(expected)' is not a commit id")
        }
        for url in request.fetch.remoteURLs where !Self.isAcceptableRemoteURL(url) {
            throw WorkspaceError.invalidRequest("unsupported remote URL \(CanonicalRemote.sanitizedURL(url))")
        }

        let destinationRoot = Self.absolutePath(request.destinationRoot)
        guard Self.isInsideOrEqual(destinationRoot, root: worktreeRoot.path) else {
            throw WorkspaceError.pathOutsideCheckout(destinationRoot)
        }
        let destination = (destinationRoot as NSString).appendingPathComponent(request.taskID.rawValue)
        guard Self.pathKind(destination) == .missing else {
            throw WorkspaceError.invalidRequest("\(destination) already exists; remove the previous worktree first")
        }

        let context: RepoContext
        switch try await inspectContext(path: request.checkoutPath) {
        case .success(let value):
            context = value
        case .failure(let info):
            if info.safety == .missing { throw WorkspaceError.missingPath(info.path) }
            throw WorkspaceError.notARepository(path: info.path)
        }

        try FileManager.default.createDirectory(
            atPath: destinationRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )

        if context.info.gitButler.isManaged {
            return try await prepareIndependentClone(
                request: request, context: context, destination: destination, localRef: localRef
            )
        }
        return try await prepareLinkedWorktree(
            request: request, context: context, destination: destination, localRef: localRef
        )
    }

    // MARK: Linked worktree

    private func prepareLinkedWorktree(
        request: WorktreeRequest, context: RepoContext, destination: String, localRef: String
    ) async throws -> PreparedWorktree {
        let sources = fetchSources(for: request.fetch, remotes: context.rawRemotes)
        let sha = try await fetchHead(
            sources: sources, refspec: request.fetch.refspec, localRef: localRef, in: context.topLevel
        )
        if let expected = request.fetch.expectedSHA, !Self.sameCommit(expected, sha) {
            _ = try? await git(["update-ref", "-d", localRef], in: context.topLevel)
            throw WorkspaceError.headMismatch(expected: expected, actual: sha)
        }
        let added = try await git(
            ["worktree", "add", "--detach", "--quiet", "--", destination, sha], in: context.topLevel
        )
        guard added.succeeded else {
            _ = try? await git(["worktree", "remove", "--force", "--", destination], in: context.topLevel)
            if Self.pathKind(destination) != .missing, Self.isStrictlyInside(destination, root: worktreeRoot.path) {
                try? FileManager.default.removeItem(atPath: destination)
            }
            _ = try? await git(["update-ref", "-d", localRef], in: context.topLevel)
            throw WorkspaceError.gitFailed(
                command: "worktree add", exitCode: added.exitCode, stderr: Self.cleanMessage(added.stderr)
            )
        }
        // Record the git dirs now, before any agent runs in the worktree (S2): later reads are pinned to them.
        let gitDirs = try await registeredGitDirs(worktree: destination, checkoutPath: context.topLevel)
        return PreparedWorktree(path: destination, baseSHA: sha, localRef: localRef, gitDirs: gitDirs)
    }

    // MARK: Independent clone (GitButler)

    private func prepareIndependentClone(
        request: WorktreeRequest, context: RepoContext, destination: String, localRef: String
    ) async throws -> PreparedWorktree {
        // Clone from the repository that holds the ref: prefer the user's configured URL for it (it carries the
        // user's working auth setup), else the provider URLs.
        let urls = fetchSources(for: request.fetch, remotes: context.rawRemotes).map(\.url)
        var failures: [String] = []
        var clonedURL: String?
        for url in urls {
            let output = try await git(
                [
                    "clone", "--quiet", "--no-checkout", "--no-recurse-submodules",
                    "--reference-if-able", context.commonDir, "--dissociate", "--", url, destination,
                ],
                in: worktreeRoot.path, timeout: networkTimeout
            )
            if output.succeeded {
                clonedURL = url
                break
            }
            failures.append(Self.fetchFailureMessage(url: url, refspec: nil, stderr: output.stderr))
            removeOwnedDirectory(destination)
        }
        guard let clonedURL else {
            throw WorkspaceError.fetchFailed(failures.isEmpty ? "no remote URL to clone from" : failures.joined(separator: "; "))
        }

        do {
            try Data(request.taskID.rawValue.utf8).write(
                to: URL(fileURLWithPath: destination).appending(path: ".git/\(Self.cloneMarkerName)")
            )
            let sha = try await fetchHead(
                sources: [FetchSource(remoteName: "origin", url: clonedURL)],
                refspec: request.fetch.refspec, localRef: localRef, in: destination
            )
            if let expected = request.fetch.expectedSHA, !Self.sameCommit(expected, sha) {
                throw WorkspaceError.headMismatch(expected: expected, actual: sha)
            }
            try await gitChecked(["checkout", "--quiet", "--detach", sha], in: destination)
            let gitDir = Self.canonicalPath((destination as NSString).appendingPathComponent(".git"))
            return PreparedWorktree(
                path: destination, baseSHA: sha, localRef: localRef, gitDirs: WorktreeGitDirs(gitDir: gitDir, commonDir: gitDir)
            )
        } catch {
            removeOwnedDirectory(destination)
            throw error
        }
    }

    // MARK: Fetching

    struct FetchSource: Sendable, Hashable {
        /// A configured remote name (git then uses its own configured URL), or nil to fetch `url` directly.
        var remoteName: String?
        /// Raw URL (never shown unsanitized).
        var url: String
        var argument: String { remoteName ?? url }
    }

    /// Configured remotes whose URL matches `fetch.remoteURLs` first, then the URLs themselves.
    func fetchSources(for fetch: FetchHeadSpec, remotes: [RawRemote]) -> [FetchSource] {
        let wanted = Set(fetch.remoteURLs.compactMap(CanonicalRemote.parse))
        var sources: [FetchSource] = []
        if let remote = remotes.first(where: { remote in
            CanonicalRemote.parse(remote.fetchURL).map(wanted.contains) ?? false
        }) {
            sources.append(FetchSource(remoteName: remote.name, url: remote.fetchURL))
        }
        for url in fetch.remoteURLs where !sources.contains(where: { $0.url == url }) {
            sources.append(FetchSource(remoteName: nil, url: url))
        }
        return sources
    }

    /// Fetches `+refspec:localRef` from the first source that works; returns the fetched commit.
    func fetchHead(sources: [FetchSource], refspec: String, localRef: String, in directory: String) async throws -> String {
        guard !sources.isEmpty else {
            throw WorkspaceError.fetchFailed("no remote URL for \(refspec)")
        }
        var failures: [String] = []
        for source in sources {
            let output = try await git(
                [
                    "fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head",
                    "--no-prune", "--refmap=", "--", source.argument, "+\(refspec):\(localRef)",
                ],
                in: directory, timeout: networkTimeout
            )
            if output.succeeded {
                let resolved = try await gitChecked(["rev-parse", "--verify", "\(localRef)^{commit}"], in: directory)
                return resolved.trimmed
            }
            failures.append(Self.fetchFailureMessage(url: source.url, refspec: refspec, stderr: output.stderr))
        }
        throw WorkspaceError.fetchFailed(failures.joined(separator: "; "))
    }

    static func fetchFailureMessage(url: String, refspec: String?, stderr: String) -> String {
        let where_ = CanonicalRemote.sanitizedURL(url)
        let detail = cleanMessage(stderr, maxBytes: 600)
        let lowered = stderr.lowercased()
        if let refspec, lowered.contains("couldn't find remote ref") || lowered.contains("could not find remote ref") {
            return "\(refspec) was not found on \(where_) (the change request may be closed or its head deleted)"
        }
        if lowered.contains("authentication failed") || lowered.contains("could not read username")
            || lowered.contains("permission denied") || lowered.contains("terminal prompts disabled") {
            return "\(where_) refused access; check that git can authenticate for it (credential helper or SSH key): \(detail)"
        }
        return "could not fetch from \(where_): \(detail)"
    }

    // MARK: Removal

    /// Removes a MergeCue worktree or clone. Refuses anything not strictly inside `worktreeRoot`; linked
    /// worktrees are removed through `git worktree remove --force` in their repository (discarding the agent's
    /// uncommitted work — callers confirm first) and the task's private ref is deleted. Independent clones are
    /// deleted only when they carry MergeCue's marker.
    public func removeWorktree(path: String, checkoutPath: String) async throws {
        let target = Self.absolutePath(path)
        guard Self.isStrictlyInside(target, root: worktreeRoot.path) else {
            throw WorkspaceError.pathOutsideCheckout(target)
        }
        let canonicalTarget = Self.canonicalPath(target)
        let taskName = (target as NSString).lastPathComponent
        let taskRef = TaskID(rawValue: taskName).map(PreparedWorktree.localRef(for:))

        var checkoutTopLevel: String?
        var registered = false
        if case .success(let context)? = try? await inspectContext(path: checkoutPath) {
            checkoutTopLevel = context.topLevel
            registered = context.info.worktrees.contains { Self.canonicalPath($0) == canonicalTarget }
        }

        if registered, let topLevel = checkoutTopLevel {
            let removed = try await git(["worktree", "remove", "--force", "--", canonicalTarget], in: topLevel)
            if !removed.succeeded, Self.pathKind(target) != .missing {
                throw WorkspaceError.gitFailed(
                    command: "worktree remove", exitCode: removed.exitCode, stderr: Self.cleanMessage(removed.stderr)
                )
            }
            if let taskRef {
                _ = try? await git(["update-ref", "-d", taskRef], in: topLevel)
            }
            removeOwnedDirectory(target)
            return
        }

        switch Self.pathKind(target) {
        case .missing:
            if let taskRef, let topLevel = checkoutTopLevel {
                _ = try? await git(["update-ref", "-d", taskRef], in: topLevel)
            }
            return
        case .file:
            throw WorkspaceError.invalidRequest("\(target) is not a MergeCue worktree")
        case .directory:
            let marker = (target as NSString).appendingPathComponent(".git/\(Self.cloneMarkerName)")
            guard Self.pathKind(marker) == .file else {
                throw WorkspaceError.invalidRequest("\(target) is not a MergeCue worktree of \(checkoutPath)")
            }
            try FileManager.default.removeItem(atPath: target)
        }
    }

    /// Deletes `path` only when it is strictly inside `worktreeRoot`.
    func removeOwnedDirectory(_ path: String) {
        guard Self.pathKind(path) != .missing, Self.isStrictlyInside(path, root: worktreeRoot.path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: Validation

    /// A full ref name (`refs/…`) accepted by `git check-ref-format`, with no refspec syntax.
    func validateRefspec(_ refspec: String) async throws {
        guard refspec.hasPrefix("refs/"), !refspec.contains(":"), !refspec.contains("*"), !refspec.hasPrefix("+"),
              !refspec.contains(where: { $0.isWhitespace || $0.isNewline })
        else {
            throw WorkspaceError.invalidRequest("'\(refspec)' is not a full ref name")
        }
        let check = try await git(["check-ref-format", refspec], in: worktreeRootOrTemp())
        guard check.succeeded else {
            throw WorkspaceError.invalidRequest("'\(refspec)' is not a valid ref name")
        }
    }

    /// Rejects option-looking arguments, remote-helper syntax (`transport::address`) and control characters.
    static func isAcceptableRemoteURL(_ url: String) -> Bool {
        guard !url.isEmpty, !url.hasPrefix("-"),
              !url.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == " " })
        else { return false }
        if let helper = url.range(of: "::"), !url[..<helper.lowerBound].contains("/") { return false }
        return true
    }

    /// A directory that exists, for commands that need no repository.
    func worktreeRootOrTemp() -> String {
        Self.pathKind(worktreeRoot.path) == .directory ? worktreeRoot.path : FileManager.default.temporaryDirectory.path
    }
}
