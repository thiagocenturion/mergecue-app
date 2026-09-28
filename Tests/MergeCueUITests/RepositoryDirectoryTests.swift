import Foundation
import MergeCueCore
import Testing
@testable import MergeCueUI

@Suite("Repository mapping: phases, listing and checkout scan")
struct RepositoryDirectoryUITests {
    static let key = AccountKey(kind: .github, host: "github.com", remoteUserID: "1")

    @Test func spinnerOnlyWhileTheFirstSyncRuns() {
        let never = AccountSyncStatus(account: Self.key, state: .syncing)
        #expect(RepositoryDirectory.phase(status: never, openRepositoryCount: 0, now: testNow) == .firstSync)
        let idle = AccountSyncStatus(account: Self.key, state: .idle)
        #expect(RepositoryDirectory.phase(status: idle, openRepositoryCount: 0, now: testNow) == .firstSync)
        // Synced with zero open PRs → empty state, never a spinner (the reported bug).
        let synced = AccountSyncStatus(account: Self.key, state: .ok, lastAttemptAt: testNow, lastSuccessAt: testNow)
        #expect(RepositoryDirectory.phase(status: synced, openRepositoryCount: 0, now: testNow) == .synced(count: 0))
        var resyncing = synced
        resyncing.state = .syncing
        #expect(RepositoryDirectory.phase(status: resyncing, openRepositoryCount: 0, now: testNow) == .synced(count: 0))
        #expect(RepositoryDirectory.phase(status: synced, openRepositoryCount: 3, now: testNow) == .synced(count: 3))
    }

    @Test func problemsShowTheRealState() {
        let expired = AccountSyncStatus(account: Self.key, state: .authExpired)
        guard case .problem(let title, let message) = RepositoryDirectory.phase(status: expired, openRepositoryCount: 0, now: testNow) else {
            Issue.record("expected a problem")
            return
        }
        #expect(title == "Credentials expired")
        #expect(message?.contains("Reconnect") == true)
        let limited = AccountSyncStatus(account: Self.key, state: .rateLimited(until: nil), message: "API rate limit exceeded")
        #expect(RepositoryDirectory.phase(status: limited, openRepositoryCount: 0, now: testNow)
            == .problem(title: "Rate limited", message: "API rate limit exceeded"))
        let offline = AccountSyncStatus(account: Self.key, state: .offline)
        if case .problem(let title, _) = RepositoryDirectory.phase(status: offline, openRepositoryCount: 0, now: testNow) {
            #expect(title == "Offline")
        } else {
            Issue.record("expected offline")
        }
    }

    @Test func otherRepositoriesAreSearchable() {
        func repo(_ id: String, _ path: String) -> Repository {
            Repository(key: RepoKey(account: Self.key, remoteRepoID: id), namespacePath: "acme", name: path,
                       fullPath: "acme/\(path)", webURL: URL(string: "https://github.com/acme/\(path)")!)
        }
        let all = [repo("1", "payments-api"), repo("2", "docs-site"), repo("3", "Payments-Web")]
        #expect(RepositoryDirectory.otherRepositories(all, excluding: [all[0].key], search: "").map(\.name) == ["docs-site", "Payments-Web"])
        #expect(RepositoryDirectory.otherRepositories(all, excluding: [], search: " PAYMENTS ").count == 2)
    }

    @MainActor
    @Test func modelLoadsListingsAndOrdersScanCandidates() async {
        let model = await makeModel()
        #expect(!model.repositoryListsSettled)
        await model.loadMissingRepositoryLists()
        #expect(model.repositoryListsSettled)
        let github = model.state.accounts.first { $0.kind == .github }
        let open = model.openRepositories(github?.id ?? Self.key)
        #expect(!open.isEmpty)
        let mapped = Set(model.state.mappings.map(\.repo))
        let candidates = model.checkoutScanCandidates
        #expect(Set(candidates).isDisjoint(with: mapped))
        #expect(Set(candidates).count == candidates.count)
    }
}

@Suite("EngineBackend repository directory (demo runtime)", .serialized)
struct EngineBackendRepositoryTests {
    @Test func listingAndScanFinishAndReachTheState() async throws {
        let harness = try await DemoBackendHarness.start()
        defer { Task { await harness.stop() } }
        let backend = harness.backend
        let github = try #require(await harness.state().accounts.first { $0.kind == .github })

        _ = try await backend.perform(.loadRepositories(github.id, forceRefresh: false))
        let loading = await harness.state().repositoryLists[github.id]
        #expect(loading != nil)
        await backend.waitForRepositoryWork()
        let list = try #require(await harness.state().repositoryLists[github.id])
        #expect(!list.isLoading)
        guard case .loaded(let repos, _, _) = list else {
            Issue.record("expected loaded, got \(list)")
            return
        }
        #expect(!repos.isEmpty)

        _ = try await backend.perform(.scanCheckouts(repos.map(\.key)))
        await backend.waitForRepositoryWork()
        let scan = await harness.state().checkoutScan
        #expect(!scan.isRunning)
        #expect(scan.finishedAt != nil)
        #expect(scan.errorMessage == nil)
    }

    @Test func listingErrorsAreReportedPerAccount() async throws {
        let harness = try await DemoBackendHarness.start()
        defer { Task { await harness.stop() } }
        let ghost = AccountKey(kind: .gitlab, host: "gitlab.example", remoteUserID: "404")
        _ = try await harness.backend.perform(.loadRepositories(ghost, forceRefresh: true))
        await harness.backend.waitForRepositoryWork()
        // Unknown accounts are filtered from AppState, but the backend recorded a failure rather than hanging.
        #expect(await harness.backend.repositoryLists[ghost]?.errorMessage != nil)
    }
}
