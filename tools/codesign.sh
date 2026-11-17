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

# Which bundle to sign
# --------------------
# Without SB_APP_BUNDLE this signs the release bundle, so `make sign` and a bare
# tools/codesign.sh call do exactly what they did before. SB_APP_BUNDLE points
# the same sequence at a candidate copy -- build/p34/unsigned/SoundBridge.app,
# for instance -- without ever falling back to dist/ when the caller asked for
# something else.
#
#   SB_APP_BUNDLE=build/p34/unsigned/SoundBridge.app tools/codesign.sh --adhoc
DEFAULT_APP_BUNDLE="$PROJECT_ROOT/dist/SoundBridge.app"
HOST_ENTITLEMENTS="$PROJECT_ROOT/packages/host/SoundBridgeHost.entitlements"
APP_ENTITLEMENTS="$PROJECT_ROOT/apps/mac/SoundBridgeApp/SoundBridgeApp.entitlements"

# Set-but-empty is a mistake, not a request for the default: a caller that built
# a path and got an empty string would otherwise sign dist/ without saying so.
if [ -n "${SB_APP_BUNDLE+x}" ] && [ -z "$SB_APP_BUNDLE" ]; then
    echo "ERROR: SB_APP_BUNDLE is set but empty; unset it to sign $DEFAULT_APP_BUNDLE" >&2
    exit 2
fi
APP_BUNDLE="${SB_APP_BUNDLE:-$DEFAULT_APP_BUNDLE}"

# 1 means: resolve everything, print the plan, sign nothing.
DRY_RUN=0
if [ "${SB_SIGN_DRY_RUN:-0}" = "1" ]; then
    DRY_RUN=1
fi

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

# The bundle has to be a bundle, not merely a directory with the right name.
# Every refusal below says which path was asked for, so a typo cannot land on a
# different app.
if [ ! -d "$APP_BUNDLE" ]; then
    error "App bundle not found at $APP_BUNDLE"
    if [ -n "${SB_APP_BUNDLE+x}" ]; then
        error "SB_APP_BUNDLE was set explicitly; $DEFAULT_APP_BUNDLE was NOT substituted"
    else
        error "Run 'make bundle' first to create the app bundle"
    fi
    exit 1
fi

case "$APP_BUNDLE" in
    *.app) : ;;
    *)
        error "not an .app bundle: $APP_BUNDLE"
        exit 1
        ;;
esac

if [ ! -f "$APP_BUNDLE/Contents/Info.plist" ] || [ ! -d "$APP_BUNDLE/Contents/MacOS" ]; then
    error "$APP_BUNDLE is not a valid app bundle (Contents/Info.plist and Contents/MacOS are required)"
    exit 1
fi

for ent in "$HOST_ENTITLEMENTS" "$APP_ENTITLEMENTS"; do
    if [ ! -f "$ent" ]; then
        error "entitlements file not found: $ent"
        exit 1
    fi
done

# From here on the path is absolute and symlink-free, so the plan printed by
# --dry-run can be compared with what actually ran.
APP_PARENT="$( cd "$( dirname "$APP_BUNDLE" )" && pwd -P )" \
    || { error "cannot resolve the parent of $APP_BUNDLE"; exit 1; }
APP_BUNDLE="$APP_PARENT/$( basename "$APP_BUNDLE" )"

# Signing mode and flags
SIGN_MODE="${SIGN_MODE:-auto}"
for arg in "$@"; do
    case "$arg" in
        --adhoc)   SIGN_MODE="adhoc" ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            echo ""
            echo "usage: $0 [--adhoc] [--dry-run]"
            echo ""
            echo "  SB_APP_BUNDLE=<path>   sign a bundle other than $DEFAULT_APP_BUNDLE"
            echo "  SIGN_MODE=<mode>       auto (default), developer-id or adhoc"
            echo "  SB_SIGN_DRY_RUN=1      same as --dry-run"
            echo "  --dry-run              print the signing plan and sign nothing"
            echo "  --adhoc                same as SIGN_MODE=adhoc"
            exit 0
            ;;
        *)
            # Silence is the wrong answer in a signing script: an unrecognised
            # flag would otherwise be ignored while the rest runs.
            echo "ERROR: unknown argument '$arg' (try --help)" >&2
            exit 2
            ;;
    esac
done

SIGNING_IDENTITY=""
if [ "$SIGN_MODE" = "adhoc" ]; then
    # Nothing to look up: ad-hoc signing uses the "-" pseudo identity.
    SIGNING_IDENTITY="-"
elif [ -n "$APPLE_DEVELOPER_ID" ]; then
    # Use provided Developer ID directly
    SIGNING_IDENTITY="$APPLE_DEVELOPER_ID"
    echo "Using Developer ID from environment: $SIGNING_IDENTITY"
elif [ -n "$APPLE_CERTIFICATE" ] && [ -n "$APPLE_CERTIFICATE_PASSWORD" ]; then
    # Importing into a keychain is a real side effect; a dry run must not have
    # any, so the CI path is refused rather than simulated.
    if [ "$DRY_RUN" = "1" ]; then
        error "a dry run cannot import a certificate; set APPLE_DEVELOPER_ID to preview a Developer ID plan"
        exit 2
    fi
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

# What is about to be signed, in full. A signing run that reports the wrong
# bundle is worse than one that fails, so the target is stated before the first
# code object is touched.
section "Signing Target"
echo "  bundle:       $APP_BUNDLE"
if [ "$APP_BUNDLE" = "$DEFAULT_APP_BUNDLE" ]; then
    echo "  source:       default (dist/SoundBridge.app)"
else
    echo "  source:       SB_APP_BUNDLE"
fi
echo "  identity:     $SIGNING_IDENTITY"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "  signature:    adhoc (not a Developer ID signature)"
else
    echo "  signature:    Developer ID Application, hardened runtime, timestamp"
fi
echo "  entitlements: host $HOST_ENTITLEMENTS"
echo "                app  $APP_ENTITLEMENTS"
echo "  options:      ${SIGN_OPTS[*]}"
if [ "$DRY_RUN" = "1" ]; then
    echo "  mode:         DRY RUN (nothing will be signed)"
fi

# Every signing action goes through here. In a dry run the call is recorded and
# printed instead of executed, which is what makes the nesting order and the
# path handling testable without a certificate.
SIGN_PLAN=()
run_codesign() {
    if [ "$DRY_RUN" = "1" ]; then
        SIGN_PLAN+=("codesign $*")
        echo "  [dry-run] codesign $*"
        return 0
    fi
    codesign "$@"
}

# "signed" is not a claim a dry run is allowed to print.
sign_success() {
    if [ "$DRY_RUN" = "1" ]; then
        info "would sign: $1"
    else
        success "$1"
    fi
}

# Step 1: Sign SoundBridgeHost executable
echo " Signing SoundBridgeHost..."
if run_codesign "${SIGN_OPTS[@]}" \
    --entitlements "$HOST_ENTITLEMENTS" \
    "$APP_BUNDLE/Contents/MacOS/SoundBridgeHost"; then
    sign_success "SoundBridgeHost signed"
else
    error "Failed to sign SoundBridgeHost"
    exit 1
fi

# Step 2: Sign SoundBridgeDriver.driver bundle (if present)
if [ -d "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver" ]; then
    echo " Signing SoundBridgeDriver.driver..."

    # Sign the driver binary inside the bundle
    if [ -f "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver" ]; then
        if run_codesign "${SIGN_OPTS[@]}" \
            "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver"; then
            sign_success "Driver binary signed"
        else
            error "Failed to sign driver binary"
            exit 1
        fi
    fi

    # Sign the driver bundle
    if run_codesign "${SIGN_OPTS[@]}" \
        "$APP_BUNDLE/Contents/Resources/SoundBridgeDriver.driver"; then
        sign_success "SoundBridgeDriver.driver bundle signed"
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
                if ! run_codesign "${SIGN_OPTS[@]}" "$macho"; then
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
            if ! run_codesign "${SIGN_OPTS[@]}" "$xpc"; then
                error "Failed to sign $(basename "$xpc")"
                exit 1
            fi
        done < <(find "$framework" -type d -name "*.xpc" | sort)

        # Sign any Mach-O binaries inside the framework (e.g. Autoupdate)
        sign_macho_binaries "$framework"

        # Finally sign the framework bundle itself with a deep signature
        if run_codesign "${SIGN_OPTS[@]}" --deep "$framework"; then
            sign_success "$NAME signed"
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
if run_codesign "${SIGN_OPTS[@]}" \
    --entitlements "$APP_ENTITLEMENTS" \
    "$APP_BUNDLE/Contents/MacOS/SoundBridgeApp"; then
    sign_success "SoundBridgeApp signed"
else
    error "Failed to sign SoundBridgeApp"
    exit 1
fi

# Step 5: Sign the entire app bundle (outer signature)
echo "Signing SoundBridge.app bundle..."
if run_codesign "${SIGN_OPTS[@]}" \
    --entitlements "$APP_ENTITLEMENTS" \
    "$APP_BUNDLE"; then
    sign_success "SoundBridge.app bundle signed"
else
    error "Failed to sign app bundle"
    exit 1
fi

section "Verification"

if [ "$DRY_RUN" = "1" ]; then
    info "dry run: nothing was signed, so there is nothing to verify"
else

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

fi

section "Code Signing Complete!"

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "Signing plan for $APP_BUNDLE"
    echo "Nothing was signed: this was a dry run."
    echo ""
    n=0
    for step in "${SIGN_PLAN[@]}"; do
        n=$((n + 1))
        echo "  $n. $step"
    done
    echo ""
    exit 0
fi

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
