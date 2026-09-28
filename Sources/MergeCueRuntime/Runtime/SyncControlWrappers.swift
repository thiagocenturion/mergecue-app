import BitbucketCloudAdapter
import Foundation
import GitHubAdapter
import GitLabAdapter
import MergeCueCore
import MergeCueEngine
import MergeCueFixtures
import MergeCueStore
import MergeCueSync
import Synchronization

/// The engine's `SyncControlling` in demo mode: a **manual** refresh (the engine's `refresh(account:)`, i.e. the
/// UI's Refresh button) first advances the fixture scenario one step for the refreshed provider(s), so the owner
/// can watch a new comment + CI failure arrive, then a reply + CI recovery. Automatic polling, wake-ups and network
/// recovery call the coordinator directly and never advance the scenario.
final class DemoSyncControl: SyncControlling {
    let coordinator: SyncCoordinator
    let scenario: DemoScenario

    init(coordinator: SyncCoordinator, scenario: DemoScenario) {
        self.coordinator = coordinator
        self.scenario = scenario
    }

    func start() async { await coordinator.start() }
    func stop() async { await coordinator.stop() }

    func refreshAll() async {
        scenario.advance()
        await coordinator.refreshAll()
    }

    func refresh(account: AccountKey) async {
        scenario.advance([account.kind])
        await coordinator.refresh(account: account)
    }

    func accountsDidChange() async { await coordinator.accountsDidChange() }
    func statuses() async -> [AccountSyncStatus] { await coordinator.statuses() }

    func setEventHandler(_ handler: @escaping @Sendable ([ChangeEvent]) async -> Void) async {
        await coordinator.setEventHandler(handler)
    }

    func setNotificationsPaused(until: Date?) async {
        await coordinator.setNotificationsPaused(until: until)
    }

    func setNotificationPreferences(_ preferences: NotificationPreferences) async {
        await coordinator.setNotificationPreferences(preferences)
    }

    func setQuietHours(_ quietHours: QuietHours?) async {
        await coordinator.setQuietHours(quietHours)
    }
}

/// Forwards Sync's `onChange` signals into the engine's change stream (the engine is created after Sync).
final class ChangeRelay: Sendable {
    private let target = Mutex<MergeCueEngine?>(nil)

    func connect(_ engine: MergeCueEngine) {
        target.withLock { $0 = engine }
    }

    func disconnect() {
        target.withLock { $0 = nil }
    }

    func forward(_ change: EngineChange) {
        guard let engine = target.withLock({ $0 }) else { return }
        Task { await engine.forwardExternalChange(change) }
    }
}

/// Seeds the adapters' process-wide link registries from stored snapshots, so deep links (which are synchronous
/// and only get keys) resolve right after launch — before the first sync hydrates anything.
enum LinkPreloader {
    @discardableResult
    static func preload(from database: MergeCueDatabase) async -> Int {
        let snapshots: [ChangeRequestSnapshot]
        do {
            snapshots = try await database.snapshots(account: nil)
        } catch {
            MCLog(category: "runtime").error("Link preload skipped: \(error)")
            return 0
        }
        for snapshot in snapshots {
            remember(snapshot)
        }
        return snapshots.count
    }

    static func remember(_ snapshot: ChangeRequestSnapshot) {
        switch snapshot.key.kind {
        case .github:
            let registry = GitHubLinkRegistry.shared
            let repository = snapshot.summary.repository
            registry.registerRepository(
                host: repository.key.account.host, remoteRepoID: repository.key.remoteRepoID, fullPath: repository.fullPath
            )
            for thread in snapshot.threads where thread.key.kind == .diffThread {
                if let root = thread.rootComment { registry.registerThreadRoot(thread.key, commentID: root.id) }
            }
            for check in snapshot.checks {
                if let url = check.detailsURL { registry.registerCheckURL(check.key, url: url) }
            }
        case .gitlab:
            GitLabProvider.rememberLinks(from: snapshot)
        case .bitbucketCloud:
            BitbucketRepositoryDirectory.shared.remember(snapshot)
        }
    }
}
