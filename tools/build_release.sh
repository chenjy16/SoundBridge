#!/bin/bash
# Master build script for SoundBridge release builds
# Builds all components as universal binaries (arm64 + x86_64)

set -e  # Exit on error
# Without pipefail a failing `swift build | tail -1` reports success, and the
# failure only surfaces two steps later as a confusing lipo error.
set -o pipefail
# `set -u` for the same reason the guard scripts use it: an empty path variable
# turns `cp "" ...` into a confusing error instead of a named one.
set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Where the bundle is written. The same variable create_app_bundle.sh reads, so
# the summary below names the directory that actually received the bundle
# instead of dist/ after a build that was pointed somewhere else.
DIST_DIR="${SB_DIST_DIR:-$PROJECT_ROOT/dist}"

echo "Building SoundBridge Release (Universal Binary)"
echo "==============================================="
echo ""

# Function to print section headers
section() {
    echo ""
    echo "----------------------------------------"
    echo "  $1"
    echo "----------------------------------------"
}

# Build a Swift package for both architectures and lipo into universal binary.
#
# One scratch path per architecture. SwiftPM 6.x no longer creates
# `.build/<triple>/release` for an explicit `--triple`; both builds land in the
# same `out/Products/Release`, so building the second arch in the default scratch
# directory overwrites the first. The lipo step then sees either the same file
# twice or nothing at all — which is exactly how a release ends up single-arch.
# Separate scratch dirs keep both products, and `--show-bin-path` asks SwiftPM
# where the product is instead of hard-coding a layout that keeps changing.
build_swift_universal() {
    local PACKAGE_DIR="$1"
    local PRODUCT_NAME="$2"

    cd "$PACKAGE_DIR"

    local ARM64_SCRATCH=".build/arm64"
    local X86_SCRATCH=".build/x86_64"

    echo "  Building arm64..."
    swift build -c release --triple arm64-apple-macosx \
        --scratch-path "$ARM64_SCRATCH" 2>&1 | tail -1

    echo "  Building x86_64..."
    swift build -c release --triple x86_64-apple-macosx \
        --scratch-path "$X86_SCRATCH" 2>&1 | tail -1

    local ARM64_DIR
    local X86_DIR
    ARM64_DIR="$(swift build -c release --triple arm64-apple-macosx \
        --scratch-path "$ARM64_SCRATCH" --show-bin-path)"
    X86_DIR="$(swift build -c release --triple x86_64-apple-macosx \
        --scratch-path "$X86_SCRATCH" --show-bin-path)"

    local ARM64_BIN="$ARM64_DIR/$PRODUCT_NAME"
    local X86_BIN="$X86_DIR/$PRODUCT_NAME"

    local bin
    for bin in "$ARM64_BIN" "$X86_BIN"; do
        if [ ! -f "$bin" ]; then
            echo "  Error: build product missing: $bin" >&2
            exit 1
        fi
    done

    local UNIVERSAL_DIR=".build/universal/release"
    local UNIVERSAL_BIN="$UNIVERSAL_DIR/$PRODUCT_NAME"

    mkdir -p "$UNIVERSAL_DIR"
    lipo -create -output "$UNIVERSAL_BIN" "$ARM64_BIN" "$X86_BIN"

    # Frameworks are build products too.
    #
    # SwiftPM drops `Sparkle.framework` next to the executable inside the scratch
    # directory. `create_app_bundle.sh` looks in `.build/universal/release` first
    # and in the legacy `.build/release` second; on a clean checkout neither holds
    # a framework, because every build here uses a per-arch scratch path. The app
    # then ships without the framework it links at `@rpath/Sparkle.framework` and
    # dies at launch with a dyld error — a failure that looks like a bad signature
    # and sends whoever debugs it to the wrong place. Staging them here keeps one
    # copy of the "where are the products" answer.
    local fw
    for fw in "$ARM64_DIR"/*.framework; do
        [ -d "$fw" ] || continue
        local fw_name
        fw_name="$(basename "$fw")"
        rm -rf "$UNIVERSAL_DIR/$fw_name"
        cp -R "$fw" "$UNIVERSAL_DIR/$fw_name"
        echo "  Staged $fw_name"
    done

    echo "  Architectures: $(lipo -archs "$UNIVERSAL_BIN")"
}

# 1. Build DSP Library (universal via CMAKE_OSX_ARCHITECTURES)
section "1/5 Building DSP Library (C++ universal)"
cd "$PROJECT_ROOT/packages/dsp"
mkdir -p build
cd build
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" ..
cmake --build . --config Release
echo "OK: DSP library built (universal)"

# 2. Build HAL Driver (universal via CMAKE_OSX_ARCHITECTURES)
section "2/5 Building HAL Driver (C++ universal)"
cd "$PROJECT_ROOT/packages/driver"
mkdir -p build
cd build
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" ..
cmake --build . --config Release
echo "OK: HAL driver built (universal)"

# 3. Build Audio Host (universal via build-twice + lipo)
section "3/5 Building Audio Host (Swift universal)"
build_swift_universal "$PROJECT_ROOT/packages/host" "SoundBridgeHost"
echo "OK: Audio host built (universal)"

# 4. Build Menu Bar App (universal via build-twice + lipo)
section "4/5 Building Menu Bar App (Swift universal)"
build_swift_universal "$PROJECT_ROOT/apps/mac/SoundBridgeApp" "SoundBridgeApp"
echo "OK: Menu bar app built (universal)"

# 5. Create .app Bundle
section "5/5 Creating .app Bundle"
cd "$PROJECT_ROOT"
"$SCRIPT_DIR/create_app_bundle.sh"

echo ""
echo "----------------------------------------"
echo "  Build Complete! (Universal Binary)"
echo "----------------------------------------"
echo ""
echo "App bundle: $DIST_DIR/SoundBridge.app"
echo ""
echo "Verify architectures:"
echo "  lipo -archs $DIST_DIR/SoundBridge.app/Contents/MacOS/SoundBridgeApp"
echo "  lipo -archs $DIST_DIR/SoundBridge.app/Contents/MacOS/SoundBridgeHost"
echo ""
echo "To test the app:"
echo "  open $DIST_DIR/SoundBridge.app"
echo ""
echo "To create a DMG:"
echo "  SB_DIST_DIR=$DIST_DIR tools/create_dmg.sh"
echo ""
