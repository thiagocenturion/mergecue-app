import Foundation
import os

/// Counts provider HTTP requests per account in a rolling window (default one hour). Thread-safe.
///
/// The runtime records every request an account's provider sends (`LiveProviderFactory` wraps the transport;
/// `304 Not Modified` answers are not recorded because conditional requests do not count against provider rate
/// limits). Sync reads the count to show "N requests in the last hour" and to slow detail refreshes down when an
/// account exceeds its soft budget.
public final class ProviderRequestLedger: Sendable {
    /// Length of the rolling window (3600 s).
    public let window: TimeInterval
    private let entries = OSAllocatedUnfairLock(initialState: [AccountKey: [Date]]())

    public init(window: TimeInterval = 3_600) {
        self.window = max(1, window)
    }

    /// Records one request of `account` at `date`.
    public func record(_ account: AccountKey, at date: Date) {
        let window = window
        entries.withLock { entries in
            var list = entries[account, default: []]
            list.append(date)
            // Prune lazily (keeps memory bounded by the request rate within one window).
            if list.count > 64, let first = list.first, date.timeIntervalSince(first) > window {
                list.removeAll { date.timeIntervalSince($0) >= window }
            }
            entries[account] = list
        }
    }

    /// Requests of `account` within the window ending at `now`.
    public func count(_ account: AccountKey, now: Date) -> Int {
        let window = window
        return entries.withLock { entries in
            guard var list = entries[account] else { return 0 }
            list.removeAll { now.timeIntervalSince($0) >= window }
            entries[account] = list
            return list.count
        }
    }

    /// Forgets every recorded request of `account` (account removed).
    public func reset(_ account: AccountKey) {
        _ = entries.withLock { $0.removeValue(forKey: account) }
    }
}
