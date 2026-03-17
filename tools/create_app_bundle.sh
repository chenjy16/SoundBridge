#!/bin/bash
# Create proper .app bundle structure for SoundBridge
# Supports universal binaries (arm64 + x86_64)

set -e  # Exit on error

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="SoundBridge.app"
APP_PATH="$DIST_DIR/$APP_NAME"

# Helper: find a Swift build product, checking universal build path first,
# then architecture-specific paths, then generic path.
find_swift_product() {
    local PACKAGE_DIR="$1"
    local PRODUCT_NAME="$2"

    # 1. Universal build path (lipo'd by build_release.sh)
    local UNIVERSAL="$PACKAGE_DIR/.build/universal/release/$PRODUCT_NAME"
    if [ -f "$UNIVERSAL" ] || [ -d "$UNIVERSAL" ]; then
        echo "$UNIVERSAL"
        return
    fi

    # 1b. Universal build path (swift build --arch arm64 --arch x86_64)
    local APPLE_UNIVERSAL="$PACKAGE_DIR/.build/apple/Products/Release/$PRODUCT_NAME"
    if [ -f "$APPLE_UNIVERSAL" ] || [ -d "$APPLE_UNIVERSAL" ]; then
        echo "$APPLE_UNIVERSAL"
        return
    fi

    # 2. Architecture-specific path (single-arch build)
    local ARCH=$(uname -m)
    local SWIFT_ARCH=""
    if [ "$ARCH" = "arm64" ]; then
        SWIFT_ARCH="arm64-apple-macosx"
    elif [ "$ARCH" = "x86_64" ]; then
        SWIFT_ARCH="x86_64-apple-macosx"
    fi
    if [ -n "$SWIFT_ARCH" ]; then
        local ARCH_PATH="$PACKAGE_DIR/.build/$SWIFT_ARCH/release/$PRODUCT_NAME"
        if [ -f "$ARCH_PATH" ] || [ -d "$ARCH_PATH" ]; then
            echo "$ARCH_PATH"
            return
        fi
    fi

    # 3. Generic path
    local GENERIC="$PACKAGE_DIR/.build/release/$PRODUCT_NAME"
    if [ -f "$GENERIC" ] || [ -d "$GENERIC" ]; then
        echo "$GENERIC"
        return
    fi

    # Not found
    echo ""
}

echo "Creating SoundBridge.app bundle structure..."

# Clean and create dist directory
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Create .app bundle structure
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
mkdir -p "$APP_PATH/Contents/Resources/Presets"

echo "  Created bundle structure"

# Copy Info.plist
echo "  Copying Info.plist..."
cp "$PROJECT_ROOT/apps/mac/SoundBridgeApp/Info.plist" "$APP_PATH/Contents/Info.plist"
echo "  Info.plist copied"

# Copy app icon
echo "  Copying app icon..."
ICON_SOURCE="$PROJECT_ROOT/apps/mac/SoundBridgeApp/Sources/Resources/MyIcon.icns"
ICON_SIZES_DIR="$PROJECT_ROOT/apps/mac/SoundBridgeApp/Sources/Resources/icons"
ICON_DEST="$APP_PATH/Contents/Resources/MyIcon.icns"
if [ -d "$ICON_SIZES_DIR" ] && command -v iconutil >/dev/null 2>&1; then
    TMP_ICONSET="$(mktemp -d)/MyIcon.iconset"
    mkdir -p "$TMP_ICONSET"
    cp "$ICON_SIZES_DIR/MacOS-16.png" "$TMP_ICONSET/icon_16x16.png"
    cp "$ICON_SIZES_DIR/MacOS-32.png" "$TMP_ICONSET/icon_16x16@2x.png"
    cp "$ICON_SIZES_DIR/MacOS-32.png" "$TMP_ICONSET/icon_32x32.png"
    cp "$ICON_SIZES_DIR/MacOS-64.png" "$TMP_ICONSET/icon_32x32@2x.png"
    cp "$ICON_SIZES_DIR/MacOS-128.png" "$TMP_ICONSET/icon_128x128.png"
    cp "$ICON_SIZES_DIR/MacOS-256.png" "$TMP_ICONSET/icon_128x128@2x.png"
    cp "$ICON_SIZES_DIR/MacOS-256.png" "$TMP_ICONSET/icon_256x256.png"
    cp "$ICON_SIZES_DIR/MacOS-512.png" "$TMP_ICONSET/icon_256x256@2x.png"
    cp "$ICON_SIZES_DIR/MacOS-512.png" "$TMP_ICONSET/icon_512x512.png"
    cp "$ICON_SIZES_DIR/MacOS-1024.png" "$TMP_ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$TMP_ICONSET" -o "$ICON_DEST"
    rm -rf "$(dirname "$TMP_ICONSET")"
    echo "  App icon generated from icons/"
elif [ -f "$ICON_SOURCE" ]; then
    cp "$ICON_SOURCE" "$APP_PATH/Contents/Resources/"
    echo "  App icon copied"
else
    echo "  Warning: App icon not found at $ICON_SIZES_DIR or $ICON_SOURCE"
fi

# Copy main executable (SoundBridgeApp)
echo "  Copying SoundBridgeApp executable..."
APP_EXECUTABLE=$(find_swift_product "$PROJECT_ROOT/apps/mac/SoundBridgeApp" "SoundBridgeApp")

if [ -z "$APP_EXECUTABLE" ]; then
    echo "  Error: SoundBridgeApp executable not found. Build it first:"
    echo "   cd apps/mac/SoundBridgeApp && swift build -c release --arch arm64 --arch x86_64"
    exit 1
fi

cp "$APP_EXECUTABLE" "$APP_PATH/Contents/MacOS/SoundBridgeApp"
chmod +x "$APP_PATH/Contents/MacOS/SoundBridgeApp"

# Add rpath for Frameworks directory (needed for Sparkle)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_PATH/Contents/MacOS/SoundBridgeApp" 2>/dev/null || true

echo "  SoundBridgeApp executable copied"

# Copy SoundBridgeHost
echo "  Copying SoundBridgeHost..."
HOST_EXECUTABLE=$(find_swift_product "$PROJECT_ROOT/packages/host" "SoundBridgeHost")

if [ -z "$HOST_EXECUTABLE" ]; then
    echo "  Error: SoundBridgeHost executable not found. Build it first:"
    echo "   cd packages/host && swift build -c release --arch arm64 --arch x86_64"
    exit 1
fi

cp "$HOST_EXECUTABLE" "$APP_PATH/Contents/MacOS/SoundBridgeHost"
chmod +x "$APP_PATH/Contents/MacOS/SoundBridgeHost"
echo "  SoundBridgeHost copied"

# Copy SoundBridgeDriver.driver
echo "  Copying SoundBridgeDriver.driver..."
DRIVER_BUNDLE="$PROJECT_ROOT/packages/driver/build/SoundBridgeDriver.driver"

if [ ! -d "$DRIVER_BUNDLE" ]; then
    echo "  SoundBridgeDriver.driver not found - will need to be installed separately"
    echo "   Note: Driver installation will be handled during onboarding"
    echo "   For development, build with: cd packages/driver && ./install.sh"
else
    cp -R "$DRIVER_BUNDLE" "$APP_PATH/Contents/Resources/SoundBridgeDriver.driver"
    echo "  SoundBridgeDriver.driver copied"
fi

# Copy presets
echo "  Copying presets..."
PRESETS_DIR="$PROJECT_ROOT/apps/mac/SoundBridgeApp/Sources/Resources/Presets"

if [ -d "$PRESETS_DIR" ]; then
    cp -R "$PRESETS_DIR"/* "$APP_PATH/Contents/Resources/Presets/"
    echo "  Presets copied ($(ls -1 "$PRESETS_DIR" | wc -l | tr -d ' ') files)"
else
    echo "  No presets directory found at $PRESETS_DIR"
fi

# Copy other app resources (images, fonts, etc.)
echo "  Copying app resources..."
RESOURCES_DIR="$PROJECT_ROOT/apps/mac/SoundBridgeApp/Sources/Resources"
if [ -d "$RESOURCES_DIR" ]; then
    # Copy everything except Presets (already handled above)
    rsync -av --exclude "Presets" "$RESOURCES_DIR"/ "$APP_PATH/Contents/Resources/" >/dev/null
    echo "  Resources copied"
else
    echo "  No resources directory found at $RESOURCES_DIR"
fi

# Copy Sparkle framework
echo "  Copying Sparkle.framework..."
mkdir -p "$APP_PATH/Contents/Frameworks"

SPARKLE_FRAMEWORK=$(find_swift_product "$PROJECT_ROOT/apps/mac/SoundBridgeApp" "Sparkle.framework")

if [ -d "$SPARKLE_FRAMEWORK" ]; then
    cp -R "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/"
    echo "  Sparkle.framework copied"
else
    echo "  Sparkle.framework not found"
    echo "   Searched in: $PROJECT_ROOT/apps/mac/SoundBridgeApp/.build/"
fi

# Create PkgInfo file
echo "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Verify architectures if lipo is available
echo ""
echo "  SoundBridge.app bundle created successfully!"
echo "   Location: $APP_PATH"
echo ""
if command -v lipo >/dev/null 2>&1; then
    echo "Architectures:"
    echo "  SoundBridgeApp: $(lipo -archs "$APP_PATH/Contents/MacOS/SoundBridgeApp" 2>/dev/null || echo 'unknown')"
    echo "  SoundBridgeHost: $(lipo -archs "$APP_PATH/Contents/MacOS/SoundBridgeHost" 2>/dev/null || echo 'unknown')"
    if [ -f "$APP_PATH/Contents/Resources/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver" ]; then
        echo "  SoundBridgeDriver: $(lipo -archs "$APP_PATH/Contents/Resources/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver" 2>/dev/null || echo 'unknown')"
    fi
    echo ""
fi
echo "Bundle contents:"
echo "  - SoundBridgeApp (main executable)"
echo "  - SoundBridgeHost (audio engine)"
echo "  - SoundBridgeDriver.driver (HAL driver)"
echo "  - Presets (EQ configurations)"
echo ""
echo "To test the bundle:"
echo "  open $APP_PATH"
echo ""
