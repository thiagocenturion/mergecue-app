import Foundation
import MergeCueCore
import Testing

/// D57: Notification Center keeps one alert per thing that needs the user.
@Suite("Notification hygiene")
struct NotificationHygieneTests {
    let pr = Fixture.changeRequestKey()

    func sent(_ id: String, items: [String] = [], topics: [String] = []) -> GroupedNotification {
        GroupedNotification(id: id, title: "t", subtitle: "s", body: "b", changeRequest: pr, attentionItemIDs: items, topics: topics)
    }

    func shown(_ notification: GroupedNotification, changeRequestID: String? = nil) -> DeliveredNotification {
        DeliveredNotification(id: notification.id, changeRequestID: changeRequestID ?? notification.changeRequest.id,
                              attentionItemIDs: notification.attentionItemIDs, topics: notification.topics)
    }

    @Test func aRepeatReplacesTheOlderAlert() {
        let first = shown(sent("n1", items: ["reapproval"]))
        let both = shown(sent("n2", items: ["reapproval", "thread"]))
        let other = shown(sent("n3", items: ["ci"]))
        let elsewhere = shown(sent("n4", items: ["reapproval"]), changeRequestID: "another")
        let replaced = NotificationHygiene.superseded(by: sent("n5", items: ["reapproval"]), delivered: [first, both, other, elsewhere])
        #expect(replaced == ["n1"], "only alerts fully repeated by the new one, on the same PR")
    }

    @Test func newsIsReplacedOnlyByTheSameNews() {
        let approved = shown(sent("a1", topics: ["event:approval"]))
        #expect(NotificationHygiene.superseded(by: sent("a2", topics: ["event:approval"]), delivered: [approved]) == ["a1"])
        #expect(NotificationHygiene.superseded(by: sent("c1", items: ["thread"]), delivered: [approved]).isEmpty)
    }

    @Test func alertsLeaveOnceNothingInThemNeedsYou() {
        let single = shown(sent("n1", items: ["reapproval"]))
        let pair = shown(sent("n2", items: ["reapproval", "thread"]))
        let news = shown(sent("n3", items: ["reapproval"], topics: ["event:approval"]))
        let task = shown(sent("n4", items: ["reapproval"], topics: ["task:mc_1"]))
        #expect(NotificationHygiene.stale(changeRequestID: pr.id, actionable: ["thread"], delivered: [single, pair, news, task]) == ["n1"])
        #expect(Set(NotificationHygiene.stale(changeRequestID: pr.id, actionable: [], delivered: [single, pair, news, task])) == ["n1", "n2"])
        #expect(NotificationHygiene.stale(changeRequestID: "another", actionable: [], delivered: [single]).isEmpty)
    }
}
