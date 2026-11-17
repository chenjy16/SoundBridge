#!/bin/bash
#
# Fault injection for the App Bundle swap (Phase 2.2.2 - Batch C).
#
# `create_app_bundle.sh` builds into a staging copy and then renames it into
# place, keeping the bundle that was there until the new one is at the final
# path. That window is the only place where a failed build can cost the working
# bundle, and until now nothing exercised it. Every section below runs the real
# script against a scratch dist/ and breaks exactly one call, then asserts what
# is left on disk.
#
# Faults are injected by putting a wrapper for `mv`, `rm` or `rsync` in front of
# the real tool on PATH. The wrapper fails the n-th call whose argument matches
# a pattern, and logs every call, so a test can show the failure landed on the
# call it meant. Nothing outside the scratch directory is touched, and the real
# dist/ is only read (C-01/C-03 copy the shipped bundle in as the "old" one).
#
# Sections
#   C-01  the normal swap, and that the bundle in place is the staged one
#   C-02  moving the old bundle aside fails
#   C-03  moving the staged bundle into place fails, the old one goes back
#   C-04  moving it into place fails and the old one cannot go back
#   C-05  the same, with no bundle at the final path to begin with
#   C-06  the staging copy is incomplete, so nothing may be swapped
#   C-07  the backup cannot be removed after a successful swap
#   C-08  the staging copy cannot be removed after a failed build
#   C-09  two swaps in a row, and a backup left by a killed run
#   C-10  two swaps at the same time
#
# The script under test can be pointed elsewhere with SB_BUNDLE_SCRIPT (a copy in a
# first-level directory of the repo, so its PROJECT_ROOT still resolves). That is
# how the same suite is run against the version before the fix, to show that these
# assertions fail on it.
#
# Usage
#   tools/test_app_bundle_swap.sh                 # run everything
#   tools/test_app_bundle_swap.sh C-04            # one section
#   KEEP_SCRATCH=1 tools/test_app_bundle_swap.sh  # keep the fixtures
#
set -uo pipefail

case "${1:-}" in
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
esac

ONLY="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the same suite can be run against a copy of the script that has
# one thing changed back -- the only way to show these assertions catch it.
SCRIPT="${SB_BUNDLE_SCRIPT:-$ROOT/tools/create_app_bundle.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/soundbridge-batchc.XXXXXX")" || exit 1
SHIM="$T/shim"
SHIM_LOG="$T/calls.log"
mkdir -p "$SHIM" "$T/out"

cleanup_scratch() {
    if [ "${KEEP_SCRATCH:-0}" = "1" ]; then
        echo "scratch kept at $T"
    else
        rm -rf "$T"
    fi
}
trap cleanup_scratch EXIT

PASSED=0
FAILED=0
SKIPPED=0

ok() { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  SKIP %s\n         %s\n' "$1" "$2"; }
no() { FAILED=$((FAILED + 1)); printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; }
# is <name> <actual> <expected>
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$3" "$2"; fi; }
has() { if [ -n "$2" ] && grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1" "text '$2' in ${3##*/}" "not found"; fi; }
hasnt() { if grep -qF -- "$2" "$3" 2>/dev/null; then no "$1" "no text '$2' in ${3##*/}" "found"; else ok "$1"; fi; }
section() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------- the wrapper

cat > "$SHIM/inject" <<'SHIM_EOF'
#!/bin/bash
# Stands in for mv/rm/rsync. Fails the n-th call whose last argument matches a
# pattern (SB_SHIM_FAIL entries: tool|pattern|nth|mode, separated by ';').
tool="$(basename "$0")"
printf '%s|%s\n' "$tool" "$*" >> "${SB_SHIM_LOG:-/dev/null}"

last=""
for arg in "$@"; do last="$arg"; done

hit=0
i=0
IFS=';' read -r -a entries <<< "${SB_SHIM_FAIL:-}"
for entry in "${entries[@]}"; do
    [ -n "$entry" ] || continue
    i=$((i + 1))
    want_tool="${entry%%|*}"
    rest="${entry#*|}"
    pattern="${rest%%|*}"
    rest="${rest#*|}"
    nth="${rest%%|*}"
    mode="${rest#*|}"

    [ "$want_tool" = "$tool" ] || continue

    matched=0
    case "$mode" in
        last) case "$last" in $pattern) matched=1 ;; esac ;;
        any) case "$*" in $pattern) matched=1 ;; esac ;;
        last-exists)
            case "$last" in $pattern) [ -e "$last" ] && matched=1 ;; esac
            ;;
        last-create)
            # Creates something at the target, then fails: the shape of a move
            # that half happened.
            case "$last" in
                $pattern) [ -e "$last" ] || mkdir -p "$last"; matched=1 ;;
            esac
            ;;
    esac
    [ "$matched" = "1" ] || continue

    # Every matching entry is counted on every call, including calls after the
    # one that already failed: the wrapper exits on the first hit, so counting
    # lazily would shift the n-th call for the entries that come after it.
    count_file="${SB_SHIM_LOG:-/dev/null}.count.$i"
    count=0
    [ -f "$count_file" ] && count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file" 2>/dev/null
    if [ "$count" = "$nth" ]; then
        hit=1
        printf 'INJECTED %s #%s %s\n' "$tool" "$nth" "$*" >> "${SB_SHIM_LOG:-/dev/null}"
    fi
done

[ "$hit" = "0" ] || exit 1

real="/bin/$tool"
[ -x "$real" ] || real="/usr/bin/$tool"
exec "$real" "$@"
SHIM_EOF
chmod +x "$SHIM/inject"
for tool in mv rm rsync; do ln -sf inject "$SHIM/$tool"; done

# ---------------------------------------------------------------- fixtures

# The bundle that is already in dist/. Only the test's own copy is ever
# replaced; `create_app_bundle.sh` reads it with `mv`, never with a validation,
# so a small tree with a version marker is enough to tell OLD from NEW.
make_old() { # make_old <dist> [marker]
    local dist="$1" marker="${2:-OLD}" app="$1/SoundBridge.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/OldSub"
    printf '%s\n' "$marker" > "$app/TEST_VERSION"
    printf 'old executable\n' > "$app/Contents/MacOS/SoundBridgeApp"
    printf 'old resource\n' > "$app/Contents/Resources/OldSub/leaf.txt"
    printf 'CFBundleShortVersionString=0.9.9\n' > "$app/Contents/Info.plist"
}

dist_for() { # dist_for <case> -> fresh empty dist, printed
    local d="$T/case/$1/dist"
    rm -rf "$T/case/$1"
    mkdir -p "$d"
    printf '%s' "$d"
}

tree_hash() { # tree_hash <dir> - names, types and contents, order fixed
    ( cd "$1" 2>/dev/null || exit 0
      { find . -print | LC_ALL=C sort
        find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
      } | shasum -a 256 | awk '{ print $1 }' )
}

stray() { # stray <dist> - temporary directories the swap should not have left
    find "$1" -maxdepth 1 -name '.SoundBridge.app.*' 2>/dev/null | wc -l | tr -d ' '
}

is_old() { [ "$(cat "$1/SoundBridge.app/TEST_VERSION" 2>/dev/null)" = "${2:-OLD}" ]; }
marker_is() { [ "$(cat "$1/TEST_VERSION" 2>/dev/null)" = "$2" ]; }
is_new() { [ -f "$1/SoundBridge.app/Contents/MacOS/SoundBridgeApp" ] && [ ! -e "$1/SoundBridge.app/TEST_VERSION" ]; }
exists() { [ -e "$1" ]; }
absent() { [ ! -e "$1" ]; }

# Run the real script against a scratch dist, with the wrappers in front of the
# real tools. Extra arguments are VAR=value pairs handed to the script.
RC=0
OUT=""
run_swap() { # run_swap <label> <dist> [VAR=value...]
    local label="$1" dist="$2"
    shift 2
    OUT="$T/out/$label.log"
    rm -f "$SHIM_LOG" "$SHIM_LOG".count.*
    PATH="$SHIM:$PATH" SB_SHIM_LOG="$SHIM_LOG" SB_DIST_DIR="$dist" \
        env "$@" "$SCRIPT" > "$OUT" 2>&1
    RC=$?
}

injected() { grep -c '^INJECTED ' "$SHIM_LOG" 2>/dev/null | tr -d ' '; }
injected_line() { grep '^INJECTED ' "$SHIM_LOG" 2>/dev/null | head -1; }

want_section() { [ -z "${ONLY:-}" ] || [ "$ONLY" = "$1" ]; }

# ---------------------------------------------------------------- sections

section "C-01: the normal swap puts the staged bundle in place"
if want_section C-01; then
    D="$(dist_for c01)"
    cp -R "$ROOT/dist/SoundBridge.app" "$D/SoundBridge.app"
    printf 'OLD\n' > "$D/SoundBridge.app/TEST_VERSION"
    before_hash="$(tree_hash "$D/SoundBridge.app")"
    run_swap c01 "$D"
    is "the swap exits 0" "$RC" "0"
    has "the run says the bundle was created" "bundle created successfully" "$OUT"
    is_new "$D" && ok "the final bundle is the new one, not the old one" \
        || no "the final bundle is the new one, not the old one" "no TEST_VERSION" "$(ls "$D/SoundBridge.app" 2>/dev/null)"
    [ "$(tree_hash "$D/SoundBridge.app")" != "$before_hash" ] \
        && ok "the final bundle differs from the one it replaced" \
        || no "the final bundle differs from the one it replaced" "a different tree" "the old tree"
    exists "$D/SoundBridge.app/Contents/Resources/SoundBridgeDriver.driver" \
        && ok "the driver is inside the bundle that was put in place" \
        || no "the driver is inside the bundle that was put in place" "driver present" "missing"
    exists "$D/SoundBridge.app/Contents/Frameworks/Sparkle.framework" \
        && ok "Sparkle is inside the bundle that was put in place" \
        || no "Sparkle is inside the bundle that was put in place" "framework present" "missing"
    is "no staging or backup directory is left behind" "$(stray "$D")" "0"
    is "no fault was injected" "$(injected)" "0"
fi

section "C-01b: what is at the final path is the staging copy, byte for byte"
if want_section C-01b; then
    if ! grep -q 'SB_BUNDLE_SWAP_HOLD' "$SCRIPT"; then
        skip "the bundle at the final path is the staging copy" \
            "create_app_bundle.sh has no SB_BUNDLE_SWAP_HOLD seam to look through"
    else
    D="$(dist_for c01b)"
    cp -R "$ROOT/dist/SoundBridge.app" "$D/SoundBridge.app"
    printf 'OLD\n' > "$D/SoundBridge.app/TEST_VERSION"
    PATH="$SHIM:$PATH" SB_SHIM_LOG="$SHIM_LOG" SB_DIST_DIR="$D" SB_BUNDLE_SWAP_HOLD=6 \
        "$SCRIPT" > "$T/out/c01b.log" 2>&1 &
    holder=$!
    staging=""
    # The lock is taken at the start of the swap, which is only reached once the
    # staging copy is complete: waiting for it is what makes the copy below a
    # copy of a finished bundle rather than of one still being written.
    for _ in $(seq 1 100); do
        [ -d "$D/.SoundBridge.app.swap.lock" ] && break
        sleep 0.1
    done
    staging="$(find "$D" -maxdepth 1 -name '.SoundBridge.app.staging.*' | head -1)"
    staged_hash=""
    if [ -n "$staging" ]; then
        cp -R "$staging" "$T/staged-snapshot"
        staged_hash="$(tree_hash "$T/staged-snapshot")"
    fi
    wait "$holder"
    RC=$?
    is "the swap exits 0" "$RC" "0"
    if [ -n "$staged_hash" ]; then
        is "the bundle at the final path is the staging copy" "$(tree_hash "$D/SoundBridge.app")" "$staged_hash"
    else
        # Without the hold the staging copy is gone before it can be copied, so
        # this criterion cannot be observed -- it is not passed by default.
        skip "the staging copy could be seen while the swap was held" "no hold seam; nothing to compare against"
    fi
    is "no staging or backup directory is left behind" "$(stray "$D")" "0"
    fi
fi

section "C-02: moving the old bundle aside fails"
if want_section C-02; then
    D="$(dist_for c02)"
    make_old "$D"
    before_hash="$(tree_hash "$D/SoundBridge.app")"
    run_swap c02 "$D" SB_SHIM_FAIL='mv|*.previous.*|1|last'
    is "the first move of the old bundle was the one that failed" "$(injected)" "1"
    has "the injected failure names the backup path" ".previous." "$SHIM_LOG"
    is "the run exits non-zero" "$RC" "1"
    has "the run says the existing bundle was not touched" "is untouched" "$OUT"
    is_old "$D" && ok "the old bundle is still at the final path" \
        || no "the old bundle is still at the final path" "TEST_VERSION=OLD" "$(ls "$D/SoundBridge.app" 2>/dev/null)"
    is "the old bundle is unchanged" "$(tree_hash "$D/SoundBridge.app")" "$before_hash"
    is "no staging or backup directory is left behind" "$(stray "$D")" "0"
fi

section "C-03: the staged bundle cannot be moved in, the old one goes back"
if want_section C-03; then
    D="$(dist_for c03)"
    cp -R "$ROOT/dist/SoundBridge.app" "$D/SoundBridge.app"
    before_hash="$(tree_hash "$D/SoundBridge.app")"
    run_swap c03 "$D" SB_SHIM_FAIL='mv|*/SoundBridge.app|1|last'
    is "one move into the final path was made to fail" "$(injected)" "1"
    case "$(injected_line)" in
        *previous*) no "the failing move was the staged bundle, not the backup" "staged -> final" "$(injected_line)" ;;
        *) ok "the failing move was the staged bundle, not the backup" ;;
    esac
    is "the run exits non-zero" "$RC" "1"
    has "the run says the previous bundle was put back" "The previous bundle was put back" "$OUT"
    is "the bundle at the final path is the old one again, byte for byte" \
        "$(tree_hash "$D/SoundBridge.app")" "$before_hash"
    is "no staging or backup directory is left behind" "$(stray "$D")" "0"
fi

section "C-04: neither move works - the only good bundle must survive"
if want_section C-04; then
    D="$(dist_for c04)"
    make_old "$D"
    before_hash="$(tree_hash "$D/SoundBridge.app")"
    run_swap c04 "$D" SB_SHIM_FAIL='mv|*/SoundBridge.app|1|last;mv|*/SoundBridge.app|2|last'
    is "both moves into the final path were made to fail" "$(injected)" "2"
    is "the run exits non-zero" "$RC" "1"
    hasnt "the run does not claim the previous bundle was put back" "The previous bundle was put back" "$OUT"
    has "the run says the previous bundle could not be put back" "could not be put back" "$OUT"
    backup="$(find "$D" -maxdepth 1 -name '.SoundBridge.app.previous.*' | head -1)"
    if [ -n "$backup" ]; then
        ok "the backup is still there"
        is "the backup still holds the old bundle" "$(tree_hash "$backup")" "$before_hash"
        marker_is "$backup" OLD && ok "the backup still carries the OLD marker" \
            || no "the backup still carries the OLD marker" "OLD" "$(cat "$backup/TEST_VERSION" 2>/dev/null)"
    else
        no "the backup is still there" "a .previous directory" "none"
    fi
    staging="$(find "$D" -maxdepth 1 -name '.SoundBridge.app.staging.*' | head -1)"
    [ -n "$staging" ] && ok "the staging copy was kept" \
        || no "the staging copy was kept" "a .staging directory" "none"
    absent "$D/SoundBridge.app" && ok "the final path is reported by its real state: absent" \
        || no "the final path is reported by its real state: absent" "nothing at the final path" "something is there"
    has "the run prints the backup path" "$backup" "$OUT"
    has "the run prints the staging path" "$staging" "$OUT"
    has "the run says the final path does not exist" "does not exist" "$OUT"
    has "the run gives the command that puts the old bundle back" "'$backup' '$D/SoundBridge.app'" "$OUT"
    has "the run says nothing was deleted" "Nothing was deleted" "$OUT"
fi

section "C-04b: a restore that lands inside a directory must not be called a restore"
if want_section C-04b; then
    D="$(dist_for c04b)"
    make_old "$D"
    before_hash="$(tree_hash "$D/SoundBridge.app")"
    # The move into the final path leaves a directory behind and fails; the
    # restore then has somewhere to land, which real `mv` treats as "put the
    # source inside it" -- a restore in the log and not one on disk.
    run_swap c04b "$D" SB_SHIM_FAIL='mv|*/SoundBridge.app|1|last-create'
    is "the move into the final path was made to fail after leaving something there" "$(injected)" "1"
    is "the run exits non-zero" "$RC" "1"
    hasnt "the run does not claim the previous bundle was put back" "The previous bundle was put back" "$OUT"
    has "the run says the previous bundle could not be put back" "could not be put back" "$OUT"
    nested="$(find "$D/SoundBridge.app" -maxdepth 1 -name '.SoundBridge.app.previous.*' 2>/dev/null | head -1)"
    [ -n "$nested" ] && ok "the old bundle is still there, one level down" \
        || no "the old bundle is still there, one level down" "a .previous directory inside the final path" "none"
    [ -n "$nested" ] && is "nothing in it was touched" "$(tree_hash "$nested")" "$before_hash"
    has "the run prints where the old bundle really is" "$nested" "$OUT"
    [ -n "$(find "$D" -maxdepth 1 -name '.SoundBridge.app.staging.*' | head -1)" ] \
        && ok "the staging copy was kept" \
        || no "the staging copy was kept" "a .staging directory" "none"
fi

section "C-05: no bundle at the final path to begin with"
if want_section C-05; then
    D="$(dist_for c05)"
    run_swap c05 "$D" SB_SHIM_FAIL='mv|*/SoundBridge.app|1|last'
    is "one move into the final path was made to fail" "$(injected)" "1"
    is "the run exits non-zero" "$RC" "1"
    has "the run says there was nothing to restore" "nothing was restored" "$OUT"
    hasnt "the run does not claim a restore" "was put back" "$OUT"
    absent "$D/SoundBridge.app" && ok "the final path is still absent" \
        || no "the final path is still absent" "nothing at the final path" "something is there"
    is "no backup was invented" "$(find "$D" -maxdepth 1 -name '.SoundBridge.app.previous.*' | wc -l | tr -d ' ')" "0"
    is "no staging directory is left behind" "$(stray "$D")" "0"
fi

section "C-06: an incomplete staging copy is never swapped in"
if want_section C-06; then
    D="$(dist_for c06)"
    make_old "$D"
    before_hash="$(tree_hash "$D/SoundBridge.app")"
    run_swap c06 "$D" SB_SHIM_FAIL='rsync|*|1|any'
    is "the copy of the app resources was made to fail" "$(injected)" "1"
    has "the run got as far as building the staging copy" "Copying app resources" "$OUT"
    is "the run exits non-zero" "$RC" "1"
    is_old "$D" && ok "the old bundle is still at the final path" \
        || no "the old bundle is still at the final path" "TEST_VERSION=OLD" "$(ls "$D/SoundBridge.app" 2>/dev/null)"
    is "the old bundle is unchanged" "$(tree_hash "$D/SoundBridge.app")" "$before_hash"
    is "the partial staging copy was removed" "$(stray "$D")" "0"
fi

section "C-07: the backup cannot be removed after a successful swap"
if want_section C-07; then
    D="$(dist_for c07)"
    make_old "$D"
    old_hash="$(tree_hash "$D/SoundBridge.app")"
    run_swap c07 "$D" SB_SHIM_FAIL='rm|*.previous.*|1|last-exists'
    is "the removal of the backup was made to fail" "$(injected)" "1"
    is "the swap still reports success" "$RC" "0"
    is_new "$D" && ok "the new bundle is at the final path" \
        || no "the new bundle is at the final path" "no TEST_VERSION" "$(ls "$D/SoundBridge.app" 2>/dev/null)"
    has "the run says the bundle was put in place anyway" "was put in place" "$OUT"
    backup="$(find "$D" -maxdepth 1 -name '.SoundBridge.app.previous.*' | head -1)"
    [ -n "$backup" ] && ok "the backup that could not be removed is still there" \
        || no "the backup that could not be removed is still there" "a .previous directory" "none"
    [ -n "$backup" ] && is "the leftover backup is the old bundle, unmodified" "$(tree_hash "$backup")" "$old_hash"
    has "the run prints where the leftover backup is" "backup could not be removed" "$OUT"
    has "the run prints the backup path" "$backup" "$OUT"
fi

section "C-08: the staging copy cannot be removed after a failed build"
if want_section C-08; then
    D="$(dist_for c08)"
    make_old "$D"
    before_hash="$(tree_hash "$D/SoundBridge.app")"
    run_swap c08 "$D" SB_SHIM_FAIL='rm|*.staging.*|1|last-exists' SB_DRIVER_BUNDLE="$T/no-such-driver"
    is "the removal of the staging copy was made to fail" "$(injected)" "1"
    is "the run exits with the failure that stopped the build" "$RC" "1"
    has "the run names the missing driver" "not found at $T/no-such-driver" "$OUT"
    is "the old bundle is unchanged" "$(tree_hash "$D/SoundBridge.app")" "$before_hash"
    staging="$(find "$D" -maxdepth 1 -name '.SoundBridge.app.staging.*' | head -1)"
    [ -n "$staging" ] && ok "the staging copy is still there, as the trap could not remove it" \
        || no "the staging copy is still there, as the trap could not remove it" "a .staging directory" "none"
    has "the run says the staging copy is still there" "could not be removed" "$OUT"
    has "the run prints the staging path" "$staging" "$OUT"
fi

section "C-09: two swaps in a row"
if want_section C-09; then
    D="$(dist_for c09)"
    make_old "$D"
    run_swap c09a "$D" SPARKLE_ED_PUBLIC_KEY=first
    is "the first swap exits 0" "$RC" "0"
    run_swap c09b "$D" SPARKLE_ED_PUBLIC_KEY=second
    is "the second swap exits 0" "$RC" "0"
    is "the second swap replaced the first one" \
        "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$D/SoundBridge.app/Contents/Info.plist" 2>/dev/null)" "second"
    is "the first swap left no backup behind" "$(grep -c '^Note: a bundle kept' "$T/out/c09b.log")" "0"
    is "no staging or backup directory is left behind" "$(stray "$D")" "0"
fi

section "C-09b: a backup left by a killed run is not overwritten"
if want_section C-09b; then
    D="$(dist_for c09c)"
    make_old "$D"
    before_hash="$(tree_hash "$D/SoundBridge.app")"
    # The backup is left under the pid the script is about to have: `exec` keeps
    # the pid of the shell that creates the directory.
    ( cd "$ROOT" && SB_DIST_DIR="$D" PATH="$SHIM:$PATH" SB_SHIM_LOG="$SHIM_LOG" SB_SCRIPT_PATH="$SCRIPT" \
        bash -c 'mkdir -p "$SB_DIST_DIR/.SoundBridge.app.previous.$$"
                 printf "KILLED-RUN\n" > "$SB_DIST_DIR/.SoundBridge.app.previous.$$/TEST_VERSION"
                 exec "$SB_SCRIPT_PATH"' > "$T/out/c09c.log" 2>&1 )
    RC=$?
    backup="$(find "$D" -maxdepth 1 -name '.SoundBridge.app.previous.*' | head -1)"
    [ -n "$backup" ] && ok "the backup left by the killed run is still there" \
        || no "the backup left by the killed run is still there" "a .previous directory" "none"
    is "the backup is the one the killed run left" "$(cat "$backup/TEST_VERSION" 2>/dev/null)" "KILLED-RUN"
    is_old "$D" && ok "the working bundle was left as it was" \
        || no "the working bundle was left as it was" "TEST_VERSION=OLD" "$(ls "$D/SoundBridge.app" 2>/dev/null)"
    is "the working bundle is unchanged" "$(tree_hash "$D/SoundBridge.app")" "$before_hash"
    is "the run refuses rather than overwrite it" "$RC" "1"
    has "the run names the bundle kept by the earlier run" "kept by an earlier run" "$T/out/c09c.log"
fi

section "C-10: two swaps at the same time"
if want_section C-10; then
    D="$(dist_for c10)"
    make_old "$D"
    rm -f "$SHIM_LOG" "$SHIM_LOG".count.*
    PATH="$SHIM:$PATH" SB_SHIM_LOG="$SHIM_LOG" SB_DIST_DIR="$D" SPARKLE_ED_PUBLIC_KEY=first \
        SB_BUNDLE_SWAP_HOLD=8 "$SCRIPT" > "$T/out/c10a.log" 2>&1 &
    holder=$!
    lock="$D/.SoundBridge.app.swap.lock"
    seen=0
    for _ in $(seq 1 60); do
        [ -d "$lock" ] && { seen=1; break; }
        sleep 0.1
    done
    if [ "$seen" = "1" ]; then
        ok "the first run holds a lock while it swaps"
        PATH="$SHIM:$PATH" SB_SHIM_LOG="$SHIM_LOG" SB_DIST_DIR="$D" SPARKLE_ED_PUBLIC_KEY=second \
            "$SCRIPT" > "$T/out/c10b.log" 2>&1
        RC=$?
        is "the second run is refused" "$RC" "1"
        has "the second run says another build is putting a bundle in place" \
            "another build is putting a bundle in place" "$T/out/c10b.log"
        has "the second run says the final path was not touched by it" \
            "did not touch" "$T/out/c10b.log"
    else
        no "the first run holds a lock while it swaps" "a lock directory at $lock" "no lock appeared"
    fi
    wait "$holder"
    is "the first run finishes successfully" "$?" "0"
    is "the bundle in place is the first run's" \
        "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$D/SoundBridge.app/Contents/Info.plist" 2>/dev/null)" "first"
    is "no lock is left behind" "$(find "$D" -maxdepth 1 -name '.SoundBridge.app.swap.lock' | wc -l | tr -d ' ')" "0"
    is "no staging or backup directory is left behind" "$(stray "$D")" "0"
fi

if [ "${KEEP_SCRATCH:-0}" != "1" ]; then
    rm -rf "$T/case" "$T/staged-snapshot"
fi
printf '\npassed: %d failed: %d skipped: %d\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ]
