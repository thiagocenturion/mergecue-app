import AgentHandoff
import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueRuntime

/// The real `AppBackend`: the UI over `MergeCueRuntime` (live accounts, or the demo runtime's fixtures served by
/// the real adapters). State comes from `MergeCueEngine.snapshot()` plus the runtime's agent detection and
/// registration status; every `AppCommand` maps to the matching engine/runtime call (see
/// `EngineBackend+Commands.swift` and `Sources/MergeCueEngine/README.md`). Engine errors become `AppBackendError`s
/// with user-facing messages.
public actor EngineBackend: AppBackend {
    /// Injection points (tests replace agent detection, registration queries and the notification prompt, which
    /// would otherwise touch the real environment).
    public nonisolated struct Options: Sendable {
        public var detectAgents: @Sendable (MergeCueRuntime) async -> [DetectedAgent]
        public var registrationStatus: @Sendable (MergeCueRuntime, DetectedAgent) async -> AgentRegistrationStatus
        public var requestNotificationAuthorization: @Sendable () async -> Bool
        /// Files looked for at the root of mapped checkouts ("Project instructions" in the handoff checklist).
        public var instructionFileNames: [String]

        public init(
            detectAgents: @escaping @Sendable (MergeCueRuntime) async -> [DetectedAgent] = Options.detectInstalledAgents,
            registrationStatus: @escaping @Sendable (MergeCueRuntime, DetectedAgent) async -> AgentRegistrationStatus = Options.queryRegistration,
            requestNotificationAuthorization: @escaping @Sendable () async -> Bool = Options.askForNotifications,
            instructionFileNames: [String] = ["AGENTS.md", "CLAUDE.md"]
        ) {
            self.detectAgents = detectAgents
            self.registrationStatus = registrationStatus
            self.requestNotificationAuthorization = requestNotificationAuthorization
            self.instructionFileNames = instructionFileNames
        }

        // Defaults are plain nonisolated functions (not closures written in this MainActor-default module), so no
        // actor isolation is inferred for them.
        @Sendable public static func detectInstalledAgents(_ runtime: MergeCueRuntime) async -> [DetectedAgent] {
            await runtime.detectAgents()
        }

        @Sendable public static func queryRegistration(_ runtime: MergeCueRuntime, _ agent: DetectedAgent) async -> AgentRegistrationStatus {
            await runtime.registrationStatus(for: agent)
        }

        @Sendable public static func askForNotifications() async -> Bool {
            await UserNotificationDeliverer(isDemo: false).requestAuthorization()
        }
    }

    public nonisolated let mode: BackendMode
    public nonisolated let runtime: MergeCueRuntime
    let options: Options
    let log = MCLog(category: "ui")
    private let broadcaster = ChangeBroadcaster()

    /// Last good state (returned again if a snapshot read fails, so the UI never blanks).
    private var lastState: AppState?
    // Agent setup (slow to query: cached, refreshed on start and on demand).
    var detectedAgents: [DetectedAgent] = []
    var registrations: [AgentKind: AgentRegistrationStatus] = [:]
    var verifications: [AgentKind: VerificationRecord] = [:]
    private var agentsTask: Task<Void, Never>?
    // Repository directory and checkout scan (EngineBackend+Repositories.swift).
    var repositoryLists: [AccountKey: RepositoryListState] = [:]
    var repositoryTasks: [AccountKey: Task<Void, Never>] = [:]
    var checkoutScan = CheckoutScanState.idle
    var scanTask: Task<Void, Never>?
    var scanGeneration = 0

    public init(runtime: MergeCueRuntime, options: Options = Options()) {
        self.runtime = runtime
        self.mode = runtime.isDemo ? .demo : .live
        self.options = options
        self.verifications = VerificationRecord.load(from: Self.verificationFile(runtime))
    }

    /// Creates the runtime for `mode` (live: Keychain + real HTTP; demo: `<root>/demo` + fixtures), starts it
    /// (IPC server included) and begins agent detection in the background.
    ///
    /// - Throws: `RuntimeError.alreadyRunning` when another MergeCue serves the IPC socket.
    public static func launch(
        mode: RuntimeMode,
        paths: MergeCuePaths = MergeCuePaths(),
        appVersion: String,
        runtimeOptions: RuntimeOptions = RuntimeOptions(),
        options: Options = Options()
    ) async throws -> EngineBackend {
        let runtime = switch mode {
        case .live: try await MergeCueRuntime.makeLive(paths: paths, appVersion: appVersion, options: runtimeOptions)
        case .demo: try await MergeCueRuntime.makeDemo(paths: paths, appVersion: appVersion, options: runtimeOptions)
        }
        try await runtime.start()
        let backend = EngineBackend(runtime: runtime, options: options)
        await backend.startAgentDetection()
        return backend
    }

    // MARK: AppBackend

    public func loadState() async -> AppState {
        do {
            let snapshot = try await runtime.engine.snapshot()
            var state = await Self.makeState(
                snapshot, agents: agentStatuses(), runtime: runtimeInfo(),
                instructionFileNames: options.instructionFileNames
            )
            let accounts = Set(state.accounts.map(\.id))
            state.repositoryLists = repositoryLists.filter { accounts.contains($0.key) }
            state.checkoutScan = checkoutScan
            lastState = state
            return state
        } catch {
            log.error("snapshot failed: \(error.localizedDescription)")
            if let lastState { return lastState }
            return AppState(runtime: await runtimeInfo())
        }
    }

    public nonisolated func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let local = broadcaster.stream()
        let engine = runtime.engine
        let forwarder = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in await engine.changes() { continuation.yield() }
                }
                group.addTask {
                    for await _ in local { continuation.yield() }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in forwarder.cancel() }
        return stream
    }

    public func refresh() async {
        await runtime.refresh(account: nil)
    }

    public func handleSystemWake() async {
        await runtime.handleSystemWake()
    }

    public func shutdown() async {
        agentsTask?.cancel()
        scanTask?.cancel()
        repositoryTasks.values.forEach { $0.cancel() }
        await runtime.stop()
    }

    /// Tells observers that backend-local state (agents) changed.
    func notifyLocalChange() {
        broadcaster.notify()
    }

    // MARK: Agents

    /// Starts (once) the background detection of agents and their registration.
    func startAgentDetection() {
        guard agentsTask == nil else { return }
        agentsTask = Task { [weak self] in
            await self?.reloadAgents()
        }
    }

    /// Detects installed agents and queries each one's `mergecue` registration (read-only).
    public func reloadAgents() async {
        let detected = await options.detectAgents(runtime)
        var statuses: [AgentKind: AgentRegistrationStatus] = [:]
        for agent in detected {
            statuses[agent.kind] = await options.registrationStatus(runtime, agent)
        }
        detectedAgents = detected
        registrations = statuses
        notifyLocalChange()
    }

    func detected(_ kind: AgentKind) throws -> DetectedAgent {
        guard let agent = detectedAgents.first(where: { $0.kind == kind }) else {
            throw AppBackendError.unsupported("\(kind.displayName) wasn't found on this Mac. Install it, then refresh the agent list.")
        }
        return agent
    }

    func agentStatuses() -> [AgentStatus] {
        let helper = runtime.mcpHelperURL
        return detectedAgents.map { agent in
            AgentStatus(detected: agent, mcpRegistration: connectionState(agent.kind, helper: helper), canOpenTasks: true)
        }
    }

    /// Registered with this Mac's helper → `.registered` (verified only when a verification of that same helper
    /// succeeded); registered with another command → needs attention.
    func connectionState(_ kind: AgentKind, helper: URL?) -> MCPConnectionState {
        switch registrations[kind] {
        case .none, .notRegistered?:
            return .notRegistered
        case .unknown(let message)?:
            return .needsAttention("Couldn't read the registration: \(SecretRedactor.redact(message))")
        case .registered(let server)?:
            guard let helper else {
                return .needsAttention("The MergeCue MCP helper wasn't found next to the app")
            }
            guard server.matches(helper: helper) else {
                return .needsAttention("Registered with a different command (\(UIFormat.abbreviatedPath(server.command)))")
            }
            let record = verifications[kind]
            let verified = record.flatMap { $0.helperPath == MergeCuePaths.fileSystemPath(helper) ? $0.verifiedAt : nil }
            return .registered(verifiedAt: verified)
        }
    }

    nonisolated static func verificationFile(_ runtime: MergeCueRuntime) -> URL {
        runtime.dataPaths.root.appending(path: "agent-verification.json")
    }

    func recordVerification(_ kind: AgentKind, helper: URL, at date: Date) {
        verifications[kind] = VerificationRecord(helperPath: MergeCuePaths.fileSystemPath(helper), verifiedAt: date)
        VerificationRecord.save(verifications, to: Self.verificationFile(runtime))
    }

    func clearVerification(_ kind: AgentKind) {
        verifications[kind] = nil
        VerificationRecord.save(verifications, to: Self.verificationFile(runtime))
    }

    // MARK: Runtime info

    func runtimeInfo() async -> RuntimeInfo {
        let data = runtime.dataPaths
        let ipc = await runtime.ipcStatus()
        let loginItem: LoginItemState = switch runtime.loginItemStatus() {
        case .enabled: .enabled
        case .disabled: .disabled
        case .requiresApproval: .requiresApproval
        case .unavailable: .unavailable
        }
        return RuntimeInfo(
            dataRoot: MergeCuePaths.fileSystemPath(data.root),
            databasePath: MergeCuePaths.fileSystemPath(data.database),
            worktreesPath: MergeCuePaths.fileSystemPath(data.worktrees),
            logsPath: MergeCuePaths.fileSystemPath(data.logs),
            backupsPath: MergeCuePaths.fileSystemPath(data.root.appending(path: "backups", directoryHint: .isDirectory)),
            socketPath: ipc.socketPath,
            ipcRunning: ipc.isRunning,
            helperPath: runtime.mcpHelperURL.map(MergeCuePaths.fileSystemPath),
            helperHome: runtime.paths.usesCustomHome ? MergeCuePaths.fileSystemPath(runtime.paths.root) : nil,
            loginItem: loginItem
        )
    }
}

/// A successful verification of the helper an agent is registered with (persisted per data root).
nonisolated struct VerificationRecord: Codable, Sendable, Hashable {
    var helperPath: String
    var verifiedAt: Date

    static func load(from url: URL) -> [AgentKind: VerificationRecord] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: VerificationRecord].self, from: data) else { return [:] }
        var result: [AgentKind: VerificationRecord] = [:]
        for (key, value) in decoded {
            if let kind = AgentKind(rawValue: key) { result[kind] = value }
        }
        return result
    }

    static func save(_ records: [AgentKind: VerificationRecord], to url: URL) {
        let encoded = Dictionary(uniqueKeysWithValues: records.map { ($0.key.rawValue, $0.value) })
        do {
            let data = try JSONEncoder().encode(encoded)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: MergeCuePaths.fileSystemPath(url))
        } catch {
            MCLog(category: "ui").error("Could not save the agent verification state: \(error.localizedDescription)")
        }
    }
}
