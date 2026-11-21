#!/bin/bash
#
# One read-only entry point for the release-payload checks (Phase 2.2.2-Batch B).
#
# Every stage is a separate script, run here in the order a release is built:
#
#   1. PKG_STRUCTURE        tools/verify_installer_pkg.sh    package layout, install scripts, transaction
#   2. DMG_STRUCTURE        tools/verify_dmg_contents.sh     mount the image, check the app inside it,
#                                                           and record the driver copy it found
#   3. DRIVER_CONSISTENCY   tools/verify_pkg_contents.sh     the driver in the package's two copies, in
#                                                           the bundle dist/ is built from, and in the
#                                                           image is one driver (four-way)
#   4. ARCHITECTURE         stages 1 and 3, plus             every core binary has arm64 and x86_64
#                           tools/verify_release_bundle.sh   ... for the app bundle in dist/ too
#   5. VERSION_CONSISTENCY  stages 1 and 2                   app, driver, protocol and both file names agree
#   6. ARTIFACT_INTEGRITY   this script                      sizes, SHA256, and the package holds this app
#
# The image stage runs before the driver comparison because the copy inside the
# image only exists while it is mounted: stage 2 writes down what it saw, stage 3
# reads that. If the image cannot be read, stage 3 reports NOT_VERIFIED -- it does
# not fall back to a three-way comparison and call the result a pass.
#
# A stage that cannot run is reported as NOT_VERIFIED, never as PASS: an image
# that was never built is not a verified image. The script exits 0 only when all
# six are PASS.
#
# Nothing here builds, installs, signs or notarizes anything. Steps that need a
# real installation (L4) are out of scope by design.
#
# Usage
#   tools/verify_release_payload.sh                     # everything in dist/ for the repository's VERSION
#   tools/verify_release_payload.sh --skip-dmg          # package only
#   tools/verify_release_payload.sh --pkg dist/x.pkg --dmg dist/x.dmg --app dist/SoundBridge.app
#   tools/verify_release_payload.sh --print-target      # say which files would be checked, then stop
#   tools/verify_release_payload.sh --verbose           # full stage output instead of the tail
#
# Which version the default target is
# -----------------------------------
# `VERSION` (the file at the repository root) names the release. It is read from
# there and *not* from `dist/SoundBridge.app`, because the bundle in dist/ is
# exactly the thing that can be stale: a 1.1.1 bundle left behind selected
# `dist/SoundBridge-1.1.1.{pkg,dmg}`, and the two old artifacts agreed with each
# other while the tree said 1.2.0. `--version` still overrides, and the bundle is
# still compared -- a mismatch is now a FAIL instead of the selector.
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP="$ROOT_DIR/dist/SoundBridge.app"
PKG=""
DMG=""
VERSION=""
VERSION_SOURCE=""
VERBOSE=0
SKIP_PKG=0
SKIP_DMG=0
PRINT_TARGETS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)      APP="$2"; shift 2 ;;
        --pkg)      PKG="$2"; shift 2 ;;
        --dmg)      DMG="$2"; shift 2 ;;
        --version)  VERSION="$2"; VERSION_SOURCE="--version"; shift 2 ;;
        --skip-pkg) SKIP_PKG=1; shift ;;
        --skip-dmg) SKIP_DMG=1; shift ;;
        --print-target|--print-targets) PRINT_TARGETS=1; shift ;;
        --verbose)  VERBOSE=1; shift ;;
        -h|--help)  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    # The repository's VERSION file decides which release is being verified.
    if [[ -f "$ROOT_DIR/VERSION" ]]; then
        VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
        VERSION_SOURCE="VERSION file"
    elif [[ -f "$APP/Contents/Info.plist" ]]; then
        # No VERSION file (an unpacked payload, say): fall back to the bundle and
        # say so, rather than pretending the tree named a version.
        VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$APP/Contents/Info.plist" 2>/dev/null || true)"
        VERSION_SOURCE="app bundle (no VERSION file)"
    fi
fi

[[ -n "$PKG" ]] || PKG="$ROOT_DIR/dist/SoundBridge-${VERSION:-unknown}.pkg"
[[ -n "$DMG" ]] || DMG="$ROOT_DIR/dist/SoundBridge-${VERSION:-unknown}.dmg"

if [[ "$PRINT_TARGETS" -eq 1 ]]; then
    echo "VERSION=$VERSION"
    echo "VERSION_SOURCE=$VERSION_SOURCE"
    echo "APP=$APP"
    echo "PKG=$PKG"
    echo "DMG=$DMG"
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/soundbridge-payload.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The version the app bundle itself declares. Kept separate from $VERSION so the
# VERSION_CONSISTENCY stage can report a stale bundle instead of inheriting it.
APP_BUNDLE_VERSION=""
if [[ -f "$APP/Contents/Info.plist" ]]; then
    APP_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP/Contents/Info.plist" 2>/dev/null || true)"
fi

echo "SoundBridge release payload verification"
echo "  app:     $APP"
echo "  version: ${VERSION:-<unknown>} (from ${VERSION_SOURCE:-nowhere})"
echo "  pkg:     $PKG"
echo "  dmg:     $DMG"
echo ""

# --- stage bookkeeping ------------------------------------------------------
# bash 3.2 (the one macOS ships) has no associative arrays, so results are kept
# in plain variables addressed through eval.
STAGE_RESULT_PKG_STRUCTURE=NOT_VERIFIED
STAGE_RESULT_DRIVER_CONSISTENCY=NOT_VERIFIED
STAGE_RESULT_PKG_ARCHITECTURE=NOT_VERIFIED
STAGE_RESULT_DMG_STRUCTURE=NOT_VERIFIED
STAGE_RESULT_DMG_ARCHITECTURE=NOT_VERIFIED
STAGE_RESULT_APP_BUNDLE_ARCHITECTURE=NOT_VERIFIED
STAGE_RESULT_VERSION_CONSISTENCY=NOT_VERIFIED
STAGE_RESULT_ARTIFACT_INTEGRITY=NOT_VERIFIED

stage_set() { eval "STAGE_RESULT_$1=\$2"; }
stage_get() { eval "printf '%s' \"\${STAGE_RESULT_$1:-NOT_VERIFIED}\""; }
stage_log() { printf '%s' "$WORK/$1.log"; }

header() { echo "── $1 ─────────────────────────────────────────────"; }

# run_stage <name> SKIP <reason> | <name> <command...>
run_stage() {
    local name="$1"; shift
    local log rc=0

    header "$name"
    if [[ "$1" == "SKIP" ]]; then
        echo "NOT_VERIFIED: $2"
        stage_set "$name" NOT_VERIFIED
        echo ""
        return
    fi

    log="$(stage_log "$name")"
    "$@" > "$log" 2>&1 || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        stage_set "$name" PASS
        echo "PASS"
    else
        stage_set "$name" FAIL
        echo "FAIL (exit $rc)"
        if [[ "$VERBOSE" -eq 1 ]]; then
            sed 's/^/    /' "$log"
        else
            grep -E '^(FAIL|error|WARNING)' "$log" 2>/dev/null | head -20 | sed 's/^/    /'
            tail -5 "$log" | sed 's/^/    /'
        fi
    fi
    echo ""
}

stage_value() {  # stage_value <log> <KEY=> ; prints the value after the first match
    local log="$1" key="$2"
    [[ -f "$log" ]] || return 0
    awk -v k="$key" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$log"
}

# --- image stages first -----------------------------------------------------
# The driver inside the image exists only while the image is mounted. This stage
# writes down what it found; the driver comparison below reads that file.
IMAGE_DRIVER_REPORT="$WORK/image-driver.report"

if [[ "$SKIP_DMG" -eq 1 ]]; then
    run_stage DMG_STRUCTURE SKIP "--skip-dmg was given"
    run_stage DMG_ARCHITECTURE SKIP "--skip-dmg was given"
elif [[ ! -f "$DMG" ]]; then
    run_stage DMG_STRUCTURE SKIP "no disk image at $DMG"
    run_stage DMG_ARCHITECTURE SKIP "no disk image at $DMG"
else
    run_stage DMG_STRUCTURE "$ROOT_DIR/tools/verify_dmg_contents.sh" --expect-version "$VERSION" \
        --driver-report "$IMAGE_DRIVER_REPORT" "$DMG"

    header "DMG_ARCHITECTURE"
    DMG_ARCH_LINE="$(stage_value "$(stage_log DMG_STRUCTURE)" 'ARCHITECTURE=')"
    if [[ "$DMG_ARCH_LINE" == "PASS" ]]; then
        if [[ "$(stage_get DMG_STRUCTURE)" == "PASS" ]]; then
            echo "PASS (from DMG_STRUCTURE)"
        else
            echo "PASS (structure checks failed, architectures did not)"
        fi
        stage_set DMG_ARCHITECTURE PASS
    elif [[ -n "$DMG_ARCH_LINE" ]]; then
        echo "FAIL ($DMG_ARCH_LINE)"
        stage_set DMG_ARCHITECTURE FAIL
    else
        echo "NOT_VERIFIED (the image check did not reach its architecture block)"
        stage_set DMG_ARCHITECTURE NOT_VERIFIED
    fi
    echo ""
fi

# --- package stages ---------------------------------------------------------
if [[ "$SKIP_PKG" -eq 1 ]]; then
    run_stage PKG_STRUCTURE SKIP "--skip-pkg was given"
    run_stage DRIVER_CONSISTENCY SKIP "--skip-pkg was given"
    run_stage PKG_ARCHITECTURE SKIP "--skip-pkg was given"
elif [[ ! -f "$PKG" ]]; then
    run_stage PKG_STRUCTURE SKIP "no package at $PKG"
    run_stage DRIVER_CONSISTENCY SKIP "no package at $PKG"
    run_stage PKG_ARCHITECTURE SKIP "no package at $PKG"
else
    run_stage PKG_STRUCTURE "$ROOT_DIR/tools/verify_installer_pkg.sh" "$PKG"
    # Four copies have to be one driver: the package's two, the bundle in dist/
    # the image is built from, and the driver inside the mounted image. Without
    # the bundle in dist/ there is nothing to compare the package to, and that is
    # NOT_VERIFIED rather than a pass.
    if [[ ! -d "$APP" ]]; then
        run_stage DRIVER_CONSISTENCY SKIP "no app bundle at $APP; the package cannot be compared against what the image is built from"
    elif [[ "$SKIP_DMG" -eq 0 && -f "$DMG" ]]; then
        run_stage DRIVER_CONSISTENCY "$ROOT_DIR/tools/verify_pkg_contents.sh" --app "$APP" \
            --image-report "$IMAGE_DRIVER_REPORT" "$PKG"
        # The package's own copies can be fine while the fourth one was never
        # read (a corrupt image, a failed mount). That is missing evidence, not
        # a difference, and the report says NOT_VERIFIED -- so does the stage.
        if [[ "$(stage_value "$(stage_log DRIVER_CONSISTENCY)" 'DRIVER_FOUR_WAY_MATCH=')" == "NOT_VERIFIED" ]]; then
            echo "    the package copies were read; the copy inside the image was not"
            stage_set DRIVER_CONSISTENCY NOT_VERIFIED
        fi
    else
        run_stage DRIVER_CONSISTENCY "$ROOT_DIR/tools/verify_pkg_contents.sh" --app "$APP" "$PKG"
    fi

    header "PKG_ARCHITECTURE"
    if [[ "$(stage_get DRIVER_CONSISTENCY)" != "PASS" ]]; then
        echo "NOT_VERIFIED (the package check did not complete)"
        stage_set PKG_ARCHITECTURE NOT_VERIFIED
    elif [[ "$(stage_value "$(stage_log DRIVER_CONSISTENCY)" 'ARCHITECTURE=')" == "PASS" ]]; then
        echo "PASS (from DRIVER_CONSISTENCY)"
        stage_set PKG_ARCHITECTURE PASS
    else
        echo "FAIL (the package check reported ARCHITECTURE=FAIL)"
        stage_set PKG_ARCHITECTURE FAIL
    fi
    echo ""
fi

# --- the app bundle the two artifacts were built from -----------------------
if [[ -d "$APP/Contents/Resources/SoundBridgeDriver.driver" ]]; then
    run_stage APP_BUNDLE_ARCHITECTURE "$ROOT_DIR/tools/verify_release_bundle.sh" \
        "$APP/Contents/Resources/SoundBridgeDriver.driver" "$VERSION"
else
    run_stage APP_BUNDLE_ARCHITECTURE SKIP "no driver bundle under $APP"
fi

# --- version consistency ----------------------------------------------------
# Five version sources, and they are not the same kind of evidence:
#
#   app bundle      Bundle Verified   CFBundleShortVersionString inside the image
#   driver bundle   Bundle Verified   the driver's own Info.plist inside the image
#   host            Source Verified   packages/host/Info.plist; the shipped host is
#                                     a bare executable with no __info_plist section
#   protocol        Bundle Verified   the driver's Info.plist, against the header
#   file names      Name Verified     the two names on disk
#
# Nothing here is Binary Verified: no product version string is read out of a
# Mach-O binary by this pipeline, and the host is reported as its source version
# rather than as a fact about the binary.
header "VERSION_CONSISTENCY"
VERSION_FAILURES=0
VERSION_UNKNOWN=0
PKG_LOG="$(stage_log DRIVER_CONSISTENCY)"
DMG_LOG="$(stage_log DMG_STRUCTURE)"
PKG_APP_VERSION="$(stage_value "$PKG_LOG" 'PKG_APP_VERSION=')"
PKG_DRIVER_VERSION="$(stage_value "$PKG_LOG" 'PKG_DRIVER_VERSION=')"
HOST_SOURCE_VERSION="$(stage_value "$DMG_LOG" 'HOST_SOURCE_VERSION=')"
HOST_VERSION_EVIDENCE="$(stage_value "$DMG_LOG" 'HOST_VERSION_EVIDENCE=')"

if [[ -z "$VERSION" ]]; then
    echo "    the app bundle declares no version"
    VERSION_UNKNOWN=1
else
    # The bundle in dist/ is no longer the selector, so it is checked like any
    # other copy: a 1.1.1 bundle sitting next to 1.2.0 artifacts is a FAIL here
    # instead of quietly naming the release.
    if [[ -n "$APP_BUNDLE_VERSION" && "$APP_BUNDLE_VERSION" != "$VERSION" ]]; then
        echo "    app bundle version '$APP_BUNDLE_VERSION' != $VERSION (stale bundle in dist/)"
        VERSION_FAILURES=$((VERSION_FAILURES + 1))
    fi
    if [[ "$PKG_APP_VERSION" != "$VERSION" ]]; then
        echo "    package app version '${PKG_APP_VERSION:-<unknown>}' != $VERSION"
        VERSION_FAILURES=$((VERSION_FAILURES + 1))
    fi
    if [[ "$PKG_DRIVER_VERSION" != "$VERSION" ]]; then
        echo "    package driver version '${PKG_DRIVER_VERSION:-<unknown>}' != $VERSION"
        VERSION_FAILURES=$((VERSION_FAILURES + 1))
    fi
    if [[ "$(basename "$PKG")" != "SoundBridge-$VERSION.pkg" ]]; then
        echo "    package name '$(basename "$PKG")' is not SoundBridge-$VERSION.pkg"
        VERSION_FAILURES=$((VERSION_FAILURES + 1))
    fi
    if [[ -n "$HOST_SOURCE_VERSION" && "$HOST_SOURCE_VERSION" != "$VERSION" ]]; then
        echo "    host source version '$HOST_SOURCE_VERSION' != $VERSION (source-level evidence)"
        VERSION_FAILURES=$((VERSION_FAILURES + 1))
    fi
    if [[ "$(basename "$DMG")" != "SoundBridge-$VERSION.dmg" ]]; then
        echo "    disk image name '$(basename "$DMG")' is not SoundBridge-$VERSION.dmg"
        VERSION_FAILURES=$((VERSION_FAILURES + 1))
    fi
fi

if [[ "$(stage_get DRIVER_CONSISTENCY)" != "PASS" || "$(stage_get DMG_STRUCTURE)" != "PASS" ]]; then
    echo "    the checks that read the versions inside the artifacts did not all pass"
    VERSION_UNKNOWN=1
fi

# A passed DMG check that reported no host source version means the value could
# not be read, not that it agreed. Saying PASS then would be an empty comparison.
if [[ "$(stage_get DMG_STRUCTURE)" == "PASS" && -z "$HOST_SOURCE_VERSION" ]]; then
    echo "    the image check ran but reported no host source version"
    VERSION_UNKNOWN=1
fi

if [[ "$VERSION_FAILURES" -gt 0 ]]; then
    echo "FAIL"
    stage_set VERSION_CONSISTENCY FAIL
elif [[ "$VERSION_UNKNOWN" -gt 0 ]]; then
    echo "NOT_VERIFIED"
    stage_set VERSION_CONSISTENCY NOT_VERIFIED
else
    echo "PASS (app $VERSION, driver $PKG_DRIVER_VERSION, host source $HOST_SOURCE_VERSION, both file names)"
    stage_set VERSION_CONSISTENCY PASS
fi
echo "    host: ${HOST_VERSION_EVIDENCE:-<not read>}${HOST_SOURCE_VERSION:+ (source declares $HOST_SOURCE_VERSION)}"
echo "    nothing here is Binary Verified: the versions come from bundles, the source tree and file names"
echo ""

# --- artifact integrity -----------------------------------------------------
# The two files as they sit in dist/: present, non-empty, hashed. The hashes are
# printed so the numbers in the report can be recomputed by hand.
header "ARTIFACT_INTEGRITY"
INTEGRITY_FAILURES=0
INTEGRITY_UNKNOWN=0

for artifact in "$PKG" "$DMG"; do
    label="$(basename "$artifact")"
    if [[ ! -f "$artifact" ]]; then
        echo "    $label is not in dist/"
        INTEGRITY_UNKNOWN=$((INTEGRITY_UNKNOWN + 1))
    elif [[ "$(/usr/bin/stat -f '%z' "$artifact")" -le 0 ]]; then
        echo "    $label is empty"
        INTEGRITY_FAILURES=$((INTEGRITY_FAILURES + 1))
    else
        echo "    $label"
        echo "      size:   $(/usr/bin/stat -f '%z' "$artifact") bytes"
        echo "      sha256: $(/usr/bin/shasum -a 256 "$artifact" | awk '{print $1}')"
    fi
done

if [[ "$SKIP_PKG" -eq 1 || "$SKIP_DMG" -eq 1 ]]; then
    echo "    a stage was skipped, so this is not a full payload"
    INTEGRITY_UNKNOWN=$((INTEGRITY_UNKNOWN + 1))
fi

if [[ "$INTEGRITY_FAILURES" -gt 0 ]]; then
    echo "FAIL"
    stage_set ARTIFACT_INTEGRITY FAIL
elif [[ "$INTEGRITY_UNKNOWN" -gt 0 ]]; then
    echo "NOT_VERIFIED"
    stage_set ARTIFACT_INTEGRITY NOT_VERIFIED
else
    echo "PASS (both artifacts present, non-empty and hashed)"
    stage_set ARTIFACT_INTEGRITY PASS
fi
echo ""

# --- summary ----------------------------------------------------------------
combine() {  # combine <stage>...: FAIL wins, then NOT_VERIFIED, else PASS
    local s r
    for s in "$@"; do
        r="$(stage_get "$s")"
        [[ "$r" == "FAIL" ]] && { echo FAIL; return; }
    done
    for s in "$@"; do
        r="$(stage_get "$s")"
        [[ "$r" == "NOT_VERIFIED" ]] && { echo NOT_VERIFIED; return; }
    done
    echo PASS
}

ARCH_ALL="$(combine PKG_ARCHITECTURE DMG_ARCHITECTURE APP_BUNDLE_ARCHITECTURE)"
FOUR_WAY="$(stage_value "$(stage_log DRIVER_CONSISTENCY)" 'DRIVER_FOUR_WAY_MATCH=')"

# Which copies took part, in the words of the stage that compared them, so the
# summary does not claim a four-way result for a run that compared three.
echo "Summary"
echo "  PKG_STRUCTURE=$(stage_get PKG_STRUCTURE)"
echo "  DRIVER_CONSISTENCY=$(stage_get DRIVER_CONSISTENCY)"
echo "  DRIVER_FOUR_WAY=${FOUR_WAY:-NOT_VERIFIED}"
echo "  ARCHITECTURE=$ARCH_ALL"
echo "  DMG_STRUCTURE=$(stage_get DMG_STRUCTURE)"
echo "  VERSION_CONSISTENCY=$(stage_get VERSION_CONSISTENCY)"
echo "  ARTIFACT_INTEGRITY=$(stage_get ARTIFACT_INTEGRITY)"
echo ""

OVERALL="$(combine PKG_STRUCTURE DRIVER_CONSISTENCY PKG_ARCHITECTURE \
                   DMG_STRUCTURE DMG_ARCHITECTURE APP_BUNDLE_ARCHITECTURE \
                   VERSION_CONSISTENCY ARTIFACT_INTEGRITY)"
echo "OVERALL_RESULT=$OVERALL"

if command -v create-dmg >/dev/null 2>&1; then
    echo "NOTE create-dmg backend: installed here; the image in dist/ came from whichever backend built it"
else
    echo "NOTE create-dmg backend: not installed here; only the hdiutil backend could have built this image"
fi
echo "NOTE read-only check: nothing was installed and no driver was touched"

[[ "$OVERALL" == "PASS" ]] || exit 1
