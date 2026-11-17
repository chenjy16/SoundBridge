#!/bin/bash
#
# SoundBridge HAL driver install transaction (Phase 2.2.1).
#
# This file is the single implementation of "put the driver this package carries
# into the HAL directory". `pkgbuild` copies it verbatim into the payload and
# `postinstall` runs it, so the code exercised by tools/test_install_transaction.sh
# is byte-for-byte the code that runs during a real install.
#
# Why the payload does not install the driver directly
# ---------------------------------------------------
# `installer` writes the payload itself. If the driver sat at its final path in
# the payload, the old driver would have to be deleted *before* that write
# (otherwise the payload merges into it -- the bug that made an upgrade report a
# new version while still loading an old binary). That leaves a window where the
# old driver is gone and the new one is not written yet. A failed copy, a full
# disk or a power cut in that window leaves the machine with no driver, and the
# app deliberately has no in-app upgrade path to repair it.
#
# So the payload stages the driver somewhere harmless and this script performs
# the replace as a transaction with a backup, a verification pass and a rollback.
#
# Transaction
# -----------
#   PRECHECK -> STAGING -> VALIDATING -> BACKUP_OLD -> REPLACING -> VERIFYING
#       |          |           |             |             |            |
#       +----------+-----------+-------------+-------------+------------+
#                                    any failure
#                                         |
#                                         v
#                                     ROLLBACK
#                                         |
#                                  +------+------+
#                                  v             v
#                             ROLLED_BACK   ROLLBACK_FAILED
#
# The stages before REPLACING only ever *read* the destination, so a refusal
# there cannot damage an existing driver. REPLACING is two rename(2) calls on the
# same volume; it never recursively deletes the destination:
#
#     mv $DEST                    -> $STATE/backup/<driver>.live
#     mv $STATE/staging/<driver>  -> $DEST
#
# Both renames are atomic. Between them the destination is absent for
# microseconds and the previous bundle is intact on disk under a name the HAL
# loader ignores (it only loads entries ending in `.driver`).
#
# Crash recovery
# --------------
# Every stage writes `$STATE/transaction.state` *before* it starts, so a SIGKILL
# or a power loss leaves a record of how far the install got. `--mode recover`
# reads that record and puts the disk back into a consistent state; it is safe to
# run any number of times. `--mode install` always runs recovery first.
#
# Serialisation
# -------------
# Two `installer` runs, or an install and a recovery, must never work on the same
# staging, backup and destination at the same time. Every mode takes
# `$STATE/transaction.lock` first -- an atomic `mkdir` -- and holds it across
# recovery, install, rollback and cleanup. A second process exits 5 without
# writing anything.
#
# The lock is claimed before its owner is recorded, so for a few microseconds the
# directory exists with no pid file in it. That state is read as "not written
# yet", never as "the owner died": a challenger waits for the write to finish.
# Only a pid that can be read and whose process is gone counts as stale, and
# reclaiming it needs a second atomic `mkdir` plus a re-read of the pid under
# that gate, so two processes that both spot the same dead owner cannot both
# delete the lock and re-claim it.
#
# Version and protocol gates
# --------------------------
# Some destinations must not be touched at all: a bundle that is not ours, a
# version that cannot be read or parsed, a downgrade, or a driver that speaks a
# newer protocol than the package does. Protocol is compared before version, the
# same order `DriverVersionGate` uses in the app: a build that speaks a different
# wire format is unusable no matter what its version string says.
#
# Exit codes
#   0  installed, or recovery found nothing to do
#   1  refused before touching anything; the existing driver is untouched
#   2  failed during the replace and rolled back; the previous driver is back
#   3  ROLLBACK FAILED; the driver on disk may be missing or incomplete
#   4  environment problem (missing tool, unusable state dir, volume mismatch)
#   5  another transaction holds the lock; this run modified nothing
#
# This script never calls sudo, never fetches anything, and never restarts
# coreaudiod. It runs as root because `postinstall` does.
#
# Usage
#   sb_install_transaction.sh --payload DIR --manifest FILE --dest PATH \
#                             --state DIR [--owner root:wheel] [--mode install|recover]
#
set -uo pipefail   # deliberately no -e: every failure needs its own decision

PROG="$(basename "$0")"
DRIVER_NAME="SoundBridgeDriver.driver"

PAYLOAD_DIR=""
MANIFEST=""
DEST=""
STATE_DIR=""
MODE="install"
OWNER="root:wheel"

# Test hooks. Only honoured when SB_INSTALL_TESTING=1, which a real `installer`
# run never sets: postinstall starts from a clean environment.
# --test-fault takes a comma-separated list, so a scenario can ask for a replace
# failure *and* a rollback failure in one run. --test-pause stops at one named
# point: `replace-gap` sleeps long enough for a test to kill -9, `lock-init`
# waits for a gate file so a test can hold a run inside the lock and release it.
TEST_FAULT=""
TEST_PAUSE=""

STAGE="INIT"
LOG_DIR=""
LOG_FILE=""
LOCK_DIR=""
LOCK_HELD=0
# How many times a challenger re-reads an ownerless lock before giving up. An
# owner is recorded microseconds after the directory appears, so this only has to
# cover a run that is descheduled between `mkdir` and the write; five checks at
# 50ms would already be generous, forty makes the window immune to a loaded CPU.
LOCK_INIT_SPINS=40
STARTED_AT="$(date +%s)"
HAVE_OLD=0
MID=""
MVER=""
MPROTO=""
MARCHS=""

# --- output -----------------------------------------------------------------

usage() {
    # Everything from the description down to the line above `set`. Written this
    # way so adding a paragraph to the header cannot silently truncate the help.
    sed -n '3,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')][$STAGE] $*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null
    fi
    printf '%s\n' "$line" >&2
}

env_problem() { log "ENVIRONMENT: $*"; exit 4; }
refuse()      { log "REFUSED: $*"; log "the existing driver was not modified"; exit 1; }

# --- lock -------------------------------------------------------------------
#
# One transaction at a time.
#
# The exclusive right to run is the existence of $LOCK_DIR, claimed with `mkdir`.
# `mkdir` is atomic on every local filesystem: exactly one create wins, so two
# runs can never both believe they are the only one working.
#
# *Who* holds it is written into a separate file a moment later, and that gap is
# where a naive lock breaks. A challenger that finds the directory but no pid
# file must not conclude "the owner is gone": the owner is mid-way through
# claiming the lock and about to write its pid. So an absent pid file is read
# here as "not written yet", never as "dead"; the challenger waits, and only a
# readable pid whose process no longer exists counts as a dead owner.
#
# Reclaiming a dead owner is itself serialised, by a second `mkdir` on
# $LOCK_DIR.reclaim. Only the gate holder may delete $LOCK_DIR, and only after
# re-reading the pid inside and finding it unchanged. Renaming the directory
# aside -- how this was done before -- was not enough: between one run's `mv` and
# its `rm`, a second run could `mv` the *new* lock the first had just created and
# delete that instead, and both would end up running. The re-read under the gate
# closes it: a lock that changed hands while it was being inspected is no longer
# ours to delete.

lock_owner() {
    cat "$LOCK_DIR/pid" 2>/dev/null
}

owner_is_alive() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    # ps, not kill -0: reading another process's existence needs no signal
    # permission, so the answer is the same for root and for a test run.
    /bin/ps -p "$pid" >/dev/null 2>&1
}

# Creates $LOCK_DIR and records this run's pid in it.
#   0  the lock is ours
#   1  somebody else holds it
#   2  the directory could be created but the pid could not be written
#
take_lock() {
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    # The test hook sits inside the very window this lock has to survive.
    maybe_pause "lock-init" wait
    if trigger_fault lock-pid; then
        # A directory where the pid file belongs, so the write below cannot
        # succeed. That is the case a lock must refuse to run through.
        mkdir "$LOCK_DIR/pid" 2>/dev/null
    fi
    if ! printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null; then
        # A lock whose owner cannot be recorded is worse than no lock: every
        # later run would find an empty pid file and have to guess whether the
        # holder is alive. Hand the directory back instead of running unrecorded.
        rm -rf "$LOCK_DIR"
        log "could not record this run's pid in $LOCK_DIR; not starting"
        return 2
    fi
    LOCK_HELD=1
    # A second hook, after the owner is on disk: a test can rewrite the pid here
    # to prove that release only removes a lock that still names this run.
    maybe_pause "lock-held" wait
    return 0
}

# reclaim_dead_lock PID -- deletes a lock whose owner is gone. The right to do so
# is the gate; inside it the pid is read again, because the lock may have changed
# hands between the first read and the claim.
#   0  the lock is gone and may be claimed again
#   5  another run got there first, or the gate is held
#
reclaim_dead_lock() {
    local expect="$1" gate="$LOCK_DIR.reclaim" now
    mkdir "$gate" 2>/dev/null || return 5
    now="$(lock_owner)"
    if [[ "$now" == "$expect" ]] && ! owner_is_alive "$now"; then
        rm -rf "$LOCK_DIR"
        log "reclaimed a stale lock (owner '${expect:-unknown}' is gone)"
        rm -rf "$gate"
        return 0
    fi
    rm -rf "$gate"
    log "the lock changed hands while it was being inspected; leaving it to its owner"
    return 5
}

acquire_lock() {
    local spins=0 rc owner
    while :; do
        take_lock
        rc=$?
        if [[ $rc -eq 0 ]]; then
            log "install lock acquired: $LOCK_DIR"
            return 0
        fi
        if [[ $rc -ne 1 ]]; then
            # 2: the directory was created but the pid could not be recorded, so
            # this run gave it back. That is an unusable lock, not a busy one.
            log "BUSY: could not claim $LOCK_DIR and this run did not start"
            log "this run did not modify state, staging, backup or the destination"
            return 4
        fi

        owner="$(lock_owner)"
        if [[ -z "$owner" ]]; then
            # Not a dead owner: one is being written right now. Wait for it to
            # finish instead of taking the directory.
            spins=$((spins + 1))
            if [[ $spins -le $LOCK_INIT_SPINS ]]; then
                /bin/sleep 0.05
                continue
            fi
            log "BUSY: $LOCK_DIR exists and has recorded no owner after $spins checks"
            log "this run did not modify state, staging, backup or the destination"
            log "if no install is running, the leftover lock is $LOCK_DIR"
            return 5
        fi

        if owner_is_alive "$owner"; then
            log "BUSY: another transaction is running (pid $owner)"
            log "this run did not modify state, staging, backup or the destination"
            return 5
        fi

        reclaim_dead_lock "$owner"
        rc=$?
        if [[ $rc -eq 0 ]]; then
            # Free again; go round and claim it like anybody else, so the winner
            # is decided by `mkdir` rather than by having spotted the dead pid.
            continue
        fi
        spins=$((spins + 1))
        if [[ $spins -le $LOCK_INIT_SPINS ]]; then
            /bin/sleep 0.05
            continue
        fi
        log "BUSY: $LOCK_DIR belongs to a pid that is gone and could not be reclaimed"
        log "this run did not modify state, staging, backup or the destination"
        log "the reclaim gate $LOCK_DIR.reclaim may be left over; remove it by hand only if no install is running"
        return 5
    done
}

release_lock() {
    [[ "$LOCK_HELD" == "1" ]] || return 0
    LOCK_HELD=0
    [[ -n "$LOCK_DIR" ]] || return 0
    # Only the owner removes it. If the lock was reclaimed from us -- reclaimed
    # after a false "owner is gone" -- deleting it here would take the lock away
    # from the process that legitimately holds it now.
    if [[ "$(lock_owner)" == "$$" ]]; then
        rm -rf "$LOCK_DIR"
    fi
}

# --- state file -------------------------------------------------------------
#
# Write-ahead: the stage name is on disk before the work starts, so an
# interrupted run can tell "never began" from "began and did not finish".

write_state() {
    local stage="$1" detail="${2:-}" tmp="$STATE_DIR/.transaction.state.tmp"
    {
        printf 'stage=%s\n' "$stage"
        printf 'started=%s\n' "$STARTED_AT"
        printf 'pid=%s\n' "$$"
        printf 'dest=%s\n' "$DEST"
        printf 'id=%s\n' "$MID"
        printf 'detail=%s\n' "$detail"
    } >"$tmp" || { log "could not write $tmp"; return 1; }
    # Content, then rename, then the directory entry. bash has no fsync, so
    # `sync` is the only handle available: it flushes the whole filesystem rather
    # than one descriptor, which is coarse but is exactly the ordering a
    # write-ahead record needs. Without it the rename can reach disk while the
    # previous contents -- or a half-written file -- are still what a crash
    # leaves behind, and recovery would read a stitched-together record.
    /bin/sync
    mv -f "$tmp" "$STATE_DIR/transaction.state" || { log "could not publish transaction.state"; return 1; }
    /bin/sync
    return 0
}

state_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$STATE_DIR/transaction.state" 2>/dev/null | head -1
}

clear_state() {
    rm -f "$STATE_DIR/transaction.state" "$STATE_DIR/.transaction.state.tmp"
}

# --- primitives -------------------------------------------------------------

manifest_value() {
    [[ -f "$MANIFEST" ]] || return 1
    /usr/libexec/PlistBuddy -c "Print :$1" "$MANIFEST" 2>/dev/null
}

same_volume() {
    local d1 d2
    d1="$(/usr/bin/stat -f %d "$1" 2>/dev/null)"
    d2="$(/usr/bin/stat -f %d "$2" 2>/dev/null)"
    [[ -n "$d1" && -n "$d2" && "$d1" == "$d2" ]]
}

# --- version and protocol gates ---------------------------------------------
#
# `DriverVersionGate` in the app puts protocol before version; the installer has
# to agree, otherwise a package could replace the driver with one the app then
# refuses to use. A destination is only replaced when this package is at least as
# new on the wire format and -- when the formats match -- at least as new by
# version.

# Version strings are compared with bash arithmetic, which is 64-bit signed and
# wraps silently on overflow: 999999999999999999 becomes a small negative number
# and would compare as *older* than everything, so a downgrade could slip through
# as an upgrade. A bundle version segment never needs more than a few digits, so
# anything longer is refused instead of being compared wrongly. The same limit
# keeps the protocol integers below inside the range where > and < mean what they
# look like.
MAX_COMPARE_DIGITS=9

# version_problem VERSION -- prints why VERSION cannot be compared, nothing when
# it can. Kept apart from the yes/no test so a refusal can say what is wrong
# instead of only that something is.
version_problem() {
    local v="$1" seg
    local -a parts
    if [[ -z "$v" ]]; then
        echo "it is empty"
        return 0
    fi
    if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "it is not dot-separated digits"
        return 0
    fi
    IFS='.' read -r -a parts <<<"$v"
    for seg in "${parts[@]}"; do
        if [[ ${#seg} -gt $MAX_COMPARE_DIGITS ]]; then
            echo "segment '$seg' has ${#seg} digits, more than the $MAX_COMPARE_DIGITS this comparison can hold without wrapping"
            return 0
        fi
    done
    return 0
}

version_is_valid() {
    # Dot-separated runs of digits, nothing else. "1.1.x", "1.2.0-beta", "" and a
    # segment too long to compare without wrapping are refused rather than
    # compared, because a comparison would be a guess.
    [[ -z "$(version_problem "$1")" ]]
}

# version_cmp A B -- prints -1, 0 or 1. Both operands must have passed
# version_is_valid first: this does no bounds checking of its own.
version_cmp() {
    local a="$1" b="$2" i n x y
    local -a pa pb
    IFS='.' read -r -a pa <<<"$a"
    IFS='.' read -r -a pb <<<"$b"
    n=${#pa[@]}
    [[ ${#pb[@]} -gt $n ]] && n=${#pb[@]}
    for ((i = 0; i < n; i++)); do
        # `:-0` so 1.1 == 1.1.0; the 10# prefix stops bash reading 08 as octal.
        x="${pa[i]:-0}"
        y="${pb[i]:-0}"
        x=$((10#$x))
        y=$((10#$y))
        if ((x < y)); then echo -1; return 0; fi
        if ((x > y)); then echo 1; return 0; fi
    done
    echo 0
}

gate_existing_driver() {
    local plist="$DEST/Contents/Info.plist" old_ver old_proto cmp

    old_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
    [[ -n "$old_ver" ]] \
        || refuse "the installed driver has no CFBundleShortVersionString; refusing to replace a driver whose version cannot be read"
    version_is_valid "$old_ver" \
        || refuse "the installed driver reports an unparseable version '$old_ver': $(version_problem "$old_ver"); refusing to compare it"

    old_proto="$(/usr/libexec/PlistBuddy -c 'Print :SBAudioProtocolVersion' "$plist" 2>/dev/null)"
    if [[ -n "$old_proto" ]]; then
        [[ "$old_proto" =~ ^[0-9]+$ ]] \
            || refuse "the installed driver declares an unreadable protocol '$old_proto'"
        [[ ${#old_proto} -le $MAX_COMPARE_DIGITS ]] \
            || refuse "the installed driver declares a protocol '$old_proto' with more digits than this comparison can hold"
        if (( old_proto > MPROTO )); then
            refuse "the installed driver speaks protocol $old_proto, newer than this package's $MPROTO; a package never downgrades the wire format"
        fi
        if (( old_proto < MPROTO )); then
            log "protocol move: $old_proto -> $MPROTO; the package is newer on the wire format, so the version comparison does not apply"
            return 0
        fi
    else
        log "the installed driver declares no SBAudioProtocolVersion (pre-1.2.0); comparing versions only"
    fi

    cmp="$(version_cmp "$old_ver" "$MVER")"
    case "$cmp" in
        -1) log "version move: $old_ver -> $MVER (upgrade)" ;;
         0) log "reinstall: $old_ver is already installed; replacing it with a fresh copy (same version)" ;;
         1) refuse "the installed driver is $old_ver, newer than this package's $MVER; refusing to downgrade" ;;
         *) env_problem "version comparison produced '$cmp' for '$old_ver' vs '$MVER'" ;;
    esac
    return 0
}

# validate_bundle DIR EXPECT_ID EXPECT_VERSION EXPECT_PROTOCOL EXPECT_ARCHS LABEL
#
# EXPECT_* may be "-" to skip that check. Used four times: on the payload, on the
# staged copy, on the bundle already at the destination (identity only, because
# replacing an older version is the whole point) and on the installed result.
validate_bundle() {
    local dir="$1" eid="$2" ever="$3" eproto="$4" earchs="$5" label="$6"
    local ok=1 plist bid exe bin

    if [[ -L "$dir" ]]; then
        log "$label: $dir is a symbolic link; refusing to treat it as a bundle"
        return 1
    fi
    if [[ ! -d "$dir" ]]; then
        log "$label: not a directory: $dir"
        return 1
    fi

    plist="$dir/Contents/Info.plist"
    if [[ ! -f "$plist" ]]; then
        log "$label: Contents/Info.plist is missing"
        return 1
    fi
    if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" >/dev/null 2>&1; then
        log "$label: Contents/Info.plist is not a readable property list"
        return 1
    fi

    bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)"
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)"

    if [[ -z "$exe" ]]; then
        log "$label: CFBundleExecutable is empty"
        ok=0
    fi
    bin="$dir/Contents/MacOS/$exe"
    if [[ -z "$exe" || ! -f "$bin" ]]; then
        log "$label: executable missing: Contents/MacOS/$exe"
        ok=0
    elif [[ ! -x "$bin" ]]; then
        log "$label: executable is not executable: Contents/MacOS/$exe"
        ok=0
    fi

    if [[ -n "$eid" && "$eid" != "-" && "$bid" != "$eid" ]]; then
        log "$label: bundle id '$bid' is not '$eid'"
        ok=0
    fi

    if [[ "$ever" != "-" ]]; then
        local v
        v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
        if [[ "$v" != "$ever" ]]; then
            log "$label: version '$v' is not '$ever'"
            ok=0
        fi
    fi

    if [[ "$eproto" != "-" ]]; then
        local p
        p="$(/usr/libexec/PlistBuddy -c 'Print :SBAudioProtocolVersion' "$plist" 2>/dev/null)"
        if [[ "$p" != "$eproto" ]]; then
            log "$label: protocol '$p' is not '$eproto'"
            ok=0
        fi
    fi

    if [[ "$earchs" != "-" && -f "$bin" ]]; then
        local archs want
        archs="$(/usr/bin/lipo -archs "$bin" 2>/dev/null)" || archs=""
        if [[ -z "$archs" ]]; then
            log "$label: cannot read architectures (not a Mach-O?)"
            ok=0
        else
            for want in $earchs; do
                case " $archs " in
                    *" $want "*) : ;;
                    *) log "$label: missing architecture '$want' (has '$archs')"; ok=0 ;;
                esac
            done
        fi
    fi

    [[ $ok -eq 1 ]] || return 1
    log "$label: structure, identity, version, protocol and architectures verified"
    return 0
}

apply_permissions() {
    local dir="$1"
    /usr/sbin/chown -R "$OWNER" "$dir" 2>/dev/null \
        || { log "could not set ownership $OWNER on $dir"; return 1; }
    /bin/chmod -R 755 "$dir" 2>/dev/null \
        || { log "could not set permissions on $dir"; return 1; }
    return 0
}

verify_permissions() {
    local dir="$1" actual exe
    actual="$(/usr/bin/stat -f '%Su:%Sg' "$dir" 2>/dev/null)"
    if [[ "$actual" != "$OWNER" ]]; then
        log "installed owner is '$actual', expected '$OWNER'"
        return 1
    fi
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$dir/Contents/Info.plist" 2>/dev/null)"
    if [[ -z "$exe" || ! -x "$dir/Contents/MacOS/$exe" ]]; then
        log "installed executable is not executable"
        return 1
    fi
    return 0
}

# A backup is only usable if it holds every file the source had, at the same
# size. Checking after the copy is the difference between "we have a backup" and
# "we believe we have a backup"; the old driver is never moved aside before this
# returns 0.
verify_backup_complete() {
    local src="$1" dst="$2" list_src list_dst rel s d
    list_src="$(cd "$src" && find . \( -type f -o -type l \) -print | sort)"
    list_dst="$(cd "$dst" && find . \( -type f -o -type l \) -print | sort)"
    if [[ "$list_src" != "$list_dst" ]]; then
        log "backup file list differs from the source bundle"
        return 1
    fi
    if [[ -z "$list_src" ]]; then
        log "source bundle contains no files; refusing to treat that as a backup"
        return 1
    fi
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        s="$(/usr/bin/stat -f %z "$src/$rel" 2>/dev/null)"
        d="$(/usr/bin/stat -f %z "$dst/$rel" 2>/dev/null)"
        if [[ -z "$s" || "$s" != "$d" ]]; then
            log "backup differs from the source at '$rel' (${s:-?} vs ${d:-?} bytes)"
            return 1
        fi
    done <<<"$list_src"
    return 0
}

# --- test hooks -------------------------------------------------------------

trigger_fault() {
    local point="$1" item
    local IFS=','
    if [[ -n "$TEST_FAULT" ]]; then
        for item in $TEST_FAULT; do
            if [[ "$item" == "$point" ]]; then
                log "test hook: injected failure at '$point'"
                return 0
            fi
        done
    fi
    return 1
}

maybe_pause() {
    local point="$1" mode="${2:-sleep}" i=0
    if [[ -z "$TEST_PAUSE" || "$TEST_PAUSE" != "$point" ]]; then
        return 0
    fi
    if [[ "$mode" != "wait" ]]; then
        log "test hook: pausing at '$point' (pid $$) so the test can kill -9"
        /bin/sleep 30
        return 0
    fi
    # Hold rather than sleep: the test decides when this run continues, which is
    # what makes a window of a few microseconds into something observable.
    log "test hook: holding at '$point' (pid $$) until $STATE_DIR/test-gate appears"
    while [[ $i -lt 600 ]]; do
        if [[ -e "$STATE_DIR/test-gate" ]]; then
            log "test hook: released at '$point'"
            return 0
        fi
        /bin/sleep 0.05
        i=$((i + 1))
    done
    log "test hook: hold at '$point' timed out"
}

# --- rollback ---------------------------------------------------------------

do_rollback() {
    local reason="$1" restore_ok=1

    STAGE="ROLLBACK"
    log "rolling back: $reason"
    write_state "rollback-intent" "$reason"

    # Quarantine whatever is at the destination. At this point it is either the
    # new bundle that failed verification or a partial copy; keeping it lets an
    # operator see what went wrong.
    if [[ -e "$DEST" ]]; then
        rm -rf "$STATE_DIR/failed"
        if mkdir -p "$STATE_DIR/failed" && mv "$DEST" "$STATE_DIR/failed/$DRIVER_NAME" 2>/dev/null; then
            log "quarantined the failed bundle at $STATE_DIR/failed/$DRIVER_NAME"
        else
            log "could not move the failed bundle out of the way"
            restore_ok=0
        fi
    fi

    if [[ $HAVE_OLD -ne 1 ]]; then
        # First install: there was no driver before, so "restored" means "no
        # driver", which is exactly the state the user started from. Leaving a
        # half-installed bundle behind would be worse than nothing.
        log "no previous driver existed; the destination is left empty"
    elif [[ $restore_ok -eq 1 ]]; then
        if [[ -d "$STATE_DIR/backup/$DRIVER_NAME.live" ]]; then
            # The original bundle, moved aside by rename: put it back by rename.
            if mv "$STATE_DIR/backup/$DRIVER_NAME.live" "$DEST" 2>/dev/null; then
                log "restored the previous driver (rename of the original bundle)"
            else
                log "could not move the original bundle back"
                restore_ok=0
            fi
        elif [[ -d "$STATE_DIR/backup/$DRIVER_NAME" ]]; then
            if /usr/bin/ditto "$STATE_DIR/backup/$DRIVER_NAME" "$DEST" 2>/dev/null; then
                log "restored the previous driver (copy of the verified backup)"
            else
                log "could not restore from the backup copy"
                restore_ok=0
            fi
        else
            log "no backup is available to restore from"
            restore_ok=0
        fi

        if [[ $restore_ok -eq 1 ]]; then
            apply_permissions "$DEST" || restore_ok=0
            validate_bundle "$DEST" "$MID" "-" "-" "-" "restored driver" || restore_ok=0
        fi
    fi

    if trigger_fault rollback; then
        restore_ok=0
    fi

    if [[ $restore_ok -eq 1 ]]; then
        rm -rf "$STATE_DIR/staging" "$STATE_DIR/failed"
        write_state "rolled-back" "$reason"
        clear_state
        log "ROLLED BACK: $reason"
        log "the driver at $DEST is the one that was installed before this run"
        return 2
    fi

    write_state "rollback-failed" "$reason"
    log "ROLLBACK FAILED: $reason"
    log "the driver at $DEST may be missing or incomplete -- audio output may be silent"
    log "run the SoundBridge installer again; the verified backup is at $STATE_DIR/backup"
    return 3
}

# --- recovery ---------------------------------------------------------------
#
# Reads the write-ahead state and puts the disk back into one of two consistent
# states: "old driver present" or "new driver present". Idempotent.

recover_transaction() {
    STAGE="RECOVER"

    if [[ ! -f "$STATE_DIR/transaction.state" ]]; then
        # No transaction in flight. A staging copy may still be lying around from
        # a run that died before writing state; it is a copy, so removing it is
        # safe. Backups are left alone: they are only ever removed after a
        # successful install or a successful rollback.
        rm -rf "$STATE_DIR/staging"
        log "no transaction in progress"
        return 0
    fi

    local stage stored_id stored_dest
    stage="$(state_value stage)"
    stored_id="$(state_value id)"
    stored_dest="$(state_value dest)"
    log "found an unfinished transaction: stage='$stage' dest='$stored_dest'"
    if [[ -n "$stored_dest" && "$stored_dest" != "$DEST" ]]; then
        log "state file refers to a different destination ($stored_dest); ignoring it"
        return 0
    fi

    # Stages are grouped by the question they leave open:
    #
    #   pre-replace   the destination has not been touched yet, so the only
    #                 possible residue is a staging copy. A backup may exist but
    #                 the destination is authoritative -- restoring over it would
    #                 mean copying a bundle on top of a bundle.
    #   in-between    the destination may hold the new bundle, the old one, or
    #                 nothing. Verify what is there and commit or restore.
    case "$stage" in
        success|rolled-back)
            rm -rf "$STATE_DIR/staging" "$STATE_DIR/failed"
            [[ "$stage" == "success" ]] && rm -rf "$STATE_DIR/backup"
            clear_state
            log "the previous run already finished ('$stage'); nothing to recover"
            return 0
            ;;
        precheck-intent|precheck-done|staging-intent|staging-done|validating-intent|validating-done|backup-intent|backup-done)
            rm -rf "$STATE_DIR/staging"
            if [[ ! -e "$DEST" && -d "$STATE_DIR/backup/$DRIVER_NAME" ]]; then
                log "the previous run died before replacing but left no driver; restoring the backup"
                /usr/bin/ditto "$STATE_DIR/backup/$DRIVER_NAME" "$DEST" 2>/dev/null \
                    && apply_permissions "$DEST" >/dev/null 2>&1 \
                    || { log "recovery: could not restore the previous driver"; return 3; }
                rm -rf "$STATE_DIR/backup"
            else
                log "the previous run stopped before replacing; the destination was never touched"
            fi
            clear_state
            return 0
            ;;
        replacing-intent|replacing-done|verifying-intent|verifying-done|rollback-intent|rollback-failed)
            if [[ -e "$DEST" ]]; then
                # A complete bundle is at the destination. Verify it; commit if
                # it passes, otherwise fall through to the restore path below.
                # (`validate_bundle` only checks structure and identity, because
                # the manifest may be gone by now.)
                if validate_bundle "$DEST" "$stored_id" "-" "-" "-" "recovered driver"; then
                    log "the driver at the destination is complete; committing the interrupted install"
                    rm -rf "$STATE_DIR/backup" "$STATE_DIR/staging" "$STATE_DIR/failed"
                    clear_state
                    return 0
                fi
                log "the driver at the destination is unusable; falling back to the previous one"
                rm -rf "$STATE_DIR/failed"
                mkdir -p "$STATE_DIR/failed"
                mv "$DEST" "$STATE_DIR/failed/$DRIVER_NAME" 2>/dev/null || true
            fi
            ;;
        *)
            log "unrecognised stage '$stage'; refusing to guess"
            return 3
            ;;
    esac

    # Restore from whichever copy of the old driver survived. Reached only with
    # the destination empty, so nothing is ever copied on top of a bundle.
    if [[ -d "$STATE_DIR/backup/$DRIVER_NAME.live" ]]; then
        if mv "$STATE_DIR/backup/$DRIVER_NAME.live" "$DEST" 2>/dev/null; then
            log "recovery: restored the previous driver (rename)"
        else
            log "recovery: could not restore the previous driver"
            return 3
        fi
    elif [[ -d "$STATE_DIR/backup/$DRIVER_NAME" ]]; then
        if /usr/bin/ditto "$STATE_DIR/backup/$DRIVER_NAME" "$DEST" 2>/dev/null; then
            apply_permissions "$DEST" || true
            log "recovery: restored the previous driver (copy of the verified backup)"
        else
            log "recovery: could not restore the previous driver"
            return 3
        fi
    elif [[ -e "$DEST" ]]; then
        log "recovery: destination exists and no backup is needed"
    else
        log "recovery: no previous driver and no new driver; the install was interrupted before it changed anything"
    fi

    rm -rf "$STATE_DIR/staging"
    clear_state
    log "recovery complete"
    return 0
}

# --- install ----------------------------------------------------------------

install_transaction() {
    local payload_driver="$PAYLOAD_DIR/$DRIVER_NAME"
    local dest_parent staged backup

    # --- PRECHECK -----------------------------------------------------------
    # Nothing below this point has touched the destination yet, so every exit
    # from here to the end of BACKUP_OLD leaves an existing driver exactly as it
    # was.
    STAGE="PRECHECK"
    write_state "precheck-intent"

    [[ -d "$PAYLOAD_DIR" ]] || refuse "payload directory missing: $PAYLOAD_DIR"
    [[ -d "$payload_driver" ]] || refuse "the payload does not contain $DRIVER_NAME"

    MID="$(manifest_value CFBundleIdentifier)" || true
    MVER="$(manifest_value CFBundleShortVersionString)" || true
    MPROTO="$(manifest_value SBAudioProtocolVersion)" || true
    MARCHS="$(manifest_value Architectures)" || true
    [[ -n "$MID" ]] || refuse "manifest has no CFBundleIdentifier"
    [[ -n "$MVER" ]] || refuse "manifest has no CFBundleShortVersionString"
    [[ -n "$MPROTO" ]] || refuse "manifest has no SBAudioProtocolVersion"
    [[ -n "$MARCHS" ]] || refuse "manifest has no Architectures"
    version_is_valid "$MVER" || refuse "the payload declares an unparseable version '$MVER': $(version_problem "$MVER")"
    [[ "$MPROTO" =~ ^[0-9]+$ ]] || refuse "the payload declares an unparseable protocol '$MPROTO'"
    [[ ${#MPROTO} -le $MAX_COMPARE_DIGITS ]] \
        || refuse "the payload declares a protocol '$MPROTO' with more digits than this comparison can hold"
    log "payload manifest: id=$MID version=$MVER protocol=$MPROTO architectures='$MARCHS'"

    validate_bundle "$payload_driver" "$MID" "$MVER" "$MPROTO" "$MARCHS" "payload driver" \
        || refuse "the driver in the payload failed validation"

    dest_parent="$(dirname "$DEST")"
    [[ -d "$dest_parent" ]] || refuse "destination directory missing: $dest_parent"

    if [[ -e "$DEST" ]]; then
        # Identity first: a directory that belongs to somebody else is not ours
        # to replace. Then the gates, which decide whether this package may
        # replace it at all -- every refusal below still leaves it untouched.
        validate_bundle "$DEST" "$MID" "-" "-" "-" "existing driver" \
            || refuse "refusing to replace $DEST: it is not the SoundBridge driver"
        gate_existing_driver
        HAVE_OLD=1
        log "an existing driver is present and will be replaced (a verified backup is taken first)"
    else
        HAVE_OLD=0
        log "no driver is installed; this is a first install"
    fi

    same_volume "$STATE_DIR" "$dest_parent" \
        || env_problem "state directory ($STATE_DIR) and destination ($dest_parent) are on different volumes; the replace could not be atomic"

    write_state "precheck-done"

    # --- STAGING ------------------------------------------------------------
    STAGE="STAGING"
    write_state "staging-intent"
    rm -rf "$STATE_DIR/staging"
    mkdir -p "$STATE_DIR/staging" || env_problem "could not create $STATE_DIR/staging"
    staged="$STATE_DIR/staging/$DRIVER_NAME"

    # ditto, not cp -R: preserves resource forks, symlinks and extended
    # attributes. Into a fresh directory, so nothing can merge.
    /usr/bin/ditto "$payload_driver" "$staged" \
        || refuse "could not copy the driver into staging"
    if trigger_fault staging; then
        refuse "injected staging failure"
    fi
    write_state "staging-done"

    # --- VALIDATING ---------------------------------------------------------
    # The copy is checked as well as the source: a copy that silently lost a file
    # would otherwise be promoted to the destination.
    STAGE="VALIDATING"
    write_state "validating-intent"
    validate_bundle "$staged" "$MID" "$MVER" "$MPROTO" "$MARCHS" "staged driver" \
        || refuse "the staged copy is not a complete driver bundle"
    apply_permissions "$staged" || refuse "could not set ownership and permissions on the staged copy"
    write_state "validating-done"

    # --- BACKUP_OLD ---------------------------------------------------------
    STAGE="BACKUP_OLD"
    if [[ $HAVE_OLD -eq 1 ]]; then
        write_state "backup-intent"
        rm -rf "$STATE_DIR/backup"
        mkdir -p "$STATE_DIR/backup" || refuse "could not create $STATE_DIR/backup"
        backup="$STATE_DIR/backup/$DRIVER_NAME"
        /usr/bin/ditto "$DEST" "$backup" || refuse "could not back up the existing driver"
        if trigger_fault backup; then
            refuse "injected backup failure"
        fi
        verify_backup_complete "$DEST" "$backup" \
            || refuse "the backup is not a complete copy of the existing driver"
        log "existing driver backed up and verified at $backup"
        write_state "backup-done"
    fi

    # --- REPLACING ----------------------------------------------------------
    STAGE="REPLACING"
    write_state "replacing-intent"

    if [[ $HAVE_OLD -eq 1 ]]; then
        # rename, not rm: the old bundle stays complete under a name the HAL
        # loader ignores. If this fails the destination has not moved.
        mv "$DEST" "$STATE_DIR/backup/$DRIVER_NAME.live" \
            || refuse "could not move the existing driver aside; nothing was changed"
        log "existing driver moved aside (rename)"
        maybe_pause "replace-gap"
    fi

    if trigger_fault replace; then
        do_rollback "injected replace failure"
        return $?
    fi

    mv "$staged" "$DEST" || { do_rollback "could not move the new driver into place"; return $?; }
    log "new driver moved into place (rename)"
    write_state "replacing-done"

    # --- VERIFYING ----------------------------------------------------------
    STAGE="VERIFYING"
    write_state "verifying-intent"
    apply_permissions "$DEST" || { do_rollback "could not set ownership and permissions"; return $?; }
    validate_bundle "$DEST" "$MID" "$MVER" "$MPROTO" "$MARCHS" "installed driver" \
        || { do_rollback "the installed driver failed re-verification"; return $?; }
    verify_permissions "$DEST" || { do_rollback "the installed driver has wrong ownership or is not executable"; return $?; }
    if trigger_fault verify; then
        do_rollback "injected post-install verification failure"
        return $?
    fi
    write_state "verifying-done"

    # --- SUCCESS ------------------------------------------------------------
    STAGE="SUCCESS"
    write_state "success"
    rm -rf "$STATE_DIR/staging" "$STATE_DIR/backup"
    clear_state
    log "SUCCESS: driver $MVER (protocol $MPROTO) is installed at $DEST"
    return 0
}

# --- entry point ------------------------------------------------------------

prune_logs() {
    local count f
    count="$(/bin/ls -1t "$LOG_DIR" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [[ -n "$count" ]] || return 0
    [[ "$count" -gt 10 ]] || return 0
    /bin/ls -1t "$LOG_DIR" | /usr/bin/tail -n +11 | while IFS= read -r f; do
        [[ -n "$f" ]] && /bin/rm -f "$LOG_DIR/$f"
    done
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --payload)   PAYLOAD_DIR="${2:-}"; shift 2 ;;
            --manifest)  MANIFEST="${2:-}"; shift 2 ;;
            --dest)      DEST="${2:-}"; shift 2 ;;
            --state)     STATE_DIR="${2:-}"; shift 2 ;;
            --owner)     OWNER="${2:-}"; shift 2 ;;
            --mode)      MODE="${2:-}"; shift 2 ;;
            --test-fault) TEST_FAULT="${2:-}"; shift 2 ;;
            --test-pause) TEST_PAUSE="${2:-}"; shift 2 ;;
            -h|--help)   usage; exit 0 ;;
            *) echo "$PROG: unknown argument '$1'" >&2; exit 4 ;;
        esac
    done

    # Test hooks are opt-in, so a real install cannot be perturbed by a stray
    # environment variable in the installer's context.
    if [[ "${SB_INSTALL_TESTING:-0}" != "1" ]]; then
        TEST_FAULT=""
        TEST_PAUSE=""
    fi
    case "$MODE" in install|recover) : ;; *) echo "$PROG: bad --mode '$MODE'" >&2; exit 4 ;; esac

    [[ -n "$PAYLOAD_DIR" ]] || env_problem "--payload is required"
    [[ -n "$MANIFEST" ]] || env_problem "--manifest is required"
    [[ -n "$DEST" ]] || env_problem "--dest is required"
    [[ -n "$STATE_DIR" ]] || env_problem "--state is required"

    case "$DEST" in
        /*) : ;;
        *) env_problem "--dest must be an absolute path" ;;
    esac

    for tool in /usr/bin/ditto /usr/bin/lipo /usr/bin/stat /usr/libexec/PlistBuddy /usr/sbin/chown /bin/chmod; do
        [[ -x "$tool" ]] || env_problem "required tool missing: $tool"
    done

    mkdir -p "$STATE_DIR/log" 2>/dev/null || env_problem "could not create state directory: $STATE_DIR"
    STATE_DIR="$(cd "$STATE_DIR" && pwd)" || env_problem "state directory is not usable: $STATE_DIR"
    LOG_DIR="$STATE_DIR/log"
    LOG_FILE="$LOG_DIR/install-$(date '+%Y%m%d-%H%M%S')-$$.log"
    : >"$LOG_FILE" 2>/dev/null || env_problem "could not create a log file in $LOG_DIR"

    log "$PROG starting (mode=$MODE dest=$DEST)"
    log "state directory: $STATE_DIR"
    log "log: $LOG_FILE"

    LOCK_DIR="$STATE_DIR/transaction.lock"
    # The lock covers recovery too. Taking it only around the install would let a
    # recovery run delete the staging directory a live install is using, and let
    # two recoveries each untangle half of the same unfinished transaction.
    trap 'release_lock' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    acquire_lock
    local lock_rc=$?
    if [[ $lock_rc -ne 0 ]]; then
        prune_logs
        exit $lock_rc
    fi

    if [[ "$MODE" == "recover" ]]; then
        recover_transaction
        local rc=$?
        prune_logs
        exit $rc
    fi

    # An interrupted run must be repaired before a new one starts, otherwise the
    # new run would build on a destination nobody has verified.
    recover_transaction
    local rec=$?
    if [[ $rec -ne 0 ]]; then
        log "refusing to install while a previous transaction is unrecoverable (rc=$rec)"
        prune_logs
        exit $rec
    fi

    install_transaction
    local rc=$?
    prune_logs
    exit $rc
}

main "$@"
