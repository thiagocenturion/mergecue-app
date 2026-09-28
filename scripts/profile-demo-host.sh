#!/usr/bin/env bash
# Profiles the headless demo runtime (real engine, sync, adapters over fixtures, IPC server) with a shortened sync
# cadence and samples its CPU/memory.
#
#   scripts/profile-demo-host.sh [duration-seconds=300] [sync-interval=5] [refresh-every=20]
#
# - Release build of mergecue-demo-host + mergecue-mcp; throwaway MERGECUE_HOME (/tmp/mcprof-XXXXXX), never your data.
# - Every account polls every <sync-interval> s and re-hydrates every change request each cycle (live: 45–300 s,
#   re-hydration only on change / every 10 min); a manual refresh (advances the demo scenario) every
#   <refresh-every> s; `mergecue-mcp --self-test` over the private socket every 15 s.
# - Samples `ps -o rss=,%cpu=` every 5 s, `footprint` at start/end, `leaks` at the end.
# - Prints a Markdown report on stdout (tables + raw samples); diagnostics on stderr.
set -euo pipefail

DURATION="${1:-300}"
SYNC_INTERVAL="${2:-5}"
REFRESH_EVERY="${3:-20}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release (demo host + helper)" >&2
swift build -c release --product mergecue-demo-host >/dev/null
swift build -c release --product mergecue-mcp >/dev/null
BIN="$ROOT/.build/release"

HOME_DIR="$(cd "$(mktemp -d /tmp/mcprof-XXXXXX)" && pwd -P)"
export MERGECUE_HOME="$HOME_DIR"
"$BIN/mergecue-demo-host" --sync-interval "$SYNC_INTERVAL" --refresh-every "$REFRESH_EVERY" \
  >"$HOME_DIR/host.stdout" 2>"$HOME_DIR/host.stderr" &
PID=$!
cleanup() { kill "$PID" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 150); do
  grep -q "demo runtime up" "$HOME_DIR/host.stderr" 2>/dev/null && break
  sleep 0.2
done
grep -q "demo runtime up" "$HOME_DIR/host.stderr" || { echo "demo host did not start" >&2; cat "$HOME_DIR/host.stderr" >&2; exit 1; }
sleep 2

footprint_summary() {
  if command -v footprint >/dev/null; then
    footprint "$1" 2>/dev/null | grep -E "phys_footprint:|phys_footprint_peak:" | sed 's/^ *//' | tr '\n' ' ' || true
  else
    echo "footprint unavailable"
  fi
}

START_FOOTPRINT="$(footprint_summary "$PID")"
SAMPLES="$HOME_DIR/samples.tsv"
echo -e "t_s\trss_kb\tcpu_pct" >"$SAMPLES"
SELFTEST_OK=0
SELFTEST_FAIL=0
T0=$(date +%s)
NEXT_SELFTEST=0
while true; do
  NOW=$(( $(date +%s) - T0 ))
  (( NOW >= DURATION )) && break
  kill -0 "$PID" 2>/dev/null || { echo "demo host exited early" >&2; cat "$HOME_DIR/host.stderr" >&2; exit 1; }
  read -r RSS CPU < <(ps -o rss=,%cpu= -p "$PID")
  echo -e "$NOW\t$RSS\t$CPU" >>"$SAMPLES"
  if (( NOW >= NEXT_SELFTEST )); then
    if "$BIN/mergecue-mcp" --self-test >/dev/null 2>&1; then SELFTEST_OK=$((SELFTEST_OK + 1)); else SELFTEST_FAIL=$((SELFTEST_FAIL + 1)); fi
    NEXT_SELFTEST=$((NOW + 15))
  fi
  sleep 5
done
END_FOOTPRINT="$(footprint_summary "$PID")"
LEAKS_OUT="$HOME_DIR/leaks.txt"
if command -v leaks >/dev/null; then
  leaks "$PID" >"$LEAKS_OUT" 2>&1 || true
  LEAKS_LINE="$(grep -E "Process [0-9]+: [0-9]+ leaks? for" "$LEAKS_OUT" | head -1 || true)"
else
  LEAKS_LINE="leaks unavailable"
fi
DB_BYTES="$(stat -f %z "$HOME_DIR/demo/mergecue.sqlite" 2>/dev/null || echo 0)"
WAL_BYTES="$(stat -f %z "$HOME_DIR/demo/mergecue.sqlite-wal" 2>/dev/null || echo 0)"
kill -TERM "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
trap - EXIT

awk -F'\t' -v dur="$DURATION" -v si="$SYNC_INTERVAL" -v re="$REFRESH_EVERY" \
    -v f0="$START_FOOTPRINT" -v f1="$END_FOOTPRINT" -v leaks="$LEAKS_LINE" \
    -v ok="$SELFTEST_OK" -v bad="$SELFTEST_FAIL" -v db="$DB_BYTES" -v wal="$WAL_BYTES" '
NR == 1 { next }
{ n++; t[n] = $1; rss[n] = $2; cpu[n] = $3; sum += $3; if ($3 > max) max = $3; if ($2 > peak) peak = $2 }
END {
  q = int(n / 4); if (q < 1) q = 1
  for (i = 1; i <= q; i++) first += rss[i]; first /= q
  for (i = n - q + 1; i <= n; i++) last += rss[i]; last /= q
  printf "| Metric | Value |\n| --- | --- |\n"
  printf "| Duration | %d s (%d samples every 5 s) |\n", dur, n
  printf "| Sync cadence | every %d s per account (3 demo accounts), full re-hydration each cycle; manual refresh every %d s |\n", si, re
  printf "| CPU | mean %.2f %%, max %.1f %% (ps %%cpu, one core = 100 %%) |\n", sum / n, max
  printf "| RSS | first quarter mean %.1f MB, last quarter mean %.1f MB, peak %.1f MB |\n", first / 1024, last / 1024, peak / 1024
  printf "| footprint (start) | %s |\n", f0
  printf "| footprint (end) | %s |\n", f1
  printf "| leaks (end) | %s |\n", leaks
  printf "| MCP self-tests over IPC | %d ok, %d failed |\n", ok, bad
  printf "| Demo database at end | %d bytes (+ WAL %d bytes) |\n", db, wal
  printf "\nRaw samples (t s, RSS KB, CPU %%):\n\n```\n"
  for (i = 1; i <= n; i++) printf "%s %s %s\n", t[i], rss[i], cpu[i]
  printf "```\n"
}' "$SAMPLES"
echo "(work dir: $HOME_DIR; leaks output: $LEAKS_OUT)" >&2
