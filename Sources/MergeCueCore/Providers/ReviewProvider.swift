import Foundation

/// Version of the `ReviewProvider` protocol contract.
public enum ReviewProviderContract {
    public static let currentVersion = 1
}

/// Provider-neutral access to a review platform. One value serves one account (or an unauthenticated probe).
///
/// Adapters throw `ProviderError.unsupported` for capabilities they cannot provide — they never silently drop
/// data — and record `Person.remoteID` faithfully so Sync can decide "is it me".
public protocol ReviewProvider: Sendable {
    /// `ReviewProvider` protocol version implemented (currently 1).
    static var protocolVersion: Int { get }
    var instance: ProviderInstance { get }
    var capabilities: CapabilityManifest { get }

    func currentUser() async throws -> ProviderUser
    func listNamespaces() async throws -> [Namespace]
    func listRepositories(namespace: Namespace?) async throws -> [Repository]
    func listChangeRequests(_ query: ChangeRequestQuery) async throws -> ChangeRequestPage
    func hydrate(_ summary: ChangeRequestSummary) async throws -> ChangeRequestSnapshot
    /// Fresh head state right before a write.
    func headInfo(for changeRequest: ChangeRequestKey) async throws -> HeadInfo
    /// Fresh thread state right before a write.
    func thread(_ key: ThreadKey) async throws -> ReviewThread
    func failureLog(for check: CheckRun, maxBytes: Int) async throws -> LogExcerpt
    func diff(for changeRequest: ChangeRequestKey, maxBytes: Int) async throws -> DiffPayload
    func createReply(to thread: ThreadKey, body: String) async throws -> ReviewComment
    func resolveThread(_ thread: ThreadKey, resolved: Bool) async throws
    func requestChanges(on changeRequest: ChangeRequestKey, body: String) async throws
    func merge(_ changeRequest: ChangeRequestKey, expectedHeadSHA: String) async throws
    func fetchHeadSpec(for snapshot: ChangeRequestSnapshot) -> FetchHeadSpec?
    func deepLink(to target: DeepLinkTarget) -> URL?
}

extension ReviewProvider {
    /// Throws `ProviderError.unsupported` unless the manifest marks `capability` usable.
    public func requireCapability(_ capability: Capability) throws {
        switch capabilities.support(for: capability) {
        case .supported, .partial:
            return
        case .requiresWriteAccess(let scope):
            throw ProviderError.forbidden(missingScope: scope, message: "\(capability.displayName) needs write access.")
        case .unsupported(let reason):
            throw ProviderError.unsupported(capability, reason: reason)
        }
    }
}
