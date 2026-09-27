import Foundation

/// Which side of a diff a line comment refers to.
public enum DiffSide: String, Codable, Sendable, CaseIterable {
    case old, new
}

/// Position of a line comment, recorded with the commit SHAs and provider-native position data.
public struct DiffAnchor: Codable, Sendable, Hashable {
    public var path: String
    public var oldPath: String?
    public var line: Int?
    public var startLine: Int?
    public var side: DiffSide
    public var commitSHA: String?
    public var originalCommitSHA: String?
    /// GitLab diff version id.
    public var diffVersionID: String?
    /// Bounded diff hunk context.
    public var diffHunk: String?
    /// True after a force-push/rebase moved the anchored code.
    public var isOutdated: Bool
    /// Opaque provider position fields for traceability and replies.
    public var nativePosition: [String: String]

    public init(
        path: String,
        oldPath: String? = nil,
        line: Int? = nil,
        startLine: Int? = nil,
        side: DiffSide = .new,
        commitSHA: String? = nil,
        originalCommitSHA: String? = nil,
        diffVersionID: String? = nil,
        diffHunk: String? = nil,
        isOutdated: Bool = false,
        nativePosition: [String: String] = [:]
    ) {
        self.path = path
        self.oldPath = oldPath
        self.line = line
        self.startLine = startLine
        self.side = side
        self.commitSHA = commitSHA
        self.originalCommitSHA = originalCommitSHA
        self.diffVersionID = diffVersionID
        self.diffHunk = diffHunk
        self.isOutdated = isOutdated
        self.nativePosition = nativePosition
    }
}

/// Semantic class of a comment.
public enum CommentKind: String, Codable, Sendable, CaseIterable {
    case comment, question, suggestion, system

    /// Shared heuristic used by adapters and sync: a ```` ```suggestion ```` fence → `.suggestion`; a question
    /// mark ending any line outside quotes/code fences → `.question`; otherwise `.comment`.
    public static func classify(body: String, isSystem: Bool = false) -> CommentKind {
        if isSystem { return .system }
        if body.range(of: "```suggestion", options: .caseInsensitive) != nil { return .suggestion }
        var inFence = false
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence || line.hasPrefix(">") { continue }
            if line.hasSuffix("?") { return .question }
        }
        return .comment
    }
}

/// A single comment inside a thread. `body` is untrusted input.
public struct ReviewComment: Codable, Sendable, Hashable, Identifiable {
    /// Remote comment id.
    public var id: String
    public var author: Person
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date?
    public var webURL: URL?
    public var kind: CommentKind
    public var inReplyToID: String?

    public init(
        id: String,
        author: Person,
        body: String,
        createdAt: Date,
        updatedAt: Date? = nil,
        webURL: URL? = nil,
        kind: CommentKind = .comment,
        inReplyToID: String? = nil
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.webURL = webURL
        self.kind = kind
        self.inReplyToID = inReplyToID
    }
}

/// A review thread with its full, chronological reply chain.
public struct ReviewThread: Codable, Sendable, Hashable, Identifiable {
    public var key: ThreadKey
    public var anchor: DiffAnchor?
    /// nil = the provider has no resolution concept for this thread.
    public var isResolved: Bool?
    public var isResolvable: Bool
    public var comments: [ReviewComment]
    public var webURL: URL?
    public var lastActivityAt: Date

    public init(
        key: ThreadKey,
        anchor: DiffAnchor? = nil,
        isResolved: Bool? = nil,
        isResolvable: Bool = false,
        comments: [ReviewComment],
        webURL: URL? = nil,
        lastActivityAt: Date
    ) {
        self.key = key
        self.anchor = anchor
        self.isResolved = isResolved
        self.isResolvable = isResolvable
        self.comments = comments
        self.webURL = webURL
        self.lastActivityAt = lastActivityAt
    }

    public var id: String { key.id }
    public var isOutdated: Bool { anchor?.isOutdated ?? false }
    public var rootComment: ReviewComment? { comments.first }
    public var latestComment: ReviewComment? { comments.last }
    /// Unresolved means the provider reports `isResolved == false` (threads without resolution never count).
    public var isUnresolved: Bool { isResolved == false }
}
