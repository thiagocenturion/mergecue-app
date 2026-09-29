import Foundation
import MergeCueCore
import MergeCueStore

/// Independent polling loop of one account (DECISIONS D35):
/// - **lists** on start, every `listInterval` (15 min), on manual refresh and on debounced events (return/focus,
///   wake, network recovery);
/// - between lists, **detail** cycles hydrate the change requests whose progressive refresh is due
///   (`ChangeRequestSchedule`);
/// - account-level failures back off (exponential; rate limits wait for the provider's reset, else 5 → 15 → 60 min);
///   `authExpired` stops the loop until the coordinator replaces the syncer after `accountsDidChange()`.
/// Scheduling uses the injected `MCClock`, so tests drive it with `TestClock`.
actor AccountSyncer {
    /// What the next cycle does.
    struct Work: Sendable, Hashable {
        var mode: SyncCycle.Mode
        /// Retry every failed change request (manual refresh).
        var resetFailures = false
        /// Retry change requests that failed terminally at least `terminalRetryOnReturnAfter` ago (return/focus).
        var resetOldTerminalFailures = false

        static let list = Work(mode: .full)
        static let details = Work(mode: .details)

        func merged(with other: Work?) -> Work {
            guard let other else { return self }
            return Work(
                mode: mode == .full || other.mode == .full ? .full : .details,
                resetFailures: resetFailures || other.resetFailures,
                resetOldTerminalFailures: resetOldTerminalFailures || other.resetOldTerminalFailures
            )
        }
    }

    let account: Account
    let credential: Credential?
    private let provider: (any ReviewProvider)?
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
    /// End of the last successful list cycle (events within `eventRefreshDebounce` of it are skipped too).
    private var lastListedAt: Date?
    /// When a failing account retries (set once per failure, so re-evaluations never retry early).
    private var failureRetryAt: Date?

    init(
        account: Account,
        credential: Credential?,
        provider: (any ReviewProvider)?,
        environment: SyncEnvironment,
        previousStatus: AccountSyncStatus?
    ) {
        self.account = account
        self.credential = credential
        self.provider = provider
        self.environment = environment
        var status = AccountSyncStatus(account: account.id)
        status.lastSuccessAt = previousStatus?.lastSuccessAt
        status.lastAttemptAt = previousStatus?.lastAttemptAt
        self.status = status
    }

    // MARK: Lifecycle

    /// Starts polling immediately with a list cycle (no-op when already running). Without a credential the account
    /// is `authExpired`.
    func start() {
        guard !isRunning else { return }
        guard provider != nil else {
            setStatus { $0.state = .authExpired; $0.message = "No stored credential. Reconnect the account."; $0.nextRunAt = nil }
            return
        }
        isRunning = true
        stoppedState = nil
        nextListAt = nil
        startLoop(with: .list)
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
    /// returns when the cycle finished. Returns immediately when the account cannot sync now (stopped,
    /// `authExpired`, `paused`, or rate limited until a future reset).
    func refresh() async {
        await request(Work(mode: .full, resetFailures: true))
    }

    /// Event-triggered refresh (return/focus, wake, network recovery), skipped within `eventRefreshDebounce` of the
    /// previous event refresh or successful list.
    /// Returns whether a cycle ran.
    @discardableResult
    func eventRefresh(retryTerminalFailures: Bool) async -> Bool {
        guard isRunning, canRunNow else { return false }
        let now = environment.clock.now
        let debounce = environment.current.configuration.eventRefreshDebounce
        let recent = [lastEventRefreshAt, lastListedAt].compactMap { $0 }.max()
        if let recent, now.timeIntervalSince(recent) < debounce { return false }
        lastEventRefreshAt = now
        await request(Work(mode: .full, resetOldTerminalFailures: retryTerminalFailures))
        return true
    }

    /// Re-evaluates when the loop wakes (hot change requests or budget changed) without running a cycle now.
    func reschedule() {
        guard isRunning, !cycleInProgress, loopTask != nil, status.state == .ok else { return }
        startLoop(with: nil)
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

    /// The work that is due now, if any: a list when the account is failing (retry after backoff) or the list is
    /// due; otherwise a detail cycle when a change request is due.
    private func plannedWork() -> Work? {
        let now = environment.clock.now
        switch status.state {
        case .ok, .idle, .syncing:
            break
        case .authExpired, .paused:
            return nil
        case .rateLimited, .offline, .permissionDenied, .error:
            return (failureRetryAt ?? .distantPast) <= now ? .list : nil
        }
        if (nextListAt ?? .distantPast) <= now { return .list }
        let configuration = environment.current.configuration
        return schedule.dueKeys(hints: hints(now: now), configuration: configuration).isEmpty ? nil : .details
    }

    /// Delay until the next wake-up, or nil when the loop must stop (`authExpired`, `paused`).
    private func nextDelay() -> TimeInterval? {
        let now = environment.clock.now
        let configuration = environment.current.configuration
        switch status.state {
        case .authExpired, .paused:
            return nil
        case .ok, .idle, .syncing:
            var wake = nextListAt ?? now
            if let due = schedule.earliestDue(hints: hints(now: now), configuration: configuration), due < wake { wake = due }
            return max(configuration.minimumDelay, wake.timeIntervalSince(now))
        case .rateLimited, .offline, .permissionDenied, .error:
            let retryAt = failureRetryAt ?? now
            return max(configuration.minimumDelay, retryAt.timeIntervalSince(now))
        }
    }

    private func hints(now: Date) -> ScheduleHints {
        let settings = environment.current
        let used = environment.requestLedger.count(account.id, now: now)
        let budget = settings.configuration.requestBudget(for: account.kind)
        return ScheduleHints(
            now: now,
            hotKeys: settings.hotChangeRequests,
            allHot: settings.hotUntil.map { $0 > now } ?? false,
            slowdown: SyncSchedule.budgetSlowdown(used: used, budget: budget, configuration: settings.configuration)
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
        } else if work.resetOldTerminalFailures {
            schedule.resetFailures(now: startedAt, terminalOlderThan: configuration.terminalRetryOnReturnAfter)
        }
        setStatus { $0.state = .syncing; $0.lastAttemptAt = startedAt; $0.nextRunAt = nil }

        let cycle = SyncCycle(account: account, provider: provider, environment: environment)
        do {
            let outcome = try await cycle.run(mode: work.mode, schedule: schedule, hints: hints(now: startedAt))
            let finishedAt = environment.clock.now
            schedule = outcome.schedule
            if work.mode == .full {
                lastListedAt = finishedAt
                nextListAt = finishedAt.addingTimeInterval(
                    SyncSchedule.listDelay(configuration: configuration, jitterSample: environment.jitter())
                )
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
            } else {
                let wait = SyncSchedule.rateLimitFallback(consecutiveFailures: failures, configuration: configuration)
                state = .rateLimited(until: now.addingTimeInterval(wait))
                message = "\(provider) rate limit reached for @\(account.username) (no reset time sent). "
                    + "MergeCue backs off for \(Int((wait / 60).rounded())) min."
            }
        }
        failureRetryAt = SyncSchedule.failureDelay(
            state: state, consecutiveFailures: failures, now: now, configuration: configuration,
            jitterSample: environment.jitter()
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
        let errors = schedule.errors(configuration: configuration)
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
