#!/bin/bash
#
# Remove the installed SoundBridge HAL driver from /Library/Audio/Plug-Ins/HAL.
#
# What this does not do
# ---------------------
# It does not stop coreaudiod and it does not restart it. The previous version
# ended with `killall coreaudiod` inside the same privileged command, so every
# uninstall cut audio for every running application, with no warning and no way
# to decline. Killing a system daemon is not part of removing a driver: the
# bundle can be deleted while coreaudiod keeps its loaded copy until the next
# restart, and the user decides when that restart happens. The commands for it
# are printed at the end and are never executed here.
#
# It also does not elevate on its own: the removal runs through the macOS
# administrator prompt (one authentication, for one fixed path), and --dry-run
# shows the whole plan without asking for anything.
#
# Safety checks
# -------------
# The only path this script will ever remove is
#   /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver
# It refuses to act if that path is a symlink, and it reads the bundle's own
# Info.plist first: a directory called SoundBridgeDriver.driver that is not
# com.soundbridge.driver is not ours to delete. A path that is not there is
# reported as "nothing to uninstall", not as a failure.
#
# Usage
#   tools/uninstall_driver.sh              # remove the driver bundle
#   tools/uninstall_driver.sh --dry-run    # print what would be removed; change nothing
#   tools/uninstall_driver.sh --help
#
# Exit codes
#   0  the driver is not installed any more (removed, or it was not there)
#   1  the bundle is not the SoundBridge driver, or the removal failed
#   2  bad usage
#
# Environment (test seam; unset in normal use)
#   SB_DRIVER_PATH=<path>  inspect a different bundle, for --dry-run against a
#                          fixture. It cannot remove anything: the removal path
#                          is fixed, so a run with this set and no --dry-run is
#                          rejected.
#
set -uo pipefail

DEFAULT_DRIVER_PATH="/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
DRIVER_PATH="${SB_DRIVER_PATH:-$DEFAULT_DRIVER_PATH}"
EXPECTED_BUNDLE_ID="com.soundbridge.driver"
PLIST="$DRIVER_PATH/Contents/Info.plist"

DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

info() { echo "      $*"; }

if [[ "$DRIVER_PATH" != "$DEFAULT_DRIVER_PATH" ]]; then
    if [[ "$(basename "$DRIVER_PATH")" != "SoundBridgeDriver.driver" ]]; then
        echo "error: SB_DRIVER_PATH must end in SoundBridgeDriver.driver" >&2
        exit 2
    fi
    if [[ "$DRY_RUN" -eq 0 ]]; then
        echo "error: SB_DRIVER_PATH is a preview seam; pass --dry-run with it" >&2
        exit 2
    fi
fi

# The restart advice is the one thing this script cannot do for the user, so it
# says exactly what to run and that it is not run here.
print_restart_advice() {
    echo ""
    echo "After the bundle is gone, coreaudiod may keep its loaded copy until it"
    echo "restarts. Nothing in this script restarts it. When you are ready, one of:"
    echo "  • log out and back in, or restart the Mac"
    echo "  • run this by hand: sudo killall coreaudiod"
}

if [[ -L "$DRIVER_PATH" ]]; then
    echo "ERROR: $DRIVER_PATH is a symlink; refusing to remove something that is not a bundle" >&2
    exit 1
fi

if [[ ! -e "$DRIVER_PATH" ]]; then
    echo "Nothing to uninstall: $DRIVER_PATH does not exist"
    exit 0
fi

if [[ ! -d "$DRIVER_PATH" ]]; then
    echo "ERROR: $DRIVER_PATH exists but is not a directory; refusing to remove it" >&2
    exit 1
fi

if [[ ! -f "$PLIST" ]]; then
    echo "ERROR: $DRIVER_PATH has no Contents/Info.plist; refusing to remove a bundle that cannot be identified" >&2
    exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "ERROR: $DRIVER_PATH declares bundle id '${BUNDLE_ID:-<none>}', not $EXPECTED_BUNDLE_ID" >&2
    echo "       nothing was removed" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
echo "SoundBridge driver to remove:"
info "path:     $DRIVER_PATH"
info "bundle:   $BUNDLE_ID"
info "version:  ${VERSION:-<not declared>}"
info "coreaudiod: left running; this script does not stop or restart it"

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "Dry run: nothing was removed. The removal would be:"
    echo "  sudo rm -rf $DRIVER_PATH"
    print_restart_advice
    exit 0
fi

echo ""
echo "Requesting administrator rights for this one removal..."
if ! osascript -e "do shell script \"/bin/rm -rf '$DRIVER_PATH'\" with administrator privileges"; then
    echo "ERROR: the removal did not run (cancelled, or authorization failed)" >&2
    echo "       the driver is still installed at $DRIVER_PATH" >&2
    exit 1
fi

# The authorisation dialog can be dismissed in ways osascript reports as
# success; the filesystem is the authority on whether the bundle is gone.
if [[ -e "$DRIVER_PATH" || -L "$DRIVER_PATH" ]]; then
    echo "ERROR: $DRIVER_PATH still exists after the removal command" >&2
    exit 1
fi

echo "Removed: $DRIVER_PATH"
print_restart_advice
exit 0
