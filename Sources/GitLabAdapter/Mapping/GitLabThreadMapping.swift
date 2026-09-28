import Foundation
import MergeCueCore

/// GitLab discussions → `ReviewThread`s.
///
/// - Thread key = discussion id. A discussion whose first note is a `DiffNote` is a `.diffThread` anchored by its
///   `position`; everything else (threaded `DiscussionNote`s, individual notes, system notes) is `.conversation`.
/// - Resolution: a thread is resolvable when any of its notes is `resolvable`; it is resolved when every
///   resolvable note is `resolved`. Non-resolvable threads report `isResolved == nil`.
/// - System notes ("added 1 commit", "requested changes") are kept, with `CommentKind.system`.
/// - Outdated: the position's `head_sha` differs from the merge request's current head.
struct GitLabThreadContext: Sendable {
    var changeRequest: ChangeRequestKey
    /// Merge request web URL (`…/-/merge_requests/<iid>`), used for `#note_<id>` links.
    var webURL: URL?
    var currentHeadSHA: String?
    var versions: [GLVersion]
}

enum GitLabThreadMapping {
    static func threads(_ discussions: [GLDiscussion], context: GitLabThreadContext) -> [ReviewThread] {
        discussions.compactMap { thread($0, context: context) }
    }

    static func thread(_ discussion: GLDiscussion, context: GitLabThreadContext) -> ReviewThread? {
        let notes = discussion.notes.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        guard let first = notes.first else { return nil }
        let diffNote = notes.first { $0.type == "DiffNote" && $0.position != nil }
        let isDiffThread = first.type == "DiffNote" && diffNote != nil
        let key = ThreadKey(
            changeRequest: context.changeRequest,
            remoteID: discussion.id,
            kind: isDiffThread ? .diffThread : .conversation
        )
        let resolvableNotes = notes.filter { $0.resolvable == true }
        let isResolvable = !resolvableNotes.isEmpty
        let isResolved: Bool? = isResolvable ? resolvableNotes.allSatisfy { $0.resolved == true } : nil
        let comments = notes.map { note in
            comment(note, rootID: note.id == first.id ? nil : String(first.id), webURL: context.webURL)
        }
        let lastActivity = notes.map { max($0.createdAt, $0.updatedAt ?? $0.createdAt) }.max() ?? first.createdAt
        return ReviewThread(
            key: key,
            anchor: isDiffThread ? diffNote.flatMap { anchor($0, context: context) } : nil,
            isResolved: isResolved,
            isResolvable: isResolvable,
            comments: comments,
            webURL: noteURL(context.webURL, noteID: first.id),
            lastActivityAt: lastActivity
        )
    }

    static func comment(_ note: GLNote, rootID: String?, webURL: URL?) -> ReviewComment {
        let isSystem = note.system == true
        return ReviewComment(
            id: String(note.id),
            author: GitLabMapping.person(note.author),
            body: note.body,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            webURL: noteURL(webURL, noteID: note.id),
            kind: CommentKind.classify(body: note.body, isSystem: isSystem),
            inReplyToID: rootID
        )
    }

    /// `<merge request web URL>#note_<id>`.
    static func noteURL(_ webURL: URL?, noteID: Int) -> URL? {
        guard let webURL else { return nil }
        return URL(string: webURL.absoluteString + "#note_\(noteID)")
    }

    static func anchor(_ note: GLNote, context: GitLabThreadContext) -> DiffAnchor? {
        guard let position = note.position else { return nil }
        guard let path = position.newPath ?? position.oldPath else { return nil }
        let side: DiffSide = position.newLine != nil ? .new : .old
        let line = position.newLine ?? position.oldLine
        var startLine: Int?
        if let start = position.lineRange?.start {
            let candidate = side == .new ? (start.newLine ?? start.oldLine) : (start.oldLine ?? start.newLine)
            if let candidate, candidate != line { startLine = candidate }
        }
        let headSHA = position.headSha
        let isOutdated: Bool = if let headSHA, let current = context.currentHeadSHA { headSHA != current } else { false }
        return DiffAnchor(
            path: path,
            oldPath: position.oldPath.flatMap { $0 != path ? $0 : nil },
            line: line,
            startLine: startLine,
            side: side,
            commitSHA: headSHA,
            originalCommitSHA: note.originalPosition?.headSha ?? note.commitId,
            diffVersionID: versionID(for: position, in: context.versions),
            isOutdated: isOutdated,
            nativePosition: nativePosition(position)
        )
    }

    /// The diff version (`/versions`) whose head/base/start SHAs match the position.
    static func versionID(for position: GLPosition, in versions: [GLVersion]) -> String? {
        guard let head = position.headSha else { return nil }
        let candidates = versions.filter { $0.headCommitSha == head }
        let exact = candidates.first {
            (position.baseSha == nil || $0.baseCommitSha == position.baseSha)
                && (position.startSha == nil || $0.startCommitSha == position.startSha)
        }
        return (exact ?? candidates.first).map { String($0.id) }
    }

    static func nativePosition(_ position: GLPosition) -> [String: String] {
        var result: [String: String] = [:]
        result["base_sha"] = position.baseSha
        result["start_sha"] = position.startSha
        result["head_sha"] = position.headSha
        result["old_path"] = position.oldPath
        result["new_path"] = position.newPath
        result["position_type"] = position.positionType
        result["old_line"] = position.oldLine.map(String.init)
        result["new_line"] = position.newLine.map(String.init)
        result["line_range_start_line_code"] = position.lineRange?.start?.lineCode
        result["line_range_end_line_code"] = position.lineRange?.end?.lineCode
        return result
    }
}
