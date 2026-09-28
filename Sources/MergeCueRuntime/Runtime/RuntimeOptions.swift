import Foundation
import MergeCueCore
import MergeCueSync

/// Live (real accounts) or demo (bundled fixtures through the real adapters, always labeled).
public enum RuntimeMode: String, Sendable, Hashable, CaseIterable {
    case live
    case demo
}

/// How IPC peers are authenticated beyond the mandatory uid + per-launch token checks.
public enum PeerValidationPolicy: Sendable, Hashable {
    /// Signed with a Team ID → require the bundled helper's signature (`RuntimeIPC.helperRequirement`);
    /// unsigned / ad-hoc (development) → uid + token only (logged).
    case automatic
    /// uid + token only.
    case disabled
    /// A custom code requirement (tests of the validator itself).
    case requirement(String)
}

/// Tunables and injection points of `MergeCueRuntime`. The defaults are what the app uses; tests inject clocks,
/// notifiers, in-memory credentials and shorter leases.
public struct RuntimeOptions: Sendable {
    public var clock: any MCClock
    /// nil = `SyncConfiguration.default` (live) / `.deterministic` (demo).
    public var syncConfiguration: SyncConfiguration?
    /// Agent lease length (engine default 600 s).
    public var leaseDuration: TimeInterval
    /// Stale-lease monitor period (engine default 30 s).
    public var staleCheckInterval: TimeInterval
    /// nil = `UserNotificationDeliverer` (UserNotifications inside an app bundle, a log line otherwise).
    public var notifier: (any NotificationDelivering)?
    /// nil = Keychain (live) / `InMemoryCredentialStore` (demo).
    public var credentials: (any CredentialStoring)?
    /// Start the private IPC server in `start()` (the MCP helper's only way in).
    public var startsIPCServer: Bool
    public var peerValidation: PeerValidationPolicy
    /// Observe `NWPathMonitor` so accounts refresh when the network comes back (live mode).
    public var monitorsNetwork: Bool
    /// Overrides where `mergecue-mcp` is looked up (tests, custom builds).
    public var mcpHelperOverride: URL?
    /// Extra environment for every git child process (`GitWorkspaceInspector`).
    public var gitEnvironmentOverrides: [String: String]
    /// Folders scanned for checkout mapping suggestions.
    public var mappingSearchRoots: [String]
    public var ids: IDGenerator

    public init(
        clock: any MCClock = SystemClock(),
        syncConfiguration: SyncConfiguration? = nil,
        leaseDuration: TimeInterval = 600,
        staleCheckInterval: TimeInterval = 30,
        notifier: (any NotificationDelivering)? = nil,
        credentials: (any CredentialStoring)? = nil,
        startsIPCServer: Bool = true,
        peerValidation: PeerValidationPolicy = .automatic,
        monitorsNetwork: Bool = true,
        mcpHelperOverride: URL? = nil,
        gitEnvironmentOverrides: [String: String] = [:],
        mappingSearchRoots: [String] = RuntimeOptions.defaultMappingSearchRoots,
        ids: IDGenerator = .system
    ) {
        self.clock = clock
        self.syncConfiguration = syncConfiguration
        self.leaseDuration = leaseDuration
        self.staleCheckInterval = staleCheckInterval
        self.notifier = notifier
        self.credentials = credentials
        self.startsIPCServer = startsIPCServer
        self.peerValidation = peerValidation
        self.monitorsNetwork = monitorsNetwork
        self.mcpHelperOverride = mcpHelperOverride
        self.gitEnvironmentOverrides = gitEnvironmentOverrides
        self.mappingSearchRoots = mappingSearchRoots
        self.ids = ids
    }

    /// `~/Developer`, `~/Projects`, `~/Code`, `~/src`, `~/Documents/GitHub` (only those that exist are scanned).
    public static var defaultMappingSearchRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Developer", "Projects", "Code", "src", "Documents/GitHub"]
            .map { MergeCuePaths.fileSystemPath(home.appending(path: $0, directoryHint: .isDirectory)) }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}

/// Errors of the runtime's own conveniences (engine calls throw `EngineError`).
public enum RuntimeError: Error, Sendable, Equatable, LocalizedError {
    /// The bundled `mergecue-mcp` could not be found.
    case helperNotFound
    /// Another MergeCue instance already serves the IPC socket.
    case alreadyRunning(socketPath: String)
    case ipcFailed(String)
    case notDemo
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .helperNotFound:
            "The MergeCue MCP helper (mergecue-mcp) was not found next to the app. Reinstall MergeCue."
        case .alreadyRunning(let path):
            "Another MergeCue instance is already running (socket \(path)). Quit it first."
        case .ipcFailed(let message):
            "The private agent channel could not start: \(SecretRedactor.redact(message))"
        case .notDemo:
            "This action is only available in demo mode."
        case .failed(let message):
            SecretRedactor.redact(message)
        }
    }
}
