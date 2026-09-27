import Foundation

/// Identity of a connected account: provider kind + instance host + the provider's immutable user id.
///
/// `id` example: `v1/github/github.com/u:123`.
public struct AccountKey: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let kind: ProviderKind
    /// Lowercased instance host (see `ProviderInstance.host`).
    public let host: String
    /// Immutable remote user id (GitHub numeric id, GitLab user id, Bitbucket account uuid).
    public let remoteUserID: String

    public init(kind: ProviderKind, host: String, remoteUserID: String) {
        self.kind = kind
        self.host = host.lowercased()
        self.remoteUserID = remoteUserID
    }

    public init(instance: ProviderInstance, remoteUserID: String) {
        self.init(kind: instance.kind, host: instance.host, remoteUserID: remoteUserID)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(ProviderKind.self, forKey: .kind),
            host: try container.decode(String.self, forKey: .host),
            remoteUserID: try container.decode(String.self, forKey: .remoteUserID)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind, host, remoteUserID
    }

    /// Stable primary key.
    public var id: String {
        "\(StableID.version)/\(kind.rawValue)/\(StableID.encode(host))/u:\(StableID.encode(remoteUserID))"
    }

    public var description: String { id }

    public static func < (lhs: AccountKey, rhs: AccountKey) -> Bool {
        lhs.id < rhs.id
    }
}

/// Identity of a repository as seen by one account. `remoteRepoID` is immutable: GitHub repository id,
/// GitLab project id, Bitbucket repository uuid (`{…}`).
public struct RepoKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public let account: AccountKey
    public let remoteRepoID: String

    public init(account: AccountKey, remoteRepoID: String) {
        self.account = account
        self.remoteRepoID = remoteRepoID
    }

    /// Stable primary key, e.g. `v1/github/github.com/u:123/r:456`.
    public var id: String {
        "\(account.id)/r:\(StableID.encode(remoteRepoID))"
    }

    /// `repo_` + 10 hex.
    public var shortID: String {
        ShortID.make(prefix: ShortID.repositoryPrefix, from: id)
    }

    public var kind: ProviderKind { account.kind }
    public var description: String { id }
}

/// Identity of a pull/merge request.
///
/// `remoteID`: GitHub PR id, GitLab MR global id, Bitbucket PR id. `number`: GitHub number, GitLab iid,
/// Bitbucket id. Only `remoteID` participates in `id`; `number` is the human-facing value. Equality and hashing
/// follow `id` — (`repo`, `remoteID`) — so a key rebuilt with a stale or placeholder `number` still finds the
/// same row, `Set` element or snapshot thread/check.
public struct ChangeRequestKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public let repo: RepoKey
    public let remoteID: String
    public let number: Int

    public init(repo: RepoKey, remoteID: String, number: Int) {
        self.repo = repo
        self.remoteID = remoteID
        self.number = number
    }

    /// Stable primary key, e.g. `v1/github/github.com/u:123/r:456/cr:789`.
    public var id: String {
        "\(repo.id)/cr:\(StableID.encode(remoteID))"
    }

    /// `cr_` + 10 hex.
    public var shortID: String {
        ShortID.make(prefix: ShortID.changeRequestPrefix, from: id)
    }

    public var account: AccountKey { repo.account }
    public var kind: ProviderKind { repo.account.kind }
    public var description: String { id }

    public static func == (lhs: ChangeRequestKey, rhs: ChangeRequestKey) -> Bool {
        lhs.repo == rhs.repo && lhs.remoteID == rhs.remoteID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(repo)
        hasher.combine(remoteID)
    }
}

/// How a review thread is anchored on the provider.
public enum ThreadKind: String, Codable, Sendable, CaseIterable {
    /// Line/file anchored review thread.
    case diffThread = "diff"
    /// Change-request level conversation (GitHub issue comment, GitLab/Bitbucket general comment).
    case conversation
    /// Body of a submitted review (GitHub review summary).
    case reviewSummary = "review_summary"
}

/// Identity of a review thread.
///
/// GitHub: review thread node id (`PRRT_…`) for diff threads, `ic:<issue comment id>` for issue-level comments,
/// `rv:<review id>` for review bodies (build those with `githubIssueComment` / `githubReviewSummary`).
/// GitLab: discussion id. Bitbucket: root comment id.
public struct ThreadKey: Codable, Sendable, Hashable, CustomStringConvertible {
    /// `remoteID` prefix of a GitHub issue-level comment thread.
    public static let githubIssueCommentPrefix = "ic:"
    /// `remoteID` prefix of a GitHub review body thread.
    public static let githubReviewSummaryPrefix = "rv:"

    public let changeRequest: ChangeRequestKey
    public let remoteID: String
    public let kind: ThreadKind

    public init(changeRequest: ChangeRequestKey, remoteID: String, kind: ThreadKind) {
        self.changeRequest = changeRequest
        self.remoteID = remoteID
        self.kind = kind
    }

    /// Stable primary key, e.g. `…/cr:789/th:diff:PRRT_abc`.
    public var id: String {
        "\(changeRequest.id)/th:\(kind.rawValue):\(StableID.encode(remoteID))"
    }

    /// `thr_` + 10 hex.
    public var shortID: String {
        ShortID.make(prefix: ShortID.threadPrefix, from: id)
    }

    public var description: String { id }

    /// GitHub issue-level comment (a `.conversation` thread keyed `ic:<comment id>`).
    public static func githubIssueComment(changeRequest: ChangeRequestKey, commentID: String) -> ThreadKey {
        ThreadKey(changeRequest: changeRequest, remoteID: githubIssueCommentPrefix + commentID, kind: .conversation)
    }

    /// GitHub review body (a `.reviewSummary` thread keyed `rv:<review id>`).
    public static func githubReviewSummary(changeRequest: ChangeRequestKey, reviewID: String) -> ThreadKey {
        ThreadKey(changeRequest: changeRequest, remoteID: githubReviewSummaryPrefix + reviewID, kind: .reviewSummary)
    }
}

/// Where a CI check came from on the provider.
public enum CheckSource: String, Codable, Sendable, CaseIterable {
    case githubCheckRun, githubStatus, githubActionsJob, gitlabPipeline, gitlabJob, bitbucketStatus, bitbucketPipelineStep
}

/// Identity of a CI check (check run, status context, job, pipeline step).
public struct CheckKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public let changeRequest: ChangeRequestKey
    public let source: CheckSource
    public let remoteID: String

    public init(changeRequest: ChangeRequestKey, source: CheckSource, remoteID: String) {
        self.changeRequest = changeRequest
        self.source = source
        self.remoteID = remoteID
    }

    /// Stable primary key, e.g. `…/cr:789/ck:githubCheckRun:555`.
    public var id: String {
        "\(changeRequest.id)/ck:\(source.rawValue):\(StableID.encode(remoteID))"
    }

    /// `chk_` + 10 hex.
    public var shortID: String {
        ShortID.make(prefix: ShortID.checkPrefix, from: id)
    }

    public var description: String { id }
}
