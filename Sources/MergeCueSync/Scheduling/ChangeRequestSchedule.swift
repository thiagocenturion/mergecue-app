import Foundation
import MergeCueCore

/// Scheduling inputs that change between cycles (hot hints, budget pressure).
struct ScheduleHints: Sendable {
    var now: Date
    /// Change requests with an active agent task.
    var hotKeys: Set<ChangeRequestKey> = []
    /// `SyncCoordinator.setHot(until:)` is in effect: every CR refreshes every cycle.
    var allHot = false
    /// Budget slowdown factor (≥ 1) of the account.
    var slowdown: Double = 1
    /// The account's list interval; nil = "Manually only" (no automatic detail refreshes at all).
    var listInterval: TimeInterval? = SyncConfiguration.default.listInterval
    /// The cycle is a manual refresh: CRs whose state the listing cannot show (pending checks, active agent
    /// task) are hydrated too, even when their automatic slot is not due (or there is none, "Manually only").
    var isManualRefresh = false

    func isHot(_ key: ChangeRequestKey) -> Bool { allHot || hotKeys.contains(key) }
}

/// Per-change-request polling state of one account (in memory; rebuilt from stored snapshots after a relaunch).
///
/// - Details refresh only inside list cycles, so never faster than the account's list interval
///   (`SyncSchedule.detailInterval`): every cycle while the CR changed within the last hour, has an active agent
///   task or checks running for less than 2 h; every second cycle once idle. Checks still "running" after 2 h count
///   as stuck. "Manually only" accounts have no automatic detail refreshes. A changed list version always hydrates
///   in the cycle that sees it.
/// - A failed hydration is retried 1 → 2 → 4 cycles later. `not found` / `forbidden` are terminal: the CR is not
///   retried until its list version changes, a manual refresh, or the user returns (`resetFailures`).
struct ChangeRequestSchedule: Sendable {
    struct Tracker: Sendable {
        var summary: ChangeRequestSummary
        var lastChangedAt: Date
        /// Last hydration attempt (success or failure).
        var lastAttemptAt: Date?
        var checksPending = false
        /// When the pending checks started running (or were first seen pending); nil = no pending checks.
        var pendingSince: Date?
        /// The stored snapshot is merged/closed: the next listing removes it, no detail polling meanwhile.
        var isFinished = false
        var failures = 0
        var lastError: ProviderError?
        var isTerminal = false
        var failedAt: Date?
        /// List version the CR had when it failed terminally (a different version retries it).
        var failedListVersion: String?
        var fingerprint: ActivityFingerprint?
        /// The version the CR had in the latest listing.
        var listVersion: String?
    }

    private(set) var trackers: [ChangeRequestKey: Tracker] = [:]

    // MARK: Seeding

    /// Adds trackers for stored snapshots that have none yet (after launch): last change = the snapshot's own
    /// activity time, last attempt = when it was fetched.
    mutating func seed(from snapshots: [ChangeRequestSnapshot]) {
        for snapshot in snapshots where trackers[snapshot.key] == nil {
            trackers[snapshot.key] = Tracker(
                summary: snapshot.summary,
                lastChangedAt: min(Self.activityDate(snapshot), snapshot.fetchedAt),
                lastAttemptAt: snapshot.fetchedAt,
                checksPending: snapshot.aggregateCheckState == .pending,
                pendingSince: Self.pendingSince(snapshot, previous: nil, now: snapshot.fetchedAt),
                isFinished: snapshot.summary.state != .open,
                fingerprint: ActivityFingerprint(snapshot)
            )
        }
    }

    // MARK: Selection

    /// Whether a listed CR is hydrated in a full cycle.
    mutating func shouldHydrate(
        listed summary: ChangeRequestSummary,
        listVersion: String,
        storedListVersion: String?,
        hasSnapshot: Bool,
        hints: ScheduleHints,
        configuration: SyncConfiguration
    ) -> Bool {
        guard var tracker = trackers[summary.key] else {
            // Never seen (no snapshot, no failure): hydrate.
            var tracker = Tracker(summary: summary, lastChangedAt: min(summary.updatedAt, hints.now))
            tracker.listVersion = listVersion
            trackers[summary.key] = tracker
            return true
        }
        tracker.summary = summary
        tracker.listVersion = listVersion
        defer { trackers[summary.key] = tracker }
        if tracker.isTerminal {
            // Terminal failure: only a new list version retries it.
            return tracker.failedListVersion != listVersion
        }
        if !hasSnapshot && tracker.failures == 0 { return true }
        if hasSnapshot, storedListVersion != listVersion { return true }
        // Refresh re-reads every CR whose state the listing cannot show, stuck checks included (the user asked).
        if hints.isManualRefresh, tracker.failures == 0, !tracker.isFinished,
           tracker.checksPending || hints.isHot(summary.key) {
            return true
        }
        guard let due = dueDate(tracker, hints: hints, configuration: configuration) else { return false }
        return due <= hints.now
    }

    /// Keys due for a detail refresh (manual detail-only cycles; automatic cycles always list first).
    func dueKeys(hints: ScheduleHints, configuration: SyncConfiguration) -> [ChangeRequestKey] {
        trackers.compactMap { key, tracker in
            guard let due = dueDate(tracker, hints: hints, configuration: configuration), due <= hints.now else { return nil }
            return key
        }
        .sorted { $0.id < $1.id }
    }

    /// The earliest automatic detail refresh (nil = none scheduled).
    func earliestDue(hints: ScheduleHints, configuration: SyncConfiguration) -> Date? {
        trackers.values.compactMap { dueDate($0, hints: hints, configuration: configuration) }.min()
    }

    /// When the tracker is next due (`distantPast` = now: never attempted or reset), or nil (terminal failure,
    /// finished, or an account that checks "Manually only").
    func dueDate(_ tracker: Tracker, hints: ScheduleHints, configuration: SyncConfiguration) -> Date? {
        guard !tracker.isTerminal, !tracker.isFinished else { return nil }
        guard let last = tracker.lastAttemptAt else { return .distantPast }
        guard let listInterval = hints.listInterval else { return nil }
        if tracker.failures > 0 {
            return last.addingTimeInterval(
                SyncSchedule.changeRequestBackoff(failures: tracker.failures, listInterval: listInterval, configuration: configuration)
            )
        }
        let interval = SyncSchedule.detailInterval(
            sinceChange: max(0, last.timeIntervalSince(tracker.lastChangedAt)),
            isHot: hints.isHot(tracker.summary.key),
            checksPending: checksRunning(tracker, now: hints.now, configuration: configuration),
            slowdown: hints.slowdown,
            listInterval: listInterval,
            configuration: configuration
        )
        return last.addingTimeInterval(interval)
    }

    /// Pending checks that are not stuck: reported pending or running for less than `stuckCheckAfter`.
    func checksRunning(_ tracker: Tracker, now: Date, configuration: SyncConfiguration) -> Bool {
        guard tracker.checksPending else { return false }
        guard let since = tracker.pendingSince else { return true }
        return now.timeIntervalSince(since) < configuration.stuckCheckAfter
    }

    func summary(_ key: ChangeRequestKey) -> ChangeRequestSummary? { trackers[key]?.summary }
    func tracker(_ key: ChangeRequestKey) -> Tracker? { trackers[key] }

    // MARK: Results

    /// A successful hydration: resets failures; "last changed" moves to `now` when the activity fingerprint changed
    /// (for a CR seen for the first time: its own activity time).
    mutating func recordSuccess(_ snapshot: ChangeRequestSnapshot, previous: ChangeRequestSnapshot?, now: Date) {
        let fingerprint = ActivityFingerprint(snapshot)
        var tracker = trackers[snapshot.key]
            ?? Tracker(summary: snapshot.summary, lastChangedAt: min(Self.activityDate(snapshot), now))
        let known = tracker.fingerprint ?? previous.map(ActivityFingerprint.init)
        if let known {
            if known != fingerprint { tracker.lastChangedAt = now }
        } else {
            tracker.lastChangedAt = min(Self.activityDate(snapshot), now)
        }
        // Checks of the same head that were already pending keep their start (a new push starts over).
        let samePendingHead = tracker.checksPending && tracker.summary.headSHA == snapshot.summary.headSHA
        tracker.summary = snapshot.summary
        tracker.fingerprint = fingerprint
        tracker.lastAttemptAt = now
        tracker.pendingSince = Self.pendingSince(snapshot, previous: samePendingHead ? tracker.pendingSince : nil, now: now)
        tracker.checksPending = snapshot.aggregateCheckState == .pending
        tracker.isFinished = snapshot.summary.state != .open
        tracker.failures = 0
        tracker.lastError = nil
        tracker.isTerminal = false
        tracker.failedAt = nil
        tracker.failedListVersion = nil
        trackers[snapshot.key] = tracker
    }

    /// A failed hydration of a CR whose list version is `listVersion` (nil in detail-only cycles: keep the known one).
    mutating func recordFailure(
        _ summary: ChangeRequestSummary, error: ProviderError, listVersion: String?, now: Date
    ) {
        var tracker = trackers[summary.key] ?? Tracker(summary: summary, lastChangedAt: min(summary.updatedAt, now))
        tracker.failures += 1
        tracker.lastError = error
        tracker.lastAttemptAt = now
        tracker.failedAt = now
        tracker.isTerminal = Self.isTerminal(error)
        tracker.failedListVersion = listVersion ?? tracker.listVersion ?? SyncCycle.listVersion(summary)
        trackers[summary.key] = tracker
    }

    /// Clears failures so every failed CR is retried on the next cycle. `terminalOlderThan` limits the reset of
    /// terminal failures to those that failed at least that long before `now` (return/focus); nil resets all.
    mutating func resetFailures(now: Date, terminalOlderThan: TimeInterval? = nil) {
        for (key, tracker) in trackers where tracker.failures > 0 {
            if tracker.isTerminal, let minimumAge = terminalOlderThan,
               let failedAt = tracker.failedAt, now.timeIntervalSince(failedAt) < minimumAge {
                continue
            }
            var reset = tracker
            reset.failures = 0
            reset.isTerminal = false
            reset.failedListVersion = nil
            reset.lastError = nil
            reset.failedAt = nil
            // Due now.
            reset.lastAttemptAt = nil
            trackers[key] = reset
        }
    }

    /// Drops trackers of CRs that left the lists.
    mutating func retain(_ keys: Set<ChangeRequestKey>) {
        trackers = trackers.filter { keys.contains($0.key) }
    }

    mutating func remove(_ key: ChangeRequestKey) {
        trackers[key] = nil
    }

    /// Failures shown in the account status (`listInterval` nil = "Manually only": no automatic retry).
    func errors(listInterval: TimeInterval?, configuration: SyncConfiguration) -> [ChangeRequestSyncError] {
        trackers.values.compactMap { tracker -> ChangeRequestSyncError? in
            guard tracker.failures > 0, let error = tracker.lastError, let failedAt = tracker.failedAt else { return nil }
            let retry: Date? = tracker.isTerminal || listInterval == nil
                ? nil
                : failedAt.addingTimeInterval(
                    SyncSchedule.changeRequestBackoff(failures: tracker.failures, listInterval: listInterval, configuration: configuration)
                )
            return ChangeRequestSyncError(
                changeRequest: tracker.summary.key,
                title: tracker.summary.title,
                repoFullPath: tracker.summary.repository.fullPath,
                webURL: WebLinkPolicy.webURL(tracker.summary.webURL),
                code: error.code,
                message: error.errorDescription ?? error.code,
                isTerminal: tracker.isTerminal,
                consecutiveFailures: tracker.failures,
                failedAt: failedAt,
                nextRetryAt: retry
            )
        }
        .sorted { $0.changeRequest.id < $1.changeRequest.id }
    }

    // MARK: Helpers

    static func isTerminal(_ error: ProviderError) -> Bool {
        switch error {
        case .notFound, .forbidden: true
        default: false
        }
    }

    /// When the snapshot's pending checks started: the earliest provider start time of a check that is not
    /// finished, else `previous` (same head, already pending), else `now` (first seen pending). Nil when no check is
    /// pending.
    static func pendingSince(_ snapshot: ChangeRequestSnapshot, previous: Date?, now: Date) -> Date? {
        guard snapshot.aggregateCheckState == .pending else { return nil }
        let started = snapshot.checks.filter { !$0.status.isTerminal }.compactMap(\.startedAt).min()
        return min(started ?? previous ?? now, now)
    }

    /// Latest activity of a snapshot (updated time, newest comment, newest check change), for seeding.
    static func activityDate(_ snapshot: ChangeRequestSnapshot) -> Date {
        var latest = snapshot.summary.updatedAt
        for thread in snapshot.threads where thread.lastActivityAt > latest { latest = thread.lastActivityAt }
        for check in snapshot.checks {
            if let date = check.completedAt ?? check.startedAt, date > latest { latest = date }
        }
        return latest
    }
}

/// What counts as "the change request changed" for the detail tiers: new activity (comments, reviews, updated
/// time), a head change, or a check state change.
struct ActivityFingerprint: Sendable, Hashable {
    var updatedAt: Date
    var headSHA: String?
    var state: ChangeRequestState
    var isDraft: Bool
    var aggregateChecks: AggregateCheckState
    var checks: [String]
    var commentCount: Int
    var lastThreadActivity: Date?
    var reviewCount: Int

    init(_ snapshot: ChangeRequestSnapshot) {
        updatedAt = snapshot.summary.updatedAt
        headSHA = snapshot.summary.headSHA
        state = snapshot.summary.state
        isDraft = snapshot.summary.isDraft
        aggregateChecks = snapshot.aggregateCheckState
        checks = snapshot.checks.map { "\($0.key.id)=\($0.status.rawValue)" }.sorted()
        commentCount = snapshot.threads.reduce(0) { $0 + $1.comments.count }
        lastThreadActivity = snapshot.threads.map(\.lastActivityAt).max()
        reviewCount = snapshot.reviews.count
    }
}
