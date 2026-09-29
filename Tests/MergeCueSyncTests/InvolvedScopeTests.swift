import Foundation
import MergeCueCore
import MergeCueStore
import Testing
@testable import MergeCueSync

/// Tracking gap: once the user submits a review on someone else's PR, GitHub drops the review request. The
/// involved listing (`ChangeRequestScope.involved`) keeps the PR tracked so replies to the user's comments arrive.
@Suite("Involved scope (reviewed / commented CRs)")
struct InvolvedScopeTests {
    typealias F = SyncFixture
    let cr = F.crKey(number: 7)
    var mine: ThreadKey { F.threadKey(cr, "MINE") }
    var other: ThreadKey { F.threadKey(cr, "OTHER") }

    /// Alice's PR with the user's review comment (review requested at baseline).
    func reviewRequested() -> ChangeRequestSnapshot {
        F.snapshot(
            cr, author: F.alice, involvement: [.reviewRequested],
            threads: [F.thread(mine, comments: [F.comment("m1", by: F.mona, "Why not reuse the retry helper?", at: 5)])]
        )
    }

    /// The user submitted the review: the provider no longer reports a review request, only participation.
    static func reviewSubmitted(_ snapshot: inout ChangeRequestSnapshot) {
        snapshot = snapshot.touched(60)
        snapshot.summary.involvement = [.participated]
    }

    @Test func replyToMyReviewCommentArrivesAfterTheReviewRequestIsGone() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.supportsInvolved = true
        remote.put(reviewRequested())
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await h.items().map(\.reason) == [.reviewRequested], "my own comment awaits nobody")

        remote.update(cr) { Self.reviewSubmitted(&$0) }
        await h.advance(900) // next list
        let stored = try #require(try await h.database.snapshot(cr), "still tracked through the involved listing")
        #expect(stored.summary.involvement.contains(.participated))
        #expect(!stored.summary.involvement.contains(.reviewRequested))

        // Alice replies in my thread, and comments in a thread I never took part in.
        let (mineKey, otherKey) = (mine, other)
        remote.update(cr) {
            $0 = $0.touched(200)
            $0.threads[0].comments.append(F.comment("a1", by: F.alice, "It doesn't cover refunds.", at: 200, replyTo: "m1"))
            $0.threads.append(F.thread(otherKey, comments: [F.comment("b1", by: F.bob, "Nit: typo", at: 200)]))
        }
        await h.advance(900) // next list
        await coordinator.stop()

        let all = try await h.items()
        #expect(all.first { $0.reason == .reviewRequested }?.disposition == .resolved, "the review request is gone")
        let items = all.filter { $0.disposition != .resolved }
        #expect(items.count == 1, "attention only for the thread I participate in")
        let item = try #require(items.first)
        #expect(item.thread == mineKey)
        #expect(item.reason == .reply)
        #expect(item.isUnread)
        #expect(!items.contains { $0.thread == otherKey })
        #expect(h.notifier.delivered.count == 1)
        #expect(h.notifier.delivered[0].body.contains("refunds"))

        // Sync asked for the involved scope with the configured window.
        let query = try #require(remote.involvedQueries.last)
        #expect(query.updatedSince == h.clock.now.addingTimeInterval(-30 * 86_400))
    }

    @Test func withoutTheCapabilityTheReviewedPRLeavesTheLists() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(reviewRequested())
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        remote.update(cr) { Self.reviewSubmitted(&$0) }
        await h.advance(900) // next list
        await coordinator.stop()
        #expect(try await h.database.snapshot(cr) == nil, "not asked for the involved scope → departed")
        #expect(remote.involvedQueries.isEmpty)
    }

    @Test func involvedListingFailuresKeepStoredCRsOrPropagate() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.supportsInvolved = true
        remote.put(reviewRequested())
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        remote.update(cr) { Self.reviewSubmitted(&$0) }
        await h.advance(900) // next list
        #expect(try await h.database.snapshot(cr) != nil)

        // An endpoint-specific failure of this additive listing keeps what is stored and the account healthy.
        remote.involvedError = .notFound("events")
        await h.advance(900) // next list
        #expect(try await h.database.snapshot(cr) != nil)
        #expect(await coordinator.statuses().first?.state == .ok)

        // A provider rejecting the query itself (Bitbucket: 400 "does not support filtering") is also contained.
        remote.involvedError = .invalidRequest(#"Field ".participants.user.uuid" does not support filtering"#)
        await h.advance(900) // next list
        #expect(try await h.database.snapshot(cr) != nil)
        #expect(await coordinator.statuses().first?.state == .ok)

        // Account-level failures propagate like every other listing.
        remote.involvedError = .unauthorized("expired")
        await h.advance(900, sleepers: 0) // an auth-expired account does not schedule another run
        for _ in 0..<400 where await coordinator.statuses().first?.state != .authExpired { try? await Task.sleep(for: .milliseconds(5)) }
        await coordinator.stop()
        #expect(await coordinator.statuses().first?.state == .authExpired)
    }

    @Test func involvedWindowOffSkipsTheListing() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.supportsInvolved = true
        remote.put(reviewRequested())
        var configuration = SyncConfiguration.deterministic
        configuration.involvedWindow = nil
        let coordinator = await h.makeCoordinator(configuration: configuration)
        await h.start(coordinator)
        await coordinator.stop()
        #expect(remote.involvedQueries.isEmpty)
    }

    @Test func listVersionTracksParticipation() {
        var summary = reviewRequested().summary
        let requested = SyncCycle.listVersion(summary)
        summary.involvement = [.participated]
        #expect(SyncCycle.listVersion(summary) != requested, "losing the review request re-hydrates once")
        #expect(ChangeRequestScope.involved.involvement == .participated)
        #expect(ChangeRequestScope.involved.capability == .listInvolved)
    }
}
