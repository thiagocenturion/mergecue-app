import Foundation
import MergeCueCore
import Testing

@Suite("Rules")
struct RuleTests {
    // MARK: Quiet hours

    /// A UTC instant at the given local wall-clock time in `zone` on 2026-03-10 (no DST transition that day in the
    /// zones used).
    private func date(_ hour: Int, _ minute: Int, in zone: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute))!
    }

    @Test(arguments: [
        (21, 59, false), (22, 0, true), (23, 30, true), (0, 0, true), (3, 15, true), (6, 59, true), (7, 0, false), (12, 0, false),
    ])
    func overnightWindow(hour: Int, minute: Int, inside: Bool) {
        let quiet = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60, timeZoneID: "Europe/Lisbon")
        #expect(quiet.contains(date(hour, minute, in: "Europe/Lisbon")) == inside)
    }

    @Test(arguments: [(8, 59, false), (9, 0, true), (12, 0, true), (16, 59, true), (17, 0, false), (23, 0, false)])
    func daytimeWindow(hour: Int, minute: Int, inside: Bool) {
        let quiet = QuietHours(start: (9, 0), end: (17, 0), timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
        #expect(quiet.contains(date(hour, minute, in: "America/Sao_Paulo")) == inside)
    }

    @Test func windowIsEvaluatedInItsOwnTimeZone() {
        let quiet = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60, timeZoneID: "Asia/Tokyo")
        // 23:00 in Tokyo is 14:00 UTC; 23:00 UTC is 08:00 in Tokyo.
        #expect(quiet.contains(date(23, 0, in: "Asia/Tokyo")))
        #expect(!quiet.contains(date(23, 0, in: "UTC")))
    }

    @Test func emptyAndInvalidWindows() {
        let empty = QuietHours(startMinute: 600, endMinute: 600, timeZoneID: "UTC")
        #expect(!empty.contains(date(10, 0, in: "UTC")))
        let unknownZone = QuietHours(startMinute: 0, endMinute: 60, timeZoneID: "Mars/Olympus")
        #expect(unknownZone.timeZone == .gmt)
        #expect(unknownZone.contains(date(0, 30, in: "UTC")))
        let wrapped = QuietHours(startMinute: 1440 + 60, endMinute: -60, timeZoneID: "UTC") // 01:00–23:00
        #expect(wrapped.contains(date(12, 0, in: "UTC")))
        #expect(!wrapped.contains(date(23, 30, in: "UTC")))
    }

    // MARK: Glob

    @Test(arguments: [
        ("acme/*", "acme/api", true),
        ("acme/*", "acme/team/api", false),
        ("acme/**", "acme/team/api", true),
        ("acme/**", "acme/api", true),
        ("**/api", "group/sub/api", true),
        ("**/api", "api", true),
        ("group/**/api", "group/api", true),
        ("group/**/api", "group/a/b/api", true),
        ("group/**/api", "group/a/b/api2", false),
        ("*/payments-*", "acme/payments-api", true),
        ("*/payments-*", "acme/billing-api", false),
        ("acme/ap?", "acme/api", true),
        ("acme/ap?", "acme/ap", false),
        ("acme/a?i", "acme/a/i", false),
        ("ACME/API", "acme/api", true),
        ("acme/api", "Acme/Api", true),
        ("*", "acme/api", false),
        ("**", "acme/api", true),
        ("", "", true),
        ("", "acme/api", false),
        ("acme/*-api", "acme/-api", true),
        ("acme/*.*", "acme/payments.api", true),
    ])
    func glob(pattern: String, candidate: String, expected: Bool) {
        #expect(RuleEvaluator.glob(pattern, matches: candidate) == expected)
    }

    @Test func globDoesNotBlowUpOnPathologicalPatterns() {
        let pattern = String(repeating: "*a", count: 30) + "b"
        let candidate = String(repeating: "a", count: 200)
        #expect(!RuleEvaluator.glob(pattern, matches: candidate))
    }

    // MARK: Matching

    private func rule(
        providerKinds: Set<ProviderKind> = [],
        accounts: Set<AccountKey> = [],
        eventTypes: Set<ChangeEventType> = [],
        include: [String] = [],
        exclude: [String] = [],
        involvement: Set<Involvement> = [],
        excludeAuthors: [String] = [],
        commentKinds: Set<CommentKind> = [],
        isActive: Bool = true,
        maxFiresPerHour: Int = 10,
        quietHours: QuietHours? = nil
    ) -> Rule {
        Rule(
            id: "rule_test", name: "Test", isActive: isActive, origin: .user,
            providerKinds: providerKinds, accounts: accounts, eventTypes: eventTypes,
            repoInclude: include, repoExclude: exclude, involvement: involvement,
            excludeAuthors: excludeAuthors, commentKinds: commentKinds,
            action: .notify, maxFiresPerHour: maxFiresPerHour, quietHours: quietHours, createdAt: Fixture.date
        )
    }

    @Test func emptyFiltersMatchAnything() {
        #expect(RuleEvaluator.matches(rule(), event: Fixture.event(), involvement: []))
    }

    @Test func eventsFromTheCurrentUserNeverMatch() {
        #expect(!RuleEvaluator.matches(rule(), event: Fixture.event(isFromCurrentUser: true), involvement: [.authored]))
    }

    @Test func providerAndAccountFilters() {
        let gitlabEvent = Fixture.event(account: Fixture.gitlabAccount)
        #expect(RuleEvaluator.matches(rule(providerKinds: [.gitlab]), event: gitlabEvent, involvement: []))
        #expect(!RuleEvaluator.matches(rule(providerKinds: [.github, .bitbucketCloud]), event: gitlabEvent, involvement: []))
        #expect(RuleEvaluator.matches(rule(accounts: [Fixture.gitlabAccount]), event: gitlabEvent, involvement: []))
        #expect(!RuleEvaluator.matches(rule(accounts: [Fixture.githubAccount]), event: gitlabEvent, involvement: []))
    }

    @Test func eventTypeFilter() {
        #expect(RuleEvaluator.matches(rule(eventTypes: [.ciFailed]), event: Fixture.event(type: .ciFailed), involvement: []))
        #expect(!RuleEvaluator.matches(rule(eventTypes: [.ciFailed]), event: Fixture.event(type: .ciRecovered), involvement: []))
    }

    @Test func repositoryIncludeAndExclude() {
        let event = Fixture.event(repoFullPath: "Acme/Payments-API")
        #expect(RuleEvaluator.matches(rule(include: ["acme/*"]), event: event, involvement: []))
        #expect(RuleEvaluator.matches(rule(include: ["other/*", "acme/payments-*"]), event: event, involvement: []))
        #expect(!RuleEvaluator.matches(rule(include: ["other/*"]), event: event, involvement: []))
        #expect(!RuleEvaluator.matches(rule(include: ["acme/*"], exclude: ["*/payments-*"]), event: event, involvement: []))
        #expect(!RuleEvaluator.matches(rule(exclude: ["**"]), event: event, involvement: []))
    }

    @Test func involvementFilter() {
        #expect(RuleEvaluator.matches(rule(involvement: [.authored]), event: Fixture.event(), involvement: [.authored, .mentioned]))
        #expect(!RuleEvaluator.matches(rule(involvement: [.authored]), event: Fixture.event(), involvement: [.reviewRequested]))
        #expect(!RuleEvaluator.matches(rule(involvement: [.authored]), event: Fixture.event(), involvement: []))
    }

    @Test func excludedAuthors() {
        let botEvent = Fixture.event(actor: Fixture.person("Dependabot", isBot: true))
        #expect(!RuleEvaluator.matches(rule(excludeAuthors: ["dependabot"]), event: botEvent, involvement: []))
        #expect(!RuleEvaluator.matches(rule(excludeAuthors: ["@DependaBot "]), event: botEvent, involvement: []))
        #expect(RuleEvaluator.matches(rule(excludeAuthors: ["renovate"]), event: botEvent, involvement: []))
        #expect(RuleEvaluator.matches(rule(excludeAuthors: ["renovate"]), event: Fixture.event(actor: nil), involvement: []))
    }

    @Test func commentKindFilter() {
        let question = Fixture.event(commentKind: .question)
        #expect(RuleEvaluator.matches(rule(commentKinds: [.question]), event: question, involvement: []))
        #expect(!RuleEvaluator.matches(rule(commentKinds: [.question]), event: Fixture.event(commentKind: .comment), involvement: []))
        #expect(!RuleEvaluator.matches(rule(commentKinds: [.question]), event: Fixture.event(commentKind: nil), involvement: []))
    }

    @Test func decisionHonorsActivationBaselineQuietHoursAndRateLimit() {
        let event = Fixture.event()
        let now = date(12, 0, in: "UTC")
        #expect(RuleEvaluator.decide(rule(), event: event, involvement: [], now: now, firesInLastHour: 0) == .fire)
        #expect(RuleEvaluator.decide(rule(isActive: false), event: event, involvement: [], now: now, firesInLastHour: 0) == .skip(.inactive))
        #expect(RuleEvaluator.decide(rule(), event: Fixture.event(isBaseline: true), involvement: [], now: now, firesInLastHour: 0) == .skip(.baseline))
        #expect(RuleEvaluator.decide(rule(eventTypes: [.merged]), event: event, involvement: [], now: now, firesInLastHour: 0) == .skip(.notMatching))
        let quiet = QuietHours(startMinute: 11 * 60, endMinute: 13 * 60, timeZoneID: "UTC")
        #expect(RuleEvaluator.decide(rule(quietHours: quiet), event: event, involvement: [], now: now, firesInLastHour: 0) == .skip(.quietHours))
        #expect(RuleEvaluator.decide(rule(maxFiresPerHour: 3), event: event, involvement: [], now: now, firesInLastHour: 2) == .fire)
        #expect(RuleEvaluator.decide(rule(maxFiresPerHour: 3), event: event, involvement: [], now: now, firesInLastHour: 3) == .skip(.rateLimited))
        #expect(RuleEvaluator.decide(rule(maxFiresPerHour: 0), event: event, involvement: [], now: now, firesInLastHour: 0) == .skip(.rateLimited))
    }

    // MARK: Templates

    @Test func fourInactiveTemplates() {
        #expect(RuleTemplates.all.count == 4)
        #expect(Set(RuleTemplates.all.map(\.id)).count == 4)
        for template in RuleTemplates.all {
            #expect(template.isActive == false)
            #expect(template.origin == .template)
            #expect(template.maxFiresPerHour > 0)
            #expect(RuleTemplates.template(id: template.id) == template)
        }
    }

    @Test func templateSemantics() {
        let ci = RuleTemplates.failedCIOnMyChangeRequest
        #expect(ci.eventTypes == [.ciFailed])
        #expect(ci.involvement == [.authored])
        #expect(ci.action == .createTask(.investigateCI))

        let change = RuleTemplates.newRequestedChange
        #expect(change.eventTypes == [.changeRequested])
        #expect(change.action == .createTask(.fixReview))

        let question = RuleTemplates.reviewerQuestion
        #expect(question.action == .notify)
        #expect(question.commentKinds == [.question])
        #expect(RuleEvaluator.matches(question, event: Fixture.event(type: .reviewComment, commentKind: .question), involvement: [.authored]))
        #expect(!RuleEvaluator.matches(question, event: Fixture.event(type: .reviewComment, commentKind: .comment), involvement: [.authored]))

        let ready = RuleTemplates.changeRequestReadyForReview
        #expect(ready.eventTypes == [.reviewRequested])
        #expect(ready.action == .notify)
        #expect(RuleEvaluator.matches(ready, event: Fixture.event(type: .reviewRequested), involvement: [.reviewRequested]))
    }

    @Test func templatesNeverFireUntilActivated() {
        let event = Fixture.event(type: .ciFailed)
        #expect(RuleEvaluator.decide(RuleTemplates.failedCIOnMyChangeRequest, event: event, involvement: [.authored], now: Fixture.date, firesInLastHour: 0) == .skip(.inactive))
        let copy = RuleTemplates.instantiate(RuleTemplates.failedCIOnMyChangeRequest, id: "rule_abc", now: Fixture.date.addingTimeInterval(10))
        #expect(copy.id == "rule_abc")
        #expect(copy.isActive == false)
        #expect(copy.createdAt == Fixture.date.addingTimeInterval(10))
        var activated = copy
        activated.isActive = true
        #expect(RuleEvaluator.decide(activated, event: event, involvement: [.authored], now: Fixture.date, firesInLastHour: 0) == .fire)
    }

    // MARK: Encoding

    @Test func ruleActionJSON() throws {
        #expect(try Fixture.json(RuleAction.notify) == #"{"type":"notify"}"#)
        #expect(try Fixture.json(RuleAction.createTask(.investigateCI)) == #"{"task_type":"investigate_ci","type":"create_task"}"#)
        #expect(try Fixture.json(RuleAction.requestExecution(.fixReview)) == #"{"task_type":"fix_review","type":"request_execution"}"#)
        for action in [RuleAction.notify, .createTask(.draftReply), .requestExecution(.addressSuggestion)] {
            #expect(try Fixture.roundTrip(action) == action)
        }
        #expect(throws: DecodingError.self) { try Fixture.decode(RuleAction.self, from: #"{"type":"create_task"}"#) }
    }

    @Test func ruleRoundTripsAndToleratesMissingOptionalFilters() throws {
        let full = rule(
            providerKinds: [.github], accounts: [Fixture.githubAccount], eventTypes: [.ciFailed], include: ["acme/*"],
            exclude: ["acme/legacy"], involvement: [.authored], excludeAuthors: ["bot"], commentKinds: [.question],
            quietHours: QuietHours(startMinute: 1320, endMinute: 420, timeZoneID: "UTC")
        )
        #expect(try Fixture.roundTrip(full) == full)
        for template in RuleTemplates.all {
            #expect(try Fixture.roundTrip(template) == template)
        }

        let minimal = """
        {"id":"r1","name":"Minimal","isActive":false,"origin":"agent_proposal","action":{"type":"notify"},
         "maxFiresPerHour":5,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoded = try Fixture.decode(Rule.self, from: minimal)
        #expect(decoded.origin == .agentProposal)
        #expect(decoded.eventTypes.isEmpty && decoded.commentKinds.isEmpty && decoded.repoInclude.isEmpty)
        #expect(decoded.quietHours == nil)
    }
}
