#!/bin/bash
#
# Prove that the driver transaction carried by an installer package actually
# installs, using nothing but temporary directories.
#
# Phase 2.2.1. verify_installer_pkg.sh answers "are the right files in the
# archive". This answers "does the archive install a driver" -- from the bytes of
# the artifact, not from a copy in the source tree. It expands the package,
# takes the payload's transaction script, manifest and driver, and runs the
# transaction against a fake HAL directory under mktemp.
#
# It never installs the package, never calls sudo, and never touches
# /Library/Audio/Plug-Ins/HAL.
#
# Usage
#   tools/test_installer_pkg_roundtrip.sh dist/SoundBridge-1.2.0.pkg
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="${1:-}"
DRIVER_NAME="SoundBridgeDriver.driver"
SUPPORT_REL="Library/Application Support/SoundBridge/InstallerPayload"
HAL_REL="Library/Audio/Plug-Ins/HAL"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 2; }

[[ -n "$PKG" ]] || die "usage: $0 <path-to.pkg>"
[[ -f "$PKG" ]] || die "package not found: $PKG"
[[ -x /usr/sbin/pkgutil ]] || die "pkgutil is missing"

OWNER="$(id -un):$(id -gn)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sb-roundtrip.XXXXXX")" || die "cannot create a temp dir"
cleanup() { /bin/rm -rf "$WORK"; }
trap cleanup EXIT

/usr/sbin/pkgutil --expand-full "$PKG" "$WORK/expanded" >/dev/null 2>&1 \
    || die "pkgutil --expand-full failed"

PAYLOAD="$(find "$WORK/expanded" -maxdepth 3 -type d -name Payload | head -1)"
[[ -n "$PAYLOAD" ]] || die "no payload found in the package"

STAGE="$PAYLOAD/$SUPPORT_REL"
SRC_TX="$STAGE/transaction.sh"
SRC_MANIFEST="$STAGE/manifest.plist"
SRC_DRIVER="$STAGE/driver/$DRIVER_NAME"

for f in "$SRC_TX" "$SRC_MANIFEST" "$SRC_DRIVER"; do
    [[ -e "$f" ]] || die "the payload is missing $f"
done

WANT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC_MANIFEST" 2>/dev/null)"
WANT_PROTOCOL="$(/usr/libexec/PlistBuddy -c 'Print :SBAudioProtocolVersion' "$SRC_MANIFEST" 2>/dev/null)"
WANT_ARCHS="$(/usr/libexec/PlistBuddy -c 'Print :Architectures' "$SRC_MANIFEST" 2>/dev/null)"
[[ -n "$WANT_VERSION" && -n "$WANT_PROTOCOL" && -n "$WANT_ARCHS" ]] \
    || die "the payload manifest is incomplete"

echo "Round-tripping $PKG"
echo "  manifest says: driver $WANT_VERSION, protocol $WANT_PROTOCOL, $WANT_ARCHS"
echo ""

version_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

# Content digest of a directory tree, used to prove that the driver step did not
# touch the app that `installer` had already written.
tree_digest() {
    local dir="$1"
    (
        cd "$dir" 2>/dev/null || exit 1
        find . -type f | LC_ALL=C sort | while IFS= read -r f; do
            printf '%s ' "$f"
            /usr/bin/shasum -a 256 "$f" | /usr/bin/awk '{print $1}'
        done
    ) | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

run_case() {
    local label="$1" hal="$2"
    local state="$WORK/state-$label" log="$WORK/$label.log" rc
    mkdir -p "$state" || return 1
    /bin/bash "$SRC_TX" \
        --payload "$STAGE/driver" \
        --manifest "$SRC_MANIFEST" \
        --dest "$hal/$DRIVER_NAME" \
        --state "$state" \
        --owner "$OWNER" \
        --mode install >"$log" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then pass "$label: the transaction exits 0"; else fail "$label: the transaction exits $rc"; fi

    local got
    got="$(version_of "$hal/$DRIVER_NAME")"
    if [[ "$got" == "$WANT_VERSION" ]]; then
        pass "$label: the installed driver reports $got"
    else
        fail "$label: the installed driver reports '${got:-<missing>}', expected $WANT_VERSION"
    fi

    local proto
    proto="$(/usr/libexec/PlistBuddy -c 'Print :SBAudioProtocolVersion' "$hal/$DRIVER_NAME/Contents/Info.plist" 2>/dev/null)"
    if [[ "$proto" == "$WANT_PROTOCOL" ]]; then
        pass "$label: the installed driver reports protocol $proto"
    else
        fail "$label: the installed driver reports protocol '${proto:-<missing>}', expected $WANT_PROTOCOL"
    fi

    local exe archs want
    exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$hal/$DRIVER_NAME/Contents/Info.plist" 2>/dev/null)"
    archs="$(/usr/bin/lipo -archs "$hal/$DRIVER_NAME/Contents/MacOS/$exe" 2>/dev/null)"
    local arch_ok=1
    for want in $WANT_ARCHS; do
        case " $archs " in
            *" $want "*) : ;;
            *) arch_ok=0 ;;
        esac
    done
    if [[ $arch_ok -eq 1 ]]; then pass "$label: architectures are $archs"; else fail "$label: architectures are '$archs', expected to include '$WANT_ARCHS'"; fi

    if [[ ! -e "$state/transaction.state" ]]; then
        pass "$label: the transaction state is cleared"
    else
        fail "$label: a transaction state file was left behind"
    fi
    if [[ ! -e "$state/backup" && ! -e "$state/staging" ]]; then
        pass "$label: no staging or backup left behind"
    else
        fail "$label: staging or backup left behind"
    fi
}

# 1. A machine with no driver at all.
HAL_FRESH="$WORK/root-fresh/$HAL_REL"
mkdir -p "$HAL_FRESH"
run_case "fresh" "$HAL_FRESH"

# 2. A machine running an older driver: the case users are recovering from.
HAL_OLD="$WORK/root-old/$HAL_REL"
mkdir -p "$HAL_OLD"
/usr/bin/ditto "$SRC_DRIVER" "$HAL_OLD/$DRIVER_NAME" || die "cannot stage the fake old driver"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.9' "$HAL_OLD/$DRIVER_NAME/Contents/Info.plist" \
    || die "cannot downgrade the fake old driver"
if [[ "$(version_of "$HAL_OLD/$DRIVER_NAME")" == "1.0.9" ]]; then
    pass "the fake old driver reports 1.0.9 before the install"
else
    fail "could not set up the fake old driver"
fi
run_case "upgrade" "$HAL_OLD"

# 3. The state a failed `installer` run leaves behind. The app has already been
#    written to its final location by the time postinstall runs, so a failed
#    driver step leaves the machine with a new app and an old driver. The package
#    is inconsistent at that instant; running it again has to converge.
HAL_PARTIAL="$WORK/root-partial/$HAL_REL"
APP_INSTALLED="$WORK/root-partial/Applications/SoundBridge.app"
STATE_PARTIAL="$WORK/state-partial"
mkdir -p "$HAL_PARTIAL" "$(dirname "$APP_INSTALLED")" "$STATE_PARTIAL"
/usr/bin/ditto "$PAYLOAD/Applications/SoundBridge.app" "$APP_INSTALLED" \
    || die "cannot stage the app from the payload"
/usr/bin/ditto "$SRC_DRIVER" "$HAL_PARTIAL/$DRIVER_NAME" \
    || die "cannot stage the old driver"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.9' \
    "$HAL_PARTIAL/$DRIVER_NAME/Contents/Info.plist" >/dev/null 2>&1
APP_DIGEST="$(tree_digest "$APP_INSTALLED")"

SB_INSTALL_TESTING=1 /bin/bash "$SRC_TX" --payload "$STAGE/driver" --manifest "$SRC_MANIFEST" \
    --dest "$HAL_PARTIAL/$DRIVER_NAME" --state "$STATE_PARTIAL" --owner "$OWNER" \
    --mode install --test-fault replace >"$WORK/partial-fail.log" 2>&1
rc=$?
if [[ $rc -eq 2 ]]; then
    pass "partial: the driver step fails and rolls back (exit 2)"
else
    fail "partial: the driver step should have rolled back, got exit $rc"
fi
if [[ "$(version_of "$HAL_PARTIAL/$DRIVER_NAME")" == "1.0.9" ]]; then
    pass "partial: the old driver is still in place after the failure"
else
    fail "partial: the driver changed even though the transaction failed"
fi
if [[ -d "$APP_INSTALLED" ]]; then
    pass "partial: the app is installed even though the driver step failed"
else
    fail "partial: the app is missing"
fi

/bin/bash "$SRC_TX" --payload "$STAGE/driver" --manifest "$SRC_MANIFEST" \
    --dest "$HAL_PARTIAL/$DRIVER_NAME" --state "$STATE_PARTIAL" --owner "$OWNER" \
    --mode install >"$WORK/partial-rerun.log" 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "partial: rerunning reconciles the machine (exit 0)"
else
    fail "partial: the rerun exits $rc"
fi
if [[ "$(version_of "$HAL_PARTIAL/$DRIVER_NAME")" == "$WANT_VERSION" ]]; then
    pass "partial: the driver is now $WANT_VERSION"
else
    fail "partial: the driver is '$(version_of "$HAL_PARTIAL/$DRIVER_NAME")' after the rerun"
fi
if [[ "$(tree_digest "$APP_INSTALLED")" == "$APP_DIGEST" ]]; then
    pass "partial: the driver step left the app byte-identical"
else
    fail "partial: the driver step modified the app"
fi
if [[ ! -e "$STATE_PARTIAL/transaction.state" && ! -e "$STATE_PARTIAL/staging" && ! -e "$STATE_PARTIAL/backup" ]]; then
    pass "partial: no residue is left after the successful rerun"
else
    fail "partial: residue was left after the rerun"
fi

echo ""
echo "──────────────────────────────────────────────"
printf 'round-trip assertions: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
echo "the driver in $PKG installs; the HAL directory was never touched"
exit 0
