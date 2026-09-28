import BitbucketCloudAdapter
import Foundation
import MergeCueCore
import MergeCueNetworking

/// Synthetic Bitbucket Cloud REST 2.0 fixtures (provider-native JSON under `Resources/bitbucket/`) and the stub
/// routes that serve them. **Fixture data — never live, never presented as such.**
///
/// Persona: `mona-dev` ("Mona Dev", uuid `{8a6f0b4e-…}`) in workspace `acme` (plus her personal workspace
/// `mona-dev` holding a fork).
/// - `acme/payments-api` PR **#42** by mona-dev: a thread with ≥3 replies (501→502→503→504), a code suggestion
///   (505), a reviewer question (506), an outdated inline comment (507), a hostile prompt-injection comment (508),
///   a pending draft (509, excluded), a deleted comment (510, excluded), a general comment (511), a resolved inline
///   thread (512), reviewer Lucía with `changes_requested`, Devon approved, one open task, Pipelines run #101 with a
///   failing "Unit tests" step (log fixture) and a passing SonarCloud commit status. Comments are served on two pages.
/// - `acme/web` PR **#7** by Devon where mona-dev is a requested reviewer (green, nothing blocking).
/// - `acme/payments-api` PR **#12** from the fork `mona-dev/payments-api`.
///
/// Steps: 0 = baseline; 1 = new blocking inline comment 513 + re-run #102 fails; 2 = reply 514 + run #103 passes.
public enum BitbucketFixtures {
    public static let instance = ProviderInstance.bitbucketCloud
    public static let userUUID = "{8a6f0b4e-2c1d-4c8e-9f3a-5b7d1e2c3a40}"
    public static let workspace = "acme"

    /// The fixture user as `currentUser()` reports it.
    public static let user = ProviderUser(
        remoteID: userUUID,
        username: "mona-dev",
        displayName: "Mona Dev",
        avatarURL: URL(string: "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/712020:0f5b6c1e-fixture-mona/fixture/128"),
        grantedScopes: [],
        email: nil
    )

    public static let accountKey = AccountKey(instance: instance, remoteUserID: userUUID)

    /// Identifiers used by the fixtures (for assertions).
    public enum IDs {
        public static let paymentsRepoUUID = "{5d3c1a2b-7e8f-4a9b-b0c1-d2e3f4a5b6c7}"
        public static let webRepoUUID = "{9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d}"
        public static let forkRepoUUID = "{2b4d6f8a-1c3e-4a5b-9d7f-0e2c4a6b8d0f}"
        public static let head42 = "3f9c2e1d8b47a5c6e0f1d2c3b4a59687a1b2c3d4"
        public static let head7 = "b7e4c1a9d2f35e6a7b8c9d0e1f2a3b4c5d6e7f80"
        public static let head12 = "e12f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f"
        public static let pipeline101 = "{1f0e2d3c-4b5a-4968-8778-a1b2c3d4e5f6}"
        public static let pipeline102 = "{2a1b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d}"
        public static let pipeline103 = "{3b2c4d5e-6f7a-4b8c-9d0e-1f2a3b4c5d6e}"
        public static let pipeline55 = "{5e5e5e5e-0000-4000-8000-000000000055}"
        public static let unitTestsStep101 = "{aa101000-0000-4000-8000-000000000002}"
        public static let unitTestsStep102 = "{bb102000-0000-4000-8000-000000000002}"
    }

    /// The comment containing the hostile prompt-injection text (PR #42).
    public static let hostileCommentID = "508"

    // MARK: Resources

    /// Raw bytes of `Resources/bitbucket/<name>`.
    public static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources/bitbucket") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "bitbucket/\(name)"])
        }
        return try Data(contentsOf: url)
    }

    /// UTF-8 text of `Resources/bitbucket/<name>`.
    public static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    // MARK: Routes

    /// A stub transport serving `routes(step:)` at the Bitbucket API base URL.
    public static func transport(step: Int = 0) -> StubTransport {
        StubTransport(routes: routes(step: step), baseURL: instance.apiURL)
    }

    /// A provider over `transport(step:)` with a private repository directory (tests never share state).
    public static func provider(
        step: Int = 0,
        transport: StubTransport? = nil,
        credential: Credential = .bearer("fixture-bitbucket-token"),
        clock: any MCClock = TestClock()
    ) -> BitbucketCloudProvider {
        BitbucketCloudProvider(
            instance: instance,
            credential: credential,
            transport: transport ?? self.transport(step: step),
            clock: clock,
            directory: BitbucketRepositoryDirectory()
        )
    }

    /// Stub routes for scenario `step` (0 baseline, 1 new blocking comment + failed pipeline, 2 reply + green).
    public static func routes(step: Int) -> [StubTransport.Route] {
        let step = min(max(step, 0), 2)
        let repoFiles = ["payments-api": "repo_payments-api.json", "web": "repo_web.json"]
        let repoByUUID = [
            IDs.paymentsRepoUUID: "repo_payments-api.json", IDs.webRepoUUID: "repo_web.json",
            IDs.forkRepoUUID: "repo_fork_payments-api.json",
        ]
        let stepsByPipeline = [
            IDs.pipeline101: "pipeline_101_steps.json", IDs.pipeline102: "pipeline_102_steps.json",
            IDs.pipeline103: "pipeline_103_steps.json", IDs.pipeline55: "pipeline_55_steps.json",
        ]
        let failingSteps: Set<String> = [IDs.unitTestsStep101, IDs.unitTestsStep102]

        /// `acme/payments-api` PR files by suffix (`nil` = not served).
        @Sendable func prFile(repo: String, id: String, _ suffix: String) -> String? {
            switch (repo, id, suffix) {
            case ("payments-api", "42", "detail"): "pr_42_step\(step).json"
            case ("payments-api", "42", "statuses"): "pr_42_statuses_step\(step).json"
            case ("payments-api", "42", "tasks"): "pr_42_tasks.json"
            case ("payments-api", "42", let other): "pr_42_\(other).json"
            case ("web", "7", "detail"): "pr_7.json"
            case ("web", "7", "tasks"): "empty_page.json"
            case ("web", "7", let other): "pr_7_\(other).json"
            case ("payments-api", "12", "detail"): "pr_12.json"
            case ("payments-api", "12", "comments"), ("payments-api", "12", "tasks"), ("payments-api", "12", "statuses"):
                "empty_page.json"
            case ("payments-api", "12", let other): "pr_12_\(other).json"
            default: nil
            }
        }

        func prRoute(_ suffix: String) -> StubTransport.Route {
            Route(method: "GET", pathPattern: "/repositories/acme/{repo}/pullrequests/{id}/\(suffix)") { _, match in
                respond(prFile(repo: match["repo"] ?? "", id: match["id"] ?? "", suffix))
            }
        }

        return [
            .fixed("GET", "/user", response: file("user.json")),
            .fixed("GET", "/user/workspaces", response: file("user_workspaces.json")),
            Route(method: "GET", pathPattern: "/repositories/{workspace}") { _, match in
                respond(["acme": "repositories_acme.json", "mona-dev": "repositories_mona-dev.json"][match["workspace"] ?? ""])
            },
            Route(method: "GET", pathPattern: "/repositories/{workspace}/{repo}") { _, match in
                let repo = match["repo"] ?? ""
                if repo.hasPrefix("{") {
                    // Addressed by UUID: only found in the workspace that owns it.
                    let name = repoByUUID[repo.lowercased()]
                    let owner = name == "repo_fork_payments-api.json" ? "mona-dev" : "acme"
                    return respond(match["workspace"] == owner ? name : nil)
                }
                if match["workspace"] == "mona-dev", repo == "payments-api" { return respond("repo_fork_payments-api.json") }
                return respond(match["workspace"] == "acme" ? repoFiles[repo] : nil)
            },
            // Authored listing (two pages for acme; the personal workspace has none).
            Route(method: "GET", pathPattern: "/workspaces/{workspace}/pullrequests/{user}") { _, match in
                guard BitbucketIdentifiers.sameUUID(match["user"], userUUID) || match["user"] == "mona-dev" else {
                    return respond(nil)
                }
                guard match["workspace"] == "acme" else { return respond(match["workspace"] == "mona-dev" ? "empty_page.json" : nil) }
                return respond(match.query["page"]?.first == "2" ? "workspace_prs_acme_page2.json" : "workspace_prs_acme_page1_step\(step).json")
            },
            // Review-requested listing (BBQL per repository).
            Route(method: "GET", pathPattern: "/repositories/{workspace}/{repo}/pullrequests") { _, match in
                let query = match.query["q"]?.first ?? ""
                let isReviewerQuery = query.contains("reviewers.uuid") && query.contains(userUUID)
                // Participants (involved listing): the user takes part in the web PR they review.
                let isParticipantQuery = query.contains("participants.user.uuid") && query.contains(userUUID)
                if isReviewerQuery || isParticipantQuery, match["workspace"] == "acme", match["repo"] == "web" {
                    return respond("reviewer_prs_web.json")
                }
                return respond("empty_page.json")
            },
            Route(method: "GET", pathPattern: "/repositories/acme/{repo}/pullrequests/{id}") { _, match in
                respond(prFile(repo: match["repo"] ?? "", id: match["id"] ?? "", "detail"))
            },
            Route(method: "GET", pathPattern: "/repositories/acme/{repo}/pullrequests/{id}/comments") { _, match in
                if match["repo"] == "payments-api", match["id"] == "42" {
                    return respond(match.query["page"]?.first == "2" ? "pr_42_comments_page2_step\(step).json" : "pr_42_comments_page1.json")
                }
                return respond(prFile(repo: match["repo"] ?? "", id: match["id"] ?? "", "comments"))
            },
            prRoute("tasks"), prRoute("statuses"), prRoute("commits"), prRoute("diffstat"),
            Route(method: "GET", pathPattern: "/repositories/acme/{repo}/pullrequests/{id}/diff") { _, match in
                respond(text: "pr_\(match["id"] ?? "").diff", when: prFile(repo: match["repo"] ?? "", id: match["id"] ?? "", "detail") != nil)
            },
            Route(method: "GET", pathPattern: "/repositories/acme/{repo}/pipelines") { _, match in
                switch match["repo"] {
                case "payments-api": respond("pipelines_payments_step\(step).json")
                case "web": respond("pipelines_web.json")
                default: respond(nil)
                }
            },
            Route(method: "GET", pathPattern: "/repositories/acme/{repo}/pipelines/{pipeline}/steps") { _, match in
                respond(stepsByPipeline[(match["pipeline"] ?? "").lowercased()])
            },
            Route(method: "GET", pathPattern: "/repositories/acme/{repo}/pipelines/{pipeline}/steps/{step}/log") { _, match in
                let failing = failingSteps.contains((match["step"] ?? "").lowercased())
                return respond(text: failing ? "pipeline_unit_tests_failed.log" : "pipeline_step_passed.log", when: true)
            },
            // Writes.
            Route(method: "POST", pathPattern: "/repositories/acme/{repo}/pullrequests/{id}/comments") { request, match in
                createdComment(request: request, repo: match["repo"] ?? "", id: match["id"] ?? "")
            },
            .fixed("POST", "/repositories/acme/{repo}/pullrequests/{id}/comments/{comment}/resolve", response: file("comment_resolution.json")),
            .fixed("DELETE", "/repositories/acme/{repo}/pullrequests/{id}/comments/{comment}/resolve", response: StubTransport.empty(status: 204)),
            .fixed("POST", "/repositories/acme/{repo}/pullrequests/{id}/request-changes", response: file("request_changes_participant.json")),
            Route(method: "POST", pathPattern: "/repositories/acme/{repo}/pullrequests/{id}/merge") { _, match in
                respond(match["repo"] == "payments-api" && match["id"] == "42" ? "pr_42_merged.json" : nil)
            },
        ]
    }

    private typealias Route = StubTransport.Route

    // MARK: Response helpers

    private static func file(_ name: String) -> HTTPResponse {
        do {
            return StubTransport.json(try data(name))
        } catch {
            return StubTransport.json(#"{"type":"error","error":{"message":"fixture missing"}}"#, status: 500)
        }
    }

    private static func respond(_ name: String?) -> HTTPResponse {
        guard let name else {
            return StubTransport.json(#"{"type":"error","error":{"message":"Resource not found"}}"#, status: 404)
        }
        return file(name)
    }

    private static func respond(text name: String, when available: Bool) -> HTTPResponse {
        guard available, let body = try? text(name) else { return respond(nil) }
        return StubTransport.text(body)
    }

    /// Echoes a created comment (id 601) with the posted body and parent, as Bitbucket does.
    private static func createdComment(request: HTTPRequest, repo: String, id: String) -> HTTPResponse {
        guard let template = try? JSONValue.defaultDecoder().decode(JSONValue.self, from: data("comment_reply_created.json")),
              case .object(var object) = template
        else { return respond(nil) }
        let body = request.jsonBody
        object["content"] = ["raw": body?["content"]?["raw"] ?? "", "markup": "markdown", "html": ""]
        if let parent = body?["parent"]?["id"] {
            object["parent"] = ["id": parent]
        } else {
            object.removeValue(forKey: "parent")
            object.removeValue(forKey: "inline")
        }
        object["links"] = [
            "html": ["href": .string("https://bitbucket.org/acme/\(repo)/pull-requests/\(id)#comment-601")],
        ]
        return StubTransport.json(value: .object(object), status: 201)
    }
}
