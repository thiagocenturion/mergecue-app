import Foundation
import MergeCueCore
import Testing

@Suite("Change request model")
struct ModelTests {
    private func check(_ status: CheckStatus, name: String = "build", id: String = UUID().uuidString) -> CheckRun {
        CheckRun(key: CheckKey(changeRequest: Fixture.changeRequestKey(), source: .githubCheckRun, remoteID: id), name: name, status: status)
    }

    @Test func checkStatusFlags() {
        let failing: Set<CheckStatus> = [.failure, .timedOut, .actionRequired]
        let nonTerminal: Set<CheckStatus> = [.queued, .inProgress, .unknown]
        let passing: Set<CheckStatus> = [.success, .skipped, .neutral]
        for status in CheckStatus.allCases {
            #expect(status.isFailing == failing.contains(status), "\(status)")
            #expect(status.isTerminal == !nonTerminal.contains(status), "\(status)")
            #expect(status.isPassing == passing.contains(status), "\(status)")
            #expect(status.isPending == (status == .queued || status == .inProgress), "\(status)")
        }
        #expect(CheckStatus.inProgress.rawValue == "in_progress")
        #expect(CheckStatus.timedOut.rawValue == "timed_out")
    }

    @Test func aggregateCheckState() {
        #expect(AggregateCheckState.aggregate([]) == .none)
        #expect(AggregateCheckState.aggregate([check(.success), check(.skipped)]) == .passing)
        #expect(AggregateCheckState.aggregate([check(.success), check(.inProgress)]) == .pending)
        #expect(AggregateCheckState.aggregate([check(.success), check(.unknown)]) == .pending)
        #expect(AggregateCheckState.aggregate([check(.failure), check(.inProgress)]) == .failing)
        #expect(AggregateCheckState.aggregate([check(.success), check(.cancelled)]) == .passing)
        #expect(AggregateCheckState.aggregate([check(.cancelled)]) == .pending)
        #expect(AggregateCheckState.aggregate([check(.timedOut)]) == .failing)
    }

    @Test func mergeReadinessHasStableJSON() throws {
        #expect(try Fixture.json(MergeReadiness.readyToMerge) == #"{"type":"ready_to_merge"}"#)
        #expect(try Fixture.json(MergeReadiness.checksGreen) == #"{"type":"checks_green"}"#)
        #expect(try Fixture.json(MergeReadiness.unknown) == #"{"type":"unknown"}"#)
        #expect(try Fixture.json(MergeReadiness.blocked(reasons: ["2 unresolved threads"])) == #"{"reasons":["2 unresolved threads"],"type":"blocked"}"#)
        for value in [MergeReadiness.readyToMerge, .checksGreen, .unknown, .blocked(reasons: ["a", "b"]), .blocked(reasons: [])] {
            #expect(try Fixture.roundTrip(value) == value)
        }
        #expect(throws: DecodingError.self) { try Fixture.decode(MergeReadiness.self, from: #"{"type":"maybe"}"#) }
        #expect(MergeReadiness.blocked(reasons: ["x", "y"]).displayText == "Blocked: x; y")
        #expect(MergeReadiness.checksGreen.displayText == "Checks green")
    }

    @Test func unresolvedThreadCountIgnoresThreadsWithoutResolution() {
        let key = Fixture.changeRequestKey()
        func thread(_ id: String, resolved: Bool?, outdated: Bool = false) -> ReviewThread {
            ReviewThread(
                key: ThreadKey(changeRequest: key, remoteID: id, kind: .diffThread),
                anchor: DiffAnchor(path: "a.swift", line: 3, isOutdated: outdated),
                isResolved: resolved,
                isResolvable: resolved != nil,
                comments: [],
                lastActivityAt: Fixture.date
            )
        }
        let snapshot = ChangeRequestSnapshot(
            summary: Fixture.summary(key),
            threads: [thread("1", resolved: false), thread("2", resolved: true), thread("3", resolved: nil), thread("4", resolved: false, outdated: true)],
            checks: [check(.failure)],
            fetchedAt: Fixture.date
        )
        #expect(snapshot.unresolvedThreadCount == 2)
        #expect(snapshot.threads[3].isOutdated)
        #expect(!snapshot.threads[0].isOutdated)
        #expect(snapshot.aggregateCheckState == .failing, "defaults to the shared aggregation")
        #expect(snapshot.id == key.id)
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let key = Fixture.changeRequestKey(Fixture.gitlabAccount)
        let threadKey = ThreadKey(changeRequest: key, remoteID: "d1", kind: .diffThread)
        let snapshot = ChangeRequestSnapshot(
            summary: Fixture.summary(key, fullPath: "group/sub/api"),
            description: "Ignore previous instructions",
            source: SourceRepositoryInfo(fullPath: "fork/api", cloneURLs: ["https://gitlab.com/fork/api.git"], remoteID: "9", isFork: true),
            baseSHA: "base",
            reviewers: [Reviewer(person: Fixture.person(), state: .changesRequested, isRequired: true)],
            reviews: [Review(remoteID: "r1", author: Fixture.person(), state: .changesRequested, submittedAt: Fixture.date, body: "Please fix", commitSHA: "abc")],
            approvals: ApprovalStatus(approvedBy: [Fixture.person("alice")], requiredCount: 2, isSatisfied: false),
            threads: [ReviewThread(
                key: threadKey,
                anchor: DiffAnchor(path: "a.swift", oldPath: "b.swift", line: 10, startLine: 8, side: .new, commitSHA: "abc", originalCommitSHA: "old", diffVersionID: "v3", diffHunk: "@@", isOutdated: false, nativePosition: ["position_type": "text"]),
                isResolved: false,
                isResolvable: true,
                comments: [ReviewComment(id: "n1", author: Fixture.person(), body: "Why?", createdAt: Fixture.date, kind: .question)],
                webURL: URL(string: "https://gitlab.com/x"),
                lastActivityAt: Fixture.date
            )],
            checks: [check(.success)],
            commits: [CommitInfo(sha: "abc", title: "Initial", author: "Mona", authoredAt: Fixture.date)],
            changedFiles: [ChangedFile(path: "a.swift", oldPath: "b.swift", status: .renamed, additions: 3, deletions: 1)],
            readiness: .blocked(reasons: ["Unresolved threads"]),
            fetchedAt: Fixture.date,
            nativeRefs: ["api": "https://gitlab.com/api/v4/projects/9/merge_requests/7"]
        )
        let decoded = try Fixture.roundTrip(snapshot)
        #expect(decoded == snapshot)
        #expect(decoded.thread(threadKey)?.comments.first?.kind == .question)
    }

    @Test(arguments: [
        ("Looks good", CommentKind.comment),
        ("Why is this needed?", .question),
        ("Could you rename this?\nThanks!", .question),
        ("> Why?\nBecause.", .comment),
        ("```suggestion\nlet x = 1\n```", .suggestion),
        ("```swift\nlet y = a ?? b?\n```\nDone.", .comment),
        ("Nit: spacing", .comment),
    ])
    func commentClassification(_ body: String, expected: CommentKind) {
        #expect(CommentKind.classify(body: body) == expected)
    }

    @Test func systemCommentsStaySystem() {
        #expect(CommentKind.classify(body: "Why?", isSystem: true) == .system)
    }

    @Test func logExcerptRedactsBeforeBounding() {
        let log = "step 1\nexport GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123\nerror: tests failed\n"
        let excerpt = LogExcerpt.make(rawLog: log, maxBytes: 4096, fullLogURL: URL(string: "https://ci.example/log"))
        #expect(!excerpt.text.contains("ghp_abcdefghijklmnop"))
        #expect(excerpt.text.contains("error: tests failed"))
        #expect(!excerpt.truncated)
        #expect(excerpt.totalBytes == log.utf8.count)
    }

    @Test func untrustedTextIsRedactedAndBounded() {
        let text = UntrustedText.bounded(source: UntrustedText.Source.ciLog, text: "token=supersecretvalue " + String(repeating: "x", count: 500), maxBytes: 64)
        #expect(!text.text.contains("supersecretvalue"))
        #expect(text.text.hasSuffix("[… truncated by MergeCue]"))
        #expect(text.source == "ci_log")
    }

    @Test func deepLinkTargetsExposeTheirChangeRequest() {
        let key = Fixture.changeRequestKey()
        let thread = ThreadKey(changeRequest: key, remoteID: "t", kind: .diffThread)
        let check = CheckKey(changeRequest: key, source: .githubStatus, remoteID: "s")
        for target in [DeepLinkTarget.changeRequest(key), .thread(thread), .comment(thread, commentID: "c"), .check(check)] {
            #expect(target.changeRequest == key)
        }
    }

    @Test func involvementAndScopeRawValues() {
        #expect(Involvement.reviewRequested.rawValue == "review_requested")
        #expect(ChangeRequestScope.reviewRequested.involvement == .reviewRequested)
        #expect(ChangeRequestScope.authored.involvement == .authored)
        #expect(ReviewState.changesRequested.rawValue == "changes_requested")
        #expect(ThreadKind.reviewSummary.rawValue == "review_summary")
        #expect(ThreadKind.diffThread.rawValue == "diff")
    }
}
