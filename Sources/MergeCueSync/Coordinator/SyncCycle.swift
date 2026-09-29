import Foundation
import MergeCueCore
import MergeCueStore

/// One sync cycle of one account, in one of two modes:
/// - **full** (every `listInterval`, manual refresh, return/focus, wake, network recovery): lists → change detection
///   (new / changed list version / due per `ChangeRequestSchedule`) → bounded hydration → departed CRs;
/// - **details** (between lists): hydrates only the CRs whose progressive detail refresh is due.
///
/// Both then run `EventDeriver` → `AttentionDeriver` → `applySyncBatch` (atomic; cursor + events persisted **before**
/// anything is notified) → `NotificationGrouper` → notifier → event handler.
struct SyncCycle {
    enum Mode: Sendable, Hashable {
        case full
        case details
    }

    struct Outcome: Sendable {
        var isBaseline: Bool
        /// Events inserted by this cycle (deduped by the store), baseline included.
        var insertedEvents: [ChangeEvent]
        var notifications: [GroupedNotification]
        var hydratedCount: Int
        var removedCount: Int
        /// Hydrations that failed per change request (the account itself is fine).
        var failedCount: Int
        /// The per-CR schedule updated with this cycle's results.
        var schedule: ChangeRequestSchedule
    }

    /// Cursor key prefix for per-CR list versions.
    static let listVersionPrefix = "cr:"
    static let lastCycleKey = "meta:last_cycle_at"

    let account: Account
    let provider: any ReviewProvider
    let environment: SyncEnvironment

    func run(mode: Mode, schedule initial: ChangeRequestSchedule, hints: ScheduleHints) async throws -> Outcome {
        let database = environment.database
        let now = hints.now
        let settings = environment.current
        let configuration = settings.configuration
        let isBaseline = try await !database.hasCompletedInitialSync(account: account.id)
        var schedule = initial

        // 1. Lists (full) or the due CRs (details).
        let storedSnapshots = try await database.snapshots(account: account.id)
        let stored = Dictionary(storedSnapshots.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let storedCursor = try await database.cursor(account: account.id)
        schedule.seed(from: storedSnapshots)

        var toHydrate: [ChangeRequestSummary] = []
        var departed: [ChangeRequestSnapshot] = []
        var departedToHydrate: [ChangeRequestSummary] = []
        var listVersions: [ChangeRequestKey: String] = [:]
        var cursor: [String: String]
        switch mode {
        case .full:
            let listed = Self.mergeLists(try await fetchLists(now: now, configuration: configuration), stored: storedSnapshots)
            let listedKeys = Set(listed.map(\.key))
            cursor = [:]
            for summary in listed {
                let version = Self.listVersion(summary)
                listVersions[summary.key] = version
                let storedVersion = storedCursor[Self.listVersionPrefix + summary.key.id]
                // Keep the previous list version when hydration is skipped or fails, so a change is still detected.
                if let storedVersion { cursor[Self.listVersionPrefix + summary.key.id] = storedVersion }
                if schedule.shouldHydrate(
                    listed: summary, listVersion: version, storedListVersion: storedVersion,
                    hasSnapshot: stored[summary.key] != nil, hints: hints, configuration: configuration
                ) {
                    toHydrate.append(summary)
                }
            }
            departed = storedSnapshots.filter { !listedKeys.contains($0.key) }.sorted { $0.key.id < $1.key.id }
            // Departed CRs are hydrated once to detect merged/closed — unless that is already known (stored as
            // merged/closed) or the CR is gone (its last hydration said not found).
            departedToHydrate = departed.filter { snapshot in
                guard snapshot.summary.state == .open else { return false }
                if case .notFound? = schedule.tracker(snapshot.key)?.lastError { return false }
                return true
            }.map(\.summary)
            schedule.retain(listedKeys)
        case .details:
            cursor = storedCursor
            for key in schedule.dueKeys(hints: hints, configuration: configuration) {
                guard let summary = schedule.summary(key) ?? stored[key]?.summary else { continue }
                toHydrate.append(summary)
            }
        }
        if mode == .details, toHydrate.isEmpty {
            return Outcome(
                isBaseline: isBaseline, insertedEvents: [], notifications: [], hydratedCount: 0, removedCount: 0,
                failedCount: 0, schedule: schedule
            )
        }
        cursor[Self.lastCycleKey] = String(now.timeIntervalSinceReferenceDate)

        // 2. Hydrate with bounded concurrency.
        let account = account.id
        let environment = environment
        let results = try await Self.hydrate(
            toHydrate + departedToHydrate, provider: provider, limit: configuration.hydrateConcurrency,
            onCall: { environment.recordProviderCall(account) }
        )

        // 3. Derive events and attention per CR.
        let me = self.account.id.remoteUserID
        var snapshots: [ChangeRequestSnapshot] = []
        var snapshotMap: [ChangeRequestKey: ChangeRequestSnapshot] = [:]
        var removed: [ChangeRequestKey] = []
        var events: [ChangeEvent] = []
        var upserts: [AttentionItem] = []
        var existingByKey: [String: AttentionItem] = [:]
        var failed = 0

        for summary in toHydrate {
            switch results[summary.key] {
            case .success(var snapshot)?:
                snapshot.summary.involvement.formUnion(summary.involvement)
                if let token = summary.versionToken { snapshot.summary.versionToken = token }
                let existing = try await database.attentionItems(changeRequest: summary.key)
                for item in existing { existingByKey[item.dedupeKey] = item }
                let derived = EventDeriver.derive(
                    previous: stored[summary.key], current: snapshot, currentUserID: me, isBaseline: isBaseline, now: now,
                    knownFailingCheckNames: Self.unresolvedFailingCheckNames(snapshot: snapshot, existing: existing)
                )
                upserts += AttentionDeriver.apply(events: derived, snapshot: snapshot, existing: existing, account: self.account, now: now)
                events += derived
                snapshots.append(snapshot)
                snapshotMap[snapshot.key] = snapshot
                schedule.recordSuccess(snapshot, previous: stored[summary.key], now: now)
                if let version = listVersions[summary.key] ?? schedule.tracker(summary.key)?.listVersion {
                    cursor[Self.listVersionPrefix + summary.key.id] = version
                }
            case .failure(let error)?:
                failed += 1
                schedule.recordFailure(summary, error: error, listVersion: listVersions[summary.key], now: now)
                MCLog.sync.notice("Hydration of a \(account.kind.rawValue) change request failed: \(error.code)")
            case nil:
                continue
            }
        }

        for previous in departed {
            let existing = try await database.attentionItems(changeRequest: previous.key)
            for item in existing { existingByKey[item.dedupeKey] = item }
            var lifecycle: [ChangeEvent] = []
            if case .success(let snapshot)? = results[previous.key] {
                let derived = EventDeriver.derive(
                    previous: previous, current: snapshot, currentUserID: me, isBaseline: isBaseline, now: now
                )
                events += derived
                lifecycle = derived.filter { $0.type == .merged || $0.type == .closedWithoutMerge }
                snapshotMap[snapshot.key] = snapshot
            }
            // Left the user's lists (merged, closed, reviewed, unassigned, deleted): resolve and forget it.
            upserts += AttentionDeriver.resolveAll(existing: existing, events: lifecycle)
            removed.append(previous.key)
            cursor[Self.listVersionPrefix + previous.key.id] = nil
        }

        // 4. Persist atomically before anything is announced.
        try Task.checkCancellation()
        let batch = SyncBatch(
            account: account,
            snapshots: snapshots,
            removedChangeRequests: removed,
            events: events,
            attentionUpserts: upserts,
            cursor: cursor,
            syncedAt: now
        )
        let inserted = try await database.applySyncBatch(batch)
        if !snapshots.isEmpty || !removed.isEmpty { environment.onChange(.changeRequests) }
        if !upserts.isEmpty { environment.onChange(.attention) }

        // 5. Notifications (one per CR), then the rule/event handler.
        var notifications: [GroupedNotification] = []
        let policy = environment.notificationPolicy
        if !isBaseline, policy.allowsDelivery(at: now) {
            notifications = NotificationGrouper.group(
                newEvents: inserted,
                attentionUpserts: upserts,
                existing: existingByKey,
                snapshots: snapshotMap,
                account: self.account,
                informationalTypes: configuration.informationalNotificationTypes,
                preferences: policy.preferences,
                now: now
            )
        }
        for notification in notifications {
            await environment.notifier.deliver(notification)
        }
        let forHandler = inserted.filter { !$0.isBaseline }
        if !forHandler.isEmpty, let handler = environment.current.eventHandler {
            await handler(forHandler)
        }

        return Outcome(
            isBaseline: isBaseline,
            insertedEvents: inserted,
            notifications: notifications,
            hydratedCount: snapshots.count,
            removedCount: removed.count,
            failedCount: failed,
            schedule: schedule
        )
    }

    /// The listings of a full cycle: authored, review-requested (per tracking preferences) and involved.
    private func fetchLists(now: Date, configuration: SyncConfiguration) async throws -> [(ChangeRequestScope, ChangeRequestPage)] {
        let repositories = try await environment.database.repositories(account: account.id)
        let tracking = environment.current.tracking
        async let authoredPage = list(query(.authored, repositories: repositories))
        async let requestedPage: ChangeRequestPage? = tracking.includeReviewRequests
            ? try await list(query(.reviewRequested, repositories: repositories))
            : nil
        async let involvedPage = tracking.includeInvolved
            ? try await involvedListing(repositories: repositories, now: now, window: configuration.involvedWindow)
            : nil
        var pages: [(ChangeRequestScope, ChangeRequestPage)] = [(.authored, try await authoredPage)]
        if let requested = try await requestedPage { pages.append((.reviewRequested, requested)) }
        if let involved = try await involvedPage { pages.append((.involved, involved)) }
        return pages
    }

    private func list(_ query: ChangeRequestQuery) async throws -> ChangeRequestPage {
        environment.recordProviderCall(account.id)
        return try await provider.listChangeRequests(query)
    }

    private func query(_ scope: ChangeRequestScope, repositories: [Repository]) -> ChangeRequestQuery {
        ChangeRequestQuery(scope: scope, namespaces: account.selectedNamespaces, repositories: repositories)
    }

    /// The involved listing (CRs of others the user reviewed or commented on), when the provider declares it and
    /// the window is on. A failure specific to this additive listing (not found, forbidden, unsupported, decoding,
    /// invalid request — e.g. a provider rejecting a query filter)
    /// keeps the stored involved CRs (`notModified`) instead of failing the whole cycle; account-level failures
    /// (auth, rate limit, offline) propagate like the other listings.
    private func involvedListing(repositories: [Repository], now: Date, window: TimeInterval?) async throws -> ChangeRequestPage? {
        guard let window, provider.capabilities.support(for: .listInvolved).isUsable else { return nil }
        var request = query(.involved, repositories: repositories)
        request.updatedSince = now.addingTimeInterval(-window)
        do {
            return try await list(request)
        } catch {
            switch ProviderError.classify(error) {
            case .notFound?, .forbidden?, .unsupported?, .decoding?, .invalidRequest?, .conflict?: return .unchanged
            default: throw error
            }
        }
    }

    // MARK: Pure helpers

    /// Union of both listings (involvement merged). A `notModified` page keeps the stored CRs of that scope.
    static func mergeLists(
        _ pages: [(ChangeRequestScope, ChangeRequestPage)], stored: [ChangeRequestSnapshot]
    ) -> [ChangeRequestSummary] {
        var order: [ChangeRequestKey] = []
        var merged: [ChangeRequestKey: ChangeRequestSummary] = [:]
        func add(_ summary: ChangeRequestSummary, scope: ChangeRequestScope) {
            var summary = summary
            summary.involvement.insert(scope.involvement)
            if var known = merged[summary.key] {
                known.involvement.formUnion(summary.involvement)
                merged[summary.key] = known
            } else {
                order.append(summary.key)
                merged[summary.key] = summary
            }
        }
        for (scope, page) in pages {
            if page.notModified {
                for snapshot in stored where snapshot.summary.involvement.contains(scope.involvement) {
                    add(snapshot.summary, scope: scope)
                }
            } else {
                for summary in page.items where summary.state == .open {
                    add(summary, scope: scope)
                }
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// Change detector of a listed CR, stored in the account cursor.
    static func listVersion(_ summary: ChangeRequestSummary) -> String {
        let scopes = summary.involvement
            .filter { $0 == .authored || $0 == .reviewRequested || $0 == .participated }
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        return [
            summary.versionToken ?? "-",
            String(summary.updatedAt.timeIntervalSinceReferenceDate),
            summary.headSHA ?? "-",
            summary.state.rawValue,
            summary.isDraft ? "draft" : "ready",
            scopes,
        ].joined(separator: "|")
    }

    /// Check names that have an unresolved CI attention item (their last terminal status was a failure).
    static func unresolvedFailingCheckNames(snapshot: ChangeRequestSnapshot, existing: [AttentionItem]) -> Set<String> {
        let unresolved = Set(existing.filter { $0.reason == .ciFailed && $0.disposition != .resolved }.map(\.dedupeKey))
        guard !unresolved.isEmpty else { return [] }
        return Set(snapshot.checks.map(\.name).filter {
            unresolved.contains(AttentionItem.dedupeKey(changeRequest: snapshot.key, checkName: $0))
        })
    }

    /// Hydrates with at most `limit` concurrent calls. Per-change-request failures (`isPerChangeRequestFailure`) are
    /// returned as failures; account-level failures (auth, rate limit, offline, timeout) cancel the rest and are thrown.
    static func hydrate(
        _ summaries: [ChangeRequestSummary], provider: any ReviewProvider, limit: Int,
        onCall: @escaping @Sendable () -> Void = {}
    ) async throws -> [ChangeRequestKey: Result<ChangeRequestSnapshot, ProviderError>] {
        guard !summaries.isEmpty else { return [:] }
        return try await withThrowingTaskGroup(
            of: (ChangeRequestKey, Result<ChangeRequestSnapshot, ProviderError>).self
        ) { group in
            var results: [ChangeRequestKey: Result<ChangeRequestSnapshot, ProviderError>] = [:]
            var pending = summaries[...]
            let width = max(1, limit)
            for _ in 0..<width {
                guard let next = pending.popFirst() else { break }
                group.addTask { try await hydrateOne(next, provider: provider, onCall: onCall) }
            }
            while let (key, result) = try await group.next() {
                if case .failure(let error) = result, !isPerChangeRequestFailure(error) {
                    group.cancelAll()
                    throw error
                }
                results[key] = result
                if let next = pending.popFirst() {
                    group.addTask { try await hydrateOne(next, provider: provider, onCall: onCall) }
                }
            }
            return results
        }
    }

    private static func hydrateOne(
        _ summary: ChangeRequestSummary, provider: any ReviewProvider, onCall: @Sendable () -> Void
    ) async throws -> (ChangeRequestKey, Result<ChangeRequestSnapshot, ProviderError>) {
        onCall()
        do {
            return (summary.key, .success(try await provider.hydrate(summary)))
        } catch {
            guard let classified = ProviderError.classify(error) else { throw CancellationError() }
            return (summary.key, .failure(classified))
        }
    }

    /// Failures that concern one change request only: `not found` / `forbidden` (terminal for that CR) and
    /// provider/server, decoding, invalid-request, conflict and unsupported errors (backed off per CR). Auth, rate
    /// limits, offline and timeouts are account-level.
    static func isPerChangeRequestFailure(_ error: ProviderError) -> Bool {
        switch error {
        case .notFound, .forbidden, .server, .decoding, .invalidRequest, .conflict, .unsupported: true
        case .unauthorized, .rateLimited, .offline, .timeout: false
        }
    }
}
