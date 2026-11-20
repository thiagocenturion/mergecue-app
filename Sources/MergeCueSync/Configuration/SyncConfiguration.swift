import Foundation
import MergeCueCore

/// Tunables of the sync service (DECISIONS D35, D36, and the owner's strict-interval rule):
/// **nothing is requested automatically more often than the account's refresh interval** (default 15 min). Every
/// automatic request happens in one list cycle per interval: the list, plus the change requests whose list version
/// changed or whose detail refresh is due (every cycle, or every second cycle once idle). Return/focus, wake and
/// network recovery only catch up on a cycle that is overdue. Failures retry at later cycles. Only Refresh and the
/// user's own actions request outside that rhythm.
public struct SyncConfiguration: Sendable, Hashable {
    // MARK: List cadence

    /// Interval between list polls of an account that never chose one (15 min). An account's
    /// `Account.refreshInterval` (Settings ▸ Accounts ▸ "Check for updates") replaces it for that account.
    public var listInterval: TimeInterval
    /// Return/focus only retries change requests that failed terminally (not found / forbidden) when the failure is
    /// at least this old (15 min), so reopening the popover repeatedly cannot hammer a dead PR.
    public var terminalRetryOnReturnAfter: TimeInterval

    // MARK: Detail tiers (per change request; never faster than the account's list interval)

    /// A CR that has not changed for this long is "idle" (1 h): its details refresh every
    /// `idleDetailCycles` list intervals instead of every one.
    public var idleAfter: TimeInterval
    /// List intervals between detail refreshes of an idle CR (2: 30 min at 15 min).
    public var idleDetailCycles: Int
    /// Checks reported as pending or running for longer than this (2 h) count as stuck: the CR is scheduled like
    /// any other instead of every cycle.
    public var stuckCheckAfter: TimeInterval

    // MARK: Per-CR error backoff

    /// List intervals before a change request whose hydration failed is retried, indexed by consecutive failures
    /// (the last value is the cap): 1 → 2 → 4 (15 → 30 → 60 min at 15 min).
    public var changeRequestBackoffCycles: [Int]

    // MARK: Account-level backoff

    /// First retry delay after an account-level failure (offline, server error); doubles per consecutive failure.
    /// Never shorter than the account's list interval.
    public var backoffBase: TimeInterval
    /// Upper bound of the account failure backoff (60 min; the list interval when that is longer).
    public var backoffCap: TimeInterval
    /// Waits when a provider rate-limits without sending a reset time, indexed by consecutive failures (the last
    /// value is the cap): 5 min → 15 min → 60 min. A reset sent by the provider is always honoured instead.
    public var rateLimitFallback: [TimeInterval]
    /// Relative jitter applied to list and backoff delays (0.1 = up to 10 % later; never earlier than the interval).
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
        terminalRetryOnReturnAfter: TimeInterval = 15 * 60,
        idleAfter: TimeInterval = 60 * 60,
        idleDetailCycles: Int = 2,
        stuckCheckAfter: TimeInterval = 2 * 60 * 60,
        changeRequestBackoffCycles: [Int] = [1, 2, 4],
        backoffBase: TimeInterval = 15 * 60,
        backoffCap: TimeInterval = 60 * 60,
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
        self.terminalRetryOnReturnAfter = terminalRetryOnReturnAfter
        self.idleAfter = idleAfter
        self.idleDetailCycles = idleDetailCycles
        self.stuckCheckAfter = stuckCheckAfter
        self.changeRequestBackoffCycles = changeRequestBackoffCycles
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
            listInterval: interval, idleDetailCycles: 1, backoffBase: interval, backoffCap: interval, jitterFraction: 0
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
    /// (default: `configuration.listInterval`). Never shorter than the list interval: details are refreshed inside
    /// list cycles only.
    /// - changed within `idleAfter` (1 h), an active agent task, or checks running for less than `stuckCheckAfter`
    ///   → every cycle (the list interval);
    /// - idle → every `idleDetailCycles` cycles (30 min at 15 min).
    /// Multiplied by `slowdown` (request budget, ≥ 1).
    /// An account checking "Manually only" has no automatic detail refreshes (see `ChangeRequestSchedule`).
    public static func detailInterval(
        sinceChange: TimeInterval,
        isHot: Bool,
        checksPending: Bool,
        slowdown: Double = 1,
        listInterval: TimeInterval? = nil,
        configuration: SyncConfiguration
    ) -> TimeInterval {
        let list = max(0, listInterval ?? configuration.listInterval)
        let cycles: Double
        if isHot || checksPending || sinceChange < configuration.idleAfter {
            cycles = 1
        } else {
            cycles = Double(max(1, configuration.idleDetailCycles))
        }
        return list * cycles * max(1, slowdown.isFinite ? slowdown : 1)
    }

    /// The list interval of `account`: its own refresh interval when chosen, else `configuration.listInterval`;
    /// nil when it checks "Manually only".
    public static func listInterval(for account: Account, configuration: SyncConfiguration) -> TimeInterval? {
        guard let chosen = account.refreshInterval else { return configuration.listInterval }
        return chosen.listInterval
    }

    /// Retry delay of a change request after `failures` consecutive non-terminal hydration failures: whole list
    /// intervals (default `configuration.listInterval`), so a retry never comes sooner than the next cycle.
    public static func changeRequestBackoff(
        failures: Int, listInterval: TimeInterval? = nil, configuration: SyncConfiguration
    ) -> TimeInterval {
        let list = max(0, listInterval ?? configuration.listInterval)
        let steps = configuration.changeRequestBackoffCycles.map { Double(max(1, $0)) }
        return list * ladder(steps, step: failures, fallback: 1)
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

    /// Exponential account failure backoff: `base * 2^(failures-1)`, capped, never shorter than `listInterval`.
    public static func backoff(
        consecutiveFailures: Int, listInterval: TimeInterval? = nil, configuration: SyncConfiguration
    ) -> TimeInterval {
        let failures = max(1, consecutiveFailures)
        let exponent = Double(min(failures - 1, 30))
        let list = max(0, listInterval ?? 0)
        let delay = min(max(configuration.backoffCap, list), max(0, configuration.backoffBase) * pow(2, exponent))
        return max(list, delay)
    }

    /// Delay before retrying an account that is in a failure `state`, or nil when it must not be polled again
    /// automatically (`authExpired`, `paused`, or an account that checks "Manually only": `listInterval` nil) or is
    /// not failing (`ok`, `idle`, `syncing`: the list schedule decides). Never shorter than `listInterval`.
    /// `jitterSample` is a value in `0..<1`; jitter only ever pushes later.
    public static func failureDelay(
        state: AccountSyncState,
        consecutiveFailures: Int,
        now: Date,
        listInterval: TimeInterval?,
        configuration: SyncConfiguration,
        jitterSample: Double = 0
    ) -> TimeInterval? {
        guard let listInterval else { return nil }
        let fraction = max(0, min(configuration.jitterFraction, 1))
        let later = 1 + fraction * min(max(jitterSample, 0), 1)
        let list = max(0, listInterval)
        switch state {
        case .authExpired, .paused, .ok, .idle, .syncing:
            return nil
        case .rateLimited(let until):
            guard let until else {
                return max(list, rateLimitFallback(consecutiveFailures: consecutiveFailures, configuration: configuration)) * later
            }
            // Never retry before the reset, nor sooner than the account's interval.
            return max(list, max(1, until.timeIntervalSince(now))) * later
        case .offline, .permissionDenied, .error:
            return backoff(consecutiveFailures: consecutiveFailures, listInterval: list, configuration: configuration) * later
        }
    }

    /// List interval (default: `configuration.listInterval`) plus up to `jitterFraction` later (never earlier).
    /// `jitterSample` is a value in `0..<1` (0 = no jitter).
    public static func listDelay(
        configuration: SyncConfiguration, listInterval: TimeInterval? = nil, jitterSample: Double = 0
    ) -> TimeInterval {
        let fraction = max(0, min(configuration.jitterFraction, 1))
        return (listInterval ?? configuration.listInterval) * (1 + fraction * min(max(jitterSample, 0), 1))
    }

    private static func ladder(_ steps: [TimeInterval], step: Int, fallback: TimeInterval) -> TimeInterval {
        guard !steps.isEmpty else { return fallback }
        return max(0, steps[min(max(1, step), steps.count) - 1])
    }
}
