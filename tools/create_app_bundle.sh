#!/bin/bash
# Create proper .app bundle structure for SoundBridge
# Supports universal binaries (arm64 + x86_64)

set -e  # Exit on error
# Same reason as build_release.sh: a failing command inside a pipeline reports
# the pipeline's status, and `cmd | tail -1` would then look like success.
set -o pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="${SB_DIST_DIR:-$PROJECT_ROOT/dist}"
APP_NAME="SoundBridge.app"

# The bundle that ships. Nothing below writes into it: a half-built bundle in
# this path is worse than no bundle at all, because the packaging steps that run
# next (sign, DMG) cannot tell the difference.
FINAL_APP="$DIST_DIR/$APP_NAME"

# Everything below is built here first. It lives in the same directory as the
# final bundle, so putting it in place at the end is a rename, not a copy, and
# an interrupted run leaves either the old bundle or the new one - not both.
STAGE_APP="$DIST_DIR/.$APP_NAME.staging.$$"
APP_PATH="$STAGE_APP"

# The backup the swap keeps while the new bundle is being renamed into place,
# and the lock that keeps two runs from swapping at the same time.
PREVIOUS_APP="$DIST_DIR/.$APP_NAME.previous.$$"
SWAP_LOCK="$DIST_DIR/.$APP_NAME.swap.lock"

# Set when the site is left mid-change: the staging copy is then the only copy
# of the bundle this run built, and it is kept for a look instead of swept up.
KEEP_STAGE=0

# Whatever happens below, the staging copy goes away with this run. The trap is
# what makes "the build failed" stop meaning "the working bundle is gone".
# It never removes a backup: that directory is only deleted by a swap that has
# already put the new bundle in place.
cleanup_stage() {
    local code=$?
    if [ "$KEEP_STAGE" = "1" ]; then
        echo "  The staging bundle was kept: $STAGE_APP" >&2
    elif ! rm -rf "$STAGE_APP"; then
        echo "  Warning: the staging bundle could not be removed; it is still at $STAGE_APP" >&2
    fi
    exit $code
}
trap cleanup_stage EXIT

# Where the built HAL driver is picked up from. Overridable so the packaging
# checks below can be pointed at a scratch tree; the default is the only place
# the driver build writes to.
DRIVER_BUNDLE="${SB_DRIVER_BUNDLE-$PROJECT_ROOT/packages/driver/build/SoundBridgeDriver.driver}"

# The app loads Sparkle through this rpath, and the bundle copies the framework
# into Contents/Frameworks, so the two have to agree.
RPATH_FRAMEWORKS="@executable_path/../Frameworks"

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

# Does an `otool -l` listing contain this LC_RPATH?
#
# The whole listing is read: `... | grep -q` exits at the first match, which can
# kill the writer with SIGPIPE, and under `set -o pipefail` that failure is
# indistinguishable from "the rpath is missing". That made the check depend on
# how large the binary happened to be.
listing_has_rpath() {
    printf '%s\n' "$1" | awk -v want="$2" '
        /^ *cmd LC_RPATH$/ { have = 1; next }
        have && /^ *path / { if ($2 == want) found = 1; have = 0 }
        END { exit(found ? 0 : 1) }
    '
}

# Print an `otool -l` listing, or fail. A file otool cannot parse (a text file,
# or an otool that does not really run) has no `Load command` lines, so "no
# rpath found" and "not a Mach-O file" are told apart here instead of being
# guessed from an exit status.
macho_listing() {
    local listing
    if ! listing="$(otool -l "$1" 2>&1)"; then
        return 1
    fi
    case "$listing" in
        *"Load command "*) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$listing"
}

# Add an rpath to a Mach-O file, but only if it is not already there.
#
# The old `install_name_tool -add_rpath ... || true` folded two very different
# outcomes into one: "the rpath is already present" (install_name_tool errors,
# the bundle is fine) and "this file could not be edited" (install_name_tool
# errors, and the bundle cannot find its frameworks at launch). The status of
# the tool cannot tell them apart, so the file is asked instead.
ensure_rpath() {
    local binary="$1"
    local rpath="$2"
    local listing

    if [ -z "$binary" ] || [ ! -f "$binary" ]; then
        echo "  Error: cannot set rpath '$rpath': '$binary' is not a file" >&2
        return 1
    fi
    if ! command -v otool >/dev/null 2>&1 || ! command -v install_name_tool >/dev/null 2>&1; then
        echo "  Error: otool and install_name_tool are both required to set rpath '$rpath' on $binary" >&2
        return 1
    fi
    if ! listing="$(macho_listing "$binary")"; then
        echo "  Error: otool cannot read '$binary' as a Mach-O file; refusing to assume rpath '$rpath' is in place" >&2
        return 1
    fi

    if listing_has_rpath "$listing" "$rpath"; then
        echo "  rpath $rpath already present in $(basename "$binary") - left alone"
        return 0
    fi

    if ! install_name_tool -add_rpath "$rpath" "$binary"; then
        echo "  Error: install_name_tool -add_rpath '$rpath' failed on $binary" >&2
        return 1
    fi

    # Trust the file, not the tool's exit status: a tool that wrote nothing and
    # exited 0 would leave a bundle that fails at dyld time instead of here.
    if ! listing="$(macho_listing "$binary")"; then
        echo "  Error: otool cannot read $binary back after install_name_tool" >&2
        return 1
    fi
    if ! listing_has_rpath "$listing" "$rpath"; then
        echo "  Error: $binary still does not declare rpath '$rpath' after install_name_tool" >&2
        return 1
    fi
    echo "  added rpath $rpath to $(basename "$binary")"
    return 0
}

# Take the swap lock, or say who has it. `mkdir` is the lock: it creates or it
# fails, atomically, and only the run that created it removes it.
acquire_swap_lock() {
    if ! mkdir "$SWAP_LOCK" 2>/dev/null; then
        local holder=""
        if [ -f "$SWAP_LOCK/pid" ]; then
            holder="$(cat "$SWAP_LOCK/pid" 2>/dev/null)"
        fi
        echo "  Error: another build is putting a bundle in place right now." >&2
        echo "   Lock: $SWAP_LOCK${holder:+ (pid $holder)}" >&2
        echo "   This run did not touch $FINAL_APP." >&2
        echo "   If no other build is running, the lock was left by one that was killed:" >&2
        echo "     rm -rf '$SWAP_LOCK'" >&2
        return 1
    fi
    printf '%s\n' "$$" > "$SWAP_LOCK/pid" 2>/dev/null || true
    return 0
}

release_swap_lock() {
    rm -rf "$SWAP_LOCK" 2>/dev/null || true
}

# Put the staging bundle in place, keeping the previous one until the new one is
# actually at the final path.
#
# This rename is the only step that touches the working bundle, and it runs after
# every check above has passed. If moving the new bundle fails after the old one
# was set aside, the old one goes back: the failure this guards against is a
# dist/ with no bundle in it.
#
# When the old one cannot go back either, nothing is deleted and every path a
# person needs to finish the job by hand is printed: at that point the backup is
# the only complete copy of the last good bundle, and the staging copy is the
# only copy of what this run built.
swap_into_place() {
    local restore_src="$PREVIOUS_APP"
    local stale
    local moved

    if ! acquire_swap_lock; then
        return 1
    fi

    # A backup an earlier run left behind is the last copy of a bundle nobody
    # has looked at yet. It is reported and left exactly where it is: the run
    # that wrote it may have died between the two renames, and cleaning up after
    # it could be cleaning up the only bundle that was working.
    for stale in "$DIST_DIR/."$APP_NAME".previous."*; do
        [ -e "$stale" ] || [ -L "$stale" ] || continue
        echo "  Note: a bundle kept by an earlier run is at $stale (left as it is)" >&2
    done

    if [ -e "$PREVIOUS_APP" ] || [ -L "$PREVIOUS_APP" ]; then
        echo "  Error: $PREVIOUS_APP already exists; this run will not overwrite it." >&2
        echo "   Look at it first, then move it away (or remove it) and run again." >&2
        release_swap_lock
        return 1
    fi

    # Test seam: hold the swap open so a second run reaches the lock above.
    if [ -n "${SB_BUNDLE_SWAP_HOLD:-}" ]; then
        sleep "$SB_BUNDLE_SWAP_HOLD"
    fi

    if [ -e "$FINAL_APP" ] || [ -L "$FINAL_APP" ]; then
        # From here until the new bundle is in place, or the old one is back,
        # the site is mid-change: whatever a signal does next, the staging copy
        # is worth keeping.
        KEEP_STAGE=1
        if ! mv "$FINAL_APP" "$PREVIOUS_APP"; then
            echo "  Error: could not move the existing bundle aside; $FINAL_APP is untouched" >&2
            KEEP_STAGE=0
            release_swap_lock
            return 1
        fi
    fi

    moved=0
    if mv "$STAGE_APP" "$FINAL_APP" && [ -e "$FINAL_APP" ] && [ ! -e "$STAGE_APP" ]; then
        moved=1
    fi

    if [ "$moved" = "0" ]; then
        echo "  Error: could not move the new bundle into $FINAL_APP" >&2

        if [ ! -e "$PREVIOUS_APP" ] && [ ! -L "$PREVIOUS_APP" ]; then
            # Nothing was there before this run, so there is nothing to put back
            # and nothing to claim about it.
            echo "   There was no bundle at $FINAL_APP before this run; nothing was restored." >&2
            if [ -e "$FINAL_APP" ] || [ -L "$FINAL_APP" ]; then
                echo "   $FINAL_APP exists now; its contents have not been checked." >&2
            else
                echo "   $FINAL_APP does not exist." >&2
            fi
            release_swap_lock
            return 1
        fi

        if mv "$PREVIOUS_APP" "$FINAL_APP" \
            && [ ! -d "$FINAL_APP/$(basename "$PREVIOUS_APP")" ]; then
            echo "   The previous bundle was put back at $FINAL_APP" >&2
            KEEP_STAGE=0
            release_swap_lock
            return 1
        fi

        # `mv` into a directory that already exists puts the source *inside* it,
        # which looks like a restore in the log and is not one.
        if [ -d "$FINAL_APP/$(basename "$PREVIOUS_APP")" ]; then
            restore_src="$FINAL_APP/$(basename "$PREVIOUS_APP")"
        fi

        KEEP_STAGE=1
        echo "  Error: the previous bundle could not be put back at $FINAL_APP." >&2
        echo "   Nothing was deleted. The last good bundle is here:" >&2
        echo "     $restore_src" >&2
        echo "   The bundle this run built is still here:" >&2
        echo "     $STAGE_APP" >&2
        if [ -e "$FINAL_APP" ] || [ -L "$FINAL_APP" ]; then
            echo "   $FINAL_APP exists now; its contents have not been checked -- do not delete anything yet." >&2
        else
            echo "   $FINAL_APP does not exist." >&2
        fi
        echo "   To put the last good bundle back by hand:" >&2
        echo "     mv '$restore_src' '$FINAL_APP'" >&2
        release_swap_lock
        return 1
    fi

    # The new bundle is at the final path; only now is the backup expendable.
    KEEP_STAGE=0
    if ! rm -rf "$PREVIOUS_APP"; then
        echo "  Warning: the bundle was put in place, but the backup could not be removed:" >&2
        echo "     $PREVIOUS_APP" >&2
    fi
    release_swap_lock
    return 0
}

# Test hook: exercise the rpath logic on a given Mach-O file without building a
# bundle. Used by the Phase 2.2.2 Batch A tests.
if [ "${SB_BUNDLE_RPATH_ONLY:-}" = "1" ]; then
    if ensure_rpath "${1:-}" "${2:-$RPATH_FRAMEWORKS}"; then
        exit 0
    fi
    exit 1
fi

echo "Creating SoundBridge.app bundle structure..."

# Build into a staging copy rather than into the bundle that already exists.
#
# The old order wiped first and validated second: `rm -rf dist/SoundBridge.app`
# ran before the driver, the host and Sparkle were known to be present, so a
# missing input cost the bundle that was there and replaced it with nothing.
# Now every check below runs against the staging copy, and the working bundle is
# only touched once a complete one exists to take its place.
#
# dist/ itself is not cleared either: a .pkg or .dmg from an earlier run is an
# artifact someone may still need.
rm -rf "$STAGE_APP"
mkdir -p "$DIST_DIR"

# Create .app bundle structure
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
mkdir -p "$APP_PATH/Contents/Resources/Presets"

echo "  Created bundle structure"

# Copy Info.plist
echo "  Copying Info.plist..."
cp "$PROJECT_ROOT/apps/mac/SoundBridgeApp/Info.plist" "$APP_PATH/Contents/Info.plist"

# Inject the Sparkle public key at bundle time.
# The public key is safe to publish, but it is kept out of the repository so a
# fresh checkout (and any local build) stays keyless: with an empty
# SUPublicEDKey the app never starts Sparkle. Release builds set
# SPARKLE_ED_PUBLIC_KEY from the CI secret.
if [ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_ED_PUBLIC_KEY" \
        "$APP_PATH/Contents/Info.plist"
    echo "  Sparkle public key injected"
else
    echo "  No SPARKLE_ED_PUBLIC_KEY set - auto-update will be disabled in this build"
fi
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

# Add rpath for Frameworks directory (needed for Sparkle). A failure here is
# fatal: the framework is copied below, but nothing can reach it without this.
echo "  Setting the Frameworks rpath..."
ensure_rpath "$APP_PATH/Contents/MacOS/SoundBridgeApp" "$RPATH_FRAMEWORKS"

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
#
# The driver is not optional. It is the half of the product the app installs
# into the HAL directory, so a bundle without it builds, launches, and then
# fails at the one moment that matters: when the user is asked to install a
# driver that was never packaged. This used to print a note and exit 0.
echo "  Copying SoundBridgeDriver.driver..."

if [ -z "$DRIVER_BUNDLE" ]; then
    echo "  Error: no driver bundle path was given (the path is empty)." >&2
    echo "   Expected: $PROJECT_ROOT/packages/driver/build/SoundBridgeDriver.driver" >&2
    echo "   Build it with: make build, or cd packages/driver && cmake -B build && cmake --build build" >&2
    exit 1
fi

if [ ! -d "$DRIVER_BUNDLE" ]; then
    echo "  Error: SoundBridgeDriver.driver not found at $DRIVER_BUNDLE" >&2
    echo "   The app bundle is not usable without it, so no bundle was kept." >&2
    echo "   Build the driver first: make build," >&2
    echo "   or cd packages/driver && cmake -B build && cmake --build build" >&2
    exit 1
fi

DRIVER_EXECUTABLE="$DRIVER_BUNDLE/Contents/MacOS/SoundBridgeDriver"
DRIVER_PLIST_SRC="$DRIVER_BUNDLE/Contents/Info.plist"
DRIVER_MISSING=""
if [ ! -f "$DRIVER_EXECUTABLE" ]; then
    DRIVER_MISSING="$DRIVER_MISSING\n   - $DRIVER_EXECUTABLE does not exist"
fi
if [ -f "$DRIVER_EXECUTABLE" ] && [ ! -x "$DRIVER_EXECUTABLE" ]; then
    DRIVER_MISSING="$DRIVER_MISSING\n   - $DRIVER_EXECUTABLE is not executable"
fi
if [ ! -f "$DRIVER_PLIST_SRC" ]; then
    DRIVER_MISSING="$DRIVER_MISSING\n   - $DRIVER_PLIST_SRC does not exist"
fi
if [ -n "$DRIVER_MISSING" ]; then
    echo "  Error: $DRIVER_BUNDLE is not a usable driver bundle; it is missing:" >&2
    printf '%b\n' "$DRIVER_MISSING" >&2
    echo "   Rebuild it: cd packages/driver && rm -rf build && cmake -B build && cmake --build build" >&2
    exit 1
fi

cp -R "$DRIVER_BUNDLE" "$APP_PATH/Contents/Resources/SoundBridgeDriver.driver"

# Verify the copy, not the source: a driver that did not survive the copy is
# just as absent as one that was never built.
if [ ! -x "$APP_PATH/Contents/Resources/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver" ] \
    || [ ! -f "$APP_PATH/Contents/Resources/SoundBridgeDriver.driver/Contents/Info.plist" ]; then
    echo "  Error: the driver bundle did not survive the copy into $APP_PATH" >&2
    exit 1
fi
echo "  SoundBridgeDriver.driver copied"

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
    # The app links `@rpath/Sparkle.framework/Versions/B/Sparkle` unconditionally.
    # A bundle without it cannot launch at all — dyld refuses before any of our
    # code runs — and the symptom ("the app is damaged") reads like a signing
    # problem, which sends the investigation to the wrong place for an hour.
    if otool -L "$APP_PATH/Contents/MacOS/SoundBridgeApp" 2>/dev/null | grep -q "Sparkle.framework"; then
        echo "  Error: SoundBridgeApp links Sparkle.framework but none was found." >&2
        echo "   Looked in: .build/universal/release, .build/apple/Products/Release," >&2
        echo "              .build/<triple>/release, .build/release" >&2
        echo "   Every per-arch build puts it next to the executable in the scratch" >&2
        echo "   directory; stage it into .build/universal/release (build_release.sh," >&2
        echo "   the Makefile 'quick' target and the release workflow all do)." >&2
        exit 1
    fi
    echo "  Sparkle.framework not found (the app does not link it)"
fi

# Create PkgInfo file
echo "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Every input has been copied and every check above has passed, so the working
# bundle can be replaced. `set -e` turns a failed swap into a non-zero exit.
swap_into_place
APP_PATH="$FINAL_APP"

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
