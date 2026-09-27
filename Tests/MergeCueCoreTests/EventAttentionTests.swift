import Foundation
import MergeCueCore
import Testing

@Suite("Events and attention")
struct EventAttentionTests {
    @Test func eventIDIsStableAndSensitiveToEveryComponent() {
        let key = Fixture.changeRequestKey()
        let base = ChangeEvent.makeID(account: Fixture.githubAccount, changeRequest: key, type: .reviewComment, objectID: "c1", objectVersion: "1")
        #expect(base == ChangeEvent.makeID(account: Fixture.githubAccount, changeRequest: key, type: .reviewComment, objectID: "c1", objectVersion: "1"))
        #expect(base.hasPrefix("evt_"))
        #expect(base.count == 4 + 32)

        let variants = [
            ChangeEvent.makeID(account: Fixture.gitlabAccount, changeRequest: key, type: .reviewComment, objectID: "c1", objectVersion: "1"),
            ChangeEvent.makeID(account: Fixture.githubAccount, changeRequest: Fixture.changeRequestKey(remoteID: "790"), type: .reviewComment, objectID: "c1", objectVersion: "1"),
            ChangeEvent.makeID(account: Fixture.githubAccount, changeRequest: key, type: .reply, objectID: "c1", objectVersion: "1"),
            ChangeEvent.makeID(account: Fixture.githubAccount, changeRequest: key, type: .reviewComment, objectID: "c2", objectVersion: "1"),
            ChangeEvent.makeID(account: Fixture.githubAccount, changeRequest: key, type: .reviewComment, objectID: "c1", objectVersion: "2"),
            // Separator injection must not collide.
            ChangeEvent.makeID(account: Fixture.githubAccount, changeRequest: key, type: .reviewComment, objectID: "c1\n1", objectVersion: ""),
        ]
        #expect(Set(variants + [base]).count == variants.count + 1)
    }

    @Test func eventInitDerivesIdentityFields() throws {
        let event = Fixture.event(type: .ciFailed, account: Fixture.gitlabAccount)
        #expect(event.id == ChangeEvent.makeID(account: Fixture.gitlabAccount, changeRequest: event.changeRequest, type: .ciFailed, objectID: "c1", objectVersion: "1"))
        #expect(event.providerKind == .gitlab)
        #expect(event.number == 42)
        #expect(event.changeRequestRef.string == "gitlab:gitlab.com/acme/payments-api!42")
        #expect(try Fixture.roundTrip(event) == event)
    }

    /// Account, provider kind and number are derived from the change request key and follow it when it changes,
    /// so a GitLab key can never be labelled as a GitHub event (or vice versa).
    @Test func derivedIdentityFieldsFollowTheChangeRequest() throws {
        var event = Fixture.event(account: Fixture.githubAccount)
        let gitlabKey = Fixture.changeRequestKey(Fixture.gitlabAccount, number: 7)
        event.changeRequest = gitlabKey
        #expect(event.account == Fixture.gitlabAccount)
        #expect(event.providerKind == .gitlab)
        #expect(event.number == 7)
        #expect(event.changeRequestRef.string == "gitlab:gitlab.com/acme/payments-api!7")

        var item = AttentionItem(
            dedupeKey: "att:reason/x", changeRequest: Fixture.changeRequestKey(), repoFullPath: "acme/payments-api",
            title: "t", reason: .readyToMerge, summary: "s", createdAt: Fixture.date, updatedAt: Fixture.date
        )
        #expect(item.providerKind == .github)
        item.changeRequest = Fixture.changeRequestKey(Fixture.bitbucketAccount, number: 9)
        #expect(item.account == Fixture.bitbucketAccount)
        #expect(item.providerKind == .bitbucketCloud)
        #expect(item.number == 9)
        #expect(try Fixture.roundTrip(item) == item)

        // TaskOrigin takes only the repository path from the supplied ref.
        let mismatched = try #require(ChangeRequestRef(string: "github:github.com/acme/payments-api#1"))
        var origin = TaskOrigin(
            changeRequest: gitlabKey, changeRequestRef: mismatched, title: "t",
            webURL: URL(string: "https://gitlab.com/acme/payments-api/-/merge_requests/7")!
        )
        #expect(origin.account == Fixture.gitlabAccount)
        #expect(origin.providerKind == .gitlab)
        #expect(origin.changeRequestRef.string == "gitlab:gitlab.com/acme/payments-api!7")
        origin.changeRequest = Fixture.changeRequestKey(Fixture.githubAccount, number: 3)
        #expect(origin.changeRequestRef.string == "github:github.com/acme/payments-api#3")
        #expect(origin.providerKind == .github)
        #expect(try Fixture.roundTrip(origin) == origin)
    }

    @Test func sameNumberOnDifferentProvidersProducesDifferentEvents() {
        let ids = [Fixture.githubAccount, Fixture.gitlabAccount, Fixture.bitbucketAccount].map { Fixture.event(account: $0).id }
        #expect(Set(ids).count == 3)
    }

    @Test func eventTypeRawValues() {
        #expect(ChangeEventType.allCases.count == 12)
        #expect(ChangeEventType.closedWithoutMerge.rawValue == "closed_without_merge")
        #expect(ChangeEventType.ciRecovered.rawValue == "ci_recovered")
        #expect(ChangeEventType.headChanged.rawValue == "head_changed")
    }

    @Test func dispositionHasStableJSON() throws {
        #expect(try Fixture.json(AttentionDisposition.open) == #"{"type":"open"}"#)
        #expect(try Fixture.json(AttentionDisposition.acknowledged) == #"{"type":"acknowledged"}"#)
        #expect(try Fixture.json(AttentionDisposition.resolved) == #"{"type":"resolved"}"#)
        #expect(try Fixture.json(AttentionDisposition.dismissed) == #"{"type":"dismissed"}"#)
        #expect(try Fixture.json(AttentionDisposition.snoozed(until: Fixture.date)) == #"{"type":"snoozed","until":"2026-01-01T00:00:00Z"}"#)
        let all: [AttentionDisposition] = [.open, .acknowledged, .snoozed(until: Fixture.date), .resolved, .dismissed]
        for value in all {
            #expect(try Fixture.roundTrip(value) == value)
        }
        #expect(throws: DecodingError.self) { try Fixture.decode(AttentionDisposition.self, from: #"{"type":"snoozed"}"#) }
    }

    @Test func actionability() {
        let now = Fixture.date
        #expect(AttentionDisposition.open.isActionable(now: now))
        #expect(!AttentionDisposition.acknowledged.isActionable(now: now))
        #expect(!AttentionDisposition.resolved.isActionable(now: now))
        #expect(!AttentionDisposition.dismissed.isActionable(now: now))
        #expect(!AttentionDisposition.snoozed(until: now.addingTimeInterval(60)).isActionable(now: now))
        #expect(AttentionDisposition.snoozed(until: now).isActionable(now: now))
        #expect(AttentionDisposition.snoozed(until: now.addingTimeInterval(-1)).isActionable(now: now))
    }

    @Test func attentionItemIdentity() throws {
        let key = Fixture.changeRequestKey()
        let thread = ThreadKey(changeRequest: key, remoteID: "PRRT_1", kind: .diffThread)
        let dedupe = AttentionItem.dedupeKey(thread: thread)
        let item = AttentionItem(
            dedupeKey: dedupe,
            changeRequest: key,
            repoFullPath: "acme/payments-api",
            title: "Add retries",
            reason: .changesRequested,
            summary: "Please add a test",
            thread: thread,
            createdAt: Fixture.date,
            updatedAt: Fixture.date
        )
        #expect(item.id == ShortID.make(prefix: "att_", from: dedupe))
        #expect(ShortID.isValid(item.id, prefix: "att_"))
        #expect(item.priority == .high)
        #expect(item.isUnread)
        #expect(item.disposition == .open)
        #expect(item.suggestedActions.contains(.fixWithAI))
        #expect(item.isActionable(now: Fixture.date))
        #expect(item.changeRequestRef.string == "github:github.com/acme/payments-api#42")
        #expect(try Fixture.roundTrip(item) == item)

        var linked = item
        linked.linkedTaskID = TaskID(rawValue: "mc_abc123")
        #expect(try Fixture.roundTrip(linked).linkedTaskID?.rawValue == "mc_abc123")
    }

    @Test func dedupeKeysSeparateThreadsChecksAndReasons() {
        let key = Fixture.changeRequestKey()
        let otherProvider = Fixture.changeRequestKey(Fixture.gitlabAccount)
        let keys = [
            AttentionItem.dedupeKey(thread: ThreadKey(changeRequest: key, remoteID: "1", kind: .diffThread)),
            AttentionItem.dedupeKey(thread: ThreadKey(changeRequest: key, remoteID: "1", kind: .conversation)),
            AttentionItem.dedupeKey(changeRequest: key, checkName: "build"),
            AttentionItem.dedupeKey(changeRequest: key, checkName: "build/linux"),
            AttentionItem.dedupeKey(changeRequest: otherProvider, checkName: "build"),
            AttentionItem.dedupeKey(changeRequest: key, reason: .reviewRequested),
            AttentionItem.dedupeKey(changeRequest: key, reason: .readyToMerge),
        ]
        #expect(Set(keys).count == keys.count)
        #expect(AttentionItem.dedupeKey(changeRequest: key, checkName: "build") == AttentionItem.dedupeKey(changeRequest: key, checkName: "build"))
    }

    @Test func priorityOrdering() {
        #expect(AttentionPriority.low < .normal)
        #expect(AttentionPriority.normal < .high)
        #expect(AttentionPriority.high < .urgent)
        #expect([AttentionPriority.urgent, .low, .high].sorted() == [.low, .high, .urgent])
    }

    @Test func taskTypeInference() {
        #expect(TaskType.inferred(from: .ciFailed) == .investigateCI)
        #expect(TaskType.inferred(from: .changesRequested) == .fixReview)
        #expect(TaskType.inferred(from: .reviewComment) == .fixReview)
        #expect(TaskType.inferred(from: .codeSuggestion) == .addressSuggestion)
        #expect(TaskType.inferred(from: .reviewerQuestion) == .draftReply)
        #expect(TaskType.inferred(from: .reviewRequested) == nil)
        #expect(TaskType.inferred(from: .readyToMerge) == nil)
        #expect(!TaskType.draftReply.isCodeTask)
        #expect(TaskType.fixReview.isCodeTask)
    }

    @Test func suggestedActionsMatchReasons() {
        #expect(AttentionReason.ciFailed.defaultSuggestedActions.first == .investigateWithAI)
        #expect(AttentionReason.codeSuggestion.defaultSuggestedActions.first == .addressWithAI)
        #expect(AttentionReason.reviewerQuestion.defaultSuggestedActions.first == .draftReply)
        for reason in AttentionReason.allCases {
            #expect(reason.defaultSuggestedActions.contains(.openInProvider))
        }
    }
}
