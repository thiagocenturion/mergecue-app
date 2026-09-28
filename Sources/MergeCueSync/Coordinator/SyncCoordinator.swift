import Foundation
import MergeCueCore
import MergeCueStore

/// The sync service (`SyncControlling`): one independent `AccountSyncer` per connected account.
///
/// Each account polls on its own schedule (immediate first run; 90 s by default, 45 s while hot, 5 min in the
/// overnight idle window), backs off exponentially with jitter on failures (cap 15 min), waits for rate-limit
/// resets, stops on expired credentials until `accountsDidChange()`, and never blocks another account.
/// Every cycle persists its batch atomically before notifications and the event handler run.
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
        onChange: @escaping @Sendable (EngineChange) -> Void = { _ in }
    ) {
        self.database = database
        self.credentials = credentials
        self.providers = providers
        self.environment = SyncEnvironment(
            database: database, notifier: notifier, clock: clock, configuration: configuration, onChange: onChange
        )
    }

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

    /// Refreshes every account concurrently and returns when their cycles finished. Accounts that cannot sync now
    /// (auth expired, paused, rate limited until a future reset) are skipped.
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
            result.append(await syncer.status)
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

    // MARK: Additional control

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

    /// Marks sync as hot (e.g. an agent task is active) until `until`: accounts poll at `hotInterval`.
    public func setHot(until: Date?) async {
        environment.update { $0.hotUntil = until }
    }

    /// Call after the Mac wakes from sleep: refreshes every account.
    public func handleSystemWake() async {
        await refreshAll()
    }

    /// Consumes connectivity updates (`true` = network reachable); every offline → online transition triggers
    /// `refreshAll()`. Replaces a previous observation.
    public func observeNetwork(_ updates: AsyncStream<Bool>) {
        networkTask?.cancel()
        networkTask = Task { [weak self] in
            var wasReachable: Bool?
            for await isReachable in updates {
                if Task.isCancelled { return }
                defer { wasReachable = isReachable }
                guard isReachable, wasReachable == false else { continue }
                await self?.refreshAll()
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
