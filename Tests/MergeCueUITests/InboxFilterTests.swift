import Foundation
import MergeCueCore
@testable import MergeCueUI
import Testing

@Suite("Inbox and PR/MR filters")
struct InboxFilterTests {
    let state = previewState()

    private func run(_ filter: InboxFilter, showRead: Bool = true) -> InboxResult {
        InboxQuery.run(state: state, filter: filter, now: testNow, showRead: showRead)
    }

    @Test func identicalNumbersOnDifferentProvidersStayDistinctGroups() {
        let groups = run(InboxFilter(collapseRead: false)).groups.filter { $0.changeRequest.number == 42 }
        #expect(groups.count == 3)
        #expect(Set(groups.map(\.providerKind)) == Set(ProviderKind.allCases))
        #expect(Set(groups.map(\.id)).count == 3)
        // Items never leak into another provider's group.
        for group in groups {
            #expect(group.items.allSatisfy { $0.changeRequest == group.changeRequest && $0.providerKind == group.providerKind })
        }
    }

    @Test func repositoryFilterIsProviderQualified() throws {
        let githubRepo = try #require(state.attention(.github, number: 42, reason: .changesRequested)).changeRequest.repo
        let items = run(InboxFilter(repo: githubRepo, collapseRead: false)).visibleItems
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.providerKind == .github && $0.changeRequest.repo == githubRepo })
        // Same path on GitLab and Bitbucket is excluded.
        #expect(state.attention.contains { $0.providerKind != .github && $0.repoFullPath == "acme/payments-api" })
        #expect(!items.contains { $0.providerKind != .github })
    }

    @Test func providerAndAccountFilters() throws {
        let gitlab = run(InboxFilter(provider: .gitlab, collapseRead: false)).visibleItems
        #expect(!gitlab.isEmpty && gitlab.allSatisfy { $0.providerKind == .gitlab })
        let account = try #require(state.accounts.first { $0.kind == .bitbucketCloud }).id
        let bitbucket = run(InboxFilter(account: account, collapseRead: false)).visibleItems
        #expect(!bitbucket.isEmpty && bitbucket.allSatisfy { $0.account == account })
    }

    @Test func searchUsesProviderSpecificNumberPrefixes() {
        let hash = run(InboxFilter(searchText: "payments-api #42", collapseRead: false)).visibleItems
        #expect(Set(hash.map(\.providerKind)) == [.github, .bitbucketCloud])
        let bang = run(InboxFilter(searchText: "!42", collapseRead: false)).visibleItems
        #expect(!bang.isEmpty && bang.allSatisfy { $0.providerKind == .gitlab && $0.number == 42 })
    }

    @Test func mineAndReviewingScopes() {
        let snapshots = Dictionary(state.changeRequests.map { ($0.key, $0.summary.involvement) }, uniquingKeysWith: { first, _ in first })
        let mine = run(InboxFilter(scope: .mine, collapseRead: false)).visibleItems
        let reviewing = run(InboxFilter(scope: .reviewing, collapseRead: false)).visibleItems
        #expect(!mine.isEmpty && mine.allSatisfy { snapshots[$0.changeRequest]?.contains(.authored) == true })
        #expect(!reviewing.isEmpty && reviewing.allSatisfy { snapshots[$0.changeRequest]?.contains(.reviewRequested) == true })
        #expect(Set(mine.map(\.id)).isDisjoint(with: reviewing.map(\.id)))
    }

    @Test func collapseReadHidesReadActivity() {
        let collapsed = InboxQuery.run(state: state, filter: InboxFilter(collapseRead: true), now: testNow)
        let expanded = InboxQuery.run(state: state, filter: InboxFilter(collapseRead: true), now: testNow, showRead: true)
        #expect(collapsed.hiddenReadCount > 0)
        #expect(collapsed.visibleItems.allSatisfy { $0.isUnread || $0.isActionable(now: testNow) })
        #expect(expanded.visibleItems.count == collapsed.visibleItems.count + collapsed.hiddenReadCount)
    }

    @Test func statusFilters() {
        let needsAction = run(InboxFilter(status: .needsAction, collapseRead: false)).visibleItems
        #expect(needsAction.count == 5)
        #expect(needsAction.allSatisfy { $0.isActionable(now: testNow) })
        let snoozed = run(InboxFilter(status: .snoozed, collapseRead: false)).visibleItems
        #expect(snoozed.count == 1)
        let withTask = run(InboxFilter(status: .withTask, collapseRead: false)).visibleItems
        #expect(withTask.allSatisfy { $0.linkedTaskID != nil })
        let done = run(InboxFilter(status: .done, collapseRead: false)).visibleItems
        #expect(done.allSatisfy { !$0.isActionable(now: testNow) })
    }

    @Test func changeRequestListKeepsEveryAccountVisibleWithItsState() throws {
        let errors = MergeCuePreview.makeState(variant: .authExpired, now: testNow)
        let sections = ChangeRequestQueryUI.run(state: errors, filter: ChangeRequestFilter())
        #expect(sections.count == 3)
        let gitlab = try #require(sections.first { $0.account.kind == .gitlab })
        #expect(gitlab.listState == .credentialsExpired)
        #expect(!gitlab.items.isEmpty, "last known data stays visible")
        let bitbucket = try #require(sections.first { $0.account.kind == .bitbucketCloud })
        if case .offline = bitbucket.listState {} else { Issue.record("Bitbucket should be offline, got \(bitbucket.listState)") }
        let github = try #require(sections.first { $0.account.kind == .github })
        #expect(github.listState == .ok)
        // #42 exists on all three providers and each stays in its own account section.
        for section in sections {
            #expect(section.items.allSatisfy { $0.key.account == section.account.id })
        }
    }

    @Test func accountListStates() {
        let key = AccountKey(kind: .github, host: "github.com", remoteUserID: "1")
        #expect(AccountListState(status: AccountSyncStatus(account: key, state: .syncing), hasItems: false) == .loading)
        #expect(AccountListState(status: AccountSyncStatus(account: key, state: .ok, lastSuccessAt: testNow), hasItems: false) == .empty)
        #expect(AccountListState(status: AccountSyncStatus(account: key, state: .permissionDenied("missing scope read:org")), hasItems: true)
            == .unsupportedPermission("missing scope read:org"))
        #expect(AccountListState(status: AccountSyncStatus(account: key, state: .rateLimited(until: testNow)), hasItems: true)
            == .rateLimited(until: testNow))
    }

    /// An account whose change requests all failed to load is never shown as a healthy empty list (DECISIONS D35).
    @Test func failedChangeRequestsAreSurfaced() throws {
        let key = AccountKey(kind: .bitbucketCloud, host: "bitbucket.org", remoteUserID: "1")
        let errors = (1...4).map { number in
            ChangeRequestSyncError(
                changeRequest: ChangeRequestKey(repo: RepoKey(account: key, remoteRepoID: "r"), remoteID: "\(number)", number: number),
                title: "PR \(number)", repoFullPath: "acme/api", code: "not_found", message: "Not found.",
                isTerminal: true, failedAt: testNow
            )
        }
        var status = AccountSyncStatus(account: key, state: .ok, lastSuccessAt: testNow, changeRequestErrors: errors)
        #expect(AccountListState(status: status, hasItems: false) == .changeRequestsFailed(count: 4))
        #expect(AccountListState(status: status, hasItems: false).isProblem)
        #expect(AccountListState(status: status, hasItems: true) == .ok)
        #expect(UIFormat.changeRequestFailureText(status, kind: .bitbucketCloud) == "4 PRs couldn't be loaded: not found")
        #expect(UIFormat.changeRequestRetryText(status)?.contains("Not retried automatically") == true)
        status.changeRequestErrors = [errors[0]]
        #expect(UIFormat.changeRequestFailureText(status, kind: .gitlab) == "1 MR couldn't be loaded: not found")
        status.changeRequestErrors = []
        #expect(UIFormat.changeRequestFailureText(status, kind: .github) == nil)
    }

    @Test func rateLimitAndRequestUsageTexts() {
        let key = AccountKey(kind: .github, host: "github.com", remoteUserID: "1")
        let limited = AccountSyncStatus(account: key, state: .rateLimited(until: testNow))
        #expect(UIFormat.syncText(limited, now: testNow) == "Rate limited — retrying at \(UIFormat.time(testNow))")
        #expect(!UIFormat.syncText(limited, now: testNow).contains("hour"))
        var usage = AccountSyncStatus(account: key, state: .ok, requestsLastHour: 142, requestBudget: 1_500)
        #expect(UIFormat.requestUsageText(usage) == "142 requests in the last hour · budget 1500/h")
        usage.requestsLastHour = 1_600
        #expect(usage.isOverRequestBudget)
        #expect(UIFormat.requestUsageText(usage)?.contains("refreshing less often") == true)
        usage.requestsLastHour = nil
        #expect(UIFormat.requestUsageText(usage) == nil)
    }
}
