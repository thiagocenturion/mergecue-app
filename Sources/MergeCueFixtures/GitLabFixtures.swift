import Foundation
import GitLabAdapter
import MergeCueCore
import MergeCueNetworking
import Synchronization

/// GitLab.com fixture scenario (synthetic data, never live) served by `StubTransport` from provider-native
/// REST v4 payloads in `Resources/gitlab/`.
///
/// Persona: user `mona-dev` (id 7001, "Mona Dev").
/// - `acme/payments-api` (project 278964) MR **!42** (global id 99042) authored by mona-dev: threaded diff
///   discussion (4 notes), code suggestion, reviewer question, outdated diff note (older diff version), individual
///   note, system note, a hostile prompt-injection note, reviewer `rev-alice` in state `requested_changes`.
/// - `acme/platform/web` (project 278990, nested group) MR **!7** (88007) by `octo-lead`; mona-dev is a reviewer.
/// - MR **!12** (99012) in `acme/payments-api` from the fork `mona-dev/payments-api` (source project 311000);
///   its pipeline runs in the fork.
///
/// Steps (`routes(step:)`): 0 = baseline (pipeline 5001 green), 1 = new blocking diff comment by rev-alice +
/// pipeline 5002 fails (`unit-tests`, trace fixture), 2 = mona-dev replies in that thread + pipeline 5003 green.
/// Write endpoints (reply, resolve, request changes, merge) are simulated and stateful per `routes(step:)` call.
public enum GitLabFixtures {
    /// Label shown wherever fixture data is displayed.
    public static let label = "GitLab fixture data (synthetic)"
    public static let instance = ProviderInstance.gitlabCom
    public static let stepCount = 3

    public static let user = ProviderUser(
        remoteID: "7001",
        username: "mona-dev",
        displayName: "Mona Dev",
        avatarURL: URL(string: "https://gitlab.com/uploads/-/system/user/avatar/7001/avatar.png"),
        grantedScopes: ["api", "read_user"],
        email: "mona-dev@example.com"
    )
    public static let accountKey = AccountKey(instance: instance, remoteUserID: user.remoteID)
    /// A fake bearer token for the stub transport (never a real credential).
    public static let credential = Credential.bearer("fixture-gitlab-token")

    /// Remote ids used by the scenario.
    public enum IDs {
        public static let paymentsProject = "278964"
        public static let webProject = "278990"
        public static let forkProject = "311000"
        public static let mr42 = "99042"
        public static let mr7 = "88007"
        public static let mr12 = "99012"
        public static let head42 = "ae44e8cc153cb128e982a7360b5171bdaed69d3c"
        public static let head42PreviousVersion = "fc9cdcb72ba0039cc098629314ff07f193db80e4"
        public static let base42 = "9286537fc5d0380eacf5eb62fe7c68cee503ecac"
        public static let head7 = "de617217db1767a951e3fd418aa820b9a7740066"
        public static let head12 = "185441ce12ce92bc802525c9ecf17b4d761df3c3"
        /// Discussion ids of MR !42.
        public static let threadedDiscussion = "b0f0ec9f0575df356fe956aa32d490d6a038bab4"
        public static let suggestionDiscussion = "cb29c5e5927455549cb1bda910e46ca341892eab"
        public static let questionDiscussion = "6cb65f69759cabb4cbd1e7653a3f647b698afa31"
        public static let outdatedDiscussion = "99e1edd301f24fea85233c096f869326dbc07afd"
        public static let individualNoteDiscussion = "b1a0e4659efae18d8f859b35dbc8dd7cb60b46d1"
        public static let systemNoteDiscussion = "cd41bf6e5fb2d9ca3d362500490dff6084d897cf"
        public static let injectionDiscussion = "f06ce242fc3f04c3e11fe19957364c3f6c20c3ed"
        /// Added at step 1.
        public static let blockingDiscussion = "1d10befca394179c9fb0c5941ff8a518099d7d61"
        /// Failed `unit-tests` job of pipeline 5002 (step 1) with a trace fixture.
        public static let failedJob = "7103"
    }

    // MARK: Keys

    public static func repoKey(project: String) -> RepoKey {
        RepoKey(account: accountKey, remoteRepoID: project)
    }

    /// MR !42 in acme/payments-api.
    public static var mr42Key: ChangeRequestKey { ChangeRequestKey(repo: repoKey(project: IDs.paymentsProject), remoteID: IDs.mr42, number: 42) }
    /// MR !7 in acme/platform/web (review requested).
    public static var mr7Key: ChangeRequestKey { ChangeRequestKey(repo: repoKey(project: IDs.webProject), remoteID: IDs.mr7, number: 7) }
    /// MR !12 in acme/payments-api from the fork.
    public static var mr12Key: ChangeRequestKey { ChangeRequestKey(repo: repoKey(project: IDs.paymentsProject), remoteID: IDs.mr12, number: 12) }

    // MARK: Transport / provider

    public static func transport(step: Int = 0) -> StubTransport {
        StubTransport(routes: routes(step: step), baseURL: instance.apiURL)
    }

    public static func provider(step: Int = 0, transport: StubTransport? = nil, clock: any MCClock = SystemClock()) -> GitLabProvider {
        GitLabProvider(instance: instance, credential: credential, transport: transport ?? self.transport(step: step), clock: clock)
    }

    // MARK: Resources

    /// Raw fixture bytes for `name` (without extension), honoring `.step<n>` overrides up to `step`.
    public static func data(_ name: String, ext: String = "json", step: Int = 0) -> Data? {
        for candidate in candidates(name, step: step) {
            if let url = resourceURL(candidate, ext: ext), let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }

    private static func candidates(_ name: String, step: Int) -> [String] {
        let clamped = min(max(step, 0), stepCount - 1)
        return stride(from: clamped, through: 1, by: -1).map { "\(name).step\($0)" } + [name]
    }

    private static func resourceURL(_ name: String, ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources/gitlab")
            ?? Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "gitlab")
    }

    // MARK: Routes

    /// Stub routes for scenario `step` (0 baseline, 1 blocking comment + failed pipeline, 2 reply + green).
    public static func routes(step: Int) -> [StubTransport.Route] {
        let state = FixtureState()
        typealias Route = StubTransport.Route
        return [
            Route(pathPattern: "/user") { request, _ in serve("user", step: step, request: request) },
            Route(pathPattern: "/personal_access_tokens/self") { request, _ in serve("personal_access_tokens_self", step: step, request: request) },
            Route(pathPattern: "/groups") { request, match in paged("groups", step: step, request: request, match: match) },
            Route(pathPattern: "/groups/{group}/projects") { request, match in
                paged("group_\(match["group"] ?? "")_projects", step: step, request: request, match: match)
            },
            Route(pathPattern: "/users/{user}/projects") { request, _ in
                guard let data = data("projects_membership", step: step), let projects = try? jsonArray(data) else { return notFound() }
                let owned = projects.filter { (($0["namespace"] as? [String: Any])?["kind"] as? String) == "user" }
                return respond(json: owned, request: request)
            },
            Route(pathPattern: "/projects") { request, match in paged("projects_membership", step: step, request: request, match: match) },
            Route(pathPattern: "/projects/{project}") { request, match in serve("project_\(match["project"] ?? "")", step: step, request: request) },
            Route(pathPattern: "/merge_requests", query: ["scope": "created_by_me"]) { request, match in
                paged("merge_requests_authored", step: step, request: request, match: match)
            },
            Route(pathPattern: "/merge_requests", query: ["reviewer_id": "*"]) { request, match in
                guard match.query["reviewer_id"]?.first == user.remoteID else { return respond(json: [Any](), request: request) }
                return paged("merge_requests_review_requested", step: step, request: request, match: match)
            },
            // Involved listing: the user's own comment events, then the commented merge requests per project.
            Route(pathPattern: "/events") { request, _ in serve("events_commented", step: step, request: request) },
            Route(pathPattern: "/projects/{project}/merge_requests") { request, match in
                let iids = Set(match.query["iids[]"] ?? [])
                let project = match["project"] ?? ""
                let lists = ["merge_requests_review_requested", "merge_requests_authored_page1", "merge_requests_authored_page2"]
                let all = lists.flatMap { name in (data(name, step: step).flatMap { try? jsonArray($0) }) ?? [] }
                let selected = all.filter { mr in
                    "\(mr["project_id"] ?? "")" == project && iids.contains("\(mr["iid"] ?? "")") && (mr["state"] as? String) == "opened"
                }
                return respond(json: selected, request: request)
            },
            Route(pathPattern: "/projects/{project}/merge_requests/{iid}") { request, match in
                serve(mrName(match), step: step, request: request)
            },
            Route(pathPattern: "/projects/{project}/merge_requests/{iid}/{resource}") { request, match in
                let resource = match["resource"] ?? ""
                if resource == "draft_notes", data(mrName(match) + "_draft_notes", step: step) == nil {
                    return respond(json: [Any](), request: request)
                }
                if resource == "reviewers" {
                    return reviewers(match: match, step: step, state: state, request: request)
                }
                return paged("\(mrName(match))_\(resource)", step: step, request: request, match: match)
            },
            Route(pathPattern: "/projects/{project}/merge_requests/{iid}/raw_diffs") { _, match in
                guard let data = data(mrName(match) + "_raw_diffs", ext: "diff", step: step) else { return notFound() }
                return StubTransport.text(String(decoding: data, as: UTF8.self))
            },
            Route(pathPattern: "/projects/{project}/merge_requests/{iid}/discussions/{discussion}") { request, match in
                guard let discussion = findDiscussion(match: match, step: step, state: state) else { return notFound() }
                return respond(json: discussion, request: request)
            },
            Route(pathPattern: "/projects/{project}/pipelines/{pipeline}/jobs") { request, match in
                paged("pipeline_\(match["pipeline"] ?? "")_jobs", step: step, request: request, match: match)
            },
            Route(pathPattern: "/projects/{project}/jobs/{job}/trace") { _, match in
                guard let data = data("job_\(match["job"] ?? "")_trace", ext: "log", step: step) else { return notFound() }
                return StubTransport.text(String(decoding: data, as: UTF8.self))
            },
            // Writes
            Route(method: "POST", pathPattern: "/projects/{project}/merge_requests/{iid}/discussions/{discussion}/notes") { request, match in
                createNote(request: request, match: match, step: step, state: state)
            },
            Route(method: "PUT", pathPattern: "/projects/{project}/merge_requests/{iid}/discussions/{discussion}") { request, match in
                resolve(request: request, match: match, step: step, state: state)
            },
            Route(method: "PUT", pathPattern: "/projects/{project}/merge_requests/{iid}/merge") { request, match in
                merge(request: request, match: match, step: step)
            },
            Route(method: "POST", pathPattern: "/projects/{project}/merge_requests/{iid}/draft_notes/bulk_publish") { request, match in
                if (request.jsonBody?["reviewer_state"]?.stringValue) == "requested_changes" {
                    state.requestChanges(mr: mrName(match))
                }
                return StubTransport.empty(status: 204)
            },
        ]
    }

    // MARK: Route helpers

    private static func mrName(_ match: StubTransport.Match) -> String {
        "mr_\(match["project"] ?? "")_\(match["iid"] ?? "")"
    }

    private static func notFound() -> HTTPResponse {
        StubTransport.json(#"{"message":"404 Not found"}"#, status: 404)
    }

    /// JSON response with a weak ETag; answers `304` when `If-None-Match` matches (as GitLab does).
    private static func respond(data: Data, request: HTTPRequest, headers: [String: String] = [:]) -> HTTPResponse {
        let etag = "W/\"\(ContentDigest.sha256Hex(data).prefix(32))\""
        if request.header("If-None-Match") == etag {
            return StubTransport.empty(status: 304, headers: headers.merging(["etag": etag]) { $1 })
        }
        return StubTransport.json(data, headers: headers.merging(["etag": etag]) { $1 })
    }

    private static func respond(json: Any, request: HTTPRequest, status: Int = 200) -> HTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return StubTransport.json(#"{"message":"fixture encoding failed"}"#, status: 500)
        }
        return status == 200 ? respond(data: data, request: request) : StubTransport.json(data, status: status)
    }

    private static func serve(_ name: String, step: Int, request: HTTPRequest) -> HTTPResponse {
        guard let data = data(name, step: step) else { return notFound() }
        return respond(data: data, request: request)
    }

    /// Serves `<name>_page<n>` files with GitLab offset-pagination headers (`x-next-page`, `Link`), or `<name>`
    /// as a single page.
    private static func paged(_ name: String, step: Int, request: HTTPRequest, match: StubTransport.Match) -> HTTPResponse {
        let page = Int(match.query["page"]?.first ?? "1") ?? 1
        guard data(name + "_page1", step: step) != nil else {
            guard page == 1, let data = data(name, step: step) else {
                return page == 1 ? notFound() : respond(data: Data("[]".utf8), request: request)
            }
            return respond(data: data, request: request, headers: ["x-page": "1", "x-next-page": "", "x-total-pages": "1"])
        }
        let total = (1...20).last { data("\(name)_page\($0)", step: step) != nil } ?? 1
        guard let body = data("\(name)_page\(page)", step: step) else { return respond(data: Data("[]".utf8), request: request) }
        var headers = ["x-page": String(page), "x-total-pages": String(total), "x-per-page": match.query["per_page"]?.first ?? "20"]
        headers["x-next-page"] = page < total ? String(page + 1) : ""
        if page < total {
            headers["link"] = "<\(pageURL(request.url, page: page + 1))>; rel=\"next\", <\(pageURL(request.url, page: 1))>; rel=\"first\""
        }
        return respond(data: body, request: request, headers: headers)
    }

    private static func pageURL(_ url: URL, page: Int) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        var items = (components.queryItems ?? []).filter { $0.name != "page" }
        items.append(URLQueryItem(name: "page", value: String(page)))
        components.queryItems = items
        return components.url?.absoluteString ?? url.absoluteString
    }

    private static func jsonArray(_ data: Data) throws -> [[String: Any]] {
        (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// All discussions of an MR for `step` (every page), with simulated writes applied.
    private static func discussions(mr: String, step: Int, state: FixtureState) -> [[String: Any]] {
        var all: [[String: Any]] = []
        if let data = data(mr + "_discussions", step: step) {
            all = (try? jsonArray(data)) ?? []
        } else {
            var page = 1
            while let data = data("\(mr)_discussions_page\(page)", step: step) {
                all += (try? jsonArray(data)) ?? []
                page += 1
            }
        }
        return all.map { state.apply(to: $0, mr: mr) }
    }

    private static func findDiscussion(match: StubTransport.Match, step: Int, state: FixtureState) -> [String: Any]? {
        discussions(mr: mrName(match), step: step, state: state).first { ($0["id"] as? String) == match["discussion"] }
    }

    private static func reviewers(match: StubTransport.Match, step: Int, state: FixtureState, request: HTTPRequest) -> HTTPResponse {
        let mr = mrName(match)
        guard let data = data(mr + "_reviewers", step: step), var entries = try? jsonArray(data) else { return notFound() }
        if state.hasRequestedChanges(mr: mr) {
            entries = entries.map { entry in
                var entry = entry
                if ((entry["user"] as? [String: Any])?["id"] as? Int).map(String.init) == user.remoteID {
                    entry["state"] = "requested_changes"
                }
                return entry
            }
        }
        return respond(json: entries, request: request)
    }

    private static func createNote(request: HTTPRequest, match: StubTransport.Match, step: Int, state: FixtureState) -> HTTPResponse {
        guard let discussion = findDiscussion(match: match, step: step, state: state) else { return notFound() }
        guard let body = request.jsonBody?["body"]?.stringValue, !body.isEmpty else {
            return StubTransport.json(#"{"error":"body is missing"}"#, status: 400)
        }
        let notes = discussion["notes"] as? [[String: Any]] ?? []
        let first = notes.first ?? [:]
        var note: [String: Any] = [
            "id": state.nextNoteID(),
            "type": (first["type"] as? String) ?? "DiscussionNote",
            "body": body,
            "author": [
                "id": 7001, "username": "mona-dev", "name": "Mona Dev", "state": "active",
                "avatar_url": "https://gitlab.com/uploads/-/system/user/avatar/7001/avatar.png",
                "web_url": "https://gitlab.com/mona-dev",
            ] as [String: Any],
            "created_at": "2026-09-22T08:00:00.000Z",
            "updated_at": "2026-09-22T08:00:00.000Z",
            "system": false,
            "noteable_type": "MergeRequest",
            "resolvable": true,
            "resolved": false,
        ]
        if let position = first["position"] { note["position"] = position }
        state.appendNote(note, discussion: match["discussion"] ?? "", mr: mrName(match))
        return respond(json: note, request: request, status: 201)
    }

    private static func resolve(request: HTTPRequest, match: StubTransport.Match, step: Int, state: FixtureState) -> HTTPResponse {
        guard let resolved = request.jsonBody?["resolved"]?.boolValue
            ?? request.queryItems.first(where: { $0.name == "resolved" }).map({ $0.value == "true" })
        else {
            return StubTransport.json(#"{"error":"resolved is missing"}"#, status: 400)
        }
        state.setResolved(resolved, discussion: match["discussion"] ?? "", mr: mrName(match))
        guard let discussion = findDiscussion(match: match, step: step, state: state) else { return notFound() }
        return respond(json: discussion, request: request)
    }

    private static func merge(request: HTTPRequest, match: StubTransport.Match, step: Int) -> HTTPResponse {
        guard let data = data(mrName(match), step: step),
              var mr = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return notFound() }
        let head = mr["sha"] as? String
        guard let sha = request.jsonBody?["sha"]?.stringValue, sha == head else {
            return StubTransport.json(#"{"message":"SHA does not match HEAD of source branch: \#(head ?? "")"}"#, status: 409)
        }
        mr["state"] = "merged"
        mr["merged_at"] = "2026-09-22T08:05:00.000Z"
        mr["detailed_merge_status"] = "not_open"
        return respond(json: mr, request: request)
    }
}

/// Mutable state of one simulated GitLab (replies, resolutions, reviewer states).
private final class FixtureState: Sendable {
    private struct Values {
        var nextNoteID = 5001
        var addedNotes: [String: [[String: Any]]] = [:]
        var resolved: [String: Bool] = [:]
        var requestedChanges: Set<String> = []
    }

    private let values = Mutex(UnsafeValues(Values()))

    /// `[String: Any]` payloads are only touched under the lock.
    private struct UnsafeValues: @unchecked Sendable {
        var value: Values
        init(_ value: Values) { self.value = value }
    }

    func nextNoteID() -> Int {
        values.withLock { box in
            defer { box.value.nextNoteID += 1 }
            return box.value.nextNoteID
        }
    }

    func appendNote(_ note: [String: Any], discussion: String, mr: String) {
        values.withLock { $0.value.addedNotes["\(mr)/\(discussion)", default: []].append(note) }
    }

    func setResolved(_ resolved: Bool, discussion: String, mr: String) {
        values.withLock { $0.value.resolved["\(mr)/\(discussion)"] = resolved }
    }

    func requestChanges(mr: String) {
        values.withLock { _ = $0.value.requestedChanges.insert(mr) }
    }

    func hasRequestedChanges(mr: String) -> Bool {
        values.withLock { $0.value.requestedChanges.contains(mr) }
    }

    func apply(to discussion: [String: Any], mr: String) -> [String: Any] {
        let id = discussion["id"] as? String ?? ""
        let (added, resolved) = values.withLock { ($0.value.addedNotes["\(mr)/\(id)"] ?? [], $0.value.resolved["\(mr)/\(id)"]) }
        var result = discussion
        var notes = (discussion["notes"] as? [[String: Any]] ?? []) + added
        if let resolved {
            notes = notes.map { note in
                guard note["resolvable"] as? Bool == true else { return note }
                var note = note
                note["resolved"] = resolved
                return note
            }
        }
        result["notes"] = notes
        return result
    }
}
