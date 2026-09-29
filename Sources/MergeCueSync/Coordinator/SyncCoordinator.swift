import Foundation
import MergeCueCore
import MergeCueStore

/// The sync service (`SyncControlling`): one independent `AccountSyncer` per connected account.
///
/// Each account polls on its own schedule (DECISIONS D35, GitButler-style): lists immediately at start, every 15 min,
/// on manual refresh and on debounced events (return/focus, wake, network recovery); between lists each change
/// request's details refresh progressively by how recently it changed (30 s → 5 min → 30 min; hot/pending-checks CRs
/// stay fast); failed CRs back off (terminal for not found/forbidden); account failures back off exponentially with
/// jitter (cap 15 min), rate limits wait for the provider's reset (else 5 → 15 → 60 min), expired credentials stop
/// the account until `accountsDidChange()`. One account never blocks another. Every cycle persists its batch
/// atomically before notifications and the event handler run.
public actor SyncCoordinator: SyncControlling {
    private let database: MergeCueDatabase
    private let credentials: any CredentialStoring
    private let providers: any ProviderFactory
    private let environment: SyncEnvironment
    private var syncers: [AccountKey: AccountSyncer] = [:]
    private var isStarted = false
    private var networkTask: Task<Void, Never>?

    public init(
        database: MergeCueDatabase,
        credentials: any CredentialStoring,
        providers: any ProviderFactory,
        notifier: any NotificationDelivering,
        clock: any MCClock,
        configuration: SyncConfiguration = .default,
        requestLedger: ProviderRequestLedger? = nil,
        onChange: @escaping @Sendable (EngineChange) -> Void = { _ in }
    ) {
        self.database = database
        self.credentials = credentials
        self.providers = providers
        self.environment = SyncEnvironment(
            database: database, notifier: notifier, clock: clock, configuration: configuration, onChange: onChange,
            requestLedger: requestLedger
        )
    }

    /// Per-account rolling request counts. When no ledger was injected, Sync counts one request per provider call;
    /// the runtime injects the ledger its HTTP transports record into (304s excluded).
    public nonisolated var requestLedger: ProviderRequestLedger { environment.requestLedger }

    // MARK: SyncControlling

    /// Loads the accounts and starts every enabled account's loop (first cycle runs immediately).
    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        await reloadAccounts()
    }

    /// Stops every loop and cancels in-flight cycles (a cancelled cycle writes nothing).
    public func stop() async {
        isStarted = false
        networkTask?.cancel()
        networkTask = nil
        for syncer in syncers.values {
            await syncer.stop()
        }
    }

    /// Manual refresh of every account (lists now, failed change requests retried), concurrently; returns when their
    /// cycles finished. Accounts that cannot sync now (auth expired, paused, rate limited until a future reset) are
    /// skipped.
    public func refreshAll() async {
        let all = Array(syncers.values)
        await withTaskGroup(of: Void.self) { group in
            for syncer in all {
                group.addTask { await syncer.refresh() }
            }
        }
    }

    public func refresh(account: AccountKey) async {
        await syncers[account]?.refresh()
    }

    /// Reloads accounts and credentials: new accounts start, removed ones stop, changed ones (or ones whose
    /// credentials had expired) restart with a fresh provider and an immediate cycle.
    public func accountsDidChange() async {
        await reloadAccounts()
    }

    public func statuses() async -> [AccountSyncStatus] {
        var result: [AccountSyncStatus] = []
        for syncer in syncers.values {
            result.append(await syncer.currentStatus())
        }
        return result.sorted { $0.account < $1.account }
    }

    public func setEventHandler(_ handler: @escaping @Sendable ([ChangeEvent]) async -> Void) async {
        environment.update { $0.eventHandler = handler }
    }

    /// Pauses notifications until `until` (nil resumes). Syncing, events and attention continue.
    public func setNotificationsPaused(until: Date?) async {
        environment.update { $0.pausedUntil = until }
    }

    /// Per-category notification switches. Attention items and events are unaffected; only alerts are filtered.
    public func setNotificationPreferences(_ preferences: NotificationPreferences) async {
        environment.update { $0.preferences = preferences }
    }

    /// Global quiet hours (the engine's persisted setting): alerts are held back inside the window.
    public func setQuietHours(_ quietHours: QuietHours?) async {
        environment.update { $0.configuration.quietHours = quietHours }
    }

    // MARK: Additional control

    /// Which PRs/MRs are tracked besides the user's own. Excluded scopes stop being listed; their change requests
    /// leave the lists and are cleaned up like any other that disappears (hydrated once, items resolved, removed).
    public func setTrackingPreferences(_ preferences: TrackingPreferences) async {
        environment.update { $0.tracking = preferences }
    }

    public func trackingPreferences() -> TrackingPreferences {
        environment.current.tracking
    }

    public func notificationPreferences() -> NotificationPreferences {
        environment.current.preferences
    }

    public func notificationsPausedUntil() -> Date? {
        environment.current.pausedUntil
    }

    public var configuration: SyncConfiguration {
        environment.current.configuration
    }

    /// Replaces the configuration; enabling/disabling accounts takes effect immediately, intervals from the next
    /// scheduling decision.
    public func updateConfiguration(_ configuration: SyncConfiguration) async {
        environment.update { $0.configuration = configuration }
        await reloadAccounts()
    }

    /// Enables or disables syncing of one account (disabled accounts show `paused`).
    public func setAccountEnabled(_ account: AccountKey, enabled: Bool) async {
        environment.update {
            if enabled {
                $0.configuration.disabledAccounts.remove(account)
            } else {
                $0.configuration.disabledAccounts.insert(account)
            }
        }
        await reloadAccounts()
    }

    /// Marks every change request hot until `until`: details refresh at the fast tier.
    public func setHot(until: Date?) async {
        environment.update { $0.hotUntil = until }
        await rescheduleAll()
    }

    /// Change requests with an active agent task refresh their details at the fast tier.
    public func setActiveChangeRequests(_ keys: Set<ChangeRequestKey>) async {
        let changed = environment.current.hotChangeRequests != keys
        environment.update { $0.hotChangeRequests = keys }
        if changed { await rescheduleAll() }
    }

    public func activeChangeRequests() -> Set<ChangeRequestKey> {
        environment.current.hotChangeRequests
    }

    /// The user came back (popover opened, main window became key): every account lists again unless it did so for
    /// an event less than `eventRefreshDebounce` ago, and CRs that failed terminally a while ago are retried.
    public func userDidReturn() async {
        await eventRefreshAll(retryTerminalFailures: true)
    }

    /// Call after the Mac wakes from sleep: every account lists again (debounced like other events).
    public func handleSystemWake() async {
        await eventRefreshAll(retryTerminalFailures: false)
    }

    private func eventRefreshAll(retryTerminalFailures: Bool) async {
        let all = Array(syncers.values)
        await withTaskGroup(of: Void.self) { group in
            for syncer in all {
                group.addTask { await syncer.eventRefresh(retryTerminalFailures: retryTerminalFailures) }
            }
        }
    }

    private func rescheduleAll() async {
        for syncer in syncers.values {
            await syncer.reschedule()
        }
    }

    /// Consumes connectivity updates (`true` = network reachable); every offline → online transition triggers a
    /// (debounced) event refresh of every account. Replaces a previous observation.
    public func observeNetwork(_ updates: AsyncStream<Bool>) {
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            var wasReachable: Bool?
            for await isReachable in updates {
                if Task.isCancelled { return }
                defer { wasReachable = isReachable }
                guard isReachable, wasReachable == false else { continue }
                await self?.eventRefreshAll(retryTerminalFailures: false)
            }
        }
    }

    /// Starts observing the system network path (`NWPathMonitor`).
    public func startNetworkMonitoring() {
        observeNetwork(NetworkReachability().updates())
    }

    // MARK: Accounts

    private func reloadAccounts() async {
        let accounts: [Account]
        do {
            accounts = try await database.accounts()
        } catch {
            MCLog.sync.error("Could not load accounts: \(error)")
            return
        }
        let keys = Set(accounts.map(\.id))
        for (key, syncer) in syncers where !keys.contains(key) {
            await syncer.stop()
            syncers[key] = nil
            environment.requestLedger.reset(key)
        }
        let disabled = environment.current.configuration.disabledAccounts
        for account in accounts {
            let credential = loadCredential(account.id)
            let isDisabled = disabled.contains(account.id)
            var previousStatus: AccountSyncStatus?
            if let syncer = syncers[account.id] {
                let status = await syncer.status
                let unchanged = syncer.account == account && syncer.credential == credential && status.state != .authExpired
                if unchanged {
                    if isDisabled {
                        if status.state != .paused { await syncer.stop(state: .paused) }
                    } else if isStarted {
                        await syncer.start()
                    }
                    continue
                }
                await syncer.stop()
                previousStatus = status
            }
            let provider = credential.map { providers.makeProvider(account: account, credential: $0) }
            let syncer = AccountSyncer(
                account: account, credential: credential, provider: provider, environment: environment,
                previousStatus: previousStatus
            )
            syncers[account.id] = syncer
            if isDisabled {
                await syncer.stop(state: .paused)
            } else if isStarted {
                await syncer.start()
            }
        }
        environment.onChange(.syncStatus)
    }

    private func loadCredential(_ account: AccountKey) -> Credential? {
        do {
            return try credentials.load(for: account)
        } catch {
            MCLog.sync.error("Could not load the credential of a \(account.kind.rawValue) account.")
            return nil
        }
    }
}
