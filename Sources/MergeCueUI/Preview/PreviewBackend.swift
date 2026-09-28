import Foundation
import MergeCueCore
import Synchronization

/// Variants of the synthetic preview dataset.
public nonisolated enum PreviewVariant: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Three accounts (GitHub ok, GitLab rate limited, Bitbucket synced 4 min ago), work in every state.
    case standard
    /// Same data; GitLab credentials expired and Bitbucket offline.
    case authExpired
    /// Nothing needs attention and no agent work is in progress.
    case allCaughtUp
    /// First launch: no accounts connected.
    case noAccounts

    public var id: String { rawValue }
}

/// Fans out change notifications to any number of `AsyncStream`s.
nonisolated final class ChangeBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    func notify() {
        let all = continuations.withLock { Array($0.values) }
        for continuation in all { continuation.yield() }
    }
}

/// In-memory `AppBackend` with rich synthetic data (mode `.preview`). Commands mutate the state realistically, but
/// nothing is fetched, posted, launched or stored: tokens are discarded, links into the synthetic repositories are
/// not opened, and no agent claim is ever faked — tasks stay "Waiting for agent" until a real agent claims them.
public actor PreviewBackend: AppBackend {
    public nonisolated let mode: BackendMode = .preview
    public nonisolated let variant: PreviewVariant

    var state: AppState
    let logs: [String: LogExcerpt]
    var previews: [String: ActionPreview] = [:]
    var completedActions: [TaskID: Set<RemoteActionKind>] = [:]
    var activityCounter = 0
    let clock: @Sendable () -> Date
    private let broadcaster = ChangeBroadcaster()

    /// - Parameters:
    ///   - variant: which synthetic scenario to load.
    ///   - now: the clock (pass a constant for reproducible snapshots and tests).
    public init(variant: PreviewVariant = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.variant = variant
        self.clock = now
        let world = PreviewWorld(now: now())
        self.state = world.makeState(variant: variant)
        self.logs = variant == .noAccounts ? [:] : world.makeCatalog().logs
    }

    /// The initial state of a variant, built synchronously (snapshots render without awaiting the actor).
    public nonisolated static func initialState(variant: PreviewVariant, now: Date) -> AppState {
        PreviewWorld(now: now).makeState(variant: variant)
    }

    /// The preview's CI log excerpts keyed by `CheckKey.id`.
    public nonisolated static func logExcerpts(now: Date) -> [String: LogExcerpt] {
        PreviewWorld(now: now).makeCatalog().logs
    }

    public func loadState() async -> AppState { state }

    public nonisolated func changes() -> AsyncStream<Void> { broadcaster.stream() }

    public func refresh() async {
        _ = try? await perform(.refresh(account: nil))
    }

    public func perform(_ command: AppCommand) async throws -> AppCommandResult {
        let result = try execute(command)
        if command.mutatesState { broadcaster.notify() }
        return result
    }

    var now: Date { clock() }

    func nextActivityID() -> String {
        activityCounter += 1
        return "act_pv_\(activityCounter)"
    }
}

nonisolated extension AppCommand {
    /// Whether the command can change `AppState` (read-only commands don't notify observers).
    var mutatesState: Bool {
        switch self {
        case .copyHandoffCommand, .openInAgent, .loadCheckLog, .openURL, .requestActionPreview, .prepareAgentRegistration,
             .findCheckouts, .exportDatabase, .requestNotificationPermission: false
        default: true
        }
    }
}
