import Foundation
import MergeCueCore
import Testing
@testable import MergeCueSync

@Suite("NotificationGrouper and scheduling")
struct NotificationGrouperTests {
    typealias F = SyncFixture
    let now = F.at(100)

    struct Cycle {
        var events: [ChangeEvent]
        var items: [AttentionItem]
        var snapshots: [ChangeRequestKey: ChangeRequestSnapshot]
    }

    func cycle(_ pairs: [(ChangeRequestSnapshot?, ChangeRequestSnapshot)], account: AccountKey = F.github, baseline: Bool = false) -> Cycle {
        var result = Cycle(events: [], items: [], snapshots: [:])
        for (previous, current) in pairs {
            let events = EventDeriver.derive(previous: previous, current: current, currentUserID: F.me, isBaseline: baseline, now: now)
            result.events += events
            result.items += AttentionDeriver.apply(events: events, snapshot: current, existing: [], account: F.account(account), now: now)
            result.snapshots[current.key] = current
        }
        return result
    }

    func group(
        _ cycle: Cycle, existing: [AttentionItem] = [], account: AccountKey = F.github,
        preferences: NotificationPreferences = .allEnabled
    ) -> [GroupedNotification] {
        NotificationGrouper.group(
            newEvents: cycle.events, attentionUpserts: cycle.items,
            existing: Dictionary(uniqueKeysWithValues: existing.map { ($0.dedupeKey, $0) }),
            snapshots: cycle.snapshots, account: F.account(account), preferences: preferences, now: now
        )
    }

    // MARK: Notification preferences ("Notify me about")

    @Test func switchedOffCategoriesAreSilentPerReason() throws {
        let cr = F.crKey()
        let busy = F.snapshot(
            cr,
            threads: [
                F.thread(F.threadKey(cr, "A"), comments: [F.comment("1", "Why a loop?")]),
                F.thread(F.threadKey(cr, "B"), comments: [F.comment("2", "Rename this")]),
            ],
            checks: [F.check(cr, id: "9", status: .failure)]
        )
        let result = cycle([(F.snapshot(cr), busy)])
        let reasons = Set(result.items.map(\.reason))
        #expect(reasons == [.reviewerQuestion, .reviewComment, .ciFailed])

        let noCI = try #require(group(result, preferences: NotificationPreferences(disabled: [.ciFailures])).first)
        #expect(noCI.attentionItemIDs.count == 2)
        #expect(!noCI.body.contains("CI failed"))

        let onlyCI = try #require(group(result, preferences: NotificationPreferences(disabled: [.reviewComments, .reviewerQuestions])).first)
        #expect(onlyCI.attentionItemIDs == result.items.filter { $0.reason == .ciFailed }.map(\.id))

        let nothing = NotificationPreferences(disabled: [.reviewComments, .reviewerQuestions, .ciFailures])
        #expect(group(result, preferences: nothing).isEmpty, "every item switched off → no notification for the CR")
        // The items themselves are untouched by preferences (they come from the deriver, not the grouper).
        #expect(result.items.allSatisfy { $0.disposition == .open })
    }

    @Test func reviewRequestsAndApprovalsFollowTheirSwitches() {
        let cr = F.crKey()
        // Approval on my CR (informational).
        let approved = F.snapshot(cr, reviews: [F.review("r1", .approved)])
        let approvalCycle = cycle([(F.snapshot(cr), approved)])
        #expect(group(approvalCycle).count == 1)
        #expect(group(approvalCycle, preferences: NotificationPreferences(disabled: [.approvals])).isEmpty)
        #expect(group(approvalCycle, preferences: NotificationPreferences(disabled: [.reviewRequests, .ciFailures])).count == 1)
    }

    @Test func preferencesMapEveryReasonAndEncodeStably() throws {
        for reason in AttentionReason.allCases {
            let category = NotificationCategory(reason: reason)
            #expect(!NotificationPreferences(disabled: [category]).allows(reason))
            #expect(NotificationPreferences.allEnabled.allows(reason))
        }
        #expect(NotificationCategory(reason: .reviewRequested) == .reviewRequests)
        #expect(NotificationCategory(reason: .reviewerQuestion) == .reviewerQuestions)
        #expect(NotificationCategory(reason: .changesRequested) == .reviewComments)
        #expect(NotificationCategory(reason: .readyToMerge) == .approvals)
        #expect(NotificationPreferences.allEnabled.allows(informationalEvent: .ciRecovered))
        #expect(!NotificationPreferences(disabled: [.approvals]).allows(informationalEvent: .approval))

        let prefs = NotificationPreferences(disabled: [.ciFailures, .agentResults, .approvals])
        let a = try MergeCueCoding.storageEncoder().encode(prefs)
        let b = try MergeCueCoding.storageEncoder().encode(NotificationPreferences(disabled: [.approvals, .agentResults, .ciFailures]))
        #expect(a == b)
        #expect(String(decoding: a, as: UTF8.self) == #"{"disabled":["agent_results","approvals","ci_failures"]}"#)
        #expect(try MergeCueCoding.storageDecoder().decode(NotificationPreferences.self, from: a) == prefs)
        // Unknown categories from a newer build are ignored, missing field = all on.
        let future = Data(#"{"disabled":["ci_failures","telepathy"]}"#.utf8)
        #expect(try MergeCueCoding.storageDecoder().decode(NotificationPreferences.self, from: future) == NotificationPreferences(disabled: [.ciFailures]))
        #expect(try MergeCueCoding.storageDecoder().decode(NotificationPreferences.self, from: Data("{}".utf8)) == .allEnabled)
        #expect(prefs.setting(.ciFailures, enabled: true).disabled == [.agentResults, .approvals])
    }

    @Test func oneNotificationPerChangeRequest() throws {
        let cr = F.crKey()
        let busy = F.snapshot(
            cr,
            threads: [
                F.thread(F.threadKey(cr, "A"), comments: [F.comment("1", "Why a loop?")]),
                F.thread(F.threadKey(cr, "B"), comments: [F.comment("2", "Rename this")]),
            ],
            checks: [F.check(cr, id: "9", status: .failure)],
            reviews: [F.review("r1", .changesRequested)]
        )
        let other = F.crKey(number: 7)
        let quiet = F.snapshot(other, threads: [F.thread(F.threadKey(other), comments: [F.comment("3")])])
        let notifications = group(cycle([(F.snapshot(cr), busy), (F.snapshot(other), quiet)]))
        #expect(notifications.count == 2)
        let first = try #require(notifications.first)
        #expect(first.changeRequest == cr)
        #expect(first.threadIdentifier == cr.id)
        #expect(first.title == "acme/payments-api #42")
        #expect(first.subtitle == "GitHub · Add retries")
        #expect(first.attentionItemIDs.count == 4)
        #expect(first.isUrgent)
        let lines = first.body.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines.last == "+1 more")
        #expect(lines.first?.hasPrefix("CI failed:") == true || lines.first?.hasPrefix("Changes requested:") == true)
        #expect(first.webURL == busy.summary.webURL)
        #expect(first.id.hasPrefix("ntf_"))
        let second = notifications[1]
        #expect(!second.isUrgent)
        #expect(second.body == "Review comment: Sources/Retry.swift:12 Alice: Please add a backoff cap.")
        #expect(second.webURL?.absoluteString.contains("discussion_r3") == true, "single thread → deep link to the comment")
    }

    @Test func titlesCarryProviderNumbering() {
        let titles = [F.github, F.gitlab, F.bitbucket].map { account -> (String, String) in
            let cr = F.crKey(account)
            let current = F.snapshot(cr, threads: [F.thread(F.threadKey(cr), comments: [F.comment("1")])])
            let notification = group(cycle([(F.snapshot(cr), current)], account: account), account: account)[0]
            return (notification.title, notification.subtitle)
        }
        #expect(titles[0] == ("acme/payments-api #42", "GitHub · Add retries"))
        #expect(titles[1] == ("acme/payments-api !42", "GitLab · Add retries"))
        #expect(titles[2] == ("acme/payments-api #42", "Bitbucket Cloud · Add retries"))
    }

    @Test func baselineAndOwnEventsAreSilent() {
        let cr = F.crKey()
        let current = F.snapshot(cr, threads: [F.thread(F.threadKey(cr), comments: [F.comment("1")])])
        #expect(group(cycle([(nil, current)], baseline: true)).isEmpty)
        let own = F.snapshot(cr, threads: [F.thread(F.threadKey(cr), comments: [F.comment("1", by: F.mona, "note")])])
        #expect(group(cycle([(F.snapshot(cr), own)])).isEmpty)
    }

    @Test func resolvedDismissedAndSnoozedItemsAreSilent() {
        let cr = F.crKey()
        let current = F.snapshot(cr, threads: [F.thread(F.threadKey(cr), comments: [F.comment("1")])])
        let result = cycle([(F.snapshot(cr), current)])
        var stored = result.items[0]
        stored.disposition = .dismissed
        #expect(group(result, existing: [stored]).isEmpty)
        stored.disposition = .snoozed(until: F.at(500))
        #expect(group(result, existing: [stored]).isEmpty)
        stored.disposition = .snoozed(until: F.at(50))
        #expect(group(result, existing: [stored]).count == 1)
        stored.disposition = .acknowledged
        #expect(group(result, existing: [stored]).count == 1, "new activity reopens acknowledged items")
        stored.disposition = .resolved
        #expect(group(result, existing: [stored]).count == 1, "new activity reopens resolved items")
    }

    @Test func recoveryIsSilent() {
        let cr = F.crKey()
        let failing = F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure)])
        let existing = cycle([(F.snapshot(cr), failing)]).items
        let green = F.snapshot(cr, checks: [F.check(cr, id: "2", status: .success, at: 80)])
        let events = EventDeriver.derive(previous: failing, current: green, currentUserID: F.me, isBaseline: false, now: now)
        let items = AttentionDeriver.apply(events: events, snapshot: green, existing: existing, account: F.account(F.github), now: now)
        #expect(events.map(\.type) == [.ciRecovered])
        #expect(group(Cycle(events: events, items: items, snapshots: [cr: green]), existing: existing).isEmpty)
    }

    @Test func approvalOnMyCRIsInformational() throws {
        let cr = F.crKey()
        let approved = F.snapshot(cr, reviews: [F.review("r1", .approved)])
        let notification = try #require(group(cycle([(F.snapshot(cr), approved)])).first)
        #expect(notification.body == "Alice approved")
        #expect(notification.attentionItemIDs.isEmpty)
        #expect(!notification.isUrgent)
        // Approvals on someone else's CR are not announced.
        let theirs = F.snapshot(cr, author: F.alice, involvement: [.reviewRequested], reviews: [F.review("r1", by: F.bob, .approved)])
        let base = F.snapshot(cr, author: F.alice, involvement: [.reviewRequested])
        #expect(group(cycle([(base, theirs)])).isEmpty)
    }

    @Test func notificationIDsAreDeterministic() {
        let cr = F.crKey()
        let current = F.snapshot(cr, threads: [F.thread(F.threadKey(cr), comments: [F.comment("1")])])
        #expect(group(cycle([(F.snapshot(cr), current)]))[0].id == group(cycle([(F.snapshot(cr), current)]))[0].id)
    }

    @Test func policy() {
        let utc = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60, timeZoneID: "UTC")
        #expect(NotificationPolicy().allowsDelivery(at: now))
        #expect(!NotificationPolicy(pausedUntil: F.at(200)).allowsDelivery(at: now))
        #expect(NotificationPolicy(pausedUntil: F.at(50)).allowsDelivery(at: now))
        #expect(!NotificationPolicy(quietHours: utc).allowsDelivery(at: now), "00:01 UTC is inside 22:00–07:00")
        #expect(NotificationPolicy(quietHours: utc).allowsDelivery(at: F.at(12 * 3600)))
    }
}
