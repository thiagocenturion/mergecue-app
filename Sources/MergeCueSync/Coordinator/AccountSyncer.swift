import Foundation
import MergeCueCore
import MergeCueStore

/// Independent polling loop of one account: immediate first run, adaptive interval, backoff with jitter,
/// rate-limit resets honoured, stops on `authExpired` (until the coordinator replaces it after
/// `accountsDidChange()`). Scheduling uses the injected `MCClock`, so tests drive it with `TestClock`.
actor AccountSyncer {
    let account: Account
    let credential: Credential?
    private let provider: (any ReviewProvider)?
    private let environment: SyncEnvironment
    private(set) var status: AccountSyncStatus
    private var loopTask: Task<Void, Never>?
    private var isRunning = false
    private var cycleInProgress = false
    private var refreshPending = false
    /// Callers of `refresh()` waiting for the next cycle to finish.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastActivityAt: Date?
    /// State shown after `stop(state:)`; an in-flight cycle finishing late must not overwrite it.
    private var stoppedState: AccountSyncState?

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

    /// Starts polling immediately (no-op when already running). Without a credential the account is `authExpired`.
    func start() {
        guard !isRunning else { return }
        guard provider != nil else {
            setStatus { $0.state = .authExpired; $0.message = "No stored credential. Reconnect the account."; $0.nextRunAt = nil }
            return
        }
        isRunning = true
        stoppedState = nil
        startLoop()
    }

    /// Stops polling and cancels an in-flight cycle (nothing is written for a cancelled cycle).
    /// `state` replaces the displayed state (e.g. `.paused` when the account is disabled).
    func stop(state: AccountSyncState? = nil) {
        isRunning = false
        refreshPending = false
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

    /// Runs a cycle now (or right after the one in flight) and returns when it finished. Returns immediately when
    /// the account cannot sync now (stopped, `authExpired`, `paused`, or rate limited until a future reset).
    func refresh() async {
        guard isRunning, canRunNow else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
            if cycleInProgress {
                refreshPending = true
            } else {
                startLoop()
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

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { await self.runLoop() }
    }

    private func runLoop() async {
        while !Task.isCancelled, isRunning {
            await runCycle()
            guard !Task.isCancelled, isRunning else { return }
            if refreshPending {
                refreshPending = false
                continue
            }
            let now = environment.clock.now
            let settings = environment.current
            let isHot = (settings.hotUntil.map { $0 > now } ?? false)
                || (lastActivityAt.map { now.timeIntervalSince($0) < settings.configuration.hotWindow } ?? false)
            guard let delay = SyncSchedule.nextDelay(
                state: status.state,
                consecutiveFailures: status.consecutiveFailures,
                now: now,
                isHot: isHot,
                configuration: settings.configuration,
                jitterSample: environment.jitter()
            ) else {
                setStatus { $0.nextRunAt = nil }
                return
            }
            setStatus { $0.nextRunAt = now.addingTimeInterval(delay) }
            do {
                try await environment.clock.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func runCycle() async {
        guard let provider else { return }
        cycleInProgress = true
        let finishing = waiters
        waiters = []
        let stateBefore = status.state
        let startedAt = environment.clock.now
        setStatus { $0.state = .syncing; $0.lastAttemptAt = startedAt; $0.nextRunAt = nil }

        let cycle = SyncCycle(account: account, provider: provider, environment: environment)
        do {
            let outcome = try await cycle.run()
            let finishedAt = environment.clock.now
            if outcome.hadAttentionActivity { lastActivityAt = finishedAt }
            let finalState = isRunning ? .ok : (stoppedState ?? .ok)
            setStatus {
                $0.state = finalState
                $0.lastSuccessAt = finishedAt
                $0.consecutiveFailures = 0
                $0.message = nil
            }
        } catch {
            if let providerError = ProviderError.classify(error), !Task.isCancelled {
                let now = environment.clock.now
                setStatus {
                    $0.state = AccountSyncState(providerError: providerError, now: now)
                    $0.consecutiveFailures += 1
                    $0.message = providerError.errorDescription
                }
                MCLog.sync.notice("Sync of \(account.id.kind.rawValue) account failed: \(providerError.code)")
            } else if status.state == .syncing {
                // Cancelled: not a failure, no backoff.
                let restored = stoppedState ?? stateBefore
                setStatus { $0.state = restored }
            }
        }
        cycleInProgress = false
        finishing.forEach { $0.resume() }
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
