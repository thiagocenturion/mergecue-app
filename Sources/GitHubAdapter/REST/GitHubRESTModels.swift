import Foundation

// Decodable mirrors of the GitHub REST v3 payloads the adapter reads (snake_case keys are declared explicitly).

struct RESTUser: Decodable, Sendable {
    var id: GHID
    var login: String
    var name: String?
    var avatarURL: URL?
    var email: String?
    var type: String?

    enum CodingKeys: String, CodingKey {
        case id, login, name, email, type
        case avatarURL = "avatar_url"
    }
}

struct RESTOrganization: Decodable, Sendable {
    var id: GHID
    var login: String
    var description: String?
}

struct RESTRepository: Decodable, Sendable {
    var id: GHID
    var name: String
    var fullName: String
    var owner: GQLLogin?
    var htmlURL: URL?
    var cloneURL: String?
    var sshURL: String?
    var defaultBranch: String?
    var isPrivate: Bool?
    var archived: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, owner, archived
        case fullName = "full_name"
        case htmlURL = "html_url"
        case cloneURL = "clone_url"
        case sshURL = "ssh_url"
        case defaultBranch = "default_branch"
        case isPrivate = "private"
    }
}

struct RESTPullRequest: Decodable, Sendable {
    struct Ref: Decodable, Sendable {
        var sha: String
        var ref: String?
    }

    var id: GHID
    var number: Int
    var state: String
    var draft: Bool?
    var merged: Bool?
    var mergedAt: Date?
    var updatedAt: Date
    var htmlURL: URL?
    var head: Ref
    var base: Ref

    enum CodingKeys: String, CodingKey {
        case id, number, state, draft, merged, head, base
        case mergedAt = "merged_at"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
    }
}

/// A pull request review comment (diff comment), e.g. the result of the replies endpoint.
struct RESTReviewComment: Decodable, Sendable {
    var id: GHID
    var body: String
    var user: RESTUser?
    var createdAt: Date
    var updatedAt: Date?
    var htmlURL: URL?
    var inReplyToID: GHID?

    enum CodingKeys: String, CodingKey {
        case id, body, user
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
        case inReplyToID = "in_reply_to_id"
    }
}

struct RESTIssueComment: Decodable, Sendable {
    var id: GHID
    var body: String?
    var user: RESTUser?
    var createdAt: Date
    var updatedAt: Date?
    var htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, body, user
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case htmlURL = "html_url"
    }
}

struct RESTReview: Decodable, Sendable {
    var id: GHID
    var body: String?
    var state: String
    var user: RESTUser?
    var submittedAt: Date?
    var htmlURL: URL?
    var commitID: String?

    enum CodingKeys: String, CodingKey {
        case id, body, state, user
        case submittedAt = "submitted_at"
        case htmlURL = "html_url"
        case commitID = "commit_id"
    }
}

struct RESTPullFile: Decodable, Sendable {
    var filename: String
    var previousFilename: String?
    var status: String
    var additions: Int?
    var deletions: Int?
    var patch: String?

    enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, patch
        case previousFilename = "previous_filename"
    }
}

struct RESTCheckRun: Decodable, Sendable {
    struct Output: Decodable, Sendable {
        var title: String?
        var summary: String?
        var text: String?
    }

    var id: GHID
    var name: String
    var htmlURL: URL?
    var detailsURL: URL?
    var output: Output?

    enum CodingKeys: String, CodingKey {
        case id, name, output
        case htmlURL = "html_url"
        case detailsURL = "details_url"
    }
}

/// `{ "body": … }` write payload.
struct RESTBodyPayload: Encodable, Sendable {
    var body: String
}

/// `POST /pulls/{n}/reviews` payload.
struct RESTReviewPayload: Encodable, Sendable {
    var body: String
    var event: String
    var commitID: String?

    enum CodingKeys: String, CodingKey {
        case body, event
        case commitID = "commit_id"
    }
}

/// `PUT /pulls/{n}/merge` payload.
struct RESTMergePayload: Encodable, Sendable {
    var sha: String
}
