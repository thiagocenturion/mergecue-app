import Foundation
import MergeCueCore
import Testing
@testable import MergeCueStore

@Suite("Rules, mappings, settings, audit")
struct RuleMappingSettingsTests {
    // MARK: Rules

    @Test func rulesCRUD() async throws {
        let database = try MergeCueDatabase.inMemory()
        var rule = StoreFixture.rule("rule_0000000001", createdAt: StoreFixture.at(1))
        let older = StoreFixture.rule("rule_0000000002", createdAt: StoreFixture.at(0))
        try await database.upsertRule(rule)
        try await database.upsertRule(older)
        #expect(try await database.rule(id: rule.id) == rule)
        #expect(try await database.rules() == [older, rule])

        rule.isActive = true
        rule.name = "Renamed"
        rule.updatedAt = StoreFixture.at(5)
        try await database.upsertRule(rule)
        #expect(try await database.rule(id: rule.id) == rule)

        #expect(try await database.deleteRule(id: rule.id))
        #expect(try await database.deleteRule(id: rule.id) == false)
        #expect(try await database.rules() == [older])
        #expect(try await database.rule(id: rule.id) == nil)
    }

    @Test func ruleFiringIsIdempotentPerRuleAndEvent() async throws {
        let database = try MergeCueDatabase.inMemory()
        let rule = StoreFixture.rule()
        let other = StoreFixture.rule("rule_0000000002")
        try await database.upsertRule(rule)
        try await database.upsertRule(other)

        #expect(try await database.recordRuleFiring(ruleID: rule.id, eventID: "evt_1", at: StoreFixture.at(0)))
        #expect(try await database.recordRuleFiring(ruleID: rule.id, eventID: "evt_1", at: StoreFixture.at(5)) == false)
        #expect(try await database.recordRuleFiring(ruleID: rule.id, eventID: "evt_1", at: StoreFixture.at(9)) == false)
        #expect(try await database.recordRuleFiring(ruleID: other.id, eventID: "evt_1", at: StoreFixture.at(0)))
        #expect(try await database.recordRuleFiring(ruleID: rule.id, eventID: "evt_2", at: StoreFixture.at(3_000)))
        #expect(try await database.hasRuleFired(ruleID: rule.id, eventID: "evt_1"))
        #expect(try await database.hasRuleFired(ruleID: rule.id, eventID: "evt_9") == false)

        #expect(try await database.ruleFiringCount(ruleID: rule.id, since: StoreFixture.at(0)) == 2)
        #expect(try await database.ruleFiringCount(ruleID: rule.id, since: StoreFixture.at(1)) == 1)
        #expect(try await database.ruleFiringCount(ruleID: other.id, since: StoreFixture.at(0)) == 1)

        await #expect(throws: StoreError.notFound) {
            try await database.recordRuleFiring(ruleID: "rule_missing000", eventID: "evt_1", at: StoreFixture.date)
        }

        // Deleting a rule removes its firings.
        try await database.deleteRule(id: rule.id)
        try await database.upsertRule(rule)
        #expect(try await database.ruleFiringCount(ruleID: rule.id, since: .distantPast) == 0)
        #expect(try await database.recordRuleFiring(ruleID: rule.id, eventID: "evt_1", at: StoreFixture.date))
    }

    // MARK: Mappings

    @Test func mappingsCRUDAndSanitizedRemotes() async throws {
        let database = try await StoreFixture.database()
        let repo = StoreFixture.repoKey()
        let mapping = RepoMapping(
            id: "map_0000000001", repo: repo, repoFullPath: "acme/payments-api", checkoutPath: "/Users/mona/src/payments-api",
            confidence: .exact, matchedRemote: "https://mona:hunter2@github.com/acme/payments-api.git", createdAt: StoreFixture.at(0)
        )
        var second = RepoMapping(
            id: "map_0000000002", repo: repo, repoFullPath: "acme/payments-api", checkoutPath: "/Users/mona/wt/payments-api",
            confidence: .probable, createdAt: StoreFixture.at(1)
        )
        let elsewhere = RepoMapping(
            id: "map_0000000003", repo: StoreFixture.repoKey(id: "999"), repoFullPath: "acme/other", checkoutPath: "/tmp/other",
            confidence: .mismatch, createdAt: StoreFixture.at(2)
        )
        try await database.upsertMapping(mapping)
        try await database.upsertMapping(second)
        try await database.upsertMapping(elsewhere)

        #expect(try await database.mappings(repo: repo) == [mapping, second])
        #expect(try await database.mappings(repo: nil) == [mapping, second, elsewhere])
        #expect(try await database.mapping(id: mapping.id)?.matchedRemote?.contains("hunter2") == false)

        second.confirmedAt = StoreFixture.at(10)
        second.confidence = .exact
        try await database.upsertMapping(second)
        #expect(try await database.mapping(id: second.id) == second)

        #expect(try await database.deleteMapping(id: mapping.id))
        #expect(try await database.deleteMapping(id: mapping.id) == false)
        #expect(try await database.mappings(repo: repo) == [second])
    }

    @Test func mappingRequiresItsAccount() async throws {
        let database = try MergeCueDatabase.inMemory()
        let mapping = RepoMapping(
            id: "map_0000000001", repo: StoreFixture.repoKey(), repoFullPath: "acme/payments-api", checkoutPath: "/tmp/x",
            confidence: .exact, createdAt: StoreFixture.date
        )
        await #expect(throws: StoreError.notFound) { try await database.upsertMapping(mapping) }
    }

    // MARK: Settings

    struct NotificationPreferences: Codable, Equatable {
        var enabled: Bool
        var quietHours: QuietHours?
        var pollSeconds: Double
        var lastShownAt: Date
    }

    @Test func settingsRoundTrip() async throws {
        let database = try MergeCueDatabase.inMemory()
        #expect(try await database.setting("prefs", as: NotificationPreferences.self) == nil)

        let prefs = NotificationPreferences(
            enabled: true,
            quietHours: QuietHours(startMinute: 1_320, endMinute: 420, timeZoneID: "America/Sao_Paulo"),
            pollSeconds: 90,
            lastShownAt: StoreFixture.date
        )
        try await database.setSetting("prefs", prefs)
        try await database.setSetting("launchAtLogin", true)
        try await database.setSetting("pollSeconds", 45)
        try await database.setSetting("theme", "system")
        #expect(try await database.setting("prefs", as: NotificationPreferences.self) == prefs)
        #expect(try await database.setting("launchAtLogin", as: Bool.self) == true)
        #expect(try await database.setting("pollSeconds", as: Int.self) == 45)
        #expect(try await database.setting("theme", as: String.self) == "system")

        try await database.setSetting("theme", "dark")
        #expect(try await database.setting("theme", as: String.self) == "dark")

        try await database.setSetting("theme", String?.none)
        #expect(try await database.setting("theme", as: String.self) == nil)
        try await database.removeSetting("pollSeconds")
        #expect(try await database.setting("pollSeconds", as: Int.self) == nil)
        try await database.removeSetting("never-set")

        // A setting read as the wrong type is a decoding failure, not a silent nil.
        await #expect(throws: StoreError.self) { try await database.setting("launchAtLogin", as: NotificationPreferences.self) }
    }

    @Test func settingsRefuseCredentialsAndSecretShapedValues() async throws {
        let database = try MergeCueDatabase.inMemory()
        let credential = Credential(secret: .bearer("ghp_" + String(repeating: "A", count: 36)))
        await #expect(throws: StoreError.self) { try await database.setSetting("github", credential) }
        await #expect(throws: StoreError.self) { try await database.setSetting("github", credential.secret) }
        await #expect(throws: StoreError.self) {
            try await database.setSetting("header", "Authorization: Bearer ghp_" + String(repeating: "B", count: 36))
        }
        #expect(try await database.queryTextForTesting("SELECT COUNT(*) FROM settings") == ["0"])
    }

    // MARK: Audit

    @Test func auditIsAppendOnlyAndNewestFirst() async throws {
        let database = try MergeCueDatabase.inMemory()
        let first = StoreFixture.audit("aud_1", at: 0, taskID: "mc_abc123")
        let second = StoreFixture.audit("aud_2", at: 10)
        let third = StoreFixture.audit("aud_3", at: 20, taskID: "mc_abc123")
        for entry in [first, second, third] {
            try await database.appendAudit(entry)
        }
        #expect(try await database.auditEntries(limit: 10) == [third, second, first])
        #expect(try await database.auditEntries(limit: 2) == [third, second])
        #expect(try await database.auditEntries(limit: 10, taskID: TaskID(rawValue: "mc_abc123")) == [third, first])

        await #expect(throws: StoreError.self) { try await database.appendAudit(first) }
        await #expect(throws: StoreError.self) { try await database.executeForTesting("UPDATE audit_log SET outcome = 'failed'") }
        await #expect(throws: StoreError.self) { try await database.executeForTesting("DELETE FROM audit_log") }
        #expect(try await database.auditEntries(limit: 10).count == 3)
    }

    @Test func auditAndActivityTextIsRedacted() async throws {
        let database = try await StoreFixture.database()
        try await database.insertTask(StoreFixture.task())
        let token = "glpat-" + String(repeating: "x", count: 20)
        try await database.appendAudit(StoreFixture.audit("aud_1", detail: "401 for PRIVATE-TOKEN: \(token)"))
        try await database.appendActivity(StoreFixture.activity(message: "used token \(token)"))
        let audit = try #require(try await database.auditEntries(limit: 1).first)
        let activity = try #require(try await database.activities(task: StoreFixture.task().id).first)
        #expect(audit.detail.contains(token) == false)
        #expect(audit.detail.contains(SecretRedactor.marker))
        #expect(activity.message.contains(token) == false)
    }
}
