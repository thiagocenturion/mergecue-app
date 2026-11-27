import Foundation
import MergeCueCore
import Testing
@testable import MergeCueUI

/// D59: Approve runs in the app when the account may write, otherwise opens the provider page; the same rule sends
/// blocked agent actions to the browser. Every browser route carries the outside glyph.
@MainActor
@Suite("Approve and browser fallbacks")
struct ApprovalRouteTests {
    func key(_ model: AppModel, _ kind: ProviderKind, _ number: Int) throws -> ChangeRequestKey {
        try #require(model.state.changeRequests.first { $0.key.kind == kind && $0.key.number == number }).key
    }

    @Test func approveShowsOnlyOnOthersOpenPullRequestsYouHaveNotApproved() async throws {
        let model = await makeModel()
        #expect(model.showsApprove(try key(model, .github, 318)), "review requested")
        #expect(model.showsApprove(try key(model, .bitbucketCloud, 12)), "re-approval needed")
        #expect(!model.showsApprove(try key(model, .github, 310)), "already approved by you")
        let mine = try #require(model.state.changeRequests.first { $0.summary.involvement.contains(.authored) })
        #expect(!model.showsApprove(mine.key), "your own PR")
    }

    @Test func writesOffOpensTheProviderPage() async throws {
        let model = await makeModel()
        let github = try key(model, .github, 318)
        guard case .browser(let url, let reason)? = model.approvalRoute(github) else {
            Issue.record("expected the browser")
            return
        }
        #expect(url.absoluteString.hasSuffix("/files"), "GitHub approves from the Files tab")
        #expect(reason.contains("Writes are off"))
        let bitbucket = try key(model, .bitbucketCloud, 12)
        guard case .browser(let page, _)? = model.approvalRoute(bitbucket) else {
            Issue.record("expected the browser")
            return
        }
        #expect(page == model.snapshot(bitbucket)?.summary.webURL)
        #expect(!(ApproveButton.help(model.approvalRoute(github), kind: .github).contains("\u{2014}")))
    }

    @Test func writesOnApprovesInTheAppAfterConfirming() async throws {
        let model = await makeModel()
        let github = try key(model, .github, 318)
        await model.send(.setWritesEnabled(github.account, true))
        #expect(model.approvalRoute(github) == .inApp)
        model.approve(github)
        #expect(model.pendingApproval == github, "asks first")
        #expect(model.approvalTitle(github).hasPrefix("Approve "))
        await model.confirmApproval()
        #expect(model.pendingApproval == nil)
        #expect(!model.state.attention.contains { $0.changeRequest == github && $0.reason == .reviewRequested && $0.isActionable(now: model.now) })
    }

    @Test func aTokenWithoutTheScopeStillOpensTheBrowser() async throws {
        let model = await makeModel()
        let gitlab = try key(model, .gitlab, 322)
        await model.send(.setWritesEnabled(gitlab.account, true))
        guard case .browser(_, let reason)? = model.approvalRoute(gitlab) else {
            Issue.record("expected the browser")
            return
        }
        #expect(reason.contains("Opens GitLab"))
    }

    @Test func reapprovalRowsApproveFromThePopover() async throws {
        let model = await makeModel()
        let item = try #require(model.state.attention.first { $0.reason == .reapprovalNeeded })
        #expect(PopoverDerivation.primaryAction(for: item) == .approve(item.changeRequest))
        #expect(PrimaryAction.approve(item.changeRequest).title == "Approve")
    }

    @Test func blockedAgentActionsOpenTheRightPageWithTheTextCopied() async throws {
        let model = await makeModel()
        let ready = try #require(model.state.task(in: .readyForReview))
        await model.send(.setWritesEnabled(ready.task.origin.account, false))
        let preview = try #require(await model.send(.requestActionPreview(ready.id, .postReply))?.preview)
        let fallback = try #require(model.browserFallback(for: preview))
        #expect(fallback.title == "Post reply in \(ready.task.origin.providerKind.displayName)")
        #expect(fallback.textToCopy == preview.body)
        await model.send(.setWritesEnabled(ready.task.origin.account, true))
        #expect(model.browserFallback(for: preview) == nil, "writes on: Approve stays in the app")
    }
}
