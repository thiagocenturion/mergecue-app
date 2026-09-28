import Foundation
import MergeCueCore

/// Deterministic sample data for sync tests (synthetic — never live data).
enum SyncFixture {
    /// TestClock's default start: 2026-01-01T00:00:00Z.
    static let start = Date(timeIntervalSince1970: 1_767_225_600)
    static let me = "1001"

    static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    // MARK: Identity

    static func accountKey(_ kind: ProviderKind, user: String = me) -> AccountKey {
        AccountKey(instance: .default(for: kind), remoteUserID: user)
    }

    static let github = accountKey(.github)
    static let gitlab = accountKey(.gitlab)
    static let bitbucket = accountKey(.bitbucketCloud)

    static func account(_ key: AccountKey) -> Account {
        Account(
            id: key,
            instance: .default(for: key.kind),
            username: "mona-dev",
            displayName: "Mona Dev",
            authMethod: .personalAccessToken,
            connectedAt: start
        )
    }

    static func crKey(_ account: AccountKey = github, number: Int = 42, repoID: String = "repo-1") -> ChangeRequestKey {
        ChangeRequestKey(repo: RepoKey(account: account, remoteRepoID: repoID), remoteID: "cr-\(number)", number: number)
    }

    static func threadKey(_ cr: ChangeRequestKey, _ id: String = "T1", kind: ThreadKind = .diffThread) -> ThreadKey {
        ThreadKey(changeRequest: cr, remoteID: id, kind: kind)
    }

    static func checkKey(_ cr: ChangeRequestKey, _ id: String) -> CheckKey {
        CheckKey(changeRequest: cr, source: .githubCheckRun, remoteID: id)
    }

    // MARK: People

    static let mona = Person(remoteID: me, username: "mona-dev", displayName: "Mona Dev")
    static let alice = Person(remoteID: "2001", username: "alice", displayName: "Alice")
    static let bob = Person(remoteID: "2002", username: "bob", displayName: "Bob")
    static let bot = Person(remoteID: "9001", username: "coverage-bot", isBot: true)

    // MARK: Model builders

    static func repository(_ key: RepoKey, fullPath: String = "acme/payments-api") -> Repository {
        let host = key.account.host
        return Repository(
            key: key,
            namespacePath: "acme",
            name: "payments-api",
            fullPath: fullPath,
            webURL: URL(string: "https://\(host)/\(fullPath)")!
        )
    }

    static func summary(
        _ key: ChangeRequestKey,
        author: Person = mona,
        involvement: Set<Involvement> = [.authored],
        state: ChangeRequestState = .open,
        headSHA: String = "aaaa1111",
        updatedAt: Date = start,
        title: String = "Add retries"
    ) -> ChangeRequestSummary {
        ChangeRequestSummary(
            key: key,
            repository: repository(key.repo),
            title: title,
            author: author,
            state: state,
            sourceBranch: "feature/retries",
            targetBranch: "main",
            headSHA: headSHA,
            createdAt: start,
            updatedAt: updatedAt,
            webURL: URL(string: "https://\(key.account.host)/acme/payments-api/pull/\(key.number)")!,
            involvement: involvement,
            versionToken: String(updatedAt.timeIntervalSince1970)
        )
    }

    static func snapshot(
        _ key: ChangeRequestKey = crKey(),
        author: Person = mona,
        involvement: Set<Involvement> = [.authored],
        state: ChangeRequestState = .open,
        headSHA: String = "aaaa1111",
        updatedAt: Date = start,
        threads: [ReviewThread] = [],
        checks: [CheckRun] = [],
        reviews: [Review] = [],
        reviewers: [Reviewer] = [],
        commits: [String]? = nil,
        readiness: MergeReadiness = .unknown,
        fetchedAt: Date = start
    ) -> ChangeRequestSnapshot {
        ChangeRequestSnapshot(
            summary: summary(key, author: author, involvement: involvement, state: state, headSHA: headSHA, updatedAt: updatedAt),
            reviewers: reviewers,
            reviews: reviews,
            threads: threads,
            checks: checks,
            commits: (commits ?? [headSHA]).map { CommitInfo(sha: $0, title: "commit \($0)") },
            readiness: readiness,
            fetchedAt: fetchedAt
        )
    }

    static func comment(
        _ id: String, by author: Person = alice, _ body: String = "Please add a backoff cap.", at seconds: TimeInterval = 10,
        kind: CommentKind = .comment, replyTo: String? = nil
    ) -> ReviewComment {
        ReviewComment(
            id: id, author: author, body: body, createdAt: at(seconds),
            webURL: URL(string: "https://github.com/acme/payments-api/pull/42#discussion_r\(id)"),
            kind: kind, inReplyToID: replyTo
        )
    }

    static func thread(
        _ key: ThreadKey, comments: [ReviewComment], resolved: Bool? = false, outdated: Bool = false,
        path: String = "Sources/Retry.swift"
    ) -> ReviewThread {
        ReviewThread(
            key: key,
            anchor: DiffAnchor(path: path, line: 12, side: .new, isOutdated: outdated),
            isResolved: resolved,
            isResolvable: resolved != nil,
            comments: comments,
            webURL: URL(string: "https://github.com/acme/payments-api/pull/42#thread-\(key.remoteID)"),
            lastActivityAt: comments.last?.createdAt ?? start
        )
    }

    static func check(
        _ cr: ChangeRequestKey, id: String, name: String = "build", status: CheckStatus, at seconds: TimeInterval = 20,
        sha: String = "aaaa1111", required: Bool? = nil, attempt: Int? = nil
    ) -> CheckRun {
        CheckRun(
            key: checkKey(cr, id),
            name: name,
            status: status,
            isRequired: required,
            startedAt: at(seconds - 5),
            completedAt: status.isTerminal ? at(seconds) : nil,
            detailsURL: URL(string: "https://github.com/acme/payments-api/runs/\(id)"),
            commitSHA: sha,
            attempt: attempt
        )
    }

    static func review(_ id: String, by author: Person = alice, _ state: ReviewState, at seconds: TimeInterval = 30, body: String? = nil) -> Review {
        Review(remoteID: id, author: author, state: state, submittedAt: at(seconds), body: body)
    }
}

extension ChangeRequestSnapshot {
    /// Test helper: a copy with a later `updatedAt` / version token so the listing reports a change.
    func touched(_ seconds: TimeInterval) -> ChangeRequestSnapshot {
        var copy = self
        copy.summary.updatedAt = SyncFixture.at(seconds)
        copy.summary.versionToken = String(copy.summary.updatedAt.timeIntervalSince1970)
        return copy
    }
}
