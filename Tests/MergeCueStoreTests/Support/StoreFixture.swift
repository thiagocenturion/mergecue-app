import Foundation
import MergeCueCore
@testable import MergeCueStore

/// Deterministic sample values and database helpers for the store tests (never the user's real data directory).
enum StoreFixture {
    /// 2026-01-01T00:00:00Z plus a sub-second fraction, so lossless date storage is exercised.
    static let date = Date(timeIntervalSince1970: 1_767_225_600.123_456)

    static func at(_ seconds: TimeInterval) -> Date {
        date.addingTimeInterval(seconds)
    }

    // MARK: Identity

    static let githubAccount = AccountKey(kind: .github, host: "github.com", remoteUserID: "123")
    static let gitlabAccount = AccountKey(kind: .gitlab, host: "gitlab.com", remoteUserID: "123")

    static func repoKey(_ account: AccountKey = githubAccount, id: String = "456") -> RepoKey {
        RepoKey(account: account, remoteRepoID: id)
    }

    static func changeRequestKey(
        _ account: AccountKey = githubAccount, repoID: String = "456", remoteID: String = "789", number: Int = 42
    ) -> ChangeRequestKey {
        ChangeRequestKey(repo: repoKey(account, id: repoID), remoteID: remoteID, number: number)
    }

    static func threadKey(_ changeRequest: ChangeRequestKey = changeRequestKey(), id: String = "PRRT_1") -> ThreadKey {
        ThreadKey(changeRequest: changeRequest, remoteID: id, kind: .diffThread)
    }

    // MARK: Model values

    static func account(_ key: AccountKey = githubAccount, username: String = "mona-dev", connectedAt: Date = date) -> Account {
        Account(
            id: key,
            instance: ProviderInstance.default(for: key.kind),
            username: username,
            displayName: "Mona Dev",
            authMethod: .personalAccessToken,
            grantedScopes: ["repo"],
            connectedAt: connectedAt
        )
    }

    static func person(_ username: String = "reviewer", id: String = "900") -> Person {
        Person(remoteID: id, username: username, displayName: username.capitalized)
    }

    static func repository(_ key: RepoKey = repoKey(), fullPath: String = "acme/payments-api") -> Repository {
        Repository(
            key: key,
            namespacePath: String(fullPath.split(separator: "/").dropLast().joined(separator: "/")),
            name: String(fullPath.split(separator: "/").last ?? ""),
            fullPath: fullPath,
            webURL: URL(string: "https://github.com/\(fullPath)")!,
            cloneURLs: ["https://github.com/\(fullPath).git", "git@github.com:\(fullPath).git"],
            defaultBranch: "main"
        )
    }

    static func snapshot(
        _ key: ChangeRequestKey = changeRequestKey(),
        title: String = "Add retries",
        state: ChangeRequestState = .open,
        headSHA: String = "abc123",
        updatedAt: Date = date
    ) -> ChangeRequestSnapshot {
        let summary = ChangeRequestSummary(
            key: key,
            repository: repository(key.repo),
            title: title,
            author: person("mona-dev", id: "123"),
            state: state,
            sourceBranch: "feature/retries",
            targetBranch: "main",
            headSHA: headSHA,
            createdAt: date,
            updatedAt: updatedAt,
            webURL: URL(string: "https://github.com/acme/payments-api/pull/\(key.number)")!,
            involvement: [.authored, .participated],
            versionToken: "\(updatedAt.timeIntervalSince1970)"
        )
        let thread = ReviewThread(
            key: threadKey(key),
            anchor: DiffAnchor(path: "Sources/Retry.swift", line: 12, side: .new, isOutdated: false),
            isResolved: false,
            isResolvable: true,
            comments: [
                ReviewComment(id: "c1", author: person(), body: "Please add a backoff cap?", createdAt: updatedAt, kind: .question),
            ],
            lastActivityAt: updatedAt
        )
        let check = CheckRun(
            key: CheckKey(changeRequest: key, source: .githubCheckRun, remoteID: "555"),
            name: "build",
            status: .failure,
            startedAt: date,
            completedAt: updatedAt,
            logLocator: ["job_id": "555"]
        )
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Adds retries.",
            baseSHA: "base000",
            reviews: [Review(remoteID: "r1", author: person(), state: .changesRequested, submittedAt: updatedAt)],
            threads: [thread],
            checks: [check],
            commits: [CommitInfo(sha: headSHA, title: "Add retries", authoredAt: date)],
            changedFiles: [ChangedFile(path: "Sources/Retry.swift", status: .modified, additions: 10, deletions: 2)],
            readiness: .blocked(reasons: ["1 unresolved thread"]),
            fetchedAt: updatedAt,
            nativeRefs: ["api": "https://api.github.com/repos/acme/payments-api/pulls/42"]
        )
    }

    static func event(
        _ changeRequest: ChangeRequestKey = changeRequestKey(),
        type: ChangeEventType = .reviewComment,
        objectID: String = "c1",
        version: String = "1",
        occurredAt: Date = date,
        detectedAt: Date = date,
        isBaseline: Bool = false
    ) -> ChangeEvent {
        ChangeEvent(
            type: type,
            changeRequest: changeRequest,
            repoFullPath: "acme/payments-api",
            title: "Add retries",
            objectID: objectID,
            objectVersion: version,
            occurredAt: occurredAt,
            detectedAt: detectedAt,
            actor: person(),
            isBaseline: isBaseline,
            summary: "Reviewer commented"
        )
    }

    static func attentionItem(
        _ changeRequest: ChangeRequestKey = changeRequestKey(),
        thread: ThreadKey? = nil,
        eventIDs: [String],
        summary: String = "Please add a backoff cap?",
        updatedAt: Date = date,
        isUnread: Bool = true,
        disposition: AttentionDisposition = .open
    ) -> AttentionItem {
        let thread = thread ?? threadKey(changeRequest)
        return AttentionItem(
            dedupeKey: AttentionItem.dedupeKey(thread: thread),
            changeRequest: changeRequest,
            repoFullPath: "acme/payments-api",
            title: "Add retries",
            reason: .reviewerQuestion,
            summary: summary,
            thread: thread,
            eventIDs: eventIDs,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            isUnread: isUnread,
            disposition: disposition
        )
    }

    static func task(
        _ id: String = "mc_abc123",
        changeRequest: ChangeRequestKey = changeRequestKey(),
        state: TaskState = .waitingForAgent,
        version: Int = 1,
        updatedAt: Date = date
    ) -> MCTask {
        MCTask(
            id: TaskID(rawValue: id)!,
            type: .fixReview,
            state: state,
            version: version,
            createdAt: date,
            updatedAt: updatedAt,
            origin: TaskOrigin(
                attentionItemID: "att_0123456789",
                changeRequest: changeRequest,
                changeRequestRef: ChangeRequestRef(kind: .github, host: "github.com", repoFullPath: "acme/payments-api", number: 42),
                title: "Add retries",
                webURL: URL(string: "https://github.com/acme/payments-api/pull/42")!,
                thread: threadKey(changeRequest)
            ),
            trigger: TaskTriggerSnapshot(
                eventType: .reviewComment,
                capturedAt: date,
                headSHA: "abc123",
                sourceBranch: "feature/retries",
                targetBranch: "main",
                quoted: [UntrustedText(source: UntrustedText.Source.reviewComment, author: "reviewer", createdAt: date, text: "Please add a backoff cap?")]
            ),
            lease: AgentLease(
                agentName: "claude-code",
                leaseID: "lease_0123",
                claimedAt: date,
                heartbeatAt: date,
                expiresAt: at(600)
            ),
            knownRisks: ["none"]
        )
    }

    static func activity(
        _ id: String = "act_1", task: String = "mc_abc123", at seconds: TimeInterval = 0, message: String = "Claimed"
    ) -> TaskActivity {
        TaskActivity(
            id: id,
            taskID: TaskID(rawValue: task)!,
            at: at(seconds),
            actor: .agent,
            actorName: "claude-code",
            kind: .claimed,
            message: message,
            fromState: .waitingForAgent,
            toState: .working,
            data: ["lease": "lease_0123"]
        )
    }

    static func rule(_ id: String = "rule_0000000001", createdAt: Date = date) -> Rule {
        Rule(
            id: id,
            name: "Failed CI on my PRs",
            origin: .template,
            providerKinds: [.github, .gitlab],
            eventTypes: [.ciFailed, .reviewComment],
            repoInclude: ["acme/**"],
            involvement: [.authored],
            action: .createTask(.investigateCI),
            maxFiresPerHour: 5,
            quietHours: QuietHours(startMinute: 22 * 60, endMinute: 7 * 60, timeZoneID: "Europe/Lisbon"),
            createdAt: createdAt
        )
    }

    static func audit(
        _ id: String, at seconds: TimeInterval = 0, taskID: String? = nil, detail: String = "posted reply"
    ) -> AuditEntry {
        AuditEntry(
            id: id,
            at: at(seconds),
            actor: "user",
            action: "post_reply",
            target: "thr_0123456789",
            outcome: .succeeded,
            detail: detail,
            taskID: taskID.flatMap(TaskID.init(rawValue:))
        )
    }

    // MARK: Databases

    /// A fresh, empty temporary directory.
    static func temporaryDirectory(_ name: String = "store") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mergecue-tests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A database file path inside a fresh temporary directory.
    static func temporaryDatabasePath(_ name: String = "store") throws -> String {
        try temporaryDirectory(name).appending(path: "mergecue.sqlite").path(percentEncoded: false)
    }

    /// An in-memory database with `accounts` connected.
    static func database(accounts: [AccountKey] = [githubAccount]) async throws -> MergeCueDatabase {
        let database = try MergeCueDatabase.inMemory()
        for key in accounts {
            try await database.upsertAccount(account(key))
        }
        return database
    }

    /// Reads a file's bytes (empty when missing).
    static func bytes(atPath path: String) -> Data {
        (try? Data(contentsOf: URL(filePath: path))) ?? Data()
    }
}
