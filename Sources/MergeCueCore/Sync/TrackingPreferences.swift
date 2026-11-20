import Foundation

/// Which pull/merge requests MergeCue tracks, beyond the ones the user authored (always tracked), and whether it
/// tracks them automatically right now.
///
/// Live accounts default to **authored only** (owner decision): review requests and change requests of others the
/// user reviewed or commented on are opt-in, so MergeCue never lists other people's work unless asked to.
/// The auto-sync fields (manual pause, schedule rules) stop every automatic request; Refresh still works. They live
/// here so they persist and reach Sync and the UI through the same path as the tracking choice.
public struct TrackingPreferences: Codable, Sendable, Hashable {
    /// Also track PRs/MRs of others that request the user's review.
    public var includeReviewRequests: Bool
    /// Also track PRs/MRs of others the user already reviewed or commented on (the "involved" listing).
    public var includeInvolved: Bool
    /// Automatic sync (timers, return/focus, wake, network recovery) is paused until this date; nil = running,
    /// `Date.distantFuture` = until the user resumes. Manual refreshes and user actions are unaffected.
    public var autoSyncPausedUntil: Date?
    /// Rules that pause automatic sync on their own (weekends, outside working hours, holidays).
    public var autoSyncSchedule: AutoSyncSchedule
    /// "Sync anyway": the schedule does not pause automatic sync until this date (set during a scheduled pause).
    public var autoSyncScheduleOverrideUntil: Date?

    public init(
        includeReviewRequests: Bool = false,
        includeInvolved: Bool = false,
        autoSyncPausedUntil: Date? = nil,
        autoSyncSchedule: AutoSyncSchedule = .off,
        autoSyncScheduleOverrideUntil: Date? = nil
    ) {
        self.includeReviewRequests = includeReviewRequests
        self.includeInvolved = includeInvolved
        self.autoSyncPausedUntil = autoSyncPausedUntil
        self.autoSyncSchedule = autoSyncSchedule
        self.autoSyncScheduleOverrideUntil = autoSyncScheduleOverrideUntil
    }

    private enum CodingKeys: String, CodingKey {
        case includeReviewRequests, includeInvolved, autoSyncPausedUntil, autoSyncSchedule, autoSyncScheduleOverrideUntil
    }

    /// Tolerates preferences saved before the auto-sync fields existed.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includeReviewRequests = try c.decodeIfPresent(Bool.self, forKey: .includeReviewRequests) ?? false
        includeInvolved = try c.decodeIfPresent(Bool.self, forKey: .includeInvolved) ?? false
        autoSyncPausedUntil = try c.decodeIfPresent(Date.self, forKey: .autoSyncPausedUntil)
        autoSyncSchedule = try c.decodeIfPresent(AutoSyncSchedule.self, forKey: .autoSyncSchedule) ?? .off
        autoSyncScheduleOverrideUntil = try c.decodeIfPresent(Date.self, forKey: .autoSyncScheduleOverrideUntil)
    }

    /// Whether automatic sync is paused at `now`.
    public func isAutoSyncPaused(at now: Date) -> Bool {
        guard let until = autoSyncPausedUntil else { return false }
        return until > now
    }

    /// Only the user's own PRs/MRs (the live default).
    public static let authoredOnly = TrackingPreferences()
    /// Authored, review-requested and involved (demo default, and Sync's default until told otherwise).
    public static let all = TrackingPreferences(includeReviewRequests: true, includeInvolved: true)

    /// Whether a listing of `scope` should run.
    public func tracks(_ scope: ChangeRequestScope) -> Bool {
        switch scope {
        case .authored: true
        case .reviewRequested: includeReviewRequests
        case .involved: includeInvolved
        }
    }
}
