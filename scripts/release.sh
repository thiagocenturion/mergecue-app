#!/usr/bin/env bash
# Notarized release build of MergeCue for distribution outside the Mac App Store.
#
#   scripts/release.sh
#
# Requires (one-time, done by the owner):
#   - a "Developer ID Application: … (TTSKDZ455K)" certificate in the login keychain;
#   - notarization credentials stored with `xcrun notarytool store-credentials mergecue`
#     (override the profile name with NOTARY_PROFILE=<name>).
#
# Steps: Release build signed with Developer ID + secure timestamp (scripts/build-app.sh) -> check the signature
# is distribution-ready (Developer ID authority, hardened runtime, timestamp, no get-task-allow) for the app and
# the embedded mergecue-mcp -> zip -> notarytool submit --wait -> staple -> Gatekeeper assessment ->
# dist/MergeCue-<version>.zip (the stapled app) and dist/MergeCue-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

profile="${NOTARY_PROFILE:-mergecue}"
section() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

security find-identity -v -p codesigning | grep -q 'Developer ID Application: .*(TTSKDZ455K)' \
    || fail 'no "Developer ID Application (TTSKDZ455K)" certificate in the keychain'

SIGNING=developerid scripts/build-app.sh Release

app="dist/MergeCue.app"
helper="$app/Contents/MacOS/mergecue-mcp"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"

section "Checking distribution signatures"
for binary in "$app" "$helper"; do
    details="$(codesign -dvvv "$binary" 2>&1)"
    grep -q '^Authority=Developer ID Application: .*(TTSKDZ455K)' <<<"$details" || fail "$binary is not signed with Developer ID"
    grep -q '^Timestamp=' <<<"$details" || fail "$binary has no secure timestamp"
    grep -q 'flags=.*runtime' <<<"$details" || fail "$binary lacks the hardened runtime"
    if codesign -d --entitlements - --xml "$binary" 2>/dev/null | grep -q 'get-task-allow'; then
        fail "$binary carries com.apple.security.get-task-allow (debug entitlement)"
    fi
    echo "  ok: $binary"
done

section "Submitting to Apple notarization (profile: $profile)"
submission="$(mktemp -d)/MergeCue-notarize.zip"
ditto -c -k --keepParent "$app" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait --output-format plist > "${submission%.zip}.plist" \
    || { cat "${submission%.zip}.plist" 2>/dev/null; fail "notarytool submit failed"; }
status="$(/usr/libexec/PlistBuddy -c 'Print :status' "${submission%.zip}.plist")"
submission_id="$(/usr/libexec/PlistBuddy -c 'Print :id' "${submission%.zip}.plist")"
echo "  submission $submission_id: $status"
if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$submission_id" --keychain-profile "$profile" || true
    fail "notarization was not accepted ($status)"
fi

section "Stapling the notarization ticket"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

section "Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$app"

section "Packaging"
zip_out="dist/MergeCue-$version.zip"
dmg_out="dist/MergeCue-$version.dmg"
rm -f "$zip_out" "$dmg_out"
ditto -c -k --keepParent "$app" "$zip_out"
staging="$(mktemp -d)"
ditto "$app" "$staging/MergeCue.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "MergeCue $version" -srcfolder "$staging" -ov -format UDZO "$dmg_out"
codesign --sign "Developer ID Application: Thiago R. Centurion (TTSKDZ455K)" --timestamp "$dmg_out"
xcrun notarytool submit "$dmg_out" --keychain-profile "$profile" --wait >/dev/null \
    && xcrun stapler staple "$dmg_out" >/dev/null \
    && echo "  dmg notarized and stapled" || echo "  warning: dmg notarization failed; the zip is still valid"
rm -rf "$staging" "$(dirname "$submission")"

section "Done: MergeCue $version ($build)"
ls -lh "$zip_out" "$dmg_out"
