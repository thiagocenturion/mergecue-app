import Foundation
@testable import GitLabAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

@Suite("GitLab account, namespaces, repositories and listings")
struct GitLabParsingTests {
    @Test func manifestDeclaresEveryCapability() {
        let manifest = GitLabProvider.capabilityManifest
        #expect(manifest.provider == .gitlab)
        #expect(manifest.undeclared.isEmpty)
        #expect(manifest.isUsable(.createReply))
        #expect(manifest.isUsable(.resolveThread))
        guard case .partial = manifest.support(for: .requestChanges) else {
            Issue.record("requestChanges should be partial")
            return
        }
        #expect(GitLabProvider.protocolVersion == 1)
    }

    @Test func currentUserIncludesTokenScopes() async throws {
        let harness = GitLabHarness()
        let user = try await harness.provider.currentUser()
        #expect(user == GitLabFixtures.user)
        #expect(harness.requestedPaths.contains("/personal_access_tokens/self"))
        // The credential is sent as a Bearer token on every request.
        #expect(harness.transport.requests.allSatisfy { $0.header("Authorization") == "Bearer fixture-gitlab-token" })
    }

    @Test func currentUserToleratesNonPATTokens() async throws {
        let harness = GitLabHarness(extraRoutes: [
            .getJSON("/personal_access_tokens/self", #"{"message":"401 Unauthorized"}"#, status: 401),
        ])
        let user = try await harness.provider.currentUser()
        #expect(user.remoteID == "7001")
        #expect(user.grantedScopes.isEmpty)
    }

    @Test func namespacesIncludeUserAndNestedGroups() async throws {
        let harness = GitLabHarness()
        let namespaces = try await harness.provider.listNamespaces()
        #expect(namespaces.map(\.path) == ["mona-dev", "acme", "acme/platform"])
        #expect(namespaces.first?.kind == .user)
        #expect(namespaces.last?.kind == .group)
        #expect(namespaces.last?.displayName == "Acme / Platform")
        let groupsRequest = try #require(harness.transport.requests(path: "/groups").first)
        #expect(groupsRequest.queryItems.contains(URLQueryItem(name: "min_access_level", value: "10")))
    }

    @Test func repositoriesUseProjectIDsAndNestedPaths() async throws {
        let harness = GitLabHarness()
        let repositories = try await harness.provider.listRepositories(namespace: nil)
        #expect(repositories.map(\.key.remoteRepoID) == ["278964", "278990", "311000"])
        let web = try #require(repositories.first { $0.fullPath == "acme/platform/web" })
        #expect(web.namespacePath == "acme/platform")
        #expect(web.name == "web")
        #expect(web.cloneURLs == ["https://gitlab.com/acme/platform/web.git", "git@gitlab.com:acme/platform/web.git"])
        #expect(web.key.account == GitLabFixtures.accountKey)
        let request = try #require(harness.transport.requests(path: "/projects").first)
        #expect(request.queryItems.contains(URLQueryItem(name: "membership", value: "true")))
        #expect(request.queryItems.contains(URLQueryItem(name: "simple", value: "true")))

        let group = Namespace(id: "group:500", path: "acme", displayName: "Acme", kind: .group)
        let inGroup = try await harness.provider.listRepositories(namespace: group)
        #expect(inGroup.map(\.fullPath) == ["acme/payments-api", "acme/platform/web"])
        #expect(harness.requestedPaths.contains("/groups/500/projects"))

        let mine = try await harness.provider.listRepositories(namespace: Namespace(id: "user:7001", path: "mona-dev", displayName: "Mona", kind: .user))
        #expect(mine.map(\.fullPath) == ["mona-dev/payments-api"])
    }

    @Test func authoredListingPaginatesAndKeepsIDAndIIDApart() async throws {
        let harness = GitLabHarness()
        let page = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .authored))
        #expect(!page.notModified)
        #expect(page.items.map(\.key.number) == [42, 12])
        let mr42 = try #require(page.items.first)
        #expect(mr42.key == GitLabFixtures.mr42Key)
        #expect(mr42.key.remoteID == "99042")
        #expect(mr42.key.repo.remoteRepoID == "278964")
        #expect(mr42.repository.fullPath == "acme/payments-api")
        #expect(mr42.repository.webURL.absoluteString == "https://gitlab.com/acme/payments-api")
        #expect(mr42.ref.string == "gitlab:gitlab.com/acme/payments-api!42")
        #expect(mr42.involvement == [.authored, .assigned])
        #expect(mr42.headSHA == GitLabFixtures.IDs.head42)
        #expect(mr42.versionToken == "2026-09-20T10:00:00.000Z")
        #expect(mr42.state == .open)
        #expect(!mr42.isDraft)
        #expect(mr42.author.remoteID == "7001")

        let listRequests = harness.transport.requests(path: "/merge_requests")
        #expect(listRequests.count == 2)
        let first = try #require(listRequests.first)
        #expect(first.queryItems.contains(URLQueryItem(name: "scope", value: "created_by_me")))
        #expect(first.queryItems.contains(URLQueryItem(name: "state", value: "opened")))
        #expect(first.queryItems.contains(URLQueryItem(name: "per_page", value: "100")))
        #expect(listRequests.last?.queryItems.contains(URLQueryItem(name: "page", value: "2")) == true)
    }

    @Test func reviewRequestedListingUsesReviewerIDAndNestedGroup() async throws {
        let harness = GitLabHarness()
        let page = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested))
        #expect(page.items.count == 1)
        let mr7 = try #require(page.items.first)
        #expect(mr7.key == GitLabFixtures.mr7Key)
        #expect(mr7.repository.fullPath == "acme/platform/web")
        #expect(mr7.repository.namespacePath == "acme/platform")
        #expect(mr7.involvement.contains(.reviewRequested))
        #expect(!mr7.involvement.contains(.authored))
        #expect(mr7.author.username == "octo-lead")
        let request = try #require(harness.transport.requests(path: "/merge_requests").first)
        #expect(request.queryItems.contains(URLQueryItem(name: "reviewer_id", value: "7001")))
        #expect(request.queryItems.contains(URLQueryItem(name: "scope", value: "all")))
    }

    @Test func involvedListingUsesOwnCommentEventsThenProjectIIDs() async throws {
        let harness = GitLabHarness()
        let since = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21
        let page = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .involved, updatedSince: since))
        // MR !7 (commented, someone else's). The issue note is ignored and the user's own !42 is left to "authored".
        #expect(page.items.map(\.key) == [GitLabFixtures.mr7Key])
        #expect(page.items.first?.involvement.contains(.participated) == true)
        let events = try #require(harness.transport.requests(path: "/events").first)
        #expect(events.queryItems.contains(URLQueryItem(name: "action", value: "commented")))
        #expect(events.queryItems.contains(URLQueryItem(name: "target_type", value: "note")))
        #expect(events.queryItems.contains(URLQueryItem(name: "after", value: "2026-09-20")))
        let web = try #require(harness.transport.requests(path: "/projects/278990/merge_requests").first)
        #expect(web.queryItems.contains(URLQueryItem(name: "iids[]", value: "7")))
        #expect(web.queryItems.contains(URLQueryItem(name: "state", value: "opened")))
        #expect(harness.transport.requests(path: "/projects/278964/merge_requests").count == 1)
        guard case .partial(let note) = GitLabProvider.capabilityManifest.support(for: .listInvolved) else {
            Issue.record("listInvolved should be partial")
            return
        }
        #expect(note.contains("Reviewers stay"))
    }

    @Test func namespaceFilterMatchesNestedGroups() async throws {
        let harness = GitLabHarness()
        let platform = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested, namespaces: ["acme/platform"]))
        #expect(platform.items.count == 1)
        let acme = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested, namespaces: ["acme"]))
        #expect(acme.items.count == 1)
        let other = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested, namespaces: ["acm"]))
        #expect(other.items.isEmpty)
    }

    @Test func unchangedListingReportsNotModified() async throws {
        let harness = GitLabHarness()
        let first = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested))
        #expect(!first.notModified)
        let second = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested))
        #expect(second.notModified)
        #expect(second.items.isEmpty)
        let conditional = harness.transport.requests(path: "/merge_requests").last
        #expect(conditional?.header("If-None-Match")?.hasPrefix("W/") == true)
    }

    @Test func updatedSinceIsSentAsUpdatedAfter() async throws {
        let harness = GitLabHarness()
        _ = try await harness.provider.listChangeRequests(
            ChangeRequestQuery(scope: .reviewRequested, updatedSince: Date(timeIntervalSince1970: 1_790_000_000))
        )
        let request = try #require(harness.transport.requests(path: "/merge_requests").first)
        #expect(request.queryItems.contains(URLQueryItem(name: "updated_after", value: "2026-09-21T14:13:20Z")))
    }

    @Test func linkHeaderPaginationIsFollowedWhenNoNextPageHeader() async throws {
        let api = GitLabFixtures.instance.apiURL.absoluteString
        let harness = GitLabHarness(extraRoutes: [
            .getJSON("/groups", #"[{"id":1,"name":"A","path":"a","full_path":"a"}]"#,
                     headers: ["link": "<\(api)/groups?cursor=abc&per_page=100>; rel=\"next\""]),
            .getJSON("/groups", query: ["cursor": "abc"], #"[{"id":2,"name":"B","path":"b","full_path":"a/b"}]"#),
        ])
        let namespaces = try await harness.provider.listNamespaces()
        #expect(namespaces.map(\.path) == ["mona-dev", "a", "a/b"])
    }

    @Test func draftAndWIPDetection() throws {
        #expect(try GitLabMapping.isDraft(fixtureMergeRequest { $0["draft"] = true }))
        #expect(try GitLabMapping.isDraft(fixtureMergeRequest {
            $0.removeValue(forKey: "draft")
            $0["work_in_progress"] = true
        }))
        #expect(try GitLabMapping.isDraft(fixtureMergeRequest {
            $0.removeValue(forKey: "draft")
            $0.removeValue(forKey: "work_in_progress")
            $0["title"] = "WIP: refactor"
        }))
        #expect(try !GitLabMapping.isDraft(fixtureMergeRequest()))
        #expect(GitLabMapping.hasDraftTitlePrefix("Draft: x"))
        #expect(GitLabMapping.hasDraftTitlePrefix("[Draft] x"))
        #expect(!GitLabMapping.hasDraftTitlePrefix("Drafting rules"))
    }

    @Test func mergedAndClosedStatesArePreserved() throws {
        #expect(GitLabMapping.state("merged") == .merged)
        #expect(GitLabMapping.state("closed") == .closed)
        #expect(GitLabMapping.state("opened") == .open)
        #expect(GitLabMapping.state("locked") == .open)
    }

    @Test func botDetection() {
        #expect(GitLabMapping.isBotUsername("project_278964_bot_3f2a"))
        #expect(GitLabMapping.isBotUsername("group_9_bot"))
        #expect(GitLabMapping.isBotUsername("renovate-bot"))
        #expect(!GitLabMapping.isBotUsername("project_manager"))
        #expect(!GitLabMapping.isBotUsername("mona-dev"))
    }

    @Test func selfManagedInstanceIsPartOfIdentity() async throws {
        let instance = ProviderInstance(
            kind: .gitlab,
            webURL: URL(string: "https://git.example.com:8443/gitlab")!,
            apiURL: URL(string: "https://git.example.com:8443/gitlab/api/v4")!
        )
        let harness = GitLabHarness(instance: instance)
        let page = try await harness.provider.listChangeRequests(ChangeRequestQuery(scope: .authored))
        #expect(page.items.first?.key.repo.account.host == "git.example.com:8443")
        #expect(page.items.first?.ref.host == "git.example.com:8443")
        #expect(harness.transport.requests.allSatisfy { $0.url.host() == "git.example.com" && $0.url.port == 8443 })
        #expect(harness.transport.requests.allSatisfy { $0.url.path.hasPrefix("/gitlab/api/v4/") })
    }

    @Test func projectPathFromWebURLStripsRelativeRoot() throws {
        let instance = ProviderInstance(
            kind: .gitlab,
            webURL: URL(string: "https://git.example.com/gitlab")!,
            apiURL: URL(string: "https://git.example.com/gitlab/api/v4")!
        )
        let mr = try fixtureMergeRequest {
            $0.removeValue(forKey: "references")
            $0["web_url"] = "https://git.example.com/gitlab/acme/platform/web/-/merge_requests/7"
        }
        #expect(GitLabMapping.projectPath(of: mr, instance: instance) == "acme/platform/web")
    }
}
