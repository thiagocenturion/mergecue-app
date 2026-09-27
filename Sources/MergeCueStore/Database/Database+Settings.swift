import Foundation
import MergeCueCore

extension MergeCueDatabase {
    // MARK: Settings

    /// The setting stored under `key`, decoded as `T` (nil when unset).
    public func setting<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try connection.queryFirst("SELECT value FROM settings WHERE key = ?", [.text(key)]) {
            try decode(T.self, from: $0, column: 0)
        }
    }

    /// Stores `value` as JSON under `key`; nil removes the setting.
    ///
    /// Settings never hold secrets: a `Credential`, or any value whose JSON contains something `SecretRedactor`
    /// recognizes as a token, is refused with `StoreError.invalidValue` (credentials belong in the Keychain).
    public func setSetting<T: Encodable>(_ key: String, _ value: T?) throws {
        guard let value else {
            try removeSetting(key)
            return
        }
        if value is Credential || value is Credential.Secret {
            throw StoreError.invalidValue("credentials are stored in the Keychain, never in settings")
        }
        let encoded = try json(value)
        if case .text(let text) = encoded, SecretRedactor.containsSecret(text) {
            throw StoreError.invalidValue("setting \(key) looks like it contains a secret; refusing to store it")
        }
        try connection.run(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), encoded]
        )
    }

    /// Removes the setting stored under `key` (no-op when unset).
    public func removeSetting(_ key: String) throws {
        try connection.run("DELETE FROM settings WHERE key = ?", [.text(key)])
    }
}
