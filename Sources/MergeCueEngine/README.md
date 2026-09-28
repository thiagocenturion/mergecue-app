# MergeCueEngine

`public actor MergeCueEngine: IPCRequestHandling` — the single façade the UI and the IPC/MCP server use
(docs/ARCHITECTURE.md §8). It depends only on Core, Store and IPC; Sync, providers and the local workspace are
reached through Core protocols injected with `EngineEnvironment`.

```swift
let engine = MergeCueEngine(environment: EngineEnvironment(
    database: db, credentials: keychain, providers: factory, sync: syncCoordinator, workspace: inspector,
    clock: SystemClock(), paths: MergeCuePaths(), isDemo: false, appVersion: "1.0",
    leaseDuration: 600, staleCheckInterval: 30))            // + maxWritesPerTaskPerMinute (30), previewLifetime (600 s),
                                                             //   mappingSearchRoots, ids (IDGenerator)
await engine.start()                                         // rule handler → Sync, stale-lease monitor
let server = IPCServer(paths: paths, handler: engine, peerValidator: validator)
```

UI-facing methods throw `EngineError` (cases mirror the UI's `AppBackendError`: `notFound`, `invalidTransition`,
`writesDisabled(account:)`, `disabledByPolicy`, `unsupported`, `previewExpired`, `invalidInput`, `conflict`,
`provider(ProviderError)`, `failed`). The IPC surface returns `IPCError`s.

## Public API by area

| Area | API |
| --- | --- |
| Lifecycle | `start()`, `stop()`, `changes() -> AsyncStream<EngineChange>` (independent stream per call), `forwardExternalChange(_:)` (the runtime relays Sync's `onChange` into `changes()`), `snapshot() -> EngineSnapshot` (accounts + statuses, attention, tasks with history, CRs, rules, mappings, pause/quiet settings, `isDemo`) |
| IPC / MCP | `handle(method:params:client:)` — every method of §5 (see guarantees below) |
| Accounts | `accountStates() -> [EngineAccountState]`, `connectAccount(AccountConnectionRequest) -> Account`, `disconnectAccount(_:)`, `setAccountLabel(_:label:)`, `setSelectedNamespaces(_:_:)`, `setWritesEnabled(_:_:)`, `availableNamespaces(_:)`, `refresh(account:)` |
| Inbox | `attentionItems(AttentionQuery)` (scope mine/reviewing/all, provider, account, repo, status all/needsAction/unread/withTask/snoozed/done), `markAttentionRead(_:read:)`, `acknowledgeAttention`, `snoozeAttention(_:until:)`, `dismissAttention`, `reopenAttention`, `changeRequests(account:)`, `changeRequest(_:)`, `events(for:)`, `loadCheckLog(_:maxBytes:)`, `loadDiff(_:maxBytes:)`, `reviewChanges(_ taskID)` |
| Tasks | `createTask(fromAttention:type:)`, `tasks(states:)`, `taskDetail(_:)`, `taskDetails(states:)`, `cancelTask`, `dismissTask`, `retryTask`, `unblockTask`, `markTaskDone`, `rejectResult(_:note:)` ("Discard and retry"), `reopenTask`, `cleanupWorktree`, `sweepExpiredLeases()` |
| Checkout | `mappings(repo:)`, `addMapping(repo:repoFullPath:checkoutPath:)`, `confirmMapping(id:)`, `removeMapping(id:)`, `mappingSuggestions(for:searchRoots:)`, `inspectCheckout(path:)`, `prepareCheckout(_ taskID) -> TaskCheckout` |
| Review gate | `previewAction(_ taskID, _ RemoteActionKind) -> ReviewPreview`, `pendingPreviews(for:)`, `perform(previewID:approval: PreviewApproval) -> ActionOutcome`, `declinePreview(previewID:approval:)`; `RemoteWritePolicy` |
| Rules | `rules()`, `ruleTemplates`, `saveRule(_:)`, `addRule(fromTemplate:)`, `deleteRule(id:)`, `setRuleActive(id:active:)`, `describe(_:)`, `handleNewEvents(_:)` (registered as Sync's event handler) |
| Audit | `auditLog(limit:taskID:)` |
| Data | `exportDatabase(to:)`, `resetAllData()`, `pruneHistory(olderThan:)`, `runMaintenanceIfDue()` / `runMaintenance()` / `lastMaintenance()` (daily 90-day retention, run by the lease monitor), `worktreeCleanupCandidates()` / `cleanUpWorktrees(_:)` (finished tasks' worktrees, removed only on the owner's click), `setNotificationsPaused(until:)`, `notificationsPausedUntil()`, `setQuietHours(_:)` (forwarded to Sync), `quietHours()`, `setNotificationPreferences(_:)` / `notificationPreferences()` (per-category alert switches, forwarded to Sync; `EngineEnvironment.notifier` delivers the agent-result alert), `handoff(for:) -> TaskHandoff`, `recordHandoffCopied(_:agentName:)` |

UI command mapping (`AppCommand` → engine): `markRead` → `markAttentionRead`, `acknowledge`, `snooze`,
`dismissAttention`, `createTask` → `createTask(fromAttention:type:)`, `cancelTask`/`retryTask`/`reopenTask`/
`dismissTask`/`unblockTask`/`markTaskDone`/`rejectResult`, `requestActionPreview` → `previewAction`,
`approvePreview` → `perform(previewID:approval:)`, `declinePreview`, `refresh` → `refresh(account:)`,
`pauseNotifications` → `setNotificationsPaused`, `setQuietHours`, `saveRule`, `deleteRule`, `activateRule` →
`setRuleActive`, `connectAccount` (build a `Credential` from the secure field: bearer, or basic email + token for
Bitbucket API tokens), `disconnectAccount`, `setWritesEnabled`, `addMapping`/`confirmMapping`/`removeMapping`,
`copyHandoffCommand` → `handoff(for:)` + `recordHandoffCopied`, `openInAgent` → `handoff(for:).workingDirectory`
(launch via AgentHandoff), `loadCheckLog`. `ReviewPreview` carries every field of the UI's `ActionPreview`
(`isSimulated` = demo mode) plus `taskVersion`, `threadVersion`, `checkoutHeadSHA`, `contentDigest`, `expiresAt`.

## Guarantees

**Tasks.** Created only in `waiting_for_agent`, from an attention item (type = `TaskType.inferred(from:)` unless
overridden) with an immutable origin + trigger snapshot that quotes the exact comment(s) / CI excerpt as bounded,
redacted `UntrustedText` (≤ 4 KiB per comment, root + 9 latest replies; CI ≤ 8 KiB). One active task per attention
item (idempotent, also under concurrent requests); reopening is refused while another task is active. Every state
change goes through `TaskStateMachine` with a compare-and-swap on `version` and appends exactly one activity of the
mapped kind (`claimed`, `result_submitted`, `completed`, `unblocked`, …). Code tasks get a checkout planned at
creation.

**Leases.** `claim_task` requires `expected_version` (two claimers → exactly one wins, the other gets
`version_conflict`), issues `lease_…` valid `leaseDuration` (600 s); heartbeat / update_task / reports renew it.
The monitor (every `staleCheckInterval` of the injected `MCClock`, plus once at `start()`) turns expired `working`
tasks `stale` — never `done` — with "No heartbeat from <agent> since <time> …". Stale tasks can be re-claimed or
retried. An agent write with an expired lease gets `lease_expired` and stales the task immediately.

**MCP writes** (check order): task exists → not terminal (`terminal_state`) → lease (`lease_invalid` /
`lease_expired`) → `expected_version` (`version_conflict`, `data.current_version`) → allowed transition
(`invalid_transition`) → method validation → CAS persist. Also: ≤ 30 writes per task per minute (`rate_limited`,
attempts count whether accepted or not), ≤ 10 `propose_rule` per minute; artifact ids / change refs outside the
task → `cross_scope_reference`; `report_changes` must name the task's isolated worktree (symlinks resolved, `..`
rejected) and changed paths inside it (`path_outside_checkout`), the recorded base SHA (`validation_failed`); the
app recomputes the diff with `WorkspaceInspecting.changes` and stores it as a `diff` artifact (`reported_by:
system`) with verified / unexpected / missing paths. `report_tests` never accepts `passed` with a non-zero exit code
or failures; output is redacted and bounded to 16 KiB. `submit_result` needs a summary, a non-empty diff artifact or
`no_changes_reason` for code tasks, `proposed_reply` for `draft_reply`. Every rejected call naming an existing task
appends a `rejected_call` activity; every rejected mutating call is audited.

**MCP reads.** `get_task` separates trusted `instructions` / `next_steps` (written by MergeCue) from
`trigger.untrusted_content`. Context comes from stored snapshots; `get_ci_failure` and `get_diff` fetch on demand
through the provider (bounded, redacted). `change_ref`s resolve with `ChangeRequestRef.matches`; several matching
accounts → `invalid_params` ("ambiguous change_ref"). `propose_rule` stores an **inactive** `agent_proposal` rule.
`TaskTransitionError.terminalState` → `terminal_state`, other transition errors → `invalid_transition`;
`ProviderError.unsupported` → `unsupported`, `notFound` → `not_found`, `rateLimited` → `rate_limited`, others →
`internal_error` (retryable when the provider error is).

**Checkout.** Mappings are confirmed automatically only for `exact` matches. `prepareCheckout` uses a confirmed
mapping, inspects it, and creates an isolated worktree at the PR head (`fetchHeadSpec`) under
`MergeCuePaths.worktrees`, recording its base SHA. Unmapped / unconfirmed / dirty / detached / GitButler /
unfetchable → policy `blocked` with `"Blocked: map a safe checkout — <reason>"` (mapped path kept for read-only
inspection). `draft_reply` tasks get `read_only`. The engine never modifies the user's checkout except
`apply_patch` after an approved preview.

**Review gate.** Policy: only `apply_patch` (local), `post_reply`, `resolve_thread`; `request_changes`,
`commit_and_push`, `merge` → `disabledByPolicy`. A preview fingerprints (`MergeCueCoding.digest`) task version,
target, content digest, head SHA, thread version and checkout head; it expires after `previewLifetime` and is
single-use. `perform` requires a live preview with a matching fingerprint, an unchanged task in `ready_for_review`,
and for provider writes `Account.writesEnabled` + a usable capability of the account-specific manifest (`ProviderFactory.capabilities(for: Account)`). It records the approval
(`approved_action`), audits `attempted`, then re-fetches fresh state right before writing (`headInfo`, `thread`;
for patches the checkout head/safety and the worktree diff) — any change → `blocked` + `action_blocked` + audit
`rejected`, nothing written. Success → `TaskStateMachine.triggerAfterSuccessfulAction(moreActionsRemain:)` (done
after the last planned action: patch when a diff was reported, reply when one was proposed). Failures →
`ready_for_review` with `lastError` (conflicts → `blocked`), audit `failed`. A fingerprint is performed at most
once (persisted marker + in-flight guard), and an identical reply already on the thread is never posted again.
Declines record an approval with decision `rejected`, a `rejected` activity and a `rejected` audit entry. Claiming,
submitting, copying a handoff command and rule evaluation never write to a provider.

**Rules.** Only the user activates rules. On new events (Sync handler): `RuleEvaluator.decide` (active,
non-baseline, filters, quiet hours, max fires/hour) → `recordRuleFiring` (per-(rule, event) idempotency) →
action. `create_task` creates at most one task per event (setting `engine.event_task.<event id>`), reusing the
attention item's active task; `request_execution` does the same and adds the note
"Unattended execution not available — task ready to start". Identical numbers on different providers are
different events and tasks.

**Accounts.** `connectAccount` probes `currentUser()` with `makeProbe`, saves the credential to the credential
store **first**, then the account (writes off for new accounts; reconnect keeps label/namespaces/writes), then
`sync.accountsDidChange()`. A failed probe or credential save stores nothing. `disconnectAccount` deletes the
credential, then the account's data (cascade); audit entries are kept.

**Data.** `resetAllData` deletes every account credential before recreating the database. Handoff text is the
canonical prompt (`TaskHandoff.command(for:)`), identical to the UI's `HandoffText`; its status is
"Task ready to start" until a real claim.
