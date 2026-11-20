import Foundation
import MergeCueCore

/// Tunables of the sync service. Defaults follow docs/ARCHITECTURE.md §7 and DECISIONS D35 (GitButler-style polling):
/// lists every 15 min + on return/focus/wake/network recovery; per change request, progressive detail refreshes
/// by time since the CR last changed; per-CR error backoff; account-level backoff honouring provider resets.
public struct SyncConfiguration: Sendable, Hashable {
    // MARK: List cadence

    /// Interval between list polls of an account that never chose one (15 min). An account's
    /// `Account.refreshInterval` (Settings ▸ Accounts ▸ "Check for updates") replaces it for that account.
    public var listInterval: TimeInterval
    /// Minimum time between an event-triggered refresh (return/focus, wake, network recovery) of one account and its
    /// previous event refresh or successful list (60 s). Manual refreshes are never debounced.
    public var eventRefreshDebounce: TimeInterval
    /// Return/focus only retries change requests that failed terminally (not found / forbidden) when the failure is
    /// at least this old (15 min), so reopening the popover repeatedly cannot hammer a dead PR.
    public var terminalRetryOnReturnAfter: TimeInterval

    // MARK: Detail tiers (per change request, by time since it last changed; DECISIONS D35, D36)

    /// Detail refresh interval of a CR with an active agent task or pending checks (30 s). Never used for an
    /// account whose refresh interval is "Manually only".
    public var fastDetailInterval: TimeInterval
    /// A CR that changed less than this long ago is "recent" (10 min).
    public var fastDetailWindow: TimeInterval
    /// Interval of a recent CR, scaled by the account's list interval ÷ `listInterval` (5 min at 15 min).
    public var mediumDetailInterval: TimeInterval
    /// A CR that changed less than this long ago (and is not recent) is "quiet"; older ones are "idle" (1 h).
    public var mediumDetailWindow: TimeInterval
    /// Interval of an idle CR, scaled like `mediumDetailInterval` (30 min at 15 min). Quiet and idle CRs are never
    /// refreshed faster than the account's list interval.
    public var slowDetailInterval: TimeInterval

    // MARK: Per-CR error backoff

    /// Retry delays of a change request whose hydration failed with a non-terminal error, indexed by consecutive
    /// failures (the last value is the cap): 30 s → 5 min → 30 min.
    public var changeRequestBackoff: [TimeInterval]

    // MARK: Account-level backoff

    /// First retry delay after an account-level failure (offline, server error); doubles per consecutive failure.
    public var backoffBase: TimeInterval
    /// Upper bound of the account failure backoff (15 min).
    public var backoffCap: TimeInterval
    /// Waits when a provider rate-limits without sending a reset time, indexed by consecutive failures (the last
    /// value is the cap): 5 min → 15 min → 60 min. A reset sent by the provider is always honoured instead.
    public var rateLimitFallback: [TimeInterval]
    /// Relative jitter applied to list and backoff delays (0.1 = ±10 %; rate-limit waits only get positive jitter).
    public var jitterFraction: Double

    // MARK: Request budget

    /// Soft hourly request budget per provider (GitHub 1500, GitLab 1000, Bitbucket 500). An account at or above
    /// `budgetWarningFraction` of it refreshes details `budgetWarningSlowdown`× slower; at or above the budget
    /// `budgetSlowdown`× slower.
    public var requestBudgets: [ProviderKind: Int]
    public var budgetWarningFraction: Double
    public var budgetWarningSlowdown: Double
    public var budgetSlowdown: Double

    // MARK: Other

    /// Maximum concurrent `hydrate` calls per account (3; each adapter also caps its own concurrent requests).
    public var hydrateConcurrency: Int
    /// Floor of every sleep of an account loop (guards against tight loops).
    public var minimumDelay: TimeInterval
    /// Notifications are suppressed inside this window (events, attention and rules still run).
    public var quietHours: QuietHours?
    /// Accounts that are not synced at all (state `paused`).
    public var disabledAccounts: Set<AccountKey>
    /// Event types that produce a notification on the user's own change requests without an attention item.
    public var informationalNotificationTypes: Set<ChangeEventType>
    /// The involved listing (`ChangeRequestScope.involved`, CRs of others the user reviewed or commented on) only
    /// asks for CRs updated within this window (30 days); nil = no involved listing at all.
    public var involvedWindow: TimeInterval?

    public init(
        listInterval: TimeInterval = 15 * 60,
        eventRefreshDebounce: TimeInterval = 60,
        terminalRetryOnReturnAfter: TimeInterval = 15 * 60,
        fastDetailInterval: TimeInterval = 30,
        fastDetailWindow: TimeInterval = 10 * 60,
        mediumDetailInterval: TimeInterval = 5 * 60,
        mediumDetailWindow: TimeInterval = 60 * 60,
        slowDetailInterval: TimeInterval = 30 * 60,
        changeRequestBackoff: [TimeInterval] = [30, 5 * 60, 30 * 60],
        backoffBase: TimeInterval = 30,
        backoffCap: TimeInterval = 900,
        rateLimitFallback: [TimeInterval] = [5 * 60, 15 * 60, 60 * 60],
        jitterFraction: Double = 0.1,
        requestBudgets: [ProviderKind: Int] = SyncConfiguration.defaultRequestBudgets,
        budgetWarningFraction: Double = 0.75,
        budgetWarningSlowdown: Double = 2,
        budgetSlowdown: Double = 4,
        hydrateConcurrency: Int = 3,
        minimumDelay: TimeInterval = 1,
        quietHours: QuietHours? = nil,
        disabledAccounts: Set<AccountKey> = [],
        informationalNotificationTypes: Set<ChangeEventType> = [.approval],
        involvedWindow: TimeInterval? = 30 * 86_400
    ) {
        self.listInterval = listInterval
        self.eventRefreshDebounce = eventRefreshDebounce
        self.terminalRetryOnReturnAfter = terminalRetryOnReturnAfter
        self.fastDetailInterval = fastDetailInterval
        self.fastDetailWindow = fastDetailWindow
        self.mediumDetailInterval = mediumDetailInterval
        self.mediumDetailWindow = mediumDetailWindow
        self.slowDetailInterval = slowDetailInterval
        self.changeRequestBackoff = changeRequestBackoff
        self.backoffBase = backoffBase
        self.backoffCap = backoffCap
        self.rateLimitFallback = rateLimitFallback
        self.jitterFraction = jitterFraction
        self.requestBudgets = requestBudgets
        self.budgetWarningFraction = budgetWarningFraction
        self.budgetWarningSlowdown = budgetWarningSlowdown
        self.budgetSlowdown = budgetSlowdown
        self.hydrateConcurrency = hydrateConcurrency
        self.minimumDelay = minimumDelay
        self.quietHours = quietHours
        self.disabledAccounts = disabledAccounts
        self.informationalNotificationTypes = informationalNotificationTypes
        self.involvedWindow = involvedWindow
    }

    /// GitHub 1500/h (of 5000), GitLab 1000/h, Bitbucket Cloud 500/h (of 1000).
    public static let defaultRequestBudgets: [ProviderKind: Int] = [.github: 1_500, .gitlab: 1_000, .bitbucketCloud: 500]

    public static let `default` = SyncConfiguration()

    /// Deterministic settings for tests and demo mode: no jitter.
    public static var deterministic: SyncConfiguration {
        SyncConfiguration(jitterFraction: 0)
    }

    /// Every list and detail refresh at one fixed `interval` (profiling / demo host).
    public static func fixedInterval(_ interval: TimeInterval) -> SyncConfiguration {
        SyncConfiguration(
            listInterval: interval, eventRefreshDebounce: 0, fastDetailInterval: interval, mediumDetailInterval: interval,
            slowDetailInterval: interval, jitterFraction: 0
        )
    }

    /// The soft hourly budget of `kind` (nil = unlimited).
    public func requestBudget(for kind: ProviderKind) -> Int? {
        requestBudgets[kind].flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Pure scheduling arithmetic (unit tested; the syncer only adds the random jitter sample).
public enum SyncSchedule {
    /// Detail refresh interval of one change request of an account polling its lists every `listInterval`
    /// (default: `configuration.listInterval`; DECISIONS D36):
    /// - hot (active agent task / `setHot`) or pending checks → `fastDetailInterval` (30 s);
    /// - recent (changed less than `fastDetailWindow` ago) → `mediumDetailInterval` × scale (5 min at 15 min);
    /// - quiet (less than `mediumDetailWindow`) → the list interval;
    /// - idle → `slowDetailInterval` × scale (30 min at 15 min), never less than the list interval.
    /// `scale` = `listInterval ÷ configuration.listInterval`. Multiplied by `slowdown` (request budget, ≥ 1).
    /// An account checking "Manually only" has no automatic detail refreshes (see `ChangeRequestSchedule`).
    public static func detailInterval(
        sinceChange: TimeInterval,
        isHot: Bool,
        checksPending: Bool,
        slowdown: Double = 1,
        listInterval: TimeInterval? = nil,
        configuration: SyncConfiguration
    ) -> TimeInterval {
        let reference = max(1, configuration.listInterval)
        let list = max(0, listInterval ?? configuration.listInterval)
        let scale = list / reference
        let fast = max(0, configuration.fastDetailInterval)
        let base: TimeInterval
        if isHot || checksPending {
            base = fast
        } else if sinceChange < configuration.fastDetailWindow {
            base = max(fast, configuration.mediumDetailInterval * scale)
        } else if sinceChange < configuration.mediumDetailWindow {
            base = max(fast, list, configuration.mediumDetailInterval * scale)
        } else {
            base = max(fast, list, configuration.slowDetailInterval * scale)
        }
        return max(0, base) * max(1, slowdown.isFinite ? slowdown : 1)
    }

    /// The list interval of `account`: its own refresh interval when chosen, else `configuration.listInterval`;
    /// nil when it checks "Manually only".
    public static func listInterval(for account: Account, configuration: SyncConfiguration) -> TimeInterval? {
        guard let chosen = account.refreshInterval else { return configuration.listInterval }
        return chosen.listInterval
    }

    /// Retry delay of a change request after `failures` consecutive non-terminal hydration failures.
    public static func changeRequestBackoff(failures: Int, configuration: SyncConfiguration) -> TimeInterval {
        ladder(configuration.changeRequestBackoff, step: failures, fallback: configuration.backoffCap)
    }

    /// Wait after a rate limit without a provider reset time (`consecutiveFailures` ≥ 1).
    public static func rateLimitFallback(consecutiveFailures: Int, configuration: SyncConfiguration) -> TimeInterval {
        ladder(configuration.rateLimitFallback, step: consecutiveFailures, fallback: 3_600)
    }

    /// Detail slowdown factor for an account that sent `used` requests in the last hour against `budget`.
    public static func budgetSlowdown(used: Int, budget: Int?, configuration: SyncConfiguration) -> Double {
        guard let budget, budget > 0 else { return 1 }
        if used >= budget { return max(1, configuration.budgetSlowdown) }
        if Double(used) >= Double(budget) * configuration.budgetWarningFraction { return max(1, configuration.budgetWarningSlowdown) }
        return 1
    }

    /// Exponential account failure backoff: `base * 2^(failures-1)`, capped.
    public static func backoff(consecutiveFailures: Int, configuration: SyncConfiguration) -> TimeInterval {
        let failures = max(1, consecutiveFailures)
        let exponent = Double(min(failures - 1, 30))
        return min(configuration.backoffCap, max(0, configuration.backoffBase) * pow(2, exponent))
    }

    /// Delay before retrying an account that is in a failure `state`, or nil when it must not be polled again
    /// automatically (`authExpired`, `paused`) or is not failing (`ok`, `idle`, `syncing`: the list/detail
    /// schedule decides). `jitterSample` is a value in `0..<1` (0.5 = no jitter).
    public static func failureDelay(
        state: AccountSyncState,
        consecutiveFailures: Int,
        now: Date,
        configuration: SyncConfiguration,
        jitterSample: Double = 0.5
    ) -> TimeInterval? {
        let fraction = max(0, min(configuration.jitterFraction, 1))
        let sample = min(max(jitterSample, 0), 1)
        let symmetric = 1 + fraction * (2 * sample - 1)
        switch state {
        case .authExpired, .paused, .ok, .idle, .syncing:
            return nil
        case .rateLimited(let until):
            guard let until else {
                return rateLimitFallback(consecutiveFailures: consecutiveFailures, configuration: configuration) * (1 + fraction * sample)
            }
            let wait = max(1, until.timeIntervalSince(now))
            // Never retry before the reset: jitter only pushes later.
            return wait * (1 + fraction * sample)
        case .offline, .permissionDenied, .error:
            return backoff(consecutiveFailures: consecutiveFailures, configuration: configuration) * symmetric
        }
    }

    /// List interval (default: `configuration.listInterval`) with symmetric jitter.
    public static func listDelay(
        configuration: SyncConfiguration, listInterval: TimeInterval? = nil, jitterSample: Double = 0.5
    ) -> TimeInterval {
        let fraction = max(0, min(configuration.jitterFraction, 1))
        return (listInterval ?? configuration.listInterval) * (1 + fraction * (2 * min(max(jitterSample, 0), 1) - 1))
    }

    private static func ladder(_ steps: [TimeInterval], step: Int, fallback: TimeInterval) -> TimeInterval {
        guard !steps.isEmpty else { return fallback }
        return max(0, steps[min(max(1, step), steps.count) - 1])
    }
}
