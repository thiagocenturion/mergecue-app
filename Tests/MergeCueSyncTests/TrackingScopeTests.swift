import Foundation
import MergeCueCore
import MergeCueStore
import Testing
@testable import MergeCueSync

/// Owner decision: live accounts track only the user's own PRs/MRs unless review requests / involved are switched on.
@Suite("Tracking preferences (authored only by default in live)")
struct TrackingScopeTests {
    typealias F = SyncFixture

    @Test func authoredOnlyNeverListsOtherPeoplesWork() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.supportsInvolved = true
        let mine = F.crKey(number: 1)
        let theirs = F.crKey(number: 7)
        remote.put(F.snapshot(mine, author: F.mona, involvement: [.authored]))
        remote.put(F.snapshot(theirs, author: F.alice, involvement: [.reviewRequested]))
        let coordinator = await h.makeCoordinator()
        await coordinator.setTrackingPreferences(.authoredOnly)
        await h.start(coordinator)

        #expect(Set(remote.listedScopes) == [.authored], "review-requested and involved listings never run")
        #expect(try await h.database.snapshot(mine) != nil)
        #expect(try await h.database.snapshot(theirs) == nil)

        // Opting in lists review requests on the next cycle; opting out again drops them.
        await coordinator.setTrackingPreferences(TrackingPreferences(includeReviewRequests: true))
        await h.advance(90)
        #expect(remote.listedScopes.contains(.reviewRequested))
        #expect(!remote.listedScopes.contains(.involved))
        #expect(try await h.database.snapshot(theirs) != nil)

        await coordinator.setTrackingPreferences(.authoredOnly)
        await h.advance(90)
        await coordinator.stop()
        #expect(try await h.database.snapshot(theirs) == nil, "no longer tracked once switched off")
        #expect(try await h.database.snapshot(mine) != nil)
    }

    @Test func preferencesDecideScopes() {
        #expect(TrackingPreferences.authoredOnly.tracks(.authored))
        #expect(!TrackingPreferences.authoredOnly.tracks(.reviewRequested))
        #expect(!TrackingPreferences.authoredOnly.tracks(.involved))
        #expect(TrackingPreferences.all.tracks(.reviewRequested) && TrackingPreferences.all.tracks(.involved))
    }
}
