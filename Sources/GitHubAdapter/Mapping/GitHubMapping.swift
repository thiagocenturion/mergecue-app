import Foundation
import MergeCueCore
import MergeCueNetworking

/// Pure conversions from GitHub payloads to Core types.
enum GitHubMapping {
    /// Bound for a diff hunk kept on a `DiffAnchor` (the commented lines are at the end of a hunk).
    static let maxDiffHunkBytes = 4_096
    /// Bound for a check summary.
    static let maxCheckSummaryBytes = 2_048

    // MARK: People

    static func person(_ actor: GQLActor?) -> Person {
        guard let actor else { return ghost }
        return Person(
            remoteID: actor.databaseId?.value ?? "login:\(actor.login)",
            username: actor.login,
            displayName: actor.name.flatMap { $0.isEmpty ? nil : $0 },
            avatarURL: actor.avatarUrl,
            isBot: actor.typename == "Bot"
        )
    }

    static func person(_ user: RESTUser?) -> Person {
        guard let user else { return ghost }
        return Person(
            remoteID: user.id.value,
            username: user.login,
            displayName: user.name.flatMap { $0.isEmpty ? nil : $0 },
            avatarURL: user.avatarURL,
            isBot: user.type == "Bot"
        )
    }

    /// Deleted accounts ("ghost" on github.com).
    static let ghost = Person(remoteID: "ghost", username: "ghost", displayName: "Deleted user")

    // MARK: Repositories

    static func repository(_ repo: GQLRepo, account: AccountKey, instance: ProviderInstance) throws -> Repository {
        guard let id = repo.databaseId?.value else {
            throw ProviderError.decoding("Repository \(repo.nameWithOwner) has no database id.")
        }
        let parts = splitFullPath(repo.nameWithOwner)
        let web = repo.url ?? webURL(instance: instance, path: repo.nameWithOwner)
        return Repository(
            key: RepoKey(account: account, remoteRepoID: id),
            namespacePath: repo.owner?.login ?? parts.owner,
            name: repo.name ?? parts.name,
            fullPath: repo.nameWithOwner,
            webURL: web,
            cloneURLs: cloneURLs(web: web, ssh: repo.sshUrl),
            defaultBranch: repo.defaultBranchRef?.name,
            isPrivate: repo.isPrivate ?? true
        )
    }

    static func repository(_ repo: RESTRepository, account: AccountKey, instance: ProviderInstance) -> Repository {
        let parts = splitFullPath(repo.fullName)
        let web = repo.htmlURL ?? webURL(instance: instance, path: repo.fullName)
        var urls: [String] = []
        if let clone = repo.cloneURL { urls.append(clone) } else { urls.append(web.absoluteString + ".git") }
        if let ssh = repo.sshURL { urls.append(ssh) }
        return Repository(
            key: RepoKey(account: account, remoteRepoID: repo.id.value),
            namespacePath: repo.owner?.login ?? parts.owner,
            name: repo.name,
            fullPath: repo.fullName,
            webURL: web,
            cloneURLs: urls,
            defaultBranch: repo.defaultBranch,
            isPrivate: repo.isPrivate ?? true
        )
    }

    static func cloneURLs(web: URL, ssh: String?) -> [String] {
        var urls = [web.absoluteString + ".git"]
        if let ssh, !ssh.isEmpty { urls.append(ssh) }
        return urls
    }

    static func webURL(instance: ProviderInstance, path: String) -> URL {
        var base = instance.webURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/" + path) ?? instance.webURL
    }

    static func splitFullPath(_ fullPath: String) -> (owner: String, name: String) {
        guard let slash = fullPath.firstIndex(of: "/") else { return (fullPath, fullPath) }
        return (String(fullPath[..<slash]), String(fullPath[fullPath.index(after: slash)...]))
    }

    // MARK: Change requests

    static func state(_ graphQLState: String) -> ChangeRequestState {
        switch graphQLState.uppercased() {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
    }

    /// Cheap change detector: `updatedAt` plus head SHA and the rollup state (a CI change or a push does not
    /// always bump the pull request's `updatedAt`).
    static func versionToken(updatedAt: Date, headSHA: String?, rollupState: String?) -> String {
        let stamp = MergeCueCoding.formatWireDate(updatedAt) ?? String(updatedAt.timeIntervalSince1970)
        return [stamp, headSHA ?? "-", rollupState ?? "-"].joined(separator: "|")
    }

    static func summary(
        _ pr: GQLPullRequest,
        account: AccountKey,
        instance: ProviderInstance,
        involvement: Set<Involvement>
    ) throws -> ChangeRequestSummary {
        guard let remoteID = pr.fullDatabaseId?.value else {
            throw ProviderError.decoding("Pull request #\(pr.number) has no database id.")
        }
        let repository = try repository(pr.repository, account: account, instance: instance)
        return ChangeRequestSummary(
            key: ChangeRequestKey(repo: repository.key, remoteID: remoteID, number: pr.number),
            repository: repository,
            title: pr.title,
            author: person(pr.author),
            state: state(pr.state),
            isDraft: pr.isDraft ?? false,
            sourceBranch: pr.headRefName,
            targetBranch: pr.baseRefName,
            headSHA: pr.headRefOid,
            createdAt: pr.createdAt,
            updatedAt: pr.updatedAt,
            webURL: pr.url,
            involvement: involvement,
            versionToken: versionToken(updatedAt: pr.updatedAt, headSHA: pr.headRefOid, rollupState: pr.rollupState)
        )
    }

    // MARK: Threads

    static func diffSide(_ side: String?) -> DiffSide {
        side?.uppercased() == "LEFT" ? .old : .new
    }

    static func comment(_ comment: GQLReviewComment) -> ReviewComment {
        ReviewComment(
            id: comment.fullDatabaseId?.value ?? comment.id,
            author: person(comment.author),
            body: comment.body,
            createdAt: comment.createdAt,
            updatedAt: comment.updatedAt,
            webURL: comment.url,
            kind: CommentKind.classify(body: comment.body),
            inReplyToID: comment.replyTo?.fullDatabaseId?.value
        )
    }

    /// A review thread; `comments` is the complete (already paginated) chain.
    static func diffThread(_ thread: GQLThread, comments rawComments: [GQLReviewComment], changeRequest: ChangeRequestKey) -> ReviewThread {
        let sorted = rawComments.sorted { $0.createdAt < $1.createdAt }
        let comments = sorted.map(comment)
        let root = sorted.first
        var native: [String: String] = ["thread_node_id": thread.id]
        if let subject = thread.subjectType { native["subject_type"] = subject }
        if let side = thread.diffSide { native["diff_side"] = side }
        if let side = thread.startDiffSide { native["start_diff_side"] = side }
        if let line = thread.originalLine { native["original_line"] = String(line) }
        if let line = thread.originalStartLine { native["original_start_line"] = String(line) }
        if let root, let id = root.fullDatabaseId?.value { native["root_comment_id"] = id }
        let hunk = root?.diffHunk.map { BoundedText.truncate($0, maxBytes: maxDiffHunkBytes, keepTail: true).text }
        let anchor = DiffAnchor(
            path: thread.path,
            line: thread.line ?? thread.originalLine,
            startLine: thread.startLine ?? thread.originalStartLine,
            side: diffSide(thread.diffSide),
            commitSHA: root?.commit?.oid,
            originalCommitSHA: root?.originalCommit?.oid,
            diffHunk: hunk,
            isOutdated: thread.isOutdated,
            nativePosition: native
        )
        let last = comments.map { max($0.createdAt, $0.updatedAt ?? $0.createdAt) }.max()
        return ReviewThread(
            key: ThreadKey(changeRequest: changeRequest, remoteID: thread.id, kind: .diffThread),
            anchor: anchor,
            isResolved: thread.isResolved,
            isResolvable: true,
            comments: comments,
            webURL: root?.url,
            lastActivityAt: last ?? .distantPast
        )
    }

    static func issueCommentThread(_ comment: GQLIssueComment, changeRequest: ChangeRequestKey) -> ReviewThread? {
        guard let id = comment.fullDatabaseId?.value else { return nil }
        let reviewComment = ReviewComment(
            id: id,
            author: person(comment.author),
            body: comment.body,
            createdAt: comment.createdAt,
            updatedAt: comment.updatedAt,
            webURL: comment.url,
            kind: CommentKind.classify(body: comment.body)
        )
        return ReviewThread(
            key: .githubIssueComment(changeRequest: changeRequest, commentID: id),
            isResolved: nil,
            isResolvable: false,
            comments: [reviewComment],
            webURL: comment.url,
            lastActivityAt: max(comment.createdAt, comment.updatedAt ?? comment.createdAt)
        )
    }

    static func issueCommentThread(_ comment: RESTIssueComment, changeRequest: ChangeRequestKey) -> ReviewThread {
        let body = comment.body ?? ""
        let reviewComment = ReviewComment(
            id: comment.id.value,
            author: person(comment.user),
            body: body,
            createdAt: comment.createdAt,
            updatedAt: comment.updatedAt,
            webURL: comment.htmlURL,
            kind: CommentKind.classify(body: body)
        )
        return ReviewThread(
            key: .githubIssueComment(changeRequest: changeRequest, commentID: comment.id.value),
            isResolved: nil,
            isResolvable: false,
            comments: [reviewComment],
            webURL: comment.htmlURL,
            lastActivityAt: max(comment.createdAt, comment.updatedAt ?? comment.createdAt)
        )
    }

    /// A review body as a `.reviewSummary` thread; nil for reviews without text or not yet submitted.
    static func reviewSummaryThread(_ review: GQLReview, changeRequest: ChangeRequestKey) -> ReviewThread? {
        guard let id = review.fullDatabaseId?.value, let body = review.body,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              review.state.uppercased() != "PENDING", let submittedAt = review.submittedAt
        else { return nil }
        return reviewSummaryThread(
            id: id, author: person(review.author), body: body, submittedAt: submittedAt, url: review.url,
            changeRequest: changeRequest
        )
    }

    static func reviewSummaryThread(_ review: RESTReview, changeRequest: ChangeRequestKey) -> ReviewThread {
        reviewSummaryThread(
            id: review.id.value, author: person(review.user), body: review.body ?? "",
            submittedAt: review.submittedAt ?? .distantPast, url: review.htmlURL, changeRequest: changeRequest
        )
    }

    private static func reviewSummaryThread(
        id: String, author: Person, body: String, submittedAt: Date, url: URL?, changeRequest: ChangeRequestKey
    ) -> ReviewThread {
        ReviewThread(
            key: .githubReviewSummary(changeRequest: changeRequest, reviewID: id),
            isResolved: nil,
            isResolvable: false,
            comments: [
                ReviewComment(id: id, author: author, body: body, createdAt: submittedAt, webURL: url,
                              kind: CommentKind.classify(body: body)),
            ],
            webURL: url,
            lastActivityAt: submittedAt
        )
    }

    static func replyComment(_ comment: RESTReviewComment) -> ReviewComment {
        ReviewComment(
            id: comment.id.value,
            author: person(comment.user),
            body: comment.body,
            createdAt: comment.createdAt,
            updatedAt: comment.updatedAt,
            webURL: comment.htmlURL,
            kind: CommentKind.classify(body: comment.body),
            inReplyToID: comment.inReplyToID?.value
        )
    }

    static func replyComment(_ comment: RESTIssueComment) -> ReviewComment {
        let body = comment.body ?? ""
        return ReviewComment(
            id: comment.id.value,
            author: person(comment.user),
            body: body,
            createdAt: comment.createdAt,
            updatedAt: comment.updatedAt,
            webURL: comment.htmlURL,
            kind: CommentKind.classify(body: body)
        )
    }

    // MARK: Reviews

    static func reviewState(_ state: String) -> ReviewState {
        switch state.uppercased() {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "DISMISSED": .dismissed
        case "PENDING": .pending
        default: .commented
        }
    }

    static func review(_ review: GQLReview) -> Review? {
        guard let id = review.fullDatabaseId?.value else { return nil }
        let body = review.body.flatMap { $0.isEmpty ? nil : $0 }
        return Review(remoteID: id, author: person(review.author), state: reviewState(review.state),
                      submittedAt: review.submittedAt, body: body, commitSHA: review.commit?.oid)
    }

    /// Latest verdicts plus outstanding requests (a re-requested reviewer is `pending` again).
    static func reviewers(latest: [GQLLatestReview], requests: [GQLReviewRequest]) -> [Reviewer] {
        var order: [String] = []
        var byID: [String: Reviewer] = [:]
        func upsert(_ reviewer: Reviewer) {
            let id = reviewer.person.remoteID
            if byID[id] == nil { order.append(id) }
            byID[id] = reviewer
        }
        for review in latest {
            upsert(Reviewer(person: person(review.author), state: reviewState(review.state)))
        }
        for request in requests {
            guard let reviewer = request.requestedReviewer else { continue }
            let person: Person
            if reviewer.typename == "Team" {
                let slug = reviewer.slug ?? reviewer.name ?? "team"
                person = Person(remoteID: "team:" + (reviewer.databaseId?.value ?? slug), username: slug,
                                displayName: reviewer.name, avatarURL: reviewer.avatarUrl)
            } else {
                let login = reviewer.login ?? "unknown"
                person = Person(remoteID: reviewer.databaseId?.value ?? "login:\(login)", username: login,
                                displayName: reviewer.name, avatarURL: reviewer.avatarUrl, isBot: reviewer.typename == "Bot")
            }
            upsert(Reviewer(person: person, state: .pending, isRequired: request.asCodeOwner == true ? true : nil))
        }
        return order.compactMap { byID[$0] }
    }

    static func approvals(latest: [GQLLatestReview], reviewDecision: String?, mergeStateStatus: String?) -> ApprovalStatus {
        let approvedBy = latest.filter { $0.state.uppercased() == "APPROVED" }.map { person($0.author) }
        let satisfied: Bool? = switch reviewDecision?.uppercased() {
        case "APPROVED": true
        case "CHANGES_REQUESTED", "REVIEW_REQUIRED": false
        default: GitHubReadiness.cleanStates.contains(mergeStateStatus?.uppercased() ?? "") ? true : nil
        }
        return ApprovalStatus(approvedBy: approvedBy, requiredCount: nil, isSatisfied: satisfied)
    }

    // MARK: Files and commits

    static func fileStatus(graphQL changeType: String?) -> FileChangeStatus {
        switch changeType?.uppercased() {
        case "ADDED": .added
        case "DELETED": .removed
        case "RENAMED": .renamed
        case "COPIED": .copied
        case "MODIFIED", "CHANGED": .modified
        default: .unknown
        }
    }

    static func fileStatus(rest status: String) -> FileChangeStatus {
        switch status.lowercased() {
        case "added": .added
        case "removed": .removed
        case "renamed": .renamed
        case "copied": .copied
        case "modified", "changed": .modified
        default: .unknown
        }
    }

    static func changedFile(_ file: GQLChangedFile) -> ChangedFile {
        ChangedFile(path: file.path, status: fileStatus(graphQL: file.changeType), additions: file.additions, deletions: file.deletions)
    }

    static func changedFile(_ file: RESTPullFile) -> ChangedFile {
        ChangedFile(path: file.filename, oldPath: file.previousFilename, status: fileStatus(rest: file.status),
                    additions: file.additions, deletions: file.deletions)
    }

    static func commit(_ node: GQLCommitNode) -> CommitInfo {
        let commit = node.commit
        return CommitInfo(sha: commit.oid, title: commit.messageHeadline ?? "",
                          author: commit.author?.user?.login ?? commit.author?.name, authoredAt: commit.authoredDate)
    }
}
