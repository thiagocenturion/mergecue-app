import Foundation
import MergeCueCore
import MergeCueNetworking
import Synchronization

/// A synthetic Bitbucket Cloud workspace for request-count measurements (fixture data, never live): workspace
/// `acme` with `repositoryCount` repositories and open pull requests authored by the user in a few of them. Every
/// endpoint the adapter reads during a sync is served from the mutable `State`, so a test can add a comment or
/// push a commit between refreshes. No ETags are sent: every request reaches the stub and is counted.
final class BitbucketWorld: Sendable {
    static let userUUID = "{0f0f0f0f-1111-4222-8333-000000000001}"
    static let otherUUID = "{0f0f0f0f-1111-4222-8333-000000000002}"
    static let workspace = "acme"

    struct PullRequest: Sendable {
        var id: Int
        var repoIndex: Int
        var head: String
        var updatedOn: Date
        var comments: [(id: Int, at: Date)]
        var taskCount: Int = 0
        var statusState: String = "SUCCESSFUL"
        var pipelineState: String = "COMPLETED"
    }

    struct State: Sendable {
        var pullRequests: [PullRequest]
    }

    let repositoryCount: Int
    let state: Mutex<State>
    let transport: StubTransport

    init(repositoryCount: Int = 500, pullRequests: [PullRequest]) {
        self.repositoryCount = repositoryCount
        state = Mutex(State(pullRequests: pullRequests))
        transport = StubTransport(routes: [], baseURL: ProviderInstance.bitbucketCloud.apiURL)
        transport.add(routes())
    }

    static func slug(_ index: Int) -> String { String(format: "repo-%03d", index) }
    static func repoUUID(_ index: Int) -> String { String(format: "{00000000-0000-4000-8000-%012d}", index) }

    func update(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    /// Requests recorded since the last `clear()`, as `GET /path?query` lines (API prefix removed).
    var requestLines: [String] {
        transport.requests.map { request in
            var line = "\(request.method) \(request.url.path(percentEncoded: false).replacingOccurrences(of: "/2.0", with: ""))"
            if let query = request.url.query(percentEncoded: false), !query.isEmpty { line += "?\(query)" }
            return line
        }
    }

    func clear() { transport.clearRequests() }

    // MARK: JSON

    static func date(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    static func account(_ uuid: String, nickname: String) -> [String: Any] {
        ["type": "user", "uuid": uuid, "nickname": nickname, "display_name": nickname, "account_id": "acc-\(nickname)"]
    }

    static func repository(_ index: Int) -> [String: Any] {
        let fullName = "\(workspace)/\(slug(index))"
        return [
            "type": "repository", "uuid": repoUUID(index), "full_name": fullName, "name": slug(index), "is_private": true,
            "links": [
                "html": ["href": "https://bitbucket.org/\(fullName)"],
                "clone": [["name": "https", "href": "https://bitbucket.org/\(fullName).git"]],
            ],
        ]
    }

    static func pullRequest(_ pr: PullRequest) -> [String: Any] {
        let repo = repository(pr.repoIndex)
        let fullName = "\(workspace)/\(slug(pr.repoIndex))"
        return [
            "type": "pullrequest", "id": pr.id, "title": "Change \(pr.id)", "state": "OPEN", "draft": false,
            "description": "Fixture pull request \(pr.id)",
            "author": account(userUUID, nickname: "mona-dev"),
            "source": ["branch": ["name": "feature/\(pr.id)"], "commit": ["hash": String(pr.head.prefix(12))], "repository": repo],
            "destination": ["branch": ["name": "main"], "commit": ["hash": "0123456789ab"], "repository": repo],
            "reviewers": [account(otherUUID, nickname: "devon")],
            "participants": [["type": "participant", "user": account(otherUUID, nickname: "devon"), "role": "REVIEWER", "approved": false]],
            "created_on": date(pr.updatedOn.addingTimeInterval(-86_400)),
            "updated_on": date(pr.updatedOn),
            "comment_count": pr.comments.count,
            "task_count": pr.taskCount,
            "links": [
                "html": ["href": "https://bitbucket.org/\(fullName)/pull-requests/\(pr.id)"],
                "self": ["href": "https://api.bitbucket.org/2.0/repositories/\(fullName)/pullrequests/\(pr.id)"],
            ],
        ]
    }

    static func commit(_ pr: PullRequest) -> [String: Any] {
        ["type": "commit", "hash": pr.head, "message": "Change \(pr.id)", "date": date(pr.updatedOn)]
    }

    static func diffstat() -> [String: Any] {
        [
            "type": "diffstat", "status": "modified", "lines_added": 3, "lines_removed": 1,
            "old": ["path": "README.md"], "new": ["path": "README.md"],
        ]
    }

    /// A response reached through one same-origin redirect (as `URLSessionTransport` reports it).
    static func redirected(_ response: HTTPResponse) -> HTTPResponse {
        var response = response
        response.headers[HTTPHeaders.redirectHops] = "1"
        return response
    }

    static func page(_ values: [Any], next: String? = nil) -> [String: Any] {
        var page: [String: Any] = ["values": values, "pagelen": max(values.count, 1)]
        if let next { page["next"] = next }
        return page
    }

    static func respond(_ object: Any) -> HTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return StubTransport.json(#"{"error":{"message":"fixture encoding failed"}}"#, status: 500)
        }
        return StubTransport.json(data)
    }

    static func notFound() -> HTTPResponse {
        StubTransport.json(#"{"type":"error","error":{"message":"Not found"}}"#, status: 404)
    }

    // MARK: Routes

    func pullRequests() -> [PullRequest] { state.withLock { $0.pullRequests } }

    func routes() -> [StubTransport.Route] {
        typealias Route = StubTransport.Route
        let repositoryCount = repositoryCount
        let workspace = Self.workspace, userUUID = Self.userUUID, otherUUID = Self.otherUUID
        @Sendable func respond(_ object: Any) -> HTTPResponse { Self.respond(object) }
        @Sendable func notFound() -> HTTPResponse { Self.notFound() }
        @Sendable func page(_ values: [Any], next: String? = nil) -> [String: Any] { Self.page(values, next: next) }
        @Sendable func date(_ value: Date) -> String { Self.date(value) }
        @Sendable func account(_ uuid: String, nickname: String) -> [String: Any] { Self.account(uuid, nickname: nickname) }
        @Sendable func slug(_ index: Int) -> String { Self.slug(index) }
        @Sendable func find(_ match: StubTransport.Match) -> PullRequest? {
            guard let slug = match["slug"], let id = Int(match["id"] ?? "") else { return nil }
            return self.pullRequests().first { Self.slug($0.repoIndex) == slug && $0.id == id }
        }
        @Sendable func authored(in slug: String?) -> [[String: Any]] {
            self.pullRequests()
                .filter { slug == nil || Self.slug($0.repoIndex) == slug }
                .map(Self.pullRequest)
        }
        return [
            Route(pathPattern: "/user") { _, _ in
                respond(["type": "user", "uuid": userUUID, "nickname": "mona-dev", "display_name": "Mona Dev", "account_id": "acc-mona"])
            },
            Route(pathPattern: "/user/workspaces") { _, _ in
                respond(page([["type": "workspace_access", "workspace": ["uuid": "{c0ffee00-0000-4000-8000-000000000001}", "slug": workspace, "name": "Acme"]]]))
            },
            // 100 repositories per page, `page=N` links (sorted by name, like `role=member`).
            Route(pathPattern: "/repositories/\(workspace)") { request, match in
                let pageNumber = Int(match.query["page"]?.first ?? "1") ?? 1
                let size = 100
                let start = (pageNumber - 1) * size
                let values = (start..<min(start + size, repositoryCount)).map(Self.repository)
                var next: String?
                if start + size < repositoryCount {
                    var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
                    var items = (components?.queryItems ?? []).filter { $0.name != "page" }
                    items.append(URLQueryItem(name: "page", value: String(pageNumber + 1)))
                    components?.queryItems = items
                    next = components?.url?.absoluteString
                }
                return respond(page(values, next: next))
            },
            Route(pathPattern: "/workspaces/\(workspace)/pullrequests/{user}") { _, _ in
                respond(page(authored(in: nil)))
            },
            Route(pathPattern: "/repositories/\(workspace)/{slug}") { _, match in
                guard let slug = match["slug"], let index = (0..<repositoryCount).first(where: { Self.slug($0) == slug || Self.repoUUID($0) == slug })
                else { return notFound() }
                return respond(Self.repository(index))
            },
            // Per-repository BBQL listings: authored (`author.uuid`) PRs of the user; reviewer listings are empty.
            Route(pathPattern: "/repositories/\(workspace)/{slug}/pullrequests") { _, match in
                let q = match.query["q"]?.first ?? ""
                guard q.contains("author.uuid") else { return respond(page([])) }
                return respond(page(authored(in: match["slug"])))
            },
            Route(pathPattern: "/repositories/\(workspace)/{slug}/pullrequests/{id}") { _, match in
                guard let pr = find(match) else { return notFound() }
                return respond(Self.pullRequest(pr))
            },
            Route(pathPattern: "/repositories/\(workspace)/{slug}/pullrequests/{id}/comments") { _, match in
                guard let pr = find(match) else { return notFound() }
                let values: [Any] = pr.comments.map { comment in
                    [
                        "type": "pullrequest_comment", "id": comment.id, "created_on": date(comment.at), "updated_on": date(comment.at),
                        "content": ["raw": "Comment \(comment.id)"], "user": account(otherUUID, nickname: "devon"),
                        "deleted": false, "pending": false,
                    ] as [String: Any]
                }
                return respond(page(values))
            },
            Route(pathPattern: "/repositories/\(workspace)/{slug}/pullrequests/{id}/tasks") { _, match in
                guard let pr = find(match) else { return notFound() }
                let values: [Any] = (0..<pr.taskCount).map { ["id": 9_000 + $0, "state": "UNRESOLVED", "content": ["raw": "Task"]] }
                return respond(page(values))
            },
            Route(pathPattern: "/repositories/\(workspace)/{slug}/pullrequests/{id}/statuses") { _, match in
                guard let pr = find(match) else { return notFound() }
                return respond(page([[
                    "type": "build", "key": "lint-\(pr.id)", "name": "Lint", "state": pr.statusState,
                    "url": "https://ci.example/lint/\(pr.id)", "created_on": date(pr.updatedOn), "updated_on": date(pr.updatedOn),
                    "links": ["commit": ["href": "https://api.bitbucket.org/2.0/repositories/\(workspace)/\(slug(pr.repoIndex))/commit/\(pr.head)"]],
                ] as [String: Any]]))
            },
            // The pull request commits/diffstat endpoints answer 302 to the repository endpoints in production; the
            // stub serves the final answer and reports the followed hop like `URLSessionTransport` does.
            Route(pathPattern: "/repositories/\(workspace)/{slug}/pullrequests/{id}/commits") { _, match in
                guard let pr = find(match) else { return notFound() }
                return Self.redirected(respond(page([Self.commit(pr)])))
            },
            Route(pathPattern: "/repositories/\(workspace)/{slug}/pullrequests/{id}/diffstat") { _, match in
                guard find(match) != nil else { return notFound() }
                return Self.redirected(respond(page([Self.diffstat()])))
            },
            Route(pathPattern: "/repositories/\(workspace)/{slug}/commits/{revision}") { _, match in
                let revision = match["revision"] ?? ""
                guard let pr = self.pullRequests().first(where: { Self.slug($0.repoIndex) == match["slug"] && $0.head.hasPrefix(revision) })
                else { return notFound() }
                return respond(page([Self.commit(pr)]))
            },
            Route(pathPattern: "/repositories/\(workspace)/{slug}/diffstat/{spec}") { _, _ in
                respond(page([Self.diffstat()]))
            },
            Route(pathPattern: "/repositories/\(workspace)/{slug}/pipelines") { _, match in
                let hash = match.query["target.commit.hash"]?.first ?? ""
                let prs = self.pullRequests().filter { Self.slug($0.repoIndex) == match["slug"] && $0.head == hash }
                let values: [Any] = prs.map { pr in
                    [
                        "type": "pipeline", "uuid": "{5e5e5e5e-0000-4000-8000-\(String(format: "%012d", pr.id))}", "build_number": pr.id,
                        "state": ["name": pr.pipelineState, "result": ["name": pr.pipelineState == "COMPLETED" ? "SUCCESSFUL" as Any : NSNull()]],
                        "target": ["type": "pipeline_commit_target", "commit": ["hash": pr.head], "selector": ["type": "pull-requests", "pattern": "**"]],
                        "created_on": date(pr.updatedOn), "completed_on": date(pr.updatedOn),
                    ] as [String: Any]
                }
                return respond(page(values))
            },
            Route(pathPattern: "/repositories/\(workspace)/{slug}/pipelines/{pipeline}/steps") { _, match in
                let pipeline = match["pipeline"] ?? ""
                let pr = self.pullRequests().first { pipeline.hasSuffix(String(format: "%012d}", $0.id)) }
                guard let pr else { return respond(page([])) }
                return respond(page([[
                    "type": "pipeline_step", "uuid": "{6e6e6e6e-0000-4000-8000-\(String(format: "%012d", pr.id))}", "name": "Unit tests",
                    "state": ["name": pr.pipelineState, "result": ["name": pr.pipelineState == "COMPLETED" ? "SUCCESSFUL" as Any : NSNull()]],
                    "started_on": date(pr.updatedOn), "completed_on": date(pr.updatedOn),
                ] as [String: Any]]))
            },
        ]
    }
}
