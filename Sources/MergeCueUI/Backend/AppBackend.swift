import Foundation
import MergeCueCore

/// Where the data shown by the UI comes from. Anything other than `.live` shows a persistent, clearly visible
/// badge so synthetic data is never mistaken for a live integration.
public nonisolated enum BackendMode: String, Sendable, Hashable, CaseIterable {
    /// Real accounts, real sync, real agents.
    case live
    /// The real engine and adapters over fixture HTTP routes (`MergeCueRuntime.makeDemo()`).
    case demo
    /// In-memory synthetic data for UI review (`PreviewBackend`). Nothing leaves the process.
    case preview

    public var isLive: Bool { self == .live }

    /// Badge text for non-live modes; nil when live.
    public var badgeText: String? {
        switch self {
        case .live: nil
        case .demo: "Demo data"
        case .preview: "Preview data"
        }
    }

    /// One sentence explaining the badge (tooltips, About, VoiceOver).
    public var explanation: String {
        switch self {
        case .live: "Connected to your accounts."
        case .demo: "Demo data from bundled fixtures. Nothing shown here comes from your accounts."
        case .preview: "Synthetic preview data. No accounts, agents or networks are contacted."
        }
    }
}

/// The UI port: everything the views need, independent of whether the engine, a demo runtime or the in-memory
/// preview answers. Views depend on this protocol only (through `AppModel`), so wiring the live engine later does
/// not require rewriting views.
public nonisolated protocol AppBackend: AnyObject, Sendable {
    /// Drives the persistent non-live badge.
    var mode: BackendMode { get }
    /// A complete, consistent snapshot of what the UI shows.
    func loadState() async -> AppState
    /// Yields whenever `loadState()` would return something different. Each call returns an independent stream.
    func changes() -> AsyncStream<Void>
    /// Refreshes every account (same as `perform(.refresh(account: nil))`).
    func refresh() async
    /// Executes one user action. Throws `AppBackendError` (or any error; the UI shows its description).
    func perform(_ command: AppCommand) async throws -> AppCommandResult
}

/// Errors a backend reports for a user action. Messages are user-facing and never contain credentials.
public nonisolated enum AppBackendError: Error, Sendable, Equatable, LocalizedError {
    case notFound(String)
    case invalidTransition(String)
    /// Remote writes are off for the account (Settings › Accounts).
    case writesDisabled(account: String)
    /// The owner's write policy hides this action (request changes, commit and push, merge).
    case disabledByPolicy(RemoteActionKind)
    case unsupported(String)
    /// The preview no longer matches the current state (head moved, task changed); request a new one.
    case previewExpired
    case invalidInput(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): "\(what) no longer exists."
        case .invalidTransition(let message): message
        case .writesDisabled(let account):
            "Remote writes are turned off for \(account). Turn them on in Settings › Accounts to post or resolve."
        case .disabledByPolicy(let action): "\(action.displayName) is disabled by your write policy."
        case .unsupported(let message): message
        case .previewExpired: "The preview is out of date. Request a new preview and review it again."
        case .invalidInput(let message): message
        case .failed(let message): SecretRedactor.redact(message)
        }
    }
}
