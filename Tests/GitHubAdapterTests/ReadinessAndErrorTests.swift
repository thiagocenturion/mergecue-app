import Foundation
@testable import GitHubAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

@Suite("GitHub readiness")
struct ReadinessTests {
    private func evaluate(
        state: ChangeRequestState = .open, draft: Bool = false, merge: String? = "CLEAN", mergeable: String? = "MERGEABLE",
        decision: String? = nil, unresolved: Int = 0, checks: AggregateCheckState = .passing
    ) -> MergeReadiness {
        GitHubReadiness.evaluate(state: state, isDraft: draft, mergeStateStatus: merge, mergeable: mergeable,
                                 reviewDecision: decision, unresolvedThreads: unresolved, checks: checks)
    }

    @Test func readyOnlyWhenCleanNoUnresolvedAndChecksPass() {
        #expect(evaluate() == .readyToMerge)
        #expect(evaluate(checks: .none) == .readyToMerge)
        #expect(evaluate(merge: "HAS_HOOKS", decision: "APPROVED") == .readyToMerge)
    }

    @Test func checksGreenWhenOnlyChecksPass() {
        #expect(evaluate(unresolved: 1) == .checksGreen)
        #expect(evaluate(merge: "BLOCKED", decision: "REVIEW_REQUIRED") == .checksGreen)
        #expect(evaluate(merge: "UNKNOWN") == .checksGreen)
        #expect(evaluate(draft: true) == .checksGreen)
    }

    @Test func blockedReasons() {
        #expect(evaluate(merge: "BLOCKED", decision: "CHANGES_REQUESTED", unresolved: 2, checks: .failing)
            == .blocked(reasons: ["Changes requested", "2 unresolved threads", "Checks failing"]))
        #expect(evaluate(merge: "DIRTY", mergeable: "CONFLICTING", unresolved: 1, checks: .pending)
            == .blocked(reasons: ["Merge conflicts", "1 unresolved thread", "Checks pending"]))
        #expect(evaluate(draft: true, merge: "DRAFT", checks: .none) == .blocked(reasons: ["Draft"]))
        #expect(evaluate(merge: "BEHIND", checks: .none) == .blocked(reasons: ["Branch is behind the base branch"]))
        #expect(evaluate(merge: "BLOCKED", checks: .none) == .blocked(reasons: ["Blocked by branch protection rules"]))
        #expect(evaluate(merge: "CLEAN", checks: .failing) == .blocked(reasons: ["Checks failing"]))
        #expect(evaluate(state: .merged) == .unknown)
        #expect(evaluate(state: .closed) == .unknown)
    }

    @Test func checkStatusMapping() {
        #expect(GitHubChecks.status(checkRunStatus: "COMPLETED", conclusion: "STARTUP_FAILURE") == .failure)
        #expect(GitHubChecks.status(checkRunStatus: "COMPLETED", conclusion: "TIMED_OUT") == .timedOut)
        #expect(GitHubChecks.status(checkRunStatus: "COMPLETED", conclusion: "ACTION_REQUIRED") == .actionRequired)
        #expect(GitHubChecks.status(checkRunStatus: "COMPLETED", conclusion: "SKIPPED") == .skipped)
        #expect(GitHubChecks.status(checkRunStatus: "IN_PROGRESS", conclusion: nil) == .inProgress)
        #expect(GitHubChecks.status(checkRunStatus: "WAITING", conclusion: nil) == .queued)
        #expect(GitHubChecks.status(statusState: "ERROR") == .failure)
        #expect(GitHubChecks.status(statusState: "PENDING") == .inProgress)
        #expect(GitHubChecks.status(statusState: "EXPECTED") == .queued)
        #expect(GitHubChecks.jobID(fromDetailsURL: URL(string: "https://github.com/a/b/actions/runs/1/job/77")) == "77")
        #expect(GitHubChecks.jobID(fromDetailsURL: URL(string: "https://ci.example.com/builds/1")) == nil)
    }
}

@Suite("GitHub error mapping")
struct ErrorMappingTests {
    @Test func unauthorized() async {
        let (provider, _) = GH.bareProvider([.fixed("GET", "/user", response: GH.response(#"{"message":"Bad credentials"}"#, status: 401))])
        await #expect(throws: ProviderError.unauthorized("Bad credentials")) { try await provider.currentUser() }
    }

    @Test func forbiddenWithMissingScope() async {
        let headers = ["x-oauth-scopes": "read:org", "x-accepted-oauth-scopes": "repo"]
        let (provider, _) = GH.bareProvider([
            .fixed("GET", "/user", response: GH.response(#"{"message":"Resource not accessible by personal access token"}"#, status: 403, headers: headers)),
        ])
        await #expect(throws: ProviderError.forbidden(missingScope: "repo", message: "Resource not accessible by personal access token")) {
            try await provider.currentUser()
        }
    }

    @Test func secondaryRateLimitIs403WithRetryAfter() async throws {
        let (provider, _) = GH.bareProvider([
            .fixed("GET", "/user", response: GH.response(#"{"message":"You have exceeded a secondary rate limit."}"#, status: 403,
                                                         headers: ["retry-after": "600"])),
        ])
        await #expect(throws: ProviderError.rateLimited(resetAt: nil, retryAfter: 600)) { try await provider.currentUser() }
    }

    @Test func notFoundAndTooManyRequests() async {
        let (provider, _) = GH.bareProvider([
            .fixed("GET", "/user/orgs", response: GH.response(#"{"message":"Not Found"}"#, status: 404)),
            .fixed("GET", "/user", response: GH.response(#"{"message":"slow down"}"#, status: 429,
                                                         headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790003600"])),
        ])
        await #expect(throws: ProviderError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_790_003_600), retryAfter: nil)) {
            try await provider.currentUser()
        }
        let (orgs, _) = GH.bareProvider([
            .getJSON("/user", String(decoding: GitHubFixtures.resource("rest/user.json") ?? Data(), as: UTF8.self)),
            .fixed("GET", "/user/orgs", response: GH.response(#"{"message":"Not Found"}"#, status: 404)),
        ])
        await #expect(throws: ProviderError.notFound("Not Found")) { try await orgs.listNamespaces() }
    }

    private func graphQLProvider(_ body: String, headers: [String: String] = [:]) -> GitHubProvider {
        GH.bareProvider([.fixed("POST", "/graphql", response: GH.response(body, status: 200, headers: headers))]).provider
    }

    @Test func graphQLErrorsMapToProviderErrors() async {
        let query = ChangeRequestQuery(scope: .authored)
        let notFound = graphQLProvider(#"{"data":null,"errors":[{"type":"NOT_FOUND","path":["node"],"message":"Could not resolve to a node"}]}"#)
        await #expect(throws: ProviderError.notFound("Could not resolve to a node")) { try await notFound.listChangeRequests(query) }

        let scopes = graphQLProvider(#"""
        {"errors":[{"type":"INSUFFICIENT_SCOPES","locations":[{"line":1,"column":1}],"message":"Your token has not been granted the required scopes to execute this query. The 'login' field requires one of the following scopes: ['read:org'], but your token has only been granted the: ['repo'] scopes."}]}
        """#)
        await #expect {
            try await scopes.listChangeRequests(query)
        } throws: { error in
            guard case .forbidden(let scope, _)? = error as? ProviderError else { return false }
            return scope == "read:org"
        }

        let forbidden = graphQLProvider(#"{"data":null,"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by integration"}]}"#)
        await #expect(throws: ProviderError.forbidden(missingScope: nil, message: "Resource not accessible by integration")) {
            try await forbidden.listChangeRequests(query)
        }

        let limited = graphQLProvider(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded for user ID 583231."}]}"#,
                                      headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1790003600"])
        await #expect(throws: ProviderError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_790_003_600), retryAfter: nil)) {
            try await limited.listChangeRequests(query)
        }

        let other = graphQLProvider(#"{"errors":[{"message":"Field 'nope' doesn't exist on type 'Query'"}]}"#)
        await #expect(throws: ProviderError.invalidRequest("Field 'nope' doesn't exist on type 'Query'")) {
            try await other.listChangeRequests(query)
        }

        let broken = graphQLProvider(#"{"data":{"viewer":{"login":"x"}}}"#)
        await #expect {
            try await broken.listChangeRequests(query)
        } throws: { error in
            if case .decoding? = error as? ProviderError { return true }
            return false
        }
    }

    @Test func graphQLHTTPErrorsUseRESTMapping() async {
        let provider = GH.bareProvider([.fixed("POST", "/graphql", response: GH.response(#"{"message":"Bad credentials"}"#, status: 401))]).provider
        await #expect(throws: ProviderError.unauthorized("Bad credentials")) {
            try await provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested))
        }
    }

    @Test func scopeParsingFromMessage() {
        #expect(GitHubGraphQLClient.missingScope(in: "requires one of the following scopes: ['read:org', 'repo'], but") == "read:org")
        #expect(GitHubGraphQLClient.missingScope(in: "no scopes here") == nil)
    }

    @Test func graphQLEndpointForEnterpriseServer() throws {
        #expect(GitHubGraphQLClient.endpoint(forAPIURL: try #require(URL(string: "https://api.github.com"))).absoluteString
            == "https://api.github.com/graphql")
        #expect(GitHubGraphQLClient.endpoint(forAPIURL: try #require(URL(string: "https://ghe.acme.dev/api/v3"))).absoluteString
            == "https://ghe.acme.dev/api/graphql")
    }

    @Test func errorsNeverContainTheToken() async {
        let (provider, _) = GH.bareProvider([
            .fixed("GET", "/user", response: GH.response(#"{"message":"token test-token-abcdef is invalid"}"#, status: 401)),
        ])
        do {
            _ = try await provider.currentUser()
            Issue.record("expected an error")
        } catch {
            #expect(!String(describing: error).contains("test-token-abcdef"))
        }
    }
}
