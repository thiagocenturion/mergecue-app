#!/usr/bin/env bash
# Builds MergeCue.app (Debug) and opens it. Until the engine is wired the app runs on synthetic preview data, and
# every screen carries a "Preview data" badge.
#
# Usage: scripts/run-app.sh [--menu-bar-only]
#   Opens the main window too, unless --menu-bar-only is given (the menu bar item is always added).
#   MERGECUE_PREVIEW_VARIANT=standard|authExpired|allCaughtUp|noAccounts picks the preview scenario.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh Debug

app="$PWD/dist/MergeCue.app"
# Quit a copy started from dist/ earlier, otherwise `open` would just bring the old build to the front.
if pgrep -f "^$app/Contents/MacOS/MergeCue" >/dev/null; then
    pkill -f "^$app/Contents/MacOS/MergeCue" || true
    sleep 1
fi

open_args=()
[[ -n "${MERGECUE_PREVIEW_VARIANT:-}" ]] && open_args+=(--env "MERGECUE_PREVIEW_VARIANT=$MERGECUE_PREVIEW_VARIANT")
[[ -n "${MERGECUE_BACKEND:-}" ]] && open_args+=(--env "MERGECUE_BACKEND=$MERGECUE_BACKEND")
echo "==> Opening $app"
if [[ "${1:-}" == "--menu-bar-only" ]]; then
    open ${open_args[@]+"${open_args[@]}"} "$app"
else
    open ${open_args[@]+"${open_args[@]}"} "$app" --args --show-window
fi
