#!/bin/bash
#
# Complete, idempotent removal of SoundBridge from this machine.
#
# Usage
#   tools/uninstall_driver.sh              # full teardown (see the phases below)
#   tools/uninstall_driver.sh --dry-run    # print the whole plan; change nothing
#   tools/uninstall_driver.sh --keep-host  # leave a running Host alone
#   tools/uninstall_driver.sh --timeout 5  # seconds to wait for the Host to exit
#   tools/uninstall_driver.sh --help
#
# Exit codes
#   0  nothing of ours is left in a state this script can change
#   1  something of ours could not be stopped or removed (reported per item)
#   2  bad usage
#
# Ownership manifest
# ------------------
# This script touches the paths below and nothing else. There is no wildcard that
# is not ours, no search for "anything called soundbridge", and no path outside
# the current user's own resources.
#
#   class          path                                                   action
#   -------------  -----------------------------------------------------  ---------------------------
#   installation   /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver    removed, after identifying it
#   installation   /Applications/SoundBridge.app                           reported, never removed here
#   runtime        /tmp/soundbridge-<our uid>-*                            removed
#   runtime        /tmp/soundbridge-devices.txt                            removed when owned by us
#   user state     ~/Library/Application Support/SoundBridge               kept
#   user config    ~/Library/Preferences/com.soundbridge.menubar.plist     kept
#   user data      ~/Library/Logs/SoundBridge                              kept
#   installer      the SoundBridge package receipt                         reported, never modified
#   system         coreaudiod                                              never signalled
#
# The App is the PKG payload's other half and is removed by the user (drag to the
# Trash) or by the installer's own maintenance, not by this script: deleting a
# running app's bundle from under it is worse than leaving it. It is reported so
# the state is not ambiguous.
#
# User data is kept on purpose
# ----------------------------
# EQ values, volume state, the device registry and the logs are what a reinstall
# resumes from. Nothing here removes them. Removing them is a separate decision
# and a separate command, and it is not made for the user.
#
# Installer receipts and InstallerState
# -------------------------------------
# The receipt (`pkgutil --pkg-info com.soundbridge.menubar`) records that the
# package was installed. It does not describe what is on disk now, it is not what
# makes the driver load, and deleting it does not unload anything: `coreaudiod`
# keeps its loaded copy of a bundle that is already gone. `installer.db` /
# `InstallerState` belong to macOS, and writing to them to make this output look
# clean is exactly the kind of undocumented system manipulation that turns a
# cosmetic report into an unsupported machine. So the receipt is *reported* and
# left alone; a receipt for a package that is no longer on disk is harmless, and
# the next install replaces it.
#
# The four states this script keeps apart
# ---------------------------------------
#   1. Driver files removed from disk      — this script does it, and verifies it.
#   2. Driver unloaded from coreaudiod     — NOT done here. The loaded copy
#                                            survives until coreaudiod restarts.
#   3. CoreAudio device disappeared        — follows from (2), so it cannot be
#                                            confirmed until then.
#   4. coreaudiod restarted                — never done by this script.
# The final report prints each one, so a user who still sees the device is not
# told that the uninstall failed.
#
# What this never does
#   * No `killall coreaudiod` (or any signal to a system daemon). Restarting
#     coreaudiod cuts audio for every running application. It is the user's
#     decision; the exact command is printed and never run.
#   * No SIP or Gatekeeper change, and no request that the user disable either.
#   * No removal of another vendor's HAL driver, or of a directory at our path
#     that is not our bundle.
#   * No removal of user configuration.
#
# Test seam (unset in normal use)
#   --sandbox-root DIR  Re-root every owned path under DIR and run the whole
#                       teardown there without privileges, so the lifecycle can
#                       be exercised for real on a disposable tree. Every path is
#                       checked to stay inside DIR; nothing outside it is read,
#                       signalled or removed.
#   SB_DRIVER_PATH      Preview seam: inspect a different driver bundle with
#                       --dry-run. It cannot remove anything.
#
set -uo pipefail

DEFAULT_DRIVER_PATH="/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
EXPECTED_BUNDLE_ID="com.soundbridge.driver"
APP_PATH="/Applications/SoundBridge.app"
RECEIPT_ID="com.soundbridge.menubar"
OWN_UID="$(id -u)"

DRY_RUN=0
STOP_HOST=1
HOST_TIMEOUT=5
SANDBOX_ROOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --keep-host) STOP_HOST=0; shift ;;
        --timeout) HOST_TIMEOUT="${2:-}"; shift 2 ;;
        --timeout=*) HOST_TIMEOUT="${1#*=}"; shift ;;
        --sandbox-root) SANDBOX_ROOT="${2:-}"; shift 2 ;;
        --sandbox-root=*) SANDBOX_ROOT="${1#*=}"; shift ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if ! [[ "$HOST_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$HOST_TIMEOUT" -lt 1 ]]; then
    echo "error: --timeout needs a whole number of seconds, at least 1" >&2
    exit 2
fi

# --- resolved paths -----------------------------------------------------------
#
# `--sandbox-root` is resolved first and then prefixes every owned path, so the
# lists below are the same in a test and on a real machine.
if [[ -n "$SANDBOX_ROOT" ]]; then
    # Resolved physically, because the Host check compares this prefix with
    # `ps -o comm=`, which reports the path the parent actually exec'd. On macOS
    # /var is a symlink to /private/var, and a logical path here would never
    # match a process started through the physical one.
    SANDBOX_ROOT="$(cd "$SANDBOX_ROOT" 2>/dev/null && pwd -P)" || {
        echo "error: --sandbox-root is not a directory" >&2
        exit 2
    }
    DRIVER_PATH="$SANDBOX_ROOT$DEFAULT_DRIVER_PATH"
    APP_PATH="$SANDBOX_ROOT/Applications/SoundBridge.app"
    IPC_PREFIX="$SANDBOX_ROOT/tmp/soundbridge-$OWN_UID-"
    CONTROL_FILE="$SANDBOX_ROOT/tmp/soundbridge-devices.txt"
    SANDBOX_STATE="$SANDBOX_ROOT/Library/Application Support/SoundBridge"
    SANDBOX_LOGS="$SANDBOX_ROOT/Library/Logs/SoundBridge"
    RECEIPT_MARKER="$SANDBOX_ROOT/receipt-present"
else
    DRIVER_PATH="${SB_DRIVER_PATH:-$DEFAULT_DRIVER_PATH}"
    IPC_PREFIX="/tmp/soundbridge-$OWN_UID-"
    CONTROL_FILE="/tmp/soundbridge-devices.txt"
    SANDBOX_STATE="$HOME/Library/Application Support/SoundBridge"
    SANDBOX_LOGS="$HOME/Library/Logs/SoundBridge"
fi

PLIST="$DRIVER_PATH/Contents/Info.plist"

if [[ -n "$SANDBOX_ROOT" ]]; then
    case "$DRIVER_PATH" in
        "$SANDBOX_ROOT"/*) ;;
        *) echo "error: refusing to run: the driver path escapes the sandbox" >&2; exit 2 ;;
    esac
elif [[ "$DRIVER_PATH" != "$DEFAULT_DRIVER_PATH" ]]; then
    if [[ "$(basename "$DRIVER_PATH")" != "SoundBridgeDriver.driver" ]]; then
        echo "error: SB_DRIVER_PATH must end in SoundBridgeDriver.driver" >&2
        exit 2
    fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "error: SB_DRIVER_PATH is a preview seam; pass --dry-run with it" >&2
        exit 2
    fi
fi

say()  { echo "$*"; }
info() { echo "      $*"; }
warn() { echo "ERROR: $*" >&2; }

FAILURES=0
note_failure() { FAILURES=$((FAILURES + 1)); warn "$@"; }

# --- phase 1: identify ------------------------------------------------------
#
# Nothing is signalled or removed before this decides. The checks are
# `uninstall_driver.sh`'s original ones, kept because they are what makes
# "remove only what is ours" true rather than hopeful: a symlink is not a
# bundle, a file at the path is not a bundle, and a bundle that does not declare
# com.soundbridge.driver is somebody else's.

IDENTIFY="absent"
if [[ -L "$DRIVER_PATH" ]]; then
    IDENTIFY="refused"
    warn "$DRIVER_PATH is a symlink; refusing to remove something that is not a bundle"
elif [[ ! -e "$DRIVER_PATH" ]]; then
    IDENTIFY="absent"
elif [[ ! -d "$DRIVER_PATH" ]]; then
    IDENTIFY="refused"
    warn "$DRIVER_PATH exists but is not a directory; refusing to remove it"
elif [[ ! -f "$PLIST" ]]; then
    IDENTIFY="refused"
    warn "$DRIVER_PATH has no Contents/Info.plist; refusing to remove a bundle that cannot be identified"
else
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
    if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
        IDENTIFY="refused"
        warn "$DRIVER_PATH declares bundle id '${BUNDLE_ID:-<none>}', not $EXPECTED_BUNDLE_ID"
        warn "nothing was removed"
    else
        IDENTIFY="ours"
        DRIVER_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
    fi
fi

if [[ "$IDENTIFY" == "refused" ]]; then
    say ""
    say "Nothing was changed. This path is not a SoundBridge driver, and removing"
    say "an unidentified bundle is not something this script will do."
    exit 1
fi

# --- phase 2: stop SoundBridge-owned Host processes ---------------------------
#
# "Owned" means the executable is our Host binary *and* the process belongs to
# this user. A process that is merely *named* like ours is not signalled, which is
# the difference between stopping our Host and matching a string.

host_executable_is_ours() {
    local path="$1"
    [[ -n "$path" ]] || return 1
    if [[ -n "$SANDBOX_ROOT" ]]; then
        case "$path" in
            "$SANDBOX_ROOT"/*/SoundBridgeHost) return 0 ;;
            *) return 1 ;;
        esac
    fi
    case "$path" in
        */SoundBridge.app/Contents/MacOS/SoundBridgeHost) return 0 ;;
        */SoundBridge.app/Contents/Helpers/SoundBridgeHost) return 0 ;;
        */.build/debug/SoundBridgeHost) return 0 ;;
        */.build/release/SoundBridgeHost) return 0 ;;
        *) return 1 ;;
    esac
}

# `ps` is the only way to attribute a candidate process to this user and to an
# executable path. Where it cannot read process state, "no Host was running" is
# a guess, so the stop phase reports that it could not verify instead of
# reporting success it does not have.
process_table_readable() {
    ps -p $$ -o comm= >/dev/null 2>&1
}

# A zombie still answers `kill -0` but holds nothing — it has already exited and
# is only waiting to be collected. Counting it as running would make the script
# report a failure, and escalate to SIGKILL against a process that is gone.
process_is_running() {
    local pid="$1" state
    state="$(ps -p "$pid" -o stat= 2>/dev/null || true)"
    [[ -n "$state" ]] || return 1
    [[ "${state#Z}" == "$state" ]] || return 1
    kill -0 "$pid" 2>/dev/null
}

PROCESS_ERROR=""

host_pids() {
    local pid comm uid out status
    out="$(pgrep -f 'SoundBridgeHost' 2>/dev/null)"
    status=$?
    if [[ "$status" -gt 1 ]]; then
        PROCESS_ERROR="pgrep exited $status"
        return 1
    fi
    for pid in $out; do
        comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        uid="$(ps -p "$pid" -o uid= 2>/dev/null || true)"
        # A pid that exited between the two calls has no owner to check; it is
        # also not something that can still be holding the driver.
        [[ -n "$comm" && -n "$uid" ]] || continue
        # `ps` pads the uid column, so a string comparison against `id -u`
        # fails without this.
        uid="${uid//[[:space:]]/}"
        [[ "$uid" == "$OWN_UID" ]] || continue
        host_executable_is_ours "$comm" || continue
        echo "$pid"
    done
}

stop_hosts() {
    local pids still pid comm elapsed=0

    if ! process_table_readable; then
        HOST_RESULT="not verified: process state is unreadable here"
        note_failure "could not check for a running Host: 'ps' is not permitted in this environment"
        return 1
    fi

    pids="$(host_pids)"
    if [[ $? -gt 0 ]]; then
        HOST_RESULT="not verified: ${PROCESS_ERROR:-could not list processes}"
        note_failure "$HOST_RESULT"
        return 1
    fi
    pids="${pids//$'\n'/ }"
    pids="${pids# }"
    pids="${pids% }"

    if [[ -z "$pids" ]]; then
        HOST_RESULT="no SoundBridge Host was running"
        info "$HOST_RESULT"
        return 0
    fi

    info "asking SoundBridge Host to stop: $pids (TERM, then ${HOST_TIMEOUT}s)"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true

    while :; do
        still=""
        for pid in $pids; do
            process_is_running "$pid" && still="$still $pid"
        done
        still="${still# }"
        [[ -z "$still" ]] && break

        if [[ "$elapsed" -ge $((HOST_TIMEOUT * 10)) ]]; then
            break
        fi
        sleep 0.1
        elapsed=$((elapsed + 1))
    done

    if [[ -z "$still" ]]; then
        HOST_RESULT="stopped $pids"
        info "$HOST_RESULT"
        return 0
    fi

    # Escalate only against the pids identified above and re-confirmed as ours.
    # A pid that exited and was reused is not something we may kill.
    info "still running after ${HOST_TIMEOUT}s: $still"
    for pid in $still; do
        comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
        if host_executable_is_ours "$comm"; then
            info "escalating to SIGKILL for pid $pid ($comm)"
            kill -KILL "$pid" 2>/dev/null || true
        else
            note_failure "pid $pid was reused by '$comm'; not killing it"
        fi
    done
    sleep 0.2

    still=""
    for pid in $pids; do
        process_is_running "$pid" && still="$still $pid"
    done
    still="${still# }"

    if [[ -n "$still" ]]; then
        HOST_RESULT="could not stop $still"
        note_failure "$HOST_RESULT"
        return 1
    fi
    HOST_RESULT="stopped $pids (SIGKILL after ${HOST_TIMEOUT}s)"
    info "$HOST_RESULT"
    return 0
}

# --- phase 3: release owned IPC resources ------------------------------------
#
# The Host unlinks its mappings on a clean exit, which phase 2 produces. This
# phase is for the Host that crashed: the files it left are ours, they are named
# with our uid, and a stale mapping is what makes the next start read a device
# list that no longer exists.

release_ipc() {
    local removed=0 failed=0 control=0 file
    for file in "$IPC_PREFIX"*; do
        [[ -e "$file" ]] || continue
        if [[ ! -f "$file" ]]; then
            note_failure "not removing $file: it is not a regular file"
            failed=$((failed + 1))
            continue
        fi
        if rm -f -- "$file"; then
            removed=$((removed + 1))
        else
            note_failure "could not remove $file"
            failed=$((failed + 1))
        fi
    done

    # The device control file is per machine, not per user, so it is only ours to
    # remove when this user owns it.
    if [[ -e "$CONTROL_FILE" ]]; then
        if [[ -O "$CONTROL_FILE" ]]; then
            if rm -f -- "$CONTROL_FILE"; then
                control=1
            else
                note_failure "could not remove $CONTROL_FILE"
                failed=$((failed + 1))
            fi
        else
            info "leaving $CONTROL_FILE: it belongs to another user"
        fi
    fi

    IPC_RESULT="removed $removed shared-memory file(s)"
    [[ "$control" -eq 1 ]] && IPC_RESULT="$IPC_RESULT and the device control file"
    if [[ "$failed" -gt 0 ]]; then
        IPC_RESULT="$IPC_RESULT; $failed could not be removed"
    fi
    info "$IPC_RESULT"
    [[ "$failed" -eq 0 ]]
}

# --- phase 4: remove the driver bundle ---------------------------------------

remove_driver() {
    if [[ "$IDENTIFY" == "absent" ]]; then
        DRIVER_RESULT="already absent"
        info "$DRIVER_RESULT"
        return 0
    fi

    if [[ -n "$SANDBOX_ROOT" ]]; then
        # Sandbox: the same command, without the administrator prompt. The path is
        # already proven to be inside the sandbox root.
        info "removing $DRIVER_PATH"
        /bin/rm -rf "$DRIVER_PATH" || true
    else
        say ""
        say "Requesting administrator rights for this one removal..."
        if ! osascript -e "do shell script \"/bin/rm -rf '$DRIVER_PATH'\" with administrator privileges"; then
            DRIVER_RESULT="not removed (cancelled, or authorization failed)"
            note_failure "the driver is still installed at $DRIVER_PATH"
            return 1
        fi
    fi

    # The authorisation dialog can be dismissed in ways osascript reports as
    # success; the filesystem is the authority on whether the bundle is gone.
    if [[ -e "$DRIVER_PATH" || -L "$DRIVER_PATH" ]]; then
        DRIVER_RESULT="still present after the removal command"
        note_failure "$DRIVER_PATH still exists after the removal command"
        return 1
    fi

    DRIVER_RESULT="removed"
    info "$DRIVER_RESULT"
    return 0
}

# --- report ------------------------------------------------------------------

receipt_state() {
    if [[ -n "$SANDBOX_ROOT" ]]; then
        [[ -f "$RECEIPT_MARKER" ]] && { echo "present"; return; }
        echo "absent"
        return
    fi
    if /usr/sbin/pkgutil --pkg-info "$RECEIPT_ID" >/dev/null 2>&1; then
        echo "present"
    else
        echo "absent"
    fi
}

report() {
    local app_state receipt
    [[ -d "$APP_PATH" ]] && app_state="present (not removed by this script)" || app_state="absent"
    receipt="$(receipt_state)"

    say ""
    say "SoundBridge uninstall"
    say "===================="
    info "driver file:        $DRIVER_PATH"
    info "driver removal:     $DRIVER_RESULT"
    info "host process:       $HOST_RESULT"
    info "shared memory:      $IPC_RESULT"
    info "app bundle:         $APP_PATH — $app_state"
    info "package receipt:    $RECEIPT_ID — $receipt (left alone on purpose)"
    say ""
    say "Four states, kept separate:"
    info "1. driver files removed from disk:  $DRIVER_RESULT"
    info "2. driver unloaded from coreaudiod: no — coreaudiod keeps its loaded copy"
    info "3. CoreAudio device disappeared:    not yet; it goes when (2) happens"
    info "4. coreaudiod restarted:            no — this script never signals it"
    say ""
    say "Kept, so a reinstall resumes where you left off:"
    info "$SANDBOX_STATE"
    info "$SANDBOX_LOGS"

    if [[ "$receipt" == "present" ]]; then
        say ""
        say "The package receipt is still registered. That is expected: it records"
        say "that the package was installed, not what is on disk, and deleting it"
        say "would not unload the driver. The next install replaces it."
    fi

    say ""
    say "If you are ready for (2) and (3), and accept that audio stops for every"
    say "application while coreaudiod restarts, one of:"
    info "• log out and back in, or restart the Mac"
    info "• run this by hand: sudo killall coreaudiod"
    say "Neither is run by this script."
}

# --- plan and run ------------------------------------------------------------

say "SoundBridge uninstall plan"
say "========================="
info "driver:  $IDENTIFY${DRIVER_VERSION:+ (version $DRIVER_VERSION)}"
info "host:    $([[ "$STOP_HOST" -eq 1 ]] && echo "stop after a bounded wait (${HOST_TIMEOUT}s)" || echo "left running (--keep-host)")"
info "ipc:     $IPC_PREFIX*${SANDBOX_ROOT:+ (inside the sandbox)}"
info "keeps:   user state, preferences and logs"
info "coreaudiod: never signalled"

if [[ "$DRY_RUN" -eq 1 ]]; then
    say ""
    say "Dry run: nothing was changed. The removal would be:"
    if [[ "$IDENTIFY" == "ours" ]]; then
        echo "  /bin/rm -rf '$DRIVER_PATH'"
    else
        info "(no driver bundle at $DRIVER_PATH, so nothing to remove)"
    fi
    exit 0
fi

say ""
HOST_RESULT="not attempted (--keep-host)"
IPC_RESULT="not attempted"
DRIVER_RESULT="not attempted"

if [[ "$STOP_HOST" -eq 1 ]]; then
    stop_hosts || true
fi

release_ipc || true
remove_driver || true

report

if [[ "$FAILURES" -gt 0 ]]; then
    say ""
    warn "$FAILURES item(s) could not be completed; see the messages above."
    exit 1
fi

say ""
say "Done: nothing of SoundBridge's remains in a state this script can change."
exit 0
