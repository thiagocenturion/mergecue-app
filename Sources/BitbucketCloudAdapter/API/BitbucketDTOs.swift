import Foundation

// Provider-native Bitbucket Cloud REST 2.0 payloads. Only the fields MergeCue reads are declared; everything is
// optional where Bitbucket may omit or null it so a partial object never fails a whole listing.

struct BBPage<Value: Decodable>: Decodable {
    var values: [Value]
    var next: String?

    private enum CodingKeys: String, CodingKey { case values, next }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = try c.decodeIfPresent([Value].self, forKey: .values) ?? []
        next = try c.decodeIfPresent(String.self, forKey: .next)
    }
}

struct BBLink: Decodable, Sendable {
    var href: String?
    var name: String?
}

struct BBText: Decodable, Sendable {
    var raw: String?
}

struct BBAccount: Decodable, Sendable {
    struct Links: Decodable, Sendable { var avatar: BBLink?; var html: BBLink? }

    var type: String?
    var uuid: String?
    var nickname: String?
    var username: String?
    var displayName: String?
    var accountID: String?
    var links: Links?

    private enum CodingKeys: String, CodingKey {
        case type, uuid, nickname, username, links
        case displayName = "display_name"
        case accountID = "account_id"
    }
}

struct BBWorkspace: Decodable, Sendable {
    var uuid: String?
    var slug: String
    var name: String?
}

struct BBWorkspaceAccess: Decodable, Sendable {
    var workspace: BBWorkspace
    var administrator: Bool?
}

struct BBBranch: Decodable, Sendable {
    var name: String?
}

struct BBCommitRef: Decodable, Sendable {
    var hash: String?
}

struct BBRepository: Decodable, Sendable {
    struct Links: Decodable, Sendable {
        var html: BBLink?
        var clone: [BBLink]?
    }

    var uuid: String?
    var fullName: String?
    var name: String?
    var isPrivate: Bool?
    var links: Links?
    var mainbranch: BBBranch?
    var updatedOn: String?

    private enum CodingKeys: String, CodingKey {
        case uuid, name, links, mainbranch
        case fullName = "full_name"
        case isPrivate = "is_private"
        case updatedOn = "updated_on"
    }
}

struct BBEndpoint: Decodable, Sendable {
    var repository: BBRepository?
    var branch: BBBranch?
    var commit: BBCommitRef?
}

struct BBParticipant: Decodable, Sendable {
    var user: BBAccount?
    var role: String?
    var approved: Bool?
    var state: String?
    var participatedOn: Date?

    private enum CodingKeys: String, CodingKey {
        case user, role, approved, state
        case participatedOn = "participated_on"
    }
}

struct BBPullRequest: Decodable, Sendable {
    struct Links: Decodable, Sendable {
        var html: BBLink?
        var api: BBLink?

        private enum CodingKeys: String, CodingKey {
            case html
            case api = "self"
        }
    }

    var id: Int
    var title: String?
    var description: String?
    var summary: BBText?
    var state: String?
    var author: BBAccount?
    var source: BBEndpoint?
    var destination: BBEndpoint?
    var createdOn: Date?
    var updatedOn: String?
    var reviewers: [BBAccount]?
    var participants: [BBParticipant]?
    var draft: Bool?
    var links: Links?
    var taskCount: Int?
    var commentCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, title, description, summary, state, author, source, destination, reviewers, participants, draft, links
        case createdOn = "created_on"
        case updatedOn = "updated_on"
        case taskCount = "task_count"
        case commentCount = "comment_count"
    }
}

struct BBInline: Decodable, Sendable {
    var path: String?
    var from: Int?
    var to: Int?
    var startFrom: Int?
    var startTo: Int?
    var outdated: Bool?

    private enum CodingKeys: String, CodingKey {
        case path, from, to, outdated
        case startFrom = "start_from"
        case startTo = "start_to"
    }
}

struct BBCommentRef: Decodable, Sendable {
    var id: Int?
}

struct BBResolution: Decodable, Sendable {
    var user: BBAccount?
    var createdOn: Date?

    private enum CodingKeys: String, CodingKey {
        case user
        case createdOn = "created_on"
    }
}

struct BBComment: Decodable, Sendable {
    struct Links: Decodable, Sendable { var html: BBLink?; var code: BBLink? }

    var id: Int
    var createdOn: Date
    var updatedOn: Date?
    var content: BBText?
    var user: BBAccount?
    var deleted: Bool?
    var pending: Bool?
    var parent: BBCommentRef?
    var inline: BBInline?
    var resolution: BBResolution?
    var links: Links?

    private enum CodingKeys: String, CodingKey {
        case id, content, user, deleted, pending, parent, inline, resolution, links
        case createdOn = "created_on"
        case updatedOn = "updated_on"
    }
}

struct BBTask: Decodable, Sendable {
    var id: Int
    var state: String?
    var pending: Bool?
    var content: BBText?
}

struct BBCommitStatus: Decodable, Sendable {
    struct Links: Decodable, Sendable { var commit: BBLink? }

    var key: String?
    var name: String?
    var state: String?
    var url: String?
    var description: String?
    var createdOn: Date?
    var updatedOn: Date?
    var links: Links?

    private enum CodingKeys: String, CodingKey {
        case key, name, state, url, description, links
        case createdOn = "created_on"
        case updatedOn = "updated_on"
    }
}

struct BBPipelineState: Decodable, Sendable {
    struct Result: Decodable, Sendable { var name: String? }
    var name: String?
    var result: Result?
    /// Present on IN_PROGRESS pipelines (`RUNNING`, `PAUSED`, …).
    var stage: Result?
}

struct BBPipeline: Decodable, Sendable {
    struct Selector: Decodable, Sendable { var type: String?; var pattern: String? }
    struct Target: Decodable, Sendable {
        var commit: BBCommitRef?
        var refName: String?
        var selector: Selector?

        private enum CodingKeys: String, CodingKey {
            case commit, selector
            case refName = "ref_name"
        }
    }

    var uuid: String
    var buildNumber: Int?
    var state: BBPipelineState?
    var target: Target?
    var createdOn: Date?
    var completedOn: Date?

    private enum CodingKeys: String, CodingKey {
        case uuid, state, target
        case buildNumber = "build_number"
        case createdOn = "created_on"
        case completedOn = "completed_on"
    }
}

struct BBPipelineStep: Decodable, Sendable {
    var uuid: String
    var name: String?
    var state: BBPipelineState?
    var startedOn: Date?
    var completedOn: Date?

    private enum CodingKeys: String, CodingKey {
        case uuid, name, state
        case startedOn = "started_on"
        case completedOn = "completed_on"
    }
}

struct BBCommit: Decodable, Sendable {
    struct Author: Decodable, Sendable { var raw: String?; var user: BBAccount? }
    var hash: String
    var message: String?
    var date: Date?
    var author: Author?
}

struct BBDiffStat: Decodable, Sendable {
    struct File: Decodable, Sendable { var path: String? }
    var status: String?
    var linesAdded: Int?
    var linesRemoved: Int?
    var old: File?
    var new: File?

    private enum CodingKeys: String, CodingKey {
        case status, old, new
        case linesAdded = "lines_added"
        case linesRemoved = "lines_removed"
    }
}

// MARK: - Request bodies

struct BBCommentBody: Encodable, Sendable {
    struct Content: Encodable, Sendable { var raw: String }
    struct Parent: Encodable, Sendable { var id: Int }
    var content: Content
    var parent: Parent?
}
