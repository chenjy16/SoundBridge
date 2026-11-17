#!/bin/bash
#
# Create the distribution DMG for SoundBridge.
#
# Naming
# ------
# The file is versioned: dist/SoundBridge-<version>.dmg. The version is read from
# the bundle's CFBundleShortVersionString unless --version/APP_VERSION says
# otherwise, so the name cannot claim a version the app does not have.
#
# Which bundle
# ------------
# $APP_BUNDLE, default dist/SoundBridge.app. `make dmg` passes its own APP_BUNDLE
# down, and `dmg-precheck` validates that same variable: the bundle that is
# checked and the bundle that is packaged are the same one by construction.
#
# Failing without losing the previous DMG
# ---------------------------------------
# Neither backend writes into dist/SoundBridge-<version>.dmg directly. The
# archive is built inside dist/.dmg-staging.$$/ and moved into place only after a
# DMG exists there and is not empty. A failed run therefore leaves whatever
# dist/ already held exactly as it was, instead of deleting the release first and
# discovering the failure afterwards.
#
# Usage
#   tools/create_dmg.sh                                  # dist/SoundBridge.app -> dist/SoundBridge-<version>.dmg
#   tools/create_dmg.sh --app dist/Other.app             # package a different bundle
#   tools/create_dmg.sh --backend hdiutil                # skip create-dmg even if installed
#   APP_BUNDLE=dist/Other.app tools/create_dmg.sh        # same, via the environment
#
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# SB_DIST_DIR lets the test suite package into a scratch directory instead of
# writing a test image into dist/, which is the real publication path.
DIST_DIR="${SB_DIST_DIR:-$PROJECT_ROOT/dist}"
BACKGROUND_IMG="$SCRIPT_DIR/dmg/dmg-background.png"

APP_BUNDLE="${APP_BUNDLE:-$DIST_DIR/SoundBridge.app}"
APP_VERSION="${APP_VERSION:-}"
BACKEND="${DMG_BACKEND:-auto}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)      APP_BUNDLE="$2"; shift 2 ;;
        --version)  APP_VERSION="$2"; shift 2 ;;
        --backend)  BACKEND="$2"; shift 2 ;;
        -h|--help)  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

fail() {
    echo -e "${RED}ERROR: $*${NC}" >&2
    exit 1
}

echo -e "${BLUE}----------------------------------------${NC}"
echo -e "${BLUE}  Creating SoundBridge DMG${NC}"
echo -e "${BLUE}----------------------------------------${NC}"

# --- the bundle being packaged ----------------------------------------------
if [ ! -d "$APP_BUNDLE" ]; then
    fail "SoundBridge.app not found at $APP_BUNDLE\nRun 'make bundle' first"
fi
[ -f "$APP_BUNDLE/Contents/Info.plist" ] \
    || fail "$APP_BUNDLE has no Contents/Info.plist; it is not an app bundle"

if [ -z "$APP_VERSION" ]; then
    APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
fi
[ -n "$APP_VERSION" ] \
    || fail "could not read CFBundleShortVersionString from $APP_BUNDLE; pass --version"

DMG_NAME="SoundBridge-$APP_VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

STAGE_DIR="$DIST_DIR/.dmg-staging.$$"
STAGING_DMG="$STAGE_DIR/$DMG_NAME"

cleanup() {
    rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# --- backend ----------------------------------------------------------------
if [ "$BACKEND" = "auto" ]; then
    if command -v create-dmg > /dev/null 2>&1; then
        BACKEND="create-dmg"
    else
        BACKEND="hdiutil"
    fi
fi

echo "INFO: app bundle: $APP_BUNDLE"
echo "INFO: version:    $APP_VERSION"
echo "INFO: DMG:        $DMG_PATH"

if [ "$BACKEND" = "create-dmg" ] && ! command -v create-dmg > /dev/null 2>&1; then
    echo -e "${YELLOW}  create-dmg was requested but is not installed; using hdiutil${NC}"
    BACKEND="hdiutil"
fi

case "$BACKEND" in
    create-dmg|hdiutil) : ;;
    *) fail "unknown backend '$BACKEND' (expected create-dmg, hdiutil or auto)" ;;
esac

if [ "$BACKEND" = "hdiutil" ]; then
    echo -e "${YELLOW}  Using the hdiutil backend (basic layout, no background image)${NC}"
    SRC_DIR="$STAGE_DIR/src"
    mkdir -p "$SRC_DIR"
    cp -R "$APP_BUNDLE" "$SRC_DIR/SoundBridge.app"
    ln -s /Applications "$SRC_DIR/Applications"
    /usr/bin/hdiutil create \
        -volname "SoundBridge" \
        -srcfolder "$SRC_DIR" \
        -format UDZO -fs HFS+ \
        "$STAGING_DMG" \
        || fail "hdiutil could not create the image (its own error is above).\nNothing in $DIST_DIR was replaced."
else
    if [ -f "$BACKGROUND_IMG" ]; then
        echo "INFO: Using custom background: $BACKGROUND_IMG"
        BACKGROUND_ARG="--background $BACKGROUND_IMG"
    else
        echo -e "${YELLOW}  Background image not found at $BACKGROUND_IMG${NC}"
        echo "Creating DMG without custom background..."
        BACKGROUND_ARG=""
    fi

    echo " Creating DMG with custom layout..."
    create-dmg \
        --volname "SoundBridge" \
        $BACKGROUND_ARG \
        --window-pos 200 120 \
        --window-size 660 450 \
        --icon-size 100 \
        --icon "SoundBridge.app" 210 220 \
        --app-drop-link 455 220 \
        --hide-extension "SoundBridge.app" \
        --no-internet-enable \
        "$STAGING_DMG" \
        "$APP_BUNDLE" \
        || fail "create-dmg could not create the image (its own error is above).\nNothing in $DIST_DIR was replaced."
fi

# --- only now is the published file touched ---------------------------------
if [ ! -f "$STAGING_DMG" ]; then
    fail "the $BACKEND backend exited successfully but produced no DMG at $STAGING_DMG\nNothing in $DIST_DIR was replaced."
fi

DMG_BYTES="$(/usr/bin/stat -f%z "$STAGING_DMG")"
if [ "$DMG_BYTES" -le 0 ]; then
    fail "the $BACKEND backend produced an empty DMG at $STAGING_DMG\nNothing in $DIST_DIR was replaced."
fi

mv -f "$STAGING_DMG" "$DMG_PATH"

echo ""
echo -e "${GREEN}OK: DMG created successfully!${NC}"
echo ""
echo "DMG_PATH=$DMG_PATH"
echo "DMG_BACKEND=$BACKEND"
echo "DMG_VERSION=$APP_VERSION"
echo "DMG_SHA256=$(/usr/bin/shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "DMG_SIZE=$DMG_BYTES"
echo "Location: $DMG_PATH"
echo "Size: $(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "Next steps:"
echo "  - Verify:  tools/verify_dmg_contents.sh \"$DMG_PATH\""
echo "  - Test:    open \"$DMG_PATH\""
echo "  - Publish: attach the DMG to a GitHub release"
echo ""
