#!/bin/bash
#
# Assert that an entire SoundBridge release set is UNSIGNED.
#
# The release policy for 1.2.0 is "no code signing at all": no Developer ID, no
# ad-hoc signature, no PKG signature, no notarization, no stapling and no Sparkle
# appcast. This script is the gate that says so out loud, on the finished files
# rather than on the sources they came from.
#
# It checks, in this order:
#   1. the app bundle  -- delegated to tools/verify_signatures.sh (no seal, no
#      Authority, no TeamIdentifier, empty SUPublicEDKey, Gatekeeper refuses it),
#   2. the installer package -- `pkgutil --check-signature` reports "no
#      signature" and `spctl` refuses it,
#   3. the disk image -- `codesign` reports "not signed at all" and `spctl`
#      refuses it,
#   4. the absence of a Sparkle feed -- no appcast.xml next to the artifacts.
#
# What a PASS does NOT mean
# -------------------------
#   * it says nothing about whether macOS will load the HAL driver (that needs a
#     real install on a real machine; see docs/risks/Known-Limitations.md),
#   * it says nothing about Gatekeeper being satisfied -- the opposite is the
#     expected verdict and is asserted as such,
#   * it does not replace verify_installer_pkg.sh / verify_pkg_contents.sh /
#     verify_pkg_driver.sh, which check structure, payload and consistency.
#
# Usage
#   ./tools/verify_unsigned_release.sh --app dist/SoundBridge.app \
#       --pkg dist/SoundBridge-1.2.0.pkg --dmg dist/SoundBridge-1.2.0.dmg
#
#   All three artifacts are REQUIRED. --app defaults to dist/SoundBridge.app and
#   --pkg/--dmg default to SoundBridge-<VERSION>.{pkg,dmg} in the app's
#   directory, but a default that does not exist is a failure, not a skip: an
#   absent package used to be reported as NOT_PRESENT and still passed, which
#   made "the package is missing" indistinguishable from "the package is
#   unsigned". A name given with --pkg/--dmg/--app is never replaced by a
#   default, and a name given that does not exist fails with an explicit
#   message saying so.
#
# Exit codes
#   0  the app, the package and the image all exist and are unsigned, and no
#      appcast was found
#   1  an unsigned assertion failed, or an artifact is missing
#   2  usage error, or the app bundle given/defaulted to does not exist
#
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

APP_BUNDLE=""
PKG=""
DMG=""
DIST=""
# Which artifacts were named on the command line. A name that was given and does
# not exist is a different failure from a default that does not exist: the first
# means the caller pointed at the wrong file (a broken workflow, a moved build,
# a typo in a version), and it must never be confused with "there is no package
# to check". Both are failures -- see the checks below.
APP_EXPLICIT=0
PKG_EXPLICIT=0
DMG_EXPLICIT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP_BUNDLE="$2"; APP_EXPLICIT=1; shift 2 ;;
        --pkg) PKG="$2"; PKG_EXPLICIT=1; shift 2 ;;
        --dmg) DMG="$2"; DMG_EXPLICIT=1; shift 2 ;;
        --dist) DIST="$2"; shift 2 ;;
        -h|--help)
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

APP_BUNDLE="${APP_BUNDLE:-$PROJECT_ROOT/dist/SoundBridge.app}"
if [ -z "$DIST" ]; then
    DIST="$(dirname "$APP_BUNDLE")"
fi
VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
PKG="${PKG:-$DIST/SoundBridge-$VERSION.pkg}"
DMG="${DMG:-$DIST/SoundBridge-$VERSION.dmg}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { CHECKS=$((CHECKS + 1)); echo -e "  ${GREEN}PASS${NC}  $1"; }
bad()  { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); echo -e "  ${RED}FAIL${NC}  $1"; }
note() { echo -e "  ${YELLOW}NOTE${NC}  $1"; }
info() { echo "  INFO  $1"; }
section() {
    echo ""
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
}

CHECKS=0
FAILED=0
APP_VERDICT="NOT_CHECKED"
PKG_VERDICT="NOT_CHECKED"
DMG_VERDICT="NOT_CHECKED"
APPCAST_VERDICT="NOT_CHECKED"

if [ ! -d "$APP_BUNDLE" ]; then
    if [ "$APP_EXPLICIT" -eq 1 ]; then
        echo "error: the app bundle named on the command line does not exist: $APP_BUNDLE" >&2
        echo "       Nothing falls back to dist/SoundBridge.app: a gate that silently" >&2
        echo "       checks a different bundle is worse than no gate." >&2
    else
        echo "error: app bundle not found: $APP_BUNDLE" >&2
        echo "       Run 'make bundle' first, or pass --app <the bundle this run produced>." >&2
    fi
    echo "usage: $0 --app <SoundBridge.app> --pkg <pkg> --dmg <dmg>" >&2
    exit 2
fi

echo "Unsigned release assertion"
echo "  app: $APP_BUNDLE"
echo "  pkg: $PKG"
echo "  dmg: $DMG"

# --- 1. app ------------------------------------------------------------------
section "1. App bundle"

APP_LOG="$(mktemp "${TMPDIR:-/tmp}/soundbridge-unsigned-app.XXXXXX")"
trap 'rm -f "$APP_LOG"' EXIT

if "$SCRIPT_DIR/verify_signatures.sh" "$APP_BUNDLE" > "$APP_LOG" 2>&1; then
    APP_VERDICT="UNSIGNED"
    ok "the app bundle is unsigned (see tools/verify_signatures.sh for the detail)"
else
    APP_VERDICT="SIGNED_OR_FAILED"
    bad "the app bundle is not unsigned"
    sed -n '/Verdict/,$p' "$APP_LOG" | sed 's/^/        /'
fi
grep -E '^UNSIGNED_APP_(BINARIES|LINKER_SIGNED|WITH_AUTHORITY|SEALED_VENDOR_BUNDLES)=' "$APP_LOG" \
    | sed 's/^/  INFO  /'

# --- 2. installer package ----------------------------------------------------
section "2. Installer package"

if [ ! -f "$PKG" ]; then
    if [ "$PKG_EXPLICIT" -eq 1 ]; then
        bad "the package named on the command line does not exist: $PKG"
    else
        bad "no package at $PKG (no --pkg given; looked for version $VERSION)"
    fi
    PKG_VERDICT="MISSING"
else
    SIG_OUT="$(pkgutil --check-signature "$PKG" 2>&1)"
    SIG_RC=$?
    printf '%s\n' "$SIG_OUT" | sed 's/^/  INFO  /'
    if printf '%s' "$SIG_OUT" | grep -q "Status: no signature"; then
        ok "pkgutil reports no signature on the package"
        PKG_VERDICT="UNSIGNED"
    else
        bad "the package carries a signature (pkgutil exit $SIG_RC)"
        PKG_VERDICT="SIGNED"
    fi

    SPCTL_OUT="$(spctl --assess --type install --verbose=4 "$PKG" 2>&1)"
    SPCTL_RC=$?
    if [ "$SPCTL_RC" -eq 0 ]; then
        bad "Gatekeeper accepted the package; an unsigned PKG must be refused"
        PKG_VERDICT="ACCEPTED_BY_GATEKEEPER"
    else
        ok "Gatekeeper refuses the package (exit $SPCTL_RC), as expected"
        printf '%s\n' "$SPCTL_OUT" | sed 's/^/  INFO  /'
    fi
fi

# --- 3. disk image -----------------------------------------------------------
section "3. Disk image"

if [ ! -f "$DMG" ]; then
    if [ "$DMG_EXPLICIT" -eq 1 ]; then
        bad "the disk image named on the command line does not exist: $DMG"
    else
        bad "no disk image at $DMG (no --dmg given; looked for version $VERSION)"
    fi
    DMG_VERDICT="MISSING"
else
    CS_OUT="$(codesign -dv "$DMG" 2>&1)"
    CS_RC=$?
    printf '%s\n' "$CS_OUT" | sed 's/^/  INFO  /'
    if printf '%s' "$CS_OUT" | grep -q "not signed at all"; then
        ok "codesign finds no signature on the disk image"
        DMG_VERDICT="UNSIGNED"
    elif [ "$CS_RC" -ne 0 ]; then
        ok "codesign refuses the disk image (exit $CS_RC), so it carries no usable signature"
        DMG_VERDICT="UNSIGNED"
    else
        bad "the disk image carries a signature"
        DMG_VERDICT="SIGNED"
    fi

    DMG_SPCTL_OUT="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1)"
    DMG_SPCTL_RC=$?
    if [ "$DMG_SPCTL_RC" -eq 0 ]; then
        bad "Gatekeeper accepted the disk image; an unsigned DMG must be refused"
        DMG_VERDICT="ACCEPTED_BY_GATEKEEPER"
    else
        ok "Gatekeeper refuses the disk image (exit $DMG_SPCTL_RC), as expected"
        printf '%s\n' "$DMG_SPCTL_OUT" | sed 's/^/  INFO  /'
    fi
fi

# --- 4. no Sparkle feed ------------------------------------------------------
section "4. No Sparkle feed"

if [ -d "$DIST/appcast" ]; then
    bad "$DIST/appcast exists; an unsigned release publishes no appcast"
    APPCAST_VERDICT="PRESENT"
elif [ -n "$(find "$DIST" -maxdepth 2 -name 'appcast.xml' -print -quit 2>/dev/null)" ]; then
    bad "an appcast.xml was found under $DIST"
    APPCAST_VERDICT="PRESENT"
else
    ok "no appcast.xml under $DIST"
    APPCAST_VERDICT="ABSENT"
fi

# --- verdict -----------------------------------------------------------------
section "Verdict"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "UNSIGNED_RELEASE=PASS"
else
    echo "UNSIGNED_RELEASE=FAIL"
fi
echo "UNSIGNED_APP=$APP_VERDICT"
echo "UNSIGNED_PKG=$PKG_VERDICT"
echo "UNSIGNED_DMG=$DMG_VERDICT"
echo "UNSIGNED_APPCAST=$APPCAST_VERDICT"
echo "UNSIGNED_RELEASE_CHECKS=$CHECKS"
echo "UNSIGNED_RELEASE_FAILURES=$FAILED"
echo ""
echo "A PASS means the app, the package and the image were all present, none of"
echo "them was signed, and no update feed was published. A missing artifact fails"
echo "this gate; it is not reported as an unchecked half."
echo "It does not mean Gatekeeper is satisfied, and it says nothing about whether"
echo "macOS will load the HAL driver: that requires a real install on a real Mac."

if [ "$FAILED" -ne 0 ]; then
    echo ""
    exit 1
fi
exit 0
