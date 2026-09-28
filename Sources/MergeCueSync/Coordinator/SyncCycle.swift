import Foundation
import MergeCueCore
import MergeCueStore

/// One sync cycle of one account:
/// lists → change detection → bounded hydration → departed CRs → `EventDeriver` → `AttentionDeriver` →
/// `applySyncBatch` (atomic; cursor + events persisted **before** anything is notified) → `NotificationGrouper` →
/// notifier → event handler.
struct SyncCycle {
    struct Outcome: Sendable {
        var isBaseline: Bool
        /// Events inserted by this cycle (deduped by the store), baseline included.
        var insertedEvents: [ChangeEvent]
        var notifications: [GroupedNotification]
        var hydratedCount: Int
        var removedCount: Int
        /// New, still-open attention activity (keeps the account "hot").
        var hadAttentionActivity: Bool
    }

    /// Cursor key prefix for per-CR list versions.
    static let listVersionPrefix = "cr:"
    static let lastCycleKey = "meta:last_cycle_at"

    let account: Account
    let provider: any ReviewProvider
    let environment: SyncEnvironment

    func run() async throws -> Outcome {
        let database = environment.database
        let now = environment.clock.now
        let settings = environment.current
        let configuration = settings.configuration
        let me = account.id.remoteUserID
        let isBaseline = try await !database.hasCompletedInitialSync(account: account.id)

        // 1. Lightweight lists.
        let repositories = try await database.repositories(account: account.id)
        async let authoredPage = provider.listChangeRequests(query(.authored, repositories: repositories))
        async let requestedPage = provider.listChangeRequests(query(.reviewRequested, repositories: repositories))
        async let involvedPage = involvedListing(repositories: repositories, now: now, window: configuration.involvedWindow)
        var pages: [(ChangeRequestScope, ChangeRequestPage)] = [(.authored, try await authoredPage), (.reviewRequested, try await requestedPage)]
        if let involved = try await involvedPage { pages.append((.involved, involved)) }

        // 2. Merge the lists and compare with stored state.
        let storedSnapshots = try await database.snapshots(account: account.id)
        let stored = Dictionary(storedSnapshots.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let storedCursor = try await database.cursor(account: account.id)
        let listed = Self.mergeLists(pages, stored: storedSnapshots)
        let listedKeys = Set(listed.map(\.key))

        var toHydrate: [ChangeRequestSummary] = []
        for summary in listed {
            let version = storedCursor[Self.listVersionPrefix + summary.key.id]
            if Self.needsHydration(
                listed: summary, listVersion: version, stored: stored[summary.key], now: now, configuration: configuration
            ) {
                toHydrate.append(summary)
            }
        }
        let departed = storedSnapshots.filter { !listedKeys.contains($0.key) }.sorted { $0.key.id < $1.key.id }

        // 3. Hydrate changed + departed CRs with bounded concurrency.
        let results = try await Self.hydrate(
            toHydrate + departed.map(\.summary), provider: provider, limit: configuration.hydrateConcurrency
        )

        // 4. Derive events and attention per CR.
        var snapshots: [ChangeRequestSnapshot] = []
        var snapshotMap: [ChangeRequestKey: ChangeRequestSnapshot] = [:]
        var removed: [ChangeRequestKey] = []
        var events: [ChangeEvent] = []
        var upserts: [AttentionItem] = []
        var existingByKey: [String: AttentionItem] = [:]
        var cursor: [String: String] = [Self.lastCycleKey: String(now.timeIntervalSinceReferenceDate)]
        for summary in listed {
            // Keep the previous list version when hydration was skipped or failed, so the CR is retried.
            if let version = storedCursor[Self.listVersionPrefix + summary.key.id] {
                cursor[Self.listVersionPrefix + summary.key.id] = version
            }
        }

        for summary in toHydrate {
            guard case .success(var snapshot)? = results[summary.key] else { continue }
            snapshot.summary.involvement.formUnion(summary.involvement)
            if let token = summary.versionToken { snapshot.summary.versionToken = token }
            let existing = try await database.attentionItems(changeRequest: summary.key)
            for item in existing { existingByKey[item.dedupeKey] = item }
            let derived = EventDeriver.derive(
                previous: stored[summary.key], current: snapshot, currentUserID: me, isBaseline: isBaseline, now: now,
                knownFailingCheckNames: Self.unresolvedFailingCheckNames(snapshot: snapshot, existing: existing)
            )
            upserts += AttentionDeriver.apply(events: derived, snapshot: snapshot, existing: existing, account: account, now: now)
            events += derived
            snapshots.append(snapshot)
            snapshotMap[snapshot.key] = snapshot
            cursor[Self.listVersionPrefix + summary.key.id] = Self.listVersion(summary)
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
        }

        // 5. Persist atomically before anything is announced.
        try Task.checkCancellation()
        let batch = SyncBatch(
            account: account.id,
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

        // 6. Notifications (one per CR), then the rule/event handler.
        var notifications: [GroupedNotification] = []
        let policy = environment.notificationPolicy
        if !isBaseline, policy.allowsDelivery(at: now) {
            notifications = NotificationGrouper.group(
                newEvents: inserted,
                attentionUpserts: upserts,
                existing: existingByKey,
                snapshots: snapshotMap,
                account: account,
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

        let insertedIDs = Set(inserted.map(\.id))
        let hadActivity = !isBaseline && upserts.contains { item in
            item.disposition != .resolved && item.eventIDs.contains(where: insertedIDs.contains)
        }
        return Outcome(
            isBaseline: isBaseline,
            insertedEvents: inserted,
            notifications: notifications,
            hydratedCount: snapshots.count,
            removedCount: removed.count,
            hadAttentionActivity: hadActivity
        )
    }

    private func query(_ scope: ChangeRequestScope, repositories: [Repository]) -> ChangeRequestQuery {
        ChangeRequestQuery(scope: scope, namespaces: account.selectedNamespaces, repositories: repositories)
    }

    /// The involved listing (CRs of others the user reviewed or commented on), when the provider declares it and
    /// the window is on. A failure specific to this additive listing (not found, forbidden, unsupported, decoding)
    /// keeps the stored involved CRs (`notModified`) instead of failing the whole cycle; account-level failures
    /// (auth, rate limit, offline) propagate like the other listings.
    private func involvedListing(repositories: [Repository], now: Date, window: TimeInterval?) async throws -> ChangeRequestPage? {
        guard let window, provider.capabilities.support(for: .listInvolved).isUsable else { return nil }
        var request = query(.involved, repositories: repositories)
        request.updatedSince = now.addingTimeInterval(-window)
        do {
            return try await provider.listChangeRequests(request)
        } catch {
            switch ProviderError.classify(error) {
            case .notFound?, .forbidden?, .unsupported?, .decoding?: return .unchanged
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

    /// Whether a listed CR must be hydrated: new, changed since the last list (version token / updated_at / head /
    /// state / involvement), checks still pending, or the stored snapshot is older than `fullRefreshInterval`.
    static func needsHydration(
        listed: ChangeRequestSummary,
        listVersion stored: String?,
        stored snapshot: ChangeRequestSnapshot?,
        now: Date,
        configuration: SyncConfiguration
    ) -> Bool {
        guard let snapshot else { return true }
        guard let stored, stored == listVersion(listed) else { return true }
        if snapshot.aggregateCheckState == .pending { return true }
        return now.timeIntervalSince(snapshot.fetchedAt) >= configuration.fullRefreshInterval
    }

    /// Check names that have an unresolved CI attention item (their last terminal status was a failure).
    static func unresolvedFailingCheckNames(snapshot: ChangeRequestSnapshot, existing: [AttentionItem]) -> Set<String> {
        let unresolved = Set(existing.filter { $0.reason == .ciFailed && $0.disposition != .resolved }.map(\.dedupeKey))
        guard !unresolved.isEmpty else { return [] }
        return Set(snapshot.checks.map(\.name).filter {
            unresolved.contains(AttentionItem.dedupeKey(changeRequest: snapshot.key, checkName: $0))
        })
    }

    /// Hydrates with at most `limit` concurrent calls. Per-CR `notFound` / `forbidden` are returned as failures
    /// (the CR is skipped or treated as gone); any other failure cancels the rest and is thrown.
    static func hydrate(
        _ summaries: [ChangeRequestSummary], provider: any ReviewProvider, limit: Int
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
                group.addTask { try await hydrateOne(next, provider: provider) }
            }
            while let (key, result) = try await group.next() {
                if case .failure(let error) = result, !isPerChangeRequestFailure(error) {
                    group.cancelAll()
                    throw error
                }
                results[key] = result
                if let next = pending.popFirst() {
                    group.addTask { try await hydrateOne(next, provider: provider) }
                }
            }
            return results
        }
    }

    private static func hydrateOne(
        _ summary: ChangeRequestSummary, provider: any ReviewProvider
    ) async throws -> (ChangeRequestKey, Result<ChangeRequestSnapshot, ProviderError>) {
        do {
            return (summary.key, .success(try await provider.hydrate(summary)))
        } catch {
            guard let classified = ProviderError.classify(error) else { throw CancellationError() }
            return (summary.key, .failure(classified))
        }
    }

    static func isPerChangeRequestFailure(_ error: ProviderError) -> Bool {
        switch error {
        case .notFound, .forbidden: true
        default: false
        }
    }
}
