import Foundation
import MergeCueCore
import MergeCueStore
import os
@testable import MergeCueSync

/// Mutable, thread-safe fake of one account's remote state.
final class FakeRemote: Sendable {
    struct State: Sendable {
        /// Every CR the remote knows (any state). Listings return the open ones with the scope's involvement.
        var changeRequests: [ChangeRequestKey: ChangeRequestSnapshot] = [:]
        var order: [ChangeRequestKey] = []
        var listError: ProviderError?
        var hydrateErrors: [ChangeRequestKey: ProviderError] = [:]
        var listCalls = 0
        var hydrateCalls: [ChangeRequestKey: Int] = [:]
        var inFlightHydrations = 0
        var maxInFlightHydrations = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func put(_ snapshot: ChangeRequestSnapshot) {
        state.withLock {
            if $0.changeRequests[snapshot.key] == nil { $0.order.append(snapshot.key) }
            $0.changeRequests[snapshot.key] = snapshot
        }
    }

    func update(_ key: ChangeRequestKey, _ change: @Sendable (inout ChangeRequestSnapshot) -> Void) {
        state.withLock {
            guard var snapshot = $0.changeRequests[key] else { return }
            change(&snapshot)
            $0.changeRequests[key] = snapshot
        }
    }

    func delete(_ key: ChangeRequestKey) {
        state.withLock {
            $0.changeRequests[key] = nil
            $0.order.removeAll { $0 == key }
        }
    }

    func snapshot(_ key: ChangeRequestKey) -> ChangeRequestSnapshot? { state.withLock { $0.changeRequests[key] } }

    var listError: ProviderError? {
        get { state.withLock { $0.listError } }
        set { state.withLock { $0.listError = newValue } }
    }

    func setHydrateError(_ error: ProviderError?, for key: ChangeRequestKey) {
        state.withLock { $0.hydrateErrors[key] = error }
    }

    var listCalls: Int { state.withLock { $0.listCalls } }
    var maxInFlightHydrations: Int { state.withLock { $0.maxInFlightHydrations } }
    func hydrateCalls(_ key: ChangeRequestKey) -> Int { state.withLock { $0.hydrateCalls[key] ?? 0 } }
    var totalHydrateCalls: Int { state.withLock { $0.hydrateCalls.values.reduce(0, +) } }

    fileprivate func list(_ query: ChangeRequestQuery) throws -> ChangeRequestPage {
        try state.withLock { state in
            state.listCalls += 1
            if let error = state.listError { throw error }
            let items = state.order.compactMap { state.changeRequests[$0] }
                .filter { $0.summary.state == .open && $0.summary.involvement.contains(query.scope.involvement) }
                .map(\.summary)
            return ChangeRequestPage(items: items)
        }
    }

    fileprivate func beginHydrate(_ key: ChangeRequestKey) throws -> ChangeRequestSnapshot {
        try state.withLock { state in
            state.hydrateCalls[key, default: 0] += 1
            if let error = state.hydrateErrors[key] ?? state.listError { throw error }
            guard let snapshot = state.changeRequests[key] else { throw ProviderError.notFound(key.shortID) }
            state.inFlightHydrations += 1
            state.maxInFlightHydrations = max(state.maxInFlightHydrations, state.inFlightHydrations)
            return snapshot
        }
    }

    fileprivate func endHydrate() {
        state.withLock { $0.inFlightHydrations -= 1 }
    }
}

/// `ReviewProvider` over a `FakeRemote` (reads only; writes are unsupported).
struct FakeProvider: ReviewProvider {
    static let protocolVersion = ReviewProviderContract.currentVersion
    let instance: ProviderInstance
    let remote: FakeRemote
    var capabilities: CapabilityManifest { CapabilityManifest(provider: instance.kind, entries: [:]) }

    func currentUser() async throws -> ProviderUser { ProviderUser(remoteID: SyncFixture.me, username: "mona-dev") }
    func listNamespaces() async throws -> [Namespace] { [] }
    func listRepositories(namespace: Namespace?) async throws -> [Repository] { [] }
    func listChangeRequests(_ query: ChangeRequestQuery) async throws -> ChangeRequestPage {
        await Task.yield()
        return try remote.list(query)
    }
    func hydrate(_ summary: ChangeRequestSummary) async throws -> ChangeRequestSnapshot {
        let snapshot = try remote.beginHydrate(summary.key)
        defer { remote.endHydrate() }
        // Yield a few times so concurrent hydrations overlap (bounded-concurrency test).
        for _ in 0..<3 { await Task.yield() }
        return snapshot
    }
    func headInfo(for changeRequest: ChangeRequestKey) async throws -> HeadInfo { throw ProviderError.notFound("head") }
    func thread(_ key: ThreadKey) async throws -> ReviewThread { throw ProviderError.notFound("thread") }
    func failureLog(for check: CheckRun, maxBytes: Int) async throws -> LogExcerpt { throw ProviderError.notFound("log") }
    func diff(for changeRequest: ChangeRequestKey, maxBytes: Int) async throws -> DiffPayload { throw ProviderError.notFound("diff") }
    func createReply(to thread: ThreadKey, body: String) async throws -> ReviewComment {
        throw ProviderError.unsupported(.createReply, reason: "fake")
    }
    func resolveThread(_ thread: ThreadKey, resolved: Bool) async throws { throw ProviderError.unsupported(.resolveThread, reason: "fake") }
    func requestChanges(on changeRequest: ChangeRequestKey, body: String) async throws {
        throw ProviderError.unsupported(.requestChanges, reason: "fake")
    }
    func merge(_ changeRequest: ChangeRequestKey, expectedHeadSHA: String) async throws { throw ProviderError.unsupported(.merge, reason: "fake") }
    func fetchHeadSpec(for snapshot: ChangeRequestSnapshot) -> FetchHeadSpec? { nil }
    func deepLink(to target: DeepLinkTarget) -> URL? { nil }
}

/// Maps accounts to fake remotes; records which credentials were used.
final class FakeProviderFactory: ProviderFactory {
    private let remotes: OSAllocatedUnfairLock<[AccountKey: FakeRemote]>
    private let made = OSAllocatedUnfairLock(initialState: [AccountKey: Int]())

    init(_ remotes: [AccountKey: FakeRemote]) {
        self.remotes = OSAllocatedUnfairLock(initialState: remotes)
    }

    func remote(_ account: AccountKey) -> FakeRemote {
        remotes.withLock { remotes in
            if let remote = remotes[account] { return remote }
            let remote = FakeRemote()
            remotes[account] = remote
            return remote
        }
    }

    func providersMade(for account: AccountKey) -> Int { made.withLock { $0[account] ?? 0 } }

    func makeProvider(account: Account, credential: Credential) -> any ReviewProvider {
        made.withLock { $0[account.id, default: 0] += 1 }
        return FakeProvider(instance: account.instance, remote: remote(account.id))
    }

    func makeProbe(instance: ProviderInstance, credential: Credential) -> any ReviewProvider {
        FakeProvider(instance: instance, remote: FakeRemote())
    }

    func capabilities(for kind: ProviderKind) -> CapabilityManifest {
        CapabilityManifest(provider: kind, entries: [:])
    }
}

/// In-memory credential store (never the Keychain).
final class TestCredentialStore: CredentialStoring {
    private let storage = OSAllocatedUnfairLock(initialState: [AccountKey: Credential]())

    func save(_ credential: Credential, for account: AccountKey) throws { storage.withLock { $0[account] = credential } }
    func load(for account: AccountKey) throws -> Credential? { storage.withLock { $0[account] } }
    func delete(for account: AccountKey) throws { storage.withLock { $0[account] = nil } }
}

/// Records delivered notifications.
final class RecordingNotifier: NotificationDelivering {
    private let storage = OSAllocatedUnfairLock(initialState: [GroupedNotification]())

    func deliver(_ notification: GroupedNotification) async { storage.withLock { $0.append(notification) } }
    var delivered: [GroupedNotification] { storage.withLock { $0 } }
    func reset() { storage.withLock { $0.removeAll() } }
}

/// Records values from `@Sendable` callbacks.
final class Recorder<Value: Sendable>: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [Value]())
    func append(_ value: Value) { storage.withLock { $0.append(value) } }
    var values: [Value] { storage.withLock { $0 } }
    func reset() { storage.withLock { $0.removeAll() } }
}
