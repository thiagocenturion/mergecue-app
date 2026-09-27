import Foundation
import MergeCueCore

/// Mine / Reviewing / All.
public nonisolated enum InboxScope: String, Sendable, Hashable, CaseIterable, Identifiable {
    case mine, reviewing, all

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mine: "Mine"
        case .reviewing: "Reviewing"
        case .all: "All"
        }
    }

    /// Whether a change request with `involvement` belongs to the scope.
    public func includes(_ involvement: Set<Involvement>?) -> Bool {
        switch self {
        case .all: true
        case .mine: involvement?.contains(.authored) ?? false
        case .reviewing: involvement?.contains(.reviewRequested) ?? false
        }
    }
}

/// Status filter of the inbox.
public nonisolated enum InboxStatusFilter: String, Sendable, Hashable, CaseIterable, Identifiable {
    case all, needsAction, unread, withTask, snoozed, done

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: "All statuses"
        case .needsAction: "Needs action"
        case .unread: "Unread"
        case .withTask: "Has a task"
        case .snoozed: "Snoozed"
        case .done: "Done"
        }
    }
}

/// Inbox filters. The repository filter uses the provider-qualified `RepoKey`, so `acme/payments-api` on GitHub
/// never matches the same path on GitLab or Bitbucket.
public nonisolated struct InboxFilter: Sendable, Hashable {
    public var scope: InboxScope = .all
    public var provider: ProviderKind?
    public var account: AccountKey?
    public var repo: RepoKey?
    public var status: InboxStatusFilter = .all
    public var searchText: String = ""
    /// Hide already-read activity behind a "Show read" row.
    public var collapseRead: Bool = true

    public init(scope: InboxScope = .all, provider: ProviderKind? = nil, account: AccountKey? = nil, repo: RepoKey? = nil,
                status: InboxStatusFilter = .all, searchText: String = "", collapseRead: Bool = true) {
        self.scope = scope
        self.provider = provider
        self.account = account
        self.repo = repo
        self.status = status
        self.searchText = searchText
        self.collapseRead = collapseRead
    }

    /// Whether any narrowing filter (other than collapse read) is set.
    public var isNarrowed: Bool {
        scope != .all || provider != nil || account != nil || repo != nil || status != .all
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Inbox items of one change request (provider-qualified: `#42` on two providers are two groups).
public nonisolated struct InboxGroup: Sendable, Hashable, Identifiable {
    public var changeRequest: ChangeRequestKey
    public var repoFullPath: String
    public var title: String
    public var items: [AttentionItem]
    public var hiddenReadCount: Int
    public var latest: Date

    public var id: String { changeRequest.id }
    public var providerKind: ProviderKind { changeRequest.kind }
    public var refText: String { "\(repoFullPath) \(providerKind.formattedNumber(changeRequest.number))" }
}

public nonisolated struct InboxResult: Sendable, Hashable {
    public var groups: [InboxGroup]
    /// Read items hidden by `collapseRead` across all groups.
    public var hiddenReadCount: Int
    public var totalCount: Int

    public var visibleItems: [AttentionItem] { groups.flatMap(\.items) }
}

/// Pure inbox filtering and grouping.
public nonisolated enum InboxQuery {
    public static func run(state: AppState, filter: InboxFilter, now: Date, showRead: Bool = false) -> InboxResult {
        let snapshots = Dictionary(state.changeRequests.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let activeTaskIDs = Set(state.tasks.filter { !$0.task.isTerminal }.map(\.id))
        let matching = state.attention.filter {
            matches($0, filter: filter, involvement: snapshots[$0.changeRequest]?.summary.involvement, activeTaskIDs: activeTaskIDs, now: now)
        }

        var order: [ChangeRequestKey] = []
        var buckets: [ChangeRequestKey: [AttentionItem]] = [:]
        for item in matching {
            if buckets[item.changeRequest] == nil { order.append(item.changeRequest) }
            buckets[item.changeRequest, default: []].append(item)
        }

        var hiddenTotal = 0
        var groups: [InboxGroup] = []
        for key in order {
            let items = (buckets[key] ?? []).sorted(by: itemOrder(now: now))
            let collapse = filter.collapseRead && !showRead && filter.status != .done
            let visible = collapse ? items.filter { $0.isUnread || $0.isActionable(now: now) } : items
            let hidden = items.count - visible.count
            hiddenTotal += hidden
            guard !visible.isEmpty, let first = items.first else { continue }
            groups.append(InboxGroup(
                changeRequest: key,
                repoFullPath: first.repoFullPath,
                title: snapshots[key]?.summary.title ?? first.title,
                items: visible,
                hiddenReadCount: hidden,
                latest: items.map(\.updatedAt).max() ?? first.updatedAt
            ))
        }
        groups.sort { $0.latest > $1.latest }
        return InboxResult(groups: groups, hiddenReadCount: hiddenTotal, totalCount: matching.count)
    }

    /// Unread first, then actionable, then most recent.
    static func itemOrder(now: Date) -> (AttentionItem, AttentionItem) -> Bool {
        { lhs, rhs in
            if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
            let lhsActionable = lhs.isActionable(now: now)
            if lhsActionable != rhs.isActionable(now: now) { return lhsActionable }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public static func matches(_ item: AttentionItem, filter: InboxFilter, involvement: Set<Involvement>?, activeTaskIDs: Set<TaskID>, now: Date) -> Bool {
        guard filter.scope.includes(involvement) else { return false }
        if let provider = filter.provider, item.providerKind != provider { return false }
        if let account = filter.account, item.account != account { return false }
        if let repo = filter.repo, item.changeRequest.repo != repo { return false }
        switch filter.status {
        case .all:
            if case .dismissed = item.disposition { return false }
        case .needsAction:
            guard item.isActionable(now: now) else { return false }
            if let task = item.linkedTaskID, activeTaskIDs.contains(task) { return false }
        case .unread:
            guard item.isUnread else { return false }
        case .withTask:
            guard item.linkedTaskID != nil else { return false }
        case .snoozed:
            guard case .snoozed(let until) = item.disposition, until > now else { return false }
        case .done:
            switch item.disposition {
            case .acknowledged, .resolved, .dismissed: break
            case .open, .snoozed: return false
            }
        }
        return matchesSearch(item, text: filter.searchText)
    }

    static func matchesSearch(_ item: AttentionItem, text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = [
            item.title, item.repoFullPath, item.summary, item.reason.displayName, item.providerKind.displayName,
            item.providerKind.formattedNumber(item.number), "\(item.repoFullPath)\(item.providerKind.formattedNumber(item.number))",
        ].joined(separator: "\n").lowercased()
        return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

// MARK: - PRs & MRs

/// Per-account state shown above that account's PR/MR list (never blocks other accounts).
public nonisolated enum AccountListState: Sendable, Hashable {
    case loading
    case empty
    case ok
    case offline(lastSuccess: Date?)
    case credentialsExpired
    case rateLimited(until: Date?)
    case unsupportedPermission(String)
    case error(String)

    public init(status: AccountSyncStatus, hasItems: Bool) {
        switch status.state {
        case .idle, .syncing:
            self = status.lastSuccessAt == nil ? .loading : (hasItems ? .ok : .empty)
        case .ok, .paused:
            self = hasItems ? .ok : .empty
        case .offline: self = .offline(lastSuccess: status.lastSuccessAt)
        case .authExpired: self = .credentialsExpired
        case .rateLimited(let until): self = .rateLimited(until: until)
        case .permissionDenied(let message): self = .unsupportedPermission(message)
        case .error(let message): self = .error(message)
        }
    }

    /// A problem banner is shown for these states (the last known data stays visible below it).
    public var isProblem: Bool {
        switch self {
        case .loading, .empty, .ok: false
        default: true
        }
    }
}

public nonisolated struct ChangeRequestFilter: Sendable, Hashable {
    public var scope: InboxScope = .all
    public var provider: ProviderKind?
    public var account: AccountKey?
    public var searchText: String = ""
    public var includeClosed: Bool = false

    public init(scope: InboxScope = .all, provider: ProviderKind? = nil, account: AccountKey? = nil, searchText: String = "", includeClosed: Bool = false) {
        self.scope = scope
        self.provider = provider
        self.account = account
        self.searchText = searchText
        self.includeClosed = includeClosed
    }
}

public nonisolated struct AccountChangeRequests: Sendable, Hashable, Identifiable {
    public var account: AccountState
    public var listState: AccountListState
    public var items: [ChangeRequestSnapshot]
    public var id: String { account.id.id }
}

public nonisolated enum ChangeRequestQueryUI {
    public static func run(state: AppState, filter: ChangeRequestFilter) -> [AccountChangeRequests] {
        state.accounts.compactMap { account in
            if let provider = filter.provider, account.kind != provider { return nil }
            if let only = filter.account, account.id != only { return nil }
            let all = state.changeRequests.filter { $0.key.account == account.id }
            let items = all.filter { snapshot in
                guard filter.scope.includes(snapshot.summary.involvement) else { return false }
                guard filter.includeClosed || snapshot.summary.state == .open else { return false }
                return matchesSearch(snapshot, text: filter.searchText)
            }
            .sorted { $0.summary.updatedAt > $1.summary.updatedAt }
            return AccountChangeRequests(account: account, listState: AccountListState(status: account.status, hasItems: !all.isEmpty), items: items)
        }
    }

    static func matchesSearch(_ snapshot: ChangeRequestSnapshot, text: String) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let summary = snapshot.summary
        let haystack = [summary.title, summary.repository.fullPath, summary.author.username, summary.displayNumber, summary.sourceBranch]
            .joined(separator: "\n").lowercased()
        return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}

// MARK: - Tasks

public nonisolated enum TaskGroup: String, Sendable, Hashable, CaseIterable, Identifiable {
    case ready, needsAttention, active, finished

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ready: "Ready for review"
        case .needsAttention: "Needs your decision"
        case .active: "Active"
        case .finished: "Finished"
        }
    }

    public static func group(for state: TaskState) -> TaskGroup {
        switch state {
        case .readyForReview: .ready
        case .blocked, .failed, .stale: .needsAttention
        case .waitingForAgent, .working, .approvedAction: .active
        case .done, .cancelled, .dismissed: .finished
        }
    }
}
