#!/bin/bash
# Generate the Sparkle appcast feed for the current release.
#
# The feed is uploaded next to the DMG in the GitHub release, which is why
# SUFeedURL points at:
#   https://github.com/chenjy16/SoundBridge/releases/latest/download/appcast.xml
# `releases/latest` always resolves to the newest published release, so the URL
# stays stable while the feed content follows the version.
#
# Requires:
#   SPARKLE_ED_PRIVATE_KEY_FILE  file holding the EdDSA private key
#                                (export one with `generate_keys -x <file>`)
#
# Optional:
#   SPARKLE_DOWNLOAD_URL_PREFIX  overrides the URL prefix of the DMG enclosure

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
ARCHIVE_DIR="$DIST_DIR/appcast"
DMG_PATH="$DIST_DIR/SoundBridge.dmg"
DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-https://github.com/chenjy16/SoundBridge/releases/latest/download/}"

# Sparkle ships its command line tools next to the SwiftPM artifact bundle.
SPARKLE_BIN_DIR="$(find "$PROJECT_ROOT/apps/mac/SoundBridgeApp/.build" \
    -type d -name bin -path "*sparkle*" 2>/dev/null | head -1)"
GENERATE_APPCAST="${SPARKLE_BIN_DIR:+$SPARKLE_BIN_DIR/generate_appcast}"

if [ ! -x "$GENERATE_APPCAST" ]; then
    echo "Error: Sparkle's generate_appcast was not found."
    echo "   Build the app first: swift build --package-path apps/mac/SoundBridgeApp"
    exit 1
fi

if [ -z "${SPARKLE_ED_PRIVATE_KEY_FILE:-}" ] || [ ! -f "${SPARKLE_ED_PRIVATE_KEY_FILE:-}" ]; then
    echo "Error: SPARKLE_ED_PRIVATE_KEY_FILE must point to the EdDSA private key file."
    echo "   Generate a key pair with Sparkle's generate_keys, then export the"
    echo "   private half with: generate_keys -x <file>"
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "Error: $DMG_PATH not found."
    echo "   Build the DMG first: ./tools/create_dmg.sh"
    exit 1
fi

# generate_appcast scans a directory of archives and writes appcast.xml into it,
# so stage a clean copy of just this release.
rm -rf "$ARCHIVE_DIR"
mkdir -p "$ARCHIVE_DIR"
cp "$DMG_PATH" "$ARCHIVE_DIR/"

echo "Generating appcast for $(basename "$DMG_PATH")"
echo "   Download prefix: $DOWNLOAD_URL_PREFIX"

"$GENERATE_APPCAST" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --ed-key-file "$SPARKLE_ED_PRIVATE_KEY_FILE" \
    "$ARCHIVE_DIR"

if [ ! -f "$ARCHIVE_DIR/appcast.xml" ]; then
    echo "Error: generate_appcast did not produce appcast.xml"
    exit 1
fi

# Sparkle only signs archives whose bundle declares SUPublicEDKey, and it
# silently emits an unsigned feed otherwise. An unsigned feed is useless to the
# app (every update fails verification), so refuse to ship one.
if ! grep -q "sparkle:edSignature" "$ARCHIVE_DIR/appcast.xml"; then
    echo "Error: appcast.xml has no EdDSA signature."
    echo "   Set SPARKLE_ED_PUBLIC_KEY when building the bundle so"
    echo "   SUPublicEDKey is present in Info.plist."
    exit 1
fi

echo ""
echo "Appcast written to $ARCHIVE_DIR/appcast.xml"
