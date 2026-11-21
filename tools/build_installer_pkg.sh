#!/bin/bash
#
# Build an unsigned installer package that ships the app AND the matching driver.
#
# Why this exists (Phase 2.1.5-A)
# ------------------------------
# Reinstalling the *app* does not touch /Library/Audio/Plug-Ins/HAL, so a user on
# an older driver stays on the older driver no matter how often they re-run the
# DMG. The only recovery path that actually replaces the driver is an installer
# that owns both halves of the pair.
#
# This script produces that installer. It does NOT:
#   - install anything (never calls `installer`, never runs sudo),
#   - sign it (no Developer ID, no notarization),
#   - upload it,
#   - touch /Library/Audio/Plug-Ins/HAL on this machine.
#
# It is a prototype: the artifact is unsigned, so macOS will require the user to
# approve it, and Gatekeeper will warn. Signing and notarization are a separate,
# explicitly authorised step.
#
# Package layout
# --------------
#   /Applications/SoundBridge.app
#   /Library/Application Support/SoundBridge/InstallerPayload/
#       driver/SoundBridgeDriver.driver
#       manifest.plist
#       transaction.sh
#
# The driver lives in the payload rather than in a postinstall download on
# purpose: an installer whose privileged script fetches a binary is a privileged
# script that fetches a binary. Everything has to be inside the archive.
#
# Why the driver is NOT at its final path in the payload
# -----------------------------------------------------
# `installer` writes the payload itself. If the driver sat at
# /Library/Audio/Plug-Ins/HAL/..., the old driver would have to be deleted
# *before* that write, or `installer` would overlay the new bundle onto the old
# one and an old binary would survive under a new version string -- the exact
# bug that made upgrades lie. Deleting first leaves a window where the old
# driver is gone and the new one is not written yet: a failed copy, a full disk
# or a power cut there leaves the machine with no driver at all, and the app
# deliberately has no in-app upgrade path to repair it.
#
# So the payload only *stages* the driver in a directory nothing loads, and
# postinstall runs tools/sb_install_transaction.sh, which replaces the driver as
# a transaction: validate the payload, stage, validate the copy, back up the old
# bundle and validate the backup, move the old bundle aside by rename, move the
# new one in by rename, re-validate, and roll back on any failure. That is the
# same script tools/test_install_transaction.sh exercises against temp dirs.
#
# Usage
#   tools/build_installer_pkg.sh                      # dist/SoundBridge.app -> dist/
#   tools/build_installer_pkg.sh --app /path/App.app --out /tmp/out --version 1.2.0
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/SoundBridge.app"
OUT_DIR="$ROOT_DIR/dist"
VERSION=""
KEEP_WORK=0

DRIVER_NAME="SoundBridgeDriver.driver"
DRIVER_ID="com.soundbridge.driver"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
APP_ID="com.soundbridge.menubar"
SUPPORT_DIR="/Library/Application Support/SoundBridge"
PAYLOAD_SUPPORT="$SUPPORT_DIR/InstallerPayload"
STATE_SUPPORT="$SUPPORT_DIR/InstallerState"
TRANSACTION_SCRIPT="$ROOT_DIR/tools/sb_install_transaction.sh"
HEADER="$ROOT_DIR/packages/shared/include/RFSharedAudio.h"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)      APP_PATH="$2"; shift 2 ;;
        --out)      OUT_DIR="$2"; shift 2 ;;
        --version)  VERSION="$2"; shift 2 ;;
        --keep-work) KEEP_WORK=1; shift ;;
        -h|--help)  sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

fail() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }

for tool in /usr/bin/pkgbuild /usr/bin/productbuild /usr/bin/ditto /usr/bin/lipo /usr/libexec/PlistBuddy; do
    [[ -x "$tool" ]] || fail "required tool missing: $tool"
done

[[ -d "$APP_PATH" ]] || fail "app bundle not found: $APP_PATH (run 'make bundle' first)"
[[ -f "$HEADER" ]] || fail "protocol header not found: $HEADER"
[[ -f "$TRANSACTION_SCRIPT" ]] || fail "transaction script not found: $TRANSACTION_SCRIPT"

APP_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$APP_PLIST" ]] || fail "app Info.plist missing: $APP_PLIST"

if [[ -z "$VERSION" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || true)"
fi
[[ -n "$VERSION" ]] || fail "could not determine version; pass --version"

APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PLIST")"
[[ "$APP_BUNDLE_ID" == "$APP_ID" ]] || fail "unexpected app bundle id: $APP_BUNDLE_ID (expected $APP_ID)"

SOURCE_DRIVER="$APP_PATH/Contents/Resources/$DRIVER_NAME"
[[ -d "$SOURCE_DRIVER" ]] || fail "driver bundle not found inside the app: $SOURCE_DRIVER"

# The driver inside the app is the only thing that may be shipped as "matching".
DRIVER_ID_FOUND="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_DRIVER/Contents/Info.plist")"
[[ "$DRIVER_ID_FOUND" == "$DRIVER_ID" ]] || fail "unexpected driver bundle id: $DRIVER_ID_FOUND"

DRIVER_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_DRIVER/Contents/Info.plist")"
DRIVER_PROTOCOL="$(/usr/libexec/PlistBuddy -c 'Print :SBAudioProtocolVersion' "$SOURCE_DRIVER/Contents/Info.plist")"

# The version is baked into preinstall so the gate can run before the payload is
# written. A string the comparison cannot parse would turn that gate into a
# silent "allow", so an unparseable version fails the build instead.
[[ "$DRIVER_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    || fail "driver version '$DRIVER_VERSION' is not dot-separated digits; the installer gate could not compare it"
for seg in ${DRIVER_VERSION//./ }; do
    [[ ${#seg} -le 9 ]] \
        || fail "driver version '$DRIVER_VERSION' has a segment longer than the installer's comparison can hold"
done
[[ "$DRIVER_PROTOCOL" =~ ^[0-9]+$ ]] \
    || fail "driver protocol '$DRIVER_PROTOCOL' is not a decimal integer"

# The transaction validates these same fields at install time; reading them here
# means a broken driver is caught while building rather than on a user's machine.
DRIVER_EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SOURCE_DRIVER/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$DRIVER_EXE" ]] || DRIVER_EXE="${DRIVER_NAME%.driver}"
DRIVER_BIN="$SOURCE_DRIVER/Contents/MacOS/$DRIVER_EXE"
[[ -x "$DRIVER_BIN" ]] || fail "driver executable missing or not executable: $DRIVER_BIN"
DRIVER_ARCHS="$(/usr/bin/lipo -archs "$DRIVER_BIN")"
case "$DRIVER_ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) : ;;
    *) fail "the driver is not a universal binary: $DRIVER_ARCHS" ;;
esac

EXPECTED_PROTOCOL_HEX="$(sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+RF_AUDIO_PROTOCOL_VERSION[[:space:]]+(0x[0-9A-Fa-f]+)[uUlL]*.*$/\1/p' "$HEADER" | head -n 1)"
[[ -n "$EXPECTED_PROTOCOL_HEX" ]] || fail "could not read RF_AUDIO_PROTOCOL_VERSION from the header"
EXPECTED_PROTOCOL_HEX="${EXPECTED_PROTOCOL_HEX#0x}"
EXPECTED_PROTOCOL="$(( 0x${EXPECTED_PROTOCOL_HEX} ))"
[[ "$DRIVER_PROTOCOL" == "$EXPECTED_PROTOCOL" ]] \
    || fail "driver protocol $DRIVER_PROTOCOL != header 0x$EXPECTED_PROTOCOL_HEX ($EXPECTED_PROTOCOL)"

echo "Building installer package"
note "app:     $APP_PATH"
note "driver:  $DRIVER_VERSION (protocol $DRIVER_PROTOCOL, $DRIVER_ARCHS)"
note "version: $VERSION"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/soundbridge-pkg.XXXXXX")"
cleanup() {
    if [[ "$KEEP_WORK" == "1" ]]; then
        echo "  work dir kept: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

PAYLOAD="$WORK/payload"
SCRIPTS="$WORK/scripts"
PAYLOAD_STAGE="$PAYLOAD$PAYLOAD_SUPPORT"
mkdir -p "$PAYLOAD/Applications" "$PAYLOAD_STAGE/driver" "$SCRIPTS"

# ditto, not cp -R: it preserves resource forks, code signatures and symlinks,
# which a driver bundle has. Into an empty directory, so nothing can merge.
/usr/bin/ditto "$APP_PATH" "$PAYLOAD/Applications/SoundBridge.app"
/usr/bin/ditto "$SOURCE_DRIVER" "$PAYLOAD_STAGE/driver/$DRIVER_NAME"

# The transaction script is shipped verbatim: the copy that runs during the
# install is byte-identical to tools/sb_install_transaction.sh, which is what the
# test suite exercises. A divergence is caught by verify_installer_pkg.sh.
/bin/cp "$TRANSACTION_SCRIPT" "$PAYLOAD_STAGE/transaction.sh"
/bin/chmod 755 "$PAYLOAD_STAGE/transaction.sh"

# The manifest is the only place the transaction learns what it should be
# installing, so a driver swapped inside the archive cannot quietly change the
# expectations: the manifest is read from the archive too, and the two must agree.
cat > "$PAYLOAD_STAGE/manifest.plist" <<MANIFEST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$DRIVER_ID</string>
    <key>CFBundleShortVersionString</key><string>$DRIVER_VERSION</string>
    <key>SBAudioProtocolVersion</key><integer>$DRIVER_PROTOCOL</integer>
    <key>Architectures</key><string>$DRIVER_ARCHS</string>
</dict>
</plist>
MANIFEST

# --- preinstall -------------------------------------------------------------
# Runs as root before the payload is written. It cannot inspect the payload
# (nothing has been copied yet), so the version this package installs and the
# protocol it speaks are baked in here at build time. It deletes nothing -- the
# old driver is removed only after a verified backup exists.
#
# Phase 3.2: this gate used to live only in postinstall, which runs *after* the
# payload has landed. A refused downgrade therefore left the new app in
# /Applications next to the old driver. Refusing here aborts the install before
# a single payload file is copied. The transaction re-runs the same gate from the
# manifest before it replaces anything, so a change to the driver between the two
# scripts is still caught.
cat > "$SCRIPTS/preinstall" <<PREINSTALL
#!/bin/bash
set -uo pipefail

TARGET="$HAL_DIR/$DRIVER_NAME"
PARENT="$HAL_DIR"
EXPECTED_ID="$DRIVER_ID"
EXPECTED_VERSION="$DRIVER_VERSION"
EXPECTED_PROTOCOL="$DRIVER_PROTOCOL"

# Version strings are compared with bash arithmetic, which is 64-bit signed and
# wraps silently on overflow, so a segment longer than this is refused rather
# than compared wrongly. Same limit and same rules as
# tools/sb_install_transaction.sh, which re-checks the destination later.
MAX_COMPARE_DIGITS=9

version_problem() {
    local v="\$1" seg
    local -a parts
    if [[ -z "\$v" ]]; then
        echo "it is empty"
        return 0
    fi
    if [[ ! "\$v" =~ ^[0-9]+(\.[0-9]+)*\$ ]]; then
        echo "it is not dot-separated digits"
        return 0
    fi
    IFS='.' read -r -a parts <<<"\$v"
    for seg in "\${parts[@]}"; do
        if [[ \${#seg} -gt \$MAX_COMPARE_DIGITS ]]; then
            echo "segment '\$seg' has \${#seg} digits, more than the \$MAX_COMPARE_DIGITS this comparison can hold without wrapping"
            return 0
        fi
    done
    return 0
}

version_is_valid() {
    [[ -z "\$(version_problem "\$1")" ]]
}

# version_cmp A B -- prints -1, 0 or 1. Both operands must have passed
# version_is_valid first: this does no bounds checking of its own.
version_cmp() {
    local a="\$1" b="\$2" i n x y
    local -a pa pb
    IFS='.' read -r -a pa <<<"\$a"
    IFS='.' read -r -a pb <<<"\$b"
    n=\${#pa[@]}
    [[ \${#pb[@]} -gt \$n ]] && n=\${#pb[@]}
    for ((i = 0; i < n; i++)); do
        # \`:-0\` so 1.1 == 1.1.0; the 10# prefix stops bash reading 08 as octal.
        x="\${pa[i]:-0}"
        y="\${pb[i]:-0}"
        x=\$((10#\$x))
        y=\$((10#\$y))
        if ((x < y)); then echo -1; return 0; fi
        if ((x > y)); then echo 1; return 0; fi
    done
    echo 0
}

# Every refusal goes through here so the user is told, in the installer's own
# output, that the failure happened before anything was written.
refuse() {
    echo "refusing to install: \$*" >&2
    echo "nothing was written: no app was installed and \$TARGET was left untouched" >&2
    exit 1
}

if [[ ! -d "\$PARENT" ]]; then
    echo "\$PARENT does not exist; this does not look like a macOS audio system" >&2
    exit 1
fi

if [[ ! -e "\$TARGET" ]]; then
    echo "no SoundBridge driver is installed; this is a first install"
    exit 0
fi

PLIST="\$TARGET/Contents/Info.plist"
[[ -f "\$PLIST" ]] || refuse "\$TARGET exists but has no Contents/Info.plist; it is not a driver bundle"

ACTUAL_ID="\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "\$PLIST" 2>/dev/null)"
[[ -n "\$ACTUAL_ID" ]] || refuse "\$TARGET has no readable CFBundleIdentifier; refusing to replace a bundle that cannot be identified"
[[ "\$ACTUAL_ID" == "\$EXPECTED_ID" ]] || refuse "\$TARGET belongs to '\$ACTUAL_ID', not '\$EXPECTED_ID'"

OLD_VERSION="\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "\$PLIST" 2>/dev/null)"
[[ -n "\$OLD_VERSION" ]] || refuse "the installed driver has no CFBundleShortVersionString; refusing to replace a driver whose version cannot be read"
version_is_valid "\$OLD_VERSION" \
    || refuse "the installed driver reports an unparseable version '\$OLD_VERSION': \$(version_problem "\$OLD_VERSION") ; refusing to compare it"

OLD_PROTOCOL="\$(/usr/libexec/PlistBuddy -c 'Print :SBAudioProtocolVersion' "\$PLIST" 2>/dev/null)"
if [[ -n "\$OLD_PROTOCOL" ]]; then
    [[ "\$OLD_PROTOCOL" =~ ^[0-9]+\$ ]] || refuse "the installed driver declares an unreadable protocol '\$OLD_PROTOCOL'"
    [[ \${#OLD_PROTOCOL} -le \$MAX_COMPARE_DIGITS ]] \
        || refuse "the installed driver declares a protocol '\$OLD_PROTOCOL' with more digits than this comparison can hold"
    if (( OLD_PROTOCOL > EXPECTED_PROTOCOL )); then
        refuse "the installed driver speaks protocol \$OLD_PROTOCOL, newer than this package's \$EXPECTED_PROTOCOL; a package never downgrades the wire format"
    fi
    if (( OLD_PROTOCOL < EXPECTED_PROTOCOL )); then
        echo "protocol move: \$OLD_PROTOCOL -> \$EXPECTED_PROTOCOL; the package is newer on the wire format, so the version comparison does not apply"
        exit 0
    fi
else
    echo "the installed driver declares no SBAudioProtocolVersion (pre-1.2.0); comparing versions only"
fi

CMP="\$(version_cmp "\$OLD_VERSION" "\$EXPECTED_VERSION")"
case "\$CMP" in
    -1) echo "version move: \$OLD_VERSION -> \$EXPECTED_VERSION (upgrade)" ;;
     0) echo "reinstall: \$OLD_VERSION is already installed; replacing it with a fresh copy (same version)" ;;
     1) refuse "the installed driver is \$OLD_VERSION, newer than this package's \$EXPECTED_VERSION; refusing to downgrade" ;;
     *) refuse "version comparison produced '\$CMP' for '\$OLD_VERSION' vs '\$EXPECTED_VERSION'" ;;
esac

echo "an existing SoundBridge driver will be replaced by a verified transaction"
exit 0
PREINSTALL

# --- postinstall ------------------------------------------------------------
# Runs as root after the payload is written. It owns no transaction logic: it
# hands over to the script the payload carries, so the code that runs during an
# install is the code the test suite exercises against temporary directories.
#
# The script is copied out of the payload before it runs, because a successful
# install removes the payload directory.
cat > "$SCRIPTS/postinstall" <<POSTINSTALL
#!/bin/bash
set -uo pipefail

PAYLOAD_DIR="$PAYLOAD_SUPPORT"
STATE_DIR="$STATE_SUPPORT"
TARGET="$HAL_DIR/$DRIVER_NAME"

SCRIPT="\$PAYLOAD_DIR/transaction.sh"
DRIVER_SRC="\$PAYLOAD_DIR/driver"
MANIFEST="\$PAYLOAD_DIR/manifest.plist"

# Baked in at build time, independently of the payload. preinstall refused the
# install if the destination was newer than this; the check below refuses it
# again if the payload in the archive no longer describes the same driver (a
# hand-edited package, or a payload swapped between the two scripts). Neither
# check replaces the transaction's own gate, which runs against the manifest and
# the destination at install time.
EXPECTED_ID="$DRIVER_ID"
EXPECTED_VERSION="$DRIVER_VERSION"
EXPECTED_PROTOCOL="$DRIVER_PROTOCOL"

if [[ ! -f "\$SCRIPT" || ! -d "\$DRIVER_SRC" || ! -f "\$MANIFEST" ]]; then
    echo "the installer payload is incomplete: \$PAYLOAD_DIR" >&2
    exit 1
fi

M_ID="\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "\$MANIFEST" 2>/dev/null)"
M_VER="\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "\$MANIFEST" 2>/dev/null)"
M_PROTO="\$(/usr/libexec/PlistBuddy -c 'Print :SBAudioProtocolVersion' "\$MANIFEST" 2>/dev/null)"
if [[ "\$M_ID" != "\$EXPECTED_ID" || "\$M_VER" != "\$EXPECTED_VERSION" || "\$M_PROTO" != "\$EXPECTED_PROTOCOL" ]]; then
    echo "the payload manifest describes id='\$M_ID' version='\$M_VER' protocol='\$M_PROTO'" >&2
    echo "but this package was built for \$EXPECTED_ID \$EXPECTED_VERSION protocol \$EXPECTED_PROTOCOL" >&2
    echo "refusing to install from a payload that does not match the package; the driver on disk was not modified" >&2
    exit 1
fi

/bin/mkdir -p "\$STATE_DIR/log" || { echo "cannot create \$STATE_DIR" >&2; exit 1; }
RUNNER="\$STATE_DIR/transaction-\$\$.sh"
/bin/cp "\$SCRIPT" "\$RUNNER" || { echo "cannot stage the transaction script" >&2; exit 1; }

/bin/bash "\$RUNNER" --payload "\$DRIVER_SRC" --manifest "\$MANIFEST" --dest "\$TARGET" --state "\$STATE_DIR" --mode install
rc=\$?
/bin/rm -f "\$RUNNER"
/bin/rm -rf "\$PAYLOAD_DIR"

if [[ \$rc -eq 0 ]]; then
    # No killall. Restarting coreaudiod is a system-wide action with audible
    # side effects, and the product decided the installer does not take it. The
    # text below is what the user is actually told, so it promises only what has
    # been verified: the files are on disk, and CoreAudio picks them up the next
    # time it scans the HAL directory.
    echo "SoundBridge $VERSION installed its driver into \$TARGET"
    echo "The new driver takes effect the next time CoreAudio scans its HAL directory"
    echo "(for example after logging out and back in, or after a restart)."
    echo "This installer does not restart coreaudiod for you."
else
    echo "the driver install failed (exit \$rc); see \$STATE_DIR/log" >&2
    echo "The driver that was on disk before this install is still in place unless the log says otherwise."
fi

exit \$rc
POSTINSTALL

chmod +x "$SCRIPTS/preinstall" "$SCRIPTS/postinstall"

# The two scripts are generated by expanding heredocs, so a quoting mistake would
# only surface on a user's machine, as root, mid-install. Check them here.
for script in preinstall postinstall; do
    /bin/bash -n "$SCRIPTS/$script" || fail "generated $script has a syntax error"
done

# --- component plist ---------------------------------------------------------
# pkgbuild infers which bundles the payload carries and defaults them to
# BundleIsRelocatable=true on build hosts older than macOS 27. That flag lets
# Installer ignore the payload path: it searches the target volume for a bundle
# with the same identifier and upgrades that copy instead. 1.2.0 shipped that
# way. On a machine with a checkout of this repository under $HOME, Installer
# found dist/SoundBridge.app there and installed over it -- /Applications was
# never created, and the user had no way to know where the app went.
#
# It also matters for the driver: relocation matches by identifier, and the live
# driver at /Library/Audio/Plug-Ins/HAL carries the same one. A relocatable
# staged driver could be written straight to the HAL directory by Installer,
# which is the layout the whole transaction exists to avoid.
#
# BundleIsVersionChecked=false moves every version decision to preinstall. That
# gate already refuses downgrades and protocol changes, and it is the only place
# that knows the protocol rule outranks the version comparison. Installer's own
# check runs before it, on whichever bundle relocation found, so leaving it on
# would mean two independent judges -- and the right one is not the first.
#
# Neither flag is set by deleting <relocate> or <upgrade-bundle> from a finished
# PackageInfo: those are outputs of this analysis, and editing them afterwards
# would leave the Bom and the PackageInfo describing different packages.
COMPONENT_PLIST="$WORK/component.plist"
/usr/bin/pkgbuild --analyze --root "$PAYLOAD" "$COMPONENT_PLIST" >/dev/null \
    || fail "pkgbuild --analyze failed"

# Walks the inferred plist -- top-level bundles and their ChildBundles -- and
# pins both flags. The plist is nested, so this recurses rather than assuming a
# shape: Sparkle brings its own Updater.app and XPC services, and a payload
# change must not silently leave one of them relocatable.
set_bundle_flags() {
    local path="$1" child=0
    /usr/libexec/PlistBuddy -c "Set $path:BundleIsRelocatable false" "$COMPONENT_PLIST" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add $path:BundleIsRelocatable bool false" "$COMPONENT_PLIST" >/dev/null
    /usr/libexec/PlistBuddy -c "Set $path:BundleIsVersionChecked false" "$COMPONENT_PLIST" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add $path:BundleIsVersionChecked bool false" "$COMPONENT_PLIST" >/dev/null
    while /usr/libexec/PlistBuddy -c "Print $path:ChildBundles:$child:RootRelativeBundlePath" "$COMPONENT_PLIST" >/dev/null 2>&1; do
        set_bundle_flags "$path:ChildBundles:$child"
        child=$((child + 1))
    done
}

bundle_index=0
while /usr/libexec/PlistBuddy -c "Print :$bundle_index:RootRelativeBundlePath" "$COMPONENT_PLIST" >/dev/null 2>&1; do
    set_bundle_flags ":$bundle_index"
    bundle_index=$((bundle_index + 1))
done

# An empty plist would make pkgbuild fall back to its own inference, silently
# undoing everything above, so an app bundle with no entry is a build failure.
[[ "$bundle_index" -gt 0 ]] || fail "pkgbuild --analyze found no bundles in the payload"

# Read the flags back instead of trusting the writes above: PlistBuddy reports a
# missing key and a missing parent differently, and a key that silently did not
# land would ship exactly the bug this block exists to remove.
assert_bundle_flags() {
    local path="$1" child=0 value relative
    relative="$(/usr/libexec/PlistBuddy -c "Print $path:RootRelativeBundlePath" "$COMPONENT_PLIST" 2>/dev/null || true)"
    value="$(/usr/libexec/PlistBuddy -c "Print $path:BundleIsRelocatable" "$COMPONENT_PLIST" 2>/dev/null || true)"
    [[ "$value" == "false" ]] || fail "component plist leaves '$relative' relocatable (got '$value')"
    value="$(/usr/libexec/PlistBuddy -c "Print $path:BundleIsVersionChecked" "$COMPONENT_PLIST" 2>/dev/null || true)"
    [[ "$value" == "false" ]] || fail "component plist leaves '$relative' under Installer's version check (got '$value')"
    while /usr/libexec/PlistBuddy -c "Print $path:ChildBundles:$child:RootRelativeBundlePath" "$COMPONENT_PLIST" >/dev/null 2>&1; do
        assert_bundle_flags "$path:ChildBundles:$child"
        child=$((child + 1))
    done
}

checked_index=0
while /usr/libexec/PlistBuddy -c "Print :$checked_index:RootRelativeBundlePath" "$COMPONENT_PLIST" >/dev/null 2>&1; do
    assert_bundle_flags ":$checked_index"
    checked_index=$((checked_index + 1))
done

note "component plist: $bundle_index top-level bundle(s), relocation disabled"

# --- distribution -----------------------------------------------------------
cat > "$WORK/distribution.xml" <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>SoundBridge $VERSION</title>
    <organization>$APP_ID</organization>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <options customize="never" require-scripts="true" rootVolumeOnly="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="13.0"/>
        </allowed-os-versions>
    </volume-check>
    <pkg-ref id="$APP_ID"/>
    <choices-outline>
        <line choice="default">
            <line choice="$APP_ID"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$APP_ID" visible="false">
        <pkg-ref id="$APP_ID"/>
    </choice>
    <pkg-ref id="$APP_ID" version="$VERSION" onConclusion="none">SoundBridge.pkg</pkg-ref>
</installer-gui-script>
DIST

COMPONENT="$WORK/SoundBridge.pkg"
/usr/bin/pkgbuild \
    --root "$PAYLOAD" \
    --scripts "$SCRIPTS" \
    --component-plist "$COMPONENT_PLIST" \
    --identifier "$APP_ID" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT"

mkdir -p "$OUT_DIR"
OUTPUT="$OUT_DIR/SoundBridge-$VERSION.pkg"
/usr/bin/productbuild \
    --distribution "$WORK/distribution.xml" \
    --package-path "$WORK" \
    "$OUTPUT"

# The component plist is kept next to the package as evidence: it is the input
# that decides relocation, and the finished archive does not carry the flags back
# (an expanded PackageInfo only shows the resulting <relocate> list). Tools can
# then assert on it without rebuilding.
/bin/cp "$COMPONENT_PLIST" "$OUT_DIR/SoundBridge-$VERSION.component.plist"

echo ""
echo "Built (UNSIGNED, NOT NOTARIZED):"
note "$OUTPUT"
note "bundle relocation: disabled (component plist: $OUT_DIR/SoundBridge-$VERSION.component.plist)"
note "sha256: $(/usr/bin/shasum -a 256 "$OUTPUT" | awk '{print $1}')"
note "size:   $(/usr/bin/stat -f%z "$OUTPUT") bytes"
note "driver: $DRIVER_NAME $DRIVER_VERSION, protocol $DRIVER_PROTOCOL, $DRIVER_ARCHS"
note "installs: /Applications/SoundBridge.app plus a verified driver transaction"
note "coreaudiod is not restarted; the driver loads on the next HAL directory scan"
echo ""
echo "This artifact has not been installed. Verify it with:"
echo "  tools/verify_installer_pkg.sh \"$OUTPUT\""
