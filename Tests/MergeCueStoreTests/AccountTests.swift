import Foundation
import MergeCueCore
import Testing
@testable import MergeCueStore

@Suite("Accounts and repositories")
struct AccountTests {
    @Test func accountRoundTripsAndUpserts() async throws {
        let database = try MergeCueDatabase.inMemory()
        var account = StoreFixture.account()
        try await database.upsertAccount(account)
        #expect(try await database.account(account.id) == account)

        account.label = "Work"
        account.writesEnabled = true
        account.selectedNamespaces = ["acme"]
        try await database.upsertAccount(account)
        #expect(try await database.account(account.id) == account)
        #expect(try await database.accounts() == [account])
    }

    @Test func accountsAreListedOldestFirst() async throws {
        let database = try MergeCueDatabase.inMemory()
        let gitlab = StoreFixture.account(StoreFixture.gitlabAccount, connectedAt: StoreFixture.at(-60))
        let github = StoreFixture.account(StoreFixture.githubAccount, connectedAt: StoreFixture.at(0))
        try await database.upsertAccount(github)
        try await database.upsertAccount(gitlab)
        #expect(try await database.accounts() == [gitlab, github])
        #expect(try await database.account(AccountKey(kind: .github, host: "github.com", remoteUserID: "999")) == nil)
    }

    @Test func deleteAccountReportsWhetherItExisted() async throws {
        let database = try await StoreFixture.database()
        #expect(try await database.deleteAccount(StoreFixture.githubAccount))
        #expect(try await database.deleteAccount(StoreFixture.githubAccount) == false)
        #expect(try await database.accounts().isEmpty)
    }

    @Test func repositoriesUpsertAndListPerAccount() async throws {
        let database = try await StoreFixture.database(accounts: [StoreFixture.githubAccount, StoreFixture.gitlabAccount])
        let api = StoreFixture.repository(StoreFixture.repoKey(id: "1"), fullPath: "acme/payments-api")
        var web = StoreFixture.repository(StoreFixture.repoKey(id: "2"), fullPath: "acme/checkout-web")
        let other = StoreFixture.repository(StoreFixture.repoKey(StoreFixture.gitlabAccount, id: "3"), fullPath: "group/sub/project")
        try await database.upsertRepositories([api, web, other])
        #expect(try await database.repositories(account: StoreFixture.githubAccount) == [web, api])
        #expect(try await database.repositories(account: StoreFixture.gitlabAccount) == [other])

        web.defaultBranch = "develop"
        try await database.upsertRepositories([web])
        #expect(try await database.repositories(account: StoreFixture.githubAccount) == [web, api])
    }

    @Test func repositoriesRequireTheirAccount() async throws {
        let database = try MergeCueDatabase.inMemory()
        await #expect(throws: StoreError.notFound) {
            try await database.upsertRepositories([StoreFixture.repository()])
        }
        #expect(try await database.repositories(account: StoreFixture.githubAccount).isEmpty)
    }
}
