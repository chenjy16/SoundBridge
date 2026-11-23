#!/bin/bash
# Verify that every version source in this checkout agrees on one number.
#
# Usage:
#   tools/verify_version_consistency.sh [--expect 1.2.0]
#                                       [--app build/release-1.2.0/unsigned/SoundBridge.app]
#                                       [--pkg build/release-1.2.0/pkg/SoundBridge-1.2.0.pkg]
#
# Without --expect the repository's VERSION file is the expected value: it is the
# source `make build` now reads, so it is the number the artifacts should carry.
#
# This is a read-only check. It never builds, signs or installs anything, and the
# --pkg branch uses `pkgutil --expand` into a temporary directory.
#
# Why it exists: the version reaches the user through eight different files. A
# release where the app says 1.2.0 and the installer gate says 1.1.1 installs
# nothing on a machine that already has a driver, and the failure shows up as a
# refused install rather than a build error.
#
# Exit codes:
#   0  every checked source agrees
#   1  at least one source disagrees or is missing
#   2  usage error

set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; NC=""
fi

EXPECT=""
APP_BUNDLE=""
PKG_PATH=""
WORK_DIR=""
KEEP_EXPANDED=0

usage() {
    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --expect)   [ "$#" -ge 2 ] || { echo "ERROR: --expect needs a value" >&2; exit 2; }
                    EXPECT="$2"; shift 2 ;;
        --app)      [ "$#" -ge 2 ] || { echo "ERROR: --app needs a value" >&2; exit 2; }
                    APP_BUNDLE="$2"; shift 2 ;;
        --pkg)      [ "$#" -ge 2 ] || { echo "ERROR: --pkg needs a value" >&2; exit 2; }
                    PKG_PATH="$2"; shift 2 ;;
        --work-dir) [ "$#" -ge 2 ] || { echo "ERROR: --work-dir needs a value" >&2; exit 2; }
                    WORK_DIR="$2"; shift 2 ;;
        --keep-expanded) KEEP_EXPANDED=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "ERROR: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

CHECKS=0
FAILS=0

pass() { CHECKS=$((CHECKS + 1)); printf '  %sPASS%s  %s\n' "$GREEN" "$NC" "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf '  %sFAIL%s  %s\n' "$RED" "$NC" "$1"; }
note() { printf '  %sNOTE%s  %s\n' "$YELLOW" "$NC" "$1"; }

plist_str() {
    # plist_str <file> <key>  -> prints the value or nothing
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

# Compare one source against the expected version.
#   expect_version <label> <actual> [<extra note>]
expect_version() {
    local label="$1" actual="$2" extra="${3:-}"
    if [ -z "$actual" ]; then
        fail "$label is missing or unreadable (expected $EXPECT)"
    elif [ "$actual" = "$EXPECT" ]; then
        pass "$label = $actual"
    else
        fail "$label = $actual (expected $EXPECT)${extra:+, $extra}"
    fi
}

# ── Expected version ─────────────────────────────────────────────────────────
echo "Version consistency check"
echo "========================="

VERSION_FILE="$PROJECT_ROOT/VERSION"
if [ -z "$EXPECT" ]; then
    if [ ! -f "$VERSION_FILE" ]; then
        echo "ERROR: no --expect given and $VERSION_FILE does not exist." >&2
        echo "The VERSION file is the number 'make build' writes; without it there is nothing to check against." >&2
        exit 2
    fi
    EXPECT="$( tr -d '[:space:]' < "$VERSION_FILE" )"
fi

if ! printf '%s' "$EXPECT" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
    echo "ERROR: expected version '$EXPECT' is not dot-separated digits." >&2
    exit 2
fi

echo "Expected: $EXPECT"
echo ""

# ── Repository sources ───────────────────────────────────────────────────────
echo "Repository version sources"

if [ -f "$VERSION_FILE" ]; then
    expect_version "VERSION (repository file)" \
        "$( tr -d '[:space:]' < "$VERSION_FILE" )"
else
    fail "VERSION (repository file) does not exist"
fi

APP_PLIST="$PROJECT_ROOT/apps/mac/SoundBridgeApp/Info.plist"
if [ -f "$APP_PLIST" ]; then
    expect_version "apps/mac/SoundBridgeApp/Info.plist CFBundleShortVersionString" \
        "$( plist_str "$APP_PLIST" CFBundleShortVersionString )"
    expect_version "apps/mac/SoundBridgeApp/Info.plist CFBundleVersion" \
        "$( plist_str "$APP_PLIST" CFBundleVersion )"
else
    fail "$APP_PLIST is missing"
fi

DRIVER_PLIST="$PROJECT_ROOT/packages/driver/Info.plist"
if [ -f "$DRIVER_PLIST" ]; then
    expect_version "packages/driver/Info.plist CFBundleShortVersionString" \
        "$( plist_str "$DRIVER_PLIST" CFBundleShortVersionString )"
    expect_version "packages/driver/Info.plist CFBundleVersion" \
        "$( plist_str "$DRIVER_PLIST" CFBundleVersion )"
else
    fail "$DRIVER_PLIST is missing"
fi

DRIVER_VERSION_FILE="$PROJECT_ROOT/packages/driver/VERSION"
if [ -f "$DRIVER_VERSION_FILE" ]; then
    expect_version "packages/driver/VERSION" \
        "$( tr -d '[:space:]' < "$DRIVER_VERSION_FILE" )"
else
    fail "$DRIVER_VERSION_FILE is missing"
fi

DRIVER_CMAKE="$PROJECT_ROOT/packages/driver/CMakeLists.txt"
if [ -f "$DRIVER_CMAKE" ]; then
    CMAKE_VER="$( sed -nE 's/^[[:space:]]*project\(SoundBridgeDriver[[:space:]]+VERSION[[:space:]]+([0-9][0-9.]*).*$/\1/p' "$DRIVER_CMAKE" | head -n 1 )"
    expect_version "packages/driver/CMakeLists.txt project() VERSION" "$CMAKE_VER"
else
    fail "$DRIVER_CMAKE is missing"
fi

# The Host plist is not copied into SoundBridge.app by create_app_bundle.sh, so
# it carries no version the user can see. It is still updated by
# update_versions.sh and would be the first place a mismatch hides.
HOST_PLIST="$PROJECT_ROOT/packages/host/Info.plist"
if [ -f "$HOST_PLIST" ]; then
    expect_version "packages/host/Info.plist CFBundleShortVersionString" \
        "$( plist_str "$HOST_PLIST" CFBundleShortVersionString )" "not shipped in the app bundle"
    expect_version "packages/host/Info.plist CFBundleVersion" \
        "$( plist_str "$HOST_PLIST" CFBundleVersion )" "not shipped in the app bundle"
else
    note "packages/host/Info.plist does not exist (the Host binary carries no version of its own)"
fi

# ── DSP library ──────────────────────────────────────────────────────────────
# The DSP is a static library compiled into SoundBridge.app, so it carries no
# independent semver: `soundbridge_dsp_get_version()` must report the product
# version. It used to report the CMake project version, which was pinned at
# 1.0.0 while the release said 1.2.0 - a fourth source of truth that this script
# did not see. Instead of adding one more number to compare, the derivation is
# checked: project() must take its VERSION from the repository VERSION file.
# The compiled-in result is asserted at runtime by
# test_version_matches_the_repository_product_version in the DSP test suite
# (`make test-dsp`), which reads the same file.
echo ""
echo "DSP library"

DSP_CMAKE="$PROJECT_ROOT/packages/dsp/CMakeLists.txt"
if [ -f "$DSP_CMAKE" ]; then
    DSP_PROJECT_LINE="$(grep -E '^[[:space:]]*project\(soundbridge_dsp[[:space:]]+VERSION' "$DSP_CMAKE" | head -n 1)"
    if [ -z "$DSP_PROJECT_LINE" ]; then
        fail "packages/dsp/CMakeLists.txt has no project(soundbridge_dsp VERSION ...) line"
    elif printf '%s' "$DSP_PROJECT_LINE" | grep -Eq 'VERSION[[:space:]]+[0-9]'; then
        DSP_LITERAL="$(printf '%s' "$DSP_PROJECT_LINE" | sed -nE 's/.*VERSION[[:space:]]+([0-9][0-9.]*).*/\1/p')"
        fail "packages/dsp/CMakeLists.txt pins project version ${DSP_LITERAL:-<unparsed>} instead of deriving it from VERSION"
    else
        pass "packages/dsp/CMakeLists.txt project() version is derived, not pinned"
    fi

    if grep -q 'SOUNDBRIDGE_PRODUCT_VERSION_FILE' "$DSP_CMAKE"; then
        pass "packages/dsp/CMakeLists.txt reads VERSION as the DSP version source"
    else
        fail "packages/dsp/CMakeLists.txt does not reference SOUNDBRIDGE_PRODUCT_VERSION_FILE"
    fi
else
    fail "packages/dsp/CMakeLists.txt is missing"
fi

# ── Protocol agreement ───────────────────────────────────────────────────────
echo ""
echo "Shared-memory protocol"

HEADER="$PROJECT_ROOT/packages/shared/include/RFSharedAudio.h"
HEADER_HEX="$( sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+RF_AUDIO_PROTOCOL_VERSION[[:space:]]+(0x[0-9A-Fa-f]+)[uUlL]*.*$/\1/p' "$HEADER" 2>/dev/null | head -n 1 )"
if [ -z "$HEADER_HEX" ]; then
    fail "could not read RF_AUDIO_PROTOCOL_VERSION from packages/shared/include/RFSharedAudio.h"
else
    HEADER_DEC=$((HEADER_HEX))
    pass "RF_AUDIO_PROTOCOL_VERSION = $HEADER_HEX ($HEADER_DEC)"
    if [ -f "$DRIVER_PLIST" ]; then
        PLIST_PROTO="$( plist_str "$DRIVER_PLIST" SBAudioProtocolVersion )"
        if [ "$PLIST_PROTO" = "$HEADER_DEC" ]; then
            pass "packages/driver/Info.plist SBAudioProtocolVersion = $PLIST_PROTO"
        else
            fail "packages/driver/Info.plist SBAudioProtocolVersion = '${PLIST_PROTO:-<missing>}' (header says $HEADER_DEC)"
        fi
    fi
fi

# ── Built app bundle (optional) ──────────────────────────────────────────────
if [ -n "$APP_BUNDLE" ]; then
    echo ""
    echo "Built app bundle: $APP_BUNDLE"
    if [ ! -d "$APP_BUNDLE" ]; then
        fail "$APP_BUNDLE does not exist"
    else
        BUILT_PLIST="$APP_BUNDLE/Contents/Info.plist"
        if [ -f "$BUILT_PLIST" ]; then
            expect_version "bundle CFBundleShortVersionString" \
                "$( plist_str "$BUILT_PLIST" CFBundleShortVersionString )"
            expect_version "bundle CFBundleVersion" \
                "$( plist_str "$BUILT_PLIST" CFBundleVersion )"
        else
            fail "$BUILT_PLIST is missing"
        fi

        BUILT_DRIVER="$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver"
        if [ -d "$BUILT_DRIVER" ]; then
            expect_version "bundled driver CFBundleShortVersionString" \
                "$( plist_str "$BUILT_DRIVER/Contents/Info.plist" CFBundleShortVersionString )"
            expect_version "bundled driver CFBundleVersion" \
                "$( plist_str "$BUILT_DRIVER/Contents/Info.plist" CFBundleVersion )"
        else
            fail "the bundle has no Contents/Resources/SoundBridgeDriver.driver"
        fi
    fi
fi

# ── Package (optional) ───────────────────────────────────────────────────────
if [ -n "$PKG_PATH" ]; then
    echo ""
    echo "Installer package: $PKG_PATH"
    if [ ! -f "$PKG_PATH" ]; then
        fail "$PKG_PATH does not exist"
    else
        TMP_PARENT="$WORK_DIR"
        MADE_TMP=0
        if [ -z "$TMP_PARENT" ]; then
            TMP_PARENT="$( mktemp -d "${TMPDIR:-/tmp}/sb-versioncheck.XXXXXX" )"
            MADE_TMP=1
        fi
        mkdir -p "$TMP_PARENT"
        EXPANDED="$TMP_PARENT/pkg"
        rm -rf "$EXPANDED"
        # --expand-full, not --expand: productbuild writes a product archive whose
        # component package carries the PackageInfo and whose Payload is still a
        # pax archive. --expand leaves both as opaque files, so the checks below
        # would report "no PackageInfo" on a package that has one.
        if ! pkgutil --expand-full "$PKG_PATH" "$EXPANDED" >/dev/null 2>&1; then
            fail "pkgutil --expand-full could not read $PKG_PATH"
        else
            # The component package is one directory below the product archive
            # root. --expand-full also writes an ExpansionCache whose entries have
            # filenames like "PackageInfo" and versions like "InstallCmds-883";
            # searching deeper would find those instead of the real pkg-info.
            PKGINFO="$( find "$EXPANDED" -maxdepth 2 -name PackageInfo -type f -not -path '*ExpansionCache*' | head -n 1 )"
            if [ -z "$PKGINFO" ] || ! grep -q '<pkg-info' "$PKGINFO" 2>/dev/null; then
                fail "the package has no PackageInfo"
            else
                # Anchored on the space before the attribute name: the tag also
                # carries generator-version="InstallCmds-883 (26B131)", and a
                # looser pattern reads that as the package version.
                PKG_VER="$( sed -nE 's/.*<pkg-info[^>]*[[:space:]]version="([^"]+)".*/\1/p' "$PKGINFO" | head -n 1 )"
                expect_version "PackageInfo pkg-info version" "$PKG_VER"

                # The product archive's own <pkg-ref> carries the version the
                # Installer window shows. It is written by productbuild from a
                # different argument than pkgbuild's, so it is read separately.
                DISTRIBUTION="$EXPANDED/Distribution"
                if [ -f "$DISTRIBUTION" ]; then
                    DIST_VER="$( sed -nE 's/.*<pkg-ref[^>]*version="([^"]+)".*/\1/p' "$DISTRIBUTION" | head -n 1 )"
                    if [ -n "$DIST_VER" ]; then
                        expect_version "Distribution pkg-ref version" "$DIST_VER"
                    else
                        note "Distribution has no pkg-ref version attribute"
                    fi
                fi

                PAYLOAD_APP_PLIST="$( find "$EXPANDED" -path '*/Payload/Applications/SoundBridge.app/Contents/Info.plist' -type f | head -n 1 )"
                if [ -n "$PAYLOAD_APP_PLIST" ]; then
                    expect_version "payload app CFBundleShortVersionString" \
                        "$( plist_str "$PAYLOAD_APP_PLIST" CFBundleShortVersionString )"
                else
                    fail "the payload has no Applications/SoundBridge.app/Contents/Info.plist"
                fi

                PAYLOAD_DRIVER_PLIST="$( find "$EXPANDED" -path '*/Payload/*/InstallerPayload/driver/SoundBridgeDriver.driver/Contents/Info.plist' -type f | head -n 1 )"
                if [ -z "$PAYLOAD_DRIVER_PLIST" ]; then
                    PAYLOAD_DRIVER_PLIST="$( find "$EXPANDED" -path '*/Payload/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist' -type f | head -n 1 )"
                fi
                if [ -n "$PAYLOAD_DRIVER_PLIST" ]; then
                    expect_version "payload driver CFBundleShortVersionString" \
                        "$( plist_str "$PAYLOAD_DRIVER_PLIST" CFBundleShortVersionString )"
                else
                    fail "the payload has no driver bundle with Contents/Info.plist"
                fi
            fi
        fi
        if [ "$MADE_TMP" = "1" ] && [ "$KEEP_EXPANDED" != "1" ]; then
            rm -rf "$TMP_PARENT"
        elif [ "$KEEP_EXPANDED" = "1" ]; then
            echo "  (expanded package kept at $EXPANDED)"
        fi
    fi
fi

# ── Verdict ─────────────────────────────────────────────────────────────────
echo ""
echo "VERSION_SOURCES_CHECKED=$CHECKS"
echo "VERSION_SOURCES_FAILED=$FAILS"
if [ "$FAILS" -eq 0 ]; then
    echo "VERSION_CONSISTENCY=PASS"
    exit 0
fi
echo "VERSION_CONSISTENCY=FAIL"
exit 1
