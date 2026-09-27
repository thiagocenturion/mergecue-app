import Foundation
import MergeCueCore

/// Builders for the synthetic preview dataset. Everything is relative to `now` so relative times stay meaningful,
/// and every identifier is fixed so snapshots are reproducible. This is **preview data**, never live data.
nonisolated struct PreviewWorld {
    let now: Date

    // MARK: Accounts (persona "mona-dev" / Mona Dev on all three providers)

    static let githubUserID = "583231"
    static let gitlabUserID = "9120334"
    static let bitbucketUserID = "{b7e3c2a1-4d5f-4e8a-9c1b-2f3d4e5a6b7c}"

    let gh = AccountKey(instance: .githubCom, remoteUserID: PreviewWorld.githubUserID)
    let gl = AccountKey(instance: .gitlabCom, remoteUserID: PreviewWorld.gitlabUserID)
    let bb = AccountKey(instance: .bitbucketCloud, remoteUserID: PreviewWorld.bitbucketUserID)

    func ago(minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
    func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    func later(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    // MARK: People

    func mona(_ kind: ProviderKind) -> Person {
        switch kind {
        case .github: Person(remoteID: Self.githubUserID, username: "mona-dev", displayName: "Mona Dev")
        case .gitlab: Person(remoteID: Self.gitlabUserID, username: "mona-dev", displayName: "Mona Dev")
        case .bitbucketCloud: Person(remoteID: Self.bitbucketUserID, username: "mona-dev", displayName: "Mona Dev")
        }
    }

    func person(_ username: String, _ displayName: String, _ kind: ProviderKind, bot: Bool = false) -> Person {
        let prefix = switch kind {
        case .github: "gh"
        case .gitlab: "gl"
        case .bitbucketCloud: "bb"
        }
        return Person(remoteID: "\(prefix)-\(username)", username: username, displayName: displayName, isBot: bot)
    }

    // MARK: Repositories and change requests

    func repository(_ account: AccountKey, id: String, path: String) -> Repository {
        let instance = ProviderInstance.default(for: account.kind)
        let web = instance.webURL.appending(path: path)
        let segments = path.split(separator: "/")
        let sshHost = account.kind == .bitbucketCloud ? "bitbucket.org" : instance.host
        return Repository(
            key: RepoKey(account: account, remoteRepoID: id),
            namespacePath: segments.dropLast().joined(separator: "/"),
            name: String(segments.last ?? Substring(path)),
            fullPath: path,
            webURL: web,
            cloneURLs: [web.absoluteString + ".git", "git@\(sshHost):\(path).git"],
            defaultBranch: "main",
            isPrivate: true
        )
    }

    func changeRequestURL(_ repo: Repository, number: Int) -> URL {
        switch repo.providerKind {
        case .github: repo.webURL.appending(path: "pull/\(number)")
        case .gitlab: repo.webURL.appending(path: "-/merge_requests/\(number)")
        case .bitbucketCloud: repo.webURL.appending(path: "pull-requests/\(number)")
        }
    }

    func summary(
        _ repo: Repository, remoteID: String, number: Int, title: String, author: Person,
        involvement: Set<Involvement>, source: String, target: String = "main", head: String,
        created: Date, updated: Date, state: ChangeRequestState = .open, isDraft: Bool = false
    ) -> ChangeRequestSummary {
        ChangeRequestSummary(
            key: ChangeRequestKey(repo: repo.key, remoteID: remoteID, number: number),
            repository: repo, title: title, author: author, state: state, isDraft: isDraft,
            sourceBranch: source, targetBranch: target, headSHA: head, createdAt: created, updatedAt: updated,
            webURL: changeRequestURL(repo, number: number), involvement: involvement,
            versionToken: String(Int(updated.timeIntervalSinceReferenceDate))
        )
    }

    // MARK: Threads and checks

    func comment(_ id: String, _ author: Person, _ body: String, at date: Date, kind: CommentKind? = nil, replyTo: String? = nil, url: URL? = nil) -> ReviewComment {
        ReviewComment(id: id, author: author, body: body, createdAt: date, webURL: url,
                      kind: kind ?? CommentKind.classify(body: body), inReplyToID: replyTo)
    }

    func thread(_ summary: ChangeRequestSummary, id: String, kind: ThreadKind = .diffThread, anchor: DiffAnchor? = nil,
                resolved: Bool?, resolvable: Bool = true, comments: [ReviewComment]) -> ReviewThread {
        let key = ThreadKey(changeRequest: summary.key, remoteID: id, kind: kind)
        let anchorFragment = switch summary.repository.providerKind {
        case .github: kind == .diffThread ? "#discussion_r\(comments.first?.id ?? id)" : "#issuecomment-\(comments.first?.id ?? id)"
        case .gitlab: "#note_\(comments.first?.id ?? id)"
        case .bitbucketCloud: "#comment-\(id)"
        }
        let url = URL(string: summary.webURL.absoluteString + anchorFragment) ?? summary.webURL
        return ReviewThread(
            key: key, anchor: anchor, isResolved: resolved, isResolvable: resolvable,
            comments: comments.map { comment in
                var comment = comment
                comment.webURL = comment.webURL ?? url
                return comment
            },
            webURL: url,
            lastActivityAt: comments.last?.createdAt ?? summary.updatedAt
        )
    }

    func check(_ summary: ChangeRequestSummary, _ source: CheckSource, id: String, name: String, status: CheckStatus,
               required: Bool? = nil, started: Date? = nil, completed: Date? = nil, summaryText: String? = nil,
               detailsPath: String) -> CheckRun {
        CheckRun(
            key: CheckKey(changeRequest: summary.key, source: source, remoteID: id),
            name: name, status: status, isRequired: required, startedAt: started, completedAt: completed,
            detailsURL: summary.repository.webURL.appending(path: detailsPath), commitSHA: summary.headSHA,
            attempt: 1, summary: summaryText, logLocator: ["job_id": id]
        )
    }

    // MARK: Ids

    /// A fixed task id (falls back to a generated one only if a literal were malformed).
    func taskID(_ raw: String) -> TaskID {
        TaskID(rawValue: raw) ?? TaskID.generate()
    }
}
