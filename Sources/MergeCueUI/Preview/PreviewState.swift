import Foundation
import MergeCueCore

/// Attention item ids of the preview (derived from their dedupe keys, like Sync does).
nonisolated struct PreviewAttentionIDs {
    var ghPaymentsThread = ""
    var ghPaymentsCI = ""
    var ghRetrySuggestion = ""
    var ghDashboardReview = ""
    var ghNioReady = ""
    var glPaymentsCI = ""
    var glPaymentsSuggestion = ""
    var glLedgerComment = ""
    var glIOSReview = ""
    var glPayments39Review = ""
    var bbPaymentsQuestion = ""
    var bbCheckoutComment = ""
    var bbRiskReview = ""
    var bbCheckoutCI = ""
}

nonisolated extension PreviewWorld {
    /// The full preview state for `variant`.
    func makeState(variant: PreviewVariant) -> AppState {
        let catalog = makeCatalog()
        let (attention, ids) = makeAttention(catalog)
        var items = attention
        var tasks = makeTasks(catalog, ids)
        var accounts = makeAccounts()
        var snapshots = catalog.all

        switch variant {
        case .standard:
            break
        case .authExpired:
            for index in accounts.indices {
                switch accounts[index].kind {
                case .gitlab:
                    accounts[index].status = AccountSyncStatus(account: accounts[index].id, state: .authExpired, lastAttemptAt: ago(minutes: 1),
                                                               lastSuccessAt: ago(hours: 3), consecutiveFailures: 4,
                                                               message: "401 Unauthorized — the token was revoked or has expired")
                case .bitbucketCloud:
                    accounts[index].status = AccountSyncStatus(account: accounts[index].id, state: .offline, lastAttemptAt: ago(minutes: 1),
                                                               lastSuccessAt: ago(minutes: 26), nextRunAt: later(minutes: 1), consecutiveFailures: 3,
                                                               message: "The network connection was lost")
                case .github:
                    break
                }
            }
        case .allCaughtUp:
            for index in items.indices {
                items[index].isUnread = false
                if items[index].isActionable(now: now) { items[index].disposition = .acknowledged }
            }
            tasks = tasks.filter { $0.task.isTerminal }
            for index in accounts.indices {
                accounts[index].status = AccountSyncStatus(account: accounts[index].id, state: .ok, lastAttemptAt: ago(minutes: 1),
                                                           lastSuccessAt: ago(minutes: 1), nextRunAt: later(minutes: 1.5))
            }
        case .noAccounts:
            accounts = []
            items = []
            tasks = []
            snapshots = []
        }

        return AppState(
            accounts: accounts,
            attention: items,
            tasks: tasks,
            changeRequests: snapshots,
            rules: makeRules(),
            mappings: variant == .noAccounts ? [] : makeMappings(catalog),
            agents: makeAgents(),
            notificationsPausedUntil: nil,
            quietHours: QuietHours(start: (22, 0), end: (7, 0), timeZone: .current),
            lastRefreshAt: variant == .noAccounts ? nil : ago(minutes: 2)
        )
    }

    // MARK: Attention

    // swiftlint:disable:next function_body_length
    func makeAttention(_ catalog: PreviewCatalog) -> ([AttentionItem], PreviewAttentionIDs) {
        var ids = PreviewAttentionIDs()
        var items: [AttentionItem] = []

        func add(_ snapshot: ChangeRequestSnapshot, dedupe: String, reason: AttentionReason, summary: String,
                 thread: ThreadKey? = nil, check: CheckKey? = nil, created: Date, updated: Date, unread: Bool,
                 disposition: AttentionDisposition = .open, task: String? = nil) -> String {
            let item = AttentionItem(
                dedupeKey: dedupe, changeRequest: snapshot.key, repoFullPath: snapshot.summary.repository.fullPath,
                title: snapshot.summary.title, reason: reason, summary: summary, thread: thread, check: check,
                eventIDs: ["evt_preview_" + String(AttentionItem.makeID(dedupeKey: dedupe).dropFirst(4))],
                createdAt: created, updatedAt: updated, isUnread: unread, disposition: disposition,
                linkedTaskID: task.map(taskID)
            )
            items.append(item)
            return item.id
        }

        let gh42 = catalog.ghPayments42
        ids.ghPaymentsThread = add(gh42, dedupe: AttentionItem.dedupeKey(thread: gh42.threads[0].key), reason: .changesRequested,
                                   summary: "New blocking comment from @rkoval", thread: gh42.threads[0].key,
                                   created: ago(minutes: 40), updated: ago(minutes: 6), unread: true)
        ids.ghPaymentsCI = add(gh42, dedupe: AttentionItem.dedupeKey(changeRequest: gh42.key, checkName: gh42.checks[0].name), reason: .ciFailed,
                               summary: "ci / unit-tests failed · 2 of 14 tests", check: gh42.checks[0].key,
                               created: ago(minutes: 9), updated: ago(minutes: 9), unread: false, task: PreviewTaskIDs.blocked)
        let gh61 = catalog.ghPayments61
        ids.ghRetrySuggestion = add(gh61, dedupe: AttentionItem.dedupeKey(thread: gh61.threads[0].key), reason: .codeSuggestion,
                                    summary: "Code suggestion from @tkim on RetryPolicy.swift", thread: gh61.threads[0].key,
                                    created: ago(hours: 3), updated: ago(hours: 3), unread: false, task: PreviewTaskIDs.ready)
        let gh318 = catalog.ghDashboard318
        ids.ghDashboardReview = add(gh318, dedupe: AttentionItem.dedupeKey(changeRequest: gh318.key, reason: .reviewRequested),
                                    reason: .reviewRequested, summary: "@jpark requested your review",
                                    created: ago(minutes: 25), updated: ago(minutes: 25), unread: true)
        let gh57 = catalog.ghPayments57
        ids.ghNioReady = add(gh57, dedupe: AttentionItem.dedupeKey(changeRequest: gh57.key, reason: .readyToMerge), reason: .readyToMerge,
                             summary: "Approved by @rkoval · required checks green", created: ago(hours: 2), updated: ago(hours: 2),
                             unread: false, disposition: .acknowledged)

        let gl42 = catalog.glPayments42
        ids.glPaymentsCI = add(gl42, dedupe: AttentionItem.dedupeKey(changeRequest: gl42.key, checkName: gl42.checks[1].name), reason: .ciFailed,
                               summary: "test:integration failed in pipeline #1402981", check: gl42.checks[1].key,
                               created: ago(minutes: 9), updated: ago(minutes: 9), unread: true)
        ids.glPaymentsSuggestion = add(gl42, dedupe: AttentionItem.dedupeKey(thread: gl42.threads[0].key), reason: .codeSuggestion,
                                       summary: "Code suggestion from @priya.n on batch_writer.go", thread: gl42.threads[0].key,
                                       created: ago(hours: 2), updated: ago(hours: 2), unread: false, task: PreviewTaskIDs.stale)
        let gl318 = catalog.glLedger318
        ids.glLedgerComment = add(gl318, dedupe: AttentionItem.dedupeKey(thread: gl318.threads[0].key), reason: .reviewComment,
                                  summary: "@oscar.b: the ledger client error is swallowed", thread: gl318.threads[0].key,
                                  created: ago(hours: 1), updated: ago(minutes: 50), unread: false, task: PreviewTaskIDs.working)
        let gl77 = catalog.glIOS77
        ids.glIOSReview = add(gl77, dedupe: AttentionItem.dedupeKey(changeRequest: gl77.key, reason: .reviewRequested), reason: .reviewRequested,
                              summary: "@sara.l requested your review", created: ago(minutes: 35), updated: ago(minutes: 35), unread: true)
        let gl39 = catalog.glPayments39
        ids.glPayments39Review = add(gl39, dedupe: AttentionItem.dedupeKey(changeRequest: gl39.key, reason: .changesRequested),
                                     reason: .changesRequested, summary: "Changes requested by @priya.n", created: ago(days: 2),
                                     updated: ago(days: 1), unread: false, disposition: .resolved, task: PreviewTaskIDs.done)

        let bb42 = catalog.bbPayments42
        ids.bbPaymentsQuestion = add(bb42, dedupe: AttentionItem.dedupeKey(thread: bb42.threads[0].key), reason: .reviewerQuestion,
                                     summary: "Question from @lucia.m on signature.ts", thread: bb42.threads[0].key,
                                     created: ago(minutes: 2), updated: ago(minutes: 2), unread: true)
        let bb128 = catalog.bbCheckout128
        ids.bbCheckoutComment = add(bb128, dedupe: AttentionItem.dedupeKey(thread: bb128.threads[0].key), reason: .reviewComment,
                                    summary: "New comment from @dchen on PaymentButtons.tsx", thread: bb128.threads[0].key,
                                    created: ago(minutes: 45), updated: ago(minutes: 45), unread: false, task: PreviewTaskIDs.waiting)
        let bb9 = catalog.bbRisk9
        let tomorrowMorning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                                    of: now.addingTimeInterval(86_400)) ?? later(minutes: 1_200)
        ids.bbRiskReview = add(bb9, dedupe: AttentionItem.dedupeKey(changeRequest: bb9.key, reason: .reviewRequested), reason: .reviewRequested,
                               summary: "@nina.w requested your review", created: ago(minutes: 50), updated: ago(minutes: 50),
                               unread: false, disposition: .snoozed(until: tomorrowMorning))
        let bb131 = catalog.bbCheckout131
        ids.bbCheckoutCI = add(bb131, dedupe: AttentionItem.dedupeKey(changeRequest: bb131.key, checkName: bb131.checks[0].name), reason: .ciFailed,
                               summary: "e2e / safari failed · 1 of 38 tests", check: bb131.checks[0].key,
                               created: ago(minutes: 95), updated: ago(minutes: 95), unread: false, task: PreviewTaskIDs.failed)
        return (items, ids)
    }

    // MARK: Accounts

    func makeAccounts() -> [AccountState] {
        let github = Account(id: gh, instance: .githubCom, username: "mona-dev", displayName: "Mona Dev", authMethod: .githubCLIImport,
                             grantedScopes: ["repo", "read:org"], connectedAt: ago(days: 12), isDemo: true)
        let gitlab = Account(id: gl, instance: .gitlabCom, username: "mona-dev", displayName: "Mona Dev", authMethod: .personalAccessToken,
                             grantedScopes: ["read_api"], connectedAt: ago(days: 12), isDemo: true)
        let bitbucket = Account(id: bb, instance: .bitbucketCloud, username: "mona-dev", displayName: "Mona Dev", authMethod: .bitbucketAPIToken,
                                grantedScopes: ["read:pullrequest:bitbucket", "read:repository:bitbucket", "read:pipeline:bitbucket"],
                                connectedAt: ago(days: 12), isDemo: true)
        return [
            AccountState(account: github,
                         status: AccountSyncStatus(account: gh, state: .ok, lastAttemptAt: ago(minutes: 2), lastSuccessAt: ago(minutes: 2),
                                                   nextRunAt: later(minutes: 1.5)),
                         capabilities: Self.manifest(.github)),
            AccountState(account: gitlab,
                         status: AccountSyncStatus(account: gl, state: .rateLimited(until: later(minutes: 20)), lastAttemptAt: ago(minutes: 1),
                                                   lastSuccessAt: ago(minutes: 11), nextRunAt: later(minutes: 20), consecutiveFailures: 1,
                                                   message: "429 Too Many Requests"),
                         capabilities: Self.manifest(.gitlab)),
            AccountState(account: bitbucket,
                         status: AccountSyncStatus(account: bb, state: .ok, lastAttemptAt: ago(minutes: 4), lastSuccessAt: ago(minutes: 4),
                                                   nextRunAt: later(minutes: 1)),
                         capabilities: Self.manifest(.bitbucketCloud)),
        ]
    }

    /// Synthetic capability manifests (the real ones come from the adapters).
    static func manifest(_ kind: ProviderKind) -> CapabilityManifest {
        var entries: [Capability: CapabilitySupport] = Dictionary(uniqueKeysWithValues: Capability.allCases.map { ($0, .supported) })
        switch kind {
        case .github:
            break
        case .gitlab:
            for capability in [Capability.createReply, .resolveThread, .merge] {
                entries[capability] = .requiresWriteAccess(scope: "api")
            }
            entries[.requestChanges] = .partial(note: "GitLab has no request-changes review; MergeCue posts a blocking thread")
        case .bitbucketCloud:
            entries[.createReply] = .requiresWriteAccess(scope: "write:pullrequest:bitbucket")
            entries[.merge] = .requiresWriteAccess(scope: "write:pullrequest:bitbucket")
            entries[.resolveThread] = .partial(note: "Only inline comments can be resolved")
        }
        return CapabilityManifest(provider: kind, entries: entries)
    }

    // MARK: Rules, mappings, agents

    func makeRules() -> [Rule] {
        let proposal = Rule(
            id: "rule_prop_ci_payments", name: "Investigate CI failures on payments-api", isActive: false, origin: .agentProposal,
            eventTypes: [.ciFailed], repoInclude: ["acme/payments-api"], involvement: [.authored],
            action: .createTask(.investigateCI), maxFiresPerHour: 4,
            quietHours: QuietHours(start: (22, 0), end: (7, 0), timeZone: .current), createdAt: ago(minutes: 20)
        )
        let userRule = Rule(
            id: "rule_user_reviews", name: "Notify me about review requests", isActive: true, origin: .user,
            eventTypes: [.reviewRequested], repoInclude: ["acme/**", "acme-platform/**"], involvement: [.reviewRequested],
            action: .notify, maxFiresPerHour: 20, createdAt: ago(days: 10)
        )
        return [proposal, userRule] + RuleTemplates.all
    }

    func makeMappings(_ catalog: PreviewCatalog) -> [RepoMapping] {
        [
            RepoMapping(id: "map_gh_payments", repo: catalog.ghPayments42.summary.repository.key, repoFullPath: "acme/payments-api",
                        checkoutPath: "~/Developer/acme/payments-api", confidence: .exact,
                        matchedRemote: "git@github.com:acme/payments-api.git", confirmedAt: ago(days: 12), createdAt: ago(days: 12)),
            RepoMapping(id: "map_gl_ledger", repo: catalog.glLedger318.summary.repository.key, repoFullPath: "acme-platform/ledger-service",
                        checkoutPath: "~/Developer/ledger-service", confidence: .exact,
                        matchedRemote: "git@gitlab.com:acme-platform/ledger-service.git", confirmedAt: ago(days: 12), createdAt: ago(days: 12)),
            RepoMapping(id: "map_bb_checkout", repo: catalog.bbCheckout128.summary.repository.key, repoFullPath: "acme/checkout-web",
                        checkoutPath: "~/Developer/checkout-web", confidence: .probable,
                        matchedRemote: "https://bitbucket.org/acme/checkout-web.git", createdAt: ago(days: 3)),
        ]
    }

    func makeAgents() -> [DetectedAgent] {
        [
            DetectedAgent(name: "Claude Code", kind: .claudeCode, version: "2.1.283", path: "~/.local/bin/claude",
                          mcpRegistration: .registered(verifiedAt: ago(days: 1))),
            DetectedAgent(name: "Codex CLI", kind: .codex, version: "0.153.4", path: "/usr/local/bin/codex",
                          mcpRegistration: .notRegistered, canOpenTasks: false),
        ]
    }
}
