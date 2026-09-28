import Foundation
import MergeCueCore
import MergeCueStore

// Repository mappings and task checkouts (PLAN §6). The engine never edits, checks out, stashes, rebases, commits
// or pushes in a user's checkout: code tasks get an isolated worktree at the fetched PR head, and anything unsafe
// (unmapped, unconfirmed mismatch, dirty, detached, GitButler workspace, unfetchable head) yields the `blocked`
// checkout policy with "Blocked: map a safe checkout" — read-only inspection stays possible.

extension MergeCueEngine {
    public static let blockedCheckoutPrefix = "Blocked: map a safe checkout"

    // MARK: Mappings

    /// Mappings of one repository (all when nil).
    public func mappings(repo: RepoKey? = nil) async throws(EngineError) -> [RepoMapping] {
        try await uiCall { try await database.mappings(repo: repo) }
    }

    /// Maps a repository to a local checkout. The confidence comes from `WorkspaceInspecting.match` (remote URL /
    /// host / path); only an `exact` match is confirmed automatically — others require `confirmMapping`, unless
    /// `confirm` is true (the owner explicitly chose "Map anyway" after seeing `previewMapping`). A subfolder of a
    /// checkout maps the checkout's top level. Missing folders and folders that are not git checkouts are refused.
    @discardableResult
    public func addMapping(repo: RepoKey, repoFullPath: String, checkoutPath: String, confirm: Bool = false) async throws(EngineError) -> RepoMapping {
        try await uiCall {
            let preview = try await mappingPreview(repo: repo, repoFullPath: repoFullPath, checkoutPath: checkoutPath)
            guard preview.isRepository else {
                throw EngineError.invalidInput(preview.suggestion.reason)
            }
            let suggestion = preview.suggestion
            let existing = try await database.mappings(repo: repo)
                .first { ($0.checkoutPath as NSString).standardizingPath == suggestion.checkoutPath }
            let mapping = RepoMapping(
                id: existing?.id ?? ids.mappingID(),
                repo: repo,
                repoFullPath: preview.repository.fullPath,
                checkoutPath: suggestion.checkoutPath,
                confidence: suggestion.confidence,
                matchedRemote: suggestion.matchedRemote,
                confirmedAt: suggestion.confidence == .exact || confirm ? now : nil,
                createdAt: existing?.createdAt ?? now
            )
            try await database.upsertMapping(mapping)
            emit(.mappings)
            return mapping
        }
    }

    /// What mapping `checkoutPath` to `repo` would record, without saving anything: the match (resolved to the
    /// checkout's top level), the remotes found and the remotes expected — shown before "Map anyway".
    public func previewMapping(repo: RepoKey, repoFullPath: String, checkoutPath: String) async throws(EngineError) -> MappingPreview {
        try await uiCall { try await mappingPreview(repo: repo, repoFullPath: repoFullPath, checkoutPath: checkoutPath) }
    }

    private func mappingPreview(repo: RepoKey, repoFullPath: String, checkoutPath: String) async throws -> MappingPreview {
        let path = (checkoutPath as NSString).standardizingPath
        guard path.hasPrefix("/") else {
            throw EngineError.invalidInput("Choose an absolute folder path for the checkout.")
        }
        let repository = try await mappableRepository(repo, fullPath: repoFullPath)
        var suggestion = await env.workspace.match(repo: repository, checkoutPath: path)
        suggestion.checkoutPath = (suggestion.checkoutPath as NSString).standardizingPath
        let info = try? await env.workspace.inspect(path: suggestion.checkoutPath)
        let isRepository = suggestion.confidence != .mismatch || (info?.isRepository ?? false)
        return MappingPreview(
            repository: repository,
            chosenPath: path,
            suggestion: suggestion,
            isRepository: isRepository,
            remotesFound: (info?.remotes ?? []).map { "\($0.name) → \(CanonicalRemote.sanitizedURL($0.fetchURL))" },
            remotesExpected: CanonicalRemote.candidates(for: repository).map(\.description).sorted()
        )
    }

    /// The stored repository, else one built from the account's instance and the full path (so its remotes can
    /// still be matched when the listing has not been stored yet).
    private func mappableRepository(_ key: RepoKey, fullPath: String) async throws -> Repository {
        if let stored = try await findRepository(key) { return stored }
        let trimmed = fullPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let base = (try await database.account(key.account))?.instance.webURL ?? key.account.kind.defaultInstance.webURL
        let slash = trimmed.lastIndex(of: "/")
        return Repository(
            key: key,
            namespacePath: slash.map { String(trimmed[..<$0]) } ?? "",
            name: slash.map { String(trimmed[trimmed.index(after: $0)...]) } ?? trimmed,
            fullPath: trimmed,
            webURL: base.appending(path: trimmed)
        )
    }

    /// The user confirms a probable/mismatched mapping.
    @discardableResult
    public func confirmMapping(id: String) async throws(EngineError) -> RepoMapping {
        try await uiCall {
            guard var mapping = try await database.mapping(id: id) else {
                throw EngineError.notFound("Mapping \(id)")
            }
            mapping.confirmedAt = now
            try await database.upsertMapping(mapping)
            emit(.mappings)
            return mapping
        }
    }

    public func removeMapping(id: String) async throws(EngineError) {
        try await uiCall {
            guard try await database.deleteMapping(id: id) else {
                throw EngineError.notFound("Mapping \(id)")
            }
            emit(.mappings)
        }
    }

    /// Candidate checkouts for a repository under `searchRoots` (default: `EngineEnvironment.mappingSearchRoots`).
    public func mappingSuggestions(for repo: RepoKey, searchRoots: [String]? = nil) async throws(EngineError) -> [MappingSuggestion] {
        try await uiCall {
            guard let repository = try await findRepository(repo) else {
                throw EngineError.notFound("Repository")
            }
            return await env.workspace.suggestMappings(for: repository, searchRoots: searchRoots ?? env.mappingSearchRoots)
        }
    }

    /// Read-only inspection of a checkout (remotes, branch, dirty state, GitButler).
    public func inspectCheckout(path: String) async throws(EngineError) -> CheckoutInfo {
        try await uiCall { try await env.workspace.inspect(path: path) }
    }

    func findRepository(_ key: RepoKey) async throws -> Repository? {
        if let stored = try await database.repositories(account: key.account).first(where: { $0.key == key }) {
            return stored
        }
        return try await database.snapshots(account: key.account).first { $0.summary.repository.key == key }?.summary.repository
    }

    // MARK: Task checkout

    /// Prepares the task's checkout and records it on the task: an isolated worktree at the PR head (base SHA
    /// recorded) for code tasks, read-only access for `draft_reply`, or `blocked` with the reason.
    @discardableResult
    public func prepareCheckout(_ taskID: TaskID) async throws(EngineError) -> TaskCheckout {
        try await uiCall { try await prepareCheckoutRecorded(taskID) }
    }

    /// Best effort at task creation; failures leave `checkout` unset.
    func prepareCheckoutQuietly(_ taskID: TaskID) async {
        do {
            _ = try await prepareCheckoutRecorded(taskID)
        } catch {
            log.info("checkout not prepared for \(taskID): \(error)")
        }
    }

    private func prepareCheckoutRecorded(_ taskID: TaskID) async throws -> TaskCheckout {
        let task = try await requireTask(taskID)
        guard !task.isTerminal else {
            throw EngineError.invalidTransition("Task \(taskID.rawValue) is \(task.state.rawValue).")
        }
        let checkout = await planCheckout(for: task)
        let latest = try await requireTask(taskID)
        try await persistUpdate(latest) { $0.checkout = checkout }
        let message: String = switch checkout.policy {
        case .isolatedWorktree:
            "Isolated worktree prepared at \(checkout.worktreePath ?? "?") (base \(checkout.baseSHA ?? "?")). Your checkout was not modified."
        case .readOnly:
            checkout.mappedCheckoutPath.map { "Read-only access to \($0)." } ?? "No checkout needed for this task."
        case .blocked:
            checkout.blockedReason ?? Self.blockedCheckoutPrefix
        }
        await recordActivity(taskID, actor: .system, kind: .note, message: message, data: ["checkout_policy": checkout.policy.rawValue])
        return checkout
    }

    private func planCheckout(for task: MCTask) async -> TaskCheckout {
        let snapshot = try? await database.snapshot(task.origin.changeRequest)
        let source = snapshot?.summary.sourceBranch ?? task.trigger.sourceBranch
        let target = snapshot?.summary.targetBranch ?? task.trigger.targetBranch
        func blocked(_ reason: String, mapped: String? = nil, gitButler: Bool = false) -> TaskCheckout {
            TaskCheckout(
                policy: .blocked, mappedCheckoutPath: mapped, sourceBranch: source, targetBranch: target,
                isGitButlerManaged: gitButler, blockedReason: "\(Self.blockedCheckoutPrefix) — \(reason)"
            )
        }
        let repoPath = task.origin.changeRequestRef.repoFullPath
        let mappings = (try? await database.mappings(repo: task.origin.changeRequest.repo)) ?? []
        let usable = mappings.filter { $0.isConfirmed && $0.confidence != .mismatch }
            + mappings.filter { $0.isConfirmed && $0.confidence == .mismatch }
        guard let mapping = usable.sorted(by: { rank($0) < rank($1) }).first else {
            if task.type == .draftReply {
                return TaskCheckout(policy: .readOnly, sourceBranch: source, targetBranch: target)
            }
            let reason = mappings.isEmpty
                ? "no local checkout is mapped for \(repoPath)."
                : "the mapping for \(repoPath) is not confirmed yet."
            return blocked(reason)
        }
        let info: CheckoutInfo
        do {
            info = try await env.workspace.inspect(path: mapping.checkoutPath)
        } catch {
            return task.type == .draftReply
                ? TaskCheckout(policy: .readOnly, sourceBranch: source, targetBranch: target)
                : blocked("the checkout at \(mapping.checkoutPath) cannot be inspected.", mapped: mapping.checkoutPath)
        }
        if info.gitButler.isManaged || info.safety == .gitButlerWorkspace {
            return task.type == .draftReply
                ? TaskCheckout(policy: .readOnly, sourceBranch: source, targetBranch: target, isGitButlerManaged: true)
                : blocked(
                    "\(mapping.checkoutPath) is a GitButler workspace; MergeCue never edits a mixed workspace. Review the patch and apply it manually or map a separate checkout.",
                    mapped: mapping.checkoutPath, gitButler: true
                )
        }
        guard info.safety == .safe else {
            return task.type == .draftReply
                ? TaskCheckout(policy: .readOnly, sourceBranch: source, targetBranch: target)
                : blocked("\(mapping.checkoutPath): \(info.safety.displayName.lowercased()).", mapped: mapping.checkoutPath)
        }
        if task.type == .draftReply {
            return TaskCheckout(policy: .readOnly, mappedCheckoutPath: mapping.checkoutPath, sourceBranch: source, targetBranch: target)
        }
        guard let snapshot else {
            return blocked("the change request snapshot is not available yet.", mapped: mapping.checkoutPath)
        }
        let spec: FetchHeadSpec?
        do {
            spec = try await provider(for: task.origin.account).fetchHeadSpec(for: snapshot)
        } catch {
            spec = nil
        }
        guard let spec else {
            return blocked("the \(task.origin.providerKind.changeRequestAbbreviation) head cannot be fetched.", mapped: mapping.checkoutPath)
        }
        let request = WorktreeRequest(
            taskID: task.id, checkoutPath: mapping.checkoutPath, fetch: spec,
            destinationRoot: MergeCuePaths.fileSystemPath(env.paths.worktrees)
        )
        do {
            let prepared = try await env.workspace.prepareWorktree(request)
            return TaskCheckout(
                policy: .isolatedWorktree, mappedCheckoutPath: mapping.checkoutPath, worktreePath: prepared.path,
                baseSHA: prepared.baseSHA, sourceBranch: source, targetBranch: target, gitDirs: prepared.gitDirs
            )
        } catch {
            let detail = SecretRedactor.redact((error as? LocalizedError)?.errorDescription ?? "\(error)")
            return blocked("fetching the head into an isolated worktree failed: \(detail)", mapped: mapping.checkoutPath)
        }
    }

    private func rank(_ mapping: RepoMapping) -> Int {
        switch mapping.confidence {
        case .exact: 0
        case .probable: 1
        case .mismatch: 2
        }
    }
}

extension MergeCueEngine {
    /// The changes of a task's isolated worktree, recomputed with git pinned to the git dirs recorded at creation
    /// (or derived from the mapped checkout for tasks created before they were recorded) — S2.
    func worktreeChanges(_ checkout: TaskCheckout, worktree: String, base: String, maxBytes: Int) async throws -> WorkspaceChanges {
        try await env.workspace.changes(
            inWorktree: worktree, gitDirs: checkout.gitDirs, checkoutPath: checkout.mappedCheckoutPath, since: base, maxBytes: maxBytes
        )
    }
}
