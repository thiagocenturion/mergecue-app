import Foundation
import MergeCueCore
import Testing

@Suite("MergeCueCoding")
struct CodingTests {
    /// A GitLab-style millisecond timestamp and a wall-clock `Date()`-like value with sub-microsecond bits.
    static let millisecondDate = Date(timeIntervalSince1970: 1_767_225_600.123)
    static let wallClockDate = Date(timeIntervalSinceReferenceDate: 812_237_010.867_745_3)
    /// A second millisecond timestamp written as a decimal (wire round trips are exact for dates parsed from
    /// millisecond text, not for arbitrary sums such as `date + 0.001`).
    static let laterMillisecondDate = Date(timeIntervalSince1970: 1_767_229_200.124)

    private static func task(at date: Date, later: Date) throws -> MCTask {
        let key = Fixture.changeRequestKey(Fixture.gitlabAccount)
        let taskID = try #require(TaskID(rawValue: "mc_sub5ec"))
        return MCTask(
            id: taskID,
            type: .fixReview,
            createdAt: date,
            updatedAt: later,
            origin: TaskOrigin(
                changeRequest: key,
                changeRequestRef: Fixture.summary(key).ref,
                title: "Add retries",
                webURL: URL(string: "https://gitlab.com/acme/payments-api/-/merge_requests/42")!
            ),
            trigger: TaskTriggerSnapshot(
                capturedAt: date,
                sourceBranch: "feature",
                targetBranch: "main",
                quoted: [UntrustedText(source: UntrustedText.Source.reviewComment, author: "alice", createdAt: date, text: "Please fix")]
            ),
            lease: AgentLease(agentName: "codex", leaseID: "lease_1", claimedAt: date, heartbeatAt: date, expiresAt: later),
            lastError: TaskErrorInfo(code: "timeout", message: "The request timed out.", retryable: true, at: date)
        )
    }

    private static func snapshot(at date: Date, later: Date) -> ChangeRequestSnapshot {
        let key = Fixture.changeRequestKey(Fixture.gitlabAccount)
        var summary = Fixture.summary(key)
        summary.createdAt = date
        summary.updatedAt = later
        summary.involvement = [.authored, .mentioned, .participated]
        return ChangeRequestSnapshot(
            summary: summary,
            reviews: [Review(remoteID: "r1", author: Fixture.person(), state: .approved, submittedAt: date)],
            threads: [ReviewThread(
                key: ThreadKey(changeRequest: key, remoteID: "d1", kind: .diffThread),
                isResolved: false,
                isResolvable: true,
                comments: [ReviewComment(id: "n1", author: Fixture.person(), body: "Why?", createdAt: date, updatedAt: later, kind: .question)],
                lastActivityAt: date
            )],
            commits: [CommitInfo(sha: "abc", title: "Initial", authoredAt: date)],
            fetchedAt: date
        )
    }

    private static func attention(at date: Date, later: Date) -> AttentionItem {
        let key = Fixture.changeRequestKey(Fixture.bitbucketAccount)
        return AttentionItem(
            dedupeKey: AttentionItem.dedupeKey(changeRequest: key, reason: .readyToMerge),
            changeRequest: key,
            repoFullPath: "acme/payments-api",
            title: "Add retries",
            reason: .readyToMerge,
            summary: "Ready",
            createdAt: date,
            updatedAt: date,
            disposition: .snoozed(until: later)
        )
    }

    private static func storageRoundTrip<T: Codable>(_ value: T) throws -> T {
        try MergeCueCoding.storageDecoder().decode(T.self, from: MergeCueCoding.storageEncoder().encode(value))
    }

    private static func wireRoundTrip<T: Codable>(_ value: T) throws -> T {
        try MergeCueCoding.wireDecoder().decode(T.self, from: MergeCueCoding.wireEncoder().encode(value))
    }

    // MARK: Storage is lossless

    @Test(arguments: [CodingTests.millisecondDate, CodingTests.wallClockDate])
    func storageRoundTripIsExact(_ date: Date) throws {
        // Arbitrary sums are fine for storage: the exact Double is written.
        let later = date.addingTimeInterval(600.000_123_4)
        let task = try Self.task(at: date, later: later)
        #expect(try Self.storageRoundTrip(task) == task)
        let snapshot = Self.snapshot(at: date, later: later)
        #expect(try Self.storageRoundTrip(snapshot) == snapshot)
        let item = Self.attention(at: date, later: later)
        #expect(try Self.storageRoundTrip(item) == item)
    }

    @Test func storageDatesSurviveManyValues() throws {
        var generator = SplitMix64(state: 11)
        for _ in 0..<2_000 {
            let seconds = Double(generator.next() % 2_000_000_000) + Double(generator.next() % 1_000_000) / 1_000_000.0
            let date = Date(timeIntervalSinceReferenceDate: seconds)
            #expect(try Self.storageRoundTrip([date]) == [date])
        }
    }

    // MARK: Wire keeps milliseconds

    @Test func wireRoundTripKeepsMillisecondDates() throws {
        let date = Self.millisecondDate
        let later = Self.laterMillisecondDate
        let task = try Self.task(at: date, later: later)
        #expect(try Self.wireRoundTrip(task) == task)
        let snapshot = Self.snapshot(at: date, later: later)
        #expect(try Self.wireRoundTrip(snapshot) == snapshot)
        let item = Self.attention(at: date, later: later)
        #expect(try Self.wireRoundTrip(item) == item)
        // Through JSONValue (the IPC params/result path) too.
        #expect(try JSONValue(encoding: task).decode(MCTask.self) == task)
    }

    /// Every millisecond timestamp (as parsed from provider text) survives a wire round trip exactly.
    @Test func wireIsExactForMillisecondTimestamps() throws {
        var generator = SplitMix64(state: 23)
        for _ in 0..<2_000 {
            let seconds = generator.next() % 4_000_000_000
            let millis = generator.next() % 1_000
            let text = "\(seconds)." + String(repeating: "0", count: 3 - String(millis).count) + String(millis)
            let date = Date(timeIntervalSince1970: try #require(Double(text)))
            #expect(try Self.wireRoundTrip([date]) == [date], "\(text)")
            let formatted = try #require(MergeCueCoding.formatWireDate(date))
            #expect(MergeCueCoding.parseWireDate(formatted) == date)
        }
    }

    @Test func wireRoundsFinerPrecisionToTheMillisecond() throws {
        let decoded = try Self.wireRoundTrip([Self.wallClockDate])
        #expect(abs(decoded[0].timeIntervalSince(Self.wallClockDate)) <= 0.0005)
    }

    @Test(arguments: [
        (1_767_225_600.0, "2026-01-01T00:00:00Z"),
        (1_767_225_600.123, "2026-01-01T00:00:00.123Z"),
        (1_767_225_600.1, "2026-01-01T00:00:00.100Z"),
        (1_767_225_600.007, "2026-01-01T00:00:00.007Z"),
        (1_767_225_600.9996, "2026-01-01T00:00:01Z"),
        (-0.5, "1969-12-31T23:59:59.500Z"),
    ])
    func wireDateFormat(_ seconds: Double, expected: String) throws {
        #expect(MergeCueCoding.formatWireDate(Date(timeIntervalSince1970: seconds)) == expected)
        let json = String(decoding: try MergeCueCoding.wireEncoder().encode([Date(timeIntervalSince1970: seconds)]), as: UTF8.self)
        #expect(json == "[\"\(expected)\"]")
    }

    @Test(arguments: [
        ("2026-01-01T00:00:00Z", 1_767_225_600.0),
        ("2026-01-01T00:00:00.123Z", 1_767_225_600.123),
        ("2026-01-01T00:00:00.1Z", 1_767_225_600.1),
        ("2026-01-01T00:00:00.123456Z", 1_767_225_600.123456),
        ("2026-01-01T00:00:00.123456789Z", 1_767_225_600.123456789),
        ("2026-01-01T01:00:00+01:00", 1_767_225_600.0),
        ("2026-01-01T01:00:00.250+01:00", 1_767_225_600.25),
        ("1969-12-31T23:59:59.500Z", -0.5),
    ])
    func wireDateParsing(_ text: String, expected: Double) throws {
        let date = try #require(MergeCueCoding.parseWireDate(text))
        #expect(date == Date(timeIntervalSince1970: expected))
        let decoded = try MergeCueCoding.wireDecoder().decode([Date].self, from: Data("[\"\(text)\"]".utf8))
        #expect(decoded == [Date(timeIntervalSince1970: expected)])
    }

    @Test(arguments: ["", "2026-01-01", "2026-01-01 00:00:00Z", "2026-01-01T00:00:00.Z", "2026-01-01T00:00:00.12", "yesterday", "1767225600"])
    func wireRejectsMalformedDates(_ text: String) {
        #expect(MergeCueCoding.parseWireDate(text) == nil)
        #expect(throws: DecodingError.self) {
            try MergeCueCoding.wireDecoder().decode([Date].self, from: Data("[\"\(text)\"]".utf8))
        }
    }

    @Test func nonFiniteDatesDoNotEncodeOnTheWire() {
        #expect(MergeCueCoding.formatWireDate(Date(timeIntervalSince1970: .infinity)) == nil)
        #expect(throws: EncodingError.self) {
            try MergeCueCoding.wireEncoder().encode([Date(timeIntervalSince1970: .nan)])
        }
    }

    @Test func jsonValueDefaultsAreTheWireCoders() throws {
        let json = try JSONValue(encoding: ["at": Self.millisecondDate])
        #expect(json["at"]?.stringValue == "2026-01-01T00:00:00.123Z")
        #expect(try json.decode([String: Date].self) == ["at": Self.millisecondDate])
    }

    // MARK: Deterministic bytes

    private static func strings(_ value: JSONValue?) -> [String]? {
        value?.arrayValue?.compactMap { $0.stringValue }
    }

    private func rule(providerKinds: [ProviderKind], accounts: [AccountKey], eventTypes: [ChangeEventType], involvement: [Involvement], commentKinds: [CommentKind]) -> Rule {
        var rule = Rule(id: "rule_1", name: "Sets", origin: .agentProposal, action: .notify, createdAt: Fixture.date)
        // Insert one by one in the given order (insertion history can change Set iteration order).
        for kind in providerKinds { rule.providerKinds.insert(kind) }
        for account in accounts { rule.accounts.insert(account) }
        for type in eventTypes { rule.eventTypes.insert(type) }
        for value in involvement { rule.involvement.insert(value) }
        for kind in commentKinds { rule.commentKinds.insert(kind) }
        return rule
    }

    @Test func setsEncodeAsSortedArraysRegardlessOfInsertionOrder() throws {
        let accounts = [Fixture.githubAccount, Fixture.gitlabAccount, Fixture.bitbucketAccount]
        let forward = rule(
            providerKinds: ProviderKind.allCases, accounts: accounts, eventTypes: ChangeEventType.allCases,
            involvement: Involvement.allCases, commentKinds: CommentKind.allCases
        )
        let backward = rule(
            providerKinds: ProviderKind.allCases.reversed(), accounts: accounts.reversed(), eventTypes: ChangeEventType.allCases.reversed(),
            involvement: Involvement.allCases.reversed(), commentKinds: CommentKind.allCases.reversed()
        )
        #expect(forward == backward)
        for encoder in [MergeCueCoding.storageEncoder(), MergeCueCoding.wireEncoder()] {
            #expect(try encoder.encode(forward) == encoder.encode(backward))
        }
        #expect(try MergeCueCoding.digest(forward) == MergeCueCoding.digest(backward))

        let json = try JSONValue(encoding: forward)
        let eventTypes = try #require(Self.strings(json["eventTypes"]))
        #expect(eventTypes == ChangeEventType.allCases.map(\.rawValue).sorted())
        let kinds = try #require(Self.strings(json["providerKinds"]))
        #expect(kinds == ["bitbucket_cloud", "github", "gitlab"])
        let accountIDs = try #require(json["accounts"]?.arrayValue).compactMap { value -> String? in
            guard let kind = value["kind"]?.stringValue, let host = value["host"]?.stringValue,
                  let user = value["remoteUserID"]?.stringValue, let parsed = ProviderKind(rawValue: kind)
            else { return nil }
            return AccountKey(kind: parsed, host: host, remoteUserID: user).id
        }
        #expect(accountIDs == accounts.map(\.id).sorted())
        #expect(try Fixture.roundTrip(forward) == forward)
    }

    @Test func summaryInvolvementEncodesSorted() throws {
        var a = Fixture.summary()
        a.involvement = []
        for value in Involvement.allCases { a.involvement.insert(value) }
        var b = a
        b.involvement = []
        for value in Involvement.allCases.reversed() { b.involvement.insert(value) }
        #expect(try MergeCueCoding.storageEncoder().encode(a) == MergeCueCoding.storageEncoder().encode(b))
        let encoded = try JSONValue(encoding: a)
        let values = try #require(Self.strings(encoded["involvement"]))
        #expect(values == Involvement.allCases.map(\.rawValue).sorted())
        #expect(try Fixture.roundTrip(a) == a)
    }

    @Test func digestIsStableHex() throws {
        let digest = try MergeCueCoding.digest(RuleTemplates.failedCIOnMyChangeRequest)
        #expect(digest.count == 64)
        #expect(try digest == MergeCueCoding.digest(RuleTemplates.failedCIOnMyChangeRequest))
        #expect(try digest != MergeCueCoding.digest(RuleTemplates.reviewerQuestion))
    }
}
