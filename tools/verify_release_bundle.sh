#!/usr/bin/env bash
#
# Release guard for the driver that actually ships.
#
# `make protocol-check` proves the *source* Info.plist agrees with the protocol
# header. That is necessary and not sufficient: the driver bundle is produced by
# CMake from `MACOSX_BUNDLE_INFO_PLIST`, then copied into
# `SoundBridge.app/Contents/Resources/` by `create_app_bundle.sh`. A stale
# `packages/driver/build/` directory, or a packaging step that copies the wrong
# things, reproduces every source-level check while shipping a driver that the
# app will reject on install — or worse, one the app accepts and the driver then
# refuses at `OnStartIO` because its protocol version differs.
#
# So this script reads the finished `.app` bundle, not the sources.
#
# Usage:
#   tools/verify_release_bundle.sh [path-to-driver.driver] [expected-version]
#
# Defaults to dist/SoundBridge.app/Contents/Resources/SoundBridgeDriver.driver.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BUNDLE="${1:-$ROOT/dist/SoundBridge.app/Contents/Resources/SoundBridgeDriver.driver}"
EXPECTED_VERSION="${2:-${EXPECTED_VERSION:-}}"

HEADER="$ROOT/packages/shared/include/RFSharedAudio.h"
SOURCE_PLIST="$ROOT/packages/driver/Info.plist"
PLIST="$BUNDLE/Contents/Info.plist"

failures=0
check_fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

plist_read() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo ""
}

echo "Release driver bundle check"
echo "==========================="
echo "Bundle: $BUNDLE"
echo ""

# ── 1. The bundle exists where the app looks for it ──────────────────────────
#
# `DriverInstaller.findDriverBundle()` looks in Bundle.main.resourcePath for
# "SoundBridgeDriver.driver". A bundle anywhere else is not shipped.
if [[ ! -d "$BUNDLE" ]]; then
    echo "FAIL: driver bundle not found: $BUNDLE" >&2
    echo "      Run 'make bundle' (or 'make build') first." >&2
    exit 1
fi

if [[ "$(basename "$BUNDLE")" != "SoundBridgeDriver.driver" ]]; then
    check_fail "bundle is named '$(basename "$BUNDLE")'; the app looks for SoundBridgeDriver.driver"
fi

if [[ ! -f "$PLIST" ]]; then
    echo "FAIL: bundle has no Contents/Info.plist: $PLIST" >&2
    exit 1
fi

if ! plutil -lint "$PLIST" >/dev/null; then
    echo "FAIL: Contents/Info.plist is not a valid property list: $PLIST" >&2
    exit 1
fi

# ── 2. Identity ──────────────────────────────────────────────────────────────
BUNDLE_ID="$(plist_read CFBundleIdentifier)"
if [[ "$BUNDLE_ID" != "com.soundbridge.driver" ]]; then
    check_fail "CFBundleIdentifier is '${BUNDLE_ID:-<missing>}', expected com.soundbridge.driver"
fi

# ── 3. The executable the plist points at must be inside the bundle ─────────
EXECUTABLE="$(plist_read CFBundleExecutable)"
EXEC_PATH="$BUNDLE/Contents/MacOS/${EXECUTABLE:-<missing>}"
if [[ -z "$EXECUTABLE" ]]; then
    check_fail "CFBundleExecutable is missing"
elif [[ ! -f "$EXEC_PATH" ]]; then
    check_fail "CFBundleExecutable '$EXECUTABLE' is not at Contents/MacOS/"
elif [[ ! -x "$EXEC_PATH" ]]; then
    check_fail "Contents/MacOS/$EXECUTABLE is not executable"
elif ! file -b "$EXEC_PATH" | grep -q "Mach-O"; then
    check_fail "Contents/MacOS/$EXECUTABLE is not a Mach-O binary ($(file -b "$EXEC_PATH"))"
fi

# ── 4. Versions ─────────────────────────────────────────────────────────────
SHORT_VERSION="$(plist_read CFBundleShortVersionString)"
BUNDLE_VERSION="$(plist_read CFBundleVersion)"

if [[ -z "$SHORT_VERSION" ]]; then
    check_fail "CFBundleShortVersionString is missing or empty"
elif ! [[ "$SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    check_fail "CFBundleShortVersionString '$SHORT_VERSION' is not a dotted numeric version"
fi

if [[ -z "$BUNDLE_VERSION" ]]; then
    check_fail "CFBundleVersion is missing or empty"
elif [[ -n "$SHORT_VERSION" && "$BUNDLE_VERSION" != "$SHORT_VERSION" ]]; then
    # The project writes both from the same tag; a divergence means one of them
    # was edited by hand and the installer's version comparison is now reading a
    # different number than the release notes.
    check_fail "CFBundleVersion '$BUNDLE_VERSION' != CFBundleShortVersionString '$SHORT_VERSION'"
fi

if [[ -n "$EXPECTED_VERSION" && -n "$SHORT_VERSION" && "$SHORT_VERSION" != "$EXPECTED_VERSION" ]]; then
    check_fail "bundle version '$SHORT_VERSION' != expected '$EXPECTED_VERSION'"
fi

# ── 5. Protocol version: bundle vs header vs source plist ───────────────────
#
# The header is the single source of truth. The App compiles the same constant,
# so a bundle that matches the header also matches what the app will demand.
HEADER_HEX="$(sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+RF_AUDIO_PROTOCOL_VERSION[[:space:]]+(0x[0-9A-Fa-f]+)[uUlL]*.*$/\1/p' "$HEADER" | head -n 1)"
if [[ -z "$HEADER_HEX" ]]; then
    echo "FAIL: could not read RF_AUDIO_PROTOCOL_VERSION from $HEADER" >&2
    exit 1
fi
HEADER_DEC=$((HEADER_HEX))

BUNDLE_PROTOCOL="$(plist_read SBAudioProtocolVersion)"
if [[ -z "$BUNDLE_PROTOCOL" ]]; then
    # A driver with no declared protocol is treated by the gate as "compare
    # versions only". That is right for third-party legacy drivers, and wrong for
    # one this build just produced: it means the plist the bundler copied was
    # older than the feature.
    check_fail "bundled driver has no SBAudioProtocolVersion; the gate would fall back to version-only comparison"
elif ! [[ "$BUNDLE_PROTOCOL" =~ ^[0-9]+$ ]]; then
    check_fail "SBAudioProtocolVersion '$BUNDLE_PROTOCOL' is not a non-negative integer"
elif [[ "$BUNDLE_PROTOCOL" != "$HEADER_DEC" ]]; then
    check_fail "bundled SBAudioProtocolVersion=$BUNDLE_PROTOCOL != header $HEADER_HEX ($HEADER_DEC); the app would reject this driver"
fi

SOURCE_PROTOCOL="$(/usr/libexec/PlistBuddy -c "Print :SBAudioProtocolVersion" "$SOURCE_PLIST" 2>/dev/null || echo "")"
if [[ -n "$SOURCE_PROTOCOL" && "$SOURCE_PROTOCOL" != "$BUNDLE_PROTOCOL" ]]; then
    check_fail "bundle protocol '$BUNDLE_PROTOCOL' != source plist '$SOURCE_PROTOCOL'; packages/driver/build is stale"
fi

# ── 6. The app's own header copy must agree too ─────────────────────────────
#
# DriverVersionGate derives its expected value from the App's compiled copy of
# the header. `sync_shared_header.sh --check` proves the copies are identical;
# this proves the number the guard just validated is the one the app will use.
for copy in \
    "$ROOT/apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h" \
    "$ROOT/packages/driver/include/RFSharedAudio.h" \
    "$ROOT/packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h"; do
    if [[ ! -f "$copy" ]]; then
        check_fail "protocol header copy missing: $copy"
        continue
    fi
    COPY_HEX="$(sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+RF_AUDIO_PROTOCOL_VERSION[[:space:]]+(0x[0-9A-Fa-f]+)[uUlL]*.*$/\1/p' "$copy" | head -n 1)"
    if [[ "$COPY_HEX" != "$HEADER_HEX" ]]; then
        check_fail "${copy#"$ROOT"/} declares ${COPY_HEX:-<missing>} but the source says $HEADER_HEX"
    fi
done

# ── 7. Universal binary ─────────────────────────────────────────────────────
#
# The release ships a universal app; a single-architecture driver would fail to
# load for half the users, and HAL reports that as "device missing" rather than
# as an architecture problem.
if [[ -f "$EXEC_PATH" ]] && command -v lipo >/dev/null 2>&1; then
    ARCHS="$(lipo -archs "$EXEC_PATH" 2>/dev/null || echo "")"
    for required in arm64 x86_64; do
        if ! [[ " $ARCHS " == *" $required "* ]]; then
            check_fail "driver binary is missing $required (has: ${ARCHS:-<unknown>})"
        fi
    done
fi

# ── 8. The app and the host next to it ──────────────────────────────────
#
# The driver is not the only binary in the bundle that has to be universal.
# `create_app_bundle.sh` prints the architectures with `lipo -archs` and then
# moves on, so a single-arch App or Host ships as a release and fails on half the
# machines — the second architecture's users get "the app is damaged" and the
# first one never notices. Checked here, before anything is signed.
APP_BUNDLE="$(cd "$(dirname "$BUNDLE")/../.." 2>/dev/null && pwd || true)"
if [[ -n "$APP_BUNDLE" && -d "$APP_BUNDLE/Contents/MacOS" ]] && command -v lipo >/dev/null 2>&1; then
    for binary in SoundBridgeApp SoundBridgeHost; do
        BIN_PATH="$APP_BUNDLE/Contents/MacOS/$binary"
        if [[ ! -f "$BIN_PATH" ]]; then
            check_fail "$binary is missing from Contents/MacOS"
            continue
        fi
        BIN_ARCHS="$(lipo -archs "$BIN_PATH" 2>/dev/null || echo "")"
        for required in arm64 x86_64; do
            if ! [[ " $BIN_ARCHS " == *" $required "* ]]; then
                check_fail "$binary is missing $required (has: ${BIN_ARCHS:-<unknown>})"
            fi
        done
    done

    # The app links @rpath/Sparkle.framework. A bundle that ships the executable
    # without the framework launches no further than dyld.
    if otool -L "$APP_BUNDLE/Contents/MacOS/SoundBridgeApp" 2>/dev/null | grep -q "Sparkle.framework"; then
        if [[ ! -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
            check_fail "SoundBridgeApp links Sparkle.framework but Contents/Frameworks does not ship it"
        fi
    fi

    # Sparkle is a fourth core binary: a framework whose executable only has the
    # build machine's architecture fails to load on the other one, and the app
    # reports that as "damaged" rather than as a missing slice.
    SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    if [[ -d "$SPARKLE_FW" ]]; then
        SPARKLE_EXE="$SPARKLE_FW/Versions/B/Sparkle"
        [[ -f "$SPARKLE_EXE" ]] || SPARKLE_EXE="$SPARKLE_FW/Versions/Current/Sparkle"
        if [[ ! -f "$SPARKLE_EXE" ]]; then
            check_fail "Sparkle.framework has no Versions/B or Versions/Current executable"
        else
            SPARKLE_ARCHS="$(lipo -archs "$SPARKLE_EXE" 2>/dev/null || echo "")"
            for required in arm64 x86_64; do
                if ! [[ " $SPARKLE_ARCHS " == *" $required "* ]]; then
                    check_fail "Sparkle is missing $required (has: ${SPARKLE_ARCHS:-<unknown>})"
                fi
            done
        fi
    fi
else
    echo "Note: no .app bundle next to the driver; skipped App/Host checks"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
if (( failures > 0 )); then
    echo "FAILED: $failures check(s) failed" >&2
    exit 1
fi

echo "Bundle id     : $BUNDLE_ID"
echo "Version       : $SHORT_VERSION"
echo "Protocol      : $BUNDLE_PROTOCOL ($HEADER_HEX)"
echo "Architectures : $(lipo -archs "$EXEC_PATH" 2>/dev/null || echo unknown)"
echo ""
echo "OK: final driver bundle matches the protocol header and the app's expectation"
