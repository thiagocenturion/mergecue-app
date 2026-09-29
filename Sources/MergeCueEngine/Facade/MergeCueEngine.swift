import Foundation
import MergeCueCore
import MergeCueIPC
import MergeCueStore

/// The single façade the UI and the IPC/MCP server use (docs/ARCHITECTURE.md §8).
///
/// - Tasks, leases and the task state machine are persisted with optimistic concurrency (`MCTask.version`).
/// - Every MCP method of §5 is served by `handle(method:params:client:)` with the guarantees listed there.
/// - Remote writes only happen through `perform(previewID:approval:)` after an approved, fingerprinted preview;
///   claiming, submitting, copying a handoff command or evaluating rules never write to a provider.
///
/// The public API is grouped by area in extensions (Accounts, Inbox, Tasks, Checkout, ReviewGate, Rules, Data);
/// see `Sources/MergeCueEngine/README.md`.
public actor MergeCueEngine: IPCRequestHandling {
    let env: EngineEnvironment
    let log = MCLog.engine

    // Change stream subscribers.
    private var subscribers: [UUID: AsyncStream<EngineChange>.Continuation] = [:]
    // Stale-lease monitor.
    private var monitorTask: Task<Void, Never>?
    private(set) var isRunning = false

    /// Per-task sliding window of agent write attempts (rate limit).
    var writeAttempts: [TaskID: [Date]] = [:]
    /// Sliding window of `propose_rule` calls (not tied to a task).
    var proposalAttempts: [Date] = []
    /// Action previews awaiting a decision (ephemeral: a restart requires a new preview).
    var previews: [String: ReviewPreview] = [:]
    /// Fingerprints whose write is running right now (reentrancy guard for idempotency).
    var inFlightFingerprints: Set<String> = []
    /// In-flight task creations per attention item (one active task per item, also under reentrancy).
    var pendingCreations: [String: Task<TaskID, any Error>] = [:]
    /// Aggregated MCP read audit per client (`ReadScope.swift`).
    var readAuditWindows: [String: ReadAuditWindow] = [:]
    /// Sliding one-minute window of provider-hitting reads per MCP client.
    var providerReadAttempts: [String: [Date]] = [:]
    /// Short-lived cache of provider-hitting read results.
    var providerReadCache: [String: CachedProviderRead] = [:]
    /// A hot-change-request update for Sync is scheduled (coalesces bursts of task changes).
    private var activeChangeRequestsUpdatePending = false

    public init(environment: EngineEnvironment) {
        self.env = environment
    }

    var database: MergeCueDatabase { env.database }
    var clock: any MCClock { env.clock }
    var now: Date { env.clock.now }
    var ids: IDGenerator { env.ids }

    // MARK: Lifecycle

    /// Registers the rule event handler with Sync and starts the stale-lease monitor. Idempotent.
    /// Does not start Sync itself (the runtime owns its lifecycle).
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        await env.sync.setEventHandler { [weak self] events in
            await self?.handleNewEvents(events)
        }
        if let paused = try? await database.setting(SettingsKey.notificationsPausedUntil, as: Date.self) {
            await env.sync.setNotificationsPaused(until: paused)
        }
        await env.sync.setNotificationPreferences(await notificationPreferences())
        await env.sync.setTrackingPreferences(await trackingPreferences())
        await env.sync.setQuietHours(await quietHours())
        await updateSyncActiveChangeRequests()
        // Leases that expired while the app was not running.
        await sweepExpiredLeases()
        let interval = env.staleCheckInterval
        let clock = env.clock
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.sweepExpiredLeases()
                await self.runMaintenanceIfDue()
            }
        }
        log.info("engine started")
    }

    /// Stops the monitor and finishes every change stream.
    public func stop() async {
        monitorTask?.cancel()
        monitorTask = nil
        isRunning = false
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    /// A new, independent stream of change notifications for the UI (coalesce on the consumer side).
    public func changes() -> AsyncStream<EngineChange> {
        let (stream, continuation) = AsyncStream<EngineChange>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Forwards a change signal that originated outside the engine (Sync's `onChange`: sync status, attention,
    /// change requests) to every `changes()` subscriber, so the UI observes a single stream. Wired by
    /// `MergeCueRuntime`.
    public func forwardExternalChange(_ change: EngineChange) {
        emit(change)
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    func emit(_ change: EngineChange) {
        for continuation in subscribers.values {
            continuation.yield(change)
        }
        if case .tasks = change, isRunning, !activeChangeRequestsUpdatePending {
            activeChangeRequestsUpdatePending = true
            Task { await self.updateSyncActiveChangeRequests() }
        }
    }

    /// Tells Sync which change requests have a task waiting for or claimed by an agent, so their details refresh at
    /// the fastest tier (DECISIONS D35).
    func updateSyncActiveChangeRequests() async {
        activeChangeRequestsUpdatePending = false
        guard let tasks = try? await database.tasks(states: [.waitingForAgent, .working]) else { return }
        await env.sync.setActiveChangeRequests(Set(tasks.map(\.origin.changeRequest)))
    }

    // MARK: Shared helpers

    /// Runs `body` and maps any failure to `EngineError` (the UI-facing error type).
    func uiCall<T: Sendable>(_ body: () async throws -> T) async throws(EngineError) -> T {
        do {
            return try await body()
        } catch {
            throw EngineErrorMapping.engineError(from: error)
        }
    }

    func requireTask(_ id: TaskID) async throws -> MCTask {
        guard let task = try await database.task(id) else {
            throw EngineError.notFound("Task \(id.rawValue)")
        }
        return task
    }

    func requireAccount(_ key: AccountKey) async throws -> Account {
        guard let account = try await database.account(key) else {
            throw EngineError.notFound("Account \(key.kind.displayName) \(key.host)")
        }
        return account
    }

    /// A provider for a connected account (credential loaded from the credential store).
    func provider(for key: AccountKey) async throws -> any ReviewProvider {
        let account = try await requireAccount(key)
        let credential: Credential?
        do {
            credential = try env.credentials.load(for: key)
        } catch {
            throw EngineError.failed("The credential for \(account.displayLabel) could not be read. Reconnect the account.")
        }
        guard let credential else {
            throw EngineError.failed("No credential stored for \(account.displayLabel). Reconnect the account.")
        }
        return env.providers.makeProvider(account: account, credential: credential)
    }

    /// The handle agents see for an account (`mona-dev@github.com`).
    static func accountHandle(username: String, host: String) -> String {
        "\(username)@\(host)"
    }

    func accountHandles() async -> [AccountKey: String] {
        let accounts = (try? await database.accounts()) ?? []
        return Dictionary(accounts.map { ($0.id, Self.accountHandle(username: $0.username, host: $0.id.host)) }, uniquingKeysWith: { a, _ in a })
    }

    func handle(for key: AccountKey, in handles: [AccountKey: String]) -> String {
        handles[key] ?? Self.accountHandle(username: key.remoteUserID, host: key.host)
    }

    func appendAudit(
        actor: String,
        action: String,
        target: String,
        outcome: AuditEntry.Outcome,
        detail: String = "",
        taskID: TaskID? = nil
    ) async {
        let entry = AuditEntry(
            id: ids.auditID(), at: now, actor: actor, action: action, target: target, outcome: outcome,
            detail: detail, taskID: taskID
        )
        do {
            try await database.appendAudit(entry)
            emit(.audit)
        } catch {
            log.error("audit write failed: \(error)")
        }
    }
}

/// Keys of engine-owned settings.
enum SettingsKey {
    static let notificationsPausedUntil = "engine.notifications_paused_until"
    static let quietHours = "engine.quiet_hours"
    static let notificationPreferences = "engine.notification_preferences"
    static let trackingPreferences = "engine.tracking_preferences"
    static let lastMaintenance = "engine.last_maintenance"
    static let agentReadAccess = "engine.agent_read_access"
    static let lastRefreshAt = "engine.last_refresh_at"
    static let checkoutSearchFolders = "engine.checkout_search_folders"
    static func repositoryListFetchedAt(_ account: AccountKey) -> String { "engine.repository_list_fetched_at.\(account.id)" }
    static func performedAction(_ fingerprint: String) -> String { "engine.performed_action.\(fingerprint)" }
    static func eventTask(_ eventID: String) -> String { "engine.event_task.\(eventID)" }
}
