import Foundation

/// A provider secret.
///
/// - Important: `Codable` exists **only** for the Keychain payload (`CredentialStoring`). A credential must never
///   be written to SQLite, logs, MCP/IPC output, crash reports or screenshots. `description`,
///   `debugDescription` and the reflection mirror (`dump`, `Mirror`) are always redacted.
public struct Credential: Sendable, Codable, Hashable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// The secret material.
    public enum Secret: Sendable, Codable, Hashable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable
    {
        /// `Authorization: Bearer <token>`.
        case bearer(String)
        /// `Authorization: Basic base64(username:password)` (e.g. Atlassian email + API token).
        case basic(username: String, password: String)

        public var description: String { "<redacted>" }
        public var debugDescription: String { "<redacted>" }
        public var customMirror: Mirror { Mirror(self, children: [Mirror.Child](), displayStyle: .enum) }

        private enum CodingKeys: String, CodingKey {
            case type, token, username, password
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "bearer":
                self = .bearer(try container.decode(String.self, forKey: .token))
            case "basic":
                self = .basic(
                    username: try container.decode(String.self, forKey: .username),
                    password: try container.decode(String.self, forKey: .password)
                )
            case let other:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container, debugDescription: "Unknown credential type \(other)"
                )
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .bearer(let token):
                try container.encode("bearer", forKey: .type)
                try container.encode(token, forKey: .token)
            case .basic(let username, let password):
                try container.encode("basic", forKey: .type)
                try container.encode(username, forKey: .username)
                try container.encode(password, forKey: .password)
            }
        }
    }

    public var secret: Secret
    public var refreshToken: String?
    public var expiresAt: Date?

    public init(secret: Secret, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.secret = secret
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Bearer token credential.
    public static func bearer(_ token: String, refreshToken: String? = nil, expiresAt: Date? = nil) -> Credential {
        Credential(secret: .bearer(token), refreshToken: refreshToken, expiresAt: expiresAt)
    }

    /// HTTP Basic credential.
    public static func basic(username: String, password: String) -> Credential {
        Credential(secret: .basic(username: username, password: password))
    }

    /// Value for the HTTP `Authorization` header. Never log it.
    public func authorizationHeaderValue() -> String {
        switch secret {
        case .bearer(let token):
            return "Bearer \(token)"
        case .basic(let username, let password):
            return "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
        }
    }

    /// "Bearer" or "Basic" — safe to display.
    public var schemeName: String {
        switch secret {
        case .bearer: "Bearer"
        case .basic: "Basic"
        }
    }

    /// Whether the credential expires within `leeway` seconds of `date`. Credentials without expiry never expire.
    public func isExpired(at date: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(date) <= leeway
    }

    public var description: String { "Credential(<redacted>)" }
    public var debugDescription: String { "Credential(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [Mirror.Child](), displayStyle: .struct) }

    private enum CodingKeys: String, CodingKey {
        case secret
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }
}

/// Secure per-account credential storage (Keychain in production, in-memory in tests).
public protocol CredentialStoring: Sendable {
    func save(_ credential: Credential, for account: AccountKey) throws
    func load(for account: AccountKey) throws -> Credential?
    func delete(for account: AccountKey) throws
}

/// Errors a `CredentialStoring` implementation may throw. Messages never contain secret material.
public enum CredentialStoreError: Error, Sendable, Equatable, LocalizedError {
    /// Underlying store failure (e.g. Keychain `OSStatus`).
    case storeFailure(status: Int32, message: String)
    /// Stored payload could not be decoded.
    case corruptedPayload
    /// The store is locked or unavailable (e.g. before first unlock).
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .storeFailure(let status, let message): "Credential store error \(status): \(message)"
        case .corruptedPayload: "The stored credential could not be read."
        case .unavailable(let message): "The credential store is unavailable: \(message)"
        }
    }
}
