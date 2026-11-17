#!/bin/bash
#
# Exercise tools/sb_install_transaction.sh against temporary directories only.
#
# Phase 2.2.1. Every scenario builds its own fake driver bundle under a fresh
# mktemp directory, so the real HAL directory (/Library/Audio/Plug-Ins/HAL) is
# never read, written, or even referenced as a path that could resolve. Nothing
# here calls sudo, `installer`, or killall.
#
# The failures that matter are not "the function returned an error" -- they are
# "the process died in the middle and left the disk half-changed". Deterministic
# faults cover the error paths; a real SIGKILL between the two renames covers the
# crash path, followed by --mode recover.
#
# Usage
#   tools/test_install_transaction.sh          # run everything
#   tools/test_install_transaction.sh --keep   # keep the temp dirs for inspection
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TX="$ROOT_DIR/tools/sb_install_transaction.sh"
DRIVER_NAME="SoundBridgeDriver.driver"
DRIVER_ID="com.soundbridge.driver"

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

for tool in /usr/bin/ditto /usr/bin/lipo /usr/bin/shasum /usr/libexec/PlistBuddy; do
    [[ -x "$tool" ]] || { echo "missing required tool: $tool" >&2; exit 2; }
done
[[ -x "$TX" ]] || { echo "missing $TX" >&2; exit 2; }

# The stub binary only has to be a real Mach-O with readable architectures. The
# architecture list is discovered at run time and written into the manifest, so
# this test does not hard-code arm64/x86_64 and cannot silently pass on a machine
# where the real driver would fail.
SYSTEM_BINARY="/usr/bin/true"
STUB_ARCHS="$(/usr/bin/lipo -archs "$SYSTEM_BINARY" 2>/dev/null)"
[[ -n "$STUB_ARCHS" ]] || { echo "cannot read architectures from $SYSTEM_BINARY" >&2; exit 2; }

OWNER="$(id -un):$(id -gn)"

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  FAIL  %s\n' "$1"; }

assert_exit() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then pass "$label (exit $actual)"; else fail "$label (expected exit $expected, got $actual)"; fi
}

assert_version() {
    local label="$1" expected="$2" dir="$3" actual
    actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dir/Contents/Info.plist" 2>/dev/null)"
    if [[ "$expected" == "$actual" ]]; then pass "$label (version $actual)"; else fail "$label (expected version $expected, got '${actual:-<missing>}')"; fi
}

assert_absent() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then pass "$label"; else fail "$label ($path still exists)"; fi
}

assert_present() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then pass "$label"; else fail "$label ($path missing)"; fi
}

assert_same_tree() {
    local label="$1" a="$2" b="$3"
    if [[ "$(tree_hash "$a")" == "$(tree_hash "$b")" ]]; then pass "$label"; else fail "$label (bundle contents differ)"; fi
}

assert_log_contains() {
    local label="$1" needle="$2" file="$3"
    if grep -q -- "$needle" "$file" 2>/dev/null; then pass "$label"; else fail "$label (log has no '$needle')"; fi
}

tree_hash() {
    local dir="$1" out
    out="$(
        cd "$dir" 2>/dev/null || exit 1
        find . -type f | LC_ALL=C sort | while IFS= read -r f; do
            printf '%s ' "$f"
            /usr/bin/shasum -a 256 "$f" | /usr/bin/awk '{print $1}'
        done
    )"
    printf '%s' "$out" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

# --- fixtures ---------------------------------------------------------------

make_bundle() {
    local dir="$1" version="$2" protocol="$3" bid="$4" exe="${5:-SoundBridgeDriver}"
    mkdir -p "$dir/Contents/MacOS" || return 1
    /bin/cp "$SYSTEM_BINARY" "$dir/Contents/MacOS/$exe" || return 1
    /bin/chmod 755 "$dir/Contents/MacOS/$exe"
    cat >"$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$bid</string>
    <key>CFBundleExecutable</key><string>$exe</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>SBAudioProtocolVersion</key><integer>$protocol</integer>
</dict>
</plist>
PLIST
}

write_manifest() {
    local file="$1" version="$2" protocol="$3" bid="$4" archs="$5"
    cat >"$file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$bid</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>SBAudioProtocolVersion</key><integer>$protocol</integer>
    <key>Architectures</key><string>$archs</string>
</dict>
</plist>
PLIST
}

# new_case NAME -> sets WORK, DIRS and a payload/dest/state layout
new_case() {
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/sb-tx.XXXXXX")" || exit 2
    PAYLOAD="$WORK/payload/driver"
    MANIFEST="$WORK/payload/manifest.plist"
    HAL="$WORK/hal"
    STATE="$WORK/state"
    DEST="$HAL/$DRIVER_NAME"
    mkdir -p "$PAYLOAD" "$HAL" "$STATE"
    # A payload driver at 1.1.2 with protocol 131328 (0x00020100), matching a
    # manifest that describes it.
    make_bundle "$PAYLOAD/$DRIVER_NAME" "1.1.2" "131328" "$DRIVER_ID"
    write_manifest "$MANIFEST" "1.1.2" "131328" "$DRIVER_ID" "$STUB_ARCHS"
    LOG="$WORK/run.log"
}

cleanup_case() {
    if [[ $KEEP -eq 1 ]]; then
        printf '        kept: %s\n' "$WORK"
    else
        /bin/rm -rf "$WORK"
    fi
}

run_tx() {
    SB_INSTALL_TESTING=1 "$TX" \
        --payload "$PAYLOAD" \
        --manifest "$MANIFEST" \
        --dest "$DEST" \
        --state "$STATE" \
        --owner "$OWNER" \
        "$@" >"$LOG" 2>&1
}

title() { printf '\n%s\n' "$1"; }

# --- scenarios --------------------------------------------------------------

title "1. fresh install (no driver present)"
new_case
run_tx; rc=$?
assert_exit "fresh install succeeds" 0 "$rc"
assert_present "driver is installed" "$DEST"
assert_version "installed version" "1.1.2" "$DEST"
assert_absent "no backup left behind" "$STATE/backup"
assert_absent "no staging left behind" "$STATE/staging"
assert_absent "transaction state is cleared" "$STATE/transaction.state"
cleanup_case

title "2. replace an older driver"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
run_tx; rc=$?
assert_exit "replace succeeds" 0 "$rc"
assert_version "driver was replaced" "1.1.2" "$DEST"
assert_absent "no backup left behind" "$STATE/backup"
cleanup_case

title "3. payload bundle is missing its executable"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
/bin/rm -f "$PAYLOAD/$DRIVER_NAME/Contents/MacOS/SoundBridgeDriver"
run_tx; rc=$?
assert_exit "install is refused" 1 "$rc"
assert_version "existing driver untouched" "1.1.1" "$DEST"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "existing driver content unchanged" || fail "existing driver content changed"
assert_log_contains "the refusal names the missing executable" "executable missing" "$LOG"
cleanup_case

title "4. payload bundle id does not match the manifest"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
make_bundle "$PAYLOAD/$DRIVER_NAME" "1.1.2" "131328" "com.example.not-soundbridge"
run_tx; rc=$?
assert_exit "install is refused" 1 "$rc"
assert_version "existing driver untouched" "1.1.1" "$DEST"
assert_log_contains "the refusal names the bundle id" "bundle id" "$LOG"
cleanup_case

title "5. payload version does not match the manifest"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
write_manifest "$MANIFEST" "1.3.0" "131328" "$DRIVER_ID" "$STUB_ARCHS"
run_tx; rc=$?
assert_exit "install is refused" 1 "$rc"
assert_version "existing driver untouched" "1.1.1" "$DEST"
assert_log_contains "the refusal names the version" "version" "$LOG"
cleanup_case

title "6. payload protocol does not match the manifest"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
write_manifest "$MANIFEST" "1.1.2" "131584" "$DRIVER_ID" "$STUB_ARCHS"
run_tx; rc=$?
assert_exit "install is refused" 1 "$rc"
assert_version "existing driver untouched" "1.1.1" "$DEST"
assert_log_contains "the refusal names the protocol" "protocol" "$LOG"
cleanup_case

title "7. payload is missing a required architecture"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
write_manifest "$MANIFEST" "1.1.2" "131328" "$DRIVER_ID" "$STUB_ARCHS i386"
run_tx; rc=$?
assert_exit "install is refused" 1 "$rc"
assert_version "existing driver untouched" "1.1.1" "$DEST"
assert_log_contains "the refusal names the architecture" "architecture" "$LOG"
cleanup_case

title "8. the destination is not the SoundBridge driver"
new_case
make_bundle "$DEST" "9.9.9" "1" "com.example.someone-elses-driver"
FOREIGN="$(tree_hash "$DEST")"
run_tx; rc=$?
assert_exit "install is refused" 1 "$rc"
assert_present "the foreign bundle still exists" "$DEST"
[[ "$(tree_hash "$DEST")" == "$FOREIGN" ]] && pass "the foreign bundle is untouched" || fail "the foreign bundle was modified"
assert_log_contains "the refusal explains why" "not the SoundBridge driver" "$LOG"
cleanup_case

title "9. copying into staging fails"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
run_tx --test-fault staging; rc=$?
assert_exit "install is refused" 1 "$rc"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "existing driver unchanged" || fail "existing driver was modified"
assert_absent "nothing was written next to the driver" "$HAL/.sb-tx-any"
[[ "$(/bin/ls -A "$HAL")" == "$DRIVER_NAME" ]] && pass "the destination directory holds only the original driver" \
    || fail "the destination directory holds: $(/bin/ls -A "$HAL")"
cleanup_case

title "10. taking the backup fails"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
run_tx --test-fault backup; rc=$?
assert_exit "install is refused" 1 "$rc"
assert_version "existing driver untouched" "1.1.1" "$DEST"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "existing driver unchanged" || fail "existing driver was modified"
cleanup_case

title "11. moving the new driver into place fails"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
run_tx --test-fault replace; rc=$?
assert_exit "install fails and rolls back" 2 "$rc"
assert_present "the previous driver is back" "$DEST"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the previous driver is byte-identical" || fail "the restored driver differs"
assert_absent "staging is cleaned up" "$STATE/staging"
assert_log_contains "the rollback is reported" "ROLLED BACK" "$LOG"
cleanup_case

title "12. post-install verification fails"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
run_tx --test-fault verify; rc=$?
assert_exit "install fails and rolls back" 2 "$rc"
assert_present "the previous driver is back" "$DEST"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the previous driver is byte-identical" || fail "the restored driver differs"
assert_version "the restored driver is the old version" "1.1.1" "$DEST"
cleanup_case

title "13. rollback itself fails"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
# Verification fails first (so a rollback is attempted), then the rollback's own
# restore step fails: the one case that must never be reported as a success.
run_tx --test-fault verify,rollback; rc=$?
assert_exit "a failed rollback is reported separately" 3 "$rc"
assert_log_contains "the log says ROLLBACK FAILED" "ROLLBACK FAILED" "$LOG"
assert_log_contains "the log tells the operator what to do" "run the SoundBridge installer again" "$LOG"
assert_present "the backup is kept for the operator" "$STATE/backup"
cleanup_case

title "14. running the install twice is idempotent"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
run_tx; first=$?
run_tx; second=$?
assert_exit "first run succeeds" 0 "$first"
assert_exit "second run succeeds" 0 "$second"
assert_version "the driver is the new version" "1.1.2" "$DEST"
assert_absent "no backup left behind" "$STATE/backup"
assert_absent "no staging left behind" "$STATE/staging"
cleanup_case

title "15. killed between the two renames, then recovered by --mode recover"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
    --state "$STATE" --owner "$OWNER" --test-pause replace-gap >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 200); do
    [[ ! -e "$DEST" ]] && grep -q 'stage=replacing-intent' "$STATE/transaction.state" 2>/dev/null && break
    /bin/sleep 0.05
done
CHILDREN="$(/usr/bin/pgrep -P "$PID" 2>/dev/null)"
kill -9 "$PID" 2>/dev/null
[[ -n "$CHILDREN" ]] && kill -9 $CHILDREN 2>/dev/null
wait "$PID" 2>/dev/null
assert_absent "the destination is empty after the kill" "$DEST"
assert_present "the state file records the interrupted stage" "$STATE/transaction.state"
assert_present "the previous driver survived as the moved-aside copy" "$STATE/backup/$DRIVER_NAME.live"
run_tx --mode recover; rc=$?
assert_exit "recovery succeeds" 0 "$rc"
assert_present "the previous driver is back" "$DEST"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the recovered driver is byte-identical" || fail "the recovered driver differs"
assert_absent "the transaction state is cleared" "$STATE/transaction.state"
assert_log_contains "recovery says it restored the driver" "restored the previous driver" "$LOG"
cleanup_case

title "16. killed between the two renames, then the installer is run again"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
    --state "$STATE" --owner "$OWNER" --test-pause replace-gap >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 200); do
    [[ ! -e "$DEST" ]] && grep -q 'stage=replacing-intent' "$STATE/transaction.state" 2>/dev/null && break
    /bin/sleep 0.05
done
CHILDREN="$(/usr/bin/pgrep -P "$PID" 2>/dev/null)"
kill -9 "$PID" 2>/dev/null
[[ -n "$CHILDREN" ]] && kill -9 $CHILDREN 2>/dev/null
wait "$PID" 2>/dev/null
run_tx; rc=$?
assert_exit "the rerun recovers and then installs" 0 "$rc"
assert_version "the driver is the new version" "1.1.2" "$DEST"
assert_absent "no backup left behind" "$STATE/backup"
cleanup_case

title "17. leftover staging from a run that died before replacing"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
mkdir -p "$STATE/staging"
make_bundle "$STATE/staging/$DRIVER_NAME" "1.1.2" "131328" "$DRIVER_ID"
printf 'stage=staging-done\nstarted=1\npid=1\ndest=%s\nid=%s\ndetail=\n' "$DEST" "$DRIVER_ID" >"$STATE/transaction.state"
run_tx --mode recover; rc=$?
assert_exit "recovery succeeds" 0 "$rc"
assert_absent "the stale staging copy is removed" "$STATE/staging"
assert_absent "the transaction state is cleared" "$STATE/transaction.state"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the installed driver was not touched" || fail "the installed driver was modified"
cleanup_case

title "18. a failed first install leaves no half-installed driver"
new_case
run_tx --test-fault replace; rc=$?
assert_exit "install fails and rolls back" 2 "$rc"
assert_absent "no driver is left behind" "$DEST"
assert_log_contains "the rollback explains there was no previous driver" "no previous driver existed" "$LOG"
cleanup_case

title "19. the payload directory is missing entirely"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
/bin/rm -rf "$PAYLOAD"
run_tx; rc=$?
assert_exit "install is refused" 1 "$rc"
assert_version "existing driver untouched" "1.1.1" "$DEST"
cleanup_case

title "20. the state directory cannot be created"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
/bin/rm -rf "$STATE"
: >"$WORK/blocked"   # a regular file where the state directory should be
mv "$WORK/blocked" "$STATE"
run_tx; rc=$?
assert_exit "the environment problem is reported, not a fake success" 4 "$rc"
assert_version "existing driver untouched" "1.1.1" "$DEST"
cleanup_case

title "21. two installs racing for the same destination"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"

# A holds the lock and is paused between the two renames. B starts afterwards and
# has to leave without touching state, staging, backup or the destination.
SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
    --state "$STATE" --owner "$OWNER" --test-pause replace-gap >"$WORK/a.log" 2>&1 &
A_PID=$!
for _ in $(seq 1 200); do
    [[ ! -e "$DEST" ]] && grep -q 'stage=replacing-intent' "$STATE/transaction.state" 2>/dev/null && break
    /bin/sleep 0.05
done
assert_present "the first run holds the lock" "$STATE/transaction.lock"

SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
    --state "$STATE" --owner "$OWNER" >"$WORK/b.log" 2>&1
rc=$?
assert_exit "the second run exits without working" 5 "$rc"
assert_log_contains "the second run says it is busy" "BUSY" "$WORK/b.log"
assert_log_contains "the second run states that it modified nothing" "did not modify" "$WORK/b.log"
if grep -q 'stage=replacing-intent' "$STATE/transaction.state" 2>/dev/null; then
    pass "the first run's state record was not rewritten"
else
    fail "the second run modified transaction.state"
fi
assert_present "the first run's staging copy survived" "$STATE/staging/$DRIVER_NAME"
assert_absent "the second run installed nothing of its own" "$DEST"

A_CHILDREN="$(/usr/bin/pgrep -P "$A_PID" 2>/dev/null)"
kill -9 "$A_PID" 2>/dev/null
[[ -n "$A_CHILDREN" ]] && kill -9 $A_CHILDREN 2>/dev/null
wait "$A_PID" 2>/dev/null
assert_present "the killed run left its lock behind" "$STATE/transaction.lock"

run_tx --mode recover; rc=$?
assert_exit "the next run reclaims the stale lock and recovers" 0 "$rc"
assert_log_contains "the stale lock is reported, not silently taken" "reclaimed a stale lock" "$LOG"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the previous driver is byte-identical after the race" || fail "the driver differs after the race"
assert_absent "the lock is gone once the transaction ends" "$STATE/transaction.lock"
cleanup_case

title "22. recovery racing a live install"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"

SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
    --state "$STATE" --owner "$OWNER" --test-pause replace-gap >"$WORK/a.log" 2>&1 &
A_PID=$!
for _ in $(seq 1 200); do
    [[ ! -e "$DEST" ]] && grep -q 'stage=replacing-intent' "$STATE/transaction.state" 2>/dev/null && break
    /bin/sleep 0.05
done
assert_present "the live install holds the lock" "$STATE/transaction.lock"

# This is the dangerous one: recovery deletes staging. Running it here would rob
# the live install of the copy it is about to promote.
SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
    --state "$STATE" --owner "$OWNER" --mode recover >"$WORK/r.log" 2>&1
rc=$?
assert_exit "recovery refuses to run alongside an install" 5 "$rc"
assert_log_contains "recovery says why it stopped" "BUSY" "$WORK/r.log"
assert_present "the live install's staging copy is intact" "$STATE/staging/$DRIVER_NAME"
assert_present "the moved-aside driver is intact" "$STATE/backup/$DRIVER_NAME.live"

A_CHILDREN="$(/usr/bin/pgrep -P "$A_PID" 2>/dev/null)"
kill -9 "$A_PID" 2>/dev/null
[[ -n "$A_CHILDREN" ]] && kill -9 $A_CHILDREN 2>/dev/null
wait "$A_PID" 2>/dev/null
run_tx --mode recover; rc=$?
assert_exit "a solo recovery afterwards succeeds" 0 "$rc"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the previous driver is restored" || fail "the driver differs after recovery"
cleanup_case

title "23. a newer driver on disk is not downgraded"
new_case
make_bundle "$DEST" "1.1.3" "131328" "$DRIVER_ID"   # the payload carries 1.1.2
BEFORE="$(tree_hash "$DEST")"
run_tx; rc=$?
assert_exit "the downgrade is refused" 1 "$rc"
assert_version "the newer driver is untouched" "1.1.3" "$DEST"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the newer driver content is unchanged" || fail "the newer driver content changed"
assert_log_contains "the refusal names the downgrade" "refusing to downgrade" "$LOG"
cleanup_case

title "24. reinstalling the version that is already installed"
new_case
make_bundle "$DEST" "1.1.2" "131328" "$DRIVER_ID"
printf 'left over\n' >"$DEST/Contents/MacOS/stale-file"
run_tx; rc=$?
assert_exit "a same-version reinstall is allowed" 0 "$rc"
assert_version "the version is unchanged" "1.1.2" "$DEST"
assert_absent "the fresh copy replaced the old contents" "$DEST/Contents/MacOS/stale-file"
assert_log_contains "the log calls it a reinstall" "reinstall" "$LOG"
cleanup_case

title "25. the installed driver has no readable version"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleShortVersionString' "$DEST/Contents/Info.plist" >/dev/null 2>&1
BEFORE="$(tree_hash "$DEST")"
run_tx; rc=$?
assert_exit "install is refused" 1 "$rc"
assert_log_contains "the refusal says the version cannot be read" "cannot be read" "$LOG"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the existing driver is untouched" || fail "the existing driver changed"
cleanup_case

title "26. the installed driver reports an unparseable version"
new_case
make_bundle "$DEST" "1.1.x" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
run_tx; rc=$?
assert_exit "install is refused" 1 "$rc"
assert_log_contains "the refusal says the version cannot be compared" "unparseable version" "$LOG"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the existing driver is untouched" || fail "the existing driver changed"
cleanup_case

title "27. a newer protocol on disk outranks the version string"
new_case
# Older version, newer wire format. Only the protocol gate can catch this, which
# is the order DriverVersionGate uses in the app.
make_bundle "$DEST" "1.0.0" "131329" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
run_tx; rc=$?
assert_exit "the protocol downgrade is refused" 1 "$rc"
assert_log_contains "the refusal names the wire format" "never downgrades the wire format" "$LOG"
if grep -q 'refusing to downgrade' "$LOG" 2>/dev/null; then
    fail "the version gate answered instead of the protocol gate"
else
    pass "the protocol gate answered before the version gate"
fi
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the existing driver is untouched" || fail "the existing driver changed"
cleanup_case

title "28. rerunning the installer after a rolled-back failure"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
run_tx --test-fault replace; rc=$?
assert_exit "the first run rolls back" 2 "$rc"
assert_version "the old driver is back" "1.1.1" "$DEST"
run_tx; rc=$?
assert_exit "the second run installs cleanly" 0 "$rc"
assert_version "the driver is now the packaged version" "1.1.2" "$DEST"
assert_absent "no backup left behind" "$STATE/backup"
assert_absent "transaction state is cleared" "$STATE/transaction.state"
cleanup_case

title "29. a challenger must not take a lock that is still being initialised"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"

# A is held inside the gap between `mkdir $LOCK_DIR` and the pid write. That gap is
# microseconds in production, which is why it needs a hook: it is the one moment
# where the directory exists without saying who owns it.
SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
    --state "$STATE" --owner "$OWNER" --test-pause lock-init >"$WORK/a.log" 2>&1 &
A_PID=$!
for _ in $(seq 1 200); do
    [[ -d "$STATE/transaction.lock" ]] && [[ ! -e "$STATE/transaction.lock/pid" ]] && break
    /bin/sleep 0.05
done
assert_present "A holds the lock directory" "$STATE/transaction.lock"
assert_absent "A has not written its pid yet" "$STATE/transaction.lock/pid"

SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
    --state "$STATE" --owner "$OWNER" >"$WORK/b.log" 2>&1
rc=$?
assert_exit "B leaves without taking the lock" 5 "$rc"
assert_log_contains "B reads the empty lock as an owner still initialising" "recorded no owner" "$WORK/b.log"
if grep -q 'reclaimed a stale lock' "$WORK/b.log" 2>/dev/null; then
    fail "B deleted a lock whose owner was still initialising"
else
    pass "B did not reclaim a lock that was being initialised"
fi
assert_present "A's lock survived B" "$STATE/transaction.lock"
assert_absent "B wrote no state record" "$STATE/transaction.state"
assert_absent "B created no staging directory" "$STATE/staging"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "B left the destination untouched" || fail "B changed the destination"

# Release A. It finishes initialising and has to remain the only holder.
: >"$STATE/test-gate"
wait "$A_PID"; rc=$?
assert_exit "A completes the whole transaction once released" 0 "$rc"
assert_version "A installed its own payload" "1.1.2" "$DEST"
assert_absent "A released the lock on exit" "$STATE/transaction.lock"
cleanup_case

title "30. two recoveries racing for the same stale lock"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"

DEAD_PID=""
for candidate in 999999 999998 888888 777777 666666; do
    /bin/ps -p "$candidate" >/dev/null 2>&1 || { DEAD_PID="$candidate"; break; }
done
if [[ -z "$DEAD_PID" ]]; then
    fail "no pid in the search range is free, cannot forge a stale lock"
else
    RACES=5
    RECLAIMS=0
    BAD_RC=0
    REMAIN=0
    for _round in $(seq 1 $RACES); do
        /bin/rm -rf "$STATE/transaction.lock" "$STATE/transaction.lock.reclaim"
        mkdir "$STATE/transaction.lock"
        printf '%s\n' "$DEAD_PID" >"$STATE/transaction.lock/pid"

        SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
            --state "$STATE" --owner "$OWNER" --mode recover >"$WORK/r1.log" 2>&1 &
        P1=$!
        SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
            --state "$STATE" --owner "$OWNER" --mode recover >"$WORK/r2.log" 2>&1 &
        P2=$!
        wait "$P1"; RC1=$?
        wait "$P2"; RC2=$?
        for r in "$RC1" "$RC2"; do
            case "$r" in 0|5) : ;; *) BAD_RC=$((BAD_RC + 1)) ;; esac
        done
        RECLAIMS=$((RECLAIMS + $(grep -c 'reclaimed a stale lock' "$WORK/r1.log" 2>/dev/null) \
                             + $(grep -c 'reclaimed a stale lock' "$WORK/r2.log" 2>/dev/null)))
        [[ -e "$STATE/transaction.lock" || -e "$STATE/transaction.lock.reclaim" ]] && REMAIN=$((REMAIN + 1))
    done
    assert_exit "every racer exits 0 (ran) or 5 (gave way)" 0 "$BAD_RC"
    # One stale lock, one reclamation. A second process that also deleted it would
    # show up here as a count above one per round.
    if [[ "$RECLAIMS" -eq "$RACES" ]]; then
        pass "each stale lock was reclaimed exactly once ($RECLAIMS of $RACES rounds)"
    else
        fail "stale locks were reclaimed $RECLAIMS times across $RACES rounds"
    fi
    assert_exit "no round left a lock or a reclaim gate behind" 0 "$REMAIN"
    [[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the driver is unchanged by the races" || fail "the driver changed during the races"
fi
cleanup_case

title "31. a version segment too long to compare is refused before anything moves"
new_case
make_bundle "$DEST" "999999999999999999.1.0" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
run_tx; rc=$?
assert_exit "the install is refused" 1 "$rc"
assert_log_contains "the refusal says the segment cannot be compared" "more than the 9" "$LOG"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the existing driver is untouched" || fail "the existing driver changed"

new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
make_bundle "$PAYLOAD/$DRIVER_NAME" "999999999999999999.1.0" "131328" "$DRIVER_ID"
write_manifest "$MANIFEST" "999999999999999999.1.0" "131328" "$DRIVER_ID" "$STUB_ARCHS"
run_tx; rc=$?
assert_exit "the payload is refused" 1 "$rc"
assert_log_contains "the payload refusal names the segment" "more than the 9" "$LOG"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the existing driver is untouched" || fail "the existing driver changed"

new_case
# 2^63 is the first value that wraps the signed comparison: on its own it turns a
# downgrade into an apparent upgrade, which is the case that matters most.
make_bundle "$DEST" "9223372036854775808" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
run_tx; rc=$?
assert_exit "a segment that would wrap is refused" 1 "$rc"
assert_log_contains "the wrap is named as the reason" "more than the 9" "$LOG"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the existing driver is untouched" || fail "the existing driver changed"
cleanup_case

title "32. version comparison edge cases still hold"
new_case
make_bundle "$DEST" "1.1" "131328" "$DRIVER_ID"
make_bundle "$PAYLOAD/$DRIVER_NAME" "1.1.0" "131328" "$DRIVER_ID"
write_manifest "$MANIFEST" "1.1.0" "131328" "$DRIVER_ID" "$STUB_ARCHS"
run_tx; rc=$?
assert_exit "1.1 and 1.1.0 are the same version" 0 "$rc"
assert_log_contains "the pair is treated as a reinstall" "reinstall" "$LOG"

new_case
make_bundle "$DEST" "1.1.09" "131328" "$DRIVER_ID"
make_bundle "$PAYLOAD/$DRIVER_NAME" "1.1.10" "131328" "$DRIVER_ID"
write_manifest "$MANIFEST" "1.1.10" "131328" "$DRIVER_ID" "$STUB_ARCHS"
run_tx; rc=$?
assert_exit "a leading zero stays decimal" 0 "$rc"
assert_log_contains "09 -> 10 is read as an upgrade" "version move: 1.1.09 -> 1.1.10 (upgrade)" "$LOG"
assert_version "the driver is now 1.1.10" "1.1.10" "$DEST"
cleanup_case

title "33. a run that cannot record its own pid does not proceed"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
BEFORE="$(tree_hash "$DEST")"
run_tx --test-fault lock-pid; rc=$?
assert_exit "the run stops instead of working unrecorded" 4 "$rc"
assert_log_contains "the reason is stated" "could not record this run's pid" "$LOG"
assert_absent "it gave the lock directory back" "$STATE/transaction.lock"
assert_absent "it wrote no state record" "$STATE/transaction.state"
[[ "$(tree_hash "$DEST")" == "$BEFORE" ]] && pass "the destination is untouched" || fail "the destination changed"
cleanup_case

title "34. a run never releases a lock it does not own"
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"

SB_INSTALL_TESTING=1 "$TX" --payload "$PAYLOAD" --manifest "$MANIFEST" --dest "$DEST" \
    --state "$STATE" --owner "$OWNER" --test-pause lock-held >"$WORK/a.log" 2>&1 &
A_PID=$!
for _ in $(seq 1 200); do
    [[ "$(cat "$STATE/transaction.lock/pid" 2>/dev/null)" == "$A_PID" ]] && break
    /bin/sleep 0.05
done
assert_present "A recorded itself as the owner" "$STATE/transaction.lock/pid"
# Hand the lock to somebody else now that A holds it. A must not delete a
# directory that no longer records it as the owner.
printf '%s\n' "$$" >"$STATE/transaction.lock/pid"
: >"$STATE/test-gate"
wait "$A_PID"; rc=$?
assert_exit "the run still completes its own work" 0 "$rc"
assert_version "the driver was installed" "1.1.2" "$DEST"
assert_present "the lock that no longer names it was left alone" "$STATE/transaction.lock"
cleanup_case

title "35. a failed install never reports success"
# Phase 3.2D §4.3. The success record is the one thing a user never sees, so a
# failure that leaves it behind turns a broken install into a silent one: the
# next run believes the driver is current. Case 12 proved the driver is restored;
# this proves the record does not lie about it.
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
run_tx --test-fault verify; rc=$?
assert_exit "the install fails and rolls back" 2 "$rc"
assert_log_contains "the rollback is reported" "ROLLED BACK" "$LOG"
if grep -q 'SUCCESS:' "$LOG"; then
    fail "a failed install wrote a SUCCESS line"
else
    pass "a failed install writes no SUCCESS line"
fi
assert_absent "the failure left no state record claiming anything" "$STATE/transaction.state"
assert_version "the old driver is still the installed one" "1.1.1" "$DEST"
cleanup_case

title "36. a failed rollback records the failure, and deletes nothing it did not create"
# §2.5. When the rollback itself fails the machine is in an unknown state; the
# one thing the transaction must not do is tidy up. A record that says
# `rollback-failed` is what makes the next run -- and the user -- diagnosable.
new_case
make_bundle "$DEST" "1.1.1" "131328" "$DRIVER_ID"
printf 'written by an operator, not by the transaction\n' >"$STATE/operator-note.txt"
run_tx --test-fault verify,rollback; rc=$?
assert_exit "the failed rollback is reported separately" 3 "$rc"
assert_present "the failure is recorded" "$STATE/transaction.state"
if grep -q 'stage=rollback-failed' "$STATE/transaction.state"; then
    pass "the record names the failure, not a stage that implies progress"
else
    fail "the record says: $(/usr/bin/head -1 "$STATE/transaction.state")"
fi
if grep -q 'stage=success' "$STATE/transaction.state"; then
    fail "the failure was recorded as a success"
else
    pass "the record does not claim success"
fi
assert_present "a file the transaction did not create is left alone" "$STATE/operator-note.txt"
cleanup_case

# --- summary ----------------------------------------------------------------

printf '\n%s\n' "──────────────────────────────────────────────"
printf 'transaction scenarios: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    printf 'failed assertions:\n'
    for name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$name"; done
    exit 1
fi
printf 'the HAL directory was never touched by this test run\n'
exit 0
