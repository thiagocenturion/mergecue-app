import Foundation

/// How often MergeCue checks one account for updates (Settings ▸ Accounts ▸ "Check for updates"; DECISIONS D36).
///
/// It is the account's list cadence. Per-change-request detail refreshes scale with it (quiet PRs/MRs are never
/// refreshed faster than this interval); the 30 s tier only applies to change requests with an active agent task or
/// pending checks. `manual` lists only at launch and on a manual Refresh: no timer, no refresh on return/focus,
/// wake or network recovery, and no automatic detail refreshes.
public enum RefreshInterval: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case manual

    /// The default for new and existing accounts.
    public static let `default` = RefreshInterval.fifteenMinutes

    public var id: String { rawValue }

    /// Seconds between list polls; nil for `manual`.
    public var listInterval: TimeInterval? {
        switch self {
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .manual: nil
        }
    }

    public var isManual: Bool { self == .manual }

    /// Picker label ("Every 15 min", "Manually only").
    public var displayName: String {
        switch self {
        case .fiveMinutes: "Every 5 min"
        case .fifteenMinutes: "Every 15 min"
        case .thirtyMinutes: "Every 30 min"
        case .oneHour: "Every hour"
        case .manual: "Manually only"
        }
    }
}

/// Which repositories' change requests one account syncs (Settings ▸ Accounts ▸ "Repositories to watch";
/// DECISIONS D36).
///
/// `Account.watchedRepositories` holds the owner's explicit choice: nil = never chosen, which means "the
/// repositories mapped to a local checkout" (and all repositories when none is mapped); an explicit empty list means
/// all repositories. When the effective list is non-empty, Sync lists only those repositories (scoped provider
/// queries) and never lists the account's other repositories during a sync cycle.
public enum WatchedRepositories {
    /// The repositories Sync tracks for `account` (empty = all repositories). `mapped` are the repositories of the
    /// account's checkout mappings, in mapping order; duplicates and other accounts' keys are dropped. Demo accounts
    /// show every fixture repository until the owner picks some (their demo checkout mapping is not a choice).
    public static func effective(for account: Account, mapped: [RepoKey]) -> [RepoKey] {
        var seen = Set<RepoKey>()
        let source = account.watchedRepositories ?? (account.isDemo ? [] : mapped)
        return source.filter { $0.account == account.id && seen.insert($0).inserted }
    }

    /// True when the account follows its mappings (the owner never edited the list).
    public static func followsMappings(_ account: Account) -> Bool {
        account.watchedRepositories == nil && !account.isDemo
    }
}
