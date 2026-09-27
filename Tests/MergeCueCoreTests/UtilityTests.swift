import Foundation
import MergeCueCore
import Testing

@Suite("IDGenerator, sync status and logging")
struct UtilityTests {
    private func isLowerHex(_ value: Substring) -> Bool {
        value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    @Test func idFormats() {
        let generator = IDGenerator()
        let cases: [(String, String, Int)] = [
            (generator.artifactID(), "art_", 10),
            (generator.activityID(), "act_", 16),
            (generator.leaseID(), "lease_", 32),
            (generator.ruleID(), "rule_", 10),
            (generator.previewID(), "pv_", 16),
            (generator.approvalID(), "apr_", 16),
            (generator.auditID(), "aud_", 16),
            (generator.mappingID(), "map_", 10),
            (generator.notificationID(), "ntf_", 16),
            (IDGenerator.artifactID(), "art_", 10),
            (IDGenerator.leaseID(), "lease_", 32),
        ]
        for (id, prefix, length) in cases {
            #expect(id.hasPrefix(prefix), "\(id)")
            #expect(id.count == prefix.count + length, "\(id)")
            #expect(isLowerHex(id.dropFirst(prefix.count)), "\(id)")
        }
        #expect(ShortID.isValid(generator.artifactID(), prefix: ShortID.artifactPrefix))
        #expect(TaskID.isValid(generator.taskID().rawValue))
    }

    @Test func seededGeneratorsAreDeterministic() {
        let a = IDGenerator(seed: 7)
        let b = IDGenerator(seed: 7)
        let c = IDGenerator(seed: 8)
        let first = [a.leaseID(), a.artifactID(), a.taskID().rawValue]
        let second = [b.leaseID(), b.artifactID(), b.taskID().rawValue]
        #expect(first == second)
        #expect(c.leaseID() != first[0])
        #expect(a.leaseID() != first[0], "sequence advances")
    }

    @Test func systemIDsAreUnique() {
        let ids = Set((0..<2_000).map { _ in IDGenerator.leaseID() })
        #expect(ids.count == 2_000)
    }

    @Test func syncStateHasStableJSON() throws {
        let cases: [(AccountSyncState, String)] = [
            (.idle, #"{"type":"idle"}"#),
            (.syncing, #"{"type":"syncing"}"#),
            (.ok, #"{"type":"ok"}"#),
            (.offline, #"{"type":"offline"}"#),
            (.authExpired, #"{"type":"auth_expired"}"#),
            (.rateLimited(until: Fixture.date), #"{"type":"rate_limited","until":"2026-01-01T00:00:00Z"}"#),
            (.rateLimited(until: nil), #"{"type":"rate_limited"}"#),
            (.permissionDenied("missing read_api"), #"{"message":"missing read_api","type":"permission_denied"}"#),
            (.error("boom"), #"{"message":"boom","type":"error"}"#),
            (.paused, #"{"type":"paused"}"#),
        ]
        for (state, json) in cases {
            #expect(try Fixture.json(state) == json)
            #expect(try Fixture.decode(AccountSyncState.self, from: json) == state)
        }
        #expect(throws: DecodingError.self) { try Fixture.decode(AccountSyncState.self, from: #"{"type":"sleeping"}"#) }
        #expect(AccountSyncState.authExpired.isProblem)
        #expect(!AccountSyncState.ok.isProblem)
    }

    @Test func accountSyncStatusRoundTrips() throws {
        let status = AccountSyncStatus(
            account: Fixture.gitlabAccount,
            state: .rateLimited(until: Fixture.date),
            lastAttemptAt: Fixture.date,
            lastSuccessAt: nil,
            nextRunAt: Fixture.date.addingTimeInterval(90),
            consecutiveFailures: 2,
            message: "429"
        )
        #expect(try Fixture.roundTrip(status) == status)
    }

    @Test func groupedNotificationDefaultsThreadToChangeRequest() throws {
        let key = Fixture.changeRequestKey()
        let notification = GroupedNotification(id: "ntf_1", title: "acme/payments-api #42", subtitle: "GitHub", body: "CI failed", changeRequest: key)
        #expect(notification.threadIdentifier == key.id)
        #expect(try Fixture.roundTrip(notification) == notification)
    }

    @Test func engineChangeIsHashable() {
        let changes: Set<EngineChange> = [.accounts, .tasks(nil), .tasks(TaskID(rawValue: "mc_abc123")), .tasks(nil)]
        #expect(changes.count == 3)
    }

    @Test func logLinesAreRedacted() {
        let line = MCLog.standardErrorLine("connecting with token=abc123secret", category: "mcp")
        #expect(line == "[mcp] connecting with token=[REDACTED]\n")
        MCLog.core.debug("redaction smoke test Authorization: Bearer abcdefgh12345")
        MCLog(category: "tests").info("private message", isPrivate: true)
        #expect(MCLog.subsystem == "dev.mergecue")
    }

    @Test func workspaceValuesRoundTrip() throws {
        let taskID = try #require(TaskID(rawValue: "mc_abc123"))
        let request = WorktreeRequest(
            taskID: taskID,
            checkoutPath: "/Users/mona/src/api",
            fetch: FetchHeadSpec(remoteURLs: ["git@github.com:acme/api.git"], refspec: "refs/pull/42/head", expectedSHA: "abc"),
            destinationRoot: "/tmp/worktrees"
        )
        #expect(try Fixture.roundTrip(request) == request)
        #expect(PreparedWorktree.localRef(for: taskID) == "refs/mergecue/tasks/mc_abc123")
        let info = CheckoutInfo(path: "/x", isRepository: true, remotes: [GitRemote(name: "origin", fetchURL: "https://github.com/acme/api")], safety: .gitButlerWorkspace)
        #expect(try Fixture.roundTrip(info) == info)
        #expect(CheckoutSafety.gitButlerWorkspace.rawValue == "gitbutler_workspace")
        #expect(WorkspaceError.unsafeCheckout(.dirty, path: "/x").errorDescription?.hasPrefix("Blocked: map a safe checkout") == true)
    }

    @Test func taskValuesRoundTrip() throws {
        let key = Fixture.changeRequestKey()
        let taskID = try #require(TaskID(rawValue: "mc_zz99aa"))
        let task = MCTask(
            id: taskID,
            type: .investigateCI,
            createdAt: Fixture.date,
            origin: TaskOrigin(
                attentionItemID: "att_0123456789",
                changeRequest: key,
                changeRequestRef: Fixture.summary(key).ref,
                title: "Add retries",
                webURL: URL(string: "https://github.com/acme/payments-api/pull/42")!,
                check: CheckKey(changeRequest: key, source: .githubActionsJob, remoteID: "9")
            ),
            trigger: TaskTriggerSnapshot(
                eventType: .ciFailed,
                capturedAt: Fixture.date,
                headSHA: "abc",
                sourceBranch: "feature",
                targetBranch: "main",
                quoted: [UntrustedText(source: UntrustedText.Source.ciLog, text: "error: boom")]
            ),
            checkout: TaskCheckout(policy: .isolatedWorktree, worktreePath: "/tmp/wt", baseSHA: "abc", sourceBranch: "feature", targetBranch: "main"),
            lease: AgentLease(agentName: "claude-code", leaseID: "lease_x", claimedAt: Fixture.date, heartbeatAt: Fixture.date, expiresAt: Fixture.date.addingTimeInterval(600)),
            approvals: [ApprovalRecord(id: "apr_1", taskID: taskID, action: .postReply, decision: .approved, decidedAt: Fixture.date, previewFingerprint: "fp")],
            lastError: TaskErrorInfo(code: "rate_limited", message: "slow down", retryable: true, at: Fixture.date)
        )
        #expect(task.state == .waitingForAgent)
        #expect(task.version == 1)
        #expect(task.updatedAt == task.createdAt)
        #expect(task.origin.providerKind == .github)
        #expect(try Fixture.roundTrip(task) == task)
        #expect(task.lease?.isExpired(at: Fixture.date.addingTimeInterval(600)) == true)
        #expect(task.lease?.isExpired(at: Fixture.date.addingTimeInterval(599)) == false)

        let artifact = Artifact(id: "art_0123456789", taskID: taskID, kind: .testRun, createdAt: Fixture.date, title: "Tests", content: "ok", reportedBy: .agent)
        let activity = TaskActivity(id: "act_1", taskID: taskID, at: Fixture.date, actor: .agent, kind: .rejectedCall, message: "lease invalid", fromState: .working, toState: nil)
        #expect(try Fixture.roundTrip(artifact) == artifact)
        #expect(try Fixture.roundTrip(activity) == activity)
        #expect(ActivityKind.rejectedCall.rawValue == "rejected_call")
        #expect(ArtifactKind.logExcerpt.rawValue == "log_excerpt")
    }
}
