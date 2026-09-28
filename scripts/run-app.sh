#!/usr/bin/env bash
# Builds MergeCue.app (Debug) and opens it.
#
# Usage: scripts/run-app.sh [--menu-bar-only] [--demo|--preview|--live]
#   Opens the main window too, unless --menu-bar-only is given (the menu bar item is always added).
#   Default mode: live (your accounts). --demo = bundled fixtures through the real engine ("Demo data" badge);
#   --preview = in-memory synthetic data; MERGECUE_PREVIEW_VARIANT=standard|authExpired|allCaughtUp|noAccounts.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh Debug

app="$PWD/dist/MergeCue.app"
# Quit a copy started from dist/ earlier, otherwise `open` would just bring the old build to the front.
if pgrep -f "^$app/Contents/MacOS/MergeCue" >/dev/null; then
    pkill -f "^$app/Contents/MacOS/MergeCue" || true
    sleep 1
fi

mode_args=()
menu_bar_only=0
for argument in "$@"; do
    case "$argument" in
        --menu-bar-only) menu_bar_only=1 ;;
        --demo | --preview | --live) mode_args+=("$argument") ;;
        *) echo "unknown argument: $argument" >&2; exit 64 ;;
    esac
done

open_args=()
[[ -n "${MERGECUE_PREVIEW_VARIANT:-}" ]] && open_args+=(--env "MERGECUE_PREVIEW_VARIANT=$MERGECUE_PREVIEW_VARIANT")
[[ -n "${MERGECUE_BACKEND:-}" ]] && open_args+=(--env "MERGECUE_BACKEND=$MERGECUE_BACKEND")
echo "==> Opening $app"
app_args=(${mode_args[@]+"${mode_args[@]}"})
[[ "$menu_bar_only" == "1" ]] || app_args+=(--show-window)
open ${open_args[@]+"${open_args[@]}"} "$app" --args ${app_args[@]+"${app_args[@]}"}
