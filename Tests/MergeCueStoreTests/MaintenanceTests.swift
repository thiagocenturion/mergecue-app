import Foundation
import MergeCueCore
import Testing
@testable import MergeCueStore

@Suite("Cascade, integrity, export, reset, retention")
struct MaintenanceTests {
    let account = StoreFixture.githubAccount
    let cr = StoreFixture.changeRequestKey()

    /// Fills `database` with one of everything for the GitHub account (and one GitLab row that must survive).
    private func populate(_ database: MergeCueDatabase) async throws {
        try await database.upsertAccount(StoreFixture.account(StoreFixture.gitlabAccount))
        try await database.upsertRepositories([StoreFixture.repository()])
        let event = StoreFixture.event(cr)
        try await database.applySyncBatch(SyncBatch(
            account: account,
            snapshots: [StoreFixture.snapshot(cr)],
            events: [event],
            attentionUpserts: [StoreFixture.attentionItem(cr, eventIDs: [event.id])],
            cursor: ["etag": "1"],
            syncedAt: StoreFixture.date
        ))
        let gitlabCR = StoreFixture.changeRequestKey(StoreFixture.gitlabAccount)
        try await database.applySyncBatch(SyncBatch(
            account: StoreFixture.gitlabAccount, snapshots: [StoreFixture.snapshot(gitlabCR)], syncedAt: StoreFixture.date
        ))
        let task = StoreFixture.task()
        try await database.insertTask(task)
        try await database.appendActivity(StoreFixture.activity())
        try await database.insertArtifact(Artifact(
            id: "art_0000000001", taskID: task.id, kind: .diff, createdAt: StoreFixture.date, title: "Diff", content: "diff", reportedBy: .system
        ))
        try await database.insertApproval(ApprovalRecord(
            id: "apr_1", taskID: task.id, action: .postReply, decision: .approved, decidedAt: StoreFixture.date, previewFingerprint: "fp"
        ))
        try await database.upsertMapping(RepoMapping(
            id: "map_0000000001", repo: StoreFixture.repoKey(), repoFullPath: "acme/payments-api", checkoutPath: "/tmp/api",
            confidence: .exact, createdAt: StoreFixture.date
        ))
        try await database.appendAudit(StoreFixture.audit("aud_1", taskID: task.id.rawValue))
        try await database.upsertRule(StoreFixture.rule())
        try await database.recordRuleFiring(ruleID: StoreFixture.rule().id, eventID: event.id, at: StoreFixture.date)
        try await database.setSetting("theme", "dark")
    }

    private func count(_ table: String, in database: MergeCueDatabase) async throws -> Int {
        Int(try await database.queryTextForTesting("SELECT COUNT(*) FROM \(table)").first ?? "") ?? -1
    }

    // MARK: Cascade

    @Test func deleteAccountCascadesButKeepsTheAuditLog() async throws {
        let database = try await StoreFixture.database()
        try await populate(database)
        #expect(try await database.deleteAccount(account))

        for table in [
            "repositories", "events", "attention_items", "tasks", "task_activities", "artifacts", "approvals", "repo_mappings",
        ] {
            #expect(try await count(table, in: database) == 0, "\(table) should be empty")
        }
        #expect(try await database.snapshots(account: account).isEmpty)
        #expect(try await database.hasCompletedInitialSync(account: account) == false)
        #expect(try await database.cursor(account: account) == [:])
        // Other accounts, the audit log, rules and settings are untouched.
        #expect(try await database.snapshots(account: StoreFixture.gitlabAccount).count == 1)
        #expect(try await database.auditEntries(limit: 10).map(\.id) == ["aud_1"])
        #expect(try await database.rules().count == 1)
        #expect(try await database.setting("theme", as: String.self) == "dark")
        #expect(try await database.integrityCheck())
    }

    // MARK: Integrity

    @Test func healthyDatabasePassesTheIntegrityCheck() async throws {
        let database = try await StoreFixture.database()
        try await populate(database)
        #expect(try await database.integrityCheck())
    }

    @Test func damagedPagesFailTheIntegrityCheck() async throws {
        let path = try StoreFixture.temporaryDatabasePath("corrupt")
        let rootPage: Int
        let pageSize: Int
        do {
            let database = try await openPopulatedFile(path)
            let events = (0..<400).map { StoreFixture.event(cr, objectID: "bulk-\($0)") }
            try await database.applySyncBatch(SyncBatch(account: account, events: events, syncedAt: StoreFixture.date))
            rootPage = Int(try await database.queryTextForTesting("SELECT rootpage FROM sqlite_master WHERE name = 'events_by_cr'").first ?? "") ?? 0
            pageSize = Int(try await database.queryTextForTesting("PRAGMA page_size").first ?? "") ?? 0
            // Move everything from the WAL into the main file before editing it behind SQLite's back.
            try await database.executeForTesting("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        #expect(rootPage > 1)
        #expect(pageSize > 0)

        // Overwrite the index's root page with garbage (the schema on page 1 stays readable).
        let handle = try FileHandle(forUpdating: URL(filePath: path))
        try handle.seek(toOffset: UInt64((rootPage - 1) * pageSize))
        try handle.write(contentsOf: Data(repeating: 0xA5, count: pageSize))
        try handle.close()

        let damaged = try MergeCueDatabase(path: path)
        #expect(try await damaged.integrityCheck() == false)
    }

    @Test func fileThatIsNotADatabaseIsReportedAsCorruptedAndCanBeReplaced() async throws {
        let path = try StoreFixture.temporaryDatabasePath("garbage")
        try Data(repeating: 0x42, count: 8_192).write(to: URL(filePath: path))
        do {
            _ = try MergeCueDatabase(path: path)
            Issue.record("expected StoreError.corrupted")
        } catch let error as StoreError {
            guard case .corrupted = error else {
                Issue.record("expected .corrupted, got \(error)")
                return
            }
        }
        try MergeCueDatabase.removeDatabaseFiles(atPath: path)
        let fresh = try MergeCueDatabase(path: path)
        #expect(try await fresh.integrityCheck())
        #expect(try await fresh.schemaVersion() == 1)
    }

    // MARK: Export

    @Test func exportCopyIsAComplete0600Snapshot() async throws {
        let path = try StoreFixture.temporaryDatabasePath("export-source")
        let database = try await openPopulatedFile(path)
        let destination = try StoreFixture.temporaryDirectory("export").appending(path: "backup.sqlite").path(percentEncoded: false)

        try await database.exportCopy(to: destination)
        #expect(DatabaseFile.permissions(atPath: destination) == 0o600)
        let copy = try MergeCueDatabase(path: destination)
        #expect(try await copy.integrityCheck())
        #expect(try await copy.snapshot(cr) == StoreFixture.snapshot(cr))
        #expect(try await copy.task(StoreFixture.task().id) == StoreFixture.task())
        #expect(try await copy.auditEntries(limit: 10).count == 1)

        // Exporting again replaces the previous export atomically and leaves no temporary files behind.
        try await database.upsertRule(StoreFixture.rule("rule_0000000009"))
        try await database.exportCopy(to: destination)
        let reopened = try MergeCueDatabase(path: destination)
        #expect(try await reopened.rules().count == 2)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: (destination as NSString).deletingLastPathComponent)
            .filter { $0.contains(".export-") }
        #expect(leftovers.isEmpty)

        await #expect(throws: StoreError.self) { try await database.exportCopy(to: path) }
    }

    @Test func inMemoryDatabaseCanBeExported() async throws {
        let database = try await StoreFixture.database()
        try await populate(database)
        let destination = try StoreFixture.temporaryDirectory("export-memory").appending(path: "copy.sqlite").path(percentEncoded: false)
        try await database.exportCopy(to: destination)
        let copy = try MergeCueDatabase(path: destination)
        #expect(try await copy.accounts().count == 2)
    }

    // MARK: Reset

    @Test func resetAllDropsAllDataAndKeepsAWorkingSchema() async throws {
        let path = try StoreFixture.temporaryDatabasePath("reset")
        let database = try await openPopulatedFile(path)
        try await database.resetAll()

        #expect(try await database.accounts().isEmpty)
        #expect(try await database.auditEntries(limit: 10).isEmpty)
        #expect(try await database.rules().isEmpty)
        #expect(try await database.setting("theme", as: String.self) == nil)
        for table in SchemaV1.tables where table != "store_maintenance" {
            #expect(try await count(table, in: database) == 0, "\(table) should be empty")
        }
        #expect(try await database.schemaVersion() == 1)
        #expect(try await database.integrityCheck())
        #expect(DatabaseFile.permissions(atPath: path) == 0o600)

        // Fully usable afterwards.
        try await database.upsertAccount(StoreFixture.account())
        #expect(try await database.accounts().count == 1)
    }

    @Test func resetAllWorksInMemory() async throws {
        let database = try await StoreFixture.database()
        try await populate(database)
        try await database.resetAll()
        #expect(try await database.accounts().isEmpty)
        #expect(try await database.schemaVersion() == 1)
    }

    // MARK: Retention

    @Test func pruneHistoryRemovesOldHistoryButNeverDataOfNonTerminalTasks() async throws {
        let database = try await StoreFixture.database()
        let activeCR = StoreFixture.changeRequestKey(remoteID: "active", number: 1)
        let doneCR = StoreFixture.changeRequestKey(remoteID: "done", number: 2)
        let old = StoreFixture.at(-90 * 86_400)
        let recent = StoreFixture.at(-86_400)
        let cutoff = StoreFixture.at(-30 * 86_400)

        let oldActiveEvent = StoreFixture.event(activeCR, objectID: "a-old", occurredAt: old, detectedAt: old)
        let oldDoneEvent = StoreFixture.event(doneCR, objectID: "d-old", occurredAt: old, detectedAt: old)
        let recentDoneEvent = StoreFixture.event(doneCR, objectID: "d-new", occurredAt: recent, detectedAt: recent)
        try await database.applySyncBatch(SyncBatch(
            account: account, events: [oldActiveEvent, oldDoneEvent, recentDoneEvent], syncedAt: recent
        ))

        let active = StoreFixture.task("mc_active", changeRequest: activeCR, state: .working)
        let done = StoreFixture.task("mc_done01", changeRequest: doneCR, state: .done)
        try await database.insertTask(active)
        try await database.insertTask(done)
        let offset = old.timeIntervalSince(StoreFixture.date)
        try await database.appendActivity(StoreFixture.activity("act_a_old", task: "mc_active", at: offset))
        try await database.appendActivity(StoreFixture.activity("act_d_old", task: "mc_done01", at: offset))
        try await database.appendActivity(StoreFixture.activity("act_d_new", task: "mc_done01", at: recent.timeIntervalSince(StoreFixture.date)))

        try await database.appendAudit(StoreFixture.audit("aud_active", at: offset, taskID: "mc_active"))
        try await database.appendAudit(StoreFixture.audit("aud_done", at: offset, taskID: "mc_done01"))
        try await database.appendAudit(StoreFixture.audit("aud_plain", at: offset))
        try await database.appendAudit(StoreFixture.audit("aud_recent", at: recent.timeIntervalSince(StoreFixture.date)))

        let rule = StoreFixture.rule()
        try await database.upsertRule(rule)
        try await database.recordRuleFiring(ruleID: rule.id, eventID: oldDoneEvent.id, at: old)
        try await database.recordRuleFiring(ruleID: rule.id, eventID: oldActiveEvent.id, at: old)

        let removed = try await database.pruneHistory(olderThan: cutoff)
        // 1 event + 1 activity + 2 audit entries + 1 orphaned firing.
        #expect(removed == 5)

        #expect(try await database.events(changeRequest: activeCR) == [oldActiveEvent])
        #expect(try await database.events(changeRequest: doneCR) == [recentDoneEvent])
        #expect(try await database.activities(task: active.id).map(\.id) == ["act_a_old"])
        #expect(try await database.activities(task: done.id).map(\.id) == ["act_d_new"])
        #expect(Set(try await database.auditEntries(limit: 10).map(\.id)) == ["aud_active", "aud_recent"])
        #expect(try await database.hasRuleFired(ruleID: rule.id, eventID: oldActiveEvent.id))
        #expect(try await database.hasRuleFired(ruleID: rule.id, eventID: oldDoneEvent.id) == false)
        #expect(try await database.task(done.id) == done, "tasks themselves are kept")

        // The append-only guards are active again after pruning.
        await #expect(throws: StoreError.self) { try await database.executeForTesting("DELETE FROM audit_log") }
        #expect(try await database.pruneHistory(olderThan: cutoff) == 0)
    }

    // MARK: Helpers

    private func openPopulatedFile(_ path: String) async throws -> MergeCueDatabase {
        let database = try MergeCueDatabase(path: path)
        try await database.upsertAccount(StoreFixture.account())
        try await populate(database)
        return database
    }
}
