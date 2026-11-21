#!/bin/bash
#
# Verify the HAL driver that the installer package actually ships.
#
# Why this exists (Phase 3.4A)
# ----------------------------
# The driver users end up running is the copy inside
# InstallerPayload/driver, not the one in the app bundle -- postinstall copies it
# into /Library/Application Support/SoundBridge and the HAL loads it from
# /Library/Audio/Plug-Ins/HAL. A package can therefore be structurally fine while
# shipping a driver that is stale, single-architecture, or a different build from
# the app it arrived with.
#
# Two verdicts, deliberately separate
# -----------------------------------
#   PKG_DRIVER_STRUCTURE=STRUCTURAL_PASS
#       bundle, plist, Mach-O, both architectures, identifier, version and
#       byte-identical content with the app's driver all check out.
#
#   PKG_DRIVER_SIGNATURE=DEVELOPER_ID_SIGNATURE_VERIFIED
#   PKG_DRIVER_SIGNATURE=DEVELOPER_ID_SIGNATURE_NOT_VERIFIED
#       whether the extracted driver carries a Developer ID signature whose
#       TeamIdentifier and integrity verification hold. An ad-hoc or
#       linker-signed driver reports NOT_VERIFIED. Passing the structural half
#       says nothing about the signature half.
#
# --require-developer-id turns a NOT_VERIFIED into a failure, which is how a
# release job that does sign would gate on it.
#
# --require-unsigned is its mirror image, and the one this project uses: a
# Developer ID signature on the shipped driver makes the run fail, because
# SoundBridge 1.2.0 is published without any signing identity. An ad-hoc or
# linker-signed driver satisfies it -- that is the expected state.
#
# Usage
#   tools/verify_pkg_driver.sh --pkg build/p34/pkg/SoundBridge-1.1.1.pkg
#   tools/verify_pkg_driver.sh --pkg <pkg> --app build/p34/unsigned/SoundBridge.app
#   tools/verify_pkg_driver.sh --driver <path>/SoundBridgeDriver.driver
#   tools/verify_pkg_driver.sh --pkg <pkg> --require-developer-id
#   tools/verify_pkg_driver.sh --pkg <pkg> --require-unsigned
#
# Exit codes
#   0  STRUCTURAL_PASS (and, with --require-developer-id, signature verified)
#   1  a structural check failed
#   2  usage error
#   4  structure passed but --require-developer-id was not satisfied
#   5  structure passed but --require-unsigned found a Developer ID signature
#
set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

PKG=""
APP=""
DRIVER=""
EXPECT_VERSION=""
EXPECT_ID="com.soundbridge.driver"
EXPECT_TEAM=""
REQUIRE_DEV_ID=0
REQUIRE_UNSIGNED=0
KEEP_EXPANDED=0
WORK_DIR=""

usage() {
    sed -n '2,47p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pkg)                  PKG="$2"; shift 2 ;;
        --app)                  APP="$2"; shift 2 ;;
        --driver)               DRIVER="$2"; shift 2 ;;
        --expect-version)       EXPECT_VERSION="$2"; shift 2 ;;
        --expect-id)            EXPECT_ID="$2"; shift 2 ;;
        --expect-team)          EXPECT_TEAM="$2"; shift 2 ;;
        --require-developer-id) REQUIRE_DEV_ID=1; shift ;;
        --require-unsigned)     REQUIRE_UNSIGNED=1; shift ;;
        --keep-expanded)        KEEP_EXPANDED=1; shift ;;
        --work-dir)             WORK_DIR="$2"; shift 2 ;;
        -h|--help)              usage ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if [ -z "$PKG" ] && [ -z "$DRIVER" ]; then
    echo "error: pass --pkg <installer.pkg> or --driver <SoundBridgeDriver.driver>" >&2
    exit 2
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CHECKS=0
FAILS=0
SIG_FAILS=0

section() {
    echo ""
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
}

pass() { CHECKS=$((CHECKS + 1)); echo -e "  ${GREEN}PASS${NC}  $1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); echo -e "  ${RED}FAIL${NC}  $1"; }

# Signature findings are counted apart from structure. The project ships an
# unsigned package by design; a driver without a valid signature is a fact to
# report, not a structural defect, and mixing the two would either hide a real
# structural break or make every current build look broken.
sigpass() { CHECKS=$((CHECKS + 1)); echo -e "  ${GREEN}SIGPASS${NC}  $1"; }
sigfail() { CHECKS=$((CHECKS + 1)); SIG_FAILS=$((SIG_FAILS + 1)); echo -e "  ${YELLOW}SIGFAIL${NC}  $1"; }
note() { echo -e "  ${YELLOW}NOTE${NC}  $1"; }
info() { echo "  INFO  $1"; }

# Recursive content hash: identical file lists and identical bytes give the same
# value, whatever the path prefix is.
tree_hash() {
    local dir="$1"
    ( cd "$dir" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 ) \
        | shasum -a 256 | awk '{print $1}'
}

plist_read() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

# --- locate the driver -------------------------------------------------------
CLEANUP_DIR=""
cleanup() {
    if [ -n "$CLEANUP_DIR" ] && [ "$KEEP_EXPANDED" = "0" ]; then
        rm -rf "$CLEANUP_DIR"
    fi
}
trap cleanup EXIT

section "Package Driver Verification"

if [ -n "$PKG" ]; then
    if [ ! -f "$PKG" ]; then
        echo -e "${RED}ERROR: package not found: $PKG${NC}" >&2
        exit 1
    fi
    PKG="$( cd "$( dirname "$PKG" )" && pwd -P )/$( basename "$PKG" )"
    info "package: $PKG"

    if [ -z "$WORK_DIR" ]; then
        WORK_DIR="$PROJECT_ROOT/build/p34/extracted/verify-driver.$$"
        CLEANUP_DIR="$WORK_DIR"
    fi
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    if ! pkgutil --expand-full "$PKG" "$WORK_DIR/expanded" >/dev/null 2>&1; then
        echo -e "${RED}ERROR: pkgutil could not expand $PKG${NC}" >&2
        exit 1
    fi
    DRIVER="$WORK_DIR/expanded/SoundBridge.pkg/Payload/Library/Application Support/SoundBridge/InstallerPayload/driver/SoundBridgeDriver.driver"
fi

info "driver:  $DRIVER"

# --- 1. bundle ---------------------------------------------------------------
section "1. Driver bundle"

if [ -d "$DRIVER" ]; then
    pass "driver bundle exists"
    BUNDLE_DIR="$DRIVER"
else
    # A fixture may point straight at the Mach-O directory's parent.
    fail "driver bundle missing at ${DRIVER#$PROJECT_ROOT/}"
    echo ""
    echo "PKG_DRIVER_STRUCTURE=STRUCTURAL_FAIL"
    echo "PKG_DRIVER_SIGNATURE=DEVELOPER_ID_SIGNATURE_NOT_VERIFIED"
    exit 1
fi

PLIST="$BUNDLE_DIR/Contents/Info.plist"
if [ -f "$PLIST" ]; then
    pass "Contents/Info.plist exists"
    PLIST_OK=1
else
    fail "Contents/Info.plist missing"
    PLIST_OK=0
fi

BUNDLE_ID=""
BUNDLE_VERSION=""
BUNDLE_EXEC=""
if [ "$PLIST_OK" = "1" ]; then
    BUNDLE_ID="$(plist_read "$PLIST" CFBundleIdentifier)"
    BUNDLE_VERSION="$(plist_read "$PLIST" CFBundleShortVersionString)"
    BUNDLE_EXEC="$(plist_read "$PLIST" CFBundleExecutable)"
    if [ -n "$BUNDLE_ID" ] && [ -n "$BUNDLE_VERSION" ] && [ -n "$BUNDLE_EXEC" ]; then
        pass "plist declares identifier, version and executable"
    else
        fail "plist is missing CFBundleIdentifier, CFBundleShortVersionString or CFBundleExecutable"
    fi
fi

# --- 2. Mach-O ---------------------------------------------------------------
section "2. Mach-O"

MACHO="$BUNDLE_DIR/Contents/MacOS/${BUNDLE_EXEC:-SoundBridgeDriver}"
if [ -f "$MACHO" ]; then
    pass "Mach-O exists at Contents/MacOS/${BUNDLE_EXEC:-SoundBridgeDriver}"
    MACHO_OK=1
else
    fail "Mach-O missing at Contents/MacOS/${BUNDLE_EXEC:-SoundBridgeDriver}"
    MACHO_OK=0
fi

ARCHS=""
if [ "$MACHO_OK" = "1" ]; then
    ARCHS="$(lipo -archs "$MACHO" 2>/dev/null || true)"
    info "architectures: ${ARCHS:-unknown}"
    case " $ARCHS " in
        *" arm64 "*) pass "contains arm64" ;;
        *) fail "arm64 missing (found '${ARCHS}')" ;;
    esac
    case " $ARCHS " in
        *" x86_64 "*) pass "contains x86_64" ;;
        *) fail "x86_64 missing (found '${ARCHS}')" ;;
    esac
fi

# --- 3. identity and version -------------------------------------------------
section "3. Identity and version"

if [ -n "$BUNDLE_ID" ]; then
    if [ "$BUNDLE_ID" = "$EXPECT_ID" ]; then
        pass "CFBundleIdentifier is $EXPECT_ID"
    else
        fail "CFBundleIdentifier is '$BUNDLE_ID', expected '$EXPECT_ID'"
    fi
fi

# Expected version, in order of authority: --expect-version, the driver inside
# the app bundle, the app's own CFBundleShortVersionString.
if [ -z "$EXPECT_VERSION" ] && [ -n "$APP" ] && [ -d "$APP/Contents/Resources/SoundBridgeDriver.driver" ]; then
    EXPECT_VERSION="$(plist_read "$APP/Contents/Resources/SoundBridgeDriver.driver/Contents/Info.plist" CFBundleShortVersionString)"
fi
if [ -z "$EXPECT_VERSION" ] && [ -n "$APP" ] && [ -f "$APP/Contents/Info.plist" ]; then
    EXPECT_VERSION="$(plist_read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
fi
if [ -z "$EXPECT_VERSION" ]; then
    note "no expected version given and no --app to read it from; the driver's own value is reported only"
    info "CFBundleShortVersionString: ${BUNDLE_VERSION:-missing}"
else
    info "expected version: $EXPECT_VERSION"
    if [ "$BUNDLE_VERSION" = "$EXPECT_VERSION" ]; then
        pass "driver version is $BUNDLE_VERSION"
    else
        fail "driver version is '${BUNDLE_VERSION}', expected '$EXPECT_VERSION'"
    fi
fi

# --- 4. signature ------------------------------------------------------------
section "4. Code signature"

TEAM=""
FLAGS=""
CDFMT=""
AUTHORITY=""
STRICT_RC=1
if [ "$MACHO_OK" = "1" ]; then
    SIG_OUT="$(codesign -dv --verbose=2 "$BUNDLE_DIR" 2>&1 || true)"
    TEAM="$(printf '%s\n' "$SIG_OUT" | sed -n 's/^TeamIdentifier=//p' | head -1)"
    FLAGS="$(printf '%s\n' "$SIG_OUT" | sed -n 's/.*flags=\(0x[0-9a-f]*([^)]*)\).*/\1/p' | head -1)"
    CDFMT="$(printf '%s\n' "$SIG_OUT" | sed -n 's/^CodeDirectory v=\([0-9]*\).*/\1/p' | head -1)"
    AUTHORITY="$(printf '%s\n' "$SIG_OUT" | sed -n 's/^Authority=//p' | head -1)"
    info "flags: ${FLAGS:-none}"
    info "CodeDirectory: ${CDFMT:-none}"
    info "TeamIdentifier: ${TEAM:-not set}"
    info "Authority: ${AUTHORITY:-none}"

    STRICT_RC=0
    codesign --verify --strict "$BUNDLE_DIR" >/dev/null 2>&1 || STRICT_RC=$?
    if [ "$STRICT_RC" = "0" ]; then
        sigpass "codesign --verify --strict"
    else
        sigfail "codesign --verify --strict (exit $STRICT_RC)"
    fi
fi

SIGNATURE_VERDICT="DEVELOPER_ID_SIGNATURE_NOT_VERIFIED"
if [ -n "$AUTHORITY" ] && printf '%s' "$AUTHORITY" | grep -q "Developer ID Application"; then
    if [ -n "$EXPECT_TEAM" ] && [ "$TEAM" != "$EXPECT_TEAM" ]; then
        sigfail "TeamIdentifier is '$TEAM', expected '$EXPECT_TEAM'"
    elif [ "$STRICT_RC" != "0" ]; then
        sigfail "Developer ID signature present but integrity verification failed"
    else
        if [ -n "$EXPECT_TEAM" ] || [ -n "$TEAM" ]; then
            sigpass "Developer ID Application signature, TeamIdentifier $TEAM"
        fi
        SIGNATURE_VERDICT="DEVELOPER_ID_SIGNATURE_VERIFIED"
    fi
else
    note "driver is not signed with a Developer ID Application identity"
    if printf '%s' "$FLAGS" | grep -q "linker-signed"; then
        note "signature is the linker's ad-hoc stamp, which codesign does not accept as a signature"
    fi
fi

# --- 5. content agreement with the app ---------------------------------------
section "5. Content agreement with the app"

if [ -z "$APP" ]; then
    note "no --app given; the package driver was not compared with an app copy"
elif [ ! -d "$APP/Contents/Resources/SoundBridgeDriver.driver" ]; then
    fail "app bundle has no Contents/Resources/SoundBridgeDriver.driver"
else
    APP_DRIVER="$APP/Contents/Resources/SoundBridgeDriver.driver"
    PKG_HASH="$(tree_hash "$BUNDLE_DIR")"
    APP_HASH="$(tree_hash "$APP_DRIVER")"
    info "package driver tree: $PKG_HASH"
    info "app driver tree:     $APP_HASH"
    if [ "$PKG_HASH" = "$APP_HASH" ]; then
        pass "package driver is byte-identical to the app's driver"
    else
        fail "package driver differs from the app's driver"
        diff <( cd "$BUNDLE_DIR" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 ) \
             <( cd "$APP_DRIVER" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 ) 2>/dev/null | head -20
    fi
fi

# --- verdict -----------------------------------------------------------------
section "Verdict"

echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "PKG_DRIVER_STRUCTURE=STRUCTURAL_PASS"
    STRUCTURE_RC=0
else
    echo "PKG_DRIVER_STRUCTURE=STRUCTURAL_FAIL"
    STRUCTURE_RC=1
fi
echo "PKG_DRIVER_SIGNATURE=$SIGNATURE_VERDICT"
echo "PKG_DRIVER_CHECKS=$CHECKS"
echo "PKG_DRIVER_FAILURES=$FAILS"
echo "PKG_DRIVER_SIGNATURE_FAILURES=$SIG_FAILS"
if [ "$MACHO_OK" = "1" ]; then
    echo "PKG_DRIVER_ARCHS=$ARCHS"
fi
echo "PKG_DRIVER_VERSION=${BUNDLE_VERSION:-unknown}"
echo "PKG_DRIVER_ID=${BUNDLE_ID:-unknown}"
echo "PKG_DRIVER_TEAM=${TEAM:-not set}"
if [ "$REQUIRE_DEV_ID" = "1" ]; then
    echo "PKG_DRIVER_REQUIREMENT=developer-id"
elif [ "$REQUIRE_UNSIGNED" = "1" ]; then
    echo "PKG_DRIVER_REQUIREMENT=unsigned"
else
    echo "PKG_DRIVER_REQUIREMENT=none"
fi
echo ""
echo "STRUCTURAL_PASS covers structure, architecture and content only."
if [ "$SIGNATURE_VERDICT" = "DEVELOPER_ID_SIGNATURE_VERIFIED" ]; then
    echo "The driver also carries a verified Developer ID Application signature."
else
    echo "It does NOT mean the driver is signed with Developer ID; see PKG_DRIVER_SIGNATURE."
fi

if [ "$STRUCTURE_RC" != "0" ]; then
    exit 1
fi
if [ "$REQUIRE_DEV_ID" = "1" ] && [ "$SIGNATURE_VERDICT" != "DEVELOPER_ID_SIGNATURE_VERIFIED" ]; then
    echo ""
    echo "FAIL: --require-developer-id was requested and the driver is not Developer ID signed"
    exit 4
fi
if [ "$REQUIRE_UNSIGNED" = "1" ] && [ "$SIGNATURE_VERDICT" = "DEVELOPER_ID_SIGNATURE_VERIFIED" ]; then
    echo ""
    echo "FAIL: --require-unsigned was requested and the driver carries a Developer ID signature"
    exit 5
fi
exit 0
