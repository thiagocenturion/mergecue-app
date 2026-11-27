import Foundation
import MergeCueCore
import MergeCueStore
import Testing
@testable import MergeCueEngine

/// Watched repositories and refresh interval per account (DECISIONS D36).
@Suite("Account sync settings")
struct AccountSyncSettingsTests {
    @Test func watchedRepositoriesFollowMappingsUntilTheOwnerEditsThem() async throws {
        let h = try await Harness.make()
        let mapped = Fixture.repo(Fixture.github)
        var state = try await h.engine.watchedRepositories(Fixture.github)
        #expect(state.repositories.map(\.key) == [mapped], "the harness mapped acme/payments-api")
        #expect(state.followsMappings)
        #expect(state.repositories.first?.fullPath == "acme/payments-api")

        let other = RepoKey(account: Fixture.github, remoteRepoID: "repo-9")
        let reloads = await h.sync.accountsDidChangeCount
        try await h.engine.setWatchedRepositories(Fixture.github, [mapped, other, mapped, RepoKey(account: Fixture.gitlab, remoteRepoID: "x")])
        #expect(try await h.db.account(Fixture.github)?.watchedRepositories == [mapped, other], "deduplicated, own account only")
        #expect(await h.sync.accountsDidChangeCount == reloads + 1, "Sync lists again")
        state = try await h.engine.watchedRepositories(Fixture.github)
        #expect(!state.followsMappings)

        // A new mapping joins an explicit list; removing everything means "all repositories".
        let third = RepoKey(account: Fixture.github, remoteRepoID: "repo-3")
        _ = try await h.engine.addMapping(repo: third, repoFullPath: "acme/third", checkoutPath: "/tmp/mergecue-tests/checkouts/third")
        #expect(try await h.db.account(Fixture.github)?.watchedRepositories == [mapped, other, third])
        try await h.engine.setWatchedRepositories(Fixture.github, [])
        #expect(try await h.engine.watchedRepositories(Fixture.github).watchesAll)
        _ = try await h.engine.addMapping(repo: other, repoFullPath: "acme/other", checkoutPath: "/tmp/mergecue-tests/checkouts/other")
        #expect(try await h.db.account(Fixture.github)?.watchedRepositories == [], "an explicit 'all' stays all")
        try await h.engine.setWatchedRepositories(Fixture.github, nil)
        #expect(try await h.engine.watchedRepositories(Fixture.github).followsMappings)
    }

    @Test func refreshIntervalIsStoredPerAccountAndSurvivesReconnect() async throws {
        let h = try await Harness.make()
        #expect(try await h.db.account(Fixture.github)?.effectiveRefreshInterval == .fifteenMinutes)
        try await h.engine.setRefreshInterval(Fixture.github, .manual)
        try await h.engine.setWatchedRepositories(Fixture.github, [Fixture.repo(Fixture.github)])
        #expect(try await h.db.account(Fixture.github)?.refreshInterval == .manual)

        h.world.state.update { $0.users["github"] = ProviderUser(remoteID: "1001", username: "mona-dev") }
        _ = try await h.engine.connectAccount(AccountConnectionRequest(
            instance: .githubCom, method: .personalAccessToken, credential: .bearer("ghp_reconnectedreconnected1234")
        ))
        let account = try #require(try await h.db.account(Fixture.github))
        #expect(account.refreshInterval == .manual, "reconnecting keeps the interval")
        #expect(account.watchedRepositories == [Fixture.repo(Fixture.github)], "and the watched repositories")
    }

    @Test func accountJSONWithoutTheNewFieldsStillDecodes() throws {
        var account = Fixture.account(Fixture.github, writesEnabled: false)
        account.watchedRepositories = nil
        account.refreshInterval = nil
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        #expect(decoded.watchedRepositories == nil && decoded.refreshInterval == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("watchedRepositories"), "optional fields are omitted when unset")
    }
}
