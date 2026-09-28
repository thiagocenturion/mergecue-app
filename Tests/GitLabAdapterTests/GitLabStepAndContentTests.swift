import Foundation
@testable import GitLabAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

@Suite("GitLab fixture steps, failure logs and diffs")
struct GitLabStepAndContentTests {
    typealias IDs = GitLabFixtures.IDs

    @Test func stepsChangeThreadsPipelinesAndVersionTokens() async throws {
        let step0 = try await GitLabHarness(step: 0).snapshot(GitLabFixtures.mr42Key)
        let step1 = try await GitLabHarness(step: 1).snapshot(GitLabFixtures.mr42Key)
        let step2 = try await GitLabHarness(step: 2).snapshot(GitLabFixtures.mr42Key)

        // Version tokens move with updated_at; the head stays the same.
        let tokens = [step0, step1, step2].map(\.summary.versionToken)
        #expect(Set(tokens).count == 3)
        #expect([step0, step1, step2].allSatisfy { $0.summary.headSHA == IDs.head42 })

        // Step 1: a new blocking, unresolved diff thread + a failed pipeline.
        #expect(step0.thread(remoteID: IDs.blockingDiscussion) == nil)
        let blocking = try #require(step1.thread(remoteID: IDs.blockingDiscussion))
        #expect(blocking.key.kind == .diffThread)
        #expect(blocking.isResolved == false)
        #expect(blocking.comments.map(\.author.username) == ["rev-alice"])
        #expect(blocking.anchor?.path == "src/payments/refund.rb")
        #expect(step1.unresolvedThreadCount == step0.unresolvedThreadCount + 1)
        #expect(step0.aggregateCheckState == .passing)
        #expect(step1.aggregateCheckState == .failing)
        let failed = try #require(step1.checks.first { $0.key.remoteID == IDs.failedJob })
        #expect(failed.status == .failure)
        #expect(failed.name == "unit-tests")
        #expect(failed.summary == "Stage: test · Failed (script failure)")
        let allowed = try #require(step1.checks.first { $0.name == "dependency-scan" })
        #expect(allowed.status == .neutral)
        #expect(allowed.isRequired == false)
        let pipeline = try #require(step1.checks.first { $0.key.source == .gitlabPipeline })
        #expect(pipeline.status == .failure)
        #expect(pipeline.logLocator["failed_job_id"] == IDs.failedJob)
        guard case .blocked(let reasons) = step1.readiness else {
            Issue.record("expected blocked")
            return
        }
        #expect(reasons.contains("Pipeline failed"))

        // Step 2: mona-dev replied in the blocking thread; CI recovered.
        let replied = try #require(step2.thread(remoteID: IDs.blockingDiscussion))
        #expect(replied.comments.map(\.author.username) == ["rev-alice", "mona-dev"])
        #expect(replied.comments.last?.inReplyToID == "1011")
        #expect(step2.aggregateCheckState == .passing)
        #expect(step2.checks.contains { $0.key.remoteID == "7106" && $0.status == .success })
        #expect(!step2.checks.contains { $0.key.remoteID == IDs.failedJob })
    }

    @Test func failureLogOfJobIsCleanedRedactedAndBounded() async throws {
        let harness = GitLabHarness(step: 1)
        let snapshot = try await harness.snapshot(GitLabFixtures.mr42Key)
        let job = try #require(snapshot.checks.first { $0.key.remoteID == IDs.failedJob })
        let log = try await harness.provider.failureLog(for: job, maxBytes: 64_000)
        #expect(harness.requestedPaths.contains("/projects/278964/jobs/7103/trace"))
        #expect(log.text.contains("Failure/Error: expect(sleeps).to eq([1, 2, 4])"))
        #expect(!log.text.contains("glpat-FixtureSecretValue"))
        #expect(!log.text.contains("\u{1B}["))
        #expect(!log.text.contains("section_start"))
        #expect(!log.truncated)
        #expect(log.fullLogURL?.absoluteString == "https://gitlab.com/acme/payments-api/-/jobs/7103")
        #expect(log.totalBytes ?? 0 > 0)

        let bounded = try await harness.provider.failureLog(for: job, maxBytes: 300)
        #expect(bounded.truncated)
        #expect(bounded.text.utf8.count <= 300)
    }

    @Test func failureLogOfPipelineUsesFirstFailedJob() async throws {
        let harness = GitLabHarness(step: 1)
        let snapshot = try await harness.snapshot(GitLabFixtures.mr42Key)
        let pipeline = try #require(snapshot.checks.first { $0.key.source == .gitlabPipeline })
        let log = try await harness.provider.failureLog(for: pipeline, maxBytes: 64_000)
        #expect(log.text.contains("1 failure"))
        #expect(log.fullLogURL?.absoluteString == "https://gitlab.com/acme/payments-api/-/jobs/7103")

        let green = try #require(try await GitLabHarness(step: 0).snapshot(GitLabFixtures.mr42Key).checks.first { $0.key.source == .gitlabPipeline })
        await #expect(throws: ProviderError.self) {
            try await harness.provider.failureLog(for: green, maxBytes: 1_000)
        }
    }

    @Test func failureLogRejectsForeignChecks() async throws {
        let harness = GitLabHarness()
        let check = CheckRun(
            key: CheckKey(changeRequest: GitLabFixtures.mr42Key, source: .githubCheckRun, remoteID: "1"),
            name: "x", status: .failure
        )
        await #expect(throws: ProviderError.invalidRequest("Not a GitLab pipeline or job check.")) {
            try await harness.provider.failureLog(for: check, maxBytes: 1_000)
        }
    }

    @Test func traceCleaning() {
        let raw = "\u{1B}[0Ksection_start:1:step_script\r\u{1B}[0K\u{1B}[36;1mRun\u{1B}[0;m\r\nok\nsection_end:1:step_script\r\u{1B}[0K\n"
        #expect(GitLabProvider.cleanTrace(raw) == "Run\nok\n\n")
    }

    @Test func diffPrefersRawDiffs() async throws {
        let harness = GitLabHarness()
        let diff = try await harness.provider.diff(for: GitLabFixtures.mr42Key, maxBytes: 100_000)
        #expect(harness.requestedPaths.contains("/projects/278964/merge_requests/42/raw_diffs"))
        #expect(diff.unifiedDiff.hasPrefix("diff --git a/src/payments/charge.rb b/src/payments/charge.rb\nindex "))
        #expect(diff.unifiedDiff.contains("rename from config/app.yml"))
        #expect(diff.files.count == 3)
        #expect(!diff.truncated)
        #expect(diff.baseSHA == IDs.base42)
        #expect(diff.headSHA == IDs.head42)

        let bounded = try await harness.provider.diff(for: GitLabFixtures.mr42Key, maxBytes: 120)
        #expect(bounded.truncated)
        #expect(bounded.unifiedDiff.utf8.count <= 120)
    }

    @Test func diffFallsBackToRenderedDiffs() async throws {
        let harness = GitLabHarness()
        let diff = try await harness.provider.diff(for: GitLabFixtures.mr7Key, maxBytes: 100_000)
        #expect(diff.unifiedDiff == """
        diff --git a/src/router.ts b/src/router.ts
        --- a/src/router.ts
        +++ b/src/router.ts
        @@ -10,3 +10,5 @@ export const routes = [
           home,
        -  checkout,
        +  ...(flags.newCheckout ? [checkoutV2] : [checkout]),
        +  // flag: new_checkout
         ];

        """)
        #expect(diff.files == [ChangedFile(path: "src/router.ts", status: .modified, additions: 2, deletions: 1)])
    }

    @Test func rendererHandlesNewDeletedRenamedAndOmittedFiles() throws {
        let json = """
        [
          {"old_path":"a.txt","new_path":"a.txt","a_mode":"0","b_mode":"100644","diff":"@@ -0,0 +1 @@\\n+hi\\n","new_file":true,"renamed_file":false,"deleted_file":false},
          {"old_path":"b.txt","new_path":"b.txt","a_mode":"100644","b_mode":"0","diff":"@@ -1 +0,0 @@\\n-bye","new_file":false,"renamed_file":false,"deleted_file":true},
          {"old_path":"c.txt","new_path":"d.txt","a_mode":"100644","b_mode":"100755","diff":"","new_file":false,"renamed_file":true,"deleted_file":false},
          {"old_path":"big.bin","new_path":"big.bin","diff":"","new_file":false,"renamed_file":false,"deleted_file":false,"too_large":true}
        ]
        """
        let files = try GitLabJSON.decoder().decode([GLDiffFile].self, from: Data(json.utf8))
        let rendered = GitLabDiffRenderer.render(files)
        #expect(rendered.text == """
        diff --git a/a.txt b/a.txt
        new file mode 100644
        --- /dev/null
        +++ b/a.txt
        @@ -0,0 +1 @@
        +hi
        diff --git a/b.txt b/b.txt
        deleted file mode 100644
        --- a/b.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/c.txt b/d.txt
        old mode 100644
        new mode 100755
        rename from c.txt
        rename to d.txt
        diff --git a/big.bin b/big.bin
        # diff omitted by GitLab (too large)

        """)
        #expect(rendered.omittedFiles == 1)
        #expect(files.map { GitLabMapping.changedFile($0).status } == [.added, .removed, .renamed, .modified])
        #expect(GitLabMapping.changedFile(files[3]).additions == nil)
    }
}

@Suite("GitLab fixture scenario")
struct GitLabFixtureScenarioTests {
    @Test(arguments: 0..<GitLabFixtures.stepCount)
    func everyRequestOfAFullSyncIsServed(step: Int) async throws {
        let harness = GitLabHarness(step: step)
        let provider = harness.provider
        _ = try await provider.currentUser()
        _ = try await provider.listNamespaces()
        _ = try await provider.listRepositories(namespace: nil)
        let authored = try await provider.listChangeRequests(ChangeRequestQuery(scope: .authored))
        let reviewing = try await provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested))
        #expect(authored.items.count + reviewing.items.count == 3)
        for summary in authored.items + reviewing.items {
            let snapshot = try await provider.hydrate(summary)
            _ = try await provider.diff(for: snapshot.key, maxBytes: 50_000)
            _ = try await provider.headInfo(for: snapshot.key)
            for thread in snapshot.threads {
                #expect(try await provider.thread(thread.key).comments == thread.comments)
            }
            for check in snapshot.checks where check.status.isFailing {
                _ = try await provider.failureLog(for: check, maxBytes: 8_000)
            }
        }
        // raw_diffs is deliberately absent for !7 and !12 (exercises the /diffs fallback).
        let unmatched = harness.transport.unmatchedRequests.map { $0.url.path }
        #expect(unmatched.allSatisfy { $0.hasSuffix("/raw_diffs") }, "unmatched: \(unmatched)")
    }

    @Test func fixtureDataIsLabeledSynthetic() throws {
        let project = try #require(GitLabFixtures.data("project_278964"))
        #expect(String(decoding: project, as: UTF8.self).contains("synthetic data"))
        #expect(GitLabFixtures.label.contains("synthetic"))
        #expect(GitLabFixtures.data("mr_278964_42", step: 2) != GitLabFixtures.data("mr_278964_42", step: 0))
        #expect(GitLabFixtures.data("mr_278964_42", step: 9) == GitLabFixtures.data("mr_278964_42", step: 2))
    }
}
