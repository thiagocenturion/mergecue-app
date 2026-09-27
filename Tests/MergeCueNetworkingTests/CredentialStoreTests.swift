import Foundation
import MergeCueCore
import Security
import Testing
@testable import MergeCueNetworking

@Suite("Credential stores")
struct CredentialStoreTests {
    private let github = AccountKey(kind: .github, host: "github.com", remoteUserID: "123")
    private let gitlab = AccountKey(kind: .gitlab, host: "gitlab.com", remoteUserID: "123")

    // MARK: In-memory

    @Test func inMemoryRoundTripPerAccount() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.load(for: github) == nil)
        try store.save(.bearer("gh-token"), for: github)
        try store.save(.basic(username: "u", password: "p"), for: gitlab)
        #expect(try store.load(for: github) == .bearer("gh-token"))
        #expect(try store.load(for: gitlab) == .basic(username: "u", password: "p"))
        #expect(store.accounts == [github, gitlab].sorted())

        try store.save(.bearer("rotated"), for: github)
        #expect(try store.load(for: github) == .bearer("rotated"))

        try store.delete(for: github)
        try store.delete(for: github)  // deleting a missing item is not an error
        #expect(try store.load(for: github) == nil)
        #expect(try store.load(for: gitlab) != nil)
    }

    @Test func inMemoryFailureSimulation() throws {
        let store = InMemoryCredentialStore([github: .bearer("x")])
        store.simulateFailure(.unavailable("locked"))
        #expect(throws: CredentialStoreError.unavailable("locked")) { try store.load(for: github) }
        #expect(throws: CredentialStoreError.self) { try store.save(.bearer("y"), for: github) }
        #expect(throws: CredentialStoreError.self) { try store.delete(for: github) }
        store.simulateFailure(nil)
        #expect(try store.load(for: github) == .bearer("x"))
    }

    @Test func inMemoryIsSafeUnderConcurrency() async throws {
        let store = InMemoryCredentialStore()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let key = AccountKey(kind: .github, host: "github.com", remoteUserID: "\(index)")
                    try? store.save(.bearer("t\(index)"), for: key)
                    _ = try? store.load(for: key)
                }
            }
        }
        #expect(store.accounts.count == 100)
    }

    // MARK: Keychain (query shape only — the real Keychain is not touched)

    @Test func keychainQueryShape() throws {
        let store = KeychainCredentialStore()
        #expect(store.service == "dev.mergecue.credentials")
        let query = store.query(for: github, dataProtection: true)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "dev.mergecue.credentials")
        #expect(query[kSecAttrAccount as String] as? String == github.id)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)

        let legacy = store.query(for: github, dataProtection: false)
        #expect(legacy[kSecUseDataProtectionKeychain as String] == nil)

        let attributes = store.attributes(for: github, data: Data("{}".utf8))
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecValueData as String] as? Data == Data("{}".utf8))
    }

    @Test func keychainErrorsAreTyped() {
        #expect(KeychainCredentialStore.error(for: errSecInteractionNotAllowed) == .unavailable("The keychain is locked."))
        guard case .storeFailure(let status, let message) = KeychainCredentialStore.error(for: errSecAuthFailed) else {
            Issue.record("expected storeFailure")
            return
        }
        #expect(status == errSecAuthFailed)
        #expect(!message.isEmpty)
    }

    @Test func keychainPayloadIsTheCredentialJSON() throws {
        let credential = Credential.bearer("tkn", refreshToken: "r", expiresAt: NetFixture.date)
        let data = try MergeCueCoding.storageEncoder().encode(credential)
        #expect(try MergeCueCoding.storageDecoder().decode(Credential.self, from: data) == credential)
    }

    /// Opt-in round trip against the real Keychain (separate service). Run with `MERGECUE_KEYCHAIN_TESTS=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MERGECUE_KEYCHAIN_TESTS"] == "1"))
    func realKeychainRoundTrip() throws {
        let store = KeychainCredentialStore(service: "dev.mergecue.credentials.tests")
        let account = AccountKey(kind: .github, host: "github.com", remoteUserID: "keychain-test-\(UUID().uuidString)")
        defer { try? store.delete(for: account) }
        #expect(try store.load(for: account) == nil)
        try store.save(.bearer("first"), for: account)
        #expect(try store.load(for: account) == .bearer("first"))
        try store.save(.bearer("second"), for: account)
        #expect(try store.load(for: account) == .bearer("second"))
        try store.delete(for: account)
        try store.delete(for: account)
        #expect(try store.load(for: account) == nil)
    }
}
