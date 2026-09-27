import Foundation

/// Per-account sync state shown in the UI.
public enum AccountSyncState: Codable, Sendable, Hashable {
    case idle
    case syncing
    case ok
    case offline
    /// Credentials rejected; syncing stops until the account changes.
    case authExpired
    case rateLimited(until: Date?)
    case permissionDenied(String)
    case error(String)
    case paused

    /// Stable machine name used as the JSON `type`.
    public var name: String {
        switch self {
        case .idle: "idle"
        case .syncing: "syncing"
        case .ok: "ok"
        case .offline: "offline"
        case .authExpired: "auth_expired"
        case .rateLimited: "rate_limited"
        case .permissionDenied: "permission_denied"
        case .error: "error"
        case .paused: "paused"
        }
    }

    /// Whether the state indicates a problem the user may need to see.
    public var isProblem: Bool {
        switch self {
        case .offline, .authExpired, .rateLimited, .permissionDenied, .error: true
        case .idle, .syncing, .ok, .paused: false
        }
    }

    public var displayText: String {
        switch self {
        case .idle: "Idle"
        case .syncing: "Syncing…"
        case .ok: "Up to date"
        case .offline: "Offline"
        case .authExpired: "Sign-in expired"
        case .rateLimited(let until):
            if let until { "Rate limited until \(until.formatted(date: .omitted, time: .shortened))" } else { "Rate limited" }
        case .permissionDenied(let message): "Permission denied: \(message)"
        case .error(let message): "Error: \(message)"
        case .paused: "Paused"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, until, message
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "idle": self = .idle
        case "syncing": self = .syncing
        case "ok": self = .ok
        case "offline": self = .offline
        case "auth_expired": self = .authExpired
        case "rate_limited": self = .rateLimited(until: try container.decodeIfPresent(Date.self, forKey: .until))
        case "permission_denied": self = .permissionDenied(try container.decode(String.self, forKey: .message))
        case "error": self = .error(try container.decode(String.self, forKey: .message))
        case "paused": self = .paused
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown sync state \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .type)
        switch self {
        case .rateLimited(let until): try container.encodeIfPresent(until, forKey: .until)
        case .permissionDenied(let message), .error(let message): try container.encode(message, forKey: .message)
        default: break
        }
    }
}

extension AccountSyncState {
    /// The shared mapping of a provider failure to an account's sync state: `unauthorized` → `authExpired`,
    /// `forbidden` → `permissionDenied`, `rateLimited` → `rateLimited(until: retryDate(now:))`, `offline`/`timeout`
    /// → `offline`, anything else → `error` (redacted description).
    public init(providerError: ProviderError, now: Date) {
        switch providerError {
        case .unauthorized:
            self = .authExpired
        case .forbidden(let scope, let message):
            let detail = scope.map { "missing scope \($0)" } ?? message
            self = .permissionDenied(SecretRedactor.redact(detail.isEmpty ? "Permission denied" : detail))
        case .rateLimited:
            self = .rateLimited(until: providerError.retryDate(now: now))
        case .offline, .timeout:
            self = .offline
        case .notFound, .server, .decoding, .unsupported, .conflict, .invalidRequest:
            self = .error(providerError.errorDescription ?? providerError.code)
        }
    }
}

/// Sync status of one account.
public struct AccountSyncStatus: Codable, Sendable, Hashable {
    public var account: AccountKey
    public var state: AccountSyncState
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var nextRunAt: Date?
    public var consecutiveFailures: Int
    public var message: String?

    public init(
        account: AccountKey,
        state: AccountSyncState = .idle,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        nextRunAt: Date? = nil,
        consecutiveFailures: Int = 0,
        message: String? = nil
    ) {
        self.account = account
        self.state = state
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.nextRunAt = nextRunAt
        self.consecutiveFailures = consecutiveFailures
        self.message = message
    }
}
