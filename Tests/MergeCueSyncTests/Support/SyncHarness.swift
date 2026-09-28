import Foundation
import MergeCueCore
import MergeCueStore
@testable import MergeCueSync

/// A coordinator wired to fakes, an in-memory database and a `TestClock` (no real sleeping).
final class SyncHarness: Sendable {
    let clock: TestClock
    let database: MergeCueDatabase
    let factory: FakeProviderFactory
    let credentials = TestCredentialStore()
    let notifier = RecordingNotifier()
    let changes = Recorder<EngineChange>()
    let handledEvents = Recorder<[ChangeEvent]>()
    let accounts: [AccountKey]

    init(accounts: [AccountKey] = [SyncFixture.github], clock: TestClock = TestClock()) async throws {
        self.clock = clock
        self.accounts = accounts
        database = try MergeCueDatabase.inMemory()
        factory = FakeProviderFactory([:])
        for key in accounts {
            try await database.upsertAccount(SyncFixture.account(key))
            try credentials.save(.bearer("test-token-\(key.kind.rawValue)"), for: key)
        }
    }

    func remote(_ account: AccountKey = SyncFixture.github) -> FakeRemote { factory.remote(account) }

    func makeCoordinator(configuration: SyncConfiguration = .deterministic) async -> SyncCoordinator {
        let coordinator = SyncCoordinator(
            database: database,
            credentials: credentials,
            providers: factory,
            notifier: notifier,
            clock: clock,
            configuration: configuration,
            onChange: { [changes] in changes.append($0) }
        )
        await coordinator.setEventHandler { [handledEvents] in handledEvents.append($0) }
        return coordinator
    }

    /// Starts the coordinator and waits until `sleepers` loops finished their first cycle and sleep.
    func start(_ coordinator: SyncCoordinator, sleepers: Int? = nil) async {
        await coordinator.start()
        await clock.waitForSleepers(count: sleepers ?? accounts.count)
    }

    /// Advances time by `seconds` and waits until `sleepers` loops are asleep again.
    func advance(_ seconds: TimeInterval, sleepers: Int? = nil) async {
        clock.advance(by: seconds)
        await clock.waitForSleepers(count: sleepers ?? accounts.count)
    }

    // MARK: Store queries

    func items(_ account: AccountKey? = nil) async throws -> [AttentionItem] {
        try await database.attentionItems(includeInactive: true).filter { account == nil || $0.account == account }
    }

    func activeItems() async throws -> [AttentionItem] {
        try await database.attentionItems(includeInactive: false, now: clock.now)
    }

    func events(_ cr: ChangeRequestKey = SyncFixture.crKey()) async throws -> [ChangeEvent] {
        try await database.events(changeRequest: cr)
    }
}
