# MergeCue — test coverage and verification status

`scripts/test.sh` builds every SwiftPM target and runs the whole suite (Swift Testing; deterministic, no network, no
real Keychain, throwaway `MERGECUE_HOME`). Provider behaviour is tested against **provider-native fixture JSON**
served by `StubTransport` through the real adapters (`Sources/MergeCueFixtures/Resources/<provider>/`); nothing in
this suite talks to a real provider. Live checks and real agent runs are separate, opt-in and recorded under
`docs/evidence/`.

| Command | What it proves |
| --- | --- |
| `scripts/test.sh` | Everything below except the opt-in live read (1,050+ tests, ~20 s). |
| `MERGECUE_LIVE_GITHUB=1 swift test --filter LiveGitHubReadTests` | Live GitHub.com read through the owner's `gh` login (read only) → `docs/evidence/live-github-read.md`. |
| `scripts/e2e-real-agent.sh claude\|codex\|sim` | Real agent MCP round trip against the headless demo host → `docs/evidence/agent-roundtrip-*.md`. |
| `scripts/profile-demo-host.sh [seconds] [sync-interval]` | CPU / memory / leaks of the runtime under a shortened sync cadence → `docs/evidence/performance.md`. |
| `swift run mergecue-snapshots` | Every screen rendered light + dark (preview and real-engine demo data) → `docs/evidence/snapshots/`. |

## Plan §11 test matrix → coverage

Test names are `Suite file › test`; all run in `scripts/test.sh`.

| Scenario (plan §11) | Expected | Covered by |
| --- | --- | --- |
| New comment, then repeated polling and relaunch | Exactly one item + one notification; replies stay in the thread | `MergeCueSyncTests/SyncCoordinatorTests › newCommentAcrossPollsAndRelaunchIsExactlyOnce`, `› repliesStayInTheSameThreadItemAndReopenIt`; all three providers end to end: `IntegrationTests/DemoScenarioIntegrationTests › baselineThenNewActivityThenRelaunch`; store dedupe: `MergeCueStoreTests/SyncBatchTests` |
| Same repo name and `#42` / `!42` on different providers | Separate ids, tasks, notifications, rules, links | `SyncCoordinatorTests › samePRNumberOnThreeProvidersStaysSeparate`; `MergeCueEngineTests/ReadAndRuleTests › "Identical #42 / !42 across providers…"`; identity: `MergeCueCoreTests/IdentityTests`, `ChangeRequestRefTests`; fixtures use CR 42 on all three providers |
| GitHub review comment vs issue comment; GitLab `id` vs `iid` | Correct thread association and API calls | `GitHubAdapterTests/ListingAndHydrateTests › threadKindsAndIDsAreDistinct`, `WritesAndLinksTests › diffThreadReplyUsesRepliesEndpointWithRootComment`, `› conversationAndReviewSummaryRepliesAreIssueComments`; `GitLabAdapterTests/GitLabParsingTests › authoredListingPaginatesAndKeepsIDAndIIDApart`; `EventDeriverTests` (namespaced object ids) |
| One provider fails auth or hits rate limits | Others keep syncing with independent status | `MergeCueSyncTests/SyncResilienceTests › accountFailuresAreIndependent`, `› missingCredentialIsAuthExpired`, `› forbiddenListingIsPermissionDenied`; `MergeCueNetworkingTests/RetryTests`, `RateLimitParserTests` |
| GitHub fork / GitLab MR from another project | Worktree fetches the real source head or blocks | `WorkspaceInspectorTests/WorktreeTests › forkHeadIsFetchedDirectlyFromItsURL`, `› shaMismatchIsRejectedAndCleanedUp`; `GitHubAdapterTests/WritesAndLinksTests › fetchHeadSpecUsesBaseRepositoryEvenForForks`; `GitLabAdapterTests/GitLabHydrateTests › crossProjectMergeRequestUsesSourceAndTargetProjects`; `BitbucketCloudAdapterTests/HydrationTests › forkPullRequestUsesTheForkForFetchingAndSkipsPipelines` |
| User's own reply and green CI rerun | No spurious notification | `SyncCoordinatorTests › ownReplyAndGreenRerunAreQuiet`; `NotificationGrouperTests › baselineAndOwnEventsAreSilent`, `› recoveryIsSilent`; `EventDeriverTests › greenRerunsProduceNothing` |
| Check fails, then retried successfully | Current state updates; history accurate | `SyncCoordinatorTests › failedCheckRetriedSuccessfullyRecovers`; `EventDeriverTests › failurePendingSuccessRecoversWithHistory`; `AttentionDeriverTests › recoveryResolvesCheckItem` |
| Force-push changes head / diff positions | Stale links and patch flagged before apply/push | `SyncCoordinatorTests › forcePushReportsHeadChangeAndOutdatedAnchors`; `MergeCueEngineTests/LifecycleTests › "Head moved after the preview…"`, `› "Stale head also blocks applying the patch…"`; `IntegrationTests/FullLoopIntegrationTests › staleHeadBlocksTheWrite` |
| Handoff command copied, never executed | Stays `Waiting for agent` | `LifecycleTests › "Handoff command copied but never executed…"`; `MergeCueUITests/PresentationTests › trackerShowsAIWorkingOnlyWithAClaim` |
| Agent claims, crashes / stops updating | `Working` → `Stale` after lease expiry, retry | `LifecycleTests › "Agent claims, then crashes…"`; `IntegrationTests/AgentScenarioIntegrationTests › crashAfterClaimTurnsStaleAfterTheLease` (real `mergecue-mcp` over IPC) |
| Two agents claim the same task | One versioned lease wins | `LifecycleTests › "Two agents claim the same task…"`; `AgentScenarioIntegrationTests › doubleClaimYieldsOneLease`; `MergeCueMCPServerTests/AgentSimTests` |
| Reviewer injects hostile instructions | Quoted untrusted data; no unauthorized writes | `LifecycleTests › "Hostile reviewer comment…"`; `AgentScenarioIntegrationTests › hostileCommentStaysQuotedData`; `BitbucketCloudAdapterTests/HydrationTests › hostileCommentIsCarriedVerbatimAsData`; MCP tool descriptions: `MergeCueMCPServerTests/ToolCatalogTests` |
| Wrong / dirty checkout, GitButler workspace | No direct edit/import; isolated worktree or remediation | `LifecycleTests › "Wrong / dirty / GitButler checkouts are blocked…"`; `WorkspaceInspectorTests/ChangesAndPatchTests › gitButlerWorkspaceIsNeverWritten`, `› dirtyCheckoutIsRefusedWithPaths`; `WorktreeTests › gitButlerCheckoutGetsAnIndependentClone`, `› dirtyCheckoutStaysUntouchedWhilePreparing` |
| Credentials expire, 429, network lost | Last known state, accurate sync time, backoff, recovery | `SyncResilienceTests › networkRecoveryRefreshesAccounts`, `› serverErrorsBackOffAndRecover`; `NotificationGrouperTests › rateLimitWaitsForResetAndAuthStops`, `› backoffIsExponentialAndCapped`; `RetryTests › longRetryAfterSurfacesRateLimitedWithoutSleeping`, `› offlineGetEventuallyThrowsOffline` |
| Owner rejects patch or remote action | No PR write; history records it | `LifecycleTests › "Owner declines a preview or discards the result…"`; `MergeCueUITests/CommandRoutingTests › staleApprovalsAreRejected` |
| App quit while the MCP process starts | Clear unavailable error; nothing fabricated | `AgentScenarioIntegrationTests › helperReportsAppUnavailableWhenTheAppIsNotRunning`; `MergeCueIPCTests/IPCSecurityTests › appUnavailableWhenNothingIsRunning`; `MergeCueMCPServerTests/StdioProtocolTests`; app-level check in `docs/evidence/app-demo-roundtrip.md` |

Additional coverage added after the matrix:

| Scenario | Covered by |
| --- | --- |
| Replies to the user's review comment after GitHub drops the review request (involved scope) | `MergeCueSyncTests/InvolvedScopeTests` (all), adapter queries: `ListingAndHydrateTests › involvedListingSearchesInvolvesButNotAuthored`, `GitLabParsingTests › involvedListingUsesOwnCommentEventsThenProjectIIDs`, `ListingTests › involvedUsesPerRepositoryParticipantBBQL` |
| "Notify me about" switches gate alerts per category, items unaffected | `NotificationGrouperTests › switchedOffCategoriesAreSilentPerReason`, `› reviewRequestsAndApprovalsFollowTheirSwitches`; `SyncCoordinatorTests › notificationPreferencesAndGlobalQuietHoursFilterAlertsOnly`; `AccountsInboxDataTests › notificationPreferences`, `› agentResultAlertIsGated`; `EngineBackendTests › accountsRulesMappingsAndSettings` |
| Retention and worktree cleanup (bounded growth) | `MergeCueEngineTests/MaintenanceTests` (all), `MergeCueStoreTests/MaintenanceTests › pruneHistory…` |
| IPC peer authentication | `MergeCueIPCTests/IPCSecurityTests` (uid, token, code requirement), signed build: `docs/evidence/ipc-peer-validation.md` |
| Sidebar labels never truncated at the default width | `MergeCueUITests/SidebarLayoutTests` |

## Per-provider parity (plan §5 "Provider parity gate")

"Fixture" = the real adapter parsing recorded provider-native JSON (plus the real engine/sync above it); it proves
parsing and flow logic, **not** that the live service behaves the same.

| Gate item | GitHub.com | GitLab.com | Bitbucket Cloud |
| --- | --- | --- | --- |
| Account connection (token probe, scopes) | **Live verified** (owner's `gh` login, `live-github-read.md`) + fixtures | Fixtures only | Fixtures only |
| List mine / reviewing / involved | **Live verified** (listing ran; the account had 0 open PRs) + fixtures | Fixtures only | Fixtures only |
| Threads with full replies | Fixtures only (no open PRs on the live account) | Fixtures only | Fixtures only |
| Failed CI / check + log excerpt | Fixtures only | Fixtures only | Fixtures only |
| Event → attention → task handoff | Fixtures + real agents (below) | Fixtures (demo) | Fixtures (demo) |
| Provider deep links | Fixtures (`WritesAndLinksTests › deepLinks`) | Fixtures (`deepLinksPointAtExactItems`) | Fixtures (`SupportTests › deepLinksPointAtTheExactBitbucketItem`) |
| Read/unread persistence, restart | Store + sync tests (provider-neutral) | same | same |
| Diff / test review, approval gate | Engine + `FullLoopIntegrationTests` (provider-neutral, fixtures) | same | same |
| Reply / resolve writes | Fixtures only; **live writes not authorized** by the owner | Fixtures only | Fixtures only |
| Live status | **Auth + sync verified live**; threads/checks unverified live (no open PRs) | **Unverified live** until the owner connects an account | **Unverified live** until the owner connects an account |

Real agents (demo data, session-only MCP config, agent configs fingerprinted unchanged):

| Agent | Result | Evidence |
| --- | --- | --- |
| Claude Code 2.1.283 | get_task → claim → report_changes → report_tests → submit_result, `ready_for_review`, 0 provider writes | `docs/evidence/agent-roundtrip-claude.md` |
| Codex CLI 0.153.4 | same | `docs/evidence/agent-roundtrip-codex.md` |
| Agent simulator (plumbing) | same, scripted | `docs/evidence/agent-roundtrip-sim.md` |
| Signed app + bundled helper | self-test + simulator round trip against the real app | `docs/evidence/app-demo-roundtrip.md` |

## Other evidence

| File | Content |
| --- | --- |
| `docs/evidence/performance.md` | Headless runtime under a 5 s sync cadence: CPU, RSS, footprint, leaks, database size. |
| `docs/evidence/ipc-peer-validation.md` | Signed Debug app: bundled helper accepted, ad-hoc re-signed and unsigned helpers rejected. |
| `docs/evidence/snapshots/` | Visual QA of every screen (light/dark). |
| `docs/evidence/icon-verification.json` | App icon sizes derived from the approved asset. |
