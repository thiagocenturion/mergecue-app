# Performance profile — headless runtime, shortened sync cadence

Date: 2026-09-28, macOS 26.6.2, Apple silicon (14 cores), release build of `mergecue-demo-host` + `mergecue-mcp`.
Command: `scripts/profile-demo-host.sh 300 5 20` (throwaway `MERGECUE_HOME=/tmp/mcprof-XXXXXX`; never the owner's
data). **Demo data** — the real engine, Sync, adapters and IPC server over the bundled provider fixtures.

Load, compared with the app's live defaults:

| | Profile run | Live default |
| --- | --- | --- |
| Poll per account | every **5 s** (3 accounts: GitHub, GitLab, Bitbucket) | 90 s (45 s hot, 300 s idle overnight) |
| Re-hydration | **every CR every cycle** (`fullRefreshInterval = 0`) | only changed CRs, or every 10 min |
| Involved listing | on (all three adapters) | on |
| Manual refresh (advances the demo scenario) | every 20 s | on demand |
| MCP helper `--self-test` over the private socket | every 15 s | when an agent connects |

That is roughly 18–60× the live request volume, so the numbers below are an upper bound for the idle app.

Sampling: `ps -o rss=,%cpu=` every 5 s; `footprint` at start and end; `leaks` at the end.

## Finding and fix

The first run showed RSS growing linearly (first-quarter mean 24.6 MB → peak 29.8 MB in 5 minutes, footprint 10 → 16 MB, ~1.2 MB/min):

| Run | CPU mean / max | RSS first ¼ → last ¼ (peak) | footprint start → end | leaks |
| --- | --- | --- | --- | --- |
| 1 (before) | 3.65 % / 17.2 % | 24.6 → 29.0 MB (peak 29.8 MB), rising steadily | 10 → 16 MB | 3 objects / 480 bytes |

Cause: the demo transport (`StubTransport`) recorded **every** request forever (tests assert on the recording;
the demo only needs the writes for `providerWrites`). Demo mode only — the live app uses `URLSessionTransport`,
which records nothing. Fix (DECISIONS D28): `StubTransport.RecordingPolicy`; the demo keeps every provider write and
only the latest 200 reads per provider. Test: `StubTransportTests › boundedRecordingKeepsWritesAndOnlyRecentReads`.

## Result after the fix

| Metric | Value |
| --- | --- |
| Duration | 300 s (60 samples every 5 s) |
| Sync cadence | every 5 s per account (3 demo accounts), full re-hydration each cycle; manual refresh every 20 s |
| CPU | mean 2.96 %, max 33.5 % (ps %cpu, one core = 100 %) |
| RSS | first quarter mean 24.4 MB, last quarter mean 25.7 MB, peak 25.8 MB |
| footprint (start) | phys_footprint: 10 MB phys_footprint_peak: 11 MB  |
| footprint (end) | phys_footprint: 11 MB phys_footprint_peak: 12 MB  |
| leaks (end) | Process 49419: 3 leaks for 480 total leaked bytes. |
| MCP self-tests over IPC | 20 ok, 0 failed |
| Demo database at end | 528384 bytes (+ WAL 403792 bytes) |

RSS rises during warm-up (first ~100 s: caches, link registries, SQLite page cache, the ETag caches filling up to
their fixed URL set) and is **flat afterwards** (25.6–25.8 MB from t = 100 s to 300 s); footprint ends at 11 MB. The
`leaks` report is the same 3 objects / 480 bytes in a 40 s run and in both 5-minute runs (one `Swift.StringStorage`
root with its breadcrumbs — a one-time allocation, not growth). CPU spikes (up to 33 % of one core for one sample)
coincide with the manual refresh that advances the demo scenario (it moves the synthetic repository's head with
`git`); the steady state at a 5 s cadence averages ~3 % of one core.

Bounded growth, by design:

| Store | Bound |
| --- | --- |
| SQLite history | Daily retention (90 days) + WAL truncate (`runMaintenanceIfDue`, DECISIONS D27). The WAL here peaked at ~4 MB (SQLite's 1000-page auto-checkpoint) before retention ran. |
| ETag caches | Per API client: 512 URLs / 32 MiB (`ETagCache`). |
| Link registries / directories | Keyed by repository / thread / check id (bounded by tracked data). |
| Demo stub recording | Writes + latest 200 reads per provider (D28). |
| Handoff scripts | Pruned by `AgentLauncher` on each launch. |
| Task worktrees | Listed for owner-confirmed cleanup after 14 days (Settings ▸ Data). |

Raw samples after the fix (t s, RSS KB, CPU %):

```
0 23360 0.5
5 23840 0.7
10 23952 1.1
15 23984 0.0
20 24720 0.0
25 24656 0.1
30 25296 0.3
35 25296 0.3
40 25472 0.7
45 25456 1.3
50 25536 2.1
55 25536 3.7
60 25760 1.4
65 25728 1.0
70 25808 2.9
75 25872 6.3
81 25968 33.5
86 25552 0.5
91 25744 0.8
96 26016 2.1
101 26224 25.1
106 26192 15.1
111 26176 4.2
116 25872 0.7
121 25984 1.5
126 25888 0.1
131 26096 1.4
136 26224 0.1
141 26256 0.7
146 26224 2.2
151 26128 4.0
156 26256 0.4
161 26192 0.9
166 26320 3.0
171 26304 0.2
176 26304 0.4
181 26304 0.9
186 26368 2.3
191 26336 4.6
196 26304 7.1
201 26336 0.4
206 26336 1.1
211 26304 3.2
216 26336 8.1
221 26272 0.3
226 26400 0.2
231 26352 0.6
236 26304 1.5
241 26336 3.7
246 26400 1.8
251 26352 0.3
256 26368 0.9
261 26272 1.6
266 26400 4.8
271 26288 1.2
276 26336 3.4
281 26368 7.8
287 26432 0.1
292 26384 0.5
297 26432 1.6
```
