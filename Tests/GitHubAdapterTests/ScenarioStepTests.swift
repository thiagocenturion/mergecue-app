import Foundation
@testable import GitHubAdapter
import MergeCueCore
import MergeCueFixtures
import MergeCueNetworking
import Testing

@Suite("GitHub fixture steps")
struct ScenarioStepTests {
    @Test func stepOneAddsBlockingThreadAndFailsLint() async throws {
        let before = try await GH.snapshot(step: 0)
        let after = try await GH.snapshot(step: 1)
        #expect(after.key == before.key)
        #expect(after.summary.versionToken != before.summary.versionToken)

        let added = Set(after.threads.map(\.key)).subtracting(before.threads.map(\.key))
        #expect(added.map(\.remoteID) == [GH.IDs.blockingThread])
        let blocking = try GH.thread(after, GH.IDs.blockingThread)
        #expect(blocking.isUnresolved)
        #expect(blocking.comments.first?.author.username == "carol-reviews")
        #expect(blocking.comments.first?.body.hasPrefix("Blocking:") == true)
        #expect(after.unresolvedThreadCount == before.unresolvedThreadCount + 1)

        let lintBefore = try #require(before.checks.first { $0.key.remoteID == GH.IDs.statusContext })
        let lintAfter = try #require(after.checks.first { $0.key.remoteID == GH.IDs.statusContext })
        #expect(lintBefore.status == .success && lintAfter.status == .failure)
        #expect(lintAfter.key == lintBefore.key)
        #expect(after.aggregateCheckState == .failing)
        #expect(after.readiness == .blocked(reasons: ["Changes requested", "6 unresolved threads", "Checks failing"]))
    }

    @Test func stepTwoAddsReplyAndRecoversCI() async throws {
        let before = try await GH.snapshot(step: 1)
        let after = try await GH.snapshot(step: 2)
        #expect(Set(after.threads.map(\.key)) == Set(before.threads.map(\.key)))

        let longBefore = try GH.thread(before, GH.IDs.longThread)
        let longAfter = try GH.thread(after, GH.IDs.longThread)
        #expect(longAfter.comments.count == longBefore.comments.count + 1)
        let reply = try #require(longAfter.comments.last)
        #expect(reply.id == GH.IDs.stepTwoReply)
        #expect(reply.inReplyToID == GH.IDs.longThreadRootComment)
        #expect(reply.author.username == "carol-reviews")
        #expect(longAfter.lastActivityAt > longBefore.lastActivityAt)

        #expect(after.aggregateCheckState == .passing)
        #expect(after.checks.allSatisfy { $0.status == .success })
        #expect(after.checks.contains { $0.key.remoteID == GH.IDs.recoveredJob })
        #expect(!after.checks.contains { $0.key.remoteID == GH.IDs.failingJob })
        #expect(after.readiness == .checksGreen)  // checks pass, but changes requested + unresolved threads remain
        #expect(after.summary.versionToken?.hasSuffix("|SUCCESS") == true)
    }

    @Test func otherPullRequestsAreStableAcrossSteps() async throws {
        for step in 0...2 {
            let (provider, _) = GH.provider(step: step)
            let authored = try await provider.listChangeRequests(ChangeRequestQuery(scope: .authored))
            #expect(authored.items.map(\.key.number) == [42, 12])
            let reviewing = try await provider.listChangeRequests(ChangeRequestQuery(scope: .reviewRequested))
            #expect(reviewing.items.map(\.key.remoteID) == [GH.IDs.pr7])
            let fork = try await GH.snapshot(provider, number: 12)
            #expect(fork.readiness == .readyToMerge)
        }
    }

    @Test func freshThreadReadFollowsTheStep() async throws {
        let (provider, _) = GH.provider(step: 2)
        let snapshot = try await GH.snapshot(provider)
        let thread = try await provider.thread(ThreadKey(changeRequest: snapshot.key, remoteID: GH.IDs.longThread, kind: .diffThread))
        #expect(thread.comments.count == 5)
    }
}
