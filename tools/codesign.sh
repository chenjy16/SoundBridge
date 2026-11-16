#!/bin/bash
# Code signing script for SoundBridge
#
# Two modes, selected with SIGN_MODE or --adhoc:
#   auto          (default) use a Developer ID when one is available, otherwise
#                 fall back to ad-hoc
#   developer-id  require a Developer ID, hardened runtime and a timestamp so
#                 the bundle can be notarized
#   adhoc         never touch a certificate
#
# Ad-hoc signatures are what Apple silicon requires to run a binary at all, and
# they are enough to publish a DMG on GitHub. They are not notarizable, so the
# first launch shows a Gatekeeper warning that the user has to approve.

set -e  # Exit on error

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_BUNDLE="$PROJECT_ROOT/dist/SoundBridge.app"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print section headers
section() {
    echo ""
    echo -e "${BLUE}----------------------------------------${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}----------------------------------------${NC}"
}

# Function to print errors
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

# Function to print warnings
warn() {
    echo -e "${YELLOW} WARNING: $1${NC}"
}

# Function to print success
success() {
    echo -e "${GREEN}OK: $1${NC}"
}

# Function to print informational notes
info() {
    echo -e "${BLUE}INFO: $1${NC}"
}

# Check if app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    error "App bundle not found at $APP_BUNDLE"
    error "Run 'make bundle' first to create the app bundle"
    exit 1
fi

# Signing mode
SIGN_MODE="${SIGN_MODE:-auto}"
if [ "${1:-}" = "--adhoc" ]; then
    SIGN_MODE="adhoc"
fi

SIGNING_IDENTITY=""
if [ "$SIGN_MODE" = "adhoc" ]; then
    # Nothing to look up: ad-hoc signing uses the "-" pseudo identity.
    SIGNING_IDENTITY="-"
elif [ -n "$APPLE_DEVELOPER_ID" ]; then
    # Use provided Developer ID directly
    SIGNING_IDENTITY="$APPLE_DEVELOPER_ID"
    echo "Using Developer ID from environment: $SIGNING_IDENTITY"
elif [ -n "$APPLE_CERTIFICATE" ] && [ -n "$APPLE_CERTIFICATE_PASSWORD" ]; then
    # Import certificate from base64-encoded .p12 (for CI/CD)
    section "Importing Certificate"

    KEYCHAIN_PATH="$HOME/Library/Keychains/signing.keychain-db"
    KEYCHAIN_PASSWORD=$(openssl rand -base64 32)

    # Create temporary keychain
    security create-keychain -p "$KEYCHAIN_PASSWORD" signing.keychain
    security set-keychain-settings -lut 21600 signing.keychain
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" signing.keychain

    # Decode and import certificate
    echo "$APPLE_CERTIFICATE" | base64 --decode > certificate.p12
    security import certificate.p12 -k signing.keychain -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" signing.keychain

    # Add to search list
    security list-keychains -d user -s signing.keychain login.keychain

    # Find the identity
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning signing.keychain | grep "Developer ID Application" | head -1 | awk '{print $2}')

    if [ -z "$SIGNING_IDENTITY" ]; then
        error "Could not find Developer ID Application certificate in keychain"
        exit 1
    fi

    success "Certificate imported successfully"
    echo "Using identity: $SIGNING_IDENTITY"

    # Cleanup certificate file
    rm -f certificate.p12
else
    # Try to find an installed Developer ID certificate
    section "Looking for Developer ID Certificate"

    SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')

    if [ -n "$SIGNING_IDENTITY" ]; then
        success "Found Developer ID certificate"
        echo "Using identity: $SIGNING_IDENTITY"
    fi
fi

# No certificate configured: fall back to ad-hoc unless the caller insisted.
if [ -z "$SIGNING_IDENTITY" ] && [ "$SIGN_MODE" != "developer-id" ]; then
    warn "No Developer ID certificate found - falling back to ad-hoc signing"
    echo "   Ad-hoc signed builds run on both architectures and install from a"
    echo "   GitHub release, but macOS asks the user to approve the first launch."
    SIGNING_IDENTITY="-"
fi

if [ -z "$SIGNING_IDENTITY" ]; then
    error "No Developer ID Application certificate found"
    echo ""
    echo "Please either:"
    echo "  1. Set APPLE_DEVELOPER_ID environment variable with your identity string"
    echo "     Example: export APPLE_DEVELOPER_ID=\"Developer ID Application: Your Name (TEAM_ID)\""
    echo ""
    echo "  2. Or set APPLE_CERTIFICATE and APPLE_CERTIFICATE_PASSWORD for CI/CD"
    echo "     APPLE_CERTIFICATE should be base64-encoded .p12 file"
    echo ""
    echo "  3. Or install your Developer ID certificate in Keychain Access"
    echo ""
    echo "  4. Or sign ad-hoc for a GitHub release: ./tools/codesign.sh --adhoc"
    echo ""
    exit 1
fi

# Signing options
if [ "$SIGNING_IDENTITY" = "-" ]; then
    section "Ad-hoc Code Signing"
    # --timestamp and --options runtime only make sense with a real identity.
    SIGN_OPTS=(
        --sign -
        --force
        --verbose
    )
else
    section "Code Signing SoundBridge"
    SIGN_OPTS=(
        --sign "$SIGNING_IDENTITY"
        --timestamp
        --options runtime
        --force
        --verbose
    )
fi

# Step 1: Sign SoundBridgeHost executable
echo " Signing SoundBridgeHost..."
if codesign "${SIGN_OPTS[@]}" \
    --entitlements "$PROJECT_ROOT/packages/host/SoundBridgeHost.entitlements" \
    "$APP_BUNDLE/Contents/MacOS/SoundBridgeHost"; then
    success "SoundBridgeHost signed"
else
    error "Failed to sign SoundBridgeHost"
    exit 1
fi

# Step 2: Sign SoundBridgeDriver.driver bundle (if present)
if [ -d "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver" ]; then
    echo " Signing SoundBridgeDriver.driver..."

    # Sign the driver binary inside the bundle
    if [ -f "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver" ]; then
        if codesign "${SIGN_OPTS[@]}" \
            "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver"; then
            success "Driver binary signed"
        else
            error "Failed to sign driver binary"
            exit 1
        fi
    fi

    # Sign the driver bundle
    if codesign "${SIGN_OPTS[@]}" \
        "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver"; then
        success "SoundBridgeDriver.driver bundle signed"
    else
        error "Failed to sign driver bundle"
        exit 1
    fi
else
    warn "SoundBridgeDriver.driver not found in bundle (optional)"
fi

# Step 3: Sign embedded frameworks (e.g. Sparkle)
if [ -d "$APP_BUNDLE/Contents/Frameworks" ]; then
    echo "Signing frameworks..."

    sign_macho_binaries() {
        local root="$1"
        while IFS= read -r macho; do
            if file "$macho" | grep -q "Mach-O"; then
                local name_rel="${macho#$APP_BUNDLE/}"
                echo "      -> $name_rel"
                if ! codesign "${SIGN_OPTS[@]}" "$macho"; then
                    error "Failed to sign $name_rel"
                    exit 1
                fi
            fi
        done < <(find "$root" -type f \( -perm -111 -o -name "*.dylib" \) | sort)
    }

    while IFS= read -r framework; do
        NAME=$(basename "$framework")
        echo "   - $NAME"

        # Sign nested XPC services first (they contain their own Mach-O)
        while IFS= read -r xpc; do
            sign_macho_binaries "$xpc/Contents/MacOS"
            if ! codesign "${SIGN_OPTS[@]}" "$xpc"; then
                error "Failed to sign $(basename "$xpc")"
                exit 1
            fi
        done < <(find "$framework" -type d -name "*.xpc" | sort)

        # Sign any Mach-O binaries inside the framework (e.g. Autoupdate)
        sign_macho_binaries "$framework"

        # Finally sign the framework bundle itself with a deep signature
        if codesign "${SIGN_OPTS[@]}" --deep "$framework"; then
            success "$NAME signed"
        else
            error "Failed to sign $NAME"
            exit 1
        fi
    done < <(find "$APP_BUNDLE/Contents/Frameworks" -maxdepth 1 -type d -name "*.framework")
else
    warn "No frameworks found in bundle"
fi

# Step 4: Sign SoundBridgeApp main executable
echo "Signing SoundBridgeApp..."
if codesign "${SIGN_OPTS[@]}" \
    --entitlements "$PROJECT_ROOT/apps/mac/SoundBridgeApp/SoundBridgeApp.entitlements" \
    "$APP_BUNDLE/Contents/MacOS/SoundBridgeApp"; then
    success "SoundBridgeApp signed"
else
    error "Failed to sign SoundBridgeApp"
    exit 1
fi

# Step 5: Sign the entire app bundle (outer signature)
echo "Signing SoundBridge.app bundle..."
if codesign "${SIGN_OPTS[@]}" \
    --entitlements "$PROJECT_ROOT/apps/mac/SoundBridgeApp/SoundBridgeApp.entitlements" \
    "$APP_BUNDLE"; then
    success "SoundBridge.app bundle signed"
else
    error "Failed to sign app bundle"
    exit 1
fi

section "Verification"

# Verify all signatures
echo " Verifying SoundBridgeHost..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE/Contents/MacOS/SoundBridgeHost"

if [ -d "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver" ]; then
    echo " Verifying SoundBridgeDriver.driver..."
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver"
fi

echo " Verifying SoundBridgeApp..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE/Contents/MacOS/SoundBridgeApp"

echo " Verifying SoundBridge.app bundle..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

# Check Gatekeeper acceptance
if [ "$SIGNING_IDENTITY" = "-" ]; then
    info "Ad-hoc signature: Gatekeeper asks the user to approve the first launch"
else
    echo " Checking Gatekeeper assessment..."
    if spctl --assess --type execute --verbose=4 "$APP_BUNDLE" 2>&1 | grep -q "accepted"; then
        success "Gatekeeper will accept this app"
    else
        warn "Gatekeeper may reject this app (this is normal before notarization)"
    fi
fi

section "Code Signing Complete!"

echo ""
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "App bundle signed ad-hoc"
else
    echo "App bundle signed with: $SIGNING_IDENTITY"
fi
echo "Location: $APP_BUNDLE"
echo ""
echo "Next steps:"
echo "  1. Test the signed app: open $APP_BUNDLE"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "  2. Create DMG: ./tools/create_dmg.sh"
else
    echo "  2. Notarize for distribution: ./tools/notarize.sh"
    echo "  3. Create DMG: ./tools/create_dmg.sh"
fi
echo ""
# Cleanup temporary keychain if created
if [ -n "$APPLE_CERTIFICATE" ]; then
    security delete-keychain signing.keychain 2>/dev/null || true
fi
