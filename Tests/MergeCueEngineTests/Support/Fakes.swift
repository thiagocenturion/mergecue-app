import Foundation
import MergeCueCore

// In-test fakes for the Core protocols the engine depends on. Deterministic, no network, no git, no Keychain.

/// A lock-protected box for fake state.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func update<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

// MARK: - Credentials

final class FakeCredentialStore: CredentialStoring {
    struct State: Sendable {
        var items: [String: Credential] = [:]
        var failSaves = false
        var log: [String] = []
    }

    let state = Locked(State())

    func save(_ credential: Credential, for account: AccountKey) throws {
        try state.update { state in
            if state.failSaves { throw CredentialStoreError.unavailable("locked") }
            state.items[account.id] = credential
            state.log.append("save:\(account.id)")
        }
    }

    func load(for account: AccountKey) throws -> Credential? {
        state.get().items[account.id]
    }

    func delete(for account: AccountKey) throws {
        state.update { state in
            state.items[account.id] = nil
            state.log.append("delete:\(account.id)")
        }
    }
}

// MARK: - Sync

actor FakeSync: SyncControlling {
    private(set) var handler: (@Sendable ([ChangeEvent]) async -> Void)?
    private(set) var accountsDidChangeCount = 0
    private(set) var refreshed: [AccountKey?] = []
    private(set) var pausedUntil: Date?
    private(set) var preferences: NotificationPreferences?
    private(set) var quietHours: QuietHours??
    private(set) var tracking: TrackingPreferences?
    var statusList: [AccountSyncStatus] = []

    func start() async {}
    func stop() async {}
    func refreshAll() async { refreshed.append(nil) }
    func refresh(account: AccountKey) async { refreshed.append(account) }
    func accountsDidChange() async { accountsDidChangeCount += 1 }
    func statuses() async -> [AccountSyncStatus] { statusList }
    func setEventHandler(_ handler: @escaping @Sendable ([ChangeEvent]) async -> Void) async { self.handler = handler }
    func setNotificationsPaused(until: Date?) async { pausedUntil = until }
    func setNotificationPreferences(_ preferences: NotificationPreferences) async { self.preferences = preferences }
    func setQuietHours(_ quietHours: QuietHours?) async { self.quietHours = .some(quietHours) }
    func setTrackingPreferences(_ preferences: TrackingPreferences) async { tracking = preferences }

    func setStatuses(_ statuses: [AccountSyncStatus]) { statusList = statuses }
}

/// Records the engine's own alerts.
final class RecordingNotifier: NotificationDelivering, @unchecked Sendable {
    private let lock = NSLock()
    private var _delivered: [GroupedNotification] = []
    var delivered: [GroupedNotification] { lock.withLock { _delivered } }
    func deliver(_ notification: GroupedNotification) async { lock.withLock { _delivered.append(notification) } }
}

// MARK: - Providers

/// Remote state shared by every fake provider, plus a log of every write.
final class FakeWorld: @unchecked Sendable {
    struct Write: Sendable, Hashable {
        var kind: String
        var target: String
        var body: String
    }

    struct State: Sendable {
        var users: [String: ProviderUser] = [:]           // keyed by ProviderKind raw value
        var probeError: ProviderError?
        var heads: [String: HeadInfo] = [:]                 // keyed by ChangeRequestKey.id
        var threads: [String: ReviewThread] = [:]           // keyed by ThreadKey.id
        var logs: [String: String] = [:]                    // keyed by CheckKey.id
        var logError: ProviderError?
        var logFetches = 0
        var diffs: [String: DiffPayload] = [:]              // keyed by ChangeRequestKey.id
        var writeError: ProviderError?
        var writes: [Write] = []
        var capabilityOverrides: [ProviderKind: [Capability: CapabilitySupport]] = [:]
        var fetchable = true
        var repositories: [Repository] = []
        var repositoryError: ProviderError?
        var repositoryCalls: [String?] = []                 // namespace paths asked for (nil = all)
        var nextCommentID = 1
    }

    let state = Locked(State())

    var writes: [Write] { state.get().writes }

    func setHead(_ key: ChangeRequestKey, sha: String, state crState: ChangeRequestState = .open, at date: Date) {
        state.update { $0.heads[key.id] = HeadInfo(headSHA: sha, state: crState, isDraft: false, updatedAt: date) }
    }

    func setThread(_ thread: ReviewThread) {
        state.update { $0.threads[thread.key.id] = thread }
    }

    static func manifest(_ kind: ProviderKind, overrides: [Capability: CapabilitySupport] = [:]) -> CapabilityManifest {
        var entries: [Capability: CapabilitySupport] = [:]
        for capability in Capability.allCases {
            entries[capability] = .supported
        }
        for (capability, support) in overrides {
            entries[capability] = support
        }
        return CapabilityManifest(provider: kind, entries: entries)
    }
}

struct FakeProvider: ReviewProvider {
    static let protocolVersion = 1
    let world: FakeWorld
    let instance: ProviderInstance
    let account: Account?

    var capabilities: CapabilityManifest {
        FakeWorld.manifest(instance.kind, overrides: world.state.get().capabilityOverrides[instance.kind] ?? [:])
    }

    func currentUser() async throws -> ProviderUser {
        let state = world.state.get()
        if let error = state.probeError { throw error }
        guard let user = state.users[instance.kind.rawValue] else { throw ProviderError.unauthorized("no user") }
        return user
    }

    func listNamespaces() async throws -> [Namespace] {
        [Namespace(id: "acme", path: "acme", displayName: "Acme", kind: .organization)]
    }

    func listRepositories(namespace: Namespace?) async throws -> [Repository] {
        try world.state.update { state in
            state.repositoryCalls.append(namespace?.path)
            if let error = state.repositoryError { throw error }
            guard let namespace else { return state.repositories }
            return state.repositories.filter { $0.namespacePath == namespace.path }
        }
    }
    func listChangeRequests(_ query: ChangeRequestQuery) async throws -> ChangeRequestPage { .unchanged }

    func hydrate(_ summary: ChangeRequestSummary) async throws -> ChangeRequestSnapshot {
        throw ProviderError.unsupported(.listAuthored, reason: "fake")
    }

    func headInfo(for changeRequest: ChangeRequestKey) async throws -> HeadInfo {
        guard let head = world.state.get().heads[changeRequest.id] else { throw ProviderError.notFound("head") }
        return head
    }

    func thread(_ key: ThreadKey) async throws -> ReviewThread {
        guard let thread = world.state.get().threads[key.id] else { throw ProviderError.notFound("thread") }
        return thread
    }

    func failureLog(for check: CheckRun, maxBytes: Int) async throws -> LogExcerpt {
        world.state.update { $0.logFetches += 1 }
        let state = world.state.get()
        if let error = state.logError { throw error }
        guard let log = state.logs[check.key.id] else { throw ProviderError.notFound("log") }
        return LogExcerpt.make(rawLog: log, maxBytes: maxBytes, fullLogURL: URL(string: "https://example.test/logs/\(check.key.remoteID)"))
    }

    func diff(for changeRequest: ChangeRequestKey, maxBytes: Int) async throws -> DiffPayload {
        guard let diff = world.state.get().diffs[changeRequest.id] else { throw ProviderError.notFound("diff") }
        return diff
    }

    func createReply(to thread: ThreadKey, body: String) async throws -> ReviewComment {
        try world.state.update { state in
            if let error = state.writeError { throw error }
            state.writes.append(.init(kind: "reply", target: thread.id, body: body))
            let id = "reply-\(state.nextCommentID)"
            state.nextCommentID += 1
            let me = Person(remoteID: account?.id.remoteUserID ?? "me", username: account?.username ?? "me")
            let comment = ReviewComment(id: id, author: me, body: body, createdAt: Date(timeIntervalSince1970: 1_767_225_600))
            state.threads[thread.id]?.comments.append(comment)
            return comment
        }
    }

    func resolveThread(_ thread: ThreadKey, resolved: Bool) async throws {
        try world.state.update { state in
            if let error = state.writeError { throw error }
            state.writes.append(.init(kind: "resolve", target: thread.id, body: String(resolved)))
            state.threads[thread.id]?.isResolved = resolved
        }
    }

    func requestChanges(on changeRequest: ChangeRequestKey, body: String) async throws {
        world.state.update { $0.writes.append(.init(kind: "request_changes", target: changeRequest.id, body: body)) }
    }

    func merge(_ changeRequest: ChangeRequestKey, expectedHeadSHA: String) async throws {
        world.state.update { $0.writes.append(.init(kind: "merge", target: changeRequest.id, body: expectedHeadSHA)) }
    }

    func fetchHeadSpec(for snapshot: ChangeRequestSnapshot) -> FetchHeadSpec? {
        guard world.state.get().fetchable else { return nil }
        return FetchHeadSpec(
            remoteURLs: snapshot.summary.repository.cloneURLs,
            refspec: "refs/pull/\(snapshot.summary.key.number)/head",
            expectedSHA: snapshot.summary.headSHA
        )
    }

    func deepLink(to target: DeepLinkTarget) -> URL? { nil }
}

struct FakeProviderFactory: ProviderFactory {
    let world: FakeWorld

    func makeProvider(account: Account, credential: Credential) -> any ReviewProvider {
        FakeProvider(world: world, instance: account.instance, account: account)
    }

    func makeProbe(instance: ProviderInstance, credential: Credential) -> any ReviewProvider {
        FakeProvider(world: world, instance: instance, account: nil)
    }

    func capabilities(for kind: ProviderKind) -> CapabilityManifest {
        FakeWorld.manifest(kind, overrides: world.state.get().capabilityOverrides[kind] ?? [:])
    }
}

// MARK: - Workspace

final class FakeWorkspace: WorkspaceInspecting, @unchecked Sendable {
    struct State: Sendable {
        var checkouts: [String: CheckoutInfo] = [:]
        var matchConfidence: MappingConfidence = .exact
        var suggestionConfidence: MappingConfidence = .probable
        var prepareError: WorkspaceError?
        var baseSHA = "head111"
        var worktreeRoot = "/tmp/mergecue-tests/worktrees"
        var changes: WorkspaceChanges = WorkspaceChanges(changedPaths: [], unifiedDiff: "", truncated: false, hasUncommittedChanges: false)
        var patchCheck: PatchApplyCheck?
        var prepared: [WorktreeRequest] = []
        var removedWorktrees: [String] = []
        var applied: [(patch: String, checkout: String)] = []
        var checked: [String] = []
        var commands: [[String]] = []
        /// Pins passed to the pinned `changes` (S2).
        var pinnedCalls: [(gitDirs: WorktreeGitDirs?, checkoutPath: String?)] = []
        var gitDirTampered = false
    }

    let state = Locked(State())

    var appliedPatches: [String] { state.get().applied.map(\.checkout) }

    func setCheckout(_ path: String, safety: CheckoutSafety, head: String = "local111", gitButler: Bool = false) {
        state.update {
            $0.checkouts[path] = CheckoutInfo(
                path: path, isRepository: true, topLevel: path, currentBranch: "feature/retries", headSHA: head,
                isDirty: safety == .dirty, dirtyPaths: safety == .dirty ? ["README.md"] : [],
                gitButler: GitButlerStatus(isManaged: gitButler, workspaceBranch: gitButler ? "gitbutler/workspace" : nil),
                safety: safety
            )
        }
    }

    func setChanges(_ paths: [String], diff: String? = nil, head: String = "wt222") {
        let unified = diff ?? paths.map { "diff --git a/\($0) b/\($0)\n--- a/\($0)\n+++ b/\($0)\n@@ -1 +1 @@\n-old\n+new\n" }.joined()
        state.update {
            $0.changes = WorkspaceChanges(
                changedPaths: paths.map { ChangedPath(path: $0, status: .modified) }, unifiedDiff: unified, truncated: false,
                headSHA: head, hasUncommittedChanges: false
            )
        }
    }

    func inspect(path: String) async throws -> CheckoutInfo {
        guard let info = state.get().checkouts[path] else { throw WorkspaceError.missingPath(path) }
        return info
    }

    func suggestMappings(for repo: Repository, searchRoots: [String]) async -> [MappingSuggestion] {
        searchRoots.map { MappingSuggestion(checkoutPath: $0 + "/" + repo.name, confidence: state.get().suggestionConfidence, reason: "name match") }
    }

    func match(repo: Repository, checkoutPath: String) async -> MappingSuggestion {
        MappingSuggestion(checkoutPath: checkoutPath, confidence: state.get().matchConfidence, matchedRemote: repo.cloneURLs.first, reason: "fake")
    }

    func prepareWorktree(_ request: WorktreeRequest) async throws -> PreparedWorktree {
        try state.update { state in
            if let error = state.prepareError { throw error }
            state.prepared.append(request)
            return PreparedWorktree(
                path: state.worktreeRoot + "/" + request.taskID.rawValue, baseSHA: state.baseSHA,
                localRef: PreparedWorktree.localRef(for: request.taskID),
                gitDirs: WorktreeGitDirs(gitDir: request.checkoutPath + "/.git/worktrees/" + request.taskID.rawValue, commonDir: request.checkoutPath + "/.git")
            )
        }
    }

    func changes(inWorktree path: String, since baseSHA: String, maxBytes: Int) async throws -> WorkspaceChanges {
        state.get().changes
    }

    func changes(inWorktree path: String, gitDirs: WorktreeGitDirs?, checkoutPath: String?, since baseSHA: String, maxBytes: Int) async throws -> WorkspaceChanges {
        try state.update { state in
            state.pinnedCalls.append((gitDirs, checkoutPath))
            if state.gitDirTampered { throw WorkspaceError.worktreeGitDirChanged(path: path) }
            return state.changes
        }
    }

    func checkPatch(_ patch: String, into checkoutPath: String, expectedHeadSHA: String?) async throws -> PatchApplyCheck {
        state.update { $0.checked.append(checkoutPath) }
        let info = state.get().checkouts[checkoutPath]
        return state.get().patchCheck ?? PatchApplyCheck(
            canApply: info?.safety == .safe, problems: [], targetHeadSHA: info?.headSHA, targetSafety: info?.safety ?? .missing
        )
    }

    func applyPatch(_ patch: String, into checkoutPath: String, expectedHeadSHA: String?) async throws -> PatchApplyCheck {
        state.update { $0.applied.append((patch, checkoutPath)) }
        let info = state.get().checkouts[checkoutPath]
        return PatchApplyCheck(canApply: true, targetHeadSHA: info?.headSHA, targetSafety: info?.safety ?? .safe)
    }

    func removeWorktree(path: String, checkoutPath: String) async throws {
        state.update { $0.removedWorktrees.append(path) }
    }

    func runCommand(_ argv: [String], in directory: String, timeout: TimeInterval) async throws -> CommandResult {
        state.update { $0.commands.append(argv) }
        return CommandResult(exitCode: 0, stdout: "", stderr: "", durationMs: 0)
    }
}
