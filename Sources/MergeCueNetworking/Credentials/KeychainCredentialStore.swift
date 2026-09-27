import Foundation
import MergeCueCore
import Security

/// `CredentialStoring` backed by the macOS Keychain: one generic-password item per account, service
/// `dev.mergecue.credentials`, account attribute = `AccountKey.id`, JSON payload, accessible
/// `AfterFirstUnlockThisDeviceOnly`, never synchronized.
///
/// Items go to the data protection keychain when the process is entitled for it; otherwise (unsigned/dev builds
/// get `errSecMissingEntitlement`) the file-based login keychain is used. Reads and deletes consult both, so an
/// item written by either build is found and fully removed.
///
/// - Important: Automated tests must not use this type (use `InMemoryCredentialStore`); the opt-in keychain tests
///   run only with `MERGECUE_KEYCHAIN_TESTS=1`.
public final class KeychainCredentialStore: CredentialStoring {
    public static let defaultService = "dev.mergecue.credentials"

    public let service: String
    public let accessGroup: String?
    public let prefersDataProtectionKeychain: Bool

    /// - Parameters:
    ///   - service: `kSecAttrService` (tests use a separate service).
    ///   - accessGroup: Optional keychain access group (data protection keychain only).
    ///   - prefersDataProtectionKeychain: Try the data protection keychain first (default true).
    public init(service: String = KeychainCredentialStore.defaultService, accessGroup: String? = nil, prefersDataProtectionKeychain: Bool = true) {
        self.service = service
        self.accessGroup = accessGroup
        self.prefersDataProtectionKeychain = prefersDataProtectionKeychain
    }

    // MARK: CredentialStoring

    public func save(_ credential: Credential, for account: AccountKey) throws {
        let data: Data
        do {
            data = try MergeCueCoding.storageEncoder().encode(credential)
        } catch {
            throw CredentialStoreError.storeFailure(status: errSecParam, message: "The credential could not be encoded.")
        }
        if prefersDataProtectionKeychain {
            let status = upsert(data, for: account, dataProtection: true)
            // A stale copy an unentitled build left in the file-based keychain is shadowed (reads prefer the data
            // protection keychain) and removed by `delete`.
            if status == errSecSuccess { return }
            guard status == errSecMissingEntitlement else { throw Self.error(for: status) }
        }
        let status = upsert(data, for: account, dataProtection: false)
        guard status == errSecSuccess else { throw Self.error(for: status) }
    }

    public func load(for account: AccountKey) throws -> Credential? {
        let keychains = prefersDataProtectionKeychain ? [true, false] : [false]
        for dataProtection in keychains {
            var lookup = query(for: account, dataProtection: dataProtection)
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else { throw CredentialStoreError.corruptedPayload }
                do {
                    return try MergeCueCoding.storageDecoder().decode(Credential.self, from: data)
                } catch {
                    throw CredentialStoreError.corruptedPayload
                }
            case errSecItemNotFound:
                continue
            case errSecMissingEntitlement where dataProtection:
                continue
            default:
                throw Self.error(for: status)
            }
        }
        return nil
    }

    public func delete(for account: AccountKey) throws {
        let keychains = prefersDataProtectionKeychain ? [true, false] : [false]
        for dataProtection in keychains {
            let status = SecItemDelete(query(for: account, dataProtection: dataProtection) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound:
                continue
            case errSecMissingEntitlement where dataProtection:
                continue
            default:
                throw Self.error(for: status)
            }
        }
    }

    // MARK: Queries

    /// The identifying attributes of `account`'s item.
    func query(for account: AccountKey, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.id,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            if let accessGroup {
                query[kSecAttrAccessGroup as String] = accessGroup
            }
        }
        return query
    }

    /// Attributes written on add/update.
    func attributes(for account: AccountKey, data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    /// Update-or-add.
    private func upsert(_ data: Data, for account: AccountKey, dataProtection: Bool) -> OSStatus {
        let identity = query(for: account, dataProtection: dataProtection)
        let changes = attributes(for: account, data: data)
        let status = SecItemUpdate(identity as CFDictionary, changes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var item = identity.merging(changes) { _, new in new }
        item[kSecAttrSynchronizable as String] = false
        item[kSecAttrLabel as String] = "MergeCue — \(account.kind.rawValue) (\(account.host))"
        item[kSecAttrDescription as String] = "MergeCue provider credential"
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func error(for status: OSStatus) -> CredentialStoreError {
        if status == errSecInteractionNotAllowed {
            return .unavailable("The keychain is locked.")
        }
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return .storeFailure(status: status, message: message)
    }
}
