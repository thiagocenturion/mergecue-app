import Foundation
import MergeCueNetworking

// Provider-native GitLab REST v4 payloads (https://docs.gitlab.com/api/). Decoded with
// `GitLabJSON.decoder()` (snake_case keys → camelCase properties). Only fields MergeCue uses are declared; every
// field that GitLab documents as optional or tier/version dependent is optional here.

/// JSON decoding configuration for GitLab payloads.
enum GitLabJSON {
    /// `JSONDecoder.mergeCueProvider` (ISO-8601 dates with/without fractions) + snake_case key conversion.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder.mergeCueProvider
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// `GET /user`, and the user objects embedded in merge requests, notes, approvals, reviewers.
struct GLUser: Decodable, Sendable, Hashable {
    var id: Int
    var username: String
    var name: String?
    var avatarUrl: String?
    var webUrl: String?
    var bot: Bool?
    var email: String?
    var publicEmail: String?
}

/// `GET /personal_access_tokens/self` (only works for personal access tokens).
struct GLTokenInfo: Decodable, Sendable {
    var scopes: [String]?
    var active: Bool?
}

/// `GET /groups`.
struct GLGroup: Decodable, Sendable {
    var id: Int
    var name: String
    var path: String
    var fullPath: String
    var fullName: String?
}

/// Namespace object embedded in projects.
struct GLNamespaceRef: Decodable, Sendable {
    var id: Int?
    var name: String?
    var path: String?
    var kind: String?
    var fullPath: String?
}

/// `GET /projects/:id`, `GET /projects?simple=true`.
struct GLProject: Decodable, Sendable {
    struct ForkParent: Decodable, Sendable {
        var id: Int
        var pathWithNamespace: String?
    }

    var id: Int
    var name: String?
    var path: String
    var pathWithNamespace: String
    var namespace: GLNamespaceRef?
    var webUrl: String
    var httpUrlToRepo: String?
    var sshUrlToRepo: String?
    var defaultBranch: String?
    /// Absent from `simple=true` listings.
    var visibility: String?
    var forkedFromProject: ForkParent?
    var archived: Bool?
}

struct GLReferences: Decodable, Sendable {
    var short: String?
    var relative: String?
    var full: String?
}

struct GLDiffRefs: Decodable, Sendable {
    var baseSha: String?
    var headSha: String?
    var startSha: String?
}

/// Pipeline object (`head_pipeline` of a merge request, `pipeline` of a job).
struct GLPipeline: Decodable, Sendable {
    var id: Int
    var iid: Int?
    var projectId: Int?
    var sha: String?
    var ref: String?
    var status: String
    var webUrl: String?
    var createdAt: Date?
    var updatedAt: Date?
    var startedAt: Date?
    var finishedAt: Date?
}

/// Merge request as returned by the list and single-MR endpoints.
struct GLMergeRequest: Decodable, Sendable {
    /// Global id (`ChangeRequestKey.remoteID`).
    var id: Int
    /// Project-scoped id (`ChangeRequestKey.number`, used in every URL together with the target project id).
    var iid: Int
    /// Target project id.
    var projectId: Int
    var title: String
    var description: String?
    /// `opened`, `closed`, `locked`, `merged`.
    var state: String
    var createdAt: Date
    /// Kept as text: it is the cheap change detector (`versionToken`) and must round-trip exactly.
    var updatedAt: String
    var targetBranch: String
    var sourceBranch: String
    var author: GLUser
    var assignees: [GLUser]?
    var reviewers: [GLUser]?
    var sourceProjectId: Int?
    var targetProjectId: Int?
    var draft: Bool?
    /// Deprecated alias of `draft` (older instances).
    var workInProgress: Bool?
    var mergeStatus: String?
    var detailedMergeStatus: String?
    var sha: String?
    var webUrl: String
    var references: GLReferences?
    var hasConflicts: Bool?
    var blockingDiscussionsResolved: Bool?
    var diffRefs: GLDiffRefs?
    var headPipeline: GLPipeline?
}

/// `GET /events?action=commented` — the current user's own contribution events (only the fields used to find the
/// merge requests they commented on).
struct GLEvent: Decodable, Sendable {
    var projectId: Int?
    /// `Note`, `DiffNote`, `DiscussionNote`, `MergeRequest`, …
    var targetType: String?
    var note: GLEventNote?
}

struct GLEventNote: Decodable, Sendable {
    /// `MergeRequest`, `Issue`, `Commit`, `Snippet`.
    var noteableType: String?
    var noteableIid: Int?
}

/// `GET …/discussions`.
struct GLDiscussion: Decodable, Sendable {
    var id: String
    var individualNote: Bool
    var notes: [GLNote]
}

struct GLNote: Decodable, Sendable {
    var id: Int
    /// `DiscussionNote`, `DiffNote` or null.
    var type: String?
    var body: String
    var author: GLUser
    var createdAt: Date
    var updatedAt: Date?
    var system: Bool?
    var resolvable: Bool?
    var resolved: Bool?
    var position: GLPosition?
    var originalPosition: GLPosition?
    var commitId: String?
}

struct GLPosition: Decodable, Sendable {
    struct LineRange: Decodable, Sendable {
        struct End: Decodable, Sendable {
            var lineCode: String?
            var type: String?
            var oldLine: Int?
            var newLine: Int?
        }

        var start: End?
        var end: End?
    }

    var baseSha: String?
    var startSha: String?
    var headSha: String?
    var oldPath: String?
    var newPath: String?
    var positionType: String?
    var oldLine: Int?
    var newLine: Int?
    var lineRange: LineRange?
}

/// `GET …/approvals`.
struct GLApprovals: Decodable, Sendable {
    struct ApprovedBy: Decodable, Sendable {
        var user: GLUser
        var approvedAt: Date?
    }

    var approvalsRequired: Int?
    var approvalsLeft: Int?
    var approved: Bool?
    var approvedBy: [ApprovedBy]?
}

/// `GET …/reviewers`.
struct GLReviewerEntry: Decodable, Sendable {
    var user: GLUser
    /// `unreviewed`, `review_started`, `reviewed`, `requested_changes`, `approved`, `unapproved`.
    var state: String?
    var createdAt: Date?
}

/// `GET /projects/:id/pipelines/:pipeline_id/jobs`.
struct GLJob: Decodable, Sendable {
    var id: Int
    var name: String
    var stage: String?
    var status: String
    var allowFailure: Bool?
    var createdAt: Date?
    var startedAt: Date?
    var finishedAt: Date?
    var webUrl: String?
    var failureReason: String?
    var pipeline: GLPipeline?
}

/// `GET …/commits`.
struct GLCommit: Decodable, Sendable {
    var id: String
    var shortId: String?
    var title: String
    var authorName: String?
    var authoredDate: Date?
}

/// `GET …/diffs`.
struct GLDiffFile: Decodable, Sendable {
    var oldPath: String
    var newPath: String
    var aMode: String?
    var bMode: String?
    var diff: String?
    var newFile: Bool
    var renamedFile: Bool
    var deletedFile: Bool
    var collapsed: Bool?
    var tooLarge: Bool?
}

/// `GET …/versions`.
struct GLVersion: Decodable, Sendable {
    var id: Int
    var headCommitSha: String?
    var baseCommitSha: String?
    var startCommitSha: String?
    var createdAt: Date?
}

/// `GET …/draft_notes` (only the id matters: pending drafts block `requestChanges`).
struct GLDraftNote: Decodable, Sendable {
    var id: Int
}

// MARK: Write bodies

struct GLNoteBody: Encodable, Sendable {
    var body: String
}

struct GLResolveBody: Encodable, Sendable {
    var resolved: Bool
}

struct GLMergeBody: Encodable, Sendable {
    var sha: String
}

struct GLBulkPublishBody: Encodable, Sendable {
    var note: String
    var reviewerState: String

    enum CodingKeys: String, CodingKey {
        case note
        case reviewerState = "reviewer_state"
    }
}
