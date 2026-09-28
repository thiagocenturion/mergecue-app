import Foundation
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing
@testable import BitbucketCloudAdapter

@Suite("Bitbucket identity and listings")
struct ListingTests {
    @Test func currentUserParsesUUIDNicknameAndDisplayName() async throws {
        let harness = Harness()
        let user = try await harness.provider.currentUser()
        #expect(user == BitbucketFixtures.user)
        #expect(user.remoteID == "{8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40}", "UUIDs keep their braces")
    }

    @Test func bearerAndBasicCredentialsProduceTheRightAuthorizationHeader() async throws {
        let bearer = Harness(credential: .bearer("workspace-access-token"))
        _ = try await bearer.provider.currentUser()
        #expect(bearer.transport.requests.first?.header("Authorization") == "Bearer workspace-access-token")

        let basic = Harness(credential: .basic(username: "mona@example.com", password: "ATATT3xFfGF0-fixture"))
        _ = try await basic.provider.currentUser()
        let expected = "Basic " + Data("mona@example.com:ATATT3xFfGF0-fixture".utf8).base64EncodedString()
        #expect(basic.transport.requests.first?.header("Authorization") == expected)
    }

    @Test func namespacesComeFromUserWorkspaces() async throws {
        let harness = Harness()
        let namespaces = try await harness.provider.listNamespaces()
        #expect(namespaces.map(\.path) == ["acme", "mona-dev"])
        #expect(namespaces.allSatisfy { $0.kind == .workspace })
        #expect(namespaces.first?.id == "{c0ffee00-1111-4222-8333-444455556666}")
        #expect(harness.requests(containing: "/2.0/user/workspaces").count == 1)
        #expect(harness.requests(containing: "/2.0/workspaces?").isEmpty, "the deprecated /workspaces listing is not used")
    }

    @Test func repositoriesUseMemberRoleAndSanitizedCloneURLs() async throws {
        let harness = Harness()
        let repos = try await harness.provider.listRepositories(namespace: Namespace(id: "x", path: "acme", displayName: "Acme", kind: .workspace))
        #expect(repos.map(\.fullPath) == ["acme/payments-api", "acme/web"])
        let payments = try #require(repos.first)
        #expect(payments.key.remoteRepoID == BitbucketFixtures.IDs.paymentsRepoUUID)
        #expect(payments.cloneURLs.contains("https://bitbucket.org/acme/payments-api.git"), "embedded clone username is dropped")
        #expect(payments.cloneURLs.contains("git@bitbucket.org:acme/payments-api.git"))
        #expect(payments.defaultBranch == "main")
        let request = try #require(harness.requests(containing: "/repositories/acme?").first)
        #expect(request.queryItems.contains(URLQueryItem(name: "role", value: "member")))
    }

    @Test func authoredListingFollowsNextAcrossWorkspacesWithEncodedUUID() async throws {
        let harness = Harness()
        let items = try await harness.authored()
        #expect(items.map(\.key.number).sorted() == [12, 42])

        let acme = harness.requests(containing: "/workspaces/acme/pullrequests/")
        #expect(acme.count == 2, "page 1 + the `next` page")
        #expect(acme.allSatisfy { $0.url.absoluteString.contains("/pullrequests/\(Fx.meEncoded)") })
        #expect(acme.first?.queryItems.contains(URLQueryItem(name: "state", value: "OPEN")) == true)
        #expect(acme.last?.queryItems.contains(URLQueryItem(name: "page", value: "2")) == true)
        #expect(harness.requests(containing: "/workspaces/mona-dev/pullrequests/\(Fx.meEncoded)").count == 1)

        let pr42 = try #require(items.first { $0.key.number == 42 })
        #expect(pr42.key.remoteID == "42")
        #expect(pr42.key.repo.remoteRepoID == BitbucketFixtures.IDs.paymentsRepoUUID)
        #expect(pr42.key.repo.account == BitbucketFixtures.accountKey)
        #expect(pr42.versionToken == "2026-09-27T16:40:05.902114+00:00")
        #expect(pr42.updatedAt == ProviderDateParser.parse("2026-09-27T16:40:05.902114+00:00"))
        #expect(pr42.headSHA == "3f9c2e1d8b47")
        #expect(pr42.involvement == [.authored])
        #expect(pr42.webURL.absoluteString == "https://bitbucket.org/acme/payments-api/pull-requests/42")
        #expect(pr42.sourceBranch == "feature/refund-guard")
        #expect(pr42.targetBranch == "main")
        #expect(pr42.ref.string == "bitbucket_cloud:bitbucket.org/acme/payments-api#42")

        let fork = try #require(items.first { $0.key.number == 12 })
        #expect(fork.key.repo.remoteRepoID == BitbucketFixtures.IDs.paymentsRepoUUID, "the destination repository owns a fork PR")
    }

    @Test func authoredListingRespectsSelectedWorkspaces() async throws {
        let harness = Harness()
        _ = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .authored, namespaces: ["acme"]))
        #expect(harness.requests(containing: "/workspaces/mona-dev/").isEmpty)
        #expect(harness.requests(containing: "/user/workspaces").isEmpty, "explicit workspaces need no workspace listing")
    }

    @Test func reviewRequestedUsesPerRepositoryBBQLWithEncodedUUID() async throws {
        let harness = Harness()
        let repos = try await harness.provider.listRepositories(namespace: nil)
        let items = try await harness.reviewing(repositories: repos)
        #expect(items.map(\.key.number) == [7])
        let pr7 = try #require(items.first)
        #expect(pr7.involvement.contains(.reviewRequested))
        #expect(pr7.key.repo.remoteRepoID == BitbucketFixtures.IDs.webRepoUUID)
        #expect(pr7.author.username == "devon-p")

        let queries = harness.requests(containing: "/pullrequests?")
        #expect(queries.count == 3, "one BBQL query per repository")
        let expectedQuery = #"reviewers.uuid="{8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40}" AND state="OPEN""#
        #expect(queries.allSatisfy { $0.queryItems.contains(URLQueryItem(name: "q", value: expectedQuery)) })
        let raw = try #require(queries.first?.url.absoluteString)
        #expect(raw.contains("q=reviewers.uuid%3D%22%7B8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40%7D%22%20AND%20state%3D%22OPEN%22"))
    }

    @Test func involvedUsesPerRepositoryParticipantBBQL() async throws {
        let harness = Harness()
        let repos = try await harness.provider.listRepositories(namespace: nil)
        let items = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .involved, repositories: repos)).items
        #expect(items.map(\.key.number) == [7])
        #expect(items.first?.involvement.contains(.participated) == true)
        let expected = #"participants.user.uuid="{8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40}" AND state="OPEN""#
        let queries = harness.requests(containing: "/pullrequests?").filter { $0.queryItems.contains(URLQueryItem(name: "q", value: expected)) }
        #expect(queries.count == repos.count, "one BBQL query per repository, bounded like reviewer search")
        #expect(BitbucketCloudProvider.capabilityManifest.isUsable(.listInvolved))
    }

    @Test func reviewRequestedWithoutRepositoriesUsesRecentlyUpdatedMemberRepositories() async throws {
        let harness = Harness()
        let items = try await harness.reviewing()
        #expect(items.map(\.key.number) == [7])
        let listing = try #require(harness.requests(containing: "/repositories/acme?").first)
        #expect(listing.queryItems.contains(URLQueryItem(name: "sort", value: "-updated_on")))
        #expect(listing.queryItems.contains(URLQueryItem(name: "role", value: "member")))
    }

    @Test func updatedSinceFiltersClientSide() async throws {
        let harness = Harness()
        let since = try #require(ProviderDateParser.parse("2026-09-26T00:00:00Z"))
        let page = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .authored, updatedSince: since))
        #expect(page.items.map(\.key.number) == [42])
        #expect(page.notModified == false)
    }

    @Test func paginationStopsOnARepeatedNextLink() async throws {
        let loop = #"{"values": [], "next": "https://api.bitbucket.org/2.0/user/workspaces?page=2"}"#
        let harness = Harness(extraRoutes: [.getJSON("/user/workspaces", loop)])
        let namespaces = try await harness.provider.listNamespaces()
        #expect(namespaces.isEmpty)
        #expect(harness.requests(containing: "/user/workspaces").count == 2, "the repeated link is not followed again")
    }

    @Test func paginationRefusesNextLinksOnAnotherHost() async throws {
        let hostile = #"{"values": [], "next": "https://evil.example/steal"}"#
        let harness = Harness(extraRoutes: [.getJSON("/user/workspaces", hostile)])
        await #expect(throws: ProviderError.self) { try await harness.provider.listNamespaces() }
        #expect(harness.transport.requests.allSatisfy { $0.url.host() == "api.bitbucket.org" })
    }
}
