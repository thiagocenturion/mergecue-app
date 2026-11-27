import Foundation
import MergeCueCore
import MergeCueStore

/// Independent polling loop of one account (DECISIONS D35, D36 and the strict-interval rule):
/// - one automatic **cycle** per list interval (the account's `refreshInterval`, default 15 min): the list plus the
///   change requests that changed or are due (`ChangeRequestSchedule`). Nothing is requested between cycles;
///   return/focus, wake and network recovery only run a cycle that is overdue. "Manually only" accounts sync at
///   launch and on Refresh only;
/// - while automatic sync is paused (menu bar pause or a schedule rule, `AutoSyncPause`) nothing runs on its own;
///   the loop wakes when the pause ends. Refresh still works;
/// - account-level failures back off (exponential, never sooner than the list interval; rate limits wait for the
///   provider's reset, else 5 → 15 → 60 min); `authExpired` stops the loop until the coordinator replaces the
///   syncer after `accountsDidChange()`.
/// Scheduling uses the injected `MCClock`, so tests drive it with `TestClock`.
actor AccountSyncer {
    /// What the next cycle does.
    struct Work: Sendable, Hashable {
        var mode: SyncCycle.Mode
        /// Retry every failed change request (manual refresh).
        var resetFailures = false
        /// Retry change requests that failed terminally at least `terminalRetryOnReturnAfter` ago (return/focus).
        var resetOldTerminalFailures = false
        /// A manual refresh: also hydrates CRs whose state the listing cannot show (pending checks, active task).
        var isManual = false

        static let list = Work(mode: .full)

        func merged(with other: Work?) -> Work {
            guard let other else { return self }
            return Work(
                mode: mode == .full || other.mode == .full ? .full : .details,
                resetFailures: resetFailures || other.resetFailures,
                resetOldTerminalFailures: resetOldTerminalFailures || other.resetOldTerminalFailures,
                isManual: isManual || other.isManual
            )
        }
    }

    /// The account (metadata changes such as watched repositories or the refresh interval are applied in place
    /// with `update(account:watched:)`, keeping the provider and its identity caches).
    private(set) var account: Account
    /// Effective watched repositories (`WatchedRepositories.effective`; empty = all).
    private(set) var watched: [RepoKey]
    let credential: Credential?
    /// Long-lived for the syncer's lifetime: its caches (`/user`, workspaces, ETags) survive across cycles.
    let provider: (any ReviewProvider)?
    private let environment: SyncEnvironment
    private(set) var status: AccountSyncStatus
    private var loopTask: Task<Void, Never>?
    private var isRunning = false
    private var cycleInProgress = false
    /// Work requested while a cycle was running; runs right after it.
    private var pendingWork: Work?
    /// Callers of `refresh()` waiting for the next cycle to finish.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// State shown after `stop(state:)`; an in-flight cycle finishing late must not overwrite it.
    private var stoppedState: AccountSyncState?
    private var schedule = ChangeRequestSchedule()
    /// Next list poll (nil = as soon as possible).
    private var nextListAt: Date?
    private var lastEventRefreshAt: Date?
    /// End of the last successful list cycle.
    private var lastListedAt: Date?
    /// When a failing account retries (set once per failure, so re-evaluations never retry early).
    private var failureRetryAt: Date?
    /// The user came back while no cycle was overdue: the next scheduled cycle retries change requests that failed
    /// terminally a while ago (no extra request now).
    private var retryOldTerminalFailuresNextCycle = false

    init(
        account: Account,
        watched: [RepoKey] = [],
        credential: Credential?,
        provider: (any ReviewProvider)?,
        environment: SyncEnvironment,
        previousStatus: AccountSyncStatus?
    ) {
        self.account = account
        self.watched = watched
        self.credential = credential
        self.provider = provider
        self.environment = environment
        var status = AccountSyncStatus(account: account.id)
        status.lastSuccessAt = previousStatus?.lastSuccessAt
        status.lastAttemptAt = previousStatus?.lastAttemptAt
        self.status = status
    }

    // MARK: Lifecycle

    /// Starts polling (no-op when already running), with a list cycle right away unless `initialList` is false
    /// (launch while automatic sync is paused: the first cycle runs when the pause ends). Without a credential the
    /// account is `authExpired`.
    func start(initialList: Bool = true) {
        guard !isRunning else { return }
        guard provider != nil else {
            setStatus { $0.state = .authExpired; $0.message = "No stored credential. Reconnect the account."; $0.nextRunAt = nil }
            return
        }
        isRunning = true
        stoppedState = nil
        nextListAt = nil
        startLoop(with: initialList ? .list : nil)
    }

    /// Stops polling and cancels an in-flight cycle (nothing is written for a cancelled cycle).
    /// `state` replaces the displayed state (e.g. `.paused` when the account is disabled).
    func stop(state: AccountSyncState? = nil) {
        isRunning = false
        pendingWork = nil
        stoppedState = state
        loopTask?.cancel()
        loopTask = nil
        if let state {
            setStatus { $0.state = state; $0.nextRunAt = nil }
        } else if status.nextRunAt != nil {
            setStatus { $0.nextRunAt = nil }
        }
        resumeWaiters()
    }

    /// Manual refresh: lists now (or right after the cycle in flight), retries every failed change request and
    /// returns when the cycle finished. Only change requests whose list version changed, that are due, failed, or
    /// whose state the listing cannot show (pending checks, active task) are hydrated. Returns immediately when the
    /// account cannot sync now (stopped, `authExpired`, `paused`, or rate limited until a future reset).
    func refresh() async {
        await request(Work(mode: .full, resetFailures: true, isManual: true))
    }

    /// Applies account metadata changes in place (same credential and instance): the provider, its caches and the
    /// per-CR schedule are kept. A changed listing scope (watched repositories, namespaces) lists right away; a
    /// changed refresh interval only moves the next list.
    func update(account newAccount: Account, watched newWatched: [RepoKey]) {
        let scopeChanged = newWatched != watched || newAccount.selectedNamespaces != account.selectedNamespaces
        let intervalChanged = newAccount.refreshInterval != account.refreshInterval
        account = newAccount
        watched = newWatched
        guard isRunning else { return }
        if scopeChanged {
            if cycleInProgress {
                pendingWork = Work.list.merged(with: pendingWork)
            } else if canRunNow {
                startLoop(with: .list)
            }
        } else if intervalChanged {
            if let listInterval, let lastListedAt {
                nextListAt = lastListedAt.addingTimeInterval(listInterval)
            }
            if !cycleInProgress, loopTask != nil { startLoop(with: nil) }
        }
    }

    /// The account's list interval; nil = "Manually only".
    private var listInterval: TimeInterval? {
        SyncSchedule.listInterval(for: account, configuration: environment.current.configuration)
    }

    /// Event-triggered refresh (return/focus, wake, network recovery): runs only when the account's last cycle (or
    /// event refresh) is at least one list interval old, i.e. the scheduled cycle is overdue (after sleep or while
    /// the timer was held up). Never while automatic sync is paused or for "Manually only" accounts.
    /// Returns whether a cycle ran.
    @discardableResult
    func eventRefresh(retryTerminalFailures: Bool) async -> Bool {
        guard isRunning, canRunNow, let listInterval else { return false }
        let now = environment.clock.now
        guard environment.autoSyncPause(now: now) == nil else { return false }
        if retryTerminalFailures { retryOldTerminalFailuresNextCycle = true }
        guard !cycleInProgress else { return false }
        let recent = [lastEventRefreshAt, lastListedAt, status.lastAttemptAt].compactMap { $0 }.max()
        if let recent, now.timeIntervalSince(recent) < listInterval { return false }
        if let retry = failureRetryAt, retry > now { return false }
        lastEventRefreshAt = now
        await request(Work(mode: .full, resetOldTerminalFailures: retryTerminalFailures))
        return true
    }

    /// Re-evaluates when the loop wakes (hot change requests, budget, automatic-sync pause or schedule changed)
    /// without running a cycle now; a cycle that became due (pause lifted) runs right away.
    func reschedule() {
        guard isRunning, !cycleInProgress, loopTask != nil else { return }
        switch status.state {
        case .authExpired, .paused: return
        default: startLoop(with: nil)
        }
    }

    private func request(_ work: Work) async {
        guard isRunning, canRunNow else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
            if cycleInProgress {
                pendingWork = work.merged(with: pendingWork)
            } else {
                startLoop(with: work)
            }
        }
    }

    private var canRunNow: Bool {
        switch status.state {
        case .authExpired, .paused:
            return false
        case .rateLimited(let until):
            return (until ?? .distantPast) <= environment.clock.now
        case .idle, .syncing, .ok, .offline, .permissionDenied, .error:
            return true
        }
    }

    // MARK: Loop

    private func startLoop(with work: Work?) {
        loopTask?.cancel()
        loopTask = Task { await self.runLoop(first: work) }
    }

    private func runLoop(first: Work?) async {
        var work = first
        while !Task.isCancelled, isRunning {
            if let current = work ?? plannedWork() {
                await runCycle(current)
                guard !Task.isCancelled, isRunning else { return }
                if let pending = pendingWork {
                    pendingWork = nil
                    work = pending
                    continue
                }
            }
            work = nil
            guard let delay = nextDelay() else {
                setStatus { $0.nextRunAt = nil }
                return
            }
            let now = environment.clock.now
            setStatus { $0.nextRunAt = now.addingTimeInterval(delay) }
            do {
                try await environment.clock.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    /// The work that is due now, if any: nothing while automatic sync is paused; a list when the account is failing
    /// (retry after backoff) or the list interval elapsed. Details are only refreshed inside list cycles.
    private func plannedWork() -> Work? {
        let now = environment.clock.now
        guard environment.autoSyncPause(now: now) == nil else { return nil }
        switch status.state {
        case .ok, .idle, .syncing:
            guard listInterval != nil else { return nil }
            return (nextListAt ?? .distantPast) <= now ? .list : nil
        case .authExpired, .paused:
            return nil
        case .rateLimited, .offline, .permissionDenied, .error:
            guard let failureRetryAt else { return nil }
            return failureRetryAt <= now ? .list : nil
        }
    }

    /// Delay until the next wake-up, or nil when the loop must stop (`authExpired`, `paused`, "Manually only", or
    /// paused until the user resumes). While automatic sync is paused the loop wakes when the pause may end.
    private func nextDelay() -> TimeInterval? {
        let now = environment.clock.now
        let configuration = environment.current.configuration
        let pause = environment.autoSyncPause(now: now)
        if status.autoSyncPause != pause { setStatus { $0.autoSyncPause = pause } }
        let wake: Date?
        switch status.state {
        case .authExpired, .paused:
            return nil
        case .ok, .idle, .syncing:
            wake = listInterval == nil ? nil : (nextListAt ?? now)
        case .rateLimited, .offline, .permissionDenied, .error:
            wake = failureRetryAt
        }
        guard var wake else { return nil }
        if pause != nil {
            // Wake when the pause may change (schedule boundary, end of a timed pause); never while it lasts.
            guard let change = environment.nextAutoSyncChange(now: now) else { return nil }
            wake = max(wake, change)
        }
        return max(configuration.minimumDelay, wake.timeIntervalSince(now))
    }

    private func hints(now: Date, manual: Bool = false) -> ScheduleHints {
        let settings = environment.current
        let used = environment.requestLedger.count(account.id, now: now)
        let budget = settings.configuration.requestBudget(for: account.kind)
        return ScheduleHints(
            now: now,
            hotKeys: settings.hotChangeRequests,
            allHot: settings.hotUntil.map { $0 > now } ?? false,
            slowdown: max(
                SyncSchedule.budgetSlowdown(used: used, budget: budget, configuration: settings.configuration),
                // The provider itself said fewer than 20 % of requests are left (Bitbucket `X-RateLimit-NearLimit`).
                environment.requestLedger.isNearLimit(account.id, now: now) ? max(1, settings.configuration.budgetSlowdown) : 1
            ),
            listInterval: SyncSchedule.listInterval(for: account, configuration: settings.configuration),
            isManualRefresh: manual
        )
    }

    private func runCycle(_ work: Work) async {
        guard let provider else { return }
        cycleInProgress = true
        let finishing = waiters
        waiters = []
        let stateBefore = status.state
        let startedAt = environment.clock.now
        let configuration = environment.current.configuration
        if work.resetFailures {
            schedule.resetFailures(now: startedAt)
        } else if work.resetOldTerminalFailures || retryOldTerminalFailuresNextCycle {
            schedule.resetFailures(now: startedAt, terminalOlderThan: configuration.terminalRetryOnReturnAfter)
        }
        retryOldTerminalFailuresNextCycle = false
        setStatus { $0.state = .syncing; $0.lastAttemptAt = startedAt; $0.nextRunAt = nil }

        let cycle = SyncCycle(account: account, watched: watched, provider: provider, environment: environment)
        do {
            let outcome = try await cycle.run(mode: work.mode, schedule: schedule, hints: hints(now: startedAt, manual: work.isManual))
            let finishedAt = environment.clock.now
            schedule = outcome.schedule
            if work.mode == .full {
                lastListedAt = finishedAt
                nextListAt = listInterval.map {
                    finishedAt.addingTimeInterval(
                        SyncSchedule.listDelay(configuration: configuration, listInterval: $0, jitterSample: environment.jitter())
                    )
                }
            }
            failureRetryAt = nil
            let finalState = isRunning ? .ok : (stoppedState ?? .ok)
            setStatus {
                $0.state = finalState
                $0.lastSuccessAt = finishedAt
                $0.consecutiveFailures = 0
                $0.message = nil
            }
        } catch {
            if let providerError = ProviderError.classify(error), !Task.isCancelled {
                recordFailure(providerError)
            } else if status.state == .syncing {
                // Cancelled: not a failure, no backoff.
                let restored = stoppedState ?? stateBefore
                setStatus { $0.state = restored }
            }
        }
        publishDetails()
        cycleInProgress = false
        finishing.forEach { $0.resume() }
    }

    private func recordFailure(_ providerError: ProviderError) {
        let now = environment.clock.now
        let failures = status.consecutiveFailures + 1
        let configuration = environment.current.configuration
        var state = AccountSyncState(providerError: providerError, now: now)
        var message = providerError.errorDescription
        if case .rateLimited(let until) = state {
            let provider = account.kind.displayName
            if let until, until > now {
                message = "\(provider) rate limit reached for @\(account.username). MergeCue waits for the reset time \(provider) sent."
                // A reset sooner than the account's interval still waits one interval (shown time = retry time).
                if let listInterval, until.timeIntervalSince(now) < listInterval {
                    state = .rateLimited(until: now.addingTimeInterval(listInterval))
                }
            } else {
                // No reset time (Bitbucket sends none for its rolling hour): wait until this account's own requests
                // of the last hour are well under its soft budget, at least the fallback's first step.
                // Never sooner than the account's own interval (shown time = actual retry time).
                var wait = max(
                    listInterval ?? 0,
                    SyncSchedule.rateLimitFallback(consecutiveFailures: failures, configuration: configuration)
                )
                if let budget = configuration.requestBudget(for: account.kind) {
                    let calm = environment.requestLedger.date(account.id, whenCountBelow: budget / 2, now: now)
                    let first = SyncSchedule.rateLimitFallback(consecutiveFailures: 1, configuration: configuration)
                    if calm.timeIntervalSince(now) > first { wait = calm.timeIntervalSince(now) }
                }
                state = .rateLimited(until: now.addingTimeInterval(wait))
                message = "\(provider) rate limit reached for @\(account.username) (no reset time sent). "
                    + "MergeCue backs off for \(Int((wait / 60).rounded())) min."
            }
        }
        failureRetryAt = SyncSchedule.failureDelay(
            state: state, consecutiveFailures: failures, now: now, listInterval: listInterval,
            configuration: configuration, jitterSample: environment.jitter()
        ).map { now.addingTimeInterval($0) }
        setStatus {
            $0.state = state
            $0.consecutiveFailures = failures
            $0.message = message
        }
        MCLog.sync.notice("Sync of \(account.id.kind.rawValue) account failed: \(providerError.code)")
    }

    /// Per-CR errors and request accounting shown in the status.
    private func publishDetails() {
        let now = environment.clock.now
        let configuration = environment.current.configuration
        let errors = schedule.errors(listInterval: listInterval, configuration: configuration)
        let used = environment.requestLedger.count(account.id, now: now)
        let budget = configuration.requestBudget(for: account.kind)
        setStatus {
            $0.changeRequestErrors = errors
            $0.requestsLastHour = used
            $0.requestBudget = budget
        }
    }

    /// Current status with a fresh request count.
    func currentStatus() -> AccountSyncStatus {
        var current = status
        current.requestsLastHour = environment.requestLedger.count(account.id, now: environment.clock.now)
        current.requestBudget = environment.current.configuration.requestBudget(for: account.kind)
        current.autoSyncPause = environment.autoSyncPause(now: environment.clock.now)
        return current
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    private func setStatus(_ change: (inout AccountSyncStatus) -> Void) {
        let before = status
        change(&status)
        if status != before { environment.onChange(.syncStatus) }
    }
}
