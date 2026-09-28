import Foundation

/// Creates providers for accounts (wired in `MergeCueRuntime`; Sync/Engine only see this protocol).
public protocol ProviderFactory: Sendable {
    func makeProvider(account: Account, credential: Credential) -> any ReviewProvider
    /// A provider used before an `Account` exists (connection validation via `currentUser()`).
    func makeProbe(instance: ProviderInstance, credential: Credential) -> any ReviewProvider
    /// The adapter's static manifest (token scopes unknown).
    func capabilities(for kind: ProviderKind) -> CapabilityManifest
    /// The manifest for one connected account, taking what is known about its token (`Account.grantedScopes`)
    /// into account. The engine gates previews and writes with this one. Default: `capabilities(for: kind)`.
    func capabilities(for account: Account) -> CapabilityManifest
}

extension ProviderFactory {
    public func capabilities(for account: Account) -> CapabilityManifest {
        capabilities(for: account.kind)
    }
}
