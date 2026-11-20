# MergeCue

**PRs move forward. You stay in flow.**

MergeCue is a native macOS menu bar app for GitHub, GitLab and Bitbucket pull/merge requests, with a bundled MCP
server (`mergecue-mcp`) that hands review work to the coding agent you already use (Claude Code, Codex CLI). It runs
no model itself. Product brief: `docs/PLAN.md`. Module contract: `docs/ARCHITECTURE.md`. Conventions: `CLAUDE.md`.
Decisions: `DECISIONS.md`.

## Install and run

Requirements: macOS 15 or later, Xcode 26 (Swift 6.3), and optionally `xcodegen` (`brew install xcodegen`) if you
change `project.yml`.

**From Xcode.** Open `MergeCue.xcodeproj`, pick the **MergeCue** scheme and **My Mac**, press **⌘R**. The icon
appears in the menu bar; the Debug scheme passes `--show-window` so the main window opens too. MergeCue is a menu bar
app (`LSUIElement`): it has a Dock icon only while its main window is open.

**From the command line.**

```sh
scripts/build-app.sh [Debug|Release]      # xcodegen + xcodebuild → dist/MergeCue.app, verifies signatures, helper, icon
scripts/run-app.sh [--demo|--preview]     # build Debug and open dist/MergeCue.app (add --menu-bar-only to skip the window)
open dist/MergeCue.app --args --demo --show-window
scripts/test.sh                           # swift build + swift test
swift run mergecue-snapshots              # render every screen (light + dark) to docs/evidence/snapshots/
```

Development builds use the **Apple Development** identity of team `TTSKDZ455K` (manual signing, Hardened Runtime,
no App Sandbox). Releases are signed with **Developer ID Application**, notarized and stapled:

```bash
scripts/release.sh    # -> dist/MergeCue-<version>.zip and .dmg (notarized; opens on any Mac without warnings)
```

It needs the Developer ID certificate in the login keychain and notarization credentials stored once with
`xcrun notarytool store-credentials mergecue` (override with `NOTARY_PROFILE=<name>`). The repo-root `MergeCue.app`
is the latest notarized release build. On another Mac change the team for
both targets (`MergeCue`, `mergecue-mcp`) or build ad-hoc with `SIGNING=adhoc scripts/build-app.sh`. Copy
`dist/MergeCue.app` to `/Applications` to install it; agents are then registered with
`/Applications/MergeCue.app/Contents/MacOS/mergecue-mcp`.

## Live, demo and preview

| Mode | How to start | What you see |
| --- | --- | --- |
| **Live** (default) | plain launch, `--live`, `MERGECUE_BACKEND=live` | Your connected accounts, synced from the providers' APIs; tokens in the Keychain. |
| **Demo** | `--demo`, `MERGECUE_BACKEND=demo`, or Settings ▸ General ▸ **Demo mode** (relaunches) | The real engine, sync and adapters over bundled fixture responses (GitHub, GitLab, Bitbucket), a synthetic local checkout, the real MCP server. Every refresh (⌘R) advances the scenario (new comment + CI failure, then reply + recovery). Always badged **Demo data**. |
| **Preview** | `--preview`, `MERGECUE_BACKEND=preview` (+ `MERGECUE_PREVIEW_VARIANT=standard\|authExpired\|allCaughtUp\|noAccounts`) | In-memory synthetic data for UI review; nothing is stored, sent, launched or posted. Badged **Preview data**. |

Precedence: launch argument › `MERGECUE_BACKEND` › the Demo mode switch › live. Demo data lives in its own folder
(`<data root>/demo`) with in-memory fixture credentials, so switching never touches your accounts; the demo's IPC
socket is the same one the live app uses, so an agent's registered `mergecue-mcp` reaches whichever mode is running.
Only one MergeCue can run at a time: a second copy shows "MergeCue is already running" and quits.

## First launch: the setup assistant

On the first live launch without accounts, the setup assistant opens (later: Settings ▸ General ▸ **Run Setup
Assistant…**). Steps: Welcome → Connect accounts → Repositories → Coding agent → Notifications → Done.

### Connecting accounts

Tokens are stored only in the Keychain (service `dev.mergecue.credentials`), never in the database, logs, MCP output
or screenshots, and the field is cleared as soon as you press Connect. MergeCue validates each token by fetching your
user profile first; a rejected token stores nothing. **Remote writes are off for every new account**; turn them on
per account in Settings ▸ Accounts (only replies and resolving threads, each after you approve an exact preview).

| Provider | Methods | Scopes |
| --- | --- | --- |
| **GitHub.com** | **Use my GitHub CLI login** (runs `gh auth token` once, after you click; requires `gh auth login`), or paste a token (**Create token** opens `github.com/settings/tokens/new?scopes=repo,read:org`). | Classic: `repo`, `read:org`. Fine-grained: Pull requests, Checks, Commit statuses, Contents, Metadata — Read (Pull requests — Read and write only if you enable replies/resolve). |
| **GitLab.com** | Personal access token (+ instance URL, default `https://gitlab.com`; the instance is part of the account identity — self-managed GitLab is not tested). | `read_api`. Add `api` only if you'll enable replies and thread resolution. |
| **Bitbucket Cloud** | Atlassian API token **+ your Atlassian email**, or a workspace/repository **access token**. App passwords are deprecated and not supported. | `read:user:bitbucket`, `read:workspace:bitbucket`, `read:repository:bitbucket`, `read:pullrequest:bitbucket`, `read:pipeline:bitbucket`; `write:pullrequest:bitbucket` only for replies. |

Disconnecting deletes the token from the Keychain and the account's local data (the audit log is kept); revoke the
token on the provider too if you no longer need it.

### Repositories

Map each repository to its local checkout: **Find Checkouts** scans `~/Developer`, `~/Projects`, `~/Code`, `~/src`
and `~/Documents/GitHub` for clones whose remote matches (exact matches are confirmed automatically, probable ones need
**Confirm**), or **Choose Folder…**. Agents work in an isolated git worktree created from the mapped checkout at the
PR/MR head; MergeCue never edits your checkout except when you approve **Apply patch**. Dirty checkouts and GitButler
workspaces are refused for code tasks ("Blocked: map a safe checkout"). The handoff checklist shows whether the
checkout has `AGENTS.md` / `CLAUDE.md` (existence only — your agent reads them itself).

### Registering the MCP server with Claude Code / Codex

Settings ▸ Agents (or the assistant's Coding agent step) detects installed agents and their versions, then:

1. **Review setup…** shows the exact command, the configuration it adds, the file it changes and the backup folder:
   - Claude Code: `claude mcp add --scope user mergecue -- <MergeCue.app>/Contents/MacOS/mergecue-mcp` → `~/.claude.json`
     (`$CLAUDE_CONFIG_DIR/.claude.json`).
   - Codex CLI: `codex mcp add mergecue -- <MergeCue.app>/Contents/MacOS/mergecue-mcp` → `~/.codex/config.toml`
     (`$CODEX_HOME/config.toml`).
   - Backup: `<data root>/backups/<agent>-<timestamp>/` (with a `manifest.json`), made before anything changes.
2. **Register** is your explicit consent; MergeCue runs that command with the agent's own CLI.
3. **Verify** starts the helper like the agent does, runs `tools/list` and one read-only call (`list_attention`). The
   agent shows **Connected** only after this succeeds.

**Copy command** is always available if you prefer to run it yourself; `mergecue-mcp --print-config claude|codex`
prints the same thing, and `mergecue-mcp --self-test` checks that the helper reaches the running app.

### Handing a task to an agent

**Fix now** / **Investigate with AI** / **Draft reply** creates a task. It sits under **In progress** with
**Waiting for agent** until an agent really claims it through MCP; only a claimed task (or one you set to "In
progress" by hand) shows the working spinner. Finished tasks (done, cancelled, dismissed) leave the Tasks list and
are kept under **Tasks ▸ Finished**, grouped by pull request with the day and time each finished. **Open in Claude
Code / Codex** opens a new Terminal window running the agent in the task's worktree with the handoff prompt; **Copy
command** copies the prompt (`Work on MergeCue task mc_…`). When the agent submits, the result review shows the diff,
tests and proposed reply; **Apply reviewed patch**, **Post reply** and **Resolve thread** each show an exact preview
and happen only after you approve it (MergeCue re-reads the PR head and thread right before writing). Request changes,
push and merge are hidden by policy.

### Notifications

The assistant asks macOS for permission (never silently at launch). One grouped notification per PR/MR; clicking it
opens the item in MergeCue. Pause and quiet hours: Settings ▸ Notifications or the popover's bell. **Notify me about**
switches (review comments, CI failures, reviewer questions, review requests, approvals, agent results) are stored by
the engine and only silence alerts of that kind — the items still appear in the inbox.

With Settings ▸ General ▸ **Tracking** set to include PRs/MRs you reviewed or commented on (live accounts track
only your own PRs/MRs by default), they stay tracked after the provider drops your review request (GitHub does once
you submit a review), so replies to your comments still reach the inbox; they show as **Reviewed** in PRs & MRs and
count as **Reviewing** in filters. Only threads you took part in create inbox items.

### How syncing works

MergeCue polls each account on its own schedule, modelled on GitButler (DECISIONS D35, D36):

- **Repositories to watch** (Settings ▸ Accounts ▸ your account): only these repositories are synced. The list
  starts with the repositories you mapped to a local checkout (mapping one in setup or Settings ▸ Repositories adds
  it); add or remove repositories with **Add Repository…** / **Remove**. With nothing watched every repository is
  synced and the account card asks you to pick some. MergeCue never lists your repositories while syncing: the
  picker uses the repository list fetched when you open it (kept for 6 hours).
- **Check for updates** (same card): every 5, 15 (default) or 30 minutes, every hour, or **Manually only**.
  MergeCue never asks a provider for anything on its own more often than that, whatever happens: once per interval
  it lists your PRs/MRs and re-reads the ones that changed or are due. Coming back to MergeCue, waking the Mac or
  getting the network back only runs a check that is overdue. **Refresh** always checks right away. "Manually only"
  checks at launch and on Refresh, nothing else.
- **Details** of each PR/MR are re-read inside those checks only: every check while it changed in the last hour,
  has an agent task, or has CI running; every second check once it has been quiet for an hour. CI still "in
  progress" after 2 hours counts as stuck and stops being re-read every check. A change in the list is picked up at
  the next check. Refresh re-reads what changed, failed PRs/MRs and PRs/MRs with CI still running.
- **Pause Auto-Sync** (menu bar menu, or Settings ▸ Accounts ▸ your account ▸ Automatic sync): pause for an hour,
  until tomorrow 9:00, until Monday 9:00 or until you resume. Rules can pause it on their own and resume it when
  they stop applying: weekends, outside your working hours, and holidays or days off (all-day events of the
  calendars you pick, the macOS Holidays calendar by default; needs Calendar access, read on your Mac only).
  "Sync Anyway" lifts a scheduled pause until it would have ended. Refresh works while paused.
- **Only what changed is fetched again.** Each provider's change indicators decide: Bitbucket `comment_count`,
  `task_count`, `updated_on`, source/destination commits and commit statuses; GitLab `user_notes_count`,
  `updated_at`, head/base commits and the head pipeline; GitHub's one GraphQL query per PR only runs when the PR's
  list entry changed (updated time, head, check rollup). Identity (`/user`, workspaces) is fetched once per session.
  At most three requests per account (two for Bitbucket) are in flight at once, and identical concurrent requests
  are shared.
- **A PR/MR that fails to load** is retried at the next check, two checks later, then every four checks. "Not found" and "no access" stop
  retrying until the PR/MR changes, you press Refresh, or you come back a while later (retried at the next check); the account shows
  "1 PR couldn't be loaded: not found (tap to retry)" and the row says why, so an account never looks empty when its
  PRs failed.

Measured with the real adapters (`SyncRequestCountTests`, fixture data), provider requests including redirects:

| Scenario | First sync | Refresh, nothing changed | Refresh, one new comment |
| --- | --- | --- | --- |
| Bitbucket, 500 repositories, 2 authored PRs, before | 19 | 2 | 10 |
| Bitbucket, same, 2 watched repositories, after | 10 | 1 | 2 |
| Bitbucket with review requests on, before | 520 | 502 | 510 |
| Bitbucket with review requests on, 2 watched, after | 12 | 3 | 4 |
| GitHub fixtures, before / after | 5 / 5 | 1 / 1 | 4 / 4 |
| GitLab fixtures, before / after (1 watched project) | 23 / 21 | 2 / 2 | 12 / 9 |

### Rate limits

- Settings ▸ Accounts shows **N requests in the last hour** per account, redirects included (answers "not modified"
  to conditional requests are free on GitHub and GitLab and not counted; Bitbucket does not document them as free, so
  they count). Above 75 % of a soft budget (GitHub 1500/h, GitLab 1000/h, Bitbucket Cloud 500/h) details refresh
  half as often, above the budget four times less often; the same slowdown applies for 15 minutes when Bitbucket
  says the token is near its limit (`X-RateLimit-NearLimit`).
- When a provider rate-limits an account, MergeCue waits exactly until the reset time the provider sends
  (`Retry-After`, GitHub `x-ratelimit-reset`, GitLab `RateLimit-Reset`); without one it waits until the account's
  own requests of the last hour are well under its budget, at least 5 minutes (then 15, then 60). The account shows
  **Rate limited**, retrying at HH:MM, with the provider and account; other accounts keep syncing.
- Conditional requests (`If-None-Match`) are used for GitLab listings, GitHub REST reads and Bitbucket reads.
  GitHub's PR listing and details use GraphQL, which has no ETags.

## Data locations and reset

| What | Where |
| --- | --- |
| Database, worktrees, handoff scripts, agent-config backups | `~/Library/Application Support/MergeCue/` (`mergecue.sqlite`, `worktrees/`, `handoff/`, `backups/`) |
| Demo data | `~/Library/Application Support/MergeCue/demo/` |
| IPC socket + per-launch token (0700 / 0600) | `~/Library/Application Support/MergeCue/ipc/` (or `/tmp/mergecue-<uid>/` if the path is too long) |
| Logs | `~/Library/Logs/MergeCue/` and the unified log (`log show --predicate 'subsystem == "dev.mergecue"'`) |
| Tokens | Keychain, service `dev.mergecue.credentials` |

Housekeeping: once a day MergeCue prunes history older than 90 days (events, finished tasks' activity and audit,
resolved items of PRs/MRs it no longer tracks) and compacts the database log. Worktrees of finished tasks are kept
until you remove them: after 14 days they are listed in Settings ▸ Data ▸ Housekeeping with a **Clean up** button.

`MERGECUE_HOME=<dir>` moves everything (including logs, under `<dir>/logs`) — handy for trials; agents then need the
same variable. Settings ▸ Data shows the paths, **Export Database…** (a copy without tokens) and **Reset Local
Data…** (deletes every stored token and all local data after a confirmation; checkouts and agent configs are not
touched). Settings ▸ General has **Launch MergeCue at login** (`SMAppService`; available in the app bundle).

## Limitations

Test coverage and the per-provider verification status: `docs/TESTING.md`.

- Live verification so far: GitHub.com via the owner's `gh` login (authentication and sync; the account had no open
  PRs, so threads/checks/writes were verified against fixtures only). GitLab.com and Bitbucket Cloud pass the same
  contract against recorded fixtures (demo) but are **unverified live** until real accounts are connected.
- Hosted services only (GitHub.com, GitLab.com, Bitbucket Cloud). GitHub Enterprise Server, GitLab self-managed and
  Bitbucket Data Center are not tested.
- No "Sign in with browser" (OAuth device flow) yet; tokens or the GitHub CLI.
- Unattended agent execution is not available: rules can create tasks, which wait for you to hand them over.
- Tracking PRs/MRs you only reviewed or commented on is bounded: updated within 30 days; GitHub at most 100 search
  results; GitLab from your latest 100 comment events in up to 20 projects; Bitbucket per repository (selected, or 30
  recently updated ones, open PRs filtered client-side because Bitbucket cannot filter on participants).

### Blocked by access or platform

| Item | Blocked by | State |
| --- | --- | --- |
| GitLab.com live acceptance | No GitLab account/token provided | Adapter complete; fixtures only. |
| Bitbucket Cloud live acceptance | No Bitbucket account/token provided | Adapter complete; fixtures only. |
| GitHub live threads/checks and remote writes (reply/resolve) | The owner's account has no open PRs; live writes to a test PR not yet authorized | Auth + sync verified live; the rest fixture-verified. |
| Provider MCP servers (GitHub, GitLab, Atlassian) alongside MergeCue MCP | Optional; depend on each provider's tier/admin setup, not validated | Not required: agents get PR/CI context through MergeCue MCP. |
| Unattended agent execution (routines / programmatic runs) | No agent runtime entitlement verified; would need owner approval and billing clarity | Rules create tasks that wait for a handoff ("Task ready to start"); never "AI working" without a real claim. |
| GitHub Enterprise Server, GitLab self-managed, Bitbucket Data Center | No instances or access | Not tested. |

## Troubleshooting

- **"MergeCue is already running"** — another copy (maybe a different build) holds the agent socket. Quit it from its
  menu bar icon (or `pkill -x MergeCue`) and open MergeCue again.
- **An account shows Credentials expired / Unsupported permission / Rate limited — retrying at …** — each account
  syncs independently; reconnect it in Settings ▸ Accounts with a token that has the scopes above, or wait for the
  time shown (see "Rate limits"). Offline accounts retry when the network comes back (and after wake).
- **"N PRs couldn't be loaded"** — the PR/MR is listed but its details answer "not found" or "no access" (deleted,
  moved, or the token lacks access to that repository). Click the line (or Retry on the row) after fixing access.
- **The agent says MergeCue isn't running** — run `…/MergeCue.app/Contents/MacOS/mergecue-mcp --self-test`. If you use
  `MERGECUE_HOME`, the agent's helper needs it too. Re-run **Verify** in Settings ▸ Agents.
- **Agent registered with a different command** — the agent points at another `mergecue-mcp` (e.g. an older build).
  Use **Remove existing entry…**, then **Review setup…** again.
- **A task stays Blocked** — map a clean, non-GitButler clone of the repository (Settings ▸ Repositories).
- **Start over** — Settings ▸ Data ▸ Reset Local Data…, or quit and delete `~/Library/Application Support/MergeCue`
  (and the `dev.mergecue.credentials` Keychain items).

## Visual design

The UI follows the owner's mockups in `Design/mockups/` (1 main inbox, 2 menu bar popover, 3 agent handoff,
4 result review): deep navy surfaces in dark mode with a matching light variant, the icon's cyan → blue → violet
gradient for primary actions, and one colour per status. Tokens: `Sources/MergeCueUI/Components/Theme.swift`.

- Menu bar icon: the owner's coloured glyphs in `Design/menubar/` (copied verbatim to `Sources/MergeCueUI/Resources/`
  and the `MenuBarIcon` / `MenuBarIconAlert` image sets; `scripts/make-icons.py --check` verifies the copies and never
  regenerates them). See `Design/README.md`.
- Provider and agent marks come from Simple Icons (CC0 path data); see `Design/THIRD-PARTY-MARKS.md`.
- `swift run mergecue-snapshots` renders the preview screens (`1-…` to `4-…` match the mockups) and an
  `engine-demo-*` set rendered from the real engine in demo mode.

## Project layout and regenerating the Xcode project

All code lives in the SwiftPM package at the repository root (`Package.swift`, `Sources/`, `Tests/`).
`MergeCue.xcodeproj` is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml` and only adds:

- the `MergeCue` app target (`App/`: `@main`, `Info.plist`, entitlements, `Assets.xcassets`), linking the package
  products `MergeCueUI` and `MergeCueRuntime`;
- the `mergecue-mcp` tool target (`Sources/mergecue-mcp`), embedded as `MergeCue.app/Contents/MacOS/mergecue-mcp`.

The UI talks to the engine through `EngineBackend` (`Sources/MergeCueUI/Backend/Engine/`), which implements the
`AppBackend` port over `MergeCueRuntime`; `PreviewBackend` implements the same port with synthetic data.

The project references the root package as a local package (relative path `.`), so the app always builds against the
working tree. Keep one Xcode window on this checkout: don't open `Package.swift` on its own while the project is
open. After changing `project.yml`, run `scripts/generate-project.sh` (not plain `xcodegen generate`: the script
removes a checkout-specific navigator folder so every clone produces the same project) and commit the project;
`scripts/build-app.sh` runs it on every build, and CI fails if the committed project is out of date.
