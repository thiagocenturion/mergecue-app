import Foundation
import MergeCueCore
import MergeCueStore

/// The sync service (`SyncControlling`): one independent `AccountSyncer` per connected account.
///
/// Each account polls on its own schedule and never more often than its refresh interval (default 15 min): one
/// cycle per interval lists and refreshes the change requests that changed or are due (every cycle, every second
/// cycle once idle; checks running for over 2 h count as stuck). Return/focus, wake and network recovery only catch
/// up on an overdue cycle. Failed CRs retry at later cycles (terminal for not found/forbidden); account failures
/// back off exponentially, never sooner than the interval; rate limits wait for the provider's reset; expired
/// credentials stop the account until `accountsDidChange()`. Automatic sync pauses while the user paused it or a
/// schedule rule applies (weekends, outside working hours, holidays) and resumes on its own; Refresh always works.
/// One account never blocks another. Every cycle persists its batch atomically before notifications and the event
/// handler run.
public actor SyncCoordinator: SyncControlling {
    private let database: MergeCueDatabase
    private let credentials: any CredentialStoring
    private let providers: any ProviderFactory
    private let environment: SyncEnvironment
    private var syncers: [AccountKey: AccountSyncer] = [:]
    private var isStarted = false
    private var networkTask: Task<Void, Never>?
    private let holidaySource: (any HolidaySource)?
    private var holidayTask: Task<Void, Never>?
    /// Holiday calendars the current holidays were loaded for (nil = not loaded).
    private var loadedHolidayCalendars: [String]?

    public init(
        database: MergeCueDatabase,
        credentials: any CredentialStoring,
        providers: any ProviderFactory,
        notifier: any NotificationDelivering,
        clock: any MCClock,
        configuration: SyncConfiguration = .default,
        requestLedger: ProviderRequestLedger? = nil,
        holidaySource: (any HolidaySource)? = nil,
        onChange: @escaping @Sendable (EngineChange) -> Void = { _ in }
    ) {
        self.holidaySource = holidaySource
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
        await updateHolidays()
        await reloadAccounts(launch: true)
    }

    /// Stops every loop and cancels in-flight cycles (a cancelled cycle writes nothing).
    public func stop() async {
        isStarted = false
        networkTask?.cancel()
        networkTask = nil
        holidayTask?.cancel()
        holidayTask = nil
        loadedHolidayCalendars = nil
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

    /// Reloads accounts, credentials and checkout mappings: new accounts start, removed ones stop; a changed
    /// credential, instance or scope set (or an expired credential) restarts the account with a fresh provider and
    /// an immediate cycle; other changes (watched repositories, refresh interval, label, namespaces) apply in place
    /// and keep the provider's caches. Call it after mappings change too (watched repositories default to them).
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
    /// The automatic-sync fields (manual pause, schedule, "sync anyway") take effect right away: paused accounts
    /// stop scheduling, resumed ones run the cycle that became due.
    public func setTrackingPreferences(_ preferences: TrackingPreferences) async {
        let before = environment.current.tracking
        environment.update { $0.tracking = preferences }
        if before.autoSyncSchedule != preferences.autoSyncSchedule || preferences.autoSyncSchedule.pauseOnHolidays {
            await updateHolidays()
        }
        if before.autoSyncPausedUntil != preferences.autoSyncPausedUntil
            || before.autoSyncSchedule != preferences.autoSyncSchedule
            || before.autoSyncScheduleOverrideUntil != preferences.autoSyncScheduleOverrideUntil {
            await rescheduleAll()
            environment.onChange(.syncStatus)
        }
    }

    /// Replaces the days off used by "Pause on holidays" (tests; the runtime's `HolidaySource` keeps them current).
    public func setHolidays(_ holidays: [String: String]) async {
        guard environment.current.holidays != holidays else { return }
        environment.update { $0.holidays = holidays }
        await rescheduleAll()
        environment.onChange(.syncStatus)
    }

    /// Calendar the schedule rules are evaluated in (tests pin a time zone).
    public func setCalendar(_ calendar: Calendar) async {
        environment.update { $0.calendar = calendar }
        await rescheduleAll()
    }

    /// The automatic-sync pause in effect now (nil = automatic sync runs).
    public func autoSyncPause() -> AutoSyncPause? {
        environment.autoSyncPause(now: environment.clock.now)
    }

    /// Loads the next 60 days off from the holiday source while "Pause on holidays" is on, and keeps them current
    /// (calendar changes, every 6 h, whenever the preferences are set again). Switched off: forgets them and stops
    /// watching.
    private func updateHolidays() async {
        let schedule = environment.current.tracking.autoSyncSchedule
        guard schedule.pauseOnHolidays else {
            holidayTask?.cancel()
            holidayTask = nil
            loadedHolidayCalendars = nil
            if !environment.current.holidays.isEmpty { environment.update { $0.holidays = [:] } }
            return
        }
        // Without a source (tests, demo) the days off come from `setHolidays`.
        guard let holidaySource else { return }
        // Always re-read (cheap, local): calendar access may have been granted since.
        await loadHolidays(from: holidaySource)
        guard loadedHolidayCalendars != schedule.holidayCalendarIDs || holidayTask == nil else { return }
        loadedHolidayCalendars = schedule.holidayCalendarIDs
        holidayTask?.cancel()
        let clock = environment.clock
        holidayTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in holidaySource.changes() {
                        if Task.isCancelled { return }
                        await self?.loadHolidays(from: holidaySource)
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        do { try await clock.sleep(for: 6 * 3_600) } catch { return }
                        await self?.loadHolidays(from: holidaySource)
                    }
                }
            }
        }
    }

    private func loadHolidays(from source: any HolidaySource) async {
        let settings = environment.current
        let ids = settings.tracking.autoSyncSchedule.holidayCalendarIDs
        let now = environment.clock.now
        let start = settings.calendar.startOfDay(for: now)
        let days = await source.daysOff(
            calendarIDs: ids, from: start, to: start.addingTimeInterval(60 * 86_400), calendar: settings.calendar
        )
        guard !Task.isCancelled, environment.current.tracking.autoSyncSchedule.pauseOnHolidays else { return }
        await setHolidays(days)
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

    /// Marks every change request hot until `until`: details refresh every cycle (never faster than the interval).
    public func setHot(until: Date?) async {
        environment.update { $0.hotUntil = until }
        await rescheduleAll()
    }

    /// Change requests with an active agent task refresh their details every cycle.
    public func setActiveChangeRequests(_ keys: Set<ChangeRequestKey>) async {
        let changed = environment.current.hotChangeRequests != keys
        environment.update { $0.hotChangeRequests = keys }
        if changed { await rescheduleAll() }
    }

    public func activeChangeRequests() -> Set<ChangeRequestKey> {
        environment.current.hotChangeRequests
    }

    /// The user came back (popover opened, main window became key): an account whose cycle is overdue (last one at
    /// least one interval ago) runs it now, retrying CRs that failed terminally a while ago. Never while automatic
    /// sync is paused.
    public func userDidReturn() async {
        await eventRefreshAll(retryTerminalFailures: true)
    }

    /// Call after the Mac wakes from sleep: accounts whose cycle is overdue run it now.
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

    /// Consumes connectivity updates (`true` = network reachable); every offline → online transition runs the
    /// overdue cycles. Replaces a previous observation.
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

    /// `launch`: the coordinator is starting (app launch); accounts then skip their first list while automatic sync
    /// is paused. Accounts added or reconnected later always list once.
    private func reloadAccounts(launch: Bool = false) async {
        let accounts: [Account]
        let mappings: [RepoMapping]
        do {
            accounts = try await database.accounts()
            mappings = try await database.mappings(repo: nil)
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
            let watched = WatchedRepositories.effective(
                for: account, mapped: mappings.filter { $0.repo.account == account.id }.map(\.repo)
            )
            var previousStatus: AccountSyncStatus?
            if let syncer = syncers[account.id] {
                let status = await syncer.status
                let current = await syncer.account
                // Same credential, instance and scopes: keep the syncer (provider caches, per-CR schedule) and
                // apply metadata changes (watched repositories, refresh interval, label, …) in place.
                let sameProvider = syncer.credential == credential && current.instance == account.instance
                    && current.grantedScopes == account.grantedScopes && status.state != .authExpired
                let currentWatched = await syncer.watched
                if sameProvider {
                    if current != account || currentWatched != watched {
                        await syncer.update(account: account, watched: watched)
                    }
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
                account: account, watched: watched, credential: credential, provider: provider, environment: environment,
                previousStatus: previousStatus
            )
            syncers[account.id] = syncer
            if isDisabled {
                await syncer.stop(state: .paused)
            } else if isStarted {
                let paused = environment.autoSyncPause(now: environment.clock.now) != nil
                await syncer.start(initialList: !(launch && paused))
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
