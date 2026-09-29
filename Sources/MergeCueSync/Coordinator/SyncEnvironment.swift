import Foundation
import MergeCueCore
import MergeCueStore
import os

/// Dependencies and cross-account settings shared by the coordinator and its per-account syncers.
///
/// Mutable settings (configuration, notification pause, event handler, hot flag) live behind a lock so syncers can
/// read the latest values without hopping through the coordinator actor.
final class SyncEnvironment: Sendable {
    typealias EventHandler = @Sendable ([ChangeEvent]) async -> Void

    struct Settings: Sendable {
        var configuration: SyncConfiguration
        var pausedUntil: Date?
        var preferences: NotificationPreferences = .allEnabled
        /// Scopes listed besides "authored". `.all` until the engine forwards the owner's choice.
        var tracking: TrackingPreferences = .all
        var hotUntil: Date?
        /// Change requests with an active agent task (fast detail tier).
        var hotChangeRequests: Set<ChangeRequestKey> = []
        var eventHandler: EventHandler?
    }

    let database: MergeCueDatabase
    let notifier: any NotificationDelivering
    let clock: any MCClock
    let onChange: @Sendable (EngineChange) -> Void
    let jitter: @Sendable () -> Double
    /// Rolling per-account request counts (shown in the UI, drives the budget slowdown).
    let requestLedger: ProviderRequestLedger
    /// True when nobody records HTTP requests into `requestLedger` (tests, custom factories): Sync then records
    /// one request per provider call itself.
    let countsProviderCalls: Bool
    private let settings: OSAllocatedUnfairLock<Settings>

    init(
        database: MergeCueDatabase,
        notifier: any NotificationDelivering,
        clock: any MCClock,
        configuration: SyncConfiguration,
        onChange: @escaping @Sendable (EngineChange) -> Void,
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        requestLedger: ProviderRequestLedger? = nil
    ) {
        self.requestLedger = requestLedger ?? ProviderRequestLedger()
        self.countsProviderCalls = requestLedger == nil
        self.database = database
        self.notifier = notifier
        self.clock = clock
        self.onChange = onChange
        self.jitter = jitter
        self.settings = OSAllocatedUnfairLock(initialState: Settings(configuration: configuration))
    }

    var current: Settings { settings.withLock { $0 } }

    func update(_ change: @Sendable (inout Settings) -> Void) {
        settings.withLock { change(&$0) }
    }

    /// Records one provider call of `account` when Sync does the accounting itself.
    func recordProviderCall(_ account: AccountKey) {
        guard countsProviderCalls else { return }
        requestLedger.record(account, at: clock.now)
    }

    var notificationPolicy: NotificationPolicy {
        let current = current
        return NotificationPolicy(
            pausedUntil: current.pausedUntil, quietHours: current.configuration.quietHours, preferences: current.preferences
        )
    }
}
