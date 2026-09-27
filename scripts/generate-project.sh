#!/usr/bin/env bash
# Generates MergeCue.xcodeproj from project.yml with XcodeGen, then normalises it so every clone and worktree produces
# the same project (commit the result).
#
# The root SwiftPM package is referenced as a local package at path "." (XCLocalSwiftPackageReference). XcodeGen also
# adds a navigator folder reference for it, named after the checkout directory ("mergecue-app", a worktree name, ...)
# and with an object id derived from that name. This script removes that one folder reference; the package reference
# itself stays, so Xcode still resolves and builds the package.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "error: xcodegen not found (brew install xcodegen)" >&2; exit 1; }
xcodegen generate --spec project.yml --quiet

pbxproj=MergeCue.xcodeproj/project.pbxproj
folder_ref_id="$(grep -E '^[[:space:]]*[0-9A-F]{24} /\* .* \*/ = \{isa = PBXFileReference; lastKnownFileType = folder; name = .*; path = \.; sourceTree = SOURCE_ROOT; \};$' "$pbxproj" | awk '{print $1}' || true)"
if [[ -z "$folder_ref_id" ]]; then
    echo "error: no folder reference for the root package in $pbxproj (did xcodegen's output change?)" >&2
    exit 1
fi
occurrences="$(grep -c "$folder_ref_id" "$pbxproj")"
if [[ "$occurrences" != "2" ]]; then
    echo "error: expected the root package folder reference $folder_ref_id twice in $pbxproj, found $occurrences" >&2
    exit 1
fi
grep -v "$folder_ref_id" "$pbxproj" > "$pbxproj.tmp"
mv "$pbxproj.tmp" "$pbxproj"
grep -q 'isa = XCLocalSwiftPackageReference;' "$pbxproj" || { echo "error: local package reference missing" >&2; exit 1; }
echo "Generated MergeCue.xcodeproj"
