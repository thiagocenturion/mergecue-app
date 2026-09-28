import Foundation
import MergeCueCore
import MergeCueEngine
import MergeCueFixtures
import MergeCueIPC
import MergeCueRuntime
import Testing

/// Demo runtime over the three real adapters (fixture transports), a real SQLite database and the real Sync.
@Suite("Demo runtime scenario", .serialized)
struct DemoScenarioIntegrationTests {
    @Test func baselineThenNewActivityThenRelaunch() async throws {
        let h = try await DemoHarness.start()
        let home = h.home
        defer { home.remove() }

        // Baseline: every provider synced, items exist, nothing notified.
        let statuses = await h.runtime.sync.statuses()
        #expect(statuses.count == 3)
        for status in statuses {
            #expect(status.state == .ok, "\(status.account.kind): \(status.state) \(status.message ?? "")")
        }
        let baseline = try await h.items()
        for kind in ProviderKind.allCases {
            #expect(!baseline.filter { $0.changeRequest.kind == kind }.isEmpty, "no baseline items for \(kind)")
        }
        #expect(h.notifier.delivered.isEmpty)
        #expect(await h.engine.handle(method: .ping, params: .object([:]), client: .init(name: "t", version: "1", pid: 0)).isDemoPing)

        // #42 on three providers: three distinct change requests with distinct stable ids.
        let snapshots = try await h.engine.changeRequests()
        let pr42 = snapshots.filter { $0.key.number == 42 }
        #expect(pr42.count == 3)
        #expect(Set(pr42.map(\.key.id)).count == 3)
        #expect(Set(pr42.map(\.key.kind)) == Set(ProviderKind.allCases))
        for snapshot in pr42 {
            // Fixture SHAs were rewritten to the synthetic repository's head.
            #expect(snapshot.summary.headSHA.map { h.scenario.repository.headSHA.hasPrefix($0) } == true, "\(snapshot.key.kind) head \(snapshot.summary.headSHA ?? "nil")")
        }
        // Deep links resolve for every provider.
        for snapshot in pr42 {
            let provider = h.runtime.providers.makeProvider(
                account: DemoScenario.accounts.first { $0.id == snapshot.key.account }!,
                credential: DemoScenario.credentials[snapshot.key.account]!
            )
            #expect(provider.deepLink(to: .changeRequest(snapshot.key)) != nil, "\(snapshot.key.kind) deep link")
        }

        // Mappings to the synthetic checkout were created and confirmed.
        let mappings = try await h.engine.mappings()
        #expect(mappings.count == 3)
        #expect(mappings.filter { !$0.isConfirmed }.isEmpty)

        // Step 1: exactly one new review-comment item per provider (the blocking comment) and a failing CI item.
        await h.runtime.refresh()
        #expect(h.scenario.steps.values.allSatisfy { $0 == 1 })
        let afterStep1 = try await h.items()
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        for kind in ProviderKind.allCases {
            let mine = afterStep1.filter { $0.changeRequest.kind == kind }
            let new = mine.filter { baselineByID[$0.id] == nil }
            let changed = mine.filter { item in baselineByID[item.id].map { $0.eventIDs != item.eventIDs } ?? false }
            let newComments = new.filter { $0.thread != nil }
            #expect(newComments.count == 1, "\(kind): new thread items \(newComments.map { "\($0.reason) \($0.summary)" })")
            #expect(newComments.first?.changeRequest.number == 42)
            let ciItems = (new + changed).filter { $0.reason == .ciFailed }
            #expect(ciItems.count == 1, "\(kind): CI items \(ciItems.map(\.summary)) new=\(new.map(\.reason)) changed=\(changed.map(\.reason))")
            #expect(ciItems.filter { !$0.isUnread }.isEmpty)
        }
        // Notifications: one per change request (grouped), only for the three #42s.
        let notified = h.notifier.delivered
        #expect(notified.count == 3, "\(notified.map { "\($0.changeRequest.kind) \($0.title)" })")
        #expect(Set(notified.map(\.changeRequest)) == Set(pr42.map(\.key)))
        for notification in notified {
            #expect(notification.attentionItemIDs.count >= 2, "\(notification.changeRequest.kind): \(notification.attentionItemIDs)")
            #expect(notification.threadIdentifier == notification.changeRequest.id)
        }

        // Relaunch on the same directory: same state, no re-alert.
        await h.runtime.stop()
        let relaunched = try await DemoHarness.start(home: home)
        #expect(relaunched.scenario.steps.values.allSatisfy { $0 == 1 })
        let afterRelaunch = try await relaunched.items()
        #expect(Set(afterRelaunch.map(\.id)) == Set(afterStep1.map(\.id)))
        #expect(relaunched.notifier.delivered.isEmpty)
        #expect(try await relaunched.engine.mappings().count == 3)

        // Step 2: replies + CI recovery; CI items resolve.
        await relaunched.runtime.refresh()
        #expect(relaunched.scenario.steps.values.allSatisfy { $0 == 2 })
        let afterStep2 = try await relaunched.items()
        let openCI = afterStep2.filter { $0.reason == .ciFailed && $0.changeRequest.number == 42 && $0.disposition == .open }
        #expect(openCI.isEmpty, "open CI items after recovery: \(openCI.map { "\($0.changeRequest.kind) \($0.summary)" })")
        await relaunched.runtime.stop()
    }

    @Test func demoAccountsAreLabeledAndWritesStartDisabled() async throws {
        let h = try await DemoHarness.start()
        defer { h.home.remove() }
        let states = try await h.engine.accountStates()
        #expect(states.count == 3)
        #expect(states.allSatisfy { $0.account.isDemo && !$0.account.writesEnabled })
        #expect(h.runtime.isDemo)
        #expect(MergeCuePaths.fileSystemPath(h.runtime.dataPaths.root).hasSuffix("/demo"))
        // Account-specific manifests: every adapter's reply capability is usable with the demo tokens.
        for state in states {
            #expect(state.capabilities.isUsable(.createReply), "\(state.account.kind): \(state.capabilities.support(for: .createReply))")
        }
        await h.runtime.stop()
    }
}

extension Result<JSONValue, IPCError> {
    var isDemoPing: Bool {
        if case .success(let value) = self { return value["is_demo"]?.boolValue == true }
        return false
    }
}
