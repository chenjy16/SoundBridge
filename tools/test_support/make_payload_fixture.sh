#!/bin/bash
#
# Build a synthetic release payload for the verifier tests (P4 Batch 1A).
#
# Why this exists
# ---------------
# tools/test_release_payload.sh used to take its fixtures from dist/. It copied,
# damaged and re-packed whatever release happened to sit there, which meant two
# things:
#
#   - the suite could not run on a tree whose dist/ was empty or held only older
#     releases, so it silently depended on a historical artifact staying put;
#   - the version under test was whatever that artifact happened to be, so the
#     assertions carried literals like 1.1.1 and 131328 that had nothing to do
#     with the tree being tested.
#
# This script builds the payload the tests damage instead. Nothing here reads
# dist/ and nothing is written there: the app, the driver and the framework are
# compiled stubs, and the .pkg/.dmg are produced by the same packagers a real
# release uses (tools/build_installer_pkg.sh, tools/create_dmg.sh) so the
# verifiers see a payload with the production layout rather than a hand-made
# directory tree.
#
# What the stub carries: a universal (arm64 + x86_64) Mach-O for the app, the
# host, the driver executable and Sparkle, the bundle identifiers the packager
# requires, the version it was told to use, and the protocol read from the shared
# header. It is not a working audio product and is never installed or run.
#
# Usage
#   tools/test_support/make_payload_fixture.sh <out-dir> <version>
#
# Writes
#   <out-dir>/SoundBridge.app
#   <out-dir>/SoundBridge-<version>.pkg
#   <out-dir>/SoundBridge-<version>.dmg
#   <out-dir>/SoundBridge-<version>.component.plist   (from the packager)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

OUT_DIR="${1:-}"
VERSION="${2:-}"
[[ -n "$OUT_DIR" && -n "$VERSION" ]] || {
    echo "usage: $0 <out-dir> <version>" >&2
    exit 2
}

HEADER="$ROOT_DIR/packages/shared/include/RFSharedAudio.h"
[[ -f "$HEADER" ]] || { echo "error: protocol header not found: $HEADER" >&2; exit 1; }
PROTOCOL_HEX="$(sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+RF_AUDIO_PROTOCOL_VERSION[[:space:]]+(0x[0-9A-Fa-f]+)[uUlL]*.*$/\1/p' "$HEADER" | head -n 1)"
[[ -n "$PROTOCOL_HEX" ]] || { echo "error: could not read RF_AUDIO_PROTOCOL_VERSION" >&2; exit 1; }
PROTOCOL="$(( 0x${PROTOCOL_HEX#0x} ))"

CLANG="$(xcrun --find clang 2>/dev/null || true)"
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
[[ -n "$CLANG" ]] || { echo "error: no clang; a universal stub cannot be built" >&2; exit 1; }
[[ -n "$SDK" ]] || { echo "error: no macOS SDK; a universal stub cannot be built" >&2; exit 1; }

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
WORK="$OUT_DIR/.fixture-build.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# --- one universal stub binary, copied to every role ------------------------
printf 'int main(void) { return 0; }\n' > "$WORK/stub.c"
"$CLANG" -isysroot "$SDK" -arch arm64 -arch x86_64 -mmacosx-version-min=14.4 \
    -o "$WORK/stub" "$WORK/stub.c"

ARCHS="$(/usr/bin/lipo -archs "$WORK/stub")"
case "$ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) : ;;
    *) echo "error: the stub is not universal: $ARCHS" >&2; exit 1 ;;
esac

plist() {   # <path> <key> <value>
    /usr/libexec/PlistBuddy -c "Add :$2 string $3" "$1" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1" >/dev/null
}
# --- app bundle -------------------------------------------------------------
APP="$OUT_DIR/SoundBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

APP_PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Clear dict' "$APP_PLIST" >/dev/null 2>&1 || true
plist "$APP_PLIST" CFBundleIdentifier com.soundbridge.menubar
plist "$APP_PLIST" CFBundleExecutable SoundBridgeApp
plist "$APP_PLIST" CFBundleName SoundBridge
plist "$APP_PLIST" CFBundlePackageType APPL
plist "$APP_PLIST" CFBundleShortVersionString "$VERSION"
plist "$APP_PLIST" CFBundleVersion "$VERSION"
plist "$APP_PLIST" LSMinimumSystemVersion 14.4

/bin/cp "$WORK/stub" "$APP/Contents/MacOS/SoundBridgeApp"
/bin/cp "$WORK/stub" "$APP/Contents/MacOS/SoundBridgeHost"
/bin/chmod 755 "$APP/Contents/MacOS/SoundBridgeApp" "$APP/Contents/MacOS/SoundBridgeHost"

# The shipped bundle carries its license and its third-party notices; the
# fixture does too, so the release guard's check for them is exercised on the
# fixture instead of failing every case that runs the guard.
for notice in LICENSE THIRD_PARTY_NOTICES.md; do
    /bin/cp "$ROOT_DIR/$notice" "$APP/Contents/Resources/$notice"
done

# --- driver bundle ----------------------------------------------------------
DRIVER="$APP/Contents/Resources/SoundBridgeDriver.driver"
mkdir -p "$DRIVER/Contents/MacOS"
DRIVER_PLIST="$DRIVER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Clear dict' "$DRIVER_PLIST" >/dev/null 2>&1 || true
plist "$DRIVER_PLIST" CFBundleIdentifier com.soundbridge.driver
plist "$DRIVER_PLIST" CFBundleExecutable SoundBridgeDriver
plist "$DRIVER_PLIST" CFBundleName SoundBridgeDriver
plist "$DRIVER_PLIST" CFBundlePackageType BNDL
plist "$DRIVER_PLIST" CFBundleShortVersionString "$VERSION"
plist "$DRIVER_PLIST" CFBundleVersion "$VERSION"
/usr/libexec/PlistBuddy -c "Add :SBAudioProtocolVersion integer $PROTOCOL" "$DRIVER_PLIST" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :SBAudioProtocolVersion $PROTOCOL" "$DRIVER_PLIST" >/dev/null
/bin/cp "$WORK/stub" "$DRIVER/Contents/MacOS/SoundBridgeDriver"
/bin/chmod 755 "$DRIVER/Contents/MacOS/SoundBridgeDriver"

# --- Sparkle.framework: the image check wants a framework with an executable --
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$SPARKLE/Versions/B"
/bin/cp "$WORK/stub" "$SPARKLE/Versions/B/Sparkle"
/bin/chmod 755 "$SPARKLE/Versions/B/Sparkle"
ln -s B "$SPARKLE/Versions/Current"
ln -s Versions/Current/Sparkle "$SPARKLE/Sparkle"

# --- package and image, through the real packagers --------------------------
PKG_OUT_LOG="$WORK/pkg.log"
"$ROOT_DIR/tools/build_installer_pkg.sh" \
    --app "$APP" --out "$OUT_DIR" --version "$VERSION" > "$PKG_OUT_LOG" 2>&1 || {
        echo "error: build_installer_pkg.sh failed; its output follows" >&2
        sed 's/^/      /' "$PKG_OUT_LOG" >&2
        exit 1
    }

DMG_OUT_LOG="$WORK/dmg.log"
SB_DIST_DIR="$OUT_DIR" "$ROOT_DIR/tools/create_dmg.sh" \
    --app "$APP" --version "$VERSION" --backend hdiutil > "$DMG_OUT_LOG" 2>&1 || {
        echo "error: create_dmg.sh failed; its output follows" >&2
        sed 's/^/      /' "$DMG_OUT_LOG" >&2
        exit 1
    }

PKG="$OUT_DIR/SoundBridge-$VERSION.pkg"
DMG="$OUT_DIR/SoundBridge-$VERSION.dmg"
[[ -f "$PKG" ]] || { echo "error: no package at $PKG" >&2; exit 1; }
[[ -f "$DMG" ]] || { echo "error: no image at $DMG" >&2; exit 1; }

echo "FIXTURE_VERSION=$VERSION"
echo "FIXTURE_PROTOCOL=$PROTOCOL"
echo "FIXTURE_APP=$APP"
echo "FIXTURE_PKG=$PKG"
echo "FIXTURE_DMG=$DMG"
