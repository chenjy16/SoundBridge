#!/bin/bash
#
# Test the argument, path and dry-run handling of tools/codesign.sh.
#
# Nothing here signs anything. codesign.sh --dry-run resolves the bundle, the
# identity and the options, prints the plan it would execute, and exits, so the
# whole sequence can be asserted without a certificate and without touching a
# single code object.
#
# Why a fixture bundle instead of dist/SoundBridge.app
# ----------------------------------------------------
# The plan only needs the shape of a bundle: Info.plist, Contents/MacOS, a driver
# bundle, a framework with nested XPCs and an Updater.app. Copies of /usr/bin/true
# give the Mach-O detection something real to match, so the plan is the same one
# a release bundle produces, while the test stays independent of whether
# `make bundle` has run and cannot be influenced by a stale dist/.
#
set -euo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CODESIGN_SH="$ROOT_DIR/tools/codesign.sh"
HOST_ENT="$ROOT_DIR/packages/host/SoundBridgeHost.entitlements"
APP_ENT="$ROOT_DIR/apps/mac/SoundBridgeApp/SoundBridgeApp.entitlements"

TMP="$( cd "$(mktemp -d "${TMPDIR:-/tmp}/soundbridge-codesign-test.XXXXXX")" && pwd -P )"
trap 'rm -rf "$TMP"' EXIT

CHECKS=0
FAILS=0

pass() { CHECKS=$((CHECKS + 1)); printf '  ok   %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf '  FAIL %s\n' "$1"; }

# assert_eq <expected> <actual> <label>
assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3 (expected '$1', got '$2')"
    fi
}

# assert_contains <file> <fixed string> <label>
assert_contains() {
    if grep -qF -- "$2" "$1"; then
        pass "$3"
    else
        fail "$3 (missing '$2')"
    fi
}

assert_not_contains() {
    if grep -qF -- "$2" "$1"; then
        fail "$3 (found '$2')"
    else
        pass "$3"
    fi
}

# run_sign <output file> <env assignments...> -- <args...>
run_sign() {
    local out="$1"; shift
    local -a envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    set +e
    # bash 3.2 refuses "${arr[@]}" under set -u when the array is empty.
    if [ "${#envs[@]}" -gt 0 ]; then
        env "${envs[@]}" "$CODESIGN_SH" "$@" > "$out" 2>&1
    else
        "$CODESIGN_SH" "$@" > "$out" 2>&1
    fi
    RC=$?
    set -e
}

# The numbered plan at the end of a dry run is the authoritative list: each
# action also appears inline as it is decided, so counts taken from the whole
# output would be doubled.
extract_plan() {
    grep -E '^  [0-9]+\. codesign ' "$1" | sed 's/^  [0-9]*\. //' > "$2"
}

# First plan step whose line matches an anchored regex.
line_of() {
    local n
    n="$(grep -nE "$1" "$2" | head -1 | cut -d: -f1)"
    echo "${n:-0}"
}

build_fixture() {
    local app="$1"
    mkdir -p "$app/Contents/MacOS" \
        "$app/Contents/Resources/SoundBridgeDriver.driver/Contents/MacOS" \
        "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS" \
        "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS" \
        "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict>' \
        '<key>CFBundleIdentifier</key><string>com.soundbridge.test</string>' \
        '<key>CFBundleShortVersionString</key><string>0.0.0</string>' \
        '</dict></plist>' > "$app/Contents/Info.plist"

    local rel
    for rel in \
        "Contents/MacOS/SoundBridgeApp" \
        "Contents/MacOS/SoundBridgeHost" \
        "Contents/Resources/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver" \
        "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
        "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
        "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
        "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
        "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    do
        cp /usr/bin/true "$app/$rel"
        chmod 755 "$app/$rel"
    done
}

# Files inside a bundle that changed since a marker file was created. A dry run
# must leave this at zero.
changed_since() {
    local dir="$1" marker="$2"
    find "$dir" -newer "$marker" 2>/dev/null | wc -l | tr -d ' '
}

echo "=== test_codesign_args"
echo ""

BUNDLE="$TMP/SoundBridge.app"
build_fixture "$BUNDLE"

# --- 1. default path ---------------------------------------------------------
# The default is dist/SoundBridge.app whether or not that bundle exists yet. On
# a clean checkout (CI runs this suite before `make bundle`) there is nothing to
# resolve, so what is asserted there is the refusal -- by path, with a remedy --
# rather than a plan. Both branches pin the same default path, which is the
# property that matters: a bare call must never silently sign some other app.
echo "1. default bundle path"
touch "$TMP/marker-default"
run_sign "$TMP/out-default" -- --adhoc --dry-run
if [ -d "$ROOT_DIR/dist/SoundBridge.app" ]; then
    assert_eq "0" "$RC" "default: exit code 0"
    assert_contains "$TMP/out-default" "bundle:       $ROOT_DIR/dist/SoundBridge.app" \
        "default: signs dist/SoundBridge.app"
    assert_contains "$TMP/out-default" "source:       default (dist/SoundBridge.app)" \
        "default: reported as the default source"
    assert_contains "$TMP/out-default" "Signing plan for $ROOT_DIR/dist/SoundBridge.app" \
        "default: plan names the default bundle"
    assert_eq "0" "$(changed_since "$ROOT_DIR/dist/SoundBridge.app" "$TMP/marker-default")" \
        "default: dry run modified nothing in dist/SoundBridge.app"
else
    assert_eq "1" "$RC" "default: exit code 1 when dist/ holds no bundle"
    assert_contains "$TMP/out-default" "App bundle not found at $ROOT_DIR/dist/SoundBridge.app" \
        "default: names dist/SoundBridge.app as the path it looked for"
    assert_contains "$TMP/out-default" "Run 'make bundle' first" \
        "default: says how to create it"
fi

# --- 2. SB_APP_BUNDLE override ----------------------------------------------
echo ""
echo "2. SB_APP_BUNDLE override"
touch "$TMP/marker-custom"
run_sign "$TMP/out-custom" SB_APP_BUNDLE="$BUNDLE" -- --adhoc --dry-run
assert_eq "0" "$RC" "custom: exit code 0"
assert_contains "$TMP/out-custom" "bundle:       $BUNDLE" "custom: signs the requested bundle"
assert_contains "$TMP/out-custom" "source:       SB_APP_BUNDLE" "custom: reported as an override"
assert_not_contains "$TMP/out-custom" "$ROOT_DIR/dist/" "custom: dist/ never appears in the plan"
assert_eq "0" "$(changed_since "$BUNDLE" "$TMP/marker-custom")" "custom: dry run modified nothing"

# relative paths are resolved to absolute, symlinks included
( cd "$TMP" && SB_APP_BUNDLE=./SoundBridge.app "$CODESIGN_SH" --adhoc --dry-run ) > "$TMP/out-relative" 2>&1
assert_contains "$TMP/out-relative" "bundle:       $BUNDLE" "custom: relative path resolved to absolute"

# --- 3. refusals -------------------------------------------------------------
echo ""
echo "3. refusals"
run_sign "$TMP/out-missing" SB_APP_BUNDLE="$TMP/absent.app" -- --adhoc --dry-run
assert_eq "1" "$RC" "missing: exit code 1"
assert_contains "$TMP/out-missing" "App bundle not found at $TMP/absent.app" "missing: names the requested path"
assert_contains "$TMP/out-missing" "was NOT substituted" "missing: no silent fallback to dist"
assert_not_contains "$TMP/out-missing" "codesign --sign" "missing: no signing plan produced"

mkdir -p "$TMP/PlainDir"
run_sign "$TMP/out-notapp" SB_APP_BUNDLE="$TMP/PlainDir" -- --adhoc --dry-run
assert_eq "1" "$RC" "not .app: exit code 1"
assert_contains "$TMP/out-notapp" "not an .app bundle" "not .app: refused by name"

mkdir -p "$TMP/Hollow.app"
run_sign "$TMP/out-hollow" SB_APP_BUNDLE="$TMP/Hollow.app" -- --adhoc --dry-run
assert_eq "1" "$RC" "hollow .app: exit code 1"
assert_contains "$TMP/out-hollow" "not a valid app bundle" "hollow .app: refused, no Contents/"

run_sign "$TMP/out-empty" SB_APP_BUNDLE="" -- --adhoc --dry-run
assert_eq "2" "$RC" "empty SB_APP_BUNDLE: exit code 2"
assert_contains "$TMP/out-empty" "set but empty" "empty SB_APP_BUNDLE: refused, not defaulted"

run_sign "$TMP/out-unknown" SB_APP_BUNDLE="$BUNDLE" -- --adhoc --bogus
assert_eq "2" "$RC" "unknown argument: exit code 2"

run_sign "$TMP/out-cert" SB_APP_BUNDLE="$BUNDLE" \
    APPLE_CERTIFICATE="Zm9v" APPLE_CERTIFICATE_PASSWORD="x" -- --dry-run
assert_eq "2" "$RC" "dry run refuses certificate import: exit code 2"

# --- 4. signature parameters -------------------------------------------------
echo ""
echo "4. signature parameters"
assert_contains "$TMP/out-custom" "signature:    adhoc (not a Developer ID signature)" \
    "adhoc: labelled as adhoc"
assert_contains "$TMP/out-custom" "--sign - --force --verbose" "adhoc: --sign -"
assert_not_contains "$TMP/out-custom" "--timestamp" "adhoc: no --timestamp"
assert_not_contains "$TMP/out-custom" "--options runtime" "adhoc: no hardened runtime"

# the flag and the environment variable both select adhoc
run_sign "$TMP/out-env-adhoc" SB_APP_BUNDLE="$BUNDLE" SIGN_MODE=adhoc -- --dry-run
assert_eq "0" "$RC" "SIGN_MODE=adhoc: exit code 0"
assert_contains "$TMP/out-env-adhoc" "--sign - " "SIGN_MODE=adhoc: --sign -"

# Developer ID parameters are generated, but nothing is signed
run_sign "$TMP/out-devid" SB_APP_BUNDLE="$BUNDLE" \
    SIGN_MODE=developer-id APPLE_DEVELOPER_ID="Developer ID Application: Test (ABCDE12345)" \
    -- --dry-run
assert_eq "0" "$RC" "developer-id: exit code 0"
assert_contains "$TMP/out-devid" "signature:    Developer ID Application, hardened runtime, timestamp" \
    "developer-id: labelled as Developer ID"
assert_contains "$TMP/out-devid" "--timestamp" "developer-id: --timestamp present"
assert_contains "$TMP/out-devid" "--options runtime" "developer-id: hardened runtime present"
assert_contains "$TMP/out-devid" '--sign Developer ID Application: Test (ABCDE12345)' \
    "developer-id: identity passed through"
assert_not_contains "$TMP/out-devid" "--sign - " "developer-id: not adhoc"

# --- 5. entitlements ---------------------------------------------------------
echo ""
echo "5. entitlements"
assert_contains "$TMP/out-custom" "--entitlements $HOST_ENT" "host entitlements path"
assert_contains "$TMP/out-custom" "--entitlements $APP_ENT" "app entitlements path"
PLAN="$TMP/plan-custom"
extract_plan "$TMP/out-custom" "$PLAN"
HOST_ENT_LINES="$(grep -c -F -- "--entitlements $HOST_ENT" "$PLAN")"
assert_eq "1" "$HOST_ENT_LINES" "host entitlements applied once"
APP_ENT_LINES="$(grep -c -F -- "--entitlements $APP_ENT" "$PLAN")"
assert_eq "2" "$APP_ENT_LINES" "app entitlements applied to binary and bundle"
assert_eq "15" "$(wc -l < "$PLAN" | tr -d ' ')" "plan has 15 steps"

# --- 6. nesting order --------------------------------------------------------
echo ""
echo "6. nesting order"
HOST_L=$(line_of 'Contents/MacOS/SoundBridgeHost$' "$PLAN")
DRV_BIN=$(line_of 'SoundBridgeDriver\.driver/Contents/MacOS/SoundBridgeDriver$' "$PLAN")
DRV_BUNDLE=$(line_of 'SoundBridgeDriver\.driver$' "$PLAN")
DL_BIN=$(line_of 'Downloader\.xpc/Contents/MacOS/Downloader$' "$PLAN")
DL_BUNDLE=$(line_of 'Downloader\.xpc$' "$PLAN")
IN_BIN=$(line_of 'Installer\.xpc/Contents/MacOS/Installer$' "$PLAN")
IN_BUNDLE=$(line_of 'Installer\.xpc$' "$PLAN")
FW=$(line_of 'Sparkle\.framework$' "$PLAN")
APP_BIN=$(line_of 'Contents/MacOS/SoundBridgeApp$' "$PLAN")
APP_BUNDLE_L=$(line_of 'SoundBridge\.app$' "$PLAN")

assert_lt() {
    if [ "$1" -gt 0 ] && [ "$2" -gt 0 ] && [ "$1" -lt "$2" ]; then
        pass "order: $3 ($1 < $2)"
    else
        fail "order: $3 ($1 < $2)"
    fi
}

assert_lt "$HOST_L" "$DRV_BIN" "host first, then driver binary"
assert_lt "$DRV_BIN" "$DRV_BUNDLE" "driver binary inside driver bundle"
assert_lt "$DRV_BUNDLE" "$DL_BIN" "driver bundle before framework XPCs"
assert_lt "$DL_BIN" "$DL_BUNDLE" "Downloader binary inside Downloader.xpc"
assert_lt "$DL_BUNDLE" "$IN_BIN" "Downloader.xpc before Installer.xpc"
assert_lt "$IN_BIN" "$IN_BUNDLE" "Installer binary inside Installer.xpc"
assert_lt "$IN_BUNDLE" "$FW" "every XPC before the framework"
assert_lt "$FW" "$APP_BIN" "framework before the app binary"
assert_lt "$APP_BIN" "$APP_BUNDLE_L" "app binary before the app bundle"

LAST_LINE="$(wc -l < "$PLAN" | tr -d ' ')"
assert_eq "$APP_BUNDLE_L" "$LAST_LINE" "order: the app bundle is signed last"

# --- 7. dry run claims nothing ----------------------------------------------
echo ""
echo "7. dry run honesty"
assert_not_contains "$TMP/out-custom" "OK: SoundBridge.app bundle signed" \
    "dry run: no 'signed' success line"
assert_contains "$TMP/out-custom" "Nothing was signed: this was a dry run." \
    "dry run: states that nothing was signed"
assert_contains "$TMP/out-custom" "DRY RUN (nothing will be signed)" "dry run: mode banner"
assert_eq "0" "$(find "$BUNDLE" -name '_CodeSignature' -type d | wc -l | tr -d ' ')" \
    "dry run: no _CodeSignature written into the fixture"

# --- 8. help -----------------------------------------------------------------
# --help has to work without a bundle: it is the one invocation that asks what
# the script does, and on a clean checkout the default bundle does not exist.
echo ""
run_sign "$TMP/out-help" -- --help
assert_eq "0" "$RC" "help: exit code 0"
assert_contains "$TMP/out-help" "SB_APP_BUNDLE" "help: documents SB_APP_BUNDLE"
assert_contains "$TMP/out-help" "--dry-run" "help: documents --dry-run"
assert_contains "$TMP/out-help" "usage:" "help: prints a usage line"

echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: $CHECKS checks, 0 failures"
    exit 0
fi
echo "FAIL: $CHECKS checks, $FAILS failures"
exit 1
