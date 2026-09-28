import Foundation
import MergeCueCore

/// Every synthetic change request of the preview, by name, plus bounded CI log excerpts keyed by `CheckKey.id`.
nonisolated struct PreviewCatalog {
    var ghPayments42: ChangeRequestSnapshot
    var ghPayments61: ChangeRequestSnapshot
    var ghDashboard318: ChangeRequestSnapshot
    var ghPayments57: ChangeRequestSnapshot
    var glPayments42: ChangeRequestSnapshot
    var glLedger318: ChangeRequestSnapshot
    var glIOS77: ChangeRequestSnapshot
    var glPayments39: ChangeRequestSnapshot
    var bbPayments42: ChangeRequestSnapshot
    var bbCheckout128: ChangeRequestSnapshot
    var bbRisk9: ChangeRequestSnapshot
    var bbCheckout131: ChangeRequestSnapshot
    var logs: [String: LogExcerpt]

    var all: [ChangeRequestSnapshot] {
        [ghPayments42, ghPayments61, ghDashboard318, ghPayments57,
         glPayments42, glLedger318, glIOS77, glPayments39,
         bbPayments42, bbCheckout128, bbRisk9, bbCheckout131]
    }
}

nonisolated extension PreviewWorld {
    func makeCatalog() -> PreviewCatalog {
        var logs: [String: LogExcerpt] = [:]
        let gh42 = githubPayments42(logs: &logs)
        let gl42 = gitlabPayments42(logs: &logs)
        let bb131 = bitbucketCheckout131(logs: &logs)
        return PreviewCatalog(
            ghPayments42: gh42,
            ghPayments61: githubPayments61(),
            ghDashboard318: githubDashboard318(),
            ghPayments57: githubPayments57(),
            glPayments42: gl42,
            glLedger318: gitlabLedger318(),
            glIOS77: gitlabIOS77(),
            glPayments39: gitlabPayments39(),
            bbPayments42: bitbucketPayments42(),
            bbCheckout128: bitbucketCheckout128(),
            bbRisk9: bitbucketRisk9(),
            bbCheckout131: bb131,
            logs: logs
        )
    }

    // MARK: GitHub

    func githubPayments42(logs: inout [String: LogExcerpt]) -> ChangeRequestSnapshot {
        let repo = repository(gh, id: "701122334", path: "acme/payments-api")
        let mona = mona(.github)
        let rkoval = person("rkoval", "Roman Koval", .github)
        let jpark = person("jpark", "Jin Park", .github)
        let lin = person("lin-sec", "Lin Zhao", .github)
        let head = "9f2c4e1a7b3d5f60812c9e4a1b2c3d4e5f607182"
        let summary = summary(repo, remoteID: "2109384756", number: 42, title: "Add idempotency keys to refund endpoint",
                              author: mona, involvement: [.authored], source: "feature/refund-idempotency", head: head,
                              created: ago(days: 2), updated: ago(minutes: 6))
        let blocking = thread(summary, id: "PRRT_kwDOH1a2b3c4", anchor: DiffAnchor(
            path: "Sources/Refunds/RefundController.swift", line: 88, startLine: 84, side: .new, commitSHA: head,
            diffHunk: """
            @@ -80,10 +80,14 @@ struct RefundController {
                 func create(_ request: RefundRequest) async throws -> Refund {
                     let charge = try await charges.find(request.chargeID)
            -        return try await processor.refund(charge, amount: request.amount)
            +        let refund = try await processor.refund(charge, amount: request.amount)
            +        try await idempotency.store(request.idempotencyKey, response: refund)
            +        try await ledger.record(refund)
            +        return refund
                 }
            """,
            nativePosition: ["line": "88", "side": "RIGHT"]
        ), resolved: false, comments: [
            comment("1893001101", rkoval, """
            This still double-refunds when the client retries after a gateway timeout: `processor.refund` runs \
            before we look at the idempotency key. Please check the key (and short-circuit with the stored \
            response) before calling the processor.
            """, at: ago(minutes: 40), kind: .comment),
            comment("1893001175", mona, "Good catch. Should the key be scoped per merchant or globally?", at: ago(minutes: 32), replyTo: "1893001101"),
            comment("1893001244", rkoval, "Per merchant — two merchants can legitimately send the same key. Store `(merchant_id, key)`.",
                    at: ago(minutes: 20), replyTo: "1893001101"),
            comment("1893001302", jpark, "+1. And please persist it with a 24 h TTL so retries after a deploy still dedupe.",
                    at: ago(minutes: 6), replyTo: "1893001101"),
        ])
        let outdated = thread(summary, id: "PRRT_kwDOH1a2b3c9", anchor: DiffAnchor(
            path: "Sources/Refunds/RefundAmount.swift", line: 31, side: .new,
            commitSHA: nil, originalCommitSHA: "4be91c2d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b",
            diffHunk: """
            @@ -27,7 +27,7 @@ enum RefundAmount {
                 static func validate(_ amount: Double, against charge: Charge) throws {
            -        guard amount > 0 else { throw RefundError.nonPositive }
            +        guard amount > 0, amount <= charge.amount else { throw RefundError.exceedsCharge }
                 }
            """,
            isOutdated: true, nativePosition: ["original_line": "31"]
        ), resolved: true, comments: [
            comment("1892880410", jpark, "Can we use `Decimal` for money here instead of `Double`?", at: ago(days: 1)),
            comment("1892881022", mona, "Switched to `Decimal` in 4be91c2.", at: ago(hours: 23), replyTo: "1892880410"),
        ])
        let conversation = thread(summary, id: ThreadKey.githubIssueCommentPrefix + "2011450987", kind: .conversation, resolved: nil,
                                  resolvable: false, comments: [
            comment("2011450987", lin, "Security sign-off: fine once the replay window is bounded. Please keep PII out of the stored response body.",
                    at: ago(hours: 2)),
        ])
        let unit = check(summary, .githubCheckRun, id: "28113390021", name: "ci / unit-tests", status: .failure, required: true,
                         started: ago(minutes: 14), completed: ago(minutes: 9), summaryText: "2 of 14 tests failed",
                         detailsPath: "actions/runs/11873020011/job/28113390021")
        logs[unit.key.id] = LogExcerpt.make(rawLog: """
        Test Suite 'RefundIdempotencyTests' started at 2026-09-28 13:31:02.114
        Test Case '-[RefundsTests.RefundIdempotencyTests testReplayReturnsOriginalResponse]' started.
        Test Case '-[RefundsTests.RefundIdempotencyTests testReplayReturnsOriginalResponse]' passed (0.041 seconds).
        Test Case '-[RefundsTests.RefundIdempotencyTests testConcurrentRetriesRefundOnce]' started.
        /work/payments-api/Tests/RefundsTests/RefundIdempotencyTests.swift:74: error: -[RefundsTests.RefundIdempotencyTests testConcurrentRetriesRefundOnce] : XCTAssertEqual failed: ("2") is not equal to ("1") - processor.refund called more than once
        Test Case '-[RefundsTests.RefundIdempotencyTests testConcurrentRetriesRefundOnce]' failed (0.212 seconds).
        Test Case '-[RefundsTests.RefundIdempotencyTests testKeyScopedPerMerchant]' started.
        /work/payments-api/Tests/RefundsTests/RefundIdempotencyTests.swift:98: error: -[RefundsTests.RefundIdempotencyTests testKeyScopedPerMerchant] : XCTAssertNil failed: "Refund(id: re_demo_0042)" - key from merchant B replayed merchant A's refund
        Test Case '-[RefundsTests.RefundIdempotencyTests testKeyScopedPerMerchant]' failed (0.018 seconds).
        Test Suite 'RefundIdempotencyTests' failed at 2026-09-28 13:31:02.731.
        \t Executed 14 tests, with 2 failures (0 unexpected) in 0.611 (0.618) seconds
        ##[error]Process completed with exit code 1.
        """, maxBytes: 16_384, fullLogURL: unit.detailsURL)
        return ChangeRequestSnapshot(
            summary: summary,
            description: """
            Adds an `Idempotency-Key` check to `POST /v1/refunds` so client retries after a timeout can't issue a second refund.

            - Stores keys per merchant with a 24 h TTL
            - Returns the original response for replays
            - Adds `RefundIdempotencyTests`
            """,
            source: SourceRepositoryInfo(fullPath: repo.fullPath, cloneURLs: repo.cloneURLs, remoteID: repo.key.remoteRepoID),
            baseSHA: "1c0ffee2d4b6a8c0e2f4a6b8c0d2e4f6a8b0c2d4",
            reviewers: [Reviewer(person: rkoval, state: .changesRequested, isRequired: true),
                        Reviewer(person: jpark, state: .approved, isRequired: true)],
            reviews: [Review(remoteID: "2345001", author: jpark, state: .approved, submittedAt: ago(hours: 3), commitSHA: head),
                      Review(remoteID: "2345117", author: rkoval, state: .changesRequested, submittedAt: ago(minutes: 40),
                             body: "One blocking issue on retries — see inline.", commitSHA: head)],
            approvals: ApprovalStatus(approvedBy: [jpark], requiredCount: 2, isSatisfied: false),
            threads: [blocking, outdated, conversation],
            checks: [
                unit,
                check(summary, .githubCheckRun, id: "28113390022", name: "ci / lint", status: .success, required: true,
                      started: ago(minutes: 14), completed: ago(minutes: 12), detailsPath: "actions/runs/11873020011/job/28113390022"),
                check(summary, .githubCheckRun, id: "28113390023", name: "ci / build (macos-15)", status: .success, required: true,
                      started: ago(minutes: 14), completed: ago(minutes: 10), detailsPath: "actions/runs/11873020011/job/28113390023"),
                check(summary, .githubStatus, id: "codecov/patch", name: "codecov/patch", status: .neutral,
                      completed: ago(minutes: 9), summaryText: "83% of diff hit (target 85%)", detailsPath: "pull/42/checks"),
            ],
            commits: [
                CommitInfo(sha: "7a1d3e9", title: "Add IdempotencyStore with per-merchant keys", author: "mona-dev", authoredAt: ago(days: 2)),
                CommitInfo(sha: "4be91c2", title: "Use Decimal for refund amounts", author: "mona-dev", authoredAt: ago(hours: 23)),
                CommitInfo(sha: "b0e4417", title: "Store idempotent response after refund", author: "mona-dev", authoredAt: ago(hours: 4)),
                CommitInfo(sha: "9f2c4e1", title: "Add RefundIdempotencyTests", author: "mona-dev", authoredAt: ago(minutes: 16)),
            ],
            changedFiles: [
                ChangedFile(path: "Sources/Refunds/RefundController.swift", status: .modified, additions: 38, deletions: 6),
                ChangedFile(path: "Sources/Refunds/IdempotencyStore.swift", status: .added, additions: 112, deletions: 0),
                ChangedFile(path: "Sources/Refunds/RefundAmount.swift", status: .modified, additions: 4, deletions: 4),
                ChangedFile(path: "Tests/RefundsTests/RefundIdempotencyTests.swift", status: .added, additions: 146, deletions: 0),
                ChangedFile(path: "Migrations/0042_refund_idempotency.sql", status: .added, additions: 18, deletions: 0),
            ],
            readiness: .blocked(reasons: ["Changes requested by @rkoval", "1 failing required check"]),
            fetchedAt: ago(minutes: 2),
            nativeRefs: ["api": "https://api.github.com/repos/acme/payments-api/pulls/42", "node_id": "PR_kwDOH1a2b3c0"]
        )
    }

    func githubPayments61() -> ChangeRequestSnapshot {
        let repo = repository(gh, id: "701122334", path: "acme/payments-api")
        let tkim = person("tkim", "Taylor Kim", .github)
        let head = "c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7"
        let summary = summary(repo, remoteID: "2109455120", number: 61, title: "Retry policy for card network timeouts",
                              author: mona(.github), involvement: [.authored], source: "feature/network-retry", head: head,
                              created: ago(days: 1), updated: ago(minutes: 14))
        let suggestion = thread(summary, id: "PRRT_kwDOH1a2b4d1", anchor: DiffAnchor(
            path: "Sources/Payments/RetryPolicy.swift", line: 22, side: .new, commitSHA: head,
            diffHunk: """
            @@ -18,6 +18,9 @@ struct RetryPolicy {
                 func delay(forAttempt attempt: Int) -> TimeInterval {
            -        baseDelay
            +        let delay = baseDelay * pow(2, Double(attempt))
            +        return min(maxDelay, delay)
                 }
            """
        ), resolved: false, comments: [
            comment("1894410032", tkim, """
            Fixed exponential delays will synchronize retries across pods after a network blip. Suggest full jitter:

            ```suggestion
                    let delay = Double.random(in: 0...min(maxDelay, baseDelay * pow(2, Double(attempt))))
            ```
            """, at: ago(hours: 3)),
        ])
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Retries card-network calls that time out, with exponential backoff capped at `maxDelay`.",
            baseSHA: "0badc0de1a2b3c4d5e6f708192a3b4c5d6e7f809",
            reviewers: [Reviewer(person: tkim, state: .commented, isRequired: true)],
            reviews: [Review(remoteID: "2345201", author: tkim, state: .commented, submittedAt: ago(hours: 3), commitSHA: head)],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: 1, isSatisfied: false),
            threads: [suggestion],
            checks: [
                check(summary, .githubCheckRun, id: "28113500101", name: "ci / unit-tests", status: .success, required: true,
                      started: ago(hours: 1), completed: ago(minutes: 52), detailsPath: "actions/runs/11873100001/job/28113500101"),
                check(summary, .githubCheckRun, id: "28113500102", name: "ci / lint", status: .success, required: true,
                      completed: ago(minutes: 55), detailsPath: "actions/runs/11873100001/job/28113500102"),
            ],
            commits: [CommitInfo(sha: "c4d5e6f", title: "Add RetryPolicy for card network timeouts", author: "mona-dev", authoredAt: ago(days: 1))],
            changedFiles: [
                ChangedFile(path: "Sources/Payments/RetryPolicy.swift", status: .added, additions: 41, deletions: 0),
                ChangedFile(path: "Sources/Payments/CardNetworkClient.swift", status: .modified, additions: 12, deletions: 3),
                ChangedFile(path: "Tests/PaymentsTests/RetryPolicyTests.swift", status: .added, additions: 58, deletions: 0),
            ],
            readiness: .blocked(reasons: ["Review required"]),
            fetchedAt: ago(minutes: 2)
        )
    }

    func githubDashboard318() -> ChangeRequestSnapshot {
        let repo = repository(gh, id: "701122399", path: "acme/web-dashboard")
        let jpark = person("jpark", "Jin Park", .github)
        let summary = summary(repo, remoteID: "2109500318", number: 318, title: "Dark mode for the settings panel",
                              author: jpark, involvement: [.reviewRequested], source: "jpark/settings-dark-mode",
                              head: "e1f2a3b4c5d6e7f8091a2b3c4d5e6f7081920a1b", created: ago(hours: 5), updated: ago(minutes: 25))
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Adds dark-mode tokens to the settings panel and fixes contrast of disabled toggles.",
            reviewers: [Reviewer(person: mona(.github), state: .pending, isRequired: true)],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: 1, isSatisfied: false),
            checks: [
                check(summary, .githubCheckRun, id: "28113600201", name: "build", status: .inProgress, started: ago(minutes: 4),
                      detailsPath: "actions/runs/11873200001/job/28113600201"),
                check(summary, .githubCheckRun, id: "28113600202", name: "e2e (chromium)", status: .queued,
                      detailsPath: "actions/runs/11873200001/job/28113600202"),
            ],
            commits: [CommitInfo(sha: "e1f2a3b", title: "Settings panel dark-mode tokens", author: "jpark", authoredAt: ago(hours: 5))],
            changedFiles: [
                ChangedFile(path: "src/settings/SettingsPanel.tsx", status: .modified, additions: 64, deletions: 21),
                ChangedFile(path: "src/theme/tokens.css", status: .modified, additions: 18, deletions: 2),
            ],
            readiness: .unknown,
            fetchedAt: ago(minutes: 2)
        )
    }

    func githubPayments57() -> ChangeRequestSnapshot {
        let repo = repository(gh, id: "701122334", path: "acme/payments-api")
        let rkoval = person("rkoval", "Roman Koval", .github)
        let summary = summary(repo, remoteID: "2109422057", number: 57, title: "Bump swift-nio to 2.81.0",
                              author: mona(.github), involvement: [.authored], source: "deps/swift-nio-2.81",
                              head: "5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081", created: ago(days: 3), updated: ago(hours: 2))
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Routine dependency update. No API changes.",
            reviewers: [Reviewer(person: rkoval, state: .approved, isRequired: true)],
            reviews: [Review(remoteID: "2344901", author: rkoval, state: .approved, submittedAt: ago(hours: 2))],
            approvals: ApprovalStatus(approvedBy: [rkoval], requiredCount: 1, isSatisfied: true),
            checks: [
                check(summary, .githubCheckRun, id: "28113400301", name: "ci / unit-tests", status: .success, required: true,
                      completed: ago(hours: 3), detailsPath: "actions/runs/11873000301/job/28113400301"),
                check(summary, .githubCheckRun, id: "28113400302", name: "ci / lint", status: .success, required: true,
                      completed: ago(hours: 3), detailsPath: "actions/runs/11873000301/job/28113400302"),
            ],
            commits: [CommitInfo(sha: "5e6f708", title: "Bump swift-nio to 2.81.0", author: "mona-dev", authoredAt: ago(days: 3))],
            changedFiles: [ChangedFile(path: "Package.resolved", status: .modified, additions: 3, deletions: 3)],
            readiness: .readyToMerge,
            fetchedAt: ago(minutes: 2)
        )
    }
}
