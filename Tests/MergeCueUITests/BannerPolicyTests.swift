import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

/// In-app banners only for problems and for results the screen cannot show.
@Suite("Banner policy")
struct BannerPolicyTests {
    @Test func visibleChangesAreSilentOutOfSightResultsAndProblemsAreShown() throws {
        let task = try #require(TaskID(rawValue: "mc_abc123"))
        let ok = AppCommandResult(message: "Done")
        #expect(!ok.showsBanner(after: .acknowledge(attentionID: "a"), tone: .neutral), "acknowledging is visible in the list")
        #expect(!ok.showsBanner(after: .markTaskDone(task), tone: .success), "the task status already changed on screen")
        #expect(!ok.showsBanner(after: .refresh(account: nil), tone: .neutral))
        #expect(ok.showsBanner(after: .copyHandoffCommand(task, agent: nil), tone: .success), "the clipboard is invisible")
        #expect(ok.showsBanner(after: .sendTestNotification, tone: .success))
        #expect(ok.showsBanner(after: .acknowledge(attentionID: "a"), tone: .attention), "problems are always shown")
        #expect(ok.showsBanner(after: .markTaskDone(task), tone: .critical))
        #expect(!AppCommandResult().showsBanner(after: .copyHandoffCommand(task, agent: nil), tone: .success), "no message, no banner")
    }
}
