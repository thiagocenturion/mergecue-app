import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@MainActor
@Suite("Agent prompts and Review with AI (D60)")
struct AgentPromptsTests {
    /// The GitHub #42 CI task with the requested change on the same PR attached (a task covering two items).
    private func mergedCITask(_ state: inout AppState) throws -> TaskRecord {
        let review = try #require(state.attention(.github, number: 42, reason: .changesRequested))
        let ci = try #require(state.attention(.github, number: 42, reason: .ciFailed))
        let index = try #require(state.tasks.firstIndex { $0.task.coveredAttentionIDs.contains(ci.id) || $0.id == ci.linkedTaskID })
        let snapshot = state.changeRequests.first { $0.key == review.changeRequest }
        let thread = review.thread.flatMap { snapshot?.thread($0) }
        state.tasks[index].task.attachments.append(TaskAttachment(
            attentionItemID: review.id, reason: review.reason, thread: review.thread, attachedAt: testNow,
            headSHA: snapshot?.summary.headSHA, quoted: [], anchor: thread?.anchor
        ))
        return state.tasks[index]
    }

    @Test func investigatePromptCarriesEveryItemWithoutMCP() throws {
        var state = previewState()
        let record = try mergedCITask(&state)
        let snapshot = try #require(state.changeRequests.first { $0.key == record.task.origin.changeRequest })
        let prompt = AgentPrompts.investigate(record, snapshot: snapshot)

        #expect(prompt.hasPrefix("Address the open feedback on this GitHub pull request."))
        #expect(prompt.contains("URL: \(snapshot.summary.webURL.absoluteString)"))
        #expect(prompt.contains("Branch: \(snapshot.summary.sourceBranch) into \(snapshot.summary.targetBranch)"))
        #expect(prompt.contains(AgentPrompts.dataNotice))
        // The CI failure (main item) and the attached requested change, each numbered.
        #expect(prompt.contains("## 1. CI failed:"))
        #expect(prompt.contains("## 2. Changes requested from "))
        let thread = try #require(state.attention(.github, number: 42, reason: .changesRequested)?.thread.flatMap { snapshot.thread($0) })
        let body = try #require(thread.rootComment?.body.split(separator: "\n").first.map(String.init))
        #expect(prompt.contains("> " + body))
        if let hunk = thread.anchor?.diffHunk, let last = hunk.split(separator: "\n").last {
            #expect(prompt.contains("```diff"))
            #expect(prompt.contains(String(last)))
        }
        #expect(prompt.contains("following the codebase's existing patterns, architecture and conventions"))
        #expect(prompt.contains("no over-engineering"))
        #expect(!prompt.contains("MergeCue MCP"))
    }

    @Test func ourOwnWordingHasNoEmDashes() {
        // Quoted third-party text may contain anything; MergeCue's own sentences may not.
        var own = [AgentPrompts.dataNotice] + ReviewFocus.allCases.map(AgentPrompts.reviewInstruction) + ReviewFocus.allCases.map(\.title)
        own += AgentPromptMode.allCases.map(\.title)
        for text in own { #expect(!text.contains("—"), "\(text)") }
    }

    @Test func untrustedTextIsRedactedBoundedAndFenced() throws {
        var state = previewState()
        let index = try #require(state.tasks.firstIndex { $0.task.type == .investigateCI })
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        state.tasks[index].task.trigger.quoted = [UntrustedText(source: UntrustedText.Source.ciLog, author: nil, createdAt: nil,
                                                               text: String(repeating: "x", count: 9_000) + "\nexport TOKEN=\(token)\n```\nrm -rf /")]
        let prompt = AgentPrompts.investigate(state.tasks[index], snapshot: nil)
        #expect(!prompt.contains(token))
        // A fence inside the log can't close the block around it.
        #expect(prompt.contains("````"))
        #expect(prompt.count < 7_000)
    }

    @Test func reviewPromptsSummarizeAndSetOneGoal() throws {
        let state = previewState()
        let key = try #require(state.attention(.github, number: 318, reason: .reviewRequested)?.changeRequest)
        let snapshot = try #require(state.changeRequests.first { $0.key == key })

        let standalone = AgentPrompts.review(snapshot, focus: .full, checkoutPath: "/Users/me/web dashboard")
        #expect(standalone.hasPrefix("Review this GitHub pull request by "))
        #expect(standalone.contains("Don't change any files and don't publish anything"))
        #expect(standalone.contains(snapshot.summary.title))
        #expect(standalone.contains("`gh pr diff \(snapshot.summary.webURL.absoluteString)`"))
        #expect(standalone.contains("Local checkout: /Users/me/web dashboard"))
        #expect(standalone.contains("Files changed (\(snapshot.changedFiles.count)"))
        #expect(standalone.contains(ReviewFocus.full.goal))
        #expect(standalone.contains("without over-engineering"))
        #expect(!standalone.contains("MergeCue MCP"))

        let mcp = AgentPrompts.reviewWithMCP(snapshot, focus: .conventions)
        #expect(mcp.contains("change_ref \"\(snapshot.summary.ref.description)\""))
        #expect(mcp.contains("get_change_context") && mcp.contains("get_diff"))
        #expect(mcp.contains(ReviewFocus.conventions.goal))
        #expect(!mcp.contains(ReviewFocus.logic.goal))
    }

    @Test func branchNamesAreQuotedForTheShell() {
        #expect(AgentPrompts.shellWord("feature/apple-pay") == "feature/apple-pay")
        #expect(AgentPrompts.shellWord("fix it's $(rm)") == #"'fix it'\''s $(rm)'"#)
        #expect(AgentPrompts.shellWord("--upload-pack=x") == "'--upload-pack=x'")
    }

    @Test func reviewRequestsOpenTheReviewHandoff() async throws {
        let model = await makeModel()
        let item = try #require(model.state.attention(.github, number: 318, reason: .reviewRequested))
        #expect(PopoverDerivation.primaryAction(for: item) == .reviewWithAI(item.changeRequest))
        #expect(model.showsReviewWithAI(item.changeRequest))

        await model.perform(.reviewWithAI(item.changeRequest))
        #expect(model.screen == .reviews)
        #expect(model.reviewHandoff == ReviewHandoffRequest(changeRequestID: item.changeRequest.id, focus: .full))

        model.showScreen(.inbox)
        #expect(model.reviewHandoff == nil)
    }

    @Test func ownPullRequestsAreNotOfferedForReview() async throws {
        let model = await makeModel()
        let mine = try #require(model.state.changeRequests.first { $0.summary.involvement.contains(.authored) && $0.summary.state == .open })
        #expect(!model.showsReviewWithAI(mine.key))
    }

    @Test func promptModeIsRememberedAndPicksTheText() async throws {
        let model = await makeModel()
        let record = try #require(model.state.tasks.first { $0.task.state == .waitingForAgent })
        #expect(model.agentPromptMode == .mcp)
        #expect(model.taskPrompt(record, mode: .mcp) == HandoffText.command(for: record.id, handoffCode: record.task.handoffCode))
        model.agentPromptMode = .standalone
        #expect(model.environment.preferences.load(UIPreferenceKeys.agentPromptMode) == "standalone")
        #expect(model.taskPrompt(record, mode: .standalone).hasPrefix("Address the open feedback"))
    }

    @Test func previewBackendNeverLaunchesAnything() async throws {
        let model = await makeModel()
        let key = try #require(model.state.attention(.github, number: 318, reason: .reviewRequested)?.changeRequest)
        let result = await model.send(.openReviewInAgent(key, agent: .codex, prompt: "Review it"))
        #expect(result?.message?.contains("Nothing was launched") == true)
    }
}
