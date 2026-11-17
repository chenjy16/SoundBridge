#!/bin/bash
#
# Verify a distribution DMG by mounting it read-only and inspecting what is in it.
#
# Why this exists (Phase 2.2.2-Batch B)
# ------------------------------------
# The DMG is the artifact users actually receive, and its name is the only thing
# most tooling looks at. A disk image called SoundBridge-1.1.1.dmg can contain an
# older app, an app without its driver, an app whose Sparkle framework was left
# out by an interrupted copy, or a single-architecture binary. So this script
# mounts the image and checks the payload itself: the bundle's parts, the version
# the app and the driver declare, and the architectures of every core binary.
#
# Mount cleanup
# -------------
# `hdiutil attach` leaves a volume behind on every exit path unless something
# detaches it. What this script can promise, and what it cannot:
#
#   normal exit, a failing check, SIGINT, SIGTERM   it detaches, then removes the
#                                                   mount point, then exits
#   detach fails                                    it says so, keeps the mount
#                                                   point in place, and exits
#                                                   non-zero even when every
#                                                   check passed
#   SIGKILL, kernel panic, power loss               outside the reach of a shell
#                                                   trap; nothing here can help
#
# The mount point is a private mktemp directory and it is passed to hdiutil with
# -mountpoint, so the detach can only hit the volume this run attached. The
# device hdiutil reports is recorded so "still attached" can be answered by
# asking hdiutil rather than by trusting the detach exit code. The script never
# writes to the mounted volume, never uses sudo and never runs the apps it
# inspects.
#
# Usage
#   tools/verify_dmg_contents.sh                              # dist/SoundBridge-<app version>.dmg
#   tools/verify_dmg_contents.sh dist/SoundBridge-1.1.1.dmg
#   tools/verify_dmg_contents.sh --expect-version 1.1.1 <dmg>
#   tools/verify_dmg_contents.sh --app dist/Other.app <dmg>     # version from a different bundle
#   tools/verify_dmg_contents.sh --driver-report out.tsv <dmg>  # record the copy inside the image
#
# The driver inside the image
# ---------------------------
# This script mounts the image and reads the driver bundle in it. That copy (D)
# still has to be compared with the other three: the bundle in dist/ (A), the
# package's embedded app (B) and the package's staged payload (C). Mounting
# belongs here, the comparison belongs to tools/verify_pkg_contents.sh. The
# report written with --driver-report is the interface: it carries the same
# manifest that script prints for the other three copies, so the comparison in
# the payload check is a manifest comparison, not a second and weaker one.
#
# The report is written right after the driver is read, before any later check
# can fail. A run that is interrupted (SIGINT, SIGTERM, SIGKILL) never gets
# there, so an interrupted run leaves no report -- and no report is reported as
# NOT_VERIFIED by the caller, never as agreement.
#
# Environment (test seams; all unset in normal use)
#   SB_DMG_VERIFY_HOLD=<seconds>  pause after mounting, so a signal can be delivered
#   SB_DMG_DETACH_FAIL=1          report a detach failure without one happening
#   SB_KEEP_WORK=1                keep the scratch directory and print its path
#   SB_MANIFEST_TOOL=<path>       script used to print the driver manifest
#
# Output (parsed by tools/verify_release_payload.sh)
#   DMG_STRUCTURE=PASS|FAIL
#   VERSION_CONSISTENCY=PASS|FAIL
#   ARCHITECTURE=PASS|FAIL
#   APP_BUNDLE_VERSION=<value>              Bundle Verified
#   DRIVER_BUNDLE_VERSION=<value>           Bundle Verified
#   HOST_SOURCE_VERSION=<value>             Source Verified (see evidence line)
#   HOST_VERSION_EVIDENCE=<level + source>  which of the four levels applies
#   PROTOCOL_VERSION=<value>                Bundle Verified
#   DMG_FILE_VERSION=<value>                Name Verified
#   DMG_MOUNTED=true|false
#   DMG_DETACHED=true|false
#   DMG_DEVICE=/dev/diskN                    the volume hdiutil attached, if any
#   DRIVER_COPY_PRESENT=true|false           whether the image carries the driver
#   DRIVER_EXECUTABLE_SHA256=<value>
#   DRIVER_EXECUTABLE_PERMISSIONS=<value>
#   DRIVER_INFO_PLIST_SHA256=<value>
#   DRIVER_COPY_MANIFEST_SHA256=<value>      the manifest of the copy in the image
#   exit 0 only when every check holds *and* the volume is detached
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADER="$ROOT_DIR/packages/shared/include/RFSharedAudio.h"
HOST_SOURCE_PLIST="$ROOT_DIR/packages/host/Info.plist"
DRIVER_NAME="SoundBridgeDriver.driver"

DMG=""
EXPECT_VERSION=""
APP_BUNDLE=""
APP_BUNDLE_EXPLICIT=0
DRIVER_REPORT_OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --expect-version) EXPECT_VERSION="$2"; shift 2 ;;
        --app) APP_BUNDLE="$2"; APP_BUNDLE_EXPLICIT=1; shift 2 ;;
        --driver-report) DRIVER_REPORT_OUT="$2"; shift 2 ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        --*) echo "error: unknown option '$1'" >&2; exit 2 ;;
        *) DMG="$1"; shift ;;
    esac
done

FAILURES=0
fail() { echo "FAIL  $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "ok    $*"; }
info() { echo "      $*"; }

# PlistBuddy answers a missing file on stdout ("File Doesn't Exist, Will
# Create: ...") and a missing key on stderr. Neither is a value, so read through
# here and treat every failure as empty.
plist_read() {
    local path="$1" key="$2"
    [[ -f "$path" ]] || return 0
    /usr/libexec/PlistBuddy -c "Print :$key" "$path" 2>/dev/null || true
}

for tool in /usr/bin/hdiutil /usr/bin/lipo /usr/bin/file /usr/bin/shasum \
            /usr/libexec/PlistBuddy; do
    [[ -x "$tool" ]] || { echo "FAIL  required tool missing: $tool" >&2; exit 1; }
done

APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/dist/SoundBridge.app}"
MANIFEST_TOOL="${SB_MANIFEST_TOOL:-$ROOT_DIR/tools/verify_pkg_contents.sh}"

# --- the copy inside the image ------------------------------------------------
# Declared here so the early exits below can record "there was nothing to read"
# instead of leaving the caller to guess from a missing file.
DRIVER_PRESENT=false
DRIVER_EXECUTABLE_REL=""
DRIVER_EXECUTABLE_PERMISSIONS=""
DRIVER_EXECUTABLE_SHA256=""
DRIVER_INFO_PLIST_SHA256=""
DRIVER_PROTOCOL_VALUE=""
IMAGE_MANIFEST=""
DRIVER_TREE_ENTRIES="0"
DRIVER_COPY_MANIFEST_SHA256=""

write_driver_report() {
    [[ -n "$DRIVER_REPORT_OUT" ]] || return 0
    {
        echo "DRIVER_REPORT_FORMAT=1"
        echo "DRIVER_PRESENT=$DRIVER_PRESENT"
        echo "DRIVER_REL=Contents/Resources/$DRIVER_NAME"
        echo "DRIVER_EXECUTABLE_REL=$DRIVER_EXECUTABLE_REL"
        echo "DRIVER_EXECUTABLE_PERMISSIONS=$DRIVER_EXECUTABLE_PERMISSIONS"
        echo "DRIVER_EXECUTABLE_SHA256=$DRIVER_EXECUTABLE_SHA256"
        echo "DRIVER_INFO_PLIST_SHA256=$DRIVER_INFO_PLIST_SHA256"
        echo "DRIVER_PROTOCOL=$DRIVER_PROTOCOL_VALUE"
        echo "DRIVER_TREE_ENTRIES=$DRIVER_TREE_ENTRIES"
        echo "DRIVER_TREE_SHA256=$DRIVER_COPY_MANIFEST_SHA256"
        echo "# --- driver manifest below ---"
        if [[ -n "$IMAGE_MANIFEST" && -f "$IMAGE_MANIFEST" ]]; then
            cat "$IMAGE_MANIFEST"
        fi
    } > "$DRIVER_REPORT_OUT" 2>/dev/null \
        || echo "warning: could not write the driver report to $DRIVER_REPORT_OUT" >&2
}

if [[ -z "$DMG" ]]; then
    DEFAULT_APP_PLIST="$APP_BUNDLE/Contents/Info.plist"
    VERSION_FROM_APP="$(plist_read "$DEFAULT_APP_PLIST" CFBundleShortVersionString)"
    if [[ -n "$VERSION_FROM_APP" ]]; then
        DMG="$ROOT_DIR/dist/SoundBridge-$VERSION_FROM_APP.dmg"
    else
        DMG="$ROOT_DIR/dist/SoundBridge.dmg"
    fi
fi

DMG_BASENAME="$(basename "$DMG")"
FILENAME_VERSION=""
if [[ "$DMG_BASENAME" =~ ^SoundBridge-(.+)\.dmg$ ]]; then
    FILENAME_VERSION="${BASH_REMATCH[1]}"
fi

if [[ ! -f "$DMG" ]]; then
    echo "FAIL  disk image not found: $DMG" >&2
    echo "DMG_STRUCTURE=FAIL"
    echo "VERSION_CONSISTENCY=FAIL"
    echo "ARCHITECTURE=FAIL"
    echo "APP_BUNDLE_VERSION="
    echo "DRIVER_BUNDLE_VERSION="
    echo "HOST_SOURCE_VERSION="
    echo "HOST_VERSION_EVIDENCE=Not Verified (no image to read)"
    echo "PROTOCOL_VERSION="
    echo "DMG_FILE_VERSION=$FILENAME_VERSION"
    echo "DMG_DEVICE="
    echo "DRIVER_COPY_PRESENT=$DRIVER_PRESENT"
    echo "DRIVER_EXECUTABLE_SHA256="
    echo "DRIVER_EXECUTABLE_PERMISSIONS="
    echo "DRIVER_INFO_PLIST_SHA256="
    echo "DRIVER_COPY_MANIFEST_SHA256="
    write_driver_report
    echo "DMG_MOUNTED=false"
    echo "DMG_DETACHED=true"
    exit 1
fi

# --- expected version -------------------------------------------------------
# From the bundle the image was built from (--app, or dist/ by default) or from
# --expect-version, never from the file name: a rename would otherwise make the
# image agree with itself.
#
# Read through plist_read: PlistBuddy answers a missing file on stdout ("File
# Doesn't Exist, Will Create: ..."), which is not a version but reads like one.
if [[ -z "$EXPECT_VERSION" ]]; then
    EXPECT_VERSION="$(plist_read "$APP_BUNDLE/Contents/Info.plist" CFBundleShortVersionString)"
    # A bundle the caller named is the bundle the caller meant. Falling back to
    # dist/ here would compare the image against something nobody asked about.
    if [[ -z "$EXPECT_VERSION" && "$APP_BUNDLE_EXPLICIT" -eq 1 ]]; then
        echo "FAIL  no version to compare against: $APP_BUNDLE has no readable CFBundleShortVersionString" >&2
        echo "      the bundle named with --app is the one this run checks; there is no fallback to dist/" >&2
        echo "DMG_STRUCTURE=FAIL"
        echo "VERSION_CONSISTENCY=FAIL"
        echo "ARCHITECTURE=FAIL"
        echo "APP_BUNDLE_VERSION="
        echo "DRIVER_BUNDLE_VERSION="
        echo "HOST_SOURCE_VERSION="
        echo "HOST_VERSION_EVIDENCE=Not Verified (no expected version)"
        echo "PROTOCOL_VERSION="
        echo "DMG_FILE_VERSION=$FILENAME_VERSION"
        echo "DMG_DEVICE="
        echo "DRIVER_COPY_PRESENT=false"
        echo "DRIVER_EXECUTABLE_SHA256="
        echo "DRIVER_EXECUTABLE_PERMISSIONS="
        echo "DRIVER_INFO_PLIST_SHA256="
        echo "DRIVER_COPY_MANIFEST_SHA256="
        write_driver_report
        echo "DMG_MOUNTED=false"
        echo "DMG_DETACHED=true"
        exit 1
    fi
fi

EXPECTED_PROTOCOL_HEX="$(sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+RF_AUDIO_PROTOCOL_VERSION[[:space:]]+(0x[0-9A-Fa-f]+)[uUlL]*.*$/\1/p' "$HEADER" | head -n 1)"
EXPECTED_PROTOCOL=""
if [[ -n "$EXPECTED_PROTOCOL_HEX" ]]; then
    EXPECTED_PROTOCOL="$(( 0x${EXPECTED_PROTOCOL_HEX#0x} ))"
fi

echo "Verifying disk image: $DMG"
info "sha256: $(/usr/bin/shasum -a 256 "$DMG" | awk '{print $1}')"
info "size:   $(/usr/bin/stat -f '%z' "$DMG") bytes"
info "name declares version: ${FILENAME_VERSION:-<not a SoundBridge-<version>.dmg name>}"
info "expected version:      ${EXPECT_VERSION:-<unknown>}"
echo ""

# --- mount (read-only) ------------------------------------------------------
MNT="$(mktemp -d "${TMPDIR:-/tmp}/soundbridge-dmg.XXXXXX")" || exit 1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/soundbridge-dmgwork.XXXXXX")" || { rmdir "$MNT"; exit 1; }
MOUNTED=0
WAS_MOUNTED=false
DETACHED=true
ATTACH_OUT=""
MOUNT_DEV=""

# "Is this image still attached?" is answered by hdiutil, not by the exit code of
# the detach: a detach that returns 0 for an image that is still there is exactly
# the failure this checks for.
#
# The whole list is read before it is compared. A `... | grep -q` here would end
# the pipeline early, SIGPIPE the writer, and with pipefail turn "found" into a
# non-zero status -- which reads as "detached", the opposite of the truth.
image_still_attached() {
    local image listed
    image="$(/bin/realpath "$DMG" 2>/dev/null || printf '%s' "$DMG")"
    listed="$(/usr/bin/hdiutil info 2>/dev/null \
        | /usr/bin/awk -F': *' '/image-path/ { print $2 }')${IFS}"
    case "$listed" in
        *"$image"*) return 0 ;;
    esac
    return 1
}

cleanup() {
    local rc=$?
    if [[ "$MOUNTED" -eq 1 ]]; then
        /usr/bin/hdiutil detach "$MNT" -force >/dev/null 2>&1 \
            || /usr/bin/hdiutil detach "$MNT" >/dev/null 2>&1
        # The exit code above is not evidence; hdiutil is.
        if [[ "${SB_DMG_DETACH_FAIL:-0}" == "1" ]]; then
            DETACHED=false
            echo "FAIL  detach failure injected by SB_DMG_DETACH_FAIL=1 (the volume was still detached for real)" >&2
        elif image_still_attached; then
            DETACHED=false
            echo "FAIL  the image is still attached after detach${MOUNT_DEV:+ ($MOUNT_DEV)}" >&2
            echo "      free it by hand: hdiutil detach '$MNT'" >&2
        elif [[ -d "$MNT/SoundBridge.app" ]]; then
            DETACHED=false
            echo "FAIL  $MNT still shows the app after detach" >&2
        else
            DETACHED=true
        fi
        MOUNTED=0
        if [[ "$DETACHED" == "false" && "$rc" -eq 0 ]]; then
            rc=1
        fi
    fi
    rmdir "$MNT" 2>/dev/null || true
    if [[ "${SB_KEEP_WORK:-0}" == "1" ]]; then
        echo "      scratch kept: $WORK"
    else
        rm -rf "$WORK"
    fi
    echo "DMG_MOUNTED=$WAS_MOUNTED"
    echo "DMG_DETACHED=$DETACHED"
    exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! ATTACH_OUT="$(/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen \
        -mountpoint "$MNT" "$DMG" 2>&1)"; then
    echo "$ATTACH_OUT" | sed 's/^/      /' >&2
    fail "hdiutil could not attach the image; it is corrupt or not a disk image"
    echo ""
    echo "DMG_STRUCTURE=FAIL"
    echo "VERSION_CONSISTENCY=FAIL"
    echo "ARCHITECTURE=FAIL"
    echo "APP_BUNDLE_VERSION="
    echo "DRIVER_BUNDLE_VERSION="
    echo "HOST_SOURCE_VERSION="
    echo "HOST_VERSION_EVIDENCE=Not Verified (the image could not be mounted)"
    echo "PROTOCOL_VERSION="
    echo "DMG_FILE_VERSION=$FILENAME_VERSION"
    echo "DMG_DEVICE="
    echo "DRIVER_COPY_PRESENT=false"
    echo "DRIVER_EXECUTABLE_SHA256="
    echo "DRIVER_EXECUTABLE_PERMISSIONS="
    echo "DRIVER_INFO_PLIST_SHA256="
    echo "DRIVER_COPY_MANIFEST_SHA256="
    write_driver_report
    exit 1
fi
MOUNTED=1
WAS_MOUNTED=true
MOUNT_DEV="$(printf '%s\n' "$ATTACH_OUT" | awk '/^\/dev\/disk/ { print $1; exit }')"
echo "mounted read-only at $MNT${MOUNT_DEV:+ ($MOUNT_DEV)}"
echo ""

# Test seam: with SB_DMG_VERIFY_HOLD set to a number of seconds, the script
# pauses right after mounting so the test suite can interrupt it and prove the
# volume is detached on SIGTERM as well as on a normal exit. Unset in normal use.
if [[ -n "${SB_DMG_VERIFY_HOLD:-}" ]]; then
    echo "test seam: holding the mount for ${SB_DMG_VERIFY_HOLD}s"
    sleep "$SB_DMG_VERIFY_HOLD"
fi

VOL="$MNT"
APP="$VOL/SoundBridge.app"

# --- 1. what the volume holds ----------------------------------------------
echo "Volume contents:"
ls -a "$VOL" | grep -Ev '^\.\.?$' | sed 's/^/  /'
echo ""

if [[ ! -d "$APP" ]]; then
    fail "the image has no SoundBridge.app at its root"
else
    pass "the image contains SoundBridge.app"
fi

if [[ ! -L "$VOL/Applications" ]]; then
    info "note: no Applications link in the image (cosmetic, not fatal)"
fi

APP_PLIST="$APP/Contents/Info.plist"
APP_EXE="$APP/Contents/MacOS/SoundBridgeApp"
HOST_EXE="$APP/Contents/MacOS/SoundBridgeHost"
DRIVER="$APP/Contents/Resources/$DRIVER_NAME"
DRIVER_PLIST="$DRIVER/Contents/Info.plist"
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -f "$SPARKLE_FW/Versions/B/Sparkle" ]]; then
    SPARKLE_BIN="$SPARKLE_FW/Versions/B/Sparkle"
elif [[ -f "$SPARKLE_FW/Versions/Current/Sparkle" ]]; then
    SPARKLE_BIN="$SPARKLE_FW/Versions/Current/Sparkle"
else
    SPARKLE_BIN=""
fi

DRIVER_EXE_NAME="$(plist_read "$DRIVER_PLIST" CFBundleExecutable)"
[[ -n "$DRIVER_EXE_NAME" ]] || DRIVER_EXE_NAME="${DRIVER_NAME%.driver}"
DRIVER_EXE="$DRIVER/Contents/MacOS/$DRIVER_EXE_NAME"

# --- 2. the parts that make it an app --------------------------------------
[[ -f "$APP_PLIST" ]] && pass "app Info.plist is present" \
    || fail "app Info.plist is missing"
if [[ -f "$APP_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PLIST" >/dev/null 2>&1 \
        && pass "app Info.plist is readable (CFBundleIdentifier present)" \
        || fail "app Info.plist has no readable CFBundleIdentifier"
fi
[[ -x "$APP_EXE" ]] && pass "app executable is present and executable" \
    || fail "app executable is missing or not executable: Contents/MacOS/SoundBridgeApp"
[[ -x "$HOST_EXE" ]] && pass "host executable is present and executable" \
    || fail "host executable is missing or not executable: Contents/MacOS/SoundBridgeHost"
[[ -d "$DRIVER" ]] && pass "driver bundle is present" \
    || fail "driver bundle is missing: Contents/Resources/$DRIVER_NAME"
[[ -x "$DRIVER_EXE" ]] && pass "driver executable is present and executable" \
    || fail "driver executable is missing or not executable: Contents/MacOS/$DRIVER_EXE_NAME"
if [[ -f "$DRIVER_PLIST" ]]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DRIVER_PLIST" >/dev/null 2>&1 \
        && pass "driver Info.plist is readable (CFBundleIdentifier present)" \
        || fail "driver Info.plist has no readable CFBundleIdentifier"
else
    fail "driver Info.plist is missing: Contents/Resources/$DRIVER_NAME/Contents/Info.plist"
fi
[[ -d "$SPARKLE_FW" ]] && pass "Sparkle.framework is present" \
    || fail "Sparkle.framework is missing; SoundBridgeApp links @rpath/Sparkle.framework"
[[ -n "$SPARKLE_BIN" ]] && pass "Sparkle.framework has an executable" \
    || fail "Sparkle.framework has no Versions/B or Versions/Current executable"

# --- 2b. the driver copy, written down while the volume is still mounted -----
# The four-way comparison runs after this script has detached, so everything it
# needs from this side is recorded here: the same tree manifest the package check
# prints for its copies, plus the three values it compares separately.
if [[ -d "$DRIVER" ]]; then
    DRIVER_PRESENT=true
    DRIVER_EXECUTABLE_REL="Contents/MacOS/$DRIVER_EXE_NAME"
    if [[ -f "$DRIVER_EXE" ]]; then
        DRIVER_EXECUTABLE_PERMISSIONS="$(/usr/bin/stat -f '%Sp' "$DRIVER_EXE")"
        DRIVER_EXECUTABLE_SHA256="$(/usr/bin/shasum -a 256 "$DRIVER_EXE" | awk '{print $1}')"
    fi
    if [[ -f "$DRIVER_PLIST" ]]; then
        DRIVER_INFO_PLIST_SHA256="$(/usr/bin/shasum -a 256 "$DRIVER_PLIST" | awk '{print $1}')"
    fi
    DRIVER_PROTOCOL_VALUE="$(plist_read "$DRIVER_PLIST" SBAudioProtocolVersion)"
    IMAGE_MANIFEST="$WORK/driver-image.tsv"
    if ! "$MANIFEST_TOOL" --manifest-only "$DRIVER" > "$IMAGE_MANIFEST" 2> "$WORK/manifest.err"; then
        : > "$IMAGE_MANIFEST"
        fail "could not read a manifest of the driver in the image"
        sed 's/^/      /' "$WORK/manifest.err" >&2
    fi
    if [[ -s "$IMAGE_MANIFEST" ]]; then
        DRIVER_TREE_ENTRIES="$(wc -l < "$IMAGE_MANIFEST" | tr -d ' ')"
        DRIVER_COPY_MANIFEST_SHA256="$(/usr/bin/shasum -a 256 "$IMAGE_MANIFEST" | awk '{print $1}')"
    fi
fi
write_driver_report

# --- 3. versions ------------------------------------------------------------
# Each value is labelled with what it actually is. The distinction matters: a
# version read out of a bundle's Info.plist is not the same kind of evidence as a
# version read out of a source file somewhere in the repository.
#
#   APP_BUNDLE_VERSION      Bundle Verified   the mounted app's Info.plist
#   DRIVER_BUNDLE_VERSION   Bundle Verified   the driver's own Info.plist
#   HOST_SOURCE_VERSION     Source Verified   packages/host/Info.plist; the host
#                                             ships as a bare executable, and the
#                                             probe below reports whether that
#                                             binary carries an __info_plist
#                                             section to read instead
#   PROTOCOL_VERSION        Bundle Verified   the driver's Info.plist, vs header
#   DMG_FILE_VERSION        Name Verified     the file name on disk
#
# The host value is never presented as a fact about the binary. Giving that
# executable version metadata is a build-system change, out of scope here.
APP_BUNDLE_VERSION="$(plist_read "$APP_PLIST" CFBundleShortVersionString)"
DRIVER_BUNDLE_VERSION="$(plist_read "$DRIVER_PLIST" CFBundleShortVersionString)"
PROTOCOL_VERSION="$(plist_read "$DRIVER_PLIST" SBAudioProtocolVersion)"
DMG_FILE_VERSION="$FILENAME_VERSION"

host_binary_has_info_plist() {
    /usr/bin/otool -l "$1" 2>/dev/null | /usr/bin/grep -q '__info_plist'
}

host_binary_version() {
    local bin="$1" hex plist="$WORK/host-info.plist"
    hex="$(/usr/bin/otool -s __TEXT __info_plist -X "$bin" 2>/dev/null \
        | /usr/bin/awk 'NR > 1 { for (i = 1; i <= NF; i++) printf "%s", $i }')"
    [[ -n "$hex" ]] || return 0
    printf '%s' "$hex" | /usr/bin/xxd -r -p > "$plist" 2>/dev/null || return 0
    plist_read "$plist" CFBundleShortVersionString
}

HOST_SOURCE_VERSION="$(plist_read "$HOST_SOURCE_PLIST" CFBundleShortVersionString)"
HOST_BINARY_VERSION=""
if [[ -f "$HOST_EXE" ]] && host_binary_has_info_plist "$HOST_EXE"; then
    HOST_BINARY_VERSION="$(host_binary_version "$HOST_EXE")"
    if [[ -n "$HOST_BINARY_VERSION" ]]; then
        HOST_VERSION_EVIDENCE="Binary Verified (__TEXT,__info_plist in the host executable)"
    else
        HOST_VERSION_EVIDENCE="Not Verified (the host executable has an __info_plist section that could not be read)"
    fi
else
    HOST_VERSION_EVIDENCE="Source Verified (packages/host/Info.plist; the host executable has no __TEXT,__info_plist)"
fi

echo ""
echo "Versions, and what each one is:"
info "app:              ${APP_BUNDLE_VERSION:-<missing>}   [Bundle Verified]"
info "driver:           ${DRIVER_BUNDLE_VERSION:-<missing>}   [Bundle Verified]"
info "host source:      ${HOST_SOURCE_VERSION:-<missing>}   [${HOST_VERSION_EVIDENCE}]"
info "host binary:      ${HOST_BINARY_VERSION:-<no version metadata in the executable>}"
info "driver protocol:  ${PROTOCOL_VERSION:-<missing>}${EXPECTED_PROTOCOL:+ (header: $EXPECTED_PROTOCOL)}   [Bundle Verified]"
info "file name:        ${DMG_FILE_VERSION:-<unversioned>}   [Name Verified]"
info "expected:         ${EXPECT_VERSION:-<unknown>}"
echo ""

if [[ -z "$EXPECT_VERSION" ]]; then
    fail "no expected version: pass --expect-version or keep dist/SoundBridge.app in place"
else
    [[ "$APP_BUNDLE_VERSION" == "$EXPECT_VERSION" ]] \
        && pass "app version is $EXPECT_VERSION (the app's own Info.plist)" \
        || fail "app version is '${APP_BUNDLE_VERSION:-<missing>}', expected $EXPECT_VERSION"
    [[ "$DRIVER_BUNDLE_VERSION" == "$EXPECT_VERSION" ]] \
        && pass "driver version is $EXPECT_VERSION (the driver's own Info.plist)" \
        || fail "driver version is '${DRIVER_BUNDLE_VERSION:-<missing>}', expected $EXPECT_VERSION"
    # Source level on purpose: the shipped host binary has no version resource,
    # so this compares the version it was built from, not a version inside it.
    [[ "$HOST_SOURCE_VERSION" == "$EXPECT_VERSION" ]] \
        && pass "host source version is $EXPECT_VERSION (packages/host/Info.plist; not read from the binary)" \
        || fail "host source version is '${HOST_SOURCE_VERSION:-<missing>}', expected $EXPECT_VERSION"
    if [[ -n "$HOST_BINARY_VERSION" ]]; then
        [[ "$HOST_BINARY_VERSION" == "$EXPECT_VERSION" ]] \
            && pass "host binary version is $EXPECT_VERSION (read from __TEXT,__info_plist)" \
            || fail "host binary version is '$HOST_BINARY_VERSION', expected $EXPECT_VERSION"
    fi
    [[ "$DMG_FILE_VERSION" == "$EXPECT_VERSION" ]] \
        && pass "file name declares $EXPECT_VERSION" \
        || fail "file name declares '${DMG_FILE_VERSION:-<unversioned>}' but the payload is $EXPECT_VERSION"
fi

if [[ -z "$EXPECTED_PROTOCOL" ]]; then
    fail "could not read RF_AUDIO_PROTOCOL_VERSION from the shared header"
elif [[ "$PROTOCOL_VERSION" == "$EXPECTED_PROTOCOL" ]]; then
    pass "driver protocol $PROTOCOL_VERSION matches the shared header (driver's Info.plist)"
else
    fail "driver protocol '${PROTOCOL_VERSION:-<missing>}' != header $EXPECTED_PROTOCOL"
fi

# --- 4. architectures -------------------------------------------------------
ARCH_FAILURES=0
ARCH_LINES=""

check_arch() {
    local label="$1" binary="$2" archs required
    if [[ -z "$binary" || ! -f "$binary" ]]; then
        ARCH_LINES+="  $label:"$'\n'"    arm64: FAIL (binary not found)"$'\n'"    x86_64: FAIL (binary not found)"$'\n'
        ARCH_FAILURES=$((ARCH_FAILURES + 1))
        return
    fi
    archs="$(/usr/bin/lipo -archs "$binary" 2>/dev/null || true)"
    if [[ -z "$archs" ]]; then
        ARCH_LINES+="  $label:"$'\n'"    arm64: FAIL (not a Mach-O binary: $(/usr/bin/file -b "$binary" | head -c 60))"$'\n'"    x86_64: FAIL (not a Mach-O binary)"$'\n'
        ARCH_FAILURES=$((ARCH_FAILURES + 1))
        return
    fi
    ARCH_LINES+="  $label:"$'\n'
    for required in arm64 x86_64; do
        if [[ " $archs " == *" $required "* ]]; then
            ARCH_LINES+="    $required: PASS"$'\n'
        else
            ARCH_LINES+="    $required: FAIL (has: $archs)"$'\n'
            ARCH_FAILURES=$((ARCH_FAILURES + 1))
        fi
    done
}

check_arch "SoundBridgeApp" "$APP_EXE"
check_arch "Host" "$HOST_EXE"
check_arch "Driver" "$DRIVER_EXE"
check_arch "Sparkle" "$SPARKLE_BIN"

echo ""
echo "ARCH_CHECK (mounted image)"
printf '%s' "$ARCH_LINES"
echo ""

# --- 5. summary -------------------------------------------------------------
if [[ "$FAILURES" -eq 0 ]]; then
    echo "DMG_STRUCTURE=PASS"
else
    echo "DMG_STRUCTURE=FAIL"
fi
if [[ "$FAILURES" -eq 0 ]]; then
    echo "VERSION_CONSISTENCY=PASS"
else
    echo "VERSION_CONSISTENCY=FAIL"
fi
if [[ "$ARCH_FAILURES" -eq 0 ]]; then
    echo "ARCHITECTURE=PASS"
else
    echo "ARCHITECTURE=FAIL"
fi
# Each version is emitted with the evidence level that produced it. A reader
# must not have to guess whether a value came out of a binary, a bundle or a
# source file.
echo "APP_BUNDLE_VERSION=${APP_BUNDLE_VERSION:-}"
echo "DRIVER_BUNDLE_VERSION=${DRIVER_BUNDLE_VERSION:-}"
echo "HOST_SOURCE_VERSION=${HOST_SOURCE_VERSION:-}"
echo "HOST_VERSION_EVIDENCE=${HOST_VERSION_EVIDENCE:-}"
echo "PROTOCOL_VERSION=${PROTOCOL_VERSION:-}"
echo "DMG_FILE_VERSION=${DMG_FILE_VERSION:-}"
echo "DMG_FILE=$DMG"
echo "DMG_SHA256=$(/usr/bin/shasum -a 256 "$DMG" | awk '{print $1}')"
echo "DMG_VOLUME_ENTRIES=$(ls -a "$VOL" | grep -Ev '^\.\.?$' | wc -l | tr -d ' ')"
echo "DMG_DEVICE=$MOUNT_DEV"
echo "DRIVER_COPY_PRESENT=$DRIVER_PRESENT"
echo "DRIVER_EXECUTABLE_SHA256=${DRIVER_EXECUTABLE_SHA256:-}"
echo "DRIVER_EXECUTABLE_PERMISSIONS=${DRIVER_EXECUTABLE_PERMISSIONS:-}"
echo "DRIVER_INFO_PLIST_SHA256=${DRIVER_INFO_PLIST_SHA256:-}"
echo "DRIVER_COPY_MANIFEST_SHA256=${DRIVER_COPY_MANIFEST_SHA256:-}"

if [[ "$FAILURES" -eq 0 && "$ARCH_FAILURES" -eq 0 ]]; then
    echo ""
    echo "PASS  $DMG (unmounted; nothing was installed)"
    exit 0
fi

echo ""
echo "FAIL  $DMG" >&2
exit 1
