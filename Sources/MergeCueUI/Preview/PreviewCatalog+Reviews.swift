import Foundation
import MergeCueCore

/// Preview pull/merge requests of others that Mona reviews, one per Reviews state (D53). Preview data only.
nonisolated extension PreviewWorld {
    /// Bitbucket: Mona approved, Nina pushed two commits and the repository reset approvals → re-approval needed.
    func bitbucketRisk12() -> ChangeRequestSnapshot {
        let repo = repository(bb, id: "{3c2d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f}", path: "acme/risk-rules")
        let nina = person("nina.w", "Nina Weber", .bitbucketCloud)
        let approvedHead = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
        let head = "c3d4e5f60718293a4b5c6d7e8f901234567890ab"
        let summary = summary(repo, remoteID: "12", number: 12, title: "Block card testing bursts per BIN",
                              author: nina, involvement: [.reviewRequested], source: "nina/bin-bursts",
                              head: head, created: ago(days: 2), updated: ago(minutes: 18))
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Adds a per-BIN burst rule so card testing from one issuer range is blocked within a minute.",
            reviewers: [Reviewer(person: mona(.bitbucketCloud), state: .commented, isRequired: nil)],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: nil, isSatisfied: nil),
            checks: [check(summary, .bitbucketStatus, id: "rules-lint-12", name: "rules-lint", status: .success, completed: ago(minutes: 12),
                           detailsPath: "pipelines/results/341")],
            commits: [
                CommitInfo(sha: approvedHead, title: "Per-BIN burst rule", author: "nina.w", authoredAt: ago(days: 2)),
                CommitInfo(sha: "b2c3d4e5f60718293a4b5c6d7e8f9012345678ab", title: "Cover prepaid ranges", author: "nina.w", authoredAt: ago(minutes: 30)),
                CommitInfo(sha: head, title: "Address review: window in seconds", author: "nina.w", authoredAt: ago(minutes: 20)),
            ],
            changedFiles: [ChangedFile(path: "rules/bin_bursts.yaml", status: .added, additions: 24, deletions: 0)],
            readiness: .checksGreen,
            fetchedAt: ago(minutes: 4),
            viewerReview: ViewerReviewMemory(verdict: .commented, verdictHeadSHA: head, verdictSeenAt: ago(minutes: 18),
                                             lostApprovalAt: ago(minutes: 18), lostApprovalHeadSHA: head)
        )
    }

    /// GitLab: Mona commented, Oscar pushed a fix since → updated since your review.
    func gitlabLedger322() -> ChangeRequestSnapshot {
        let repo = repository(gl, id: "48120773", path: "acme/ledger-service")
        let oscar = person("oscar.b", "Oscar Brandt", .gitlab)
        let reviewedHead = "d4e5f60718293a4b5c6d7e8f901234567890abcd"
        let head = "f60718293a4b5c6d7e8f901234567890abcdef12"
        let summary = summary(repo, remoteID: "322", number: 322, title: "Paginate ledger exports",
                              author: oscar, involvement: [.participated], source: "oscar/paginate-exports",
                              head: head, created: ago(days: 1), updated: ago(minutes: 40))
        let thread = thread(summary, id: "d-322", anchor: DiffAnchor(path: "exports/writer.go", line: 88, side: .new), resolved: false,
                            comments: [comment("n-322-1", mona(.gitlab), "Page size should come from config, not a constant.", at: ago(hours: 20))])
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Streams exports in pages of 5,000 rows instead of loading the whole ledger.",
            reviewers: [Reviewer(person: mona(.gitlab), state: .commented, isRequired: nil)],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: 1, isSatisfied: false),
            threads: [thread],
            checks: [check(summary, .gitlabPipeline, id: "1403310", name: "pipeline", status: .inProgress, started: ago(minutes: 6),
                           detailsPath: "-/pipelines/1403310")],
            commits: [
                CommitInfo(sha: reviewedHead, title: "Paginate exports", author: "oscar.b", authoredAt: ago(days: 1)),
                CommitInfo(sha: head, title: "Read page size from config", author: "oscar.b", authoredAt: ago(minutes: 45)),
            ],
            changedFiles: [ChangedFile(path: "exports/writer.go", status: .modified, additions: 41, deletions: 12)],
            readiness: .unknown,
            fetchedAt: ago(minutes: 4),
            viewerReview: ViewerReviewMemory(verdict: .commented, verdictHeadSHA: reviewedHead, verdictSeenAt: ago(hours: 20))
        )
    }

    /// GitHub: Mona requested changes; nothing new from the author yet → waiting on author.
    func githubPayments64() -> ChangeRequestSnapshot {
        let repo = repository(gh, id: "701122334", path: "acme/payments-api")
        let tkim = person("tkim", "Taylor Kim", .github)
        let head = "0718293a4b5c6d7e8f901234567890abcdef1234"
        let summary = summary(repo, remoteID: "PR_kwDO64", number: 64, title: "Retry webhook delivery with jitter",
                              author: tkim, involvement: [.participated], source: "tkim/webhook-jitter",
                              head: head, created: ago(days: 3), updated: ago(hours: 5))
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Adds full jitter to webhook retries to avoid thundering herds after an outage.",
            reviewers: [Reviewer(person: mona(.github), state: .changesRequested, isRequired: true)],
            reviews: [Review(remoteID: "PRR_64_1", author: mona(.github), state: .changesRequested, submittedAt: ago(hours: 5),
                             body: "The retry cap needs a test before this ships.", commitSHA: head)],
            approvals: ApprovalStatus(approvedBy: [], requiredCount: 1, isSatisfied: false),
            checks: [check(summary, .githubCheckRun, id: "64001", name: "ci / unit-tests", status: .success, completed: ago(hours: 6),
                           detailsPath: "actions/runs/64001")],
            commits: [CommitInfo(sha: head, title: "Jittered webhook retries", author: "tkim", authoredAt: ago(days: 3))],
            readiness: .blocked(reasons: ["Review required"]),
            fetchedAt: ago(minutes: 4)
        )
    }

    /// Bitbucket: Mona approved; one commit landed since (approvals not reset in this repository) → approved, watching.
    func bitbucketCheckout133() -> ChangeRequestSnapshot {
        let repo = repository(bb, id: "{8f1e2d3c-4b5a-4968-8778-695a4b3c2d1e}", path: "acme/checkout-web")
        let dchen = person("dchen", "Daniel Chen", .bitbucketCloud)
        let approvedHead = "18293a4b5c6d7e8f901234567890abcdef123456"
        let head = "293a4b5c6d7e8f901234567890abcdef12345678"
        let summary = summary(repo, remoteID: "133", number: 133, title: "Persist cart across tabs",
                              author: dchen, involvement: [.reviewRequested], source: "dchen/cart-sync",
                              head: head, created: ago(days: 2), updated: ago(hours: 1))
        return ChangeRequestSnapshot(
            summary: summary,
            description: "Syncs the cart through BroadcastChannel so a second tab shows the same items.",
            reviewers: [Reviewer(person: mona(.bitbucketCloud), state: .approved, isRequired: nil),
                        Reviewer(person: person("lucia.m", "Lucía Méndez", .bitbucketCloud), state: .pending, isRequired: nil)],
            approvals: ApprovalStatus(approvedBy: [mona(.bitbucketCloud)], requiredCount: nil, isSatisfied: nil),
            checks: [check(summary, .bitbucketStatus, id: "e2e-133", name: "e2e / chrome", status: .success, completed: ago(minutes: 50),
                           detailsPath: "pipelines/results/352")],
            commits: [
                CommitInfo(sha: approvedHead, title: "Cart sync via BroadcastChannel", author: "dchen", authoredAt: ago(days: 2)),
                CommitInfo(sha: head, title: "Fix typo in cart badge", author: "dchen", authoredAt: ago(hours: 1)),
            ],
            readiness: .checksGreen,
            fetchedAt: ago(minutes: 4),
            viewerReview: ViewerReviewMemory(verdict: .approved, verdictHeadSHA: approvedHead, verdictSeenAt: ago(hours: 20))
        )
    }

    /// GitHub: Mona approved and nothing changed → approved, watching until merge.
    func githubDashboard310() -> ChangeRequestSnapshot {
        let repo = repository(gh, id: "701199887", path: "acme/merchant-dashboard")
        let jpark = person("jpark", "Jin Park", .github)
        let head = "3a4b5c6d7e8f901234567890abcdef1234567890"
        let summary = summary(repo, remoteID: "PR_kwDO310", number: 310, title: "Export payouts as CSV",
                              author: jpark, involvement: [.participated], source: "jpark/payout-csv",
                              head: head, created: ago(days: 4), updated: ago(hours: 9))
        return ChangeRequestSnapshot(
            summary: summary,
            reviewers: [Reviewer(person: mona(.github), state: .approved, isRequired: true)],
            reviews: [Review(remoteID: "PRR_310_1", author: mona(.github), state: .approved, submittedAt: ago(hours: 9), commitSHA: head)],
            approvals: ApprovalStatus(approvedBy: [mona(.github)], requiredCount: 2, isSatisfied: false),
            checks: [check(summary, .githubCheckRun, id: "310001", name: "ci / build", status: .success, completed: ago(hours: 9),
                           detailsPath: "actions/runs/310001")],
            commits: [CommitInfo(sha: head, title: "Payout CSV export", author: "jpark", authoredAt: ago(days: 4))],
            readiness: .blocked(reasons: ["Review required"]),
            fetchedAt: ago(minutes: 4)
        )
    }
}
