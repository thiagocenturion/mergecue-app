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
            if let until { "Rate limited — retrying at \(until.formatted(date: .omitted, time: .shortened))" } else { "Rate limited" }
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
    /// Change requests whose detail refresh failed (per CR; the account itself may still be `ok`). Terminal ones
    /// (`not found`, `forbidden`) are not retried until their listing changes, a manual Refresh, or the user returns.
    public var changeRequestErrors: [ChangeRequestSyncError]
    /// Provider HTTP requests of this account in the last rolling hour (304 Not Modified not counted); nil = unknown.
    public var requestsLastHour: Int?
    /// The soft hourly request budget of the account's provider; above it Sync slows detail refreshes.
    public var requestBudget: Int?

    public init(
        account: AccountKey,
        state: AccountSyncState = .idle,
        lastAttemptAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        nextRunAt: Date? = nil,
        consecutiveFailures: Int = 0,
        message: String? = nil,
        changeRequestErrors: [ChangeRequestSyncError] = [],
        requestsLastHour: Int? = nil,
        requestBudget: Int? = nil
    ) {
        self.account = account
        self.state = state
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.nextRunAt = nextRunAt
        self.consecutiveFailures = consecutiveFailures
        self.message = message
        self.changeRequestErrors = changeRequestErrors
        self.requestsLastHour = requestsLastHour
        self.requestBudget = requestBudget
    }

    /// Whether the rolling request count reached the soft budget (Sync is slowing detail refreshes down).
    public var isOverRequestBudget: Bool {
        guard let used = requestsLastHour, let budget = requestBudget, budget > 0 else { return false }
        return used >= budget
    }

    private enum CodingKeys: String, CodingKey {
        case account, state, lastAttemptAt, lastSuccessAt, nextRunAt, consecutiveFailures, message
        case changeRequestErrors, requestsLastHour, requestBudget
    }

    /// Tolerates payloads written before the per-CR errors and request accounting existed.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decode(AccountKey.self, forKey: .account)
        state = try c.decode(AccountSyncState.self, forKey: .state)
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSuccessAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        nextRunAt = try c.decodeIfPresent(Date.self, forKey: .nextRunAt)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message)
        changeRequestErrors = try c.decodeIfPresent([ChangeRequestSyncError].self, forKey: .changeRequestErrors) ?? []
        requestsLastHour = try c.decodeIfPresent(Int.self, forKey: .requestsLastHour)
        requestBudget = try c.decodeIfPresent(Int.self, forKey: .requestBudget)
    }
}

/// A change request whose detail refresh (hydration) failed while its account kept syncing.
public struct ChangeRequestSyncError: Codable, Sendable, Hashable, Identifiable {
    public var changeRequest: ChangeRequestKey
    /// Untrusted provider title from the listing (display only).
    public var title: String
    public var repoFullPath: String
    public var webURL: URL?
    /// `ProviderError.code` (`not_found`, `forbidden`, `server_error`, …).
    public var code: String
    /// Redacted, user-facing description.
    public var message: String
    /// `not found` / `forbidden`: not retried automatically until the CR's listing changes, a manual Refresh or the
    /// user returns to MergeCue. Other failures back off (30 s → 5 min → 30 min).
    public var isTerminal: Bool
    public var consecutiveFailures: Int
    public var failedAt: Date
    /// Next automatic retry (nil for terminal failures).
    public var nextRetryAt: Date?

    public init(
        changeRequest: ChangeRequestKey,
        title: String,
        repoFullPath: String,
        webURL: URL? = nil,
        code: String,
        message: String,
        isTerminal: Bool,
        consecutiveFailures: Int = 1,
        failedAt: Date,
        nextRetryAt: Date? = nil
    ) {
        self.changeRequest = changeRequest
        self.title = title
        self.repoFullPath = repoFullPath
        self.webURL = webURL
        self.code = code
        self.message = message
        self.isTerminal = isTerminal
        self.consecutiveFailures = consecutiveFailures
        self.failedAt = failedAt
        self.nextRetryAt = nextRetryAt
    }

    public var id: String { changeRequest.id }

    /// Short reason: "not found", "access denied", "provider error", …
    public var reasonText: String {
        switch code {
        case "not_found": "not found"
        case "forbidden": "access denied"
        case "server_error": "provider error"
        case "decoding_error": "unexpected response"
        case "timeout": "timed out"
        default: code.replacingOccurrences(of: "_", with: " ")
        }
    }
}
