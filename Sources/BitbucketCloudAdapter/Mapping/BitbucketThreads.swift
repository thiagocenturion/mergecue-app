import Foundation
import MergeCueCore

/// Rebuilds Bitbucket reply chains into `ReviewThread`s.
///
/// - Bitbucket comments form a tree through `parent`; each top-level comment is one thread (its id is the
///   `ThreadKey.remoteID` and the id the resolve endpoints accept). Replies at any depth are flattened into the root's
///   thread in chronological order, each keeping its direct parent as `inReplyToID`.
/// - `pending` (unpublished draft) and `deleted` comments are excluded. A reply whose parent was excluded is
///   attached to the nearest surviving ancestor; a thread whose root was deleted keeps the root's id as key but only
///   carries the surviving replies (dropped entirely when nothing survives).
/// - Inline comments (`inline.path`) become `.diffThread`s with a `DiffAnchor`: `to` → new side, otherwise `from` →
///   old side; `start_to`/`start_from` → `startLine`. General comments become `.conversation`s.
/// - Resolution: inline threads are resolvable (`isResolved` = root has a `resolution`). General comments are not
///   treated as resolvable; `isResolved` is `true` when Bitbucket reports a resolution and nil otherwise, so they
///   never count as unresolved.
/// - Outdated: `inline.outdated` when Bitbucket sends it; otherwise the anchor commit taken from the comment's
///   `links.code` diff spec is compared with the current head — outdated when none of the spec's commits is the
///   head. Without any anchor commit the adapter cannot tell and reports not outdated.
struct BitbucketThreadBuilder: Sendable {
    let mapper: BitbucketMapper
    let changeRequest: ChangeRequestKey
    let pullRequestURL: URL
    let headSHA: String?

    func build(_ comments: [BBComment]) -> [ReviewThread] {
        let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visible = { (comment: BBComment) in comment.deleted != true && comment.pending != true }

        /// Root id of a comment (following parents; cycles and missing parents stop the walk).
        func root(of comment: BBComment) -> Int {
            var current = comment
            var seen: Set<Int> = [comment.id]
            while let parentID = current.parent?.id, let parent = byID[parentID], !seen.contains(parentID) {
                seen.insert(parentID)
                current = parent
            }
            return current.parent?.id.flatMap { byID[$0] == nil ? $0 : nil } ?? current.id
        }

        /// Nearest visible ancestor id (nil when none).
        func visibleParent(of comment: BBComment) -> Int? {
            var parentID = comment.parent?.id
            var seen: Set<Int> = [comment.id]
            while let id = parentID, !seen.contains(id) {
                seen.insert(id)
                guard let parent = byID[id] else { return id }
                if visible(parent) { return id }
                parentID = parent.parent?.id
            }
            return nil
        }

        var groups: [Int: [BBComment]] = [:]
        for comment in comments {
            groups[root(of: comment), default: []].append(comment)
        }

        var threads: [ReviewThread] = []
        for (rootID, members) in groups {
            let rootComment = byID[rootID]
            let survivors = members.filter(visible).sorted { ($0.createdOn, $0.id) < ($1.createdOn, $1.id) }
            guard !survivors.isEmpty else { continue }
            let anchorSource = rootComment ?? survivors[0]
            let isInline = anchorSource.inline?.path != nil
            let key = ThreadKey(
                changeRequest: changeRequest,
                remoteID: String(rootID),
                kind: isInline ? .diffThread : .conversation
            )
            let reviewComments = survivors.map { comment in
                ReviewComment(
                    id: String(comment.id),
                    author: mapper.person(comment.user),
                    body: comment.content?.raw ?? "",
                    createdAt: comment.createdOn,
                    updatedAt: comment.updatedOn,
                    webURL: commentURL(comment),
                    kind: CommentKind.classify(body: comment.content?.raw ?? ""),
                    inReplyToID: comment.id == rootID ? nil : visibleParent(of: comment).map(String.init)
                )
            }
            let resolved = rootComment?.resolution != nil
            let lastActivity = survivors.map { max($0.createdOn, $0.updatedOn ?? $0.createdOn) }.max() ?? anchorSource.createdOn
            threads.append(
                ReviewThread(
                    key: key,
                    anchor: isInline ? anchor(anchorSource) : nil,
                    isResolved: isInline ? resolved : (resolved ? true : nil),
                    isResolvable: isInline,
                    comments: reviewComments,
                    webURL: pullRequestURL.withFragment("comment-\(rootID)"),
                    lastActivityAt: lastActivity
                )
            )
        }
        return threads.sorted { lhs, rhs in
            let l = lhs.comments.first?.createdAt ?? lhs.lastActivityAt
            let r = rhs.comments.first?.createdAt ?? rhs.lastActivityAt
            return (l, lhs.key.remoteID) < (r, rhs.key.remoteID)
        }
    }

    private func commentURL(_ comment: BBComment) -> URL? {
        comment.links?.html?.href.flatMap(URL.init(string:)) ?? pullRequestURL.withFragment("comment-\(comment.id)")
    }

    func anchor(_ comment: BBComment) -> DiffAnchor? {
        guard let inline = comment.inline, let path = inline.path else { return nil }
        let codeLink = comment.links?.code?.href
        let specCommits = codeLink.map(Self.specCommits) ?? []
        let anchorCommit = specCommits.first
        let isOutdated: Bool
        if let flag = inline.outdated {
            isOutdated = flag
        } else if !specCommits.isEmpty, let headSHA {
            isOutdated = !specCommits.contains { BitbucketIdentifiers.sameCommit($0, headSHA) }
        } else {
            isOutdated = false
        }
        var native: [String: String] = ["path": path]
        if let from = inline.from { native["from"] = String(from) }
        if let to = inline.to { native["to"] = String(to) }
        if let startFrom = inline.startFrom { native["start_from"] = String(startFrom) }
        if let startTo = inline.startTo { native["start_to"] = String(startTo) }
        if let codeLink { native["code_link"] = codeLink }
        let onNewSide = inline.to != nil || inline.from == nil
        return DiffAnchor(
            path: path,
            line: onNewSide ? inline.to : inline.from,
            startLine: onNewSide ? inline.startTo : inline.startFrom,
            side: onNewSide ? .new : .old,
            commitSHA: anchorCommit,
            originalCommitSHA: anchorCommit,
            isOutdated: isOutdated,
            nativePosition: native
        )
    }

    /// Commit hashes of the diff spec in a comment's `links.code` URL
    /// (`…/diff/acme/payments-api:3f9c2e1d8b47..9c1e4d2b7a60?path=…`), newest (source side) first.
    static func specCommits(fromCodeLink link: String) -> [String] {
        guard let url = URL(string: link) else { return [] }
        let path = url.path(percentEncoded: false)
        guard let range = path.range(of: "/diff/") else { return [] }
        var spec = String(path[range.upperBound...])
        if let colon = spec.lastIndex(of: ":") { spec = String(spec[spec.index(after: colon)...]) }
        return BitbucketIdentifiers.commitHashes(in: spec)
    }
}

extension URL {
    /// The URL with its fragment replaced by `fragment`.
    func withFragment(_ fragment: String) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.fragment = fragment
        return components.url ?? self
    }
}
