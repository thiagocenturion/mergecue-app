import Foundation
import MergeCueCore
import Testing
@testable import MergeCueStore

@Suite("Sync batches")
struct SyncBatchTests {
    let account = StoreFixture.githubAccount
    let crA = StoreFixture.changeRequestKey(remoteID: "789", number: 42)
    let crB = StoreFixture.changeRequestKey(remoteID: "790", number: 43)

    @Test func batchPersistsSnapshotsEventsAttentionCursorAndInitialSync() async throws {
        let database = try await StoreFixture.database()
        #expect(try await database.hasCompletedInitialSync(account: account) == false)
        #expect(try await database.cursor(account: account) == [:])

        let snapshot = StoreFixture.snapshot(crA)
        let event = StoreFixture.event(crA, isBaseline: true)
        let item = StoreFixture.attentionItem(crA, eventIDs: [event.id])
        let inserted = try await database.applySyncBatch(SyncBatch(
            account: account,
            snapshots: [snapshot],
            events: [event],
            attentionUpserts: [item],
            cursor: ["authored_etag": "W/\"abc\""],
            syncedAt: StoreFixture.at(5)
        ))

        #expect(inserted == [event])
        // Lossless: the stored snapshot is == to the fetched one (sub-second dates included).
        #expect(try await database.snapshot(crA) == snapshot)
        #expect(try await database.snapshots(account: account) == [snapshot])
        #expect(try await database.snapshots(account: nil) == [snapshot])
        #expect(try await database.events(changeRequest: crA) == [event])
        #expect(try await database.event(id: event.id) == event)
        #expect(try await database.attentionItem(id: item.id) == item)
        #expect(try await database.attentionItem(dedupeKey: item.dedupeKey) == item)
        #expect(try await database.cursor(account: account) == ["authored_etag": "W/\"abc\""])
        #expect(try await database.hasCompletedInitialSync(account: account))
        #expect(try await database.lastSyncAt(account: account) == StoreFixture.at(5))
    }

    @Test func repeatedBatchesInsertEachEventExactlyOnce() async throws {
        let database = try await StoreFixture.database()
        let e1 = StoreFixture.event(crA, objectID: "c1")
        let e2 = StoreFixture.event(crA, objectID: "c2")
        let e3 = StoreFixture.event(crA, type: .ciFailed, objectID: "chk", version: "failure#1")
        let first = SyncBatch(account: account, snapshots: [StoreFixture.snapshot(crA)], events: [e1, e2], syncedAt: StoreFixture.date)

        #expect(try await database.applySyncBatch(first) == [e1, e2])
        #expect(try await database.applySyncBatch(first).isEmpty)
        #expect(try await database.applySyncBatch(first).isEmpty)

        // Overlapping batch: only the unseen event is new; a duplicate inside one batch is inserted once.
        let overlapping = SyncBatch(account: account, events: [e2, e3, e3], syncedAt: StoreFixture.at(1))
        #expect(try await database.applySyncBatch(overlapping) == [e3])
        #expect(try await database.events(changeRequest: crA).map(\.id).sorted() == [e1, e2, e3].map(\.id).sorted())

        // Same object, new version → a genuinely new event.
        let e3Retry = StoreFixture.event(crA, type: .ciFailed, objectID: "chk", version: "failure#2")
        #expect(try await database.applySyncBatch(SyncBatch(account: account, events: [e3Retry], syncedAt: StoreFixture.at(2))) == [e3Retry])
        #expect(try await database.recentEvents(limit: 100).count == 4)
    }

    @Test func eventsAreOrderedPerChangeRequestAndRecentFirstGlobally() async throws {
        let database = try await StoreFixture.database()
        let late = StoreFixture.event(crA, objectID: "late", occurredAt: StoreFixture.at(20), detectedAt: StoreFixture.at(30))
        let early = StoreFixture.event(crA, objectID: "early", occurredAt: StoreFixture.at(10), detectedAt: StoreFixture.at(30))
        let other = StoreFixture.event(crB, objectID: "other", occurredAt: StoreFixture.at(5), detectedAt: StoreFixture.at(40))
        try await database.applySyncBatch(SyncBatch(account: account, events: [late, early, other], syncedAt: StoreFixture.at(40)))

        #expect(try await database.events(changeRequest: crA) == [early, late])
        #expect(try await database.events(changeRequest: crB) == [other])
        #expect(try await database.recentEvents(limit: 2) == [other, early])
        #expect(try await database.recentEvents(limit: 0).isEmpty)
    }

    @Test func snapshotsAreUpsertedAndRemoved() async throws {
        let database = try await StoreFixture.database()
        let a1 = StoreFixture.snapshot(crA, updatedAt: StoreFixture.at(1))
        let b1 = StoreFixture.snapshot(crB, updatedAt: StoreFixture.at(2))
        try await database.applySyncBatch(SyncBatch(account: account, snapshots: [a1, b1], syncedAt: StoreFixture.at(2)))
        #expect(try await database.snapshots(account: account) == [b1, a1])

        let a2 = StoreFixture.snapshot(crA, title: "Add retries (v2)", state: .merged, headSHA: "def456", updatedAt: StoreFixture.at(3))
        try await database.applySyncBatch(SyncBatch(account: account, snapshots: [a2], removedChangeRequests: [crB], syncedAt: StoreFixture.at(3)))
        #expect(try await database.snapshots(account: account) == [a2])
        #expect(try await database.snapshot(crB) == nil)

        // A key both upserted and removed in one batch ends up removed.
        try await database.applySyncBatch(SyncBatch(account: account, snapshots: [a2], removedChangeRequests: [crA], syncedAt: StoreFixture.at(4)))
        #expect(try await database.snapshot(crA) == nil)
    }

    @Test func snapshotLookupIgnoresTheDisplayNumber() async throws {
        let database = try await StoreFixture.database()
        try await database.applySyncBatch(SyncBatch(account: account, snapshots: [StoreFixture.snapshot(crA)], syncedAt: StoreFixture.date))
        let stalePlaceholder = StoreFixture.changeRequestKey(remoteID: "789", number: 0)
        #expect(try await database.snapshot(stalePlaceholder) != nil)
    }

    @Test func cursorIsReplacedByEachBatch() async throws {
        let database = try await StoreFixture.database()
        try await database.applySyncBatch(SyncBatch(account: account, cursor: ["a": "1", "b": "2"], syncedAt: StoreFixture.at(1)))
        try await database.applySyncBatch(SyncBatch(account: account, cursor: ["a": "3"], syncedAt: StoreFixture.at(2)))
        #expect(try await database.cursor(account: account) == ["a": "3"])
        #expect(try await database.lastSyncAt(account: account) == StoreFixture.at(2))
    }

    @Test func batchIsAtomic() async throws {
        let database = try await StoreFixture.database()
        let good = StoreFixture.event(crA, objectID: "good")
        // Two different items that claim the same `id` → the second write violates the primary key mid-transaction.
        let first = StoreFixture.attentionItem(crA, eventIDs: [good.id])
        var clash = StoreFixture.attentionItem(crA, thread: StoreFixture.threadKey(crA, id: "PRRT_2"), eventIDs: [good.id])
        clash.id = first.id
        let batch = SyncBatch(
            account: account,
            snapshots: [StoreFixture.snapshot(crA)],
            events: [good],
            attentionUpserts: [first, clash],
            cursor: ["page": "2"],
            syncedAt: StoreFixture.date
        )
        await #expect(throws: StoreError.self) {
            try await database.applySyncBatch(batch)
        }
        #expect(try await database.snapshot(crA) == nil)
        #expect(try await database.recentEvents(limit: 10).isEmpty)
        #expect(try await database.attentionItems(includeInactive: true).isEmpty)
        #expect(try await database.cursor(account: account) == [:])
        #expect(try await database.hasCompletedInitialSync(account: account) == false)

        // After the failure the same events are still "new".
        let retry = SyncBatch(account: account, events: [good], syncedAt: StoreFixture.date)
        #expect(try await database.applySyncBatch(retry) == [good])
    }

    @Test func batchRejectsRowsOfAnotherAccount() async throws {
        let database = try await StoreFixture.database(accounts: [StoreFixture.githubAccount, StoreFixture.gitlabAccount])
        let foreign = StoreFixture.changeRequestKey(StoreFixture.gitlabAccount)
        let batches = [
            SyncBatch(account: account, snapshots: [StoreFixture.snapshot(foreign)], syncedAt: StoreFixture.date),
            SyncBatch(account: account, removedChangeRequests: [foreign], syncedAt: StoreFixture.date),
            SyncBatch(account: account, events: [StoreFixture.event(foreign)], syncedAt: StoreFixture.date),
            SyncBatch(account: account, attentionUpserts: [StoreFixture.attentionItem(foreign, eventIDs: [])], syncedAt: StoreFixture.date),
        ]
        for batch in batches {
            await #expect(throws: StoreError.self) {
                try await database.applySyncBatch(batch)
            }
        }
        #expect(try await database.hasCompletedInitialSync(account: account) == false)
    }

    @Test func batchForAnUnknownAccountIsNotFound() async throws {
        let database = try MergeCueDatabase.inMemory()
        await #expect(throws: StoreError.notFound) {
            try await database.applySyncBatch(SyncBatch(account: StoreFixture.githubAccount, syncedAt: StoreFixture.date))
        }
    }

    @Test func accountsAreIsolated() async throws {
        let database = try await StoreFixture.database(accounts: [StoreFixture.githubAccount, StoreFixture.gitlabAccount])
        let gitlabCR = StoreFixture.changeRequestKey(StoreFixture.gitlabAccount)
        try await database.applySyncBatch(SyncBatch(account: account, snapshots: [StoreFixture.snapshot(crA)], cursor: ["gh": "1"], syncedAt: StoreFixture.date))
        try await database.applySyncBatch(SyncBatch(
            account: StoreFixture.gitlabAccount, snapshots: [StoreFixture.snapshot(gitlabCR)], cursor: ["gl": "1"], syncedAt: StoreFixture.date
        ))
        #expect(try await database.snapshots(account: account).map(\.key) == [crA])
        #expect(try await database.snapshots(account: StoreFixture.gitlabAccount).map(\.key) == [gitlabCR])
        #expect(try await database.snapshots(account: nil).count == 2)
        #expect(try await database.cursor(account: account) == ["gh": "1"])
        #expect(try await database.cursor(account: StoreFixture.gitlabAccount) == ["gl": "1"])
    }
}
