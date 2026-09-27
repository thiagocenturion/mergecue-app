import Foundation

/// Creates providers for accounts (wired in `MergeCueRuntime`; Sync/Engine only see this protocol).
public protocol ProviderFactory: Sendable {
    func makeProvider(account: Account, credential: Credential) -> any ReviewProvider
    /// A provider used before an `Account` exists (connection validation via `currentUser()`).
    func makeProbe(instance: ProviderInstance, credential: Credential) -> any ReviewProvider
    func capabilities(for kind: ProviderKind) -> CapabilityManifest
}
