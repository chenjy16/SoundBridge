#!/bin/bash
#
# Exercise tools/uninstall_driver.sh against disposable sandboxes.
#
# Stage E (1.2.1). The uninstaller is the one tool here that deletes things, so
# its lifecycle is tested for real -- not by stubbing `rm` -- on trees that copy
# the layout a real machine has. Every scenario builds its own mktemp directory
# and passes --sandbox-root, which re-roots every owned path under it. The real
# /Library/Audio/Plug-Ins/HAL, the real /tmp mappings, the real preferences and
# the real app bundle are never read, written, or signalled. Nothing here calls
# sudo and nothing here signals coreaudiod.
#
# What is asserted, scenario by scenario: the removal happens; a second run is a
# no-op that still exits 0; nothing that is not ours is touched (another vendor's
# HAL bundle, another user's mappings, the app bundle, user state, logs, the
# package receipt); a Host that ignores TERM is escalated only after the bounded
# wait and only against pids re-confirmed as ours; a removal that fails is
# reported with exit 1 instead of a cheerful summary; and --dry-run changes
# nothing.
#
# The Host fixtures are real processes: a tiny compiled program installed under
# the sandbox as `bin/SoundBridgeHost`, so `ps -o comm=` reports a path the
# script's ownership check accepts, and `--keep-host` can be seen to leave it
# running. It is compiled rather than copied because a copy of a platform binary
# is refused by the kernel here, and a shell script would report its interpreter
# as `comm` instead of its own path. Where this machine cannot compile it or
# cannot read process state, the process scenarios are reported as skipped
# rather than silently passing.
#
# Usage
#   tools/test_uninstall_lifecycle.sh          # run everything
#   tools/test_uninstall_lifecycle.sh --keep   # keep the sandboxes for inspection
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNINSTALL="$ROOT_DIR/tools/uninstall_driver.sh"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
CLANG="$(command -v clang 2>/dev/null || true)"

DRIVER_ID="com.soundbridge.driver"
HAL_REL="Library/Audio/Plug-Ins/HAL"
DRIVER_REL="$HAL_REL/SoundBridgeDriver.driver"
OWN_UID="$(id -u)"

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

[[ -x "$UNINSTALL" ]] || { echo "missing or not executable: $UNINSTALL" >&2; exit 2; }
[[ -x "$PLIST_BUDDY" ]] || { echo "missing required tool: $PLIST_BUDDY" >&2; exit 2; }

WORK="$(mktemp -d -t sb-uninstall-lifecycle)"
LOG_DIR="$WORK/logs"
mkdir -p "$LOG_DIR"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=""
SKIPPED_NAMES=""
CLEANUP_DIRS=""
FIXTURE_PIDS=""
RUNS=0
LOG=""
RC=0
STDOUT=""

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES="${FAILED_NAMES}  - $1
"
    printf '  FAIL  %s\n' "$1"
}
skip() {
    SKIP=$((SKIP + 1))
    SKIPPED_NAMES="${SKIPPED_NAMES}  - $1
"
    printf '  skip  %s\n' "$1"
}
scenario() { printf '\n%s\n' "-- $*"; }

cleanup() {
    local pid dir
    if [[ -n "$FIXTURE_PIDS" ]]; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            kill -KILL "$pid" 2>/dev/null || true
        done <<< "$FIXTURE_PIDS"
    fi
    if [[ "$KEEP" -eq 1 ]]; then
        printf '\nsandboxes kept in %s and under %s\n' "$WORK" "${TMPDIR:-/tmp}"
        return
    fi
    if [[ -n "$CLEANUP_DIRS" ]]; then
        while IFS= read -r dir; do
            [[ -n "$dir" ]] || continue
            chmod -R u+rwX "$dir" 2>/dev/null || true
            rm -rf "$dir" 2>/dev/null || true
        done <<< "$CLEANUP_DIRS"
    fi
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# --- assertions --------------------------------------------------------------

assert_exit() {
    local label="$1" expected="$2"
    if [[ "$RC" == "$expected" ]]; then pass "$label (exit $RC)"; else fail "$label (expected exit $expected, got $RC)"; fi
}

assert_absent() {
    local label="$1" path="$2"
    if [[ ! -e "$path" && ! -L "$path" ]]; then pass "$label"; else fail "$label ($path still exists)"; fi
}

assert_present() {
    local label="$1" path="$2"
    if [[ -e "$path" || -L "$path" ]]; then pass "$label"; else fail "$label ($path is missing)"; fi
}

assert_out() {
    local label="$1" needle="$2"
    if grep -qF -- "$needle" "$LOG" 2>/dev/null; then pass "$label"; else fail "$label (output has no '$needle')"; fi
}

assert_out_re() {
    local label="$1" pattern="$2"
    if grep -qE -- "$pattern" "$LOG" 2>/dev/null; then pass "$label"; else fail "$label (output does not match /$pattern/)"; fi
}

assert_not_out() {
    local label="$1" needle="$2"
    if grep -qF -- "$needle" "$LOG" 2>/dev/null; then fail "$label (output should not contain '$needle')"; else pass "$label"; fi
}

# --- sandboxes ---------------------------------------------------------------

new_root() {
    local root
    # Physical path: the Host check compares this prefix against `ps -o comm=`,
    # so the test and the script have to agree on /var vs /private/var.
    root="$(cd "$(mktemp -d -t sb-uninstall)" && pwd -P)"
    CLEANUP_DIRS="${CLEANUP_DIRS}${root}
"
    printf '%s' "$root"
}

# The tree a fully installed machine has, minus anything privileged.
make_layout() {
    local root="$1"
    mkdir -p \
        "$root/tmp" \
        "$root/Library/Application Support/SoundBridge" \
        "$root/Library/Logs/SoundBridge" \
        "$root/Library/Preferences" \
        "$root/Applications/SoundBridge.app/Contents/MacOS" \
        "$root/$HAL_REL/OtherVendor.driver/Contents" \
        "$root/$DRIVER_REL/Contents"
    printf '{"device":"default"}\n' > "$root/Library/Application Support/SoundBridge/device-state.json"
    printf 'log line\n' > "$root/Library/Logs/SoundBridge/soundbridge.log"
    printf 'prefs\n' > "$root/Library/Preferences/com.soundbridge.menubar.plist"
    printf 'app\n' > "$root/Applications/SoundBridge.app/Contents/MacOS/SoundBridgeApp"
    printf 'other vendor\n' > "$root/$HAL_REL/OtherVendor.driver/Contents/Info.plist"
    printf 'stale mapping\n' > "$root/tmp/soundbridge-$OWN_UID-0"
    printf 'stale mapping\n' > "$root/tmp/soundbridge-$OWN_UID-1"
    printf 'control\n' > "$root/tmp/soundbridge-devices.txt"
    printf 'not ours\n' > "$root/tmp/unrelated.txt"
    printf 'not our uid\n' > "$root/tmp/soundbridge-999999-other-user"
    printf 'receipt\n' > "$root/receipt-present"
    write_driver "$root"
}

write_driver() {
    local root="$1" id="${2:-$DRIVER_ID}"
    rm -rf "$root/$DRIVER_REL"
    mkdir -p "$root/$DRIVER_REL/Contents"
    "$PLIST_BUDDY" -c "Add :CFBundleIdentifier string $id" \
                   -c 'Add :CFBundleShortVersionString string 1.2.1' \
                   "$root/$DRIVER_REL/Contents/Info.plist" >/dev/null 2>&1 || return 1
    printf 'driver\n' > "$root/$DRIVER_REL/SoundBridgeDriver"
}

# --- Host fixtures -----------------------------------------------------------

process_state_readable() { ps -p $$ -o comm= >/dev/null 2>&1; }

# A real compile is the only honest check: `clang` can be present and still fail
# without an SDK, and a skipped scenario must say why.
fixture_compiles() {
    local out="$WORK/fixture-probe"
    [[ -n "$CLANG" && -x "$CLANG" ]] || return 1
    "$CLANG" -O0 -o "$out" "$(fixture_source)" >/dev/null 2>&1 || return 1
    rm -f "$out"
    return 0
}

process_tests_supported() {
    process_state_readable || return 1
    command -v pgrep >/dev/null 2>&1 || return 1
    fixture_compiles
}

# `kill -0` still answers for a zombie, which has already exited and holds
# nothing. The uninstaller makes the same distinction.
fixture_alive() {
    local state
    state="$(ps -p "$1" -o stat= 2>/dev/null || true)"
    [[ -n "$state" ]] || return 1
    [[ "${state#Z}" == "$state" ]] || return 1
    kill -0 "$1" 2>/dev/null
}

fixture_source() {
    local src="$WORK/host_fixture.c"
    if [[ ! -f "$src" ]]; then
        # Writes a readiness file once the signal disposition is in place, so the
        # test never sends TERM to a process that has not installed its handler
        # yet.
        cat > "$src" <<'SRC'
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    const char *ready = getenv("SB_FIXTURE_READY");
    if (argc > 1 && argv[1][0] == 's') signal(SIGTERM, SIG_IGN);
    if (ready) {
        FILE *f = fopen(ready, "w");
        if (f) fclose(f);
    }
    for (;;) pause();
    return 0;
}
SRC
    fi
    printf '%s' "$src"
}

FIXTURE_PID=""
# mode "stubborn" ignores SIGTERM, so the bounded wait and the escalation run.
spawn_host() {
    local root="$1" mode="${2:-graceful}" bin i ready src
    bin="$root/bin/SoundBridgeHost"
    ready="$root/fixture-ready"
    rm -f "$ready"
    src="$(fixture_source)"
    mkdir -p "$root/bin"
    "$CLANG" -O0 -o "$bin" "$src" 2>/dev/null || return 1
    if [[ "$mode" == "stubborn" ]]; then
        SB_FIXTURE_READY="$ready" "$bin" stubborn >/dev/null 2>&1 &
    else
        SB_FIXTURE_READY="$ready" "$bin" >/dev/null 2>&1 &
    fi
    FIXTURE_PID=$!
    FIXTURE_PIDS="${FIXTURE_PIDS}${FIXTURE_PID}
"
    # The termination of a fixture is the thing under test, not a shell event to
    # narrate: `disown` keeps bash from printing "Terminated: 15" over the
    # assertions. Liveness is read from `ps`, not from the job table.
    disown "$FIXTURE_PID" 2>/dev/null || true
    for i in $(seq 1 100); do
        fixture_alive "$FIXTURE_PID" || return 1
        if [[ -f "$ready" ]] && pgrep -f "$bin" >/dev/null 2>&1; then return 0; fi
        sleep 0.05
    done
    return 1
}

# Stop a fixture the test itself started, so the sandbox cleanup has nothing to
# chase. Killing our own child is not `kill -KILL` against anything else.
reap_fixture() {
    local pid="$1"
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

wait_fixture_dead() {
    local pid="$1" i
    for i in $(seq 1 200); do
        fixture_alive "$pid" || { wait "$pid" 2>/dev/null || true; return 0; }
        sleep 0.05
    done
    return 1
}

# --- running -----------------------------------------------------------------

run() {
    local root="$1"
    shift
    RUNS=$((RUNS + 1))
    LOG="$LOG_DIR/run-$RUNS.log"
    "$UNINSTALL" --sandbox-root "$root" "$@" >"$LOG" 2>&1
    RC=$?
}

# --- scenarios ---------------------------------------------------------------

scenario "normal uninstall (driver, stale mappings, receipt, user data, app)"
ROOT="$(new_root)"
make_layout "$ROOT"
if spawn_host "$ROOT" graceful; then HOST_PID="$FIXTURE_PID"; else HOST_PID=""; fi
run "$ROOT"
assert_exit "full teardown succeeds" 0
assert_absent "driver bundle removed" "$ROOT/$DRIVER_REL"
assert_absent "owned mapping 0 removed" "$ROOT/tmp/soundbridge-$OWN_UID-0"
assert_absent "owned mapping 1 removed" "$ROOT/tmp/soundbridge-$OWN_UID-1"
assert_absent "owned device control file removed" "$ROOT/tmp/soundbridge-devices.txt"
assert_present "unrelated file in the same directory kept" "$ROOT/tmp/unrelated.txt"
assert_present "another uid's mapping kept" "$ROOT/tmp/soundbridge-999999-other-user"
assert_present "app bundle kept" "$ROOT/Applications/SoundBridge.app"
assert_present "another vendor's HAL bundle kept" "$ROOT/$HAL_REL/OtherVendor.driver"
assert_present "user state kept" "$ROOT/Library/Application Support/SoundBridge/device-state.json"
assert_present "logs kept" "$ROOT/Library/Logs/SoundBridge/soundbridge.log"
assert_present "preferences kept" "$ROOT/Library/Preferences/com.soundbridge.menubar.plist"
assert_present "package receipt marker kept" "$ROOT/receipt-present"
assert_out "report says the driver was removed" "driver removal:     removed"
assert_out "report says the receipt was left alone" "left alone on purpose"
assert_out "report keeps state (2) separate" "2. driver unloaded from coreaudiod: no"
assert_out "report keeps state (3) separate" "3. CoreAudio device disappeared:"
assert_out_re "report keeps state (4) separate" "4\. coreaudiod restarted:[[:space:]]+no( —.*)?$"
assert_out "restart advice is printed, not run" "run this by hand: sudo killall coreaudiod"
if [[ -n "$HOST_PID" ]]; then
    if wait_fixture_dead "$HOST_PID"; then pass "a TERM-respecting Host is gone"; else fail "a TERM-respecting Host is still running"; fi
else
    skip "a TERM-respecting Host is gone (process fixture unavailable here)"
fi

scenario "repeated uninstall (idempotent)"
run "$ROOT"
assert_exit "second run still exits 0" 0
assert_out "second run reports the driver already absent" "driver removal:     already absent"
assert_out "second run removes no mappings" "removed 0 shared-memory file(s)"
assert_not_out "second run reports no failure" "could not be completed"

scenario "partially installed state (no driver, stale mappings and a receipt left)"
ROOT="$(new_root)"
make_layout "$ROOT"
rm -rf "$ROOT/$DRIVER_REL"
run "$ROOT"
assert_exit "partial teardown succeeds" 0
assert_out "reports the driver as already absent" "already absent"
assert_absent "stale mapping removed anyway" "$ROOT/tmp/soundbridge-$OWN_UID-0"
assert_absent "control file removed anyway" "$ROOT/tmp/soundbridge-devices.txt"
assert_present "receipt marker still there" "$ROOT/receipt-present"
assert_out "receipt reported as present" "com.soundbridge.menubar — present"

scenario "nothing installed at all"
ROOT="$(new_root)"
mkdir -p "$ROOT/tmp"
run "$ROOT"
assert_exit "empty machine exits 0" 0
assert_out "reports the driver as already absent" "already absent"
assert_out "reports the app bundle as absent" "SoundBridge.app — absent"
assert_out "reports the receipt as absent" "com.soundbridge.menubar — absent"
assert_not_out "no receipt paragraph when there is no receipt" "still registered"

scenario "app bundle already gone"
ROOT="$(new_root)"
make_layout "$ROOT"
rm -rf "$ROOT/Applications"
run "$ROOT"
assert_exit "teardown succeeds without the app" 0
assert_out "app bundle reported absent" "SoundBridge.app — absent"
assert_absent "driver still removed" "$ROOT/$DRIVER_REL"

scenario "Host stops on TERM"
if ! process_tests_supported; then
    skip "Host stops on TERM (process state is unreadable in this environment)"
elif ROOT="$(new_root)" && make_layout "$ROOT" && spawn_host "$ROOT" graceful; then
    HOST_PID="$FIXTURE_PID"
    run "$ROOT"
    assert_exit "teardown succeeds with a Host running" 0
    assert_out "Host stopped after TERM" "stopped $HOST_PID"
    assert_not_out "no SIGKILL was needed" "SIGKILL"
    if wait_fixture_dead "$HOST_PID"; then pass "Host process is gone"; else fail "Host process survived"; fi
else
    skip "Host stops on TERM (could not start a Host fixture)"
fi

scenario "Host ignores TERM: bounded wait, then SIGKILL against the same pid"
if ! process_tests_supported; then
    skip "Host escalation (process state is unreadable in this environment)"
elif ROOT="$(new_root)" && make_layout "$ROOT" && spawn_host "$ROOT" stubborn; then
    HOST_PID="$FIXTURE_PID"
    run "$ROOT" --timeout 1
    assert_exit "teardown still succeeds" 0
    assert_out_re "waited the whole timeout before escalating" "still running after 1s: .*$HOST_PID"
    assert_out "escalated against the identified pid" "escalating to SIGKILL for pid $HOST_PID"
    assert_out "reported how it stopped" "SIGKILL after 1s"
    if wait_fixture_dead "$HOST_PID"; then pass "Host process is gone"; else fail "Host process survived SIGKILL"; fi
else
    skip "Host escalation (could not start a Host fixture)"
fi

scenario "--keep-host leaves a running Host alone"
if ! process_tests_supported; then
    skip "--keep-host (process state is unreadable in this environment)"
elif ROOT="$(new_root)" && make_layout "$ROOT" && spawn_host "$ROOT" graceful; then
    HOST_PID="$FIXTURE_PID"
    run "$ROOT" --keep-host
    assert_exit "teardown succeeds" 0
    assert_out "plan says the Host is left running" "left running (--keep-host)"
    assert_absent "driver still removed" "$ROOT/$DRIVER_REL"
    if fixture_alive "$HOST_PID"; then pass "--keep-host left the Host running"; else fail "--keep-host stopped the Host anyway"; fi
    reap_fixture "$HOST_PID"
else
    skip "--keep-host (could not start a Host fixture)"
fi

scenario "--dry-run changes nothing"
ROOT="$(new_root)"
make_layout "$ROOT"
run "$ROOT" --dry-run
assert_exit "dry run exits 0" 0
assert_present "driver bundle untouched" "$ROOT/$DRIVER_REL"
assert_present "stale mapping untouched" "$ROOT/tmp/soundbridge-$OWN_UID-0"
assert_present "control file untouched" "$ROOT/tmp/soundbridge-devices.txt"
assert_out "prints the exact command it would run" "/bin/rm -rf '$ROOT/$DRIVER_REL'"
assert_out "says nothing was changed" "Dry run: nothing was changed"

scenario "removal scope: only soundbridge-<uid>- files and the control file"
ROOT="$(new_root)"
make_layout "$ROOT"
printf 'lookalike\n' > "$ROOT/tmp/soundbridge-$OWN_UID"
printf 'lookalike\n' > "$ROOT/tmp/soundbridge-${OWN_UID}0-x"
printf 'backup\n' > "$ROOT/$HAL_REL/SoundBridgeDriver.driver.bak"
run "$ROOT"
assert_exit "teardown succeeds" 0
assert_present "a name without the trailing dash is not ours" "$ROOT/tmp/soundbridge-$OWN_UID"
assert_present "a different uid suffix is not ours" "$ROOT/tmp/soundbridge-${OWN_UID}0-x"
assert_present "a backup next to the bundle is not ours" "$ROOT/$HAL_REL/SoundBridgeDriver.driver.bak"
assert_out "counts exactly two owned mappings" "removed 2 shared-memory file(s)"

scenario "cleanup failure is reported, not swallowed"
ROOT="$(new_root)"
make_layout "$ROOT"
mkdir -p "$ROOT/tmp/soundbridge-$OWN_UID-directory"
printf 'inside\n' > "$ROOT/tmp/soundbridge-$OWN_UID-directory/keep"
run "$ROOT"
assert_exit "a leftover this script will not delete makes the run fail" 1
assert_out "says which file it refused to remove" "not removing $ROOT/tmp/soundbridge-$OWN_UID-directory: it is not a regular file"
assert_out "summarises the failure" "1 item(s) could not be completed"
assert_present "the directory is still there" "$ROOT/tmp/soundbridge-$OWN_UID-directory/keep"
assert_absent "the driver was still removed" "$ROOT/$DRIVER_REL"

scenario "driver removal that fails is reported"
ROOT="$(new_root)"
make_layout "$ROOT"
chmod 500 "$ROOT/$HAL_REL"
run "$ROOT"
assert_exit "an undeletable bundle makes the run fail" 1
assert_present "the bundle is still there" "$ROOT/$DRIVER_REL"
assert_out "says it is still installed" "still exists after the removal command"
assert_out "summarises the failure" "item(s) could not be completed"
chmod 700 "$ROOT/$HAL_REL"

scenario "refuses a bundle that is not ours"
ROOT="$(new_root)"
make_layout "$ROOT"
write_driver "$ROOT" "com.othervendor.driver"
run "$ROOT"
assert_exit "a foreign bundle is refused" 1
assert_present "the foreign bundle is untouched" "$ROOT/$DRIVER_REL/Contents/Info.plist"
assert_present "its mappings are untouched too" "$ROOT/tmp/soundbridge-$OWN_UID-0"
assert_out "names the identifier it found" "declares bundle id 'com.othervendor.driver'"
assert_out "says nothing was changed" "Nothing was changed"

scenario "refuses a symlink at the HAL path"
ROOT="$(new_root)"
make_layout "$ROOT"
mv "$ROOT/$DRIVER_REL" "$ROOT/elsewhere.driver"
ln -s "$ROOT/elsewhere.driver" "$ROOT/$DRIVER_REL"
run "$ROOT"
assert_exit "a symlink is refused" 1
assert_present "the link is untouched" "$ROOT/$DRIVER_REL"
assert_present "the target is untouched" "$ROOT/elsewhere.driver/Contents/Info.plist"
assert_out "explains why" "is a symlink"
assert_out "says nothing was changed" "Nothing was changed"

scenario "refuses a plain file at the HAL path"
ROOT="$(new_root)"
make_layout "$ROOT"
rm -rf "$ROOT/$DRIVER_REL"
printf 'not a bundle\n' > "$ROOT/$DRIVER_REL"
run "$ROOT"
assert_exit "a plain file is refused" 1
assert_present "the file is untouched" "$ROOT/$DRIVER_REL"
assert_out "explains why" "is not a directory"

scenario "refuses a bundle with no Info.plist"
ROOT="$(new_root)"
make_layout "$ROOT"
rm -f "$ROOT/$DRIVER_REL/Contents/Info.plist"
run "$ROOT"
assert_exit "an unidentifiable bundle is refused" 1
assert_present "the bundle is untouched" "$ROOT/$DRIVER_REL/Contents"
assert_out "explains why" "has no Contents/Info.plist"

scenario "usage errors"
ROOT="$(new_root)"
mkdir -p "$ROOT/tmp"
run "$ROOT" --timeout 0
assert_exit "--timeout 0 is rejected" 2
run "$ROOT" --timeout abc
assert_exit "--timeout abc is rejected" 2
run "$ROOT" --nonsense
assert_exit "an unknown option is rejected" 2
assert_out "names the option" "unknown argument '--nonsense'"

scenario "--help"
ROOT="$(new_root)"
mkdir -p "$ROOT/tmp"
run "$ROOT" --help
assert_exit "--help exits 0" 0
assert_out "documents the sandbox seam" "--sandbox-root"
assert_out "documents the exit codes" "bad usage"

scenario "source gates (what the script may never do)"
NOT_OURS="$(grep -nE 'killall|launchctl|kextunload|kextload|pkill|sudo' "$UNINSTALL" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
if [[ -z "$NOT_OURS" ]]; then
    fail "the script has no privileged or daemon-signalling line at all (expected the printed advice)"
else
    OFFENDERS="$(printf '%s\n' "$NOT_OURS" | grep -v 'run this by hand' || true)"
    if [[ -z "$OFFENDERS" ]]; then
        pass "every killall/sudo mention is the printed advice, never an executed line"
    else
        fail "an executed line mentions a daemon signal or sudo: $(printf '%s' "$OFFENDERS" | head -1)"
    fi
fi

if grep -qF "/bin/rm -rf '\$DRIVER_PATH'" "$UNINSTALL"; then
    pass "keeps the one removal command shape the app's policy test reads"
else
    fail "the removal command shape that DriverInstallBoundaryTests expects is gone"
fi

if grep -qE 'Application Support/SoundBridge[[:space:]]+kept' "$UNINSTALL" &&
   grep -qE 'Library/Logs/SoundBridge[[:space:]]+kept' "$UNINSTALL"; then
    pass "the ownership manifest lists user state and logs as kept"
else
    fail "the ownership manifest does not say user state and logs are kept"
fi

if grep -qF 'DEFAULT_DRIVER_PATH="/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"' "$UNINSTALL"; then
    pass "removes exactly one HAL path, spelled out"
else
    fail "the default HAL path is not the literal policy path"
fi

if grep -qF 'RECEIPT_ID="com.soundbridge.menubar"' "$UNINSTALL"; then
    pass "reports the same receipt id the package is built with"
else
    fail "the receipt id is not the package's"
fi

# --- summary -----------------------------------------------------------------

printf '\nsummary: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [[ -n "$SKIPPED_NAMES" ]]; then
    printf 'skipped:\n%s' "$SKIPPED_NAMES"
fi
if [[ "$FAIL" -gt 0 ]]; then
    printf 'failed:\n%s' "$FAILED_NAMES"
    printf 'logs: %s\n' "$LOG_DIR"
    KEEP=1
    exit 1
fi
exit 0
