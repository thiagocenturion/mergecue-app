import Foundation
import Network

/// System network reachability as an `AsyncStream<Bool>` (`true` = a usable path exists), backed by
/// `NWPathMonitor`. Feed it to `SyncCoordinator.observeNetwork(_:)` so accounts refresh on recovery.
public struct NetworkReachability: Sendable {
    public init() {}

    /// A new stream with its own monitor; the monitor is cancelled when the stream terminates.
    public func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "dev.mergecue.sync.reachability"))
        }
    }
}
