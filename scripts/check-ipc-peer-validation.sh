#!/usr/bin/env bash
# Signed-build IPC peer validation check (run after scripts/build-app.sh Debug). Launches dist/MergeCue.app --demo in a
# throwaway MERGECUE_HOME, runs the bundled helper (must pass), an ad-hoc re-signed copy and the unsigned SwiftPM
# helper (both must be rejected), then quits only the app it launched (other MergeCue instances are left alone).
# Evidence: docs/evidence/ipc-peer-validation.md.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"
APP=dist/MergeCue.app
H="$(cd "$(mktemp -d /tmp/mcipc-XXXXXX)" && pwd -P)"
echo "home=$H"
OTHERS="$(pgrep -x MergeCue | tr '\n' ' ')"; echo "other MergeCue processes left alone: ${OTHERS:-none}"
echo "--- signatures"
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier|Runtime Version|CodeDirectory)" 
codesign -dvv "$APP/Contents/MacOS/mergecue-mcp" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier|CodeDirectory)"
START="$(date '+%Y-%m-%d %H:%M:%S')"
open -n --env MERGECUE_HOME="$H" "$APP" --args --demo --menu-bar-only
for _ in $(seq 1 100); do [[ -S "$H/ipc/mergecue.sock" ]] && break; sleep 0.2; done
sleep 1
APP_PID="$(pgrep -f "$ROOT/dist/MergeCue.app/Contents/MacOS/MergeCue" | head -1)"
echo "app pid=$APP_PID socket=$(ls -l "$H/ipc/mergecue.sock" 2>&1)"
echo "--- 1. bundled helper (Apple Development, team TTSKDZ455K, id com.thiagocenturion.MergeCue.mcp)"
MERGECUE_HOME="$H" "$APP/Contents/MacOS/mergecue-mcp" --self-test; echo "exit=$?"
echo "--- 2. ad-hoc re-signed copy of the same helper"
cp "$APP/Contents/MacOS/mergecue-mcp" "$H/mergecue-mcp-adhoc"
codesign -f -s - "$H/mergecue-mcp-adhoc" 2>&1
codesign -dvv "$H/mergecue-mcp-adhoc" 2>&1 | grep -E "^(Identifier|Signature|TeamIdentifier|CodeDirectory)"
MERGECUE_HOME="$H" "$H/mergecue-mcp-adhoc" --self-test; echo "exit=$?"
echo "--- 3. unsigned SwiftPM build (linker ad-hoc signature)"
codesign -dvv .build/debug/mergecue-mcp 2>&1 | grep -E "^(Identifier|Signature|TeamIdentifier)"
MERGECUE_HOME="$H" .build/debug/mergecue-mcp --self-test; echo "exit=$?"
echo "--- 4. bundled helper again (the server keeps accepting the legitimate peer after rejections)"
MERGECUE_HOME="$H" "$APP/Contents/MacOS/mergecue-mcp" --self-test; echo "exit=$?"
echo "--- app log (dev.mergecue) since launch"
log show --start "$START" --predicate 'subsystem == "dev.mergecue"' --style compact 2>/dev/null | grep -iE "IPC|peer|reject|unauthor" | sed -E 's#/tmp/mcipc-[A-Za-z0-9]+#<home>#g' | head -20
echo "--- quit (SIGTERM to pid $APP_PID only)"
kill -TERM "$APP_PID"
for _ in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.2; done
kill -0 "$APP_PID" 2>/dev/null && echo "still running" || echo "app exited"
[[ -e "$H/ipc/mergecue.sock" ]] && echo "socket left behind" || echo "socket removed"
