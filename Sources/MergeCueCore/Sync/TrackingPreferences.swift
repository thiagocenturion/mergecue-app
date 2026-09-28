import Foundation

/// Which pull/merge requests MergeCue tracks, beyond the ones the user authored (always tracked).
///
/// Live accounts default to **authored only** (owner decision): review requests and change requests of others the
/// user reviewed or commented on are opt-in, so MergeCue never lists other people's work unless asked to.
public struct TrackingPreferences: Codable, Sendable, Hashable {
    /// Also track PRs/MRs of others that request the user's review.
    public var includeReviewRequests: Bool
    /// Also track PRs/MRs of others the user already reviewed or commented on (the "involved" listing).
    public var includeInvolved: Bool

    public init(includeReviewRequests: Bool = false, includeInvolved: Bool = false) {
        self.includeReviewRequests = includeReviewRequests
        self.includeInvolved = includeInvolved
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
