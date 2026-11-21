#!/bin/bash
#
# Assert that a built app bundle is UNSIGNED.
#
# This replaces the old "verify_signatures.sh" that required every component to
# carry a code signature. SoundBridge 1.2.0 ships completely unsigned, so the
# check is inverted: it passes only when nothing in the bundle was signed by this
# project.
#
# What is asserted
# ----------------
#   1. the bundle itself is not sealed -- `codesign --verify --strict` refuses it
#      and there is no Contents/_CodeSignature,
#   2. no Mach-O inside carries an Authority= line or a TeamIdentifier (that is
#      what a Developer ID signature would leave behind),
#   3. Info.plist declares no SUPublicEDKey (auto-update stays disabled),
#   4. Gatekeeper refuses the bundle -- an "accepted" verdict would mean something
#      signed or notarized it, which contradicts the release policy.
#
# What is reported, not failed
# ----------------------------
#   * The ad-hoc CodeDirectory ld64 writes into every Mach-O
#     (`flags=0x20002(adhoc,linker-signed)`). Apple silicon will not load a
#     binary without it, it carries no TeamIdentifier and no Authority, and it is
#     produced by the linker rather than by any step in this repository.
#   * Sealed third-party bundles. Sparkle.framework arrives from SwiftPM already
#     signed by its vendor with an ad-hoc signature and sealed resources; the
#     release copies it verbatim because SoundBridgeApp links it through @rpath.
#     It has no Authority and no TeamIdentifier, and it is listed by path so the
#     exception is visible instead of assumed.
#
# Usage
#   ./tools/verify_signatures.sh [path/to/SoundBridge.app]
#
# Exit codes
#   0  every unsigned assertion holds
#   1  an assertion failed (the bundle is signed, sealed or has a public key)
#   2  usage error / bundle missing
#
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_BUNDLE="${1:-$PROJECT_ROOT/dist/SoundBridge.app}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error()   { echo -e "${RED}ERROR: $1${NC}" >&2; }
ok()      { CHECKS=$((CHECKS + 1)); echo -e "  ${GREEN}PASS${NC}  $1"; }
bad()     { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); echo -e "  ${RED}FAIL${NC}  $1"; }
note()    { echo -e "  ${YELLOW}NOTE${NC}  $1"; }
info()    { echo "  INFO  $1"; }
section() {
    echo ""
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
}

CHECKS=0
FAILED=0
BINARIES=0
LINKER_SIGNED=0
WITH_AUTHORITY=0
SEALED_VENDOR=""

if [ ! -d "$APP_BUNDLE" ]; then
    error "app bundle not found: $APP_BUNDLE"
    echo "Usage: $0 [path/to/SoundBridge.app]" >&2
    exit 2
fi
if [ ! -f "$APP_BUNDLE/Contents/Info.plist" ] || [ ! -d "$APP_BUNDLE/Contents/MacOS" ]; then
    error "$APP_BUNDLE is not an app bundle (Contents/Info.plist and Contents/MacOS are required)"
    exit 2
fi

section "Unsigned app assertion"
echo "Bundle: $APP_BUNDLE"

# --- 1. the bundle is not sealed --------------------------------------------
section "1. Bundle seal"

VERIFY_RC=0
codesign --verify --strict "$APP_BUNDLE" >/dev/null 2>&1 || VERIFY_RC=$?
if [ "$VERIFY_RC" -eq 0 ]; then
    bad "the bundle passes 'codesign --verify --strict', so it is signed and sealed"
else
    ok "the bundle is not sealed ('codesign --verify --strict' exits $VERIFY_RC)"
fi

if [ -d "$APP_BUNDLE/Contents/_CodeSignature" ]; then
    bad "the outer app bundle has Contents/_CodeSignature, so it is sealed"
else
    ok "the outer app bundle has no Contents/_CodeSignature"
fi

# Seals are classified by their origin, not by the fact that they exist.
#   * Sparkle.framework arrives from SwiftPM already signed by its vendor: an
#     ad-hoc CodeDirectory plus sealed resources. The release copies it verbatim
#     because SoundBridgeApp links it through @rpath. Those seals carry no
#     Authority and no TeamIdentifier; they are reported by path so the exception
#     is visible instead of assumed.
#   * Any _CodeSignature anywhere else was produced by something in this
#     repository -- the old ad-hoc signing step, a stray `codesign` run, a build
#     that still seals the driver. An unsigned release must not carry one, so it
#     fails here instead of being described as a vendor exception.
SEAL_DIRS="$(find "$APP_BUNDLE" -type d -name '_CodeSignature' 2>/dev/null | sort)"
VENDOR_SEALS=""
PROJECT_SEALS=""
if [ -n "$SEAL_DIRS" ]; then
    while IFS= read -r d; do
        case "$d" in
            */Sparkle.framework/*) VENDOR_SEALS="${VENDOR_SEALS}${d}"$'\n' ;;
            *)                     PROJECT_SEALS="${PROJECT_SEALS}${d}"$'\n' ;;
        esac
    done <<< "$SEAL_DIRS"
fi

if [ -z "$PROJECT_SEALS" ] && [ -z "$VENDOR_SEALS" ]; then
    ok "no nested bundle carries a seal either"
fi

while IFS= read -r d; do
    [ -n "$d" ] || continue
    note "sparkle vendor seal: ${d#"$APP_BUNDLE"/}"
done <<< "$VENDOR_SEALS"

while IFS= read -r d; do
    [ -n "$d" ] || continue
    bad "seal produced by this repository: ${d#"$APP_BUNDLE"/}"
done <<< "$PROJECT_SEALS"

# --- 2. no Mach-O was signed by an identity ---------------------------------
section "2. No signing identity in any binary"

while IFS= read -r -d '' f; do
    file "$f" 2>/dev/null | grep -q "Mach-O" || continue
    rel="${f#"$APP_BUNDLE"/}"
    BINARIES=$((BINARIES + 1))
    SIG="$(codesign -dv --verbose=2 "$f" 2>&1 || true)"

    if printf '%s' "$SIG" | grep -q '^Authority='; then
        WITH_AUTHORITY=$((WITH_AUTHORITY + 1))
        bad "$rel carries an Authority= line: $(printf '%s' "$SIG" | sed -n 's/^Authority=//p' | head -1)"
    fi

    TEAM="$(printf '%s' "$SIG" | sed -n 's/^TeamIdentifier=//p' | head -1)"
    if [ -n "$TEAM" ] && [ "$TEAM" != "not set" ]; then
        bad "$rel has TeamIdentifier=$TEAM"
    fi

    if printf '%s' "$SIG" | grep -q 'linker-signed'; then
        LINKER_SIGNED=$((LINKER_SIGNED + 1))
    elif printf '%s' "$SIG" | grep -q 'code object is not signed at all'; then
        note "$rel has no CodeDirectory at all"
    fi
done < <(find "$APP_BUNDLE" -type f -print0 2>/dev/null | sort -z)

if [ "$BINARIES" -eq 0 ]; then
    bad "no Mach-O binaries found inside $APP_BUNDLE"
else
    info "Mach-O binaries inspected: $BINARIES"
    info "carrying the linker's ad-hoc stamp: $LINKER_SIGNED"
    info "carrying an Authority= line: $WITH_AUTHORITY"
    if [ "$WITH_AUTHORITY" -eq 0 ]; then
        ok "no binary in the bundle carries a certificate identity"
    fi
fi

# --- 3. the update channel stays off ----------------------------------------
section "3. Update channel"

PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$PUBKEY" ]; then
    ok "Info.plist has no SUPublicEDKey, so the updater never initialises"
else
    bad "Info.plist carries SUPublicEDKey='$PUBKEY'; an unsigned release must not enable Sparkle"
fi

# A second, independent switch: automatic checks must not be announced either.
# An empty key alone would still leave a user-visible "check for updates" promise.
AUTOCHECKS="$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
case "$AUTOCHECKS" in
    true|TRUE|YES|1)
        bad "Info.plist sets SUEnableAutomaticChecks=$AUTOCHECKS; this release ships no update feed" ;;
    *)
        ok "Info.plist does not enable automatic update checks (SUEnableAutomaticChecks='${AUTOCHECKS}')" ;;
esac

FEEDURL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$FEEDURL" ]; then
    note "SUFeedURL is present ($FEEDURL). It is not an update channel: it is the"
    note "  source of the GitHub release link in the driver notice, and Sparkle is"
    note "  held off by VersionManager.updateChannelAvailable == false as well as by"
    note "  the empty key."
else
    note "SUFeedURL is absent; the driver notice will offer no release link."
fi

# --- 4. Gatekeeper refuses the bundle ---------------------------------------
section "4. Gatekeeper"

ASSESS_OUT="$(spctl --assess --type execute --verbose=4 "$APP_BUNDLE" 2>&1)"
ASSESS_RC=$?
if [ "$ASSESS_RC" -eq 0 ]; then
    bad "Gatekeeper accepted the bundle; an unsigned build must be rejected (someone signed or notarized it)"
else
    ok "Gatekeeper rejects the bundle (exit $ASSESS_RC), which is the expected unsigned verdict"
fi
printf '%s\n' "$ASSESS_OUT" | sed 's/^/  INFO  /'

# --- verdict ----------------------------------------------------------------
section "Verdict"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "UNSIGNED_APP=PASS"
else
    echo "UNSIGNED_APP=FAIL"
fi
echo "UNSIGNED_APP_CHECKS=$CHECKS"
echo "UNSIGNED_APP_FAILURES=$FAILED"
echo "UNSIGNED_APP_BINARIES=$BINARIES"
echo "UNSIGNED_APP_LINKER_SIGNED=$LINKER_SIGNED"
echo "UNSIGNED_APP_WITH_AUTHORITY=$WITH_AUTHORITY"
count_lines() {
    printf '%s' "$1" | grep -c . || true
}
echo "UNSIGNED_APP_SEALED_VENDOR_BUNDLES=$(count_lines "$VENDOR_SEALS")"
echo "UNSIGNED_APP_SEALED_PROJECT_BUNDLES=$(count_lines "$PROJECT_SEALS")"
echo ""
echo "Three kinds of signature metadata are told apart above:"
echo "  * LINKER_SIGNED binaries carry the ad-hoc CodeDirectory ld64 writes, not a"
echo "    signature this project produced: no Authority, no TeamIdentifier, no seal."
echo "  * SEALED_VENDOR_BUNDLES are third-party artifacts copied verbatim from"
echo "    SwiftPM (Sparkle.framework and its nested bundles). They carry the"
echo "    vendor's own ad-hoc seal and are reported by path, never claimed by us."
echo "  * SEALED_PROJECT_BUNDLES would be anything else carrying _CodeSignature."
echo "    That is a seal this repository produced, it fails section 1, and the"
echo "    count must stay 0 for an unsigned release."
echo "No Developer ID, no Authority and no TeamIdentifier may appear anywhere."

if [ "$FAILED" -ne 0 ]; then
    echo ""
    error "$FAILED unsigned assertion(s) failed"
    exit 1
fi

echo ""
echo "PASS  $APP_BUNDLE is unsigned"
exit 0
