import AppKit
import MergeCueRuntime
import MergeCueUI
import os

/// MergeCue app entry point: the AppKit shell from MergeCueUI on top of the backend chosen at launch.
@main
@MainActor
enum MergeCueApp {
    static func main() {
        let options = LaunchOptions(processInfo: .processInfo, defaults: .standard)
        let delegate = MergeCueAppDelegate(asyncBackendFactory: { try await options.makeBackend() })
        delegate.showsWindowOnLaunch = options.showsWindowOnLaunch
        let app = NSApplication.shared
        app.delegate = delegate
        // `NSApplication.delegate` is weak: keep the delegate alive for the whole run loop.
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Launch configuration (documented in README "Run").
///
/// Mode, first match wins:
/// 1. `--live`, `--demo` or `--preview` launch argument;
/// 2. `MERGECUE_BACKEND=live|demo|preview`;
/// 3. the Settings › General › Demo mode choice (`LaunchPreferences.backendModeKey`);
/// 4. live.
///
/// - `live`: real accounts (`MergeCueRuntime.makeLive`), Keychain, real HTTP, the IPC server for `mergecue-mcp`.
/// - `demo`: the real engine and adapters over bundled fixtures (`makeDemo`), data in `<root>/demo`, badged "Demo data".
/// - `preview`: in-memory synthetic data for UI review (`MERGECUE_PREVIEW_VARIANT=standard|authExpired|allCaughtUp|noAccounts`).
/// - `--show-window`: open the main window at launch (otherwise the app starts in the menu bar only).
struct LaunchOptions: Sendable {
    enum Backend: String, Sendable {
        case preview, demo, live
    }

    let backend: Backend
    /// Where the mode came from (logged).
    let source: String
    let previewVariant: PreviewVariant
    let showsWindowOnLaunch: Bool

    private static let logger = Logger(subsystem: "com.thiagocenturion.MergeCue", category: "launch")

    init(processInfo: ProcessInfo, defaults: UserDefaults) {
        let arguments = processInfo.arguments
        let environment = processInfo.environment
        if let fromArgument = [Backend.live, .demo, .preview].first(where: { arguments.contains("--\($0.rawValue)") }) {
            (backend, source) = (fromArgument, "launch argument")
        } else if let fromEnvironment = environment["MERGECUE_BACKEND"].flatMap({ Backend(rawValue: $0.lowercased()) }) {
            (backend, source) = (fromEnvironment, "MERGECUE_BACKEND")
        } else if let saved = defaults.string(forKey: LaunchPreferences.backendModeKey).flatMap(Backend.init(rawValue:)), saved != .preview {
            (backend, source) = (saved, "Settings › General")
        } else {
            (backend, source) = (.live, "default")
        }
        previewVariant = environment["MERGECUE_PREVIEW_VARIANT"].flatMap(PreviewVariant.init(rawValue:)) ?? .standard
        showsWindowOnLaunch = arguments.contains("--show-window")
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
    }

    /// Builds (and starts) the backend. Demo and preview data are always badged in the UI.
    @MainActor
    func makeBackend() async throws -> any AppBackend {
        Self.logger.notice("Starting MergeCue in \(backend.rawValue, privacy: .public) mode (from \(source, privacy: .public))")
        switch backend {
        case .preview:
            return MergeCuePreview.makeBackend(variant: previewVariant)
        case .demo:
            return try await EngineBackend.launch(mode: .demo, appVersion: Self.appVersion)
        case .live:
            return try await EngineBackend.launch(mode: .live, appVersion: Self.appVersion)
        }
    }
}
