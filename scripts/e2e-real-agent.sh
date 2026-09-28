#!/usr/bin/env bash
# Real agent round trip against a headless MergeCue **demo** host (fixture data, synthetic throwaway repository).
#
#   scripts/e2e-real-agent.sh claude|codex|sim [--keep]
#
# 1. Builds the package and starts `mergecue-demo-host --prepare-task` with a throwaway MERGECUE_HOME
#    (/tmp/mce2e-XXXXXX): demo runtime + private IPC socket, fixture step 1 (a new blocking review comment on
#    GitHub #42), a task created from it with an isolated worktree of the synthetic acme/payments-api checkout.
# 2. Runs the agent non-interactively in that worktree with ONLY the MergeCue MCP server, configured for this run
#    only (Claude: --mcp-config <tmp json> --strict-mcp-config; Codex: -c mcp_servers.mergecue.* overrides with
#    --ignore-user-config --ephemeral). ~/.claude.json and ~/.codex/config.toml are never edited by this script;
#    their MCP server entries are fingerprinted before/after to prove it.
#    `sim` runs mergecue-agent-sim instead (free dry run of the plumbing).
# 3. Stops the host (final task state, activities, artifacts, provider writes → host-final.json) and writes a
#    redacted evidence report to docs/evidence/agent-roundtrip-<agent>.md (+ .transcript.jsonl).
#
# Each real run uses the owner's agent subscription quota: run it deliberately.
set -euo pipefail

AGENT="${1:-}"
KEEP="${2:-}"
case "$AGENT" in
  claude|codex|sim) ;;
  *) echo "usage: $0 claude|codex|sim [--keep]" >&2; exit 64 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
CODEX_BIN="${CODEX_BIN:-/Applications/ChatGPT.app/Contents/Resources/codex}"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-1200}"

echo "==> swift build" >&2
swift build >/dev/null
BIN="$ROOT/.build/debug"
for product in mergecue-demo-host mergecue-mcp mergecue-agent-sim; do
  [[ -x "$BIN/$product" ]] || { echo "missing $BIN/$product" >&2; exit 1; }
done

E2E_HOME="$(cd "$(mktemp -d /tmp/mce2e-XXXXXX)" && pwd -P)"
export MERGECUE_HOME="$E2E_HOME"
unset MERGECUE_SOCKET || true
echo "==> throwaway MERGECUE_HOME: $E2E_HOME" >&2

HOST_PID=""
cleanup() {
  if [[ -n "$HOST_PID" ]] && kill -0 "$HOST_PID" 2>/dev/null; then
    kill -TERM "$HOST_PID" 2>/dev/null || true
    wait "$HOST_PID" 2>/dev/null || true
  fi
  if [[ "$KEEP" != "--keep" ]]; then rm -rf "$E2E_HOME"; fi
}
trap cleanup EXIT

# Fingerprints of the agents' persistent MCP configuration (must not change).
config_fingerprint() {
  /usr/bin/python3 - <<'PY'
import hashlib, json, os
home = os.path.expanduser("~")
out = {}
try:
    with open(os.path.join(home, ".claude.json")) as f:
        data = json.load(f)
    servers = data.get("mcpServers", {})
    out["claude_user_mcpServers"] = hashlib.sha256(json.dumps(servers, sort_keys=True).encode()).hexdigest()[:16]
    out["claude_user_mcpServer_names"] = sorted(servers.keys())
except FileNotFoundError:
    out["claude_user_mcpServers"] = "absent"
try:
    with open(os.path.join(home, ".codex", "config.toml"), "rb") as f:
        out["codex_config_toml"] = hashlib.sha256(f.read()).hexdigest()[:16]
except FileNotFoundError:
    out["codex_config_toml"] = "absent"
print(json.dumps(out, sort_keys=True))
PY
}
BEFORE_CONFIG="$(config_fingerprint)"

echo "==> starting mergecue-demo-host" >&2
"$BIN/mergecue-demo-host" --prepare-task >"$E2E_HOME/host.out" 2>"$E2E_HOME/host.err" &
HOST_PID=$!
for _ in $(seq 1 120); do
  [[ -s "$E2E_HOME/host-ready.json" ]] && break
  kill -0 "$HOST_PID" 2>/dev/null || { cat "$E2E_HOME/host.err" >&2; exit 1; }
  sleep 0.5
done
[[ -s "$E2E_HOME/host-ready.json" ]] || { echo "host did not become ready" >&2; cat "$E2E_HOME/host.err" >&2; exit 1; }

read_ready() { /usr/bin/python3 -c "import json,sys; print(json.load(open('$E2E_HOME/host-ready.json'))['$1'])"; }
TASK_ID="$(read_ready task_id)"
WORKTREE="$(read_ready worktree)"
PROMPT="$(read_ready handoff)"
# The handoff code is only in the prompt (get_task never reveals it); the simulator reads it from there like an agent.
HANDOFF_CODE="$(printf '%s' "$PROMPT" | sed -n 's/.*(handoff code: \([A-Za-z0-9-]*\)).*/\1/p')"
echo "==> task $TASK_ID, worktree $WORKTREE" >&2
echo "==> prompt: $PROMPT" >&2

TRANSCRIPT="$E2E_HOME/transcript.jsonl"
AGENT_ERR="$E2E_HOME/agent.err"
STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

run_with_timeout() {
  "$@" &
  local pid=$!
  ( sleep "$AGENT_TIMEOUT"; kill -TERM "$pid" 2>/dev/null ) &
  local watchdog=$!
  local status=0
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$status"
}

AGENT_STATUS=0
AGENT_VERSION=""
case "$AGENT" in
  claude)
    AGENT_VERSION="$("$CLAUDE_BIN" --version 2>/dev/null || true)"
    MCP_JSON="$E2E_HOME/mcp-session.json"
    /usr/bin/python3 - "$MCP_JSON" "$BIN/mergecue-mcp" "$E2E_HOME" <<'PY'
import json, sys
path, helper, home = sys.argv[1:4]
config = {"mcpServers": {"mergecue": {"type": "stdio", "command": helper, "args": [], "env": {"MERGECUE_HOME": home}}}}
with open(path, "w") as f:
    json.dump(config, f, indent=2)
PY
    COMMAND=("$CLAUDE_BIN" -p "$PROMPT" --mcp-config "$MCP_JSON" --strict-mcp-config
      --allowedTools "mcp__mergecue__*" Edit Write Read Bash
      --permission-mode acceptEdits --output-format stream-json --verbose --no-session-persistence)
    (cd "$WORKTREE" && run_with_timeout "${COMMAND[@]}") >"$TRANSCRIPT" 2>"$AGENT_ERR" || AGENT_STATUS=$?
    ;;
  codex)
    # Codex persists a trust entry for the repository root it runs in; pre-trust the throwaway paths for this run
    # only (-c) so it has nothing to persist, and remove any entry it still adds (see below).
    WORKTREE_REAL="$(cd "$WORKTREE" && pwd -P)"
    CHECKOUT="$(cd "$WORKTREE" && cd "$(git rev-parse --git-common-dir)/.." && pwd -P)"
    AGENT_VERSION="$("$CODEX_BIN" --version 2>/dev/null || true)"
    COMMAND=("$CODEX_BIN" exec --json --ephemeral --ignore-user-config --skip-git-repo-check
      -s workspace-write -C "$WORKTREE"
      -c "mcp_servers.mergecue.command=\"$BIN/mergecue-mcp\""
      -c "mcp_servers.mergecue.args=[]"
      -c "mcp_servers.mergecue.env={MERGECUE_HOME=\"$E2E_HOME\"}"
      -c "projects.\"$CHECKOUT\".trust_level=\"trusted\""
      -c "projects.\"$WORKTREE_REAL\".trust_level=\"trusted\""
      ${CODEX_EXTRA:-}
      "$PROMPT")
    (cd "$WORKTREE" && run_with_timeout "${COMMAND[@]}" </dev/null) >"$TRANSCRIPT" 2>"$AGENT_ERR" || AGENT_STATUS=$?
    ;;
  sim)
    AGENT_VERSION="mergecue-agent-sim (scenario happy)"
    COMMAND=("$BIN/mergecue-agent-sim" --mcp "$BIN/mergecue-mcp" --scenario happy --task "$TASK_ID")
    if [[ -n "$HANDOFF_CODE" ]]; then COMMAND+=(--handoff-code "$HANDOFF_CODE"); fi
    run_with_timeout "${COMMAND[@]}" >"$TRANSCRIPT" 2>"$AGENT_ERR" || AGENT_STATUS=$?
    ;;
esac
FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "==> agent exited with status $AGENT_STATUS" >&2

# Let the last state land, then stop the host (writes host-final.json, removes the socket).
sleep 1
kill -TERM "$HOST_PID" 2>/dev/null || true
wait "$HOST_PID" 2>/dev/null || true
HOST_PID=""
# Remove trust entries an agent CLI persisted for this run's throwaway paths (nothing else is touched).
CONFIG_CLEANUP="$(/usr/bin/python3 - "$E2E_HOME" <<'PY'
import os, re, sys
home = sys.argv[1]
prefixes = {home, home.replace("/private/tmp/", "/tmp/", 1)}
path = os.path.expanduser("~/.codex/config.toml")
try:
    text = open(path).read()
except FileNotFoundError:
    sys.exit(0)
pattern = re.compile(r'\[projects\."([^"]+)"\]\ntrust_level = "[a-z_]+"\n\n?')
removed = []
def drop(match):
    if any(match.group(1).startswith(p) for p in prefixes):
        removed.append(match.group(1))
        return ""
    return match.group(0)
cleaned = pattern.sub(drop, text)
if removed:
    mode = os.stat(path).st_mode & 0o777
    with open(path, "w") as f:
        f.write(cleaned)
    os.chmod(path, mode)
    print("removed Codex trust entries it added for the throwaway paths: " + ", ".join(p.replace(home, "$MERGECUE_HOME") for p in removed))
PY
)"
[[ -n "$CONFIG_CLEANUP" ]] && echo "==> $CONFIG_CLEANUP" >&2
AFTER_CONFIG="$(config_fingerprint)"

mkdir -p "$ROOT/docs/evidence"
REPORT="$ROOT/docs/evidence/agent-roundtrip-$AGENT.md"
/usr/bin/python3 - "$AGENT" "$E2E_HOME" "$REPORT" "$AGENT_STATUS" "$AGENT_VERSION" "$STARTED" "$FINISHED" \
  "$BEFORE_CONFIG" "$AFTER_CONFIG" "${COMMAND[*]}" "$CONFIG_CLEANUP" <<'PY'
import json, os, re, sys

agent, home, report, status, version, started, finished, before, after, command, cleanup = sys.argv[1:12]
user_home = os.path.expanduser("~")

SECRET_PATTERNS = [
    r"gh[pousr]_[A-Za-z0-9]{20,}", r"github_pat_[A-Za-z0-9_]{20,}", r"glpat-[A-Za-z0-9_-]{16,}",
    r"sk-ant-[A-Za-z0-9_-]{16,}", r"sk-[A-Za-z0-9_-]{20,}", r"ATATT[A-Za-z0-9_=-]{16,}",
    r"(?i)(authorization|bearer)\s*[:=]?\s*[A-Za-z0-9._~+/=-]{16,}", r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}",
]
homes = sorted({home, home.replace("/private/tmp/", "/tmp/", 1)}, key=len, reverse=True)
def redact(text):
    for h in homes:
        text = text.replace(h, "$MERGECUE_HOME")
    text = text.replace(user_home, "~")
    for pattern in SECRET_PATTERNS:
        text = re.sub(pattern, "<redacted>", text)
    return text

def load(name):
    try:
        with open(os.path.join(home, name)) as f:
            return json.load(f)
    except Exception:
        return {}

final = load("host-final.json")
ready = load("host-ready.json")
transcript_path = os.path.join(home, "transcript.jsonl")
lines = open(transcript_path, errors="replace").read().splitlines() if os.path.exists(transcript_path) else []

# Tool calls the agent made through MergeCue MCP.
calls = []
final_message = ""
for line in lines:
    try:
        event = json.loads(line)
    except Exception:
        continue
    if agent == "claude":
        if event.get("type") == "assistant":
            for block in event.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    calls.append(block.get("name", ""))
        if event.get("type") == "result":
            final_message = event.get("result") or ""
    elif agent == "codex":
        item = event.get("item") or {}
        if event.get("type") == "item.completed" and item.get("type") == "mcp_tool_call":
            calls.append(f"mcp__{item.get('server')}__{item.get('tool')}" + ("" if item.get("status") == "completed" else f" ({item.get('status')})"))
        elif event.get("type") == "item.completed" and item.get("type") == "command_execution":
            calls.append("shell: " + (item.get("command") or "")[:120])
        elif event.get("type") == "item.completed" and item.get("type") == "file_change":
            calls.append("file_change: " + ", ".join(c.get("path", "") for c in item.get("changes", [])))
        elif event.get("type") == "item.completed" and item.get("type") == "agent_message":
            final_message = item.get("text") or final_message
if agent == "sim":
    try:
        sim = json.loads("\n".join(lines))
        calls = [s.get("name", "") + ("" if s.get("ok") else " (FAILED)") for s in sim.get("steps", [])]
        final_message = "passed" if sim.get("passed") else "failed"
    except Exception:
        pass

mergecue_calls = [c for c in calls if c.startswith("mcp__mergecue__") or agent == "sim"]
def called(name):
    return any(name in c for c in calls)
checks = {name: called(name) for name in ["get_task", "claim_task", "update_task", "report_changes", "report_tests", "submit_result", "heartbeat", "get_thread", "get_change_context"]}
state = final.get("state")
writes = final.get("providerWrites", [])

out = []
out.append(f"# Real agent round trip — {agent}")
out.append("")
out.append("Synthetic **demo data** (MergeCue demo mode: fixture provider data through the real adapters, a synthetic")
out.append("throwaway `acme/payments-api` repository). Generated by `scripts/e2e-real-agent.sh " + agent + "`.")
out.append("")
out.append("| | |")
out.append("| --- | --- |")
out.append(f"| Agent | `{redact(version.strip())}` |")
out.append(f"| Started / finished (UTC) | {started} / {finished} |")
out.append(f"| Agent exit status | {status} |")
out.append(f"| Task | `{ready.get('task_id')}` (GitHub #42, step-1 blocking review comment) |")
out.append(f"| Final task state | **{state}** |")
out.append(f"| Reached ready_for_review | {'yes' if state == 'ready_for_review' else 'no'} |")
out.append(f"| Provider writes during the run | {len(writes)} {'(none — claim/report/submit never publish)' if not writes else writes} |")
out.append(f"| Agent MCP config unchanged | {'yes' if before == after else 'NO'} (before `{before}`, after `{after}`) |")
if cleanup:
    out.append(f"| Config cleanup | {cleanup} |")
out.append("")
out.append("## Command (session-only MCP configuration)")
out.append("")
out.append("```")
out.append(redact(command.replace(home, "$MERGECUE_HOME")))
out.append("```")
out.append("")
out.append("## MergeCue MCP calls observed")
out.append("")
for name, ok in checks.items():
    out.append(f"- `{name}`: {'called' if ok else 'not called'}")
out.append("")
out.append("All tool calls, in order:")
out.append("")
for c in calls:
    out.append(f"1. `{redact(c.replace(home, '$MERGECUE_HOME'))}`")
out.append("")
out.append("## Task activity (from the app's append-only history)")
out.append("")
out.append("| At | Actor | Kind | State | Message |")
out.append("| --- | --- | --- | --- | --- |")
for a in final.get("activities", []):
    transition = f"{a.get('fromState') or ''} → {a.get('toState') or ''}" if a.get("toState") else ""
    message = redact(a.get("message", "")).replace("|", "\\|").replace("\n", " ").replace(home, "$MERGECUE_HOME")
    out.append(f"| {a.get('at')} | {a.get('actor')}{(' (' + a['actorName'] + ')') if a.get('actorName') else ''} | {a.get('kind')} | {transition} | {message[:300]} |")
out.append("")
out.append("## Result")
out.append("")
out.append("Summary submitted by the agent:")
out.append("")
out.append("> " + redact(final.get("resultSummary") or "(none)").replace("\n", "\n> "))
out.append("")
out.append("Proposed reply (not posted; posting requires the owner's approval in the app):")
out.append("")
out.append("> " + redact(final.get("proposedReply") or "(none)").replace("\n", "\n> "))
out.append("")
for art in final.get("artifacts", []):
    out.append(f"### Artifact `{art.get('id')}` — {art.get('kind')} ({art.get('title')}, reported by {art.get('reportedBy')})")
    out.append("")
    fence = "diff" if art.get("kind") == "diff" else ""
    out.append("```" + fence)
    out.append(redact(art.get("content", "")).replace(home, "$MERGECUE_HOME")[:8000])
    out.append("```")
    out.append("")
out.append("## Agent's final message")
out.append("")
out.append("> " + redact(final_message or "(none)").replace("\n", "\n> ")[:4000])
out.append("")
out.append(f"Raw transcript (redacted): `docs/evidence/agent-roundtrip-{agent}.transcript.jsonl` ({len(lines)} lines).")
out.append("")
with open(report, "w") as f:
    f.write("\n".join(out))
with open(report.replace(".md", ".transcript.jsonl"), "w") as f:
    for line in lines:
        f.write(redact(line.replace(home, "$MERGECUE_HOME")) + "\n")
print(json.dumps({"state": state, "checks": checks, "provider_writes": len(writes), "config_unchanged": before == after}))
PY
echo "==> evidence: $REPORT" >&2
