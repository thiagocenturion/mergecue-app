import Foundation

// Decodable mirrors of the GraphQL shapes requested in `GitHubQuery`. Fields the adapter can live without are
// optional so a partially populated node (deleted author, missing head repository…) still decodes.

/// A GitHub id that may arrive as a JSON string (`BigInt`, `fullDatabaseId`) or number (`databaseId`, REST `id`).
struct GHID: Decodable, Hashable, Sendable, CustomStringConvertible {
    let value: String

    init(_ value: String) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Int64.self) {
            value = String(number)
        } else if let number = try? container.decode(Double.self), number.isFinite, number.rounded() == number,
                  abs(number) < 9.0e15
        {
            value = String(Int64(number))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a string or integer id")
        }
    }

    var description: String { value }
}

struct GQLPageInfo: Decodable, Sendable {
    var hasNextPage: Bool
    var endCursor: String?
}

struct GQLConnection<Node: Decodable & Sendable>: Decodable, Sendable {
    var pageInfo: GQLPageInfo?
    var nodes: [Node?]?
    var totalCount: Int?

    var items: [Node] { nodes?.compactMap { $0 } ?? [] }
    var nextCursor: String? {
        guard let pageInfo, pageInfo.hasNextPage, let cursor = pageInfo.endCursor, !cursor.isEmpty else { return nil }
        return cursor
    }
}

struct GQLActor: Decodable, Sendable {
    var typename: String?
    var login: String
    var avatarUrl: URL?
    var databaseId: GHID?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", login, avatarUrl, databaseId, name
    }
}

struct GQLLogin: Decodable, Sendable { var login: String }
struct GQLName: Decodable, Sendable { var name: String }
struct GQLOid: Decodable, Sendable { var oid: String }
struct GQLNumber: Decodable, Sendable { var number: Int }

struct GQLRepo: Decodable, Sendable {
    var databaseId: GHID?
    var name: String?
    var nameWithOwner: String
    var url: URL?
    var sshUrl: String?
    var isPrivate: Bool?
    var owner: GQLLogin?
    var defaultBranchRef: GQLName?
}

struct GQLReviewComment: Decodable, Sendable {
    struct ReplyTo: Decodable, Sendable { var fullDatabaseId: GHID? }

    var id: String
    var fullDatabaseId: GHID?
    var body: String
    var url: URL?
    var createdAt: Date
    var updatedAt: Date?
    var diffHunk: String?
    var outdated: Bool?
    var author: GQLActor?
    var replyTo: ReplyTo?
    var commit: GQLOid?
    var originalCommit: GQLOid?
}

struct GQLThread: Decodable, Sendable {
    var typename: String?
    var id: String
    var isResolved: Bool
    var isOutdated: Bool
    var path: String
    var line: Int?
    var startLine: Int?
    var originalLine: Int?
    var originalStartLine: Int?
    var diffSide: String?
    var startDiffSide: String?
    var subjectType: String?
    var viewerCanResolve: Bool?
    var viewerCanUnresolve: Bool?
    var viewerCanReply: Bool?
    var pullRequest: GQLNumber?
    var repository: GQLRepo?
    var comments: GQLConnection<GQLReviewComment>?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", id, isResolved, isOutdated, path, line, startLine, originalLine, originalStartLine
        case diffSide, startDiffSide, subjectType, viewerCanResolve, viewerCanUnresolve, viewerCanReply, pullRequest
        case repository, comments
    }
}

struct GQLIssueComment: Decodable, Sendable {
    var id: String
    var fullDatabaseId: GHID?
    var body: String
    var url: URL?
    var createdAt: Date
    var updatedAt: Date?
    var author: GQLActor?
}

struct GQLReview: Decodable, Sendable {
    var id: String
    var fullDatabaseId: GHID?
    var body: String?
    var state: String
    var submittedAt: Date?
    var url: URL?
    var author: GQLActor?
    var commit: GQLOid?
}

struct GQLLatestReview: Decodable, Sendable {
    var state: String
    var author: GQLActor?
}

struct GQLReviewRequest: Decodable, Sendable {
    struct Reviewer: Decodable, Sendable {
        var typename: String?
        var login: String?
        var databaseId: GHID?
        var name: String?
        var slug: String?
        var avatarUrl: URL?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename", login, databaseId, name, slug, avatarUrl
        }
    }

    var asCodeOwner: Bool?
    var requestedReviewer: Reviewer?
}

/// A `StatusCheckRollupContext` union member: `CheckRun` or `StatusContext`.
struct GQLContext: Decodable, Sendable {
    struct CheckSuite: Decodable, Sendable {
        struct App: Decodable, Sendable { var slug: String?; var name: String? }
        struct WorkflowRun: Decodable, Sendable {
            var databaseId: GHID?
            var runNumber: Int?
            var workflow: GQLName?
        }

        var app: App?
        var workflowRun: WorkflowRun?
    }

    var typename: String
    // CheckRun
    var databaseId: GHID?
    var name: String?
    var status: String?
    var conclusion: String?
    var detailsUrl: URL?
    var url: URL?
    var title: String?
    var summary: String?
    var startedAt: Date?
    var completedAt: Date?
    var checkSuite: CheckSuite?
    // StatusContext
    var id: String?
    var context: String?
    var state: String?
    var targetUrl: URL?
    var description: String?
    var createdAt: Date?
    // Both
    var isRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename", databaseId, name, status, conclusion, detailsUrl, url, title, summary, startedAt
        case completedAt, checkSuite, id, context, state, targetUrl, description, createdAt, isRequired
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        typename = try c.decode(String.self, forKey: .typename)
        databaseId = try c.decodeIfPresent(GHID.self, forKey: .databaseId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        conclusion = try c.decodeIfPresent(String.self, forKey: .conclusion)
        detailsUrl = Self.url(c, .detailsUrl)
        url = Self.url(c, .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        checkSuite = try c.decodeIfPresent(CheckSuite.self, forKey: .checkSuite)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        context = try c.decodeIfPresent(String.self, forKey: .context)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        targetUrl = Self.url(c, .targetUrl)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        isRequired = try c.decodeIfPresent(Bool.self, forKey: .isRequired)
    }

    /// Third-party status target URLs are free text; an unparsable one must not fail the whole snapshot.
    private static func url(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> URL? {
        guard let text = try? c.decodeIfPresent(String.self, forKey: key), !text.isEmpty else { return nil }
        return URL(string: text)
    }
}

struct GQLStatusCheckRollup: Decodable, Sendable {
    var state: String?
    var contexts: GQLConnection<GQLContext>?
}

struct GQLHeadCommit: Decodable, Sendable {
    struct Commit: Decodable, Sendable {
        var oid: String
        var statusCheckRollup: GQLStatusCheckRollup?
    }

    var commit: Commit
}

struct GQLCommitNode: Decodable, Sendable {
    struct Commit: Decodable, Sendable {
        struct Author: Decodable, Sendable {
            var name: String?
            var user: GQLLogin?
        }

        var oid: String
        var messageHeadline: String?
        var authoredDate: Date?
        var author: Author?
    }

    var commit: Commit
}

struct GQLChangedFile: Decodable, Sendable {
    var path: String
    var additions: Int?
    var deletions: Int?
    var changeType: String?
}

struct GQLPullRequest: Decodable, Sendable {
    var id: String
    var fullDatabaseId: GHID?
    var number: Int
    var title: String
    var body: String?
    var url: URL
    var state: String
    var isDraft: Bool?
    var createdAt: Date
    var updatedAt: Date
    var headRefName: String
    var baseRefName: String
    var headRefOid: String?
    var baseRefOid: String?
    var isCrossRepository: Bool?
    var mergeStateStatus: String?
    var mergeable: String?
    var reviewDecision: String?
    var author: GQLActor?
    var repository: GQLRepo
    var headRepository: GQLRepo?
    var reviewRequests: GQLConnection<GQLReviewRequest>?
    var latestReviews: GQLConnection<GQLLatestReview>?
    var reviews: GQLConnection<GQLReview>?
    var comments: GQLConnection<GQLIssueComment>?
    var reviewThreads: GQLConnection<GQLThread>?
    var commits: GQLConnection<GQLCommitNode>?
    var files: GQLConnection<GQLChangedFile>?
    var headCommit: GQLConnection<GQLHeadCommit>?

    var headCommitNode: GQLHeadCommit.Commit? { headCommit?.items.last?.commit }
    var rollupState: String? { headCommitNode?.statusCheckRollup?.state }
}

/// A search result node; only pull requests are kept.
struct GQLSearchNode: Decodable, Sendable {
    var pullRequest: GQLPullRequest?

    private enum CodingKeys: String, CodingKey { case typename = "__typename" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let typename = try c.decodeIfPresent(String.self, forKey: .typename)
        pullRequest = typename == "PullRequest" ? try GQLPullRequest(from: decoder) : nil
    }
}

struct GQLViewer: Decodable, Sendable {
    var login: String
    var databaseId: GHID?
    var name: String?
    var avatarUrl: URL?
}

struct GQLSearchData: Decodable, Sendable {
    struct Search: Decodable, Sendable {
        var issueCount: Int?
        var pageInfo: GQLPageInfo?
        var nodes: [GQLSearchNode?]?
    }

    var viewer: GQLViewer
    var search: Search
}

struct GQLPullRequestData: Decodable, Sendable {
    struct Repository: Decodable, Sendable { var pullRequest: GQLPullRequest? }
    var repository: Repository?
}

/// Pull request fields returned by the `…Page` queries.
struct GQLPullRequestPage: Decodable, Sendable {
    var reviewThreads: GQLConnection<GQLThread>?
    var comments: GQLConnection<GQLIssueComment>?
    var reviews: GQLConnection<GQLReview>?
    var headCommit: GQLConnection<GQLHeadCommit>?
}

struct GQLPullRequestPageData: Decodable, Sendable {
    struct Repository: Decodable, Sendable { var pullRequest: GQLPullRequestPage? }
    var repository: Repository?
}

struct GQLThreadNodeData: Decodable, Sendable {
    var node: GQLThread?

    private enum CodingKeys: String, CodingKey { case node }
    private struct Typename: Decodable { var __typename: String? }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let probe = try c.decodeIfPresent(Typename.self, forKey: .node) else {
            node = nil
            return
        }
        node = probe.__typename == "PullRequestReviewThread" ? try c.decode(GQLThread.self, forKey: .node) : nil
    }
}

struct GQLThreadCommentsData: Decodable, Sendable {
    struct Node: Decodable, Sendable { var comments: GQLConnection<GQLReviewComment>? }
    var node: Node?
}

struct GQLResolveData: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        struct Thread: Decodable, Sendable { var id: String; var isResolved: Bool }
        var thread: Thread?
    }

    var resolveReviewThread: Payload?
    var unresolveReviewThread: Payload?
}
