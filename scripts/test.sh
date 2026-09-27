#!/usr/bin/env bash
# One-command build + test for all SwiftPM modules. Usage: scripts/test.sh [--filter <pattern>]
set -euo pipefail
cd "$(dirname "$0")/.."
export MERGECUE_HOME="${MERGECUE_HOME:-$(mktemp -d -t mergecue-test)}"
swift build --build-tests
swift test --skip-build "$@"
