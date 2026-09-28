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

    func group(_ cycle: Cycle, existing: [AttentionItem] = [], account: AccountKey = F.github) -> [GroupedNotification] {
        NotificationGrouper.group(
            newEvents: cycle.events, attentionUpserts: cycle.items,
            existing: Dictionary(uniqueKeysWithValues: existing.map { ($0.dedupeKey, $0) }),
            snapshots: cycle.snapshots, account: F.account(account), now: now
        )
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

    // MARK: Scheduling

    @Test func successIntervals() {
        var config = SyncConfiguration.deterministic
        #expect(SyncSchedule.nextDelay(state: .ok, consecutiveFailures: 0, now: now, isHot: false, configuration: config) == 90)
        #expect(SyncSchedule.nextDelay(state: .ok, consecutiveFailures: 0, now: now, isHot: true, configuration: config) == 45)
        config.idleHours = QuietHours(startMinute: 0, endMinute: 7 * 60, timeZoneID: "UTC")
        #expect(SyncSchedule.nextDelay(state: .ok, consecutiveFailures: 0, now: now, isHot: false, configuration: config) == 300)
        #expect(SyncSchedule.nextDelay(state: .ok, consecutiveFailures: 0, now: now, isHot: true, configuration: config) == 45)
        #expect(SyncSchedule.nextDelay(state: .ok, consecutiveFailures: 0, now: F.at(12 * 3600), isHot: false, configuration: config) == 90)
    }

    @Test func backoffIsExponentialAndCapped() {
        let config = SyncConfiguration.deterministic
        let delays = (1...8).map {
            SyncSchedule.nextDelay(state: .offline, consecutiveFailures: $0, now: now, isHot: false, configuration: config)
        }
        #expect(delays == [30, 60, 120, 240, 480, 900, 900, 900])
        #expect(SyncSchedule.nextDelay(state: .error("x"), consecutiveFailures: 100, now: now, isHot: false, configuration: config) == 900)
        #expect(SyncSchedule.nextDelay(state: .permissionDenied("x"), consecutiveFailures: 1, now: now, isHot: false, configuration: config) == 30)
    }

    @Test func rateLimitWaitsForResetAndAuthStops() {
        let config = SyncConfiguration.deterministic
        #expect(SyncSchedule.nextDelay(state: .rateLimited(until: F.at(1300)), consecutiveFailures: 1, now: now, isHot: false, configuration: config) == 1200)
        #expect(SyncSchedule.nextDelay(state: .rateLimited(until: nil), consecutiveFailures: 2, now: now, isHot: false, configuration: config) == 60)
        #expect(SyncSchedule.nextDelay(state: .rateLimited(until: F.at(0)), consecutiveFailures: 1, now: now, isHot: false, configuration: config) == 1)
        #expect(SyncSchedule.nextDelay(state: .authExpired, consecutiveFailures: 1, now: now, isHot: false, configuration: config) == nil)
        #expect(SyncSchedule.nextDelay(state: .paused, consecutiveFailures: 0, now: now, isHot: false, configuration: config) == nil)
    }

    @Test func jitterStaysInBounds() {
        var config = SyncConfiguration.deterministic
        config.jitterFraction = 0.1
        let low = SyncSchedule.nextDelay(state: .ok, consecutiveFailures: 0, now: now, isHot: false, configuration: config, jitterSample: 0)
        let high = SyncSchedule.nextDelay(state: .ok, consecutiveFailures: 0, now: now, isHot: false, configuration: config, jitterSample: 0.999)
        #expect(low == 81)
        #expect((high ?? 0) < 99 && (high ?? 0) > 98.9)
        // Rate limits are never retried early.
        let limited = SyncSchedule.nextDelay(state: .rateLimited(until: F.at(700)), consecutiveFailures: 1, now: now, isHot: false, configuration: config, jitterSample: 0)
        #expect(limited == 600)
        #expect(SyncConfiguration.default.defaultInterval == 90)
        #expect(SyncConfiguration.default.hotInterval == 45)
        #expect(SyncConfiguration.default.idleInterval == 300)
        #expect(SyncConfiguration.default.backoffCap == 900)
        #expect(SyncConfiguration.default.hydrateConcurrency == 4)
    }
}
