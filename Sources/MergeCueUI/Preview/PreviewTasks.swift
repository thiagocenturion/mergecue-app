import Foundation
import MergeCueCore

/// Fixed ids of the preview tasks (one per interesting state).
nonisolated enum PreviewTaskIDs {
    static let waiting = "mc_q8w2e5"
    static let working = "mc_w0rk3r"
    static let ready = "mc_r7vq2m"
    static let stale = "mc_s9t4le"
    static let blocked = "mc_4bq7ck"
    static let failed = "mc_f4i1ed"
    static let done = "mc_d0ne42"
}

nonisolated extension PreviewWorld {
    func origin(_ snapshot: ChangeRequestSnapshot, attentionID: String?, thread: ThreadKey? = nil, check: CheckKey? = nil) -> TaskOrigin {
        TaskOrigin(attentionItemID: attentionID, changeRequest: snapshot.key, changeRequestRef: snapshot.summary.ref,
                   title: snapshot.summary.title, webURL: snapshot.summary.webURL, thread: thread, check: check)
    }

    func trigger(_ snapshot: ChangeRequestSnapshot, event: ChangeEventType, capturedAt: Date, thread: ReviewThread? = nil,
                 log: LogExcerpt? = nil) -> TaskTriggerSnapshot {
        var quoted: [UntrustedText] = []
        if let root = thread?.rootComment {
            quoted.append(.bounded(source: UntrustedText.Source.reviewComment, author: root.author.username,
                                   createdAt: root.createdAt, text: root.body, maxBytes: 4_096))
        }
        if let log {
            quoted.append(.bounded(source: UntrustedText.Source.ciLog, text: log.text, maxBytes: 4_096))
        }
        return TaskTriggerSnapshot(eventType: event, capturedAt: capturedAt, headSHA: snapshot.summary.headSHA,
                                   sourceBranch: snapshot.summary.sourceBranch, targetBranch: snapshot.summary.targetBranch,
                                   quoted: quoted, anchor: thread?.anchor)
    }

    func activity(_ task: TaskID, _ index: Int, at date: Date, _ actor: TransitionActor, _ name: String? = nil,
                  _ kind: ActivityKind, _ message: String, from: TaskState? = nil, to: TaskState? = nil,
                  data: [String: String] = [:]) -> TaskActivity {
        TaskActivity(id: "act_\(task.rawValue.dropFirst(3))_\(index)", taskID: task, at: date, actor: actor, actorName: name,
                     kind: kind, message: message, fromState: from, toState: to, data: data)
    }

    func worktree(_ task: TaskID, mapped: String, snapshot: ChangeRequestSnapshot, base: String) -> TaskCheckout {
        TaskCheckout(policy: .isolatedWorktree, mappedCheckoutPath: mapped,
                     worktreePath: "~/Library/Application Support/MergeCue/worktrees/\(task.rawValue)",
                     baseSHA: base, sourceBranch: snapshot.summary.sourceBranch, targetBranch: snapshot.summary.targetBranch)
    }

    // swiftlint:disable:next function_body_length
    func makeTasks(_ catalog: PreviewCatalog, _ ids: PreviewAttentionIDs) -> [TaskRecord] {
        var records: [TaskRecord] = []

        // Waiting for agent — Bitbucket acme/checkout-web #128. Created 3 min ago, nobody has claimed it.
        do {
            let snapshot = catalog.bbCheckout128
            let id = taskID(PreviewTaskIDs.waiting)
            let thread = snapshot.threads[0]
            let task = MCTask(id: id, type: .fixReview, createdAt: ago(minutes: 3),
                              origin: origin(snapshot, attentionID: ids.bbCheckoutComment, thread: thread.key),
                              trigger: trigger(snapshot, event: .reviewComment, capturedAt: ago(minutes: 3), thread: thread),
                              checkout: TaskCheckout(policy: .isolatedWorktree, mappedCheckoutPath: "~/Developer/checkout-web",
                                                     baseSHA: snapshot.summary.headSHA, sourceBranch: snapshot.summary.sourceBranch,
                                                     targetBranch: snapshot.summary.targetBranch))
            records.append(TaskRecord(task: task, activities: [
                activity(id, 1, at: ago(minutes: 3), .user, "mona-dev", .created, "Created from @dchen's review comment (Fix with AI)", to: .waitingForAgent),
            ]))
        }

        // Working — GitLab acme-platform/ledger-service !318, claimed by Claude Code with a live heartbeat.
        do {
            let snapshot = catalog.glLedger318
            let id = taskID(PreviewTaskIDs.working)
            let thread = snapshot.threads[0]
            var task = MCTask(id: id, type: .fixReview, state: .working, version: 7, createdAt: ago(minutes: 22), updatedAt: ago(minutes: 2),
                              origin: origin(snapshot, attentionID: ids.glLedgerComment, thread: thread.key),
                              trigger: trigger(snapshot, event: .reviewComment, capturedAt: ago(minutes: 22), thread: thread),
                              checkout: worktree(id, mapped: "~/Developer/ledger-service", snapshot: snapshot,
                                                 base: snapshot.summary.headSHA ?? ""),
                              agentLabel: "Claude Code")
            task.lease = AgentLease(agentName: "Claude Code", runID: "run_2c81f0", leaseID: "lease_preview_working",
                                    claimedAt: ago(minutes: 18), heartbeatAt: now.addingTimeInterval(-40), expiresAt: later(minutes: 9))
            records.append(TaskRecord(task: task, activities: [
                activity(id, 1, at: ago(minutes: 22), .user, "mona-dev", .created, "Created from @oscar.b's review comment (Fix with AI)", to: .waitingForAgent),
                activity(id, 2, at: ago(minutes: 18), .agent, "Claude Code", .claimed, "Claimed the task", from: .waitingForAgent, to: .working),
                activity(id, 3, at: ago(minutes: 16), .agent, "Claude Code", .progress, "Investigating: read the thread and the ledger client error paths",
                         data: ["phase": "investigating"]),
                activity(id, 4, at: ago(minutes: 9), .agent, "Claude Code", .progress, "Editing: propagate LedgerClientError out of reconcile(region:)",
                         data: ["phase": "editing"]),
                activity(id, 5, at: ago(minutes: 5), .agent, "Claude Code", .changesReported, "Reported 2 changed files",
                         data: ["changed_paths": "internal/reconcile/job.go, internal/reconcile/job_test.go"]),
                activity(id, 6, at: ago(minutes: 2), .agent, "Claude Code", .progress, "Testing: go test ./internal/reconcile/...",
                         data: ["phase": "testing"]),
            ]))
        }

        records.append(readyTask(catalog, ids))

        // Stale — GitLab acme/payments-api !42 code suggestion, Codex stopped sending heartbeats.
        do {
            let snapshot = catalog.glPayments42
            let id = taskID(PreviewTaskIDs.stale)
            let thread = snapshot.threads[0]
            var task = MCTask(id: id, type: .addressSuggestion, state: .stale, version: 5, createdAt: ago(minutes: 55), updatedAt: ago(minutes: 24),
                              origin: origin(snapshot, attentionID: ids.glPaymentsSuggestion, thread: thread.key),
                              trigger: trigger(snapshot, event: .reviewComment, capturedAt: ago(minutes: 55), thread: thread),
                              checkout: worktree(id, mapped: "~/Developer/payments-api-gitlab", snapshot: snapshot,
                                                 base: snapshot.summary.headSHA ?? ""),
                              agentLabel: "Codex CLI")
            task.lease = AgentLease(agentName: "Codex CLI", runID: "run_91be", leaseID: "lease_preview_stale",
                                    claimedAt: ago(minutes: 50), heartbeatAt: ago(minutes: 34), expiresAt: ago(minutes: 24))
            records.append(TaskRecord(task: task, activities: [
                activity(id, 1, at: ago(minutes: 55), .user, "mona-dev", .created, "Created from @priya.n's code suggestion (Address with AI)", to: .waitingForAgent),
                activity(id, 2, at: ago(minutes: 50), .agent, "Codex CLI", .claimed, "Claimed the task", from: .waitingForAgent, to: .working),
                activity(id, 3, at: ago(minutes: 46), .agent, "Codex CLI", .progress, "Investigating: batch_writer.go flush paths",
                         data: ["phase": "investigating"]),
                activity(id, 4, at: ago(minutes: 24), .system, nil, .stale, "No heartbeat for 10 minutes — lease expired. The agent may have stopped.",
                         from: .working, to: .stale),
            ]))
        }

        // Blocked — GitHub acme/payments-api #42 CI failure; the mapped checkout is a GitButler workspace.
        do {
            let snapshot = catalog.ghPayments42
            let id = taskID(PreviewTaskIDs.blocked)
            let unit = snapshot.checks[0]
            let task = MCTask(id: id, type: .investigateCI, state: .blocked, version: 2, createdAt: ago(minutes: 8), updatedAt: ago(minutes: 8),
                              origin: origin(snapshot, attentionID: ids.ghPaymentsCI, check: unit.key),
                              trigger: trigger(snapshot, event: .ciFailed, capturedAt: ago(minutes: 8), log: catalog.logs[unit.key.id]),
                              checkout: TaskCheckout(policy: .blocked, mappedCheckoutPath: "~/Developer/acme/payments-api",
                                                     sourceBranch: snapshot.summary.sourceBranch, targetBranch: snapshot.summary.targetBranch,
                                                     isGitButlerManaged: true, blockedReason: "Blocked: map a safe checkout"))
            records.append(TaskRecord(task: task, activities: [
                activity(id, 1, at: ago(minutes: 8), .user, "mona-dev", .created, "Created from the failed check ci / unit-tests (Investigate with AI)", to: .waitingForAgent),
                activity(id, 2, at: ago(minutes: 8), .system, nil, .blocked,
                         "Blocked: map a safe checkout — ~/Developer/acme/payments-api is a GitButler workspace (gitbutler/workspace). "
                            + "MergeCue never edits a mixed workspace; map a separate clone or let MergeCue create an isolated worktree from a clean clone.",
                         from: .waitingForAgent, to: .blocked, data: ["safety": "gitbutler_workspace"]),
            ]))
        }

        // Failed — Bitbucket acme/checkout-web #131, the agent could not reproduce the Safari failure.
        do {
            let snapshot = catalog.bbCheckout131
            let id = taskID(PreviewTaskIDs.failed)
            let safari = snapshot.checks[0]
            let task = MCTask(id: id, type: .investigateCI, state: .failed, version: 6, createdAt: ago(minutes: 70), updatedAt: ago(minutes: 40),
                              origin: origin(snapshot, attentionID: ids.bbCheckoutCI, check: safari.key),
                              trigger: trigger(snapshot, event: .ciFailed, capturedAt: ago(minutes: 70), log: catalog.logs[safari.key.id]),
                              checkout: worktree(id, mapped: "~/Developer/checkout-web", snapshot: snapshot, base: snapshot.summary.headSHA ?? ""),
                              agentLabel: "Claude Code",
                              lastError: TaskErrorInfo(code: "agent_failed",
                                                       message: "Couldn't reproduce — the Safari e2e suite needs a WebKit runner that isn't available in the worktree",
                                                       retryable: true, at: ago(minutes: 40)))
            records.append(TaskRecord(task: task, activities: [
                activity(id, 1, at: ago(minutes: 70), .user, "mona-dev", .created, "Created from the failed check e2e / safari (Investigate with AI)", to: .waitingForAgent),
                activity(id, 2, at: ago(minutes: 65), .agent, "Claude Code", .claimed, "Claimed the task", from: .waitingForAgent, to: .working),
                activity(id, 3, at: ago(minutes: 60), .agent, "Claude Code", .progress, "Investigating: read the e2e log excerpt", data: ["phase": "investigating"]),
                activity(id, 4, at: ago(minutes: 44), .agent, "Claude Code", .testsReported, "npx playwright test --project=webkit: not run (no WebKit runner)",
                         data: ["status": "not_run"]),
                activity(id, 5, at: ago(minutes: 40), .agent, "Claude Code", .failed,
                         "Couldn't reproduce — the Safari e2e suite needs a WebKit runner that isn't available in the worktree", from: .working, to: .failed,
                         data: ["retryable": "true"]),
            ]))
        }

        // Done — GitLab acme/payments-api !39 (merged).
        do {
            let snapshot = catalog.glPayments39
            let id = taskID(PreviewTaskIDs.done)
            let task = MCTask(id: id, type: .fixReview, state: .done, version: 9, createdAt: ago(days: 2), updatedAt: ago(days: 1),
                              origin: origin(snapshot, attentionID: ids.glPayments39Review),
                              trigger: TaskTriggerSnapshot(eventType: .changeRequested, capturedAt: ago(days: 2), headSHA: snapshot.summary.headSHA,
                                                           sourceBranch: snapshot.summary.sourceBranch, targetBranch: snapshot.summary.targetBranch,
                                                           quoted: [.bounded(source: UntrustedText.Source.reviewSummary, author: "priya.n",
                                                                             createdAt: ago(days: 2), text: "Rounding must use the currency exponent (JPY has none).",
                                                                             maxBytes: 4_096)]),
                              agentLabel: "Codex CLI", resultSummary: "Rounded payouts with the currency exponent and added JPY/BHD cases.")
            records.append(TaskRecord(task: task, activities: [
                activity(id, 1, at: ago(days: 2), .user, "mona-dev", .created, "Created from @priya.n's requested change (Fix with AI)", to: .waitingForAgent),
                activity(id, 2, at: ago(hours: 47), .agent, "Codex CLI", .claimed, "Claimed the task", from: .waitingForAgent, to: .working),
                activity(id, 3, at: ago(hours: 46), .agent, "Codex CLI", .resultSubmitted, "Submitted result", from: .working, to: .readyForReview),
                activity(id, 4, at: ago(hours: 44), .user, "mona-dev", .approved, "Approved Apply patch", from: .readyForReview, to: .approvedAction),
                activity(id, 5, at: ago(hours: 44), .system, nil, .completed, "Patch applied to ~/Developer/payments-api-gitlab", from: .approvedAction, to: .done),
            ]))
        }
        return records
    }

    func readyTask(_ catalog: PreviewCatalog, _ ids: PreviewAttentionIDs) -> TaskRecord {
        let snapshot = catalog.ghPayments61
        let id = taskID(PreviewTaskIDs.ready)
        let thread = snapshot.threads[0]
        let base = snapshot.summary.headSHA ?? ""
        let reply = "Thanks — switched to full jitter (capped at `maxDelay`) and injected the RNG so `RetryPolicyTests` stays deterministic. All 48 tests pass."
        let artifacts = [
            Artifact(id: "art_7c1e0b9d2f", taskID: id, kind: .diff, createdAt: ago(minutes: 20), title: "Worktree diff (recomputed by MergeCue)",
                     content: Self.readyDiff, metadata: ["files_changed": "2", "additions": "15", "deletions": "5", "base_sha": base,
                                                         "head_sha": "e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0"], reportedBy: .system),
            Artifact(id: "art_3d9f2a1c7e", taskID: id, kind: .testRun, createdAt: ago(minutes: 17), title: "swift test --filter PaymentsTests",
                     content: Self.readyTestOutput, metadata: ["command": "swift test --filter PaymentsTests", "status": "passed", "exit_code": "0",
                                                               "passed": "48", "failed": "0", "skipped": "0", "duration_ms": "7310"],
                     reportedBy: .agent),
            Artifact(id: "art_5b8e4c2a0f", taskID: id, kind: .proposedReply, createdAt: ago(minutes: 14), title: "Proposed reply to @tkim",
                     content: reply, reportedBy: .agent),
        ]
        let task = MCTask(id: id, type: .addressSuggestion, state: .readyForReview, version: 11, createdAt: ago(hours: 2), updatedAt: ago(minutes: 14),
                          origin: origin(snapshot, attentionID: ids.ghRetrySuggestion, thread: thread.key),
                          trigger: trigger(snapshot, event: .reviewComment, capturedAt: ago(hours: 2), thread: thread),
                          checkout: worktree(id, mapped: "~/Developer/acme/payments-api-clean", snapshot: snapshot, base: base),
                          agentLabel: "Codex CLI", artifactIDs: artifacts.map(\.id),
                          resultSummary: "Replaced the fixed exponential backoff with full jitter capped at maxDelay, and added an injectable RNG so the tests stay deterministic.",
                          proposedReply: reply,
                          knownRisks: ["Retry timing in the load-test profile changes; the p99 latency alert may need a new baseline."])
        return TaskRecord(task: task, activities: [
            activity(id, 1, at: ago(hours: 2), .user, "mona-dev", .created, "Created from @tkim's code suggestion (Address with AI)", to: .waitingForAgent),
            activity(id, 2, at: ago(minutes: 115), .agent, "Codex CLI", .claimed, "Claimed the task", from: .waitingForAgent, to: .working),
            activity(id, 3, at: ago(minutes: 110), .agent, "Codex CLI", .progress, "Investigating: RetryPolicy and its callers", data: ["phase": "investigating"]),
            activity(id, 4, at: ago(minutes: 60), .agent, "Codex CLI", .progress, "Editing: full jitter + injectable RNG", data: ["phase": "editing"]),
            activity(id, 5, at: ago(minutes: 20), .agent, "Codex CLI", .changesReported, "Reported 2 changed files (verified against the worktree)",
                     data: ["changed_paths": "Sources/Payments/RetryPolicy.swift, Tests/PaymentsTests/RetryPolicyTests.swift"]),
            activity(id, 6, at: ago(minutes: 17), .agent, "Codex CLI", .testsReported, "swift test --filter PaymentsTests: 48 passed, 0 failed",
                     data: ["status": "passed"]),
            activity(id, 7, at: ago(minutes: 14), .agent, "Codex CLI", .resultSubmitted, "Submitted result with a proposed reply", from: .working, to: .readyForReview),
        ], artifacts: artifacts)
    }

    static let readyDiff = """
    diff --git a/Sources/Payments/RetryPolicy.swift b/Sources/Payments/RetryPolicy.swift
    index 3f1c2aa..8e0d7b4 100644
    --- a/Sources/Payments/RetryPolicy.swift
    +++ b/Sources/Payments/RetryPolicy.swift
    @@ -1,11 +1,14 @@
     import Foundation

     struct RetryPolicy {
         var baseDelay: TimeInterval = 0.2
         var maxDelay: TimeInterval = 5
    +    /// Injected so tests can make the jitter deterministic.
    +    var random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }

         func delay(forAttempt attempt: Int) -> TimeInterval {
    -        let delay = baseDelay * pow(2, Double(attempt))
    -        return min(maxDelay, delay)
    +        // Full jitter spreads retries across pods after a network blip.
    +        let cap = min(maxDelay, baseDelay * pow(2, Double(attempt)))
    +        return random(0...cap)
         }
     }
    diff --git a/Tests/PaymentsTests/RetryPolicyTests.swift b/Tests/PaymentsTests/RetryPolicyTests.swift
    index 51aa0c3..d2c94e1 100644
    --- a/Tests/PaymentsTests/RetryPolicyTests.swift
    +++ b/Tests/PaymentsTests/RetryPolicyTests.swift
    @@ -8,8 +8,18 @@ final class RetryPolicyTests: XCTestCase {
    -    func testDelayDoublesPerAttempt() {
    -        let policy = RetryPolicy()
    -        XCTAssertEqual(policy.delay(forAttempt: 3), 1.6, accuracy: 0.001)
    +    func testDelayIsJitteredWithinCap() {
    +        var policy = RetryPolicy()
    +        policy.random = { $0.upperBound }
    +        XCTAssertEqual(policy.delay(forAttempt: 3), 1.6, accuracy: 0.001)
    +        policy.random = { $0.lowerBound }
    +        XCTAssertEqual(policy.delay(forAttempt: 3), 0, accuracy: 0.001)
    +    }
    +
    +    func testDelayNeverExceedsMaxDelay() {
    +        var policy = RetryPolicy()
    +        policy.random = { $0.upperBound }
    +        XCTAssertEqual(policy.delay(forAttempt: 20), 5, accuracy: 0.001)
         }
     }
    """

    static let readyTestOutput = """
    $ swift test --filter PaymentsTests
    Building for debugging...
    Build complete! (6.84s)
    Test Suite 'Selected tests' started at 2026-09-28 13:28:40.102.
    Test Case '-[PaymentsTests.RetryPolicyTests testDelayIsJitteredWithinCap]' passed (0.002 seconds).
    Test Case '-[PaymentsTests.RetryPolicyTests testDelayNeverExceedsMaxDelay]' passed (0.001 seconds).
    Test Case '-[PaymentsTests.CardNetworkClientTests testTimeoutIsRetried]' passed (0.114 seconds).
    …
    Test Suite 'Selected tests' passed at 2026-09-28 13:28:40.533.
    \t Executed 48 tests, with 0 failures (0 unexpected) in 0.412 (0.431) seconds
    """
}
