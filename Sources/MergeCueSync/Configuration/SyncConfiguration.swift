import Foundation
import MergeCueCore

/// Tunables of the sync service. Defaults follow docs/ARCHITECTURE.md §7.
public struct SyncConfiguration: Sendable, Hashable {
    /// Normal polling interval (90 s).
    public var defaultInterval: TimeInterval
    /// Interval while something is hot: `SyncCoordinator.setHot(until:)` or recent attention activity (45 s).
    public var hotInterval: TimeInterval
    /// Interval inside `idleHours` when nothing is hot (5 min).
    public var idleInterval: TimeInterval
    /// Local window treated as "idle overnight" (nil = never idle).
    public var idleHours: QuietHours?
    /// New attention activity keeps an account hot for this long.
    public var hotWindow: TimeInterval
    /// First retry delay after a failure; doubles per consecutive failure.
    public var backoffBase: TimeInterval
    /// Upper bound of the failure backoff (15 min). Rate-limit resets may exceed it (they come from the provider).
    public var backoffCap: TimeInterval
    /// Relative jitter applied to every delay (0.1 = ±10 %; rate-limit waits only get positive jitter).
    public var jitterFraction: Double
    /// Maximum concurrent `hydrate` calls per account.
    public var hydrateConcurrency: Int
    /// Stored snapshots older than this are re-hydrated even if the listing says nothing changed (CI status changes
    /// do not always bump a PR's `updated_at`). Snapshots with pending checks are always re-hydrated.
    public var fullRefreshInterval: TimeInterval
    /// Notifications are suppressed inside this window (events, attention and rules still run).
    public var quietHours: QuietHours?
    /// Accounts that are not synced at all (state `paused`).
    public var disabledAccounts: Set<AccountKey>
    /// Event types that produce a notification on the user's own change requests without an attention item.
    public var informationalNotificationTypes: Set<ChangeEventType>

    public init(
        defaultInterval: TimeInterval = 90,
        hotInterval: TimeInterval = 45,
        idleInterval: TimeInterval = 300,
        idleHours: QuietHours? = QuietHours(start: (hour: 0, minute: 0), end: (hour: 7, minute: 0), timeZone: .current),
        hotWindow: TimeInterval = 15 * 60,
        backoffBase: TimeInterval = 30,
        backoffCap: TimeInterval = 900,
        jitterFraction: Double = 0.1,
        hydrateConcurrency: Int = 4,
        fullRefreshInterval: TimeInterval = 10 * 60,
        quietHours: QuietHours? = nil,
        disabledAccounts: Set<AccountKey> = [],
        informationalNotificationTypes: Set<ChangeEventType> = [.approval]
    ) {
        self.defaultInterval = defaultInterval
        self.hotInterval = hotInterval
        self.idleInterval = idleInterval
        self.idleHours = idleHours
        self.hotWindow = hotWindow
        self.backoffBase = backoffBase
        self.backoffCap = backoffCap
        self.jitterFraction = jitterFraction
        self.hydrateConcurrency = hydrateConcurrency
        self.fullRefreshInterval = fullRefreshInterval
        self.quietHours = quietHours
        self.disabledAccounts = disabledAccounts
        self.informationalNotificationTypes = informationalNotificationTypes
    }

    public static let `default` = SyncConfiguration()

    /// Deterministic settings for tests and demo mode: no jitter, no overnight idling.
    public static var deterministic: SyncConfiguration {
        SyncConfiguration(idleHours: nil, jitterFraction: 0)
    }
}

/// Pure scheduling arithmetic (unit tested; the syncer only adds the random jitter sample).
public enum SyncSchedule {
    /// Interval after a successful cycle.
    public static func successInterval(now: Date, isHot: Bool, configuration: SyncConfiguration) -> TimeInterval {
        if isHot { return configuration.hotInterval }
        if let idle = configuration.idleHours, idle.contains(now) { return configuration.idleInterval }
        return configuration.defaultInterval
    }

    /// Exponential failure backoff: `base * 2^(failures-1)`, capped.
    public static func backoff(consecutiveFailures: Int, configuration: SyncConfiguration) -> TimeInterval {
        let failures = max(1, consecutiveFailures)
        let exponent = Double(min(failures - 1, 30))
        return min(configuration.backoffCap, max(0, configuration.backoffBase) * pow(2, exponent))
    }

    /// Delay before the next cycle for an account in `state`, or nil when the account must not be polled again
    /// automatically (`authExpired`, `paused`). `jitterSample` is a value in `0..<1` (0.5 = no jitter).
    public static func nextDelay(
        state: AccountSyncState,
        consecutiveFailures: Int,
        now: Date,
        isHot: Bool,
        configuration: SyncConfiguration,
        jitterSample: Double = 0.5
    ) -> TimeInterval? {
        let fraction = max(0, min(configuration.jitterFraction, 1))
        let symmetric = 1 + fraction * (2 * min(max(jitterSample, 0), 1) - 1)
        switch state {
        case .authExpired, .paused:
            return nil
        case .ok, .idle, .syncing:
            return successInterval(now: now, isHot: isHot, configuration: configuration) * symmetric
        case .rateLimited(let until):
            let backoff = backoff(consecutiveFailures: consecutiveFailures, configuration: configuration)
            guard let until else { return backoff * symmetric }
            let wait = max(1, until.timeIntervalSince(now))
            // Never retry before the reset: jitter only pushes later.
            return wait * (1 + fraction * min(max(jitterSample, 0), 1))
        case .offline, .permissionDenied, .error:
            return backoff(consecutiveFailures: consecutiveFailures, configuration: configuration) * symmetric
        }
    }
}
