import Foundation
import MergeCueCore
import MergeCueStore

// Accounts: validate + connect (probe `currentUser()`, credential saved to the credential store FIRST, then the
// account row), disconnect (credential + data deleted, audit kept), labels / namespaces / writes toggle, and the
// independent per-account sync statuses reported by Sync.

extension MergeCueEngine {
    /// Every account with its sync status and capability manifest.
    public func accountStates() async throws(EngineError) -> [EngineAccountState] {
        try await uiCall {
            let accounts = try await database.accounts()
            let statuses = await env.sync.statuses()
            return accounts.map { account in
                EngineAccountState(
                    account: account,
                    status: statuses.first { $0.account == account.id } ?? AccountSyncStatus(account: account.id),
                    capabilities: env.providers.capabilities(for: account.kind)
                )
            }
        }
    }

    /// Validates the credential with the provider (`currentUser()`), stores it in the credential store, then
    /// stores the account (remote writes disabled for a new account) and tells Sync to pick it up.
    /// Reconnecting an existing account keeps its label, namespaces and writes setting.
    @discardableResult
    public func connectAccount(_ request: AccountConnectionRequest) async throws(EngineError) -> Account {
        try await uiCall {
            let probe = env.providers.makeProbe(instance: request.instance, credential: request.credential)
            let user: ProviderUser
            do {
                user = try await probe.currentUser()
            } catch {
                guard let providerError = ProviderError.classify(error) else { throw CancellationError() }
                await appendAudit(
                    actor: "user", action: "connect_account", target: "\(request.kind.rawValue):\(request.instance.host)",
                    outcome: .failed, detail: providerError.errorDescription ?? providerError.code
                )
                throw EngineError.provider(providerError)
            }
            let key = AccountKey(instance: request.instance, remoteUserID: user.remoteID)
            let existing = try await database.account(key)
            do {
                try env.credentials.save(request.credential, for: key)
            } catch {
                throw EngineError.failed("The credential could not be saved to the Keychain; the account was not connected.")
            }
            let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = Account(
                id: key,
                instance: request.instance,
                username: user.username,
                displayName: user.displayName,
                avatarURL: user.avatarURL,
                authMethod: request.method,
                grantedScopes: user.grantedScopes,
                writesEnabled: existing?.writesEnabled ?? false,
                label: (label?.isEmpty ?? true) ? existing?.label : label,
                selectedNamespaces: request.selectedNamespaces.isEmpty ? (existing?.selectedNamespaces ?? []) : request.selectedNamespaces,
                connectedAt: existing?.connectedAt ?? now,
                isDemo: env.isDemo
            )
            do {
                try await database.upsertAccount(account)
            } catch {
                if existing == nil { try? env.credentials.delete(for: key) }
                throw error
            }
            await appendAudit(
                actor: "user", action: existing == nil ? "connect_account" : "reconnect_account",
                target: "\(key.kind.rawValue):\(key.host)/\(user.username)", outcome: .succeeded,
                detail: "Scopes: \(user.grantedScopes.joined(separator: " "))"
            )
            await env.sync.accountsDidChange()
            emit(.accounts)
            return account
        }
    }

    /// Deletes the credential and every record the account owns (snapshots, attention, tasks, mappings). The
    /// audit log is kept.
    public func disconnectAccount(_ key: AccountKey) async throws(EngineError) {
        try await uiCall {
            let account = try await requireAccount(key)
            do {
                try env.credentials.delete(for: key)
            } catch {
                throw EngineError.failed("The credential could not be removed from the Keychain; nothing was deleted.")
            }
            // Pending previews may target the account's tasks; they must be requested again.
            previews.removeAll()
            try await database.deleteAccount(key)
            await appendAudit(
                actor: "user", action: "disconnect_account", target: "\(key.kind.rawValue):\(key.host)/\(account.username)",
                outcome: .succeeded, detail: "Credential and account data deleted."
            )
            await env.sync.accountsDidChange()
            for change in [EngineChange.accounts, .attention, .changeRequests, .tasks(nil), .mappings, .syncStatus] {
                emit(change)
            }
        }
    }

    public func setAccountLabel(_ key: AccountKey, label: String?) async throws(EngineError) {
        try await updateAccount(key) {
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.label = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    /// Namespaces (org/group/workspace paths) to sync; empty = all accessible.
    public func setSelectedNamespaces(_ key: AccountKey, _ namespaces: [String]) async throws(EngineError) {
        try await updateAccount(key) { $0.selectedNamespaces = namespaces }
        await env.sync.accountsDidChange()
    }

    /// Turns remote writes (reply, resolve) on or off for an account. Audited.
    public func setWritesEnabled(_ key: AccountKey, _ enabled: Bool) async throws(EngineError) {
        try await updateAccount(key) { $0.writesEnabled = enabled }
        await appendAudit(
            actor: "user", action: enabled ? "enable_writes" : "disable_writes", target: "\(key.kind.rawValue):\(key.host)",
            outcome: .succeeded
        )
    }

    /// Namespaces the account can access (for the namespace picker).
    public func availableNamespaces(_ key: AccountKey) async throws(EngineError) -> [Namespace] {
        try await uiCall { try await provider(for: key).listNamespaces() }
    }

    /// Asks Sync to refresh one account (all when nil).
    public func refresh(account: AccountKey? = nil) async {
        if let account {
            await env.sync.refresh(account: account)
        } else {
            await env.sync.refreshAll()
        }
        try? await database.setSetting(SettingsKey.lastRefreshAt, now)
        emit(.syncStatus)
    }

    private func updateAccount(_ key: AccountKey, _ mutate: (inout Account) -> Void) async throws(EngineError) {
        try await uiCall {
            var account = try await requireAccount(key)
            mutate(&account)
            try await database.upsertAccount(account)
            emit(.accounts)
        }
    }
}
