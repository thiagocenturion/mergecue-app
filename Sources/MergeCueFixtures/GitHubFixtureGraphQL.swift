import Foundation
import MergeCueCore
import MergeCueNetworking

/// Answers the adapter's named GraphQL operations (`operationName`) from the `Resources/github/graphql` fixtures,
/// the way api.github.com would (including `errors` entries with a `type` for unknown nodes).
enum GitHubFixtureGraphQL {
    typealias IDs = GitHubFixtures.IDs

    static func respond(to request: HTTPRequest, step: Int) -> HTTPResponse {
        guard let body = request.jsonBody, let operation = body["operationName"]?.stringValue else {
            return error(type: nil, message: "A query attribute must be specified and must be a string.")
        }
        let variables = body["variables"]?.objectValue ?? [:]
        switch operation {
        case "MergeCueSearch":
            let query = variables["q"]?.stringValue ?? ""
            if query.contains("review-requested:@me") { return GitHubFixtures.file("graphql/search_review_requested.json") }
            if query.contains("author:@me") { return GitHubFixtures.file("graphql/search_authored_step\(step).json") }
            return data(["viewer": viewer, "search": ["issueCount": 0, "pageInfo": emptyPageInfo, "nodes": []]])

        case "MergeCuePullRequest":
            guard let file = pullRequestFile(variables, step: step) else {
                return error(type: "NOT_FOUND", message: "Could not resolve to a PullRequest with the number of \(number(variables) ?? 0).",
                             data: ["repository": ["pullRequest": .null]])
            }
            return GitHubFixtures.file(file)

        case "MergeCueReviewThreadsPage":
            if number(variables) == 42, variables["after"]?.stringValue == IDs.threadsCursor {
                return GitHubFixtures.file("graphql/pr42_threads_page2_step\(step).json")
            }
            return emptyPullRequestPage("reviewThreads")

        case "MergeCueIssueCommentsPage":
            return emptyPullRequestPage("comments")

        case "MergeCueReviewsPage":
            return emptyPullRequestPage("reviews")

        case "MergeCueCheckContextsPage":
            return data(["repository": ["pullRequest": ["headCommit": ["nodes": []]]]])

        case "MergeCueThread":
            let id = variables["id"]?.stringValue ?? ""
            guard let thread = thread(id: id, step: step) else { return nodeNotFound(id) }
            return data(["node": thread])

        case "MergeCueThreadCommentsPage":
            let id = variables["id"]?.stringValue ?? ""
            if id == IDs.longThread, variables["after"]?.stringValue == IDs.longThreadCommentsCursor {
                return GitHubFixtures.file("graphql/pr42_thread_comments_page2_step\(step).json")
            }
            guard thread(id: id, step: step) != nil else { return nodeNotFound(id) }
            return data(["node": ["__typename": "PullRequestReviewThread", "comments": ["pageInfo": emptyPageInfo, "nodes": []]]])

        case "MergeCueResolveThread", "MergeCueUnresolveThread":
            let id = variables["id"]?.stringValue ?? ""
            guard thread(id: id, step: step) != nil else { return nodeNotFound(id) }
            let field = operation == "MergeCueResolveThread" ? "resolveReviewThread" : "unresolveReviewThread"
            let resolved: JSONValue = .bool(operation == "MergeCueResolveThread")
            return data([field: ["thread": ["id": .string(id), "isResolved": resolved]]])

        default:
            return error(type: nil, message: "Unknown operation \(operation) (fixture).")
        }
    }

    // MARK: Lookups

    private static func number(_ variables: [String: JSONValue]) -> Int? {
        variables["number"]?.intValue
    }

    private static func pullRequestFile(_ variables: [String: JSONValue], step: Int) -> String? {
        let owner = variables["owner"]?.stringValue?.lowercased()
        let name = variables["name"]?.stringValue?.lowercased()
        switch (owner, name, number(variables)) {
        case ("acme", "payments-api", 42): return "graphql/pr42_step\(step).json"
        case ("acme", "payments-api", 12): return "graphql/pr12.json"
        case ("acme", "web", 7): return "graphql/pr7.json"
        default: return nil
        }
    }

    /// A `PullRequestReviewThread` node of PR #42 at `step` (first comments page, as the API returns it).
    static func thread(id: String, step: Int) -> JSONValue? {
        let firstPage = GitHubFixtures.json("graphql/pr42_step\(step).json")?["data"]?["repository"]?["pullRequest"]?["reviewThreads"]?["nodes"]
        let secondPage = GitHubFixtures.json("graphql/pr42_threads_page2_step\(step).json")?["data"]?["repository"]?["pullRequest"]?["reviewThreads"]?["nodes"]
        let all = (firstPage?.arrayValue ?? []) + (secondPage?.arrayValue ?? [])
        guard case .object(var object)? = all.first(where: { $0["id"]?.stringValue == id }) else { return nil }
        object["__typename"] = "PullRequestReviewThread"
        return .object(object)
    }

    // MARK: Responses

    private static let emptyPageInfo: JSONValue = ["hasNextPage": false, "endCursor": .null]
    private static let viewer: JSONValue = ["login": "mona-dev", "databaseId": 583231, "name": "Mona Dev", "avatarUrl": .null]

    private static func emptyPullRequestPage(_ connection: String) -> HTTPResponse {
        data(["repository": ["pullRequest": .object([connection: ["pageInfo": emptyPageInfo, "nodes": []]])]])
    }

    private static func nodeNotFound(_ id: String) -> HTTPResponse {
        error(type: "NOT_FOUND", message: "Could not resolve to a node with the global id of '\(id)'", data: ["node": .null])
    }

    private static func data(_ value: JSONValue) -> HTTPResponse {
        StubTransport.json(value: ["data": value], headers: GitHubFixtures.rateHeaders.merging(["x-ratelimit-resource": "graphql"]) { _, new in new })
    }

    static func error(type: String?, message: String, data: JSONValue = .null) -> HTTPResponse {
        var entry: [String: JSONValue] = ["message": .string(message), "locations": [["line": 1, "column": 1]]]
        if let type { entry["type"] = .string(type) }
        return StubTransport.json(value: ["data": data, "errors": [.object(entry)]])
    }
}
