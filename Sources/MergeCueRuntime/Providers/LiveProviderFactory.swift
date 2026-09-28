import BitbucketCloudAdapter
import Foundation
import GitHubAdapter
import GitLabAdapter
import MergeCueCore
import MergeCueNetworking

/// Creates the real adapters (`GitHubProvider`, `GitLabProvider`, `BitbucketCloudProvider`) for accounts.
///
/// Live mode uses one shared `URLSessionTransport`; demo mode injects the scenario's fixture transports through
/// `transport` — the adapters are the same either way (DECISIONS D10). Providers share the process-wide link
/// registries (`GitHubLinkRegistry.shared`, the GitLab link cache, `BitbucketRepositoryDirectory.shared`), which
/// `MergeCueRuntime` preloads from stored snapshots at start.
public struct LiveProviderFactory: ProviderFactory {
    /// The transport for a provider instance.
    public typealias TransportProvider = @Sendable (ProviderInstance) -> any HTTPTransport

    public let clock: any MCClock
    private let transport: TransportProvider

    /// - Parameters:
    ///   - transport: nil = one shared `URLSessionTransport` (with a MergeCue user agent) for every provider.
    public init(clock: any MCClock = SystemClock(), appVersion: String? = nil, transport: TransportProvider? = nil) {
        self.clock = clock
        if let transport {
            self.transport = transport
        } else {
            let shared = URLSessionTransport(userAgent: URLSessionTransport.userAgent(forVersion: appVersion))
            self.transport = { _ in shared }
        }
    }

    public func makeProvider(account: Account, credential: Credential) -> any ReviewProvider {
        make(instance: account.instance, credential: credential, grantedScopes: account.grantedScopes)
    }

    public func makeProbe(instance: ProviderInstance, credential: Credential) -> any ReviewProvider {
        make(instance: instance, credential: credential, grantedScopes: nil)
    }

    public func capabilities(for kind: ProviderKind) -> CapabilityManifest {
        WriteCapabilityPolicy.staticManifest(for: kind)
    }

    public func capabilities(for account: Account) -> CapabilityManifest {
        WriteCapabilityPolicy.manifest(for: account)
    }

    private func make(instance: ProviderInstance, credential: Credential, grantedScopes: [String]?) -> any ReviewProvider {
        let transport = transport(instance)
        switch instance.kind {
        case .github:
            return GitHubProvider(
                instance: instance, credential: credential, transport: transport, clock: clock, grantedScopes: grantedScopes
            )
        case .gitlab:
            return GitLabProvider(instance: instance, credential: credential, transport: transport, clock: clock)
        case .bitbucketCloud:
            return BitbucketCloudProvider(instance: instance, credential: credential, transport: transport, clock: clock)
        }
    }
}

/// One write-capability semantic for the three adapters.
///
/// Whether a write may happen at all is decided by the engine (`Account.writesEnabled` + the owner's
/// `RemoteWritePolicy` + an approved preview). This policy only answers "can this account's token write?", from
/// what is known about the token:
/// - **GitHub** — classic scopes from `X-OAuth-Scopes`: `repo` → supported, `public_repo` → partial (public repos
///   only), none reported (fine-grained / app token: GitHub does not say) → partial, other scopes only →
///   `requiresWriteAccess(repo)`.
/// - **GitLab** — PAT scopes from `/personal_access_tokens/self`: unknown (OAuth, older instance) → the adapter's
///   manifest; known without `api` → `requiresWriteAccess(api)`.
/// - **Bitbucket Cloud** — scopes are usually not reported → the adapter's manifest; when reported without a
///   pull-request write scope → `requiresWriteAccess(write:pullrequest:bitbucket)`.
/// The static per-kind manifest (`GitHubProvider.capabilityManifest` marks writes `requiresWriteAccess`) is never
/// used to gate an account's writes, so a GitHub account whose token has `repo` is not rejected.
public enum WriteCapabilityPolicy {
    public static func staticManifest(for kind: ProviderKind) -> CapabilityManifest {
        switch kind {
        case .github: GitHubProvider.capabilityManifest
        case .gitlab: GitLabProvider.capabilityManifest
        case .bitbucketCloud: BitbucketCloudProvider.capabilityManifest
        }
    }

    public static func manifest(for account: Account) -> CapabilityManifest {
        let scopes = Set(account.grantedScopes.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        switch account.kind {
        case .github:
            return GitHubProvider.capabilities(grantedScopes: account.grantedScopes)
        case .gitlab:
            let manifest = GitLabProvider.capabilityManifest
            guard !scopes.isEmpty, !scopes.contains("api") else { return manifest }
            return requiringWriteAccess(manifest, scope: "api")
        case .bitbucketCloud:
            let manifest = BitbucketCloudProvider.capabilityManifest
            let writeScopes: Set<String> = ["write:pullrequest:bitbucket", "pullrequest:write", "pullrequest"]
            guard !scopes.isEmpty, scopes.isDisjoint(with: writeScopes) else { return manifest }
            return requiringWriteAccess(manifest, scope: "write:pullrequest:bitbucket")
        }
    }

    private static func requiringWriteAccess(_ manifest: CapabilityManifest, scope: String) -> CapabilityManifest {
        var manifest = manifest
        for capability in Capability.allCases where capability.isWrite && manifest.support(for: capability).isUsable {
            manifest.entries[capability] = .requiresWriteAccess(scope: scope)
        }
        return manifest
    }
}
