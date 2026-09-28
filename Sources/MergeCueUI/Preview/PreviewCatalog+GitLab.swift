import Foundation
import MergeCueCore

nonisolated extension PreviewWorld {
    func gitlabPayments42(logs: inout [String: LogExcerpt]) -> ChangeRequestSnapshot {
        let repo = repository(gl, id: "48213377", path: "acme/payments-api")
        let priya = person("priya.n", "Priya Nair", .gitlab)
        let head = "3a7c9e1b5d2f4a6c8e0b1d3f5a7c9e1b3d5f7a9c"
        let summary = summary(repo, remoteID: "301442210", number: 42, title: "Migrate ledger writer to async batching",
                              author: mona(.gitlab), involvement: [.authored], source: "mona/async-ledger-batching", head: head,
                              created: ago(days: 1), updated: ago(minutes: 9))
        let suggestion = thread(summary, id: "5c1f9e0d2b7a4e6c8d0f1a3b5c7d9e1f2a4b6c8d", anchor: DiffAnchor(
            path: "internal/ledger/batch_writer.go", line: 57, side: .new, commitSHA: head, diffVersionID: "881234019",
            diffHunk: """
            @@ -51,8 +51,10 @@ func (w *BatchWriter) Append(ctx context.Context, e Entry) error {
             \tw.mu.Lock()
             \tdefer w.mu.Unlock()
             \tw.buf = append(w.buf, e)
            -\treturn nil
            +\treturn w.flush(ctx)
             }
            """,
            nativePosition: ["new_line": "57", "position_type": "text"]
        ), resolved: false, comments: [
            comment("2144870011", priya, """
            Flushing on every append defeats the batching. Flush on size or interval instead:

            ```suggestion
            \tif len(w.buf) >= w.maxBatch || time.Since(w.lastFlush) >= w.interval {
            \t\treturn w.flush(ctx)
            \t}
            \treturn nil
            ```
            """, at: ago(hours: 2)),
        ])
        let integration = check(summary, .gitlabJob, id: "7819340021", name: "test:integration", status: .failure, required: true,
                                started: ago(minutes: 16), completed: ago(minutes: 9), summaryText: "Job failed: exit code 1",
                                detailsPath: "-/jobs/7819340021")
        logs[integration.key.id] = LogExcerpt.make(rawLog: """
        $ go test ./internal/ledger/... -run Integration -count=1
        === RUN   TestBatchWriterIntegration
        === RUN   TestBatchWriterIntegration/preserves_order_across_batches
        --- PASS: TestBatchWriterIntegration/preserves_order_across_batches (0.84s)
        === RUN   TestBatchWriterIntegration/flushes_on_interval
            batch_writer_integration_test.go:88: expected 1 flush within 250ms, got 0 (ledger rows: 0)
        --- FAIL: TestBatchWriterIntegration/flushes_on_interval (5.01s)
        --- FAIL: TestBatchWriterIntegration (5.86s)
        FAIL
        FAIL\tgitlab.com/acme/payments-api/internal/ledger\t6.214s
        Cleaning up project directory and file based variables
        ERROR: Job failed: exit code 1
        """, maxBytes: 16_384, fullLogURL: integration.detailsURL)
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Replaces synchronous ledger inserts with a batched writer (size- or time-based flush).",
            source: SourceRepositoryInfo(fullPath: repo.fullPath, cloneURLs: repo.cloneURLs, remoteID: repo.key.remoteRepoID),
            baseSHA: "d2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0",
            reviewers: [Reviewer(person: priya, state: .commented, isRequired: nil)],
            reviews: [],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: 1, isSatisfied: false),
            threads: [suggestion],
            checks: [
                check(summary, .gitlabPipeline, id: "1402981", name: "pipeline #1402981", status: .failure,
                      started: ago(minutes: 16), completed: ago(minutes: 9), detailsPath: "-/pipelines/1402981"),
                integration,
                check(summary, .gitlabJob, id: "7819340019", name: "lint", status: .success, completed: ago(minutes: 14),
                      detailsPath: "-/jobs/7819340019"),
                check(summary, .gitlabJob, id: "7819340020", name: "build", status: .success, completed: ago(minutes: 13),
                      detailsPath: "-/jobs/7819340020"),
            ],
            commits: [
                CommitInfo(sha: "8b2d4f6", title: "Introduce BatchWriter", author: "mona-dev", authoredAt: ago(days: 1)),
                CommitInfo(sha: "3a7c9e1", title: "Flush ledger batches from Append", author: "mona-dev", authoredAt: ago(minutes: 20)),
            ],
            changedFiles: [
                ChangedFile(path: "internal/ledger/batch_writer.go", status: .added, additions: 96, deletions: 0),
                ChangedFile(path: "internal/ledger/writer.go", status: .modified, additions: 7, deletions: 22),
                ChangedFile(path: "internal/ledger/batch_writer_integration_test.go", status: .added, additions: 118, deletions: 0),
            ],
            readiness: .blocked(reasons: ["Pipeline failed", "Approval required"]),
            fetchedAt: ago(minutes: 11),
            nativeRefs: ["project_id": "48213377", "mr_iid": "42", "mr_id": "301442210"]
        )
    }

    func gitlabLedger318() -> ChangeRequestSnapshot {
        let repo = repository(gl, id: "48213501", path: "acme-platform/ledger-service")
        let oscar = person("oscar.b", "Oscar Brandt", .gitlab)
        let head = "6d8f0a2c4e6b8d0f2a4c6e8b0d2f4a6c8e0b2d4f"
        let summary = summary(repo, remoteID: "301450318", number: 318, title: "Split reconciliation job by region",
                              author: mona(.gitlab), involvement: [.authored], source: "mona/reconcile-per-region", head: head,
                              created: ago(days: 2), updated: ago(minutes: 3))
        let review = thread(summary, id: "9e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f", anchor: DiffAnchor(
            path: "internal/reconcile/job.go", line: 142, side: .new, commitSHA: head, diffVersionID: "881240777",
            diffHunk: """
            @@ -136,9 +136,15 @@ func (j *Job) Run(ctx context.Context) error {
             \tfor _, region := range j.regions {
            -\t\tj.reconcile(ctx, region)
            +\t\tif err := j.reconcile(ctx, region); err != nil {
            +\t\t\tj.log.Warn("reconcile failed", "region", region)
            +\t\t}
             \t}
             \treturn nil
            """
        ), resolved: false, comments: [
            comment("2144812001", oscar, "`reconcile(region:)` swallows the error from the ledger client — a failed region will be reported as reconciled.",
                    at: ago(hours: 1)),
            comment("2144813377", mona(.gitlab), "Right, I'll propagate it and mark the region as failed.", at: ago(minutes: 50), replyTo: "2144812001"),
        ])
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Runs reconciliation per region so a slow region no longer delays the others.",
            reviewers: [Reviewer(person: oscar, state: .commented, isRequired: true)],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: 1, isSatisfied: false),
            threads: [review],
            checks: [
                check(summary, .gitlabPipeline, id: "1402990", name: "pipeline #1402990", status: .success,
                      completed: ago(hours: 1), detailsPath: "-/pipelines/1402990"),
            ],
            commits: [CommitInfo(sha: "6d8f0a2", title: "Reconcile regions independently", author: "mona-dev", authoredAt: ago(days: 2))],
            changedFiles: [
                ChangedFile(path: "internal/reconcile/job.go", status: .modified, additions: 44, deletions: 12),
                ChangedFile(path: "internal/reconcile/job_test.go", status: .modified, additions: 31, deletions: 0),
            ],
            readiness: .blocked(reasons: ["1 unresolved thread"]),
            fetchedAt: ago(minutes: 11)
        )
    }

    func gitlabIOS77() -> ChangeRequestSnapshot {
        let repo = repository(gl, id: "48213777", path: "acme-platform/mobile/ios-app")
        let sara = person("sara.l", "Sara Lindqvist", .gitlab)
        let summary = summary(repo, remoteID: "301460077", number: 77, title: "Offline queue for receipts",
                              author: sara, involvement: [.reviewRequested], source: "sara/offline-receipts",
                              head: "a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9", created: ago(hours: 7), updated: ago(minutes: 35))
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Queues receipt uploads while offline and retries with exponential backoff.",
            reviewers: [Reviewer(person: mona(.gitlab), state: .pending, isRequired: true)],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: 2, isSatisfied: false),
            checks: [check(summary, .gitlabPipeline, id: "1402870", name: "pipeline #1402870", status: .success,
                           completed: ago(minutes: 40), detailsPath: "-/pipelines/1402870")],
            commits: [CommitInfo(sha: "a0b1c2d", title: "ReceiptUploadQueue", author: "sara.l", authoredAt: ago(hours: 7))],
            changedFiles: [ChangedFile(path: "App/Receipts/ReceiptUploadQueue.swift", status: .added, additions: 187, deletions: 0)],
            readiness: .checksGreen,
            fetchedAt: ago(minutes: 11)
        )
    }

    func gitlabPayments39() -> ChangeRequestSnapshot {
        let repo = repository(gl, id: "48213377", path: "acme/payments-api")
        let priya = person("priya.n", "Priya Nair", .gitlab)
        let summary = summary(repo, remoteID: "301441939", number: 39, title: "Fix currency rounding in payout report",
                              author: mona(.gitlab), involvement: [.authored], source: "mona/payout-rounding",
                              head: "f0e1d2c3b4a5968778695a4b3c2d1e0f9a8b7c6d", created: ago(days: 4), updated: ago(days: 1), state: .merged)
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Rounds payouts with banker's rounding per currency exponent.",
            reviewers: [Reviewer(person: priya, state: .approved, isRequired: true)],
            approvals: ApprovalStatus(approvedBy: [priya], requiredCount: 1, isSatisfied: true),
            checks: [check(summary, .gitlabPipeline, id: "1401120", name: "pipeline #1401120", status: .success,
                           completed: ago(days: 1), detailsPath: "-/pipelines/1401120")],
            commits: [CommitInfo(sha: "f0e1d2c", title: "Use per-currency exponent when rounding payouts", author: "mona-dev", authoredAt: ago(days: 2))],
            changedFiles: [ChangedFile(path: "internal/payout/report.go", status: .modified, additions: 9, deletions: 4)],
            readiness: .unknown,
            fetchedAt: ago(minutes: 11)
        )
    }
}
