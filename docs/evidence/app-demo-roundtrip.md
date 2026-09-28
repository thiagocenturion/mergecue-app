# Evidence: the real app (demo mode) serving an agent round trip

Date: 2026-09-28, macOS 26.6, `scripts/build-app.sh Debug` (Apple Development signature, team TTSKDZ455K, Hardened
Runtime). Demo data only (bundled fixtures through the real adapters); no real account, token or Keychain item was
used.

Procedure (a throwaway `MERGECUE_HOME` so the check never touches the owner's data):

1. Seed a task the same way the UI's **Fix with AI** does (`MergeCueEngine.createTask`), using
   `mergecue-demo-host --prepare-task` in the throwaway home, then stop the host (SIGTERM: socket removed).
2. Launch the built app: `open --env MERGECUE_HOME=<home> dist/MergeCue.app --args --demo --show-window`.
3. `dist/MergeCue.app/Contents/MacOS/mergecue-mcp --self-test` against the running app.
4. `mergecue-agent-sim --mcp dist/MergeCue.app/Contents/MacOS/mergecue-mcp --scenario happy --task <id>` against the
   running app (claim → progress → report_changes → report_tests → submit_result), then `get_task` through the
   helper/IPC and a read-only look at the demo database.
5. Check the unified log for errors/faults and crash reports; quit with SIGTERM (what `pkill -x MergeCue` sends) and
   check the IPC socket and token are removed.

The same launch without `MERGECUE_HOME` (default paths, `~/Library/Application Support/MergeCue/ipc/mergecue.sock`)
also passed `--self-test` ("connected to MergeCue 0.1.0 (IPC protocol 1, demo data)").

Remaining log errors are macOS noise seen by every signed app on this machine (`DetachedSignatures` from the code
signature check of the IPC peer requirement, BaseBoard task-port) plus one private-redacted `AppKit:General` line at
window creation; no crash reports.

## Output

```text
## seed (mergecue-demo-host --prepare-task, MERGECUE_HOME=/tmp/mcapp-z4jV9Y)
task mc_lxnova
## launch: open --env MERGECUE_HOME=/tmp/mcapp-z4jV9Y dist/MergeCue.app --args --demo --show-window
pid 54555 (~/Documents/mergecue-app/.claude/worktrees/d-wiring/dist/MergeCue.app/Contents/MacOS/MergeCue --demo --show-window)
## socket
srw-------@  - thiagocenturion 28 Sep 05:55 mergecue.sock
.rw-------@ 64 thiagocenturion 28 Sep 05:55 token
## self-test
[mergecue-mcp] self-test: OK — mergecue-mcp 0.1.0 connected to MergeCue 0.1.0 (IPC protocol 1, demo data) at /tmp/mcapp-z4jV9Y/ipc/mergecue.sock.
## agent-sim happy
exit 0
passed: True task: mc_lxnova server: {'name': 'mergecue', 'protocol_version': '2025-11-25', 'version': '0.1.0'}
  ok  initialize(agent) — server mergecue 0.1.0, MCP protocol 2025-11-25
  ok  tools/list — claim_task, fail_task, get_change_context, get_ci_failure, get_diff, get_task, get_thread,
  ok  get_task — {"artifacts":[],"checkout":{"base_sha":"2323146402b502e63cd9574834e23fb8bced3ca0","gitbutl
  ok  claim_task — {"checkout":{"base_sha":"2323146402b502e63cd9574834e23fb8bced3ca0","gitbutler_managed":fal
  ok  update_task(editing) — {"lease_expires_at":"2026-09-28T05:05:53.564Z","version":4}
  ok  edit file — /tmp/mcapp-z4jV9Y/demo/worktrees/mc_lxnova/mergecue-agent-sim.txt
  ok  report_changes — {"artifact_id":"art_9ff08b07a7","missing_paths":[],"unexpected_paths":[],"verified_changed
  ok  run tests — test -s mergecue-agent-sim.txt && echo ok → exit 0
  ok  report_tests — {"artifact_id":"art_0e154656cf","version":6}
  ok  submit_result — {"state":"ready_for_review","version":7}
  ok  state is ready_for_review — state: ready_for_review
## state via the app's IPC (mergecue-mcp get_task in the sim) and read-only DB check
mc_lxnova|ready_for_review|7
## log errors/faults of pid 54555 (last 2m)
2026-09-28 05:55:45.424 E  MergeCue[54555:fa8a5f] [com.apple.libsqlite3:logging-persist] cannot open file at line 51044 of [f0ca7bba1c]
2026-09-28 05:55:45.424 E  MergeCue[54555:fa8a5f] [com.apple.libsqlite3:logging-persist] os_unix.c:51044: (2) open(/private/var/db/DetachedSignatures) - No such file or d
2026-09-28 05:55:45.556 E  MergeCue[54555:fa8a51] [com.apple.AppKit:General] <private>
2026-09-28 05:55:45.596 E  MergeCue[54555:fa8a80] [com.apple.BaseBoard:Common] Unable to obtain a task name port right for pid 166: (os/kern) failure (0x5)
## app log lines (dev.mergecue / launch)
2026-09-28 05:55:45.393 Df MergeCue[54555:fa8a51] [com.thiagocenturion.MergeCue:launch] Starting MergeCue in demo mode (from launch argument)
2026-09-28 05:55:45.428 Df MergeCue[54555:fa8a5f] [dev.mergecue:runtime] IPC listening at /tmp/mcapp-z4jV9Y/ipc/mergecue.sock; peers: uid + token + anchor apple generic and certificate leaf[subject.OU
## crash reports
(none)
## quit: kill -TERM 54555
process gone
ipc dir after quit:
2026-09-28 05:55:45.428 Df MergeCue[54555:fa8a5f] [dev.mergecue:runtime] IPC listening at /tmp/mcapp-z4jV9Y/ipc/mergecue.sock; peers: uid + token + anchor apple
2026-09-28 05:56:04.099 Df MergeCue[54555:fa8a51] [dev.mergecue:ui] signal 15 received; quitting
2026-09-28 05:56:04.100 Df MergeCue[54555:fa8a51] [dev.mergecue:ui] quitting: stopping the backend
2026-09-28 05:56:04.103 I  MergeCue[54555:fa8df7] [dev.mergecue:ipc] IPC: stopped
2026-09-28 05:56:04.104 I  MergeCue[54555:fa8df7] [dev.mergecue:runtime] runtime (demo) stopped
2026-09-28 05:56:04.113 Df MergeCue[54555:fa8a51] [dev.mergecue:ui] backend stopped; terminating
```
