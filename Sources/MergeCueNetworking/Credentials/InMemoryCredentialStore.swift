import Foundation
import MergeCueCore
import Synchronization

/// Thread-safe in-memory `CredentialStoring` for tests, previews and demo mode. Never touches the Keychain.
public final class InMemoryCredentialStore: CredentialStoring {
    private struct State {
        var credentials: [AccountKey: Credential] = [:]
        var failure: CredentialStoreError?
    }

    private let state: Mutex<State>

    public init(_ credentials: [AccountKey: Credential] = [:]) {
        state = Mutex(State(credentials: credentials))
    }

    public func save(_ credential: Credential, for account: AccountKey) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.credentials[account] = credential
        }
    }

    public func load(for account: AccountKey) throws -> Credential? {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            return state.credentials[account]
        }
    }

    public func delete(for account: AccountKey) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.credentials[account] = nil
        }
    }

    /// Accounts that currently have a stored credential, sorted.
    public var accounts: [AccountKey] {
        state.withLock { $0.credentials.keys.sorted() }
    }

    /// Makes every subsequent operation throw `failure` (nil restores normal behaviour), e.g. to simulate a locked
    /// Keychain.
    public func simulateFailure(_ failure: CredentialStoreError?) {
        state.withLock { $0.failure = failure }
    }
}
