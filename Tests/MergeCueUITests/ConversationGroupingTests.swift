import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@Suite("Conversation grouping")
struct ConversationGroupingTests {
    let base: ChangeRequestSnapshot
    let reviewer = Person(remoteID: "r1", username: "reviewer")
    let author = Person(remoteID: "a1", username: "author")

    init() throws {
        base = try #require(previewState().changeRequests.first { $0.summary.providerKind == .bitbucketCloud })
    }

    private func comment(_ id: String, _ minutes: Double, by person: Person? = nil) -> ReviewComment {
        ReviewComment(id: id, author: person ?? reviewer, body: "Comment \(id)", createdAt: testNow.addingTimeInterval(minutes * 60))
    }

    private func thread(_ id: String, kind: ThreadKind, anchor: DiffAnchor? = nil, resolvable: Bool = false,
                        comments: [ReviewComment]) -> ReviewThread {
        ReviewThread(key: ThreadKey(changeRequest: base.key, remoteID: id, kind: kind), anchor: anchor,
                     isResolved: resolvable ? false : nil, isResolvable: resolvable, comments: comments,
                     lastActivityAt: comments.map(\.createdAt).max() ?? testNow)
    }

    private func item(for thread: ReviewThread, minutes: Double, unread: Bool = true) -> AttentionItem {
        AttentionItem(dedupeKey: AttentionItem.dedupeKey(thread: thread.key), changeRequest: base.key,
                      repoFullPath: base.summary.repository.fullPath, title: base.summary.title, reason: .reviewComment,
                      summary: "", thread: thread.key, createdAt: testNow, updatedAt: testNow.addingTimeInterval(minutes * 60),
                      isUnread: unread)
    }

    private func snapshot(_ threads: [ReviewThread]) -> ChangeRequestSnapshot {
        var copy = base
        copy.threads = threads
        return copy
    }

    @Test func topLevelCommentsFormOneConversation() throws {
        let first = thread("1", kind: .conversation, comments: [comment("1", 0)])
        let second = thread("2", kind: .conversation, comments: [comment("2", 5, by: author)])
        let third = thread("3", kind: .conversation, comments: [comment("3", 10)])
        let snap = snapshot([third, first, second])
        #expect(Set([first, second, third].map(ConversationGrouping.key)).count == 1)
        let merged = try #require(ConversationGrouping.merged(ConversationGrouping.threads(inConversationOf: third, snapshot: snap)))
        #expect(merged.comments.map(\.id) == ["1", "2", "3"])
        #expect(merged.isResolved == nil)
    }

    @Test func threadsOnTheSameLineMergeButOtherLinesStayApart() throws {
        let line12 = DiffAnchor(path: "src/a.ts", line: 12)
        let a = thread("10", kind: .diffThread, anchor: line12, resolvable: true, comments: [comment("10", 0), comment("11", 2, by: author)])
        let b = thread("20", kind: .diffThread, anchor: line12, resolvable: true, comments: [comment("20", 1)])
        let c = thread("30", kind: .diffThread, anchor: DiffAnchor(path: "src/a.ts", line: 40), resolvable: true, comments: [comment("30", 3)])
        var outdated = line12
        outdated.isOutdated = true
        let d = thread("40", kind: .diffThread, anchor: outdated, resolvable: true, comments: [comment("40", 4)])
        let groups = ConversationGrouping.conversations(snapshot([a, b, c, d]))
        #expect(groups.map { $0.map(\.key.remoteID) } == [["10", "20"], ["30"], ["40"]])
        let merged = try #require(ConversationGrouping.merged(groups[0]))
        #expect(merged.comments.map(\.id) == ["10", "20", "11"])
        #expect(merged.isResolved == false)
    }

    @Test func resolvableDiscussionsWithoutAnAnchorStayApart() {
        let a = thread("d1", kind: .conversation, resolvable: true, comments: [comment("1", 0)])
        let b = thread("d2", kind: .conversation, resolvable: true, comments: [comment("2", 1)])
        #expect(ConversationGrouping.key(a) != ConversationGrouping.key(b))
    }

    @Test func inboxShowsOneCardPerConversation() throws {
        let first = thread("1", kind: .conversation, comments: [comment("1", 0)])
        let second = thread("2", kind: .conversation, comments: [comment("2", 5)])
        let inline = thread("9", kind: .diffThread, anchor: DiffAnchor(path: "src/a.ts", line: 3), resolvable: true,
                            comments: [comment("9", 7)])
        var state = previewState()
        let snap = snapshot([first, second, inline])
        state.changeRequests = state.changeRequests.map { $0.key == base.key ? snap : $0 }
        let items = [item(for: first, minutes: 1, unread: false), item(for: second, minutes: 6), item(for: inline, minutes: 8)]
        state.attention = state.attention.filter { $0.changeRequest != base.key } + items

        let result = InboxQuery.run(state: state, filter: InboxFilter(collapseRead: false), now: testNow)
        let group = try #require(result.groups.first { $0.changeRequest == base.key })
        #expect(group.items.count == 2)
        // The unread item represents the conversation; the read one is folded into it.
        let card = try #require(group.items.first { $0.thread == second.key })
        #expect(result.members(of: card.id).map(\.id).sorted() == [items[0].id, items[1].id].sorted())
        #expect(result.containingCard(of: items[0].id) == card.id)
    }

    @Test func readConversationsCollapseAsOne() throws {
        let first = thread("1", kind: .conversation, comments: [comment("1", 0)])
        let second = thread("2", kind: .conversation, comments: [comment("2", 5)])
        var state = previewState()
        state.changeRequests = state.changeRequests.map { $0.key == base.key ? snapshot([first, second]) : $0 }
        var read = [item(for: first, minutes: 1, unread: false), item(for: second, minutes: 6, unread: false)]
        read = read.map { var copy = $0; copy.disposition = .acknowledged; return copy }
        state.attention = state.attention.filter { $0.changeRequest != base.key }
        let baseline = InboxQuery.run(state: state, filter: InboxFilter(collapseRead: true), now: testNow).hiddenReadCount
        state.attention += read

        let collapsed = InboxQuery.run(state: state, filter: InboxFilter(collapseRead: true), now: testNow)
        #expect(collapsed.groups.first { $0.changeRequest == base.key } == nil)
        let all = InboxQuery.run(state: state, filter: InboxFilter(collapseRead: false), now: testNow)
        #expect(all.groups.first { $0.changeRequest == base.key }?.items.count == 1)
        // Two read items, one conversation: one hidden row.
        #expect(collapsed.hiddenReadCount == baseline + 1)
    }

    /// D55: acknowledging the open item of a conversation clears the card even when another item of the same
    /// conversation was resolved by the provider while still unread (it used to come back without a checkmark).
    @Test func acknowledgedConversationStaysClearedWithAnUnreadResolvedMember() throws {
        let first = thread("1", kind: .conversation, comments: [comment("1", 0)])
        let second = thread("2", kind: .conversation, comments: [comment("2", 5)])
        var state = previewState()
        state.changeRequests = state.changeRequests.map { $0.key == base.key ? snapshot([first, second]) : $0 }
        var resolved = item(for: first, minutes: 1)
        resolved.disposition = .resolved
        var acknowledged = item(for: second, minutes: 6, unread: false)
        acknowledged.disposition = .acknowledged
        state.attention = state.attention.filter { $0.changeRequest != base.key } + [resolved, acknowledged]

        let collapsed = InboxQuery.run(state: state, filter: InboxFilter(collapseRead: true), now: testNow)
        #expect(collapsed.groups.first { $0.changeRequest == base.key } == nil)
        let expanded = InboxQuery.run(state: state, filter: InboxFilter(collapseRead: true), now: testNow, showRead: true)
        #expect(expanded.groups.first { $0.changeRequest == base.key }?.items.count == 1)
    }
}
