import Foundation
import MergeCueCore

/// Deterministic text formatting against an explicit `now` (so previews and snapshots are reproducible).
public nonisolated enum UIFormat {
    /// Untrusted provider text (comment bodies, review summaries, check summaries) as it may be displayed and
    /// selected: terminal control sequences stripped and secrets redacted (S9).
    public static func untrustedDisplay(_ text: String) -> String {
        SecretRedactor.redact(TerminalControlStripper.strip(text))
    }

    /// "now", "6m", "2h", "3d", "5w".
    public static func compactAge(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(86_400 * 14): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (86_400 * 7)))w"
        }
    }

    /// "just now", "6 min ago", "2 h ago", "3 days ago".
    public static func relative(from date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "in " + duration(from: now, to: date) }
        switch seconds {
        case ..<45: return "just now"
        case ..<3_600: return "\(max(1, Int((seconds / 60).rounded()))) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) h ago"
        case ..<(86_400 * 2): return "yesterday"
        default: return "\(Int(seconds / 86_400)) days ago"
        }
    }

    /// "6 minutes ago" for VoiceOver.
    public static func spokenAge(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        func plural(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s") ago" }
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return plural(Int(seconds / 60), "minute")
        case ..<86_400: return plural(Int(seconds / 3_600), "hour")
        default: return plural(Int(seconds / 86_400), "day")
        }
    }

    /// "40 s", "34 min", "2 h 5 min", "3 days".
    public static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        switch seconds {
        case ..<60: return "\(Int(seconds)) s"
        case ..<3_600: return "\(Int(seconds / 60)) min"
        case ..<86_400:
            let hours = Int(seconds / 3_600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)
            return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "1 day" : "\(days) days"
        }
    }

    /// Localized short time ("14:05" / "2:05 PM").
    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Localized short date and time.
    public static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "synced 2 min ago", "Rate limited — retrying at 14:05", "Credentials expired", "Offline".
    public static func syncText(_ status: AccountSyncStatus, now: Date) -> String {
        switch status.state {
        case .ok, .idle:
            guard let last = status.lastSuccessAt else { return "Not synced yet" }
            return "synced " + relative(from: last, now: now)
        case .syncing:
            return status.lastSuccessAt == nil ? "Loading…" : "Syncing…"
        case .offline:
            guard let last = status.lastSuccessAt else { return "Offline" }
            return "Offline · synced " + relative(from: last, now: now)
        case .authExpired: return "Credentials expired"
        case .rateLimited(let until):
            guard let until else { return "Rate limited" }
            return "Rate limited — retrying at \(time(until))"
        case .permissionDenied: return "Unsupported permission"
        case .error: return "Sync error"
        case .paused: return "Paused"
        }
    }

    /// "1 PR couldn't be loaded: not found", "3 MRs couldn't be loaded: access denied, not found"; nil when every
    /// change request of the account loaded.
    public static func changeRequestFailureText(_ status: AccountSyncStatus, kind: ProviderKind) -> String? {
        let errors = status.changeRequestErrors
        guard !errors.isEmpty else { return nil }
        let noun = kind.changeRequestAbbreviation + (errors.count == 1 ? "" : "s")
        let reasons = Set(errors.map(\.reasonText)).sorted().joined(separator: ", ")
        return "\(errors.count) \(noun) couldn't be loaded: \(reasons)"
    }

    /// What happens next for failed change requests: "Retrying automatically at 14:05" / "Not retried until it
    /// changes — Retry to try again now".
    public static func changeRequestRetryText(_ status: AccountSyncStatus) -> String? {
        let errors = status.changeRequestErrors
        guard !errors.isEmpty else { return nil }
        if let next = errors.compactMap(\.nextRetryAt).min() {
            return "Retrying automatically at \(time(next))."
        }
        return "Not retried automatically until it changes. Retry to try again now."
    }

    /// "142 requests in the last hour" (+ " · budget 500/h reached, refreshing less often"); nil when unknown.
    public static func requestUsageText(_ status: AccountSyncStatus) -> String? {
        guard let used = status.requestsLastHour else { return nil }
        let count = "\(used) request\(used == 1 ? "" : "s") in the last hour"
        guard let budget = status.requestBudget else { return count }
        if status.isOverRequestBudget { return "\(count) · over the \(budget)/h budget, refreshing less often" }
        return "\(count) · budget \(budget)/h"
    }

    /// Tone of an account sync state.
    public static func tone(of state: AccountSyncState) -> Tone {
        switch state {
        case .ok, .idle: .success
        case .syncing, .paused: .neutral
        case .rateLimited, .offline: .attention
        case .authExpired, .permissionDenied, .error: .critical
        }
    }

    /// "a1b2c3d" (7-char SHA).
    public static func shortSHA(_ sha: String?) -> String {
        guard let sha, !sha.isEmpty else { return "—" }
        return String(sha.prefix(7))
    }

    /// Abbreviates the home directory as "~".
    public static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if !trimmedHome.isEmpty, path.hasPrefix(trimmedHome) {
            return "~" + path.dropFirst(trimmedHome.count)
        }
        return path
    }
}
