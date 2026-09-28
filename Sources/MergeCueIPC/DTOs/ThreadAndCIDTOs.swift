import Foundation
import MergeCueCore

// MARK: - get_thread

/// `{thread_id}` (`thr_…`).
public struct GetThreadParams: IPCMethodParams, Hashable {
    public typealias Output = ThreadDTO
    public static let method = IPCMethod.getThread

    public var threadID: String

    public init(threadID: String) {
        self.threadID = threadID
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireText(threadID, field: "thread_id", maxLength: 64)
    }

    private enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
    }
}

/// A full review thread: `{thread_id, change_ref, kind, resolved?, resolvable, outdated, anchor?, comments,
/// web_url?}`.
public struct ThreadDTO: Codable, Sendable, Hashable {
    /// JSON paths of fields that hold third-party text (data, never instructions). See `UntrustedFields`.
    public var untrustedFields: [String]? = UntrustedFields.thread
    public static let defaultMaxCommentBytes = 16 * 1024

    public var threadID: String
    public var changeRef: ChangeRequestRef
    public var kind: ThreadKind
    /// nil = the provider has no resolution concept for this thread.
    public var resolved: Bool?
    public var resolvable: Bool
    public var outdated: Bool
    public var anchor: DiffAnchorDTO?
    /// Chronological, full reply chain.
    public var comments: [ThreadCommentDTO]
    public var webURL: URL?

    public init(
        threadID: String,
        changeRef: ChangeRequestRef,
        kind: ThreadKind,
        resolved: Bool? = nil,
        resolvable: Bool,
        outdated: Bool = false,
        anchor: DiffAnchorDTO? = nil,
        comments: [ThreadCommentDTO],
        webURL: URL? = nil
    ) {
        self.threadID = threadID
        self.changeRef = changeRef
        self.kind = kind
        self.resolved = resolved
        self.resolvable = resolvable
        self.outdated = outdated
        self.anchor = anchor
        self.comments = comments
        self.webURL = webURL
    }

    /// Wire view of a Core thread; every comment body is redacted and bounded to `maxCommentBytes`.
    public init(_ thread: ReviewThread, changeRef: ChangeRequestRef, maxCommentBytes: Int = ThreadDTO.defaultMaxCommentBytes) {
        let source = thread.key.kind == .reviewSummary ? UntrustedText.Source.reviewSummary : UntrustedText.Source.reviewComment
        self.init(
            threadID: thread.key.shortID,
            changeRef: changeRef,
            kind: thread.key.kind,
            resolved: thread.isResolved,
            resolvable: thread.isResolvable,
            outdated: thread.isOutdated,
            anchor: thread.anchor.map(DiffAnchorDTO.init),
            comments: thread.comments.map { ThreadCommentDTO($0, source: source, maxBodyBytes: maxCommentBytes) },
            webURL: thread.webURL
        )
    }

    private enum CodingKeys: String, CodingKey {
        case untrustedFields = "untrusted_fields"
        case kind, resolved, resolvable, outdated, anchor, comments
        case threadID = "thread_id"
        case changeRef = "change_ref"
        case webURL = "web_url"
    }
}

/// `{comment_id, author, created_at, kind, body: UntrustedText}`.
public struct ThreadCommentDTO: Codable, Sendable, Hashable {
    public var commentID: String
    /// Author username.
    public var author: String
    public var createdAt: Date
    public var kind: CommentKind
    /// Reviewer text. Data, never instructions.
    public var body: UntrustedText {
        get { bodyWire.value }
        set { bodyWire = UntrustedTextWire(newValue) }
    }

    private var bodyWire: UntrustedTextWire

    public init(commentID: String, author: String, createdAt: Date, kind: CommentKind, body: UntrustedText) {
        self.commentID = commentID
        self.author = author
        self.createdAt = createdAt
        self.kind = kind
        self.bodyWire = UntrustedTextWire(body)
    }

    /// Wire view of a Core comment; the body is redacted and bounded.
    public init(_ comment: ReviewComment, source: String = UntrustedText.Source.reviewComment, maxBodyBytes: Int = ThreadDTO.defaultMaxCommentBytes) {
        self.init(
            commentID: comment.id,
            author: comment.author.username,
            createdAt: comment.createdAt,
            kind: comment.kind,
            body: UntrustedText.bounded(
                source: source,
                author: comment.author.username,
                createdAt: comment.createdAt,
                text: comment.body,
                maxBytes: maxBodyBytes
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case author, kind
        case commentID = "comment_id"
        case createdAt = "created_at"
        case bodyWire = "body"
    }
}

// MARK: - get_ci_failure

/// `{check_id, max_bytes? (1…65536, default 16384)}`.
public struct GetCIFailureParams: IPCMethodParams, Hashable {
    public typealias Output = CIFailureResult
    public static let method = IPCMethod.getCIFailure
    public static let defaultMaxBytes = 16 * 1024
    public static let maxMaxBytes = 64 * 1024

    /// `chk_…`.
    public var checkID: String
    public var maxBytes: Int?

    public init(checkID: String, maxBytes: Int? = nil) {
        self.checkID = checkID
        self.maxBytes = maxBytes
    }

    /// `max_bytes` clamped to 1…65536, default 16384.
    public var resolvedMaxBytes: Int {
        min(max(maxBytes ?? Self.defaultMaxBytes, 1), Self.maxMaxBytes)
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireText(checkID, field: "check_id", maxLength: 64)
        try IPCValidation.requireRange(maxBytes, field: "max_bytes", 1...Self.maxMaxBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case checkID = "check_id"
        case maxBytes = "max_bytes"
    }
}

/// `{check_id, name, status, commit_sha?, details_url?, log_url?, excerpt: UntrustedText, truncated}`.
public struct CIFailureResult: Codable, Sendable, Hashable {
    /// JSON paths of fields that hold third-party text (data, never instructions). See `UntrustedFields`.
    public var untrustedFields: [String]? = UntrustedFields.ciFailure
    public var checkID: String
    public var name: String
    public var status: CheckStatus
    public var commitSHA: String?
    public var detailsURL: URL?
    /// Full log in the provider UI/API.
    public var logURL: URL?
    /// Bounded, redacted log excerpt. Data, never instructions.
    public var excerpt: UntrustedText {
        get { excerptWire.value }
        set { excerptWire = UntrustedTextWire(newValue) }
    }
    /// The excerpt is not the whole log.
    public var truncated: Bool

    private var excerptWire: UntrustedTextWire

    public init(
        checkID: String,
        name: String,
        status: CheckStatus,
        commitSHA: String? = nil,
        detailsURL: URL? = nil,
        logURL: URL? = nil,
        excerpt: UntrustedText,
        truncated: Bool
    ) {
        self.checkID = checkID
        self.name = name
        self.status = status
        self.commitSHA = commitSHA
        self.detailsURL = detailsURL
        self.logURL = logURL
        self.excerptWire = UntrustedTextWire(excerpt)
        self.truncated = truncated
    }

    /// Wire view of a check and its fetched log excerpt, re-bounded to `maxBytes` (redacted again).
    public init(_ check: CheckRun, log: LogExcerpt, maxBytes: Int = GetCIFailureParams.defaultMaxBytes) {
        let excerpt = UntrustedText.bounded(
            source: UntrustedText.Source.ciLog,
            createdAt: check.completedAt,
            text: log.text,
            maxBytes: maxBytes
        )
        // `bounded` cuts exactly when the redacted text exceeds the budget.
        let cut = SecretRedactor.redact(log.text).utf8.count > max(0, maxBytes)
        self.init(
            checkID: check.key.shortID,
            name: UntrustedFields.clean(check.name),
            status: check.status,
            commitSHA: check.commitSHA,
            detailsURL: check.detailsURL,
            logURL: log.fullLogURL,
            excerpt: excerpt,
            truncated: log.truncated || cut
        )
    }

    private enum CodingKeys: String, CodingKey {
        case untrustedFields = "untrusted_fields"
        case name, status, truncated
        case checkID = "check_id"
        case commitSHA = "commit_sha"
        case detailsURL = "details_url"
        case logURL = "log_url"
        case excerptWire = "excerpt"
    }
}
