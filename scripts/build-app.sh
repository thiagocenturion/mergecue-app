#!/usr/bin/env bash
# Builds MergeCue.app with Xcode, copies it to dist/ and verifies the bundle.
#
# Usage: scripts/build-app.sh [Debug|Release]
#
# Environment:
#   SIGNING=development  (default) sign with the "Apple Development" identity of team TTSKDZ455K (login keychain)
#   SIGNING=adhoc        ad-hoc signature (CODE_SIGN_IDENTITY=-, no team): CI or machines without the certificate
#   SIGNING=developerid  "Developer ID Application" of team TTSKDZ455K with a secure timestamp, for notarized
#                        distribution (use scripts/release.sh, which also notarizes and staples)
#   VERBOSE=1            full xcodebuild output instead of errors/warnings only
#
# Steps: scripts/generate-project.sh (xcodegen) -> xcodebuild (derived data in build/DerivedData) -> copy to
# dist/MergeCue.app -> verify the signatures of the app and the embedded Contents/MacOS/mergecue-mcp, run
# `mergecue-mcp --version` -> check Info.plist and the app icon.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-Debug}"
case "$configuration" in
    Debug | Release) ;;
    *) echo "usage: $0 [Debug|Release]" >&2; exit 64 ;;
esac

signing="${SIGNING:-development}"
signing_args=()
case "$signing" in
    development) ;;
    adhoc) signing_args=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=) ;;
    developerid)
        signing_args=(
            "CODE_SIGN_IDENTITY=Developer ID Application" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=TTSKDZ455K
            PROVISIONING_PROFILE_SPECIFIER= "OTHER_CODE_SIGN_FLAGS=--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
        )
        ;;
    *) echo "SIGNING must be 'development', 'adhoc' or 'developerid' (got '$signing')" >&2; exit 64 ;;
esac

# Debug: the Mac's own architecture. Release: universal (arm64 + x86_64).
destination="platform=macOS,arch=$(uname -m)"
[[ "$configuration" == "Release" ]] && destination='generic/platform=macOS'

quiet_args=(-quiet)
[[ "${VERBOSE:-0}" == "1" ]] && quiet_args=()

section() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

section "Generating MergeCue.xcodeproj from project.yml"
scripts/generate-project.sh

section "Building MergeCue ($configuration, signing: $signing)"
xcodebuild \
    -project MergeCue.xcodeproj \
    -scheme MergeCue \
    -configuration "$configuration" \
    -destination "$destination" \
    -derivedDataPath build/DerivedData \
    ${quiet_args[@]+"${quiet_args[@]}"} \
    ${signing_args[@]+"${signing_args[@]}"} \
    build

built_app="build/DerivedData/Build/Products/$configuration/MergeCue.app"
[[ -d "$built_app" ]] || fail "build finished but $built_app is missing"

section "Copying to dist/MergeCue.app"
mkdir -p dist
rm -rf dist/MergeCue.app
ditto "$built_app" dist/MergeCue.app
app="dist/MergeCue.app"
helper="$app/Contents/MacOS/mergecue-mcp"

section "Verifying code signatures"
codesign --verify --deep --strict --verbose=2 "$app"
[[ -x "$helper" ]] || fail "$helper is missing or not executable"
app_signature="$(codesign -dv --verbose=2 "$app" 2>&1)"
helper_signature="$(codesign -dv --verbose=2 "$helper" 2>&1)"
signature_field() { sed -n "s/^$2=//p" <<<"$1" | head -n 1; }
print_signature() {
    echo "  $1"
    grep -E '^(Identifier|Format|CodeDirectory|Authority|Signature|TeamIdentifier)[ =]' <<<"$2" | sed 's/^/    /'
}
print_signature "$app" "$app_signature"
print_signature "$helper" "$helper_signature"

app_id="$(signature_field "$app_signature" Identifier)"
helper_id="$(signature_field "$helper_signature" Identifier)"
app_team="$(signature_field "$app_signature" TeamIdentifier)"
helper_team="$(signature_field "$helper_signature" TeamIdentifier)"
[[ "$app_id" == "com.thiagocenturion.MergeCue" ]] || fail "unexpected app identifier '$app_id'"
[[ "$helper_id" == "com.thiagocenturion.MergeCue.mcp" ]] || fail "unexpected helper identifier '$helper_id'"
[[ "$app_team" == "$helper_team" ]] || fail "team mismatch: app '$app_team', helper '$helper_team'"
runtime_flag='flags=0x[0-9a-f]*\([^)]*runtime'
if [[ "$signing" == "development" ]]; then
    [[ "$app_team" == "TTSKDZ455K" ]] || fail "expected team TTSKDZ455K, got '$app_team'"
    [[ "$app_signature" =~ $runtime_flag ]] || fail "Hardened Runtime is not enabled on the app"
    [[ "$helper_signature" =~ $runtime_flag ]] || fail "Hardened Runtime is not enabled on mergecue-mcp"
    echo "  Hardened Runtime: on (app and helper)"
else
    # Xcode leaves Hardened Runtime off the app bundle when it signs to run locally (ad-hoc); only the development
    # (and future Developer ID) builds are expected to carry it.
    echo "  Ad-hoc signature: Hardened Runtime is not checked"
fi

section "Running the embedded helper"
echo "  \$ mergecue-mcp --version"
"$helper" --version | sed 's/^/    /'

section "Checking Info.plist and the app icon"
info="$app/Contents/Info.plist"
for key in CFBundleIdentifier CFBundleDisplayName CFBundleShortVersionString CFBundleVersion LSUIElement \
    LSMinimumSystemVersion LSApplicationCategoryType CFBundleIconName; do
    printf '    %-28s %s\n' "$key" "$(/usr/libexec/PlistBuddy -c "Print :$key" "$info" 2>/dev/null || echo '<missing>')"
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" == "com.thiagocenturion.MergeCue" ]] ||
    fail "unexpected CFBundleIdentifier"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$info")" == "true" ]] || fail "LSUIElement is not set"
asset_info="$(xcrun assetutil --info "$app/Contents/Resources/Assets.car")"
grep -q '"Name" : "AppIcon"' <<<"$asset_info" || fail "Assets.car has no AppIcon"
[[ -f "$app/Contents/Resources/AppIcon.icns" ]] || fail "AppIcon.icns is missing"
echo "    AppIcon present in Assets.car and AppIcon.icns"

section "Done: $app ($configuration, $signing)"
