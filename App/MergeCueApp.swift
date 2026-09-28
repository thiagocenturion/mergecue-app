import AppKit
import MergeCueUI
import os

/// MergeCue app entry point: the AppKit shell from MergeCueUI on top of the backend chosen at launch.
@main
@MainActor
enum MergeCueApp {
    static func main() {
        let options = LaunchOptions(processInfo: .processInfo)
        let delegate = MergeCueAppDelegate(backendFactory: { options.makeBackend() })
        delegate.showsWindowOnLaunch = options.showsWindowOnLaunch
        let app = NSApplication.shared
        app.delegate = delegate
        // `NSApplication.delegate` is weak: keep the delegate alive for the whole run loop.
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Launch configuration read from the environment and arguments (documented in README "Run from Xcode").
///
/// - `MERGECUE_BACKEND=preview|demo|live`: which backend powers the UI. Only `preview` exists today.
/// - `MERGECUE_PREVIEW_VARIANT=standard|authExpired|allCaughtUp|noAccounts`: the preview scenario.
/// - `--show-window`: open the main window at launch (otherwise the app starts in the menu bar only).
struct LaunchOptions: Sendable {
    enum Backend: String, Sendable {
        case preview, demo, live
    }

    /// The backend that was asked for (`MERGECUE_BACKEND`), `nil` when unset or unrecognised.
    let requestedBackend: Backend?
    let previewVariant: PreviewVariant
    let showsWindowOnLaunch: Bool

    private static let logger = Logger(subsystem: "com.thiagocenturion.MergeCue", category: "launch")

    init(processInfo: ProcessInfo) {
        let environment = processInfo.environment
        requestedBackend = environment["MERGECUE_BACKEND"].flatMap { Backend(rawValue: $0.lowercased()) }
        previewVariant = environment["MERGECUE_PREVIEW_VARIANT"].flatMap(PreviewVariant.init(rawValue:)) ?? .standard
        showsWindowOnLaunch = processInfo.arguments.contains("--show-window")
    }

    /// Builds the backend. Every screen of the preview backend carries a "Preview data" badge.
    func makeBackend() -> any AppBackend {
        switch requestedBackend {
        case .demo, .live:
            // TODO: wire `MergeCueRuntime.makeDemo()` / `makeLive()` (ARCHITECTURE §10) once the engine exists, and make
            // `live` the default. Until then the app always runs on synthetic preview data.
            Self.logger.notice(
                "MERGECUE_BACKEND=\(requestedBackend?.rawValue ?? "", privacy: .public) is not available yet; using preview"
            )
        case .preview, nil:
            break
        }
        Self.logger.notice("Starting with the preview backend (\(previewVariant.rawValue, privacy: .public))")
        return MergeCuePreview.makeBackend(variant: previewVariant)
    }
}
