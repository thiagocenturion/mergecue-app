#!/usr/bin/env bash
# Runs the MergeCue app shell with synthetic preview data. Nothing is fetched, stored, posted or launched, and
# every screen carries a "Preview data" badge.
# Usage: scripts/run-preview.sh [standard|authExpired|allCaughtUp|noAccounts] [--menu-bar-only]
set -euo pipefail
cd "$(dirname "$0")/.."
variant="${1:-standard}"
shift || true
swift build --product mergecue-snapshots
exec .build/debug/mergecue-snapshots --app "$variant" "$@"
