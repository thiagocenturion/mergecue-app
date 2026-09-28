import Foundation
@testable import GitHubAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

@Suite("GitHub fixture parsing")
struct FixtureParsingTests {
    @Test func everyJSONFixtureIsValidJSON() throws {
        let paths = GitHubFixtures.allResourcePaths()
        #expect(paths.count >= 30)
        for path in paths where path.hasSuffix(".json") {
            let data = try #require(GitHubFixtures.resource(path), "missing \(path)")
            #expect(throws: Never.self, "\(path)") { try JSONValue.defaultDecoder().decode(JSONValue.self, from: data) }
        }
    }

    @Test func graphQLFixturesDecodeIntoAdapterModels() throws {
        let decoder = JSONDecoder.mergeCueProvider
        struct Envelope<D: Decodable>: Decodable { var data: D }
        for step in 0...2 {
            let pr = try decoder.decode(Envelope<GQLPullRequestData>.self, from: try #require(GitHubFixtures.resource("graphql/pr42_step\(step).json")))
            #expect(pr.data.repository?.pullRequest?.number == 42)
            let page = try decoder.decode(Envelope<GQLPullRequestPageData>.self,
                                          from: try #require(GitHubFixtures.resource("graphql/pr42_threads_page2_step\(step).json")))
            #expect((page.data.repository?.pullRequest?.reviewThreads?.items.count ?? 0) == (step == 0 ? 2 : 3))
            let comments = try decoder.decode(Envelope<GQLThreadCommentsData>.self,
                                              from: try #require(GitHubFixtures.resource("graphql/pr42_thread_comments_page2_step\(step).json")))
            #expect((comments.data.node?.comments?.items.count ?? 0) == (step == 2 ? 3 : 2))
            let search = try decoder.decode(Envelope<GQLSearchData>.self, from: try #require(GitHubFixtures.resource("graphql/search_authored_step\(step).json")))
            #expect(search.data.search.nodes?.compactMap { $0?.pullRequest?.number } == [42, 12])
        }
        for name in ["pr7", "pr12"] {
            let pr = try decoder.decode(Envelope<GQLPullRequestData>.self, from: try #require(GitHubFixtures.resource("graphql/\(name).json")))
            #expect(pr.data.repository?.pullRequest != nil)
        }
        let requested = try decoder.decode(Envelope<GQLSearchData>.self, from: try #require(GitHubFixtures.resource("graphql/search_review_requested.json")))
        #expect(requested.data.search.nodes?.compactMap { $0?.pullRequest?.number } == [7])
    }

    @Test func restFixturesDecodeIntoAdapterModels() throws {
        let decoder = JSONDecoder.mergeCueProvider
        func load<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            try decoder.decode(type, from: try #require(GitHubFixtures.resource(path)))
        }
        #expect(try load(RESTUser.self, "rest/user.json").login == "mona-dev")
        #expect(try load([RESTOrganization].self, "rest/user_orgs.json").map(\.login) == ["acme"])
        #expect(try load([RESTRepository].self, "rest/user_repos_page1.json").count == 2)
        #expect(try load([RESTRepository].self, "rest/user_repos_page2.json").count == 2)
        #expect(try load([RESTRepository].self, "rest/org_acme_repos.json").count == 3)
        #expect(try load(RESTRepository.self, "rest/repository_1296269.json").fullName == "acme/payments-api")
        #expect(try load(RESTRepository.self, "rest/repository_1296300.json").fullName == "acme/web")
        #expect(try load(RESTPullRequest.self, "rest/pull_42.json").head.sha == GH.IDs.head42)
        #expect(try load([RESTPullFile].self, "rest/pull_42_files.json").count == 4)
        #expect(try load(RESTCheckRun.self, "rest/check_run_9001.json").output?.summary != nil)
        #expect(try load(RESTIssueComment.self, "rest/issue_comment_2500000201.json").id.value == GH.IDs.issueComment)
        #expect(try load(RESTReview.self, "rest/review_2600000301.json").state == "CHANGES_REQUESTED")
        #expect(try load(RESTReviewComment.self, "rest/review_comment_created.json").inReplyToID?.value == "2400000101")
        #expect(try load(RESTIssueComment.self, "rest/issue_comment_created.json").id.value == "2500000999")
        #expect(try load(RESTReview.self, "rest/review_created.json").state == "CHANGES_REQUESTED")
        #expect(GitHubFixtures.resource("rest/job_9001.log").map { !$0.isEmpty } == true)
        #expect(GitHubFixtures.resource("rest/pull_42.diff").map { String(decoding: $0, as: UTF8.self).hasPrefix("diff --git") } == true)
    }

    @Test func currentUserReadsScopesFromHeader() async throws {
        let (provider, _) = GH.provider()
        let user = try await provider.currentUser()
        #expect(user == GitHubFixtures.user)
        #expect(user.grantedScopes == ["repo", "read:org"])
    }

    @Test func fineGrainedTokenHasNoScopes() async throws {
        let body = String(decoding: try #require(GitHubFixtures.resource("rest/user.json")), as: UTF8.self)
        let (provider, _) = GH.bareProvider([.getJSON("/user", body)])
        let user = try await provider.currentUser()
        #expect(user.grantedScopes.isEmpty)
        #expect(user.remoteID == "583231")
    }

    @Test func namespacesAreUserThenOrganizations() async throws {
        let (provider, _) = GH.provider()
        let namespaces = try await provider.listNamespaces()
        #expect(namespaces.map(\.path) == ["mona-dev", "acme"])
        #expect(namespaces.map(\.kind) == [.user, .organization])
        #expect(namespaces.first?.id == "583231")
    }

    @Test func repositoriesFollowLinkPaginationAndSkipArchived() async throws {
        let (provider, transport) = GH.provider()
        let all = try await provider.listRepositories(namespace: nil)
        #expect(all.map(\.fullPath) == ["acme/payments-api", "acme/web", "mona-dev/payments-api"])
        #expect(transport.requests("GET", path: "/user/repos").count == 2)
        let payments = try #require(all.first)
        #expect(payments.key.remoteRepoID == "1296269")
        #expect(payments.key.account == GitHubFixtures.accountKey)
        #expect(payments.cloneURLs == ["https://github.com/acme/payments-api.git", "git@github.com:acme/payments-api.git"])
        #expect(payments.defaultBranch == "main")

        let org = Namespace(id: "9919", path: "acme", displayName: "acme", kind: .organization)
        let orgRepos = try await provider.listRepositories(namespace: org)
        #expect(orgRepos.map(\.fullPath) == ["acme/payments-api", "acme/web"])
        #expect(transport.requests("GET", path: "/orgs/acme/repos").count == 1)
    }

    @Test func manifestDeclaresEveryCapability() {
        let manifest = GitHubProvider.capabilityManifest
        #expect(manifest.undeclared.isEmpty)
        #expect(manifest.provider == .github)
        for capability in Capability.allCases where capability.isWrite {
            #expect(manifest.support(for: capability) == .requiresWriteAccess(scope: "repo"))
        }
        for capability in Capability.allCases where !capability.isWrite {
            #expect(manifest.isUsable(capability))
        }
        #expect(GitHubProvider.capabilities(grantedScopes: ["repo"]).support(for: .merge) == .supported)
        #expect(GitHubProvider.capabilities(grantedScopes: ["read:org"]).support(for: .createReply) == .requiresWriteAccess(scope: "repo"))
        if case .partial = GitHubProvider.capabilities(grantedScopes: []).support(for: .createReply) {} else {
            Issue.record("fine-grained tokens should get partial write support")
        }
        #expect(GH.provider().provider.capabilities.support(for: .resolveThread) == .supported)
    }
}
