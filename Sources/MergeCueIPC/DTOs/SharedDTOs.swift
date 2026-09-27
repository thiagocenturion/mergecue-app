import Foundation
import MergeCueCore

// Building blocks shared by several method DTOs. Every DTO uses explicit snake_case `CodingKeys`, omits nil
// optionals, and encodes dates with the wire coders (`IPCCoding`). IDs are short IDs (`thr_…`, `chk_…`, `art_…`,
// `att_…`, `mc_…`) and `change_ref` strings.

// MARK: - Wire adapters for Core types whose own Codable form is not the wire form

/// Wire form of Core's `UntrustedText`: `{source, author?, created_at?, text}`. DTOs expose `UntrustedText`
/// itself and store this adapter privately, so the Swift API reuses the Core type while the JSON stays snake_case.
struct UntrustedTextWire: Codable, Sendable, Hashable {
    var value: UntrustedText

    init(_ value: UntrustedText) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case source, author, text
        case createdAt = "created_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = UntrustedText(
            source: try container.decode(String.self, forKey: .source),
            author: try container.decodeIfPresent(String.self, forKey: .author),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt),
            text: try container.decode(String.self, forKey: .text)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.source, forKey: .source)
        try container.encodeIfPresent(value.author, forKey: .author)
        try container.encodeIfPresent(value.createdAt, forKey: .createdAt)
        try container.encode(value.text, forKey: .text)
    }
}

/// `AttentionPriority` as its `name` (`low|normal|high|urgent`), never the Int raw value.
struct AttentionPriorityWire: Codable, Sendable, Hashable {
    var value: AttentionPriority

    init(_ value: AttentionPriority) {
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let priority = AttentionPriority(name: name) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown priority '\(name)' (expected low, normal, high or urgent)")
        }
        value = priority
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value.name)
    }
}

// MARK: - Diff anchors and files

/// Where a line comment points: `{path, old_path?, line?, start_line?, side, commit_sha?, original_commit_sha?,
/// outdated, diff_hunk?}`.
public struct DiffAnchorDTO: Codable, Sendable, Hashable {
    public var path: String
    public var oldPath: String?
    public var line: Int?
    public var startLine: Int?
    public var side: DiffSide
    public var commitSHA: String?
    public var originalCommitSHA: String?
    /// The anchored code moved (force-push/rebase) since the comment was written.
    public var outdated: Bool
    /// Bounded diff context around the anchor.
    public var diffHunk: String?

    public init(
        path: String,
        oldPath: String? = nil,
        line: Int? = nil,
        startLine: Int? = nil,
        side: DiffSide = .new,
        commitSHA: String? = nil,
        originalCommitSHA: String? = nil,
        outdated: Bool = false,
        diffHunk: String? = nil
    ) {
        self.path = path
        self.oldPath = oldPath
        self.line = line
        self.startLine = startLine
        self.side = side
        self.commitSHA = commitSHA
        self.originalCommitSHA = originalCommitSHA
        self.outdated = outdated
        self.diffHunk = diffHunk
    }

    /// Wire view of a Core anchor (provider-native position fields are not exposed).
    public init(_ anchor: DiffAnchor) {
        self.init(
            path: anchor.path,
            oldPath: anchor.oldPath,
            line: anchor.line,
            startLine: anchor.startLine,
            side: anchor.side,
            commitSHA: anchor.commitSHA,
            originalCommitSHA: anchor.originalCommitSHA,
            outdated: anchor.isOutdated,
            diffHunk: anchor.diffHunk
        )
    }

    private enum CodingKeys: String, CodingKey {
        case path, line, side, outdated
        case oldPath = "old_path"
        case startLine = "start_line"
        case commitSHA = "commit_sha"
        case originalCommitSHA = "original_commit_sha"
        case diffHunk = "diff_hunk"
    }
}

/// A changed file: `{path, old_path?, status, additions?, deletions?}`.
public struct ChangedFileDTO: Codable, Sendable, Hashable {
    public var path: String
    public var oldPath: String?
    public var status: FileChangeStatus
    public var additions: Int?
    public var deletions: Int?

    public init(path: String, oldPath: String? = nil, status: FileChangeStatus, additions: Int? = nil, deletions: Int? = nil) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }

    public init(_ file: ChangedFile) {
        self.init(path: file.path, oldPath: file.oldPath, status: file.status, additions: file.additions, deletions: file.deletions)
    }

    public init(_ path: ChangedPath) {
        self.init(path: path.path, status: path.status)
    }

    private enum CodingKeys: String, CodingKey {
        case path, status, additions, deletions
        case oldPath = "old_path"
    }
}

// MARK: - Checks, threads, reviews

/// Compact CI check: `{check_id, name, status}`.
public struct CheckSummaryDTO: Codable, Sendable, Hashable {
    /// `chk_…`.
    public var checkID: String
    public var name: String
    public var status: CheckStatus

    public init(checkID: String, name: String, status: CheckStatus) {
        self.checkID = checkID
        self.name = name
        self.status = status
    }

    public init(_ check: CheckRun) {
        self.init(checkID: check.key.shortID, name: check.name, status: check.status)
    }

    private enum CodingKeys: String, CodingKey {
        case name, status
        case checkID = "check_id"
    }
}

/// Compact review thread: `{thread_id, kind, path?, line?, resolved?, outdated, comment_count, last_author?}`.
public struct ThreadSummaryDTO: Codable, Sendable, Hashable {
    /// `thr_…`.
    public var threadID: String
    public var kind: ThreadKind
    public var path: String?
    public var line: Int?
    /// nil = the provider has no resolution concept for this thread.
    public var resolved: Bool?
    public var outdated: Bool
    public var commentCount: Int
    /// Username of the latest comment's author.
    public var lastAuthor: String?

    public init(
        threadID: String,
        kind: ThreadKind,
        path: String? = nil,
        line: Int? = nil,
        resolved: Bool? = nil,
        outdated: Bool = false,
        commentCount: Int,
        lastAuthor: String? = nil
    ) {
        self.threadID = threadID
        self.kind = kind
        self.path = path
        self.line = line
        self.resolved = resolved
        self.outdated = outdated
        self.commentCount = commentCount
        self.lastAuthor = lastAuthor
    }

    public init(_ thread: ReviewThread) {
        self.init(
            threadID: thread.key.shortID,
            kind: thread.key.kind,
            path: thread.anchor?.path,
            line: thread.anchor?.line,
            resolved: thread.isResolved,
            outdated: thread.isOutdated,
            commentCount: thread.comments.count,
            lastAuthor: thread.latestComment?.author.username
        )
    }

    private enum CodingKeys: String, CodingKey {
        case kind, path, line, resolved, outdated
        case threadID = "thread_id"
        case commentCount = "comment_count"
        case lastAuthor = "last_author"
    }
}

/// A submitted review: `{author, state, submitted_at?}` (the review body is exposed through `get_thread`).
public struct ReviewSummaryDTO: Codable, Sendable, Hashable {
    public var author: String
    public var state: ReviewState
    public var submittedAt: Date?

    public init(author: String, state: ReviewState, submittedAt: Date? = nil) {
        self.author = author
        self.state = state
        self.submittedAt = submittedAt
    }

    public init(_ review: Review) {
        self.init(author: review.author.username, state: review.state, submittedAt: review.submittedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case author, state
        case submittedAt = "submitted_at"
    }
}

// MARK: - Checkout

/// The checkout an agent must work in: `{policy, worktree_path?, mapped_checkout_path?, base_sha?,
/// source_branch, target_branch, gitbutler_managed, blocked_reason?}`.
public struct TaskCheckoutDTO: Codable, Sendable, Hashable {
    public var policy: CheckoutPolicy
    public var worktreePath: String?
    public var mappedCheckoutPath: String?
    public var baseSHA: String?
    public var sourceBranch: String
    public var targetBranch: String
    public var gitButlerManaged: Bool
    public var blockedReason: String?

    public init(
        policy: CheckoutPolicy,
        worktreePath: String? = nil,
        mappedCheckoutPath: String? = nil,
        baseSHA: String? = nil,
        sourceBranch: String,
        targetBranch: String,
        gitButlerManaged: Bool = false,
        blockedReason: String? = nil
    ) {
        self.policy = policy
        self.worktreePath = worktreePath
        self.mappedCheckoutPath = mappedCheckoutPath
        self.baseSHA = baseSHA
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.gitButlerManaged = gitButlerManaged
        self.blockedReason = blockedReason
    }

    public init(_ checkout: TaskCheckout) {
        self.init(
            policy: checkout.policy,
            worktreePath: checkout.worktreePath,
            mappedCheckoutPath: checkout.mappedCheckoutPath,
            baseSHA: checkout.baseSHA,
            sourceBranch: checkout.sourceBranch,
            targetBranch: checkout.targetBranch,
            gitButlerManaged: checkout.isGitButlerManaged,
            blockedReason: checkout.blockedReason
        )
    }

    private enum CodingKeys: String, CodingKey {
        case policy
        case worktreePath = "worktree_path"
        case mappedCheckoutPath = "mapped_checkout_path"
        case baseSHA = "base_sha"
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case gitButlerManaged = "gitbutler_managed"
        case blockedReason = "blocked_reason"
    }
}

// MARK: - Result aliases (one `<Method>Params` / `<Method>Result` pair per method)

public typealias GetTaskResult = TaskContextDTO
public typealias GetChangeContextResult = ChangeContextResult
public typealias GetThreadResult = ThreadDTO
public typealias GetCIFailureResult = CIFailureResult
