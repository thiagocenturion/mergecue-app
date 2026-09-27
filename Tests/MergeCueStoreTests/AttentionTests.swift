import Foundation
import MergeCueCore
import Testing
@testable import MergeCueStore

@Suite("Attention items")
struct AttentionTests {
    let account = StoreFixture.githubAccount
    let cr = StoreFixture.changeRequestKey()

    /// Stores `item` through a sync batch and returns what was stored.
    private func upsert(_ item: AttentionItem, into database: MergeCueDatabase, at seconds: TimeInterval = 0) async throws -> AttentionItem {
        try await database.applySyncBatch(SyncBatch(account: account, attentionUpserts: [item], syncedAt: StoreFixture.at(seconds)))
        return try #require(try await database.attentionItem(dedupeKey: item.dedupeKey))
    }

    // MARK: Merge rule (through applySyncBatch)

    @Test func reDerivingTheSameStateKeepsTheUsersReadState() async throws {
        let database = try await StoreFixture.database()
        let item = StoreFixture.attentionItem(cr, eventIDs: ["evt_1"])
        _ = try await upsert(item, into: database)
        try await database.setAttentionUnread(id: item.id, false)

        // The next cycle re-derives the same item (unread + open, same events): nothing the user did is undone.
        let stored = try await upsert(item, into: database, at: 90)
        #expect(stored.isUnread == false)
        #expect(stored.disposition == .open)
    }

    @Test func newerActivityMarksAnOpenItemUnreadAgainAndUpdatesContent() async throws {
        let database = try await StoreFixture.database()
        let item = StoreFixture.attentionItem(cr, eventIDs: ["evt_1"], updatedAt: StoreFixture.at(0))
        _ = try await upsert(item, into: database)
        try await database.setAttentionUnread(id: item.id, false)

        let reply = StoreFixture.attentionItem(cr, eventIDs: ["evt_1", "evt_2"], summary: "Any update?", updatedAt: StoreFixture.at(60))
        let stored = try await upsert(reply, into: database, at: 60)
        #expect(stored.isUnread)
        #expect(stored.disposition == .open)
        #expect(stored.summary == "Any update?")
        #expect(stored.eventIDs == ["evt_1", "evt_2"])
        #expect(stored.createdAt == item.createdAt)
        #expect(stored.updatedAt == StoreFixture.at(60))
        #expect(try await database.attentionItems(includeInactive: true).count == 1)
    }

    @Test(arguments: [AttentionDisposition.acknowledged, .resolved])
    func newerActivityReopensAcknowledgedAndResolvedItems(_ disposition: AttentionDisposition) async throws {
        let database = try await StoreFixture.database()
        let item = StoreFixture.attentionItem(cr, eventIDs: ["evt_1"], updatedAt: StoreFixture.at(0))
        _ = try await upsert(item, into: database)
        try await database.setAttentionUnread(id: item.id, false)
        try await database.setAttentionDisposition(id: item.id, disposition)

        let newer = StoreFixture.attentionItem(cr, eventIDs: ["evt_1", "evt_2"], updatedAt: StoreFixture.at(60))
        let stored = try await upsert(newer, into: database, at: 60)
        #expect(stored.disposition == .open)
        #expect(stored.isUnread)
    }

    @Test(arguments: [AttentionDisposition.acknowledged, .resolved])
    func olderOrAlreadySeenEventsDoNotReopen(_ disposition: AttentionDisposition) async throws {
        let database = try await StoreFixture.database()
        let item = StoreFixture.attentionItem(cr, eventIDs: ["evt_1", "evt_2"], updatedAt: StoreFixture.at(100))
        _ = try await upsert(item, into: database)
        try await database.setAttentionUnread(id: item.id, false)
        try await database.setAttentionDisposition(id: item.id, disposition)

        // Same events again (a relaunch, a re-derivation): no change.
        var stored = try await upsert(item, into: database, at: 200)
        #expect(stored.disposition == disposition)
        #expect(stored.isUnread == false)

        // An event the item never had, but not newer than the stored activity: no change either.
        let older = StoreFixture.attentionItem(cr, eventIDs: ["evt_0"], updatedAt: StoreFixture.at(50))
        stored = try await upsert(older, into: database, at: 300)
        #expect(stored.disposition == disposition)
        #expect(stored.isUnread == false)
        #expect(stored.eventIDs == ["evt_1", "evt_2", "evt_0"])
        #expect(stored.updatedAt == StoreFixture.at(100))
    }

    @Test func dismissedStaysDismissed() async throws {
        let database = try await StoreFixture.database()
        let item = StoreFixture.attentionItem(cr, eventIDs: ["evt_1"], updatedAt: StoreFixture.at(0))
        _ = try await upsert(item, into: database)
        try await database.setAttentionUnread(id: item.id, false)
        try await database.setAttentionDisposition(id: item.id, .dismissed)

        let newer = StoreFixture.attentionItem(cr, eventIDs: ["evt_2"], updatedAt: StoreFixture.at(60))
        var stored = try await upsert(newer, into: database, at: 60)
        #expect(stored.disposition == .dismissed)
        #expect(stored.isUnread == false)

        let resolved = StoreFixture.attentionItem(cr, eventIDs: ["evt_3"], updatedAt: StoreFixture.at(90), disposition: .resolved)
        stored = try await upsert(resolved, into: database, at: 90)
        #expect(stored.disposition == .dismissed)
    }

    @Test func snoozedItemStaysSnoozedButBecomesUnread() async throws {
        let database = try await StoreFixture.database()
        let item = StoreFixture.attentionItem(cr, eventIDs: ["evt_1"], updatedAt: StoreFixture.at(0))
        _ = try await upsert(item, into: database)
        try await database.setAttentionUnread(id: item.id, false)
        try await database.setAttentionDisposition(id: item.id, .snoozed(until: StoreFixture.at(3_600)))

        let newer = StoreFixture.attentionItem(cr, eventIDs: ["evt_2"], updatedAt: StoreFixture.at(60))
        let stored = try await upsert(newer, into: database, at: 60)
        #expect(stored.disposition == .snoozed(until: StoreFixture.at(3_600)))
        #expect(stored.isUnread)
    }

    @Test func incomingResolutionResolvesOpenAcknowledgedAndSnoozedItems() async throws {
        let database = try await StoreFixture.database()
        let item = StoreFixture.attentionItem(cr, eventIDs: ["evt_1"], updatedAt: StoreFixture.at(0))
        _ = try await upsert(item, into: database)
        try await database.setAttentionDisposition(id: item.id, .snoozed(until: StoreFixture.at(3_600)))

        let cleared = StoreFixture.attentionItem(cr, eventIDs: ["evt_resolved"], updatedAt: StoreFixture.at(30), disposition: .resolved)
        let stored = try await upsert(cleared, into: database, at: 30)
        #expect(stored.disposition == .resolved)
        #expect(stored.isUnread, "read state is kept")
        #expect(try await database.attentionItems(includeInactive: false, now: StoreFixture.at(7_200)).isEmpty)
    }

    @Test func taskLinkAndCreationTimeSurviveReDerivation() async throws {
        let database = try await StoreFixture.database()
        try await database.insertTask(StoreFixture.task())
        let item = StoreFixture.attentionItem(cr, eventIDs: ["evt_1"], updatedAt: StoreFixture.at(0))
        _ = try await upsert(item, into: database)
        try await database.linkAttention(id: item.id, taskID: StoreFixture.task().id)

        // The deriver does not know about the link.
        let newer = StoreFixture.attentionItem(cr, eventIDs: ["evt_2"], updatedAt: StoreFixture.at(60))
        let stored = try await upsert(newer, into: database, at: 60)
        #expect(stored.linkedTaskID == StoreFixture.task().id)
        #expect(stored.createdAt == StoreFixture.at(0))
    }

    @Test func mergePolicyCapsEventIDs() {
        let existing = StoreFixture.attentionItem(cr, eventIDs: (0..<AttentionMergePolicy.maxEventIDs).map { "evt_\($0)" }, updatedAt: StoreFixture.at(0))
        let incoming = StoreFixture.attentionItem(cr, eventIDs: ["evt_new"], updatedAt: StoreFixture.at(1))
        let merged = AttentionMergePolicy.merge(existing: existing, incoming: incoming)
        #expect(merged.eventIDs.count == AttentionMergePolicy.maxEventIDs)
        #expect(merged.eventIDs.last == "evt_new")
        #expect(merged.eventIDs.first == "evt_1")
        #expect(AttentionMergePolicy.merge(existing: nil, incoming: incoming) == incoming)
    }

    // MARK: User actions and queries

    @Test func userActionsUpdateTheStoredItem() async throws {
        let database = try await StoreFixture.database()
        let item = StoreFixture.attentionItem(cr, eventIDs: ["evt_1"])
        _ = try await upsert(item, into: database)

        try await database.setAttentionUnread(id: item.id, false)
        try await database.setAttentionDisposition(id: item.id, .acknowledged)
        var expected = item
        expected.isUnread = false
        expected.disposition = .acknowledged
        #expect(try await database.attentionItem(id: item.id) == expected)

        try await database.insertTask(StoreFixture.task())
        try await database.linkAttention(id: item.id, taskID: StoreFixture.task().id)
        #expect(try await database.attentionItem(id: item.id)?.linkedTaskID == StoreFixture.task().id)
        try await database.linkAttention(id: item.id, taskID: nil)
        #expect(try await database.attentionItem(id: item.id)?.linkedTaskID == nil)
    }

    @Test func userActionsOnMissingRowsAreNotFound() async throws {
        let database = try await StoreFixture.database()
        await #expect(throws: StoreError.notFound) { try await database.setAttentionUnread(id: "att_missing000", true) }
        await #expect(throws: StoreError.notFound) { try await database.setAttentionDisposition(id: "att_missing000", .dismissed) }

        let item = StoreFixture.attentionItem(cr, eventIDs: [])
        _ = try await upsert(item, into: database)
        await #expect(throws: StoreError.notFound) {
            try await database.linkAttention(id: item.id, taskID: TaskID(rawValue: "mc_zzzzzz")!)
        }
    }

    @Test func activeListingHonoursDispositionsSnoozeExpiryAndPriority() async throws {
        let database = try await StoreFixture.database()
        func item(_ thread: String, reason: AttentionReason, updated: TimeInterval) -> AttentionItem {
            let key = StoreFixture.threadKey(cr, id: thread)
            return AttentionItem(
                dedupeKey: AttentionItem.dedupeKey(thread: key), changeRequest: cr, repoFullPath: "acme/payments-api",
                title: "Add retries", reason: reason, summary: thread, thread: key,
                createdAt: StoreFixture.at(updated), updatedAt: StoreFixture.at(updated)
            )
        }
        let normalOld = item("normal-old", reason: .reviewComment, updated: 0)
        let normalNew = item("normal-new", reason: .reviewComment, updated: 10)
        let high = item("high", reason: .ciFailed, updated: 5)
        let snoozed = item("snoozed", reason: .reply, updated: 20)
        let acknowledged = item("ack", reason: .reply, updated: 30)
        let dismissed = item("dismissed", reason: .reply, updated: 40)
        try await database.applySyncBatch(SyncBatch(
            account: account, attentionUpserts: [normalOld, normalNew, high, snoozed, acknowledged, dismissed], syncedAt: StoreFixture.date
        ))
        try await database.setAttentionDisposition(id: snoozed.id, .snoozed(until: StoreFixture.at(1_000)))
        try await database.setAttentionDisposition(id: acknowledged.id, .acknowledged)
        try await database.setAttentionDisposition(id: dismissed.id, .dismissed)

        let beforeExpiry = try await database.attentionItems(includeInactive: false, now: StoreFixture.at(999)).map(\.summary)
        #expect(beforeExpiry == ["high", "normal-new", "normal-old"])
        let afterExpiry = try await database.attentionItems(includeInactive: false, now: StoreFixture.at(1_000)).map(\.summary)
        #expect(afterExpiry == ["high", "snoozed", "normal-new", "normal-old"])
        #expect(try await database.attentionItems(includeInactive: true).count == 6)
        #expect(try await database.attentionItems(changeRequest: cr).count == 6)
        #expect(try await database.attentionItems(changeRequest: StoreFixture.changeRequestKey(remoteID: "other")).isEmpty)
    }
}
