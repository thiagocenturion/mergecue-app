import Foundation
import MergeCueCore
import MergeCueStore

/// Everything the engine needs, injected by `MergeCueRuntime` (live/demo) or by tests (in-memory store + fakes).
///
/// The engine talks to Sync, the providers and the local workspace **only** through these Core protocols.
public struct EngineEnvironment: Sendable {
    public var database: MergeCueDatabase
    public var credentials: any CredentialStoring
    public var providers: any ProviderFactory
    public var sync: any SyncControlling
    public var workspace: any WorkspaceInspecting
    public var clock: any MCClock
    public var paths: MergeCuePaths
    /// True when the app serves labeled fixture data (`ping.is_demo`, previews are marked simulated).
    public var isDemo: Bool
    public var appVersion: String
    /// Agent lease length; renewed by `heartbeat` / `update_task` / reports. Default 600 s.
    public var leaseDuration: TimeInterval
    /// Period of the stale-lease monitor. Default 30 s.
    public var staleCheckInterval: TimeInterval
    /// Maximum agent writes per task per minute (`rate_limited` beyond). Default 30.
    public var maxWritesPerTaskPerMinute: Int
    /// How long an action preview can be approved after it was built. Default 600 s.
    public var previewLifetime: TimeInterval
    /// Folders scanned for checkout mapping suggestions (e.g. `~/Developer`).
    public var mappingSearchRoots: [String]
    /// Id source (seeded in tests).
    public var ids: IDGenerator
    /// Delivers the engine's own alerts ("agent result ready for review"); nil = none. Sync has its own notifier.
    public var notifier: (any NotificationDelivering)?

    public init(
        database: MergeCueDatabase,
        credentials: any CredentialStoring,
        providers: any ProviderFactory,
        sync: any SyncControlling,
        workspace: any WorkspaceInspecting,
        clock: any MCClock = SystemClock(),
        paths: MergeCuePaths = MergeCuePaths(),
        isDemo: Bool = false,
        appVersion: String = "0.0.0",
        leaseDuration: TimeInterval = 600,
        staleCheckInterval: TimeInterval = 30,
        maxWritesPerTaskPerMinute: Int = 30,
        previewLifetime: TimeInterval = 600,
        mappingSearchRoots: [String] = [],
        ids: IDGenerator = .system,
        notifier: (any NotificationDelivering)? = nil
    ) {
        self.database = database
        self.credentials = credentials
        self.providers = providers
        self.sync = sync
        self.workspace = workspace
        self.clock = clock
        self.paths = paths
        self.isDemo = isDemo
        self.appVersion = appVersion
        self.leaseDuration = leaseDuration
        self.staleCheckInterval = staleCheckInterval
        self.maxWritesPerTaskPerMinute = maxWritesPerTaskPerMinute
        self.previewLifetime = previewLifetime
        self.mappingSearchRoots = mappingSearchRoots
        self.ids = ids
        self.notifier = notifier
    }
}
