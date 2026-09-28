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

Signing uses the **Apple Development** identity of team `TTSKDZ455K` (manual signing, Hardened Runtime, no App
Sandbox; there is no Developer ID certificate yet, so builds are not notarized). On another Mac change the team for
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

**Fix with AI** / **Investigate with AI** / **Draft reply** creates a task that says **Task ready to start** /
**Waiting for agent** until an agent really claims it through MCP — never "AI working" on a guess. **Open in Claude
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

PRs/MRs you reviewed or commented on stay tracked after the provider drops your review request (GitHub does once
you submit a review), so replies to your comments still reach the inbox; they show as **Reviewed** in PRs & MRs and
count as **Reviewing** in filters. Only threads you took part in create inbox items.

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
- Not notarized (no Developer ID certificate): on other Macs, Gatekeeper asks you to confirm the first launch.
- Tracking PRs/MRs you only reviewed or commented on is bounded: updated within 30 days; GitHub at most 100 search
  results; GitLab from your latest 100 comment events in up to 20 projects; Bitbucket per repository (selected, or 30
  recently updated ones).

### Blocked by access or platform

| Item | Blocked by | State |
| --- | --- | --- |
| Notarized direct-download build | No Developer ID Application certificate | Builds are signed with Apple Development (Hardened Runtime) and run locally; Gatekeeper warns elsewhere. |
| GitLab.com live acceptance | No GitLab account/token provided | Adapter complete; fixtures only. |
| Bitbucket Cloud live acceptance | No Bitbucket account/token provided | Adapter complete; fixtures only. |
| GitHub live threads/checks and remote writes (reply/resolve) | The owner's account has no open PRs; live writes to a test PR not yet authorized | Auth + sync verified live; the rest fixture-verified. |
| Provider MCP servers (GitHub, GitLab, Atlassian) alongside MergeCue MCP | Optional; depend on each provider's tier/admin setup, not validated | Not required: agents get PR/CI context through MergeCue MCP. |
| Unattended agent execution (routines / programmatic runs) | No agent runtime entitlement verified; would need owner approval and billing clarity | Rules create tasks that wait for a handoff ("Task ready to start"); never "AI working" without a real claim. |
| GitHub Enterprise Server, GitLab self-managed, Bitbucket Data Center | No instances or access | Not tested. |

## Troubleshooting

- **"MergeCue is already running"** — another copy (maybe a different build) holds the agent socket. Quit it from its
  menu bar icon (or `pkill -x MergeCue`) and open MergeCue again.
- **An account shows Credentials expired / Unsupported permission / Rate limited until …** — each account syncs
  independently; reconnect it in Settings ▸ Accounts with a token that has the scopes above, or wait for the rate
  limit to reset. Offline accounts retry when the network comes back (and after wake).
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
