#!/bin/bash
#
# Negative and positive tests for tools/verify_pkg_driver.sh.
#
# Every case runs against a copy under build/p34/extracted/, never against
# dist/, build/p32/ or the installed driver, and nothing is signed here. The
# tamper case uses an object that is already signed by someone else -- the
# Sparkle Updater.app inside the candidate app -- so "codesign noticed the change"
# can be demonstrated without performing a single signing operation.
#
set -euo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
VERIFY="$ROOT_DIR/tools/verify_pkg_driver.sh"

APP="${1:-$ROOT_DIR/build/p34/unsigned/SoundBridge.app}"
REAL_DRIVER="$APP/Contents/Resources/SoundBridgeDriver.driver"
SPARKLE_UPDATER="$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"

WORK="$ROOT_DIR/build/p34/extracted/test-pkg-driver.$$"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$WORK"
mkdir -p "$WORK"

CHECKS=0
FAILS=0
pass() { CHECKS=$((CHECKS + 1)); echo "  ok   $1"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); echo "  FAIL $1"; }

# run_verify <output file> <args...>; sets RC
run_verify() {
    local out="$1"; shift
    set +e
    "$VERIFY" "$@" > "$out" 2>&1
    RC=$?
    set -e
}

expect_rc() {
    if [ "$RC" = "$1" ]; then pass "$2 (exit $RC)"; else bad "$2 (expected exit $1, got $RC)"; fi
}

expect_line() {
    if grep -qxF "$2" "$1"; then pass "$3"; else bad "$3 (missing line '$2')"; fi
}

expect_note() {
    if grep -qF "$2" "$1"; then pass "$3"; else bad "$3 (missing '$2')"; fi
}

echo "=== test_verify_pkg_driver"
echo ""

if [ ! -d "$REAL_DRIVER" ] || [ ! -d "$SPARKLE_UPDATER" ]; then
    echo "SKIP: $APP is missing; run the Phase 3.4A candidate build first" >&2
    exit 1
fi

# --- 1. the real driver passes ----------------------------------------------
echo "1. control case"
run_verify "$WORK/ok.txt" --driver "$REAL_DRIVER" --app "$APP"
expect_rc 0 "real driver passes"
expect_line "$WORK/ok.txt" "PKG_DRIVER_STRUCTURE=STRUCTURAL_PASS" "structure verdict"
expect_line "$WORK/ok.txt" "PKG_DRIVER_SIGNATURE=DEVELOPER_ID_SIGNATURE_NOT_VERIFIED" \
    "signature verdict is NOT_VERIFIED, not VERIFIED"
expect_note "$WORK/ok.txt" "byte-identical to the app's driver" "content agreement"
expect_note "$WORK/ok.txt" "contains arm64" "arm64 present"
expect_note "$WORK/ok.txt" "contains x86_64" "x86_64 present"

# --- 2. missing driver -------------------------------------------------------
echo ""
echo "2. missing driver"
run_verify "$WORK/missing.txt" --driver "$WORK/absent/SoundBridgeDriver.driver" --app "$APP"
expect_rc 1 "missing driver fails"
expect_note "$WORK/missing.txt" "driver bundle missing" "missing driver is named"
expect_line "$WORK/missing.txt" "PKG_DRIVER_STRUCTURE=STRUCTURAL_FAIL" "missing driver verdict"

# --- 3. version mismatch -----------------------------------------------------
echo ""
echo "3. version mismatch"
run_verify "$WORK/version.txt" --driver "$REAL_DRIVER" --expect-version 9.9.9
expect_rc 1 "version mismatch fails"
expect_note "$WORK/version.txt" "driver version is '1.1.1', expected '9.9.9'" "version mismatch is specific"

# --- 4. bundle identifier mismatch -------------------------------------------
echo ""
echo "4. bundle identifier mismatch"
ditto "$REAL_DRIVER" "$WORK/id-driver.driver"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.wrong' \
    "$WORK/id-driver.driver/Contents/Info.plist"
run_verify "$WORK/id.txt" --driver "$WORK/id-driver.driver" --expect-version 1.1.1
expect_rc 1 "identifier mismatch fails"
expect_note "$WORK/id.txt" "CFBundleIdentifier is 'com.example.wrong'" "identifier mismatch is specific"

# --- 5. missing architecture -------------------------------------------------
echo ""
echo "5. missing architecture"
ditto "$REAL_DRIVER" "$WORK/thin-driver.driver"
MACHO="Contents/MacOS/SoundBridgeDriver"
lipo -thin arm64 -output "$WORK/thin.bin" "$WORK/thin-driver.driver/$MACHO"
cp "$WORK/thin.bin" "$WORK/thin-driver.driver/$MACHO"
chmod 755 "$WORK/thin-driver.driver/$MACHO"
run_verify "$WORK/thin.txt" --driver "$WORK/thin-driver.driver" --expect-version 1.1.1
expect_rc 1 "arm64-only driver fails"
expect_note "$WORK/thin.txt" "x86_64 missing" "the missing architecture is named"

# --- 6. driver replaced ------------------------------------------------------
echo ""
echo "6. driver content replaced"
ditto "$REAL_DRIVER" "$WORK/edit-driver.driver"
printf 'tampered' >> "$WORK/edit-driver.driver/$MACHO"
run_verify "$WORK/edit.txt" --driver "$WORK/edit-driver.driver" --app "$APP"
expect_rc 1 "modified driver fails"
expect_note "$WORK/edit.txt" "differs from the app's driver" "content drift is detected"

# --- 7. require-developer-id -------------------------------------------------
echo ""
echo "7. --require-developer-id on an unsigned driver"
run_verify "$WORK/reqid.txt" --driver "$REAL_DRIVER" --app "$APP" --require-developer-id
expect_rc 4 "require-developer-id rejects an unsigned driver"
expect_note "$WORK/reqid.txt" "is not Developer ID signed" "refusal explains why"

# --- 8. tamper detection on an already signed object -------------------------
# The Sparkle Updater.app carries a real ad-hoc signature from its vendor, so it
# can show that a broken seal is caught without signing anything here.
echo ""
echo "8. signature integrity on an already signed object"
run_verify "$WORK/signed-before.txt" --driver "$SPARKLE_UPDATER" \
    --expect-id org.sparkle-project.Sparkle.Updater
expect_rc 0 "signed Updater.app verifies"
expect_note "$WORK/signed-before.txt" "SIGPASS" "seal is valid before tampering"
expect_note "$WORK/signed-before.txt" "codesign --verify --strict" "strict verification ran"

ditto "$SPARKLE_UPDATER" "$WORK/tampered.app"
printf 'tampered' >> "$WORK/tampered.app/Contents/MacOS/Updater"
run_verify "$WORK/signed-after.txt" --driver "$WORK/tampered.app" \
    --expect-id org.sparkle-project.Sparkle.Updater
expect_note "$WORK/signed-after.txt" "SIGFAIL" "broken seal is caught"
expect_note "$WORK/signed-after.txt" "codesign --verify --strict (exit" "the failing check is named"

# --- 9. usage ----------------------------------------------------------------
echo ""
echo "9. usage"
run_verify "$WORK/usage.txt"
expect_rc 2 "no arguments is a usage error"

echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: $CHECKS checks, 0 failures"
    exit 0
fi
echo "FAIL: $CHECKS checks, $FAILS failures"
exit 1
