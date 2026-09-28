import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueFixtures
import MergeCueIPC
import MergeCueNetworking
import MergeCueStore
import MergeCueSync
import WorkspaceInspector

/// The composition root (docs/ARCHITECTURE.md §10): wires the database, credentials, the three adapters
/// (`LiveProviderFactory`), `SyncCoordinator`, `GitWorkspaceInspector`, `MergeCueEngine`, notifications and the
/// private IPC server that `mergecue-mcp` talks to.
///
/// ```swift
/// let runtime = try await MergeCueRuntime.makeLive(appVersion: "1.0")   // or .makeDemo(appVersion:)
/// try await runtime.start()
/// let engine = runtime.engine                                           // the UI's façade
/// …
/// await runtime.stop()                                                  // on quit: socket removed
/// ```
///
/// - **Live**: data in `MergeCuePaths.root` (Application Support, or `MERGECUE_HOME`), credentials in the Keychain.
/// - **Demo**: data in `<root>/demo`, an in-memory credential store, three demo accounts (`isDemo`) served by the
///   real adapters over fixture routes, a synthetic local checkout with pre-confirmed mappings, and a scenario
///   that advances on every manual refresh (`DemoScenario`). The engine reports `isDemo` (`ping.is_demo`, previews
///   are "simulated"). The IPC socket/token stay at the base `paths`, so an agent's registered `mergecue-mcp`
///   reaches the demo exactly like the live app.
public final class MergeCueRuntime: Sendable {
    public let mode: RuntimeMode
    public let appVersion: String
    /// Base paths: the IPC socket/token the helper connects to (and `MERGECUE_HOME` for the helper).
    public let paths: MergeCuePaths
    /// Where this runtime's data lives: `paths` in live mode, `<root>/demo` in demo mode.
    public let dataPaths: MergeCuePaths
    public let engine: MergeCueEngine
    /// The concrete sync service (wake/network hooks, statuses). The engine sees it through `SyncControlling`.
    public let sync: SyncCoordinator
    public let database: MergeCueDatabase
    public let credentials: any CredentialStoring
    public let providers: LiveProviderFactory
    public let workspace: GitWorkspaceInspector
    /// The fixture scenario (demo mode only).
    public let demo: DemoScenario?
    public let options: RuntimeOptions

    let lifecycle = RuntimeLifecycle()
    let relay: ChangeRelay
    let log = MCLog(category: "runtime")

    public var isDemo: Bool { mode == .demo }

    init(
        mode: RuntimeMode, appVersion: String, paths: MergeCuePaths, dataPaths: MergeCuePaths, engine: MergeCueEngine,
        sync: SyncCoordinator, database: MergeCueDatabase, credentials: any CredentialStoring,
        providers: LiveProviderFactory, workspace: GitWorkspaceInspector, demo: DemoScenario?, options: RuntimeOptions,
        relay: ChangeRelay
    ) {
        self.mode = mode
        self.appVersion = appVersion
        self.paths = paths
        self.dataPaths = dataPaths
        self.engine = engine
        self.sync = sync
        self.database = database
        self.credentials = credentials
        self.providers = providers
        self.workspace = workspace
        self.demo = demo
        self.options = options
        self.relay = relay
    }

    // MARK: Factories

    /// The live runtime: real accounts from the database, credentials from the Keychain, real HTTP.
    public static func makeLive(
        paths: MergeCuePaths = MergeCuePaths(),
        appVersion: String,
        options: RuntimeOptions = RuntimeOptions()
    ) async throws -> MergeCueRuntime {
        try paths.ensureDirectories()
        let database = try MergeCueDatabase(url: paths.database)
        let credentials = options.credentials ?? KeychainCredentialStore()
        let providers = LiveProviderFactory(clock: options.clock, appVersion: appVersion)
        return try await assemble(
            mode: .live, appVersion: appVersion, paths: paths, dataPaths: paths, database: database,
            credentials: credentials, providers: providers, demo: nil, options: options
        )
    }

    /// The demo runtime: `<paths.root>/demo`, in-memory credentials, fixture transports, a synthetic checkout.
    public static func makeDemo(
        paths: MergeCuePaths = MergeCuePaths(),
        appVersion: String,
        options: RuntimeOptions = RuntimeOptions()
    ) async throws -> MergeCueRuntime {
        let demoRoot = paths.root.appending(path: "demo", directoryHint: .isDirectory)
        let dataPaths = MergeCuePaths(root: demoRoot, logs: paths.logs, socketOverride: paths.socket)
        try paths.ensureDirectories()
        try dataPaths.ensureDirectories()
        let scenario = try DemoScenario(directory: demoRoot.appending(path: "scenario", directoryHint: .isDirectory))
        let database = try MergeCueDatabase(url: dataPaths.database)
        let credentials = options.credentials ?? InMemoryCredentialStore()
        for account in DemoScenario.accounts {
            if let credential = DemoScenario.credentials[account.id] {
                try credentials.save(credential, for: account.id)
            }
            if let existing = try await database.account(account.id) {
                // Keep the owner's choices (writes toggle, label) across relaunches; the account stays demo.
                var kept = existing
                kept.isDemo = true
                if kept != existing { try await database.upsertAccount(kept) }
            } else {
                try await database.upsertAccount(account)
            }
        }
        let providers = LiveProviderFactory(clock: options.clock, appVersion: appVersion) { instance in
            scenario.transport(for: instance.kind)
        }
        var options = options
        if options.syncConfiguration == nil { options.syncConfiguration = .deterministic }
        options.monitorsNetwork = false
        // The synthetic repository routes fetches through its own config; keep git hermetic in demo mode.
        for (key, value) in ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"] where options.gitEnvironmentOverrides[key] == nil {
            options.gitEnvironmentOverrides[key] = value
        }
        return try await assemble(
            mode: .demo, appVersion: appVersion, paths: paths, dataPaths: dataPaths, database: database,
            credentials: credentials, providers: providers, demo: scenario, options: options
        )
    }

    private static func assemble(
        mode: RuntimeMode, appVersion: String, paths: MergeCuePaths, dataPaths: MergeCuePaths,
        database: MergeCueDatabase, credentials: any CredentialStoring, providers: LiveProviderFactory,
        demo: DemoScenario?, options: RuntimeOptions
    ) async throws -> MergeCueRuntime {
        let relay = ChangeRelay()
        let notifier = options.notifier ?? UserNotificationDeliverer(isDemo: mode == .demo)
        let sync = SyncCoordinator(
            database: database, credentials: credentials, providers: providers, notifier: notifier, clock: options.clock,
            configuration: options.syncConfiguration ?? .default,
            onChange: { change in relay.forward(change) }
        )
        let workspace = GitWorkspaceInspector(
            worktreeRoot: dataPaths.worktrees, environmentOverrides: options.gitEnvironmentOverrides
        )
        let syncControl: any SyncControlling = demo.map { DemoSyncControl(coordinator: sync, scenario: $0) } ?? sync
        let engine = MergeCueEngine(environment: EngineEnvironment(
            database: database, credentials: credentials, providers: providers, sync: syncControl, workspace: workspace,
            clock: options.clock, paths: dataPaths, isDemo: mode == .demo, appVersion: appVersion,
            leaseDuration: options.leaseDuration, staleCheckInterval: options.staleCheckInterval,
            mappingSearchRoots: options.mappingSearchRoots, ids: options.ids, notifier: notifier
        ))
        relay.connect(engine)
        return MergeCueRuntime(
            mode: mode, appVersion: appVersion, paths: paths, dataPaths: dataPaths, engine: engine, sync: sync,
            database: database, credentials: credentials, providers: providers, workspace: workspace, demo: demo,
            options: options, relay: relay
        )
    }

    // MARK: Lifecycle

    /// Starts everything (idempotent): link registries preloaded from stored snapshots, the engine (rule handler,
    /// stale-lease monitor), Sync (every account polls; network monitoring in live mode) and the IPC server.
    /// In demo mode it also waits for the baseline sync and maps the synthetic checkout.
    ///
    /// - Throws: `RuntimeError.alreadyRunning` when another instance serves the socket, `.ipcFailed` otherwise.
    public func start() async throws {
        guard await lifecycle.beginStart() else { return }
        let preloaded = await LinkPreloader.preload(from: database)
        log.info("runtime (\(mode.rawValue)) starting; \(preloaded) stored change request(s) preloaded for deep links")
        await engine.start()
        await sync.start()
        if options.monitorsNetwork, mode == .live {
            await sync.startNetworkMonitoring()
        }
        if options.startsIPCServer {
            do {
                try await startIPC()
            } catch {
                await stop()
                throw error
            }
        }
        if let demo {
            await sync.refreshAll()
            await DemoSetup.ensureMappings(engine: engine, database: database, scenario: demo)
        }
        await lifecycle.finishStart()
    }

    /// Stops the IPC server (socket and token removed), Sync and the engine. Idempotent.
    public func stop() async {
        if let server = await lifecycle.takeServer() {
            await server.stop()
        }
        await sync.stop()
        await engine.stop()
        await lifecycle.markStopped()
        log.info("runtime (\(mode.rawValue)) stopped")
    }

    /// Call on `NSWorkspace.didWakeNotification`: every account refreshes (without advancing the demo scenario)
    /// and expired agent leases turn stale right away.
    public func handleSystemWake() async {
        await sync.handleSystemWake()
        _ = await engine.sweepExpiredLeases()
    }

    /// The manual refresh (same as `engine.refresh(account:)`; in demo mode it advances the scenario).
    public func refresh(account: AccountKey? = nil) async {
        await engine.refresh(account: account)
    }

    public var isRunning: Bool {
        get async { await lifecycle.isStarted }
    }

    // MARK: IPC

    /// Whether the private channel is up, where, and which peer checks apply.
    public struct IPCStatus: Sendable, Hashable {
        public var isRunning: Bool
        public var socketPath: String
        public var peerValidation: String
    }

    public func ipcStatus() async -> IPCStatus {
        let (running, description) = await lifecycle.ipcState()
        return IPCStatus(isRunning: running, socketPath: paths.socketPath, peerValidation: description)
    }

    private func startIPC() async throws {
        let (validator, description): ((any PeerValidator)?, String)
        do {
            (validator, description) = try RuntimeIPC.peerValidator(for: options.peerValidation)
        } catch {
            throw RuntimeError.ipcFailed("invalid code requirement: \(error.localizedDescription)")
        }
        let server = IPCServer(paths: paths, handler: engine, peerValidator: validator)
        do {
            try await server.start()
        } catch {
            if case .alreadyRunning(let socketPath) = error {
                throw RuntimeError.alreadyRunning(socketPath: socketPath)
            }
            throw RuntimeError.ipcFailed(error.localizedDescription)
        }
        await lifecycle.setServer(server, description: description)
        log.notice("IPC listening at \(paths.socketPath); peers: \(description)")
    }
}

/// Mutable lifecycle state of a runtime.
actor RuntimeLifecycle {
    private(set) var isStarted = false
    private var starting = false
    private var server: IPCServer?
    private var peerDescription = "not running"

    func beginStart() -> Bool {
        guard !isStarted, !starting else { return false }
        starting = true
        return true
    }

    func finishStart() {
        starting = false
        isStarted = true
    }

    func markStopped() {
        starting = false
        isStarted = false
    }

    func setServer(_ server: IPCServer, description: String) {
        self.server = server
        peerDescription = description
    }

    func takeServer() -> IPCServer? {
        defer { server = nil; peerDescription = "not running" }
        return server
    }

    func ipcState() async -> (Bool, String) {
        guard let server else { return (false, peerDescription) }
        return (await server.isRunning, peerDescription)
    }
}
