import Foundation
import MergeCueCore
import MergeCueStore
import Testing
@testable import MergeCueSync

/// End-to-end cycles through `SyncCoordinator` with fake providers, an in-memory database and a `TestClock`.
@Suite("SyncCoordinator scenarios")
struct SyncCoordinatorTests {
    typealias F = SyncFixture
    let cr = F.crKey()
    var t1: ThreadKey { F.threadKey(cr, "T1") }

    @Test func newCommentAcrossPollsAndRelaunchIsExactlyOnce() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(F.snapshot(cr))
        let first = await h.makeCoordinator()
        await h.start(first)
        #expect(try await h.database.hasCompletedInitialSync(account: F.github))
        #expect(h.notifier.delivered.isEmpty)
        #expect(try await h.items().isEmpty)

        let thread = t1
        remote.update(cr) { $0 = $0.touched(60); $0.threads = [F.thread(thread, comments: [F.comment("c1", "Why no cap?", at: 60)])] }
        await h.advance(90)
        await h.advance(90)
        await h.advance(90)
        await first.stop()

        // Relaunch: a new coordinator over the same database.
        let second = await h.makeCoordinator()
        await h.start(second)
        await h.advance(90)
        await second.stop()

        let events = try await h.events()
        #expect(events.map(\.type) == [.reviewComment])
        #expect(events[0].commentKind == .question)
        let items = try await h.items()
        #expect(items.count == 1)
        #expect(items[0].reason == .reviewerQuestion)
        #expect(items[0].eventIDs == [events[0].id])
        #expect(h.notifier.delivered.count == 1)
        #expect(h.notifier.delivered[0].attentionItemIDs == [items[0].id])
        #expect(h.handledEvents.values.flatMap { $0 }.map(\.id) == [events[0].id])
    }

    @Test func repliesStayInTheSameThreadItemAndReopenIt() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])]))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        let baseline = try #require(try await h.items().first)
        #expect(baseline.thread == t1)
        #expect(h.notifier.delivered.isEmpty)

        try await h.database.setAttentionDisposition(id: baseline.id, .acknowledged)
        try await h.database.setAttentionUnread(id: baseline.id, false)

        let thread = t1
        remote.update(cr) {
            $0 = $0.touched(120)
            $0.threads = [F.thread(thread, comments: [F.comment("c1"), F.comment("c2", by: F.bob, "Still needed?", at: 120, replyTo: "c1")])]
        }
        await h.advance(90)
        var items = try await h.items()
        #expect(items.count == 1)
        #expect(items[0].id == baseline.id)
        #expect(items[0].disposition == .open)
        #expect(items[0].isUnread)
        #expect(items[0].eventIDs.count == 2)

        remote.update(cr) {
            $0 = $0.touched(200)
            $0.threads[0].comments.append(F.comment("c3", by: F.alice, "Yes please", at: 200, replyTo: "c1"))
        }
        await h.advance(90)
        items = try await h.items()
        #expect(items.count == 1)
        #expect(items[0].eventIDs.count == 3)
        #expect(h.notifier.delivered.count == 2)
        #expect(Set(h.notifier.delivered.map(\.threadIdentifier)) == [cr.id])
        #expect(try await h.events().map(\.type) == [.reviewComment, .reply, .reply])
        await coordinator.stop()
    }

    @Test func samePRNumberOnThreeProvidersStaysSeparate() async throws {
        let accounts = [F.github, F.gitlab, F.bitbucket]
        let h = try await SyncHarness(accounts: accounts)
        for account in accounts { h.remote(account).put(F.snapshot(F.crKey(account))) }
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        for account in accounts {
            let key = F.crKey(account)
            let thread = F.threadKey(key)
            h.remote(account).update(key) { $0 = $0.touched(60); $0.threads = [F.thread(thread, comments: [F.comment("c1", at: 60)])] }
        }
        await h.advance(90)
        await coordinator.stop()

        let items = try await h.items()
        #expect(items.count == 3)
        #expect(Set(items.map(\.id)).count == 3)
        #expect(Set(items.map(\.providerKind)) == [.github, .gitlab, .bitbucketCloud])
        #expect(Set(items.map(\.number)) == [42])
        let notifications = h.notifier.delivered
        #expect(notifications.count == 3)
        #expect(Set(notifications.map(\.threadIdentifier)).count == 3)
        #expect(Set(notifications.map(\.title)) == ["acme/payments-api #42", "acme/payments-api !42"])
        #expect(Set(notifications.map(\.subtitle)) == ["GitHub · Add retries", "GitLab · Add retries", "Bitbucket Cloud · Add retries"])
        for account in accounts {
            #expect(try await h.events(F.crKey(account)).count == 1)
        }
    }

    @Test func ownReplyAndGreenRerunAreQuiet() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(F.snapshot(cr, threads: [F.thread(t1, comments: [F.comment("c1")])], checks: [F.check(cr, id: "1", status: .success)]))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        let before = try #require(try await h.items().first)

        remote.update(cr) { [cr] in
            $0 = $0.touched(120)
            $0.threads[0].comments.append(F.comment("c2", by: F.mona, "Fixed in abc", at: 110))
            $0.checks = [F.check(cr, id: "2", status: .success, at: 115)]
        }
        await h.advance(90)
        await coordinator.stop()

        #expect(h.notifier.delivered.isEmpty)
        let events = try await h.events()
        #expect(events.filter { !$0.isBaseline }.map(\.type) == [.reply])
        #expect(events.last?.isFromCurrentUser == true)
        let after = try await h.items()
        #expect(after == [before])
        #expect(h.handledEvents.values.flatMap { $0 }.map(\.isFromCurrentUser) == [true])
    }

    @Test func failedCheckRetriedSuccessfullyRecovers() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(F.snapshot(cr, checks: [F.check(cr, id: "1", status: .success)]))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)

        remote.update(cr) { [cr] in $0 = $0.touched(60); $0.checks = [F.check(cr, id: "2", status: .failure, at: 60, required: true)] }
        await h.advance(90)
        let failing = try #require(try await h.items().first)
        #expect(failing.reason == .ciFailed)
        #expect(failing.priority == .high)
        #expect(h.notifier.delivered.count == 1)
        #expect(h.notifier.delivered[0].isUrgent)

        // Re-run in progress (providers do not bump updated_at for CI): nothing yet, but pending checks re-hydrate.
        remote.update(cr) { [cr] in $0.checks = [F.check(cr, id: "3", status: .inProgress, at: 150)] }
        await h.advance(700) // beyond fullRefreshInterval, so the unchanged listing is re-hydrated
        #expect(try await h.items().first?.disposition == .open)
        remote.update(cr) { [cr] in $0.checks = [F.check(cr, id: "3", status: .success, at: 800)] }
        await h.advance(90)
        await coordinator.stop()

        let item = try #require(try await h.items().first)
        #expect(item.id == failing.id)
        #expect(item.disposition == .resolved)
        #expect(h.notifier.delivered.count == 1)
        let history = try await h.events().filter { !$0.isBaseline }.map(\.type)
        #expect(history == [.ciFailed, .ciRecovered])
        #expect(try await h.database.snapshot(cr)?.checks.first?.status == .success)
    }

    @Test func forcePushReportsHeadChangeAndOutdatedAnchors() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(F.snapshot(cr, headSHA: "aaaa1111", threads: [F.thread(t1, comments: [F.comment("c1")])]))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        let before = try #require(try await h.items().first)

        remote.update(cr) {
            $0 = $0.touched(60)
            $0.summary.headSHA = "bbbb2222"
            $0.commits = [CommitInfo(sha: "cccc3333", title: "rebased"), CommitInfo(sha: "bbbb2222", title: "rebased 2")]
            $0.threads[0].anchor?.isOutdated = true
        }
        await h.advance(90)
        await coordinator.stop()

        let head = try #require(try await h.events().first { $0.type == .headChanged })
        #expect(head.nativeRefs["force_push"] == "true")
        #expect(head.nativeRefs["outdated_threads"] == "1")
        #expect(head.isFromCurrentUser)
        let item = try #require(try await h.items().first)
        #expect(item.id == before.id)
        #expect(item.summary.hasPrefix("[outdated] "))
        #expect(item.updatedAt == before.updatedAt)
        #expect(h.notifier.delivered.isEmpty)
        let stored = try #require(try await h.database.snapshot(cr))
        #expect(stored.summary.headSHA == "bbbb2222")
        #expect(stored.threads[0].isOutdated)
    }

    @Test func mergedClosedAndDeletedChangeRequestsAreDetectedAndRemoved() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        let merged = F.crKey(number: 42), closed = F.crKey(number: 43), deleted = F.crKey(number: 44)
        remote.put(F.snapshot(merged, threads: [F.thread(F.threadKey(merged), comments: [F.comment("c1")])]))
        remote.put(F.snapshot(closed, checks: [F.check(closed, id: "1", status: .failure)]))
        remote.put(F.snapshot(deleted, author: F.alice, involvement: [.reviewRequested]))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        #expect(try await h.activeItems().count == 3)

        remote.update(merged) { $0 = $0.touched(60); $0.summary.state = .merged }
        remote.update(closed) { $0 = $0.touched(60); $0.summary.state = .closed }
        remote.delete(deleted)
        await h.advance(90)
        #expect(remote.hydrateCalls(merged) == 2)
        #expect(remote.hydrateCalls(deleted) == 2)
        await h.advance(90)
        await coordinator.stop()

        #expect(try await h.events(merged).last?.type == .merged)
        #expect(try await h.events(closed).last?.type == .closedWithoutMerge)
        #expect(try await h.activeItems().isEmpty)
        #expect(try await h.items().allSatisfy { $0.disposition == .resolved })
        #expect(try await h.database.snapshots(account: F.github).isEmpty)
        #expect(remote.hydrateCalls(merged) == 2, "departed CRs are hydrated exactly once")
        #expect(h.notifier.delivered.isEmpty)
    }

    @Test func baselineCreatesItemsWithoutNotifications() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        let reviewing = F.crKey(number: 50)
        remote.put(F.snapshot(
            cr,
            threads: [
                F.thread(F.threadKey(cr, "open"), comments: [F.comment("c1", "Why?")]),
                F.thread(F.threadKey(cr, "done"), comments: [F.comment("c2")], resolved: true),
                F.thread(F.threadKey(cr, "answered"), comments: [F.comment("c3"), F.comment("c4", by: F.mona, "ok", at: 20)]),
            ],
            checks: [F.check(cr, id: "1", status: .failure), F.check(cr, id: "2", name: "lint", status: .success)]
        ))
        remote.put(F.snapshot(reviewing, author: F.alice, involvement: [.reviewRequested]))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        await h.advance(90)
        await coordinator.stop()

        let reasons = try await h.items().map(\.reason)
        #expect(Set(reasons) == [.reviewerQuestion, .ciFailed, .reviewRequested])
        #expect(reasons.count == 3)
        #expect(h.notifier.delivered.isEmpty)
        #expect(h.handledEvents.values.isEmpty)
        let events = try await h.database.recentEvents(limit: 100)
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.isBaseline })
    }

    @Test func concurrentChangesOnOneChangeRequestGiveOneNotification() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        let other = F.crKey(number: 7)
        remote.put(F.snapshot(cr))
        remote.put(F.snapshot(other))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        let thread = t1
        remote.update(cr) { [cr] in
            $0 = $0.touched(60)
            $0.threads = [F.thread(thread, comments: [F.comment("c1", "```suggestion\nlet cap = 5\n```", at: 50)])]
            $0.checks = [F.check(cr, id: "9", status: .failure, at: 55)]
            $0.reviews = [F.review("r1", .changesRequested, at: 58)]
        }
        remote.update(other) { $0 = $0.touched(60); $0.threads = [F.thread(F.threadKey(other), comments: [F.comment("x1", at: 59)])] }
        await h.advance(90)
        await coordinator.stop()

        let notifications = h.notifier.delivered
        #expect(notifications.count == 2)
        let main = try #require(notifications.first { $0.changeRequest == cr })
        #expect(main.attentionItemIDs.count == 3)
        #expect(main.isUrgent)
        #expect(main.body.split(separator: "\n").count == 3)
        #expect(main.body.contains("Code suggestion"))
        #expect(try await h.items().count == 4)
    }

    @Test func quietHoursAndPauseSuppressNotificationsOnly() async throws {
        let h = try await SyncHarness()
        let remote = h.remote()
        remote.put(F.snapshot(cr))
        var configuration = SyncConfiguration.deterministic
        configuration.quietHours = QuietHours(startMinute: 23 * 60, endMinute: 7 * 60, timeZoneID: "UTC")
        let coordinator = await h.makeCoordinator(configuration: configuration)
        await h.start(coordinator)
        let thread = t1
        remote.update(cr) { $0 = $0.touched(60); $0.threads = [F.thread(thread, comments: [F.comment("c1", at: 60)])] }
        await h.advance(90)
        #expect(h.notifier.delivered.isEmpty)
        #expect(try await h.items().count == 1)
        #expect(h.handledEvents.values.count == 1, "rules still see events during quiet hours")

        // Outside quiet hours but explicitly paused.
        configuration.quietHours = nil
        await coordinator.updateConfiguration(configuration)
        await coordinator.setNotificationsPaused(until: h.clock.now.addingTimeInterval(150))
        #expect(await coordinator.notificationsPausedUntil() != nil)
        remote.update(cr) { $0 = $0.touched(200); $0.threads[0].comments.append(F.comment("c2", by: F.bob, "ping", at: 200)) }
        await h.advance(90)
        #expect(h.notifier.delivered.isEmpty)

        remote.update(cr) { $0 = $0.touched(400); $0.threads[0].comments.append(F.comment("c3", by: F.bob, "ping again", at: 400)) }
        await h.advance(90)
        await coordinator.stop()
        #expect(h.notifier.delivered.count == 1)
        #expect(h.notifier.delivered[0].body.contains("ping again"))
    }

    @Test func changeSignalsAreEmitted() async throws {
        let h = try await SyncHarness()
        h.remote().put(F.snapshot(cr, checks: [F.check(cr, id: "1", status: .failure)]))
        let coordinator = await h.makeCoordinator()
        await h.start(coordinator)
        await coordinator.stop()
        let signals = Set(h.changes.values)
        #expect(signals.isSuperset(of: [.syncStatus, .changeRequests, .attention]))
    }
}
