#!/bin/bash
#
# Verify an installer package without installing it.
#
# Phase 2.2.1: the artifact produced by build_installer_pkg.sh is the only path
# that replaces an old driver, so its contents are checked here rather than
# discovered on a user's machine. Everything below is read-only:
#   - `pkgutil --expand-full` into a temporary directory,
#   - `PlistBuddy`/`lipo`/`shasum`/`bash -n` on the extracted files,
#   - `pkgutil --check-signature` (report only).
# It never runs `installer`, `sudo`, or a package script.
#
# What is asserted, beyond "the files are there":
#   - the payload does NOT write the driver into the HAL directory (that layout
#     is what made a failed install unrecoverable),
#   - the packaged transaction script is byte-identical to the one the tests
#     exercise, reaches every stage, reports rollback failures and never
#     recursively deletes the destination,
#   - preinstall deletes nothing and postinstall does no transaction work itself.
#   - preinstall (Phase 3.2B) performs the version and protocol comparison itself,
#     using a target version baked into the script at build time. It must not read
#     the payload or the transaction state, both of which only exist after the
#     payload has been written -- a check that runs there cannot prevent the app
#     from being installed.
#
# Usage
#   tools/verify_installer_pkg.sh build/release-1.2.0/pkg/SoundBridge-1.2.0.pkg
#   tools/verify_installer_pkg.sh --allow-legacy-preinstall build/p32/SoundBridge-1.1.1.pkg
#
# `--allow-legacy-preinstall` reports the Phase 3.2B gate assertions as notes
# instead of failures. It exists so a package built before the gate moved into
# preinstall can still be inspected for everything else, and so the difference
# between the two packages can be stated factually instead of assumed.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOW_LEGACY_PREINSTALL=0
PKG=""
for arg in "$@"; do
    case "$arg" in
        --allow-legacy-preinstall) ALLOW_LEGACY_PREINSTALL=1 ;;
        -h|--help)
            echo "usage: $0 [--allow-legacy-preinstall] <path-to.pkg>"
            exit 0
            ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)
            [[ -z "$PKG" ]] || { echo "unexpected extra argument: $arg" >&2; exit 2; }
            PKG="$arg"
            ;;
    esac
done

DRIVER_NAME="SoundBridgeDriver.driver"
DRIVER_ID="com.soundbridge.driver"
APP_ID="com.soundbridge.menubar"
HAL_REL="Library/Audio/Plug-Ins/HAL"
SUPPORT_REL="Library/Application Support/SoundBridge/InstallerPayload"
SOURCE_TX="$ROOT_DIR/tools/sb_install_transaction.sh"
HEADER="$ROOT_DIR/packages/shared/include/RFSharedAudio.h"

fail() { echo "FAIL  $*" >&2; exit 1; }
pass() { echo "ok    $*"; }

[[ -n "$PKG" ]] || { echo "usage: $0 <path-to.pkg>" >&2; exit 2; }
[[ -f "$PKG" ]] || fail "package not found: $PKG"

EXPECTED_PROTOCOL_HEX="$(sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+RF_AUDIO_PROTOCOL_VERSION[[:space:]]+(0x[0-9A-Fa-f]+)[uUlL]*.*$/\1/p' "$HEADER" | head -n 1)"
[[ -n "$EXPECTED_PROTOCOL_HEX" ]] || fail "could not read RF_AUDIO_PROTOCOL_VERSION from the header"
EXPECTED_PROTOCOL_HEX="${EXPECTED_PROTOCOL_HEX#0x}"
EXPECTED_PROTOCOL="$(( 0x${EXPECTED_PROTOCOL_HEX} ))"

echo "Verifying $PKG"
echo "  expected driver protocol: 0x$EXPECTED_PROTOCOL_HEX ($EXPECTED_PROTOCOL)"
echo ""

# --- signature (informational) ----------------------------------------------
SIGNATURE="$(/usr/sbin/pkgutil --check-signature "$PKG" 2>&1 || true)"
if echo "$SIGNATURE" | grep -q "signed"; then
    pass "signature status: signed (verify the certificate chain separately)"
    echo "$SIGNATURE" | sed 's/^/      /'
else
    echo "note  signature status: UNSIGNED — expected for the prototype; Gatekeeper will warn"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/soundbridge-pkgverify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

/usr/sbin/pkgutil --expand-full "$PKG" "$WORK/expanded" >/dev/null 2>&1 \
    || fail "pkgutil --expand-full failed"

PAYLOAD="$(find "$WORK/expanded" -maxdepth 3 -type d -name Payload | head -1)"
SCRIPTS="$(find "$WORK/expanded" -maxdepth 3 -type d -name Scripts | head -1)"
[[ -n "$PAYLOAD" ]] || fail "no expanded payload found"
[[ -n "$SCRIPTS" ]] || fail "no scripts directory found"

# --- 1. payload contents ----------------------------------------------------
TOP_LEVEL="$(cd "$PAYLOAD" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort)"
EXPECTED_TOP_LEVEL=$'Applications\nLibrary'
if [[ "$TOP_LEVEL" != "$EXPECTED_TOP_LEVEL" ]]; then
    echo "$TOP_LEVEL" | sed 's/^/      /'
    fail "unexpected top-level payload entries (expected exactly Applications and Library)"
fi
pass "payload has exactly Applications/ and Library/"

# --- 1b. no bundle relocation ------------------------------------------------
# When a package allows relocation, Installer resolves each bundle by identifier
# and installs over whichever copy it finds on the target volume -- the payload
# path is a suggestion. 1.2.0 shipped that way: on a machine with a checkout of
# this repository under $HOME, the app was installed over that checkout's
# dist/SoundBridge.app and /Applications was never created.
#
# The allow-list is recorded inside <relocate> in the component's PackageInfo.
# An empty <relocate/> is the only shape that pins every bundle to its payload
# path, so a single <bundle> entry between the tags is a release blocker.
PKGINFO="$(find "$WORK/expanded" -maxdepth 3 -type f -name PackageInfo | head -1)"
[[ -n "$PKGINFO" ]] || fail "no PackageInfo in the expanded package"
RELOCATION_LIST="$(/usr/bin/sed -n '/<relocate>/,/<\/relocate>/p' "$PKGINFO" | /usr/bin/grep '<bundle' || true)"
if [[ -n "$RELOCATION_LIST" ]]; then
    echo "$RELOCATION_LIST" | sed 's/^/      /'
    fail "the package allows bundle relocation; Installer would install over any same-identifier bundle on the volume instead of the payload path"
fi
pass "no bundle in the package may be relocated"

APP="$PAYLOAD/Applications/SoundBridge.app"
STAGE="$PAYLOAD/$SUPPORT_REL"
DRIVER="$STAGE/driver/$DRIVER_NAME"
TX="$STAGE/transaction.sh"
MANIFEST="$STAGE/manifest.plist"
[[ -d "$APP" ]] || fail "app bundle missing from payload"
[[ -d "$DRIVER" ]] || fail "driver bundle missing from the staging directory"
pass "payload contains the app and the staged driver"

# Regression guard. If the driver ever appears at its final path in the payload,
# `installer` writes it itself, which means the old driver has to be deleted
# before that write -- and a failure in between leaves the machine with no
# driver. That is exactly the bug this layout exists to remove.
if [[ -e "$PAYLOAD/$HAL_REL/$DRIVER_NAME" ]]; then
    fail "the payload installs the driver directly into $HAL_REL; the transaction would be bypassed"
fi
pass "the payload does not write into the HAL directory"

STAGE_ENTRIES="$(cd "$STAGE" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort)"
EXPECTED_STAGE_ENTRIES=$'driver\nmanifest.plist\ntransaction.sh'
if [[ "$STAGE_ENTRIES" != "$EXPECTED_STAGE_ENTRIES" ]]; then
    echo "$STAGE_ENTRIES" | sed 's/^/      /'
    fail "unexpected entries in the staging directory"
fi
pass "staging directory holds driver/, manifest.plist and transaction.sh"

if [[ -n "$(find "$PAYLOAD" -name '.*.new' -o -name '*.orig' 2>/dev/null)" ]]; then
    fail "staging leftovers found in the payload"
fi
pass "no staging leftovers"

# --- 2. app metadata --------------------------------------------------------
APP_PLIST="$APP/Contents/Info.plist"
[[ -f "$APP_PLIST" ]] || fail "app Info.plist missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PLIST")" == "$APP_ID" ]] \
    || fail "unexpected app bundle id"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
pass "app id $APP_ID, version $APP_VERSION"

[[ -x "$APP/Contents/MacOS/SoundBridgeApp" ]] || fail "app executable missing or not executable"
APP_ARCHS="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/SoundBridgeApp")"
case "$APP_ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) pass "app architectures: $APP_ARCHS" ;;
    *) fail "app is not universal: $APP_ARCHS" ;;
esac

# --- 3. driver metadata -----------------------------------------------------
DRIVER_PLIST="$DRIVER/Contents/Info.plist"
[[ -f "$DRIVER_PLIST" ]] || fail "driver Info.plist missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DRIVER_PLIST")" == "$DRIVER_ID" ]] \
    || fail "unexpected driver bundle id"
DRIVER_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DRIVER_PLIST")"
DRIVER_PROTOCOL="$(/usr/libexec/PlistBuddy -c 'Print :SBAudioProtocolVersion' "$DRIVER_PLIST")"
[[ "$DRIVER_PROTOCOL" == "$EXPECTED_PROTOCOL" ]] \
    || fail "driver protocol $DRIVER_PROTOCOL does not match the header ($EXPECTED_PROTOCOL)"
pass "driver id $DRIVER_ID, version $DRIVER_VERSION, protocol $DRIVER_PROTOCOL"

DRIVER_BIN="$DRIVER/Contents/MacOS/SoundBridgeDriver"
[[ -x "$DRIVER_BIN" ]] || fail "driver executable missing or not executable"
DRIVER_ARCHS="$(/usr/bin/lipo -archs "$DRIVER_BIN")"
case "$DRIVER_ARCHS" in
    *arm64*x86_64*|*x86_64*arm64*) pass "driver architectures: $DRIVER_ARCHS" ;;
    *) fail "driver is not universal: $DRIVER_ARCHS" ;;
esac

# --- 4. app and driver agree ------------------------------------------------
# The whole point of the package: one artifact, one pair. A package whose app
# expects a newer protocol than the driver it carries is the failure mode users
# are recovering from.
EMBEDDED="$APP/Contents/Resources/$DRIVER_NAME"
if [[ -d "$EMBEDDED" ]]; then
    EMBEDDED_PROTOCOL="$(/usr/libexec/PlistBuddy -c 'Print :SBAudioProtocolVersion' "$EMBEDDED/Contents/Info.plist" 2>/dev/null || true)"
    EMBEDDED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$EMBEDDED/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$EMBEDDED_PROTOCOL" == "$DRIVER_PROTOCOL" ]] \
        || fail "app embeds driver protocol $EMBEDDED_PROTOCOL but the payload installs $DRIVER_PROTOCOL"
    [[ "$EMBEDDED_VERSION" == "$DRIVER_VERSION" ]] \
        || fail "app embeds driver $EMBEDDED_VERSION but the payload installs $DRIVER_VERSION"
    pass "app-embedded driver matches the installed driver ($DRIVER_VERSION, protocol $DRIVER_PROTOCOL)"

    EMBEDDED_SUM="$(/usr/bin/shasum -a 256 "$EMBEDDED/Contents/MacOS/SoundBridgeDriver" | awk '{print $1}')"
    PAYLOAD_SUM="$(/usr/bin/shasum -a 256 "$DRIVER_BIN" | awk '{print $1}')"
    [[ "$EMBEDDED_SUM" == "$PAYLOAD_SUM" ]] \
        || fail "the driver in the payload is not the driver inside the app (binary differs)"
    pass "driver binary is byte-identical to the one the app carries"
else
    fail "the app does not carry a driver bundle; the install would replace the driver with nothing"
fi

# --- 5. manifest ------------------------------------------------------------
# The transaction takes its expectations from the manifest, so the manifest has
# to describe the driver that is actually in the archive.
[[ -f "$MANIFEST" ]] || fail "the staging directory has no manifest.plist"
M_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$MANIFEST" 2>/dev/null)"
M_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MANIFEST" 2>/dev/null)"
M_PROTO="$(/usr/libexec/PlistBuddy -c 'Print :SBAudioProtocolVersion' "$MANIFEST" 2>/dev/null)"
M_ARCHS="$(/usr/libexec/PlistBuddy -c 'Print :Architectures' "$MANIFEST" 2>/dev/null)"
[[ "$M_ID" == "$DRIVER_ID" ]] || fail "manifest bundle id '$M_ID' is not $DRIVER_ID"
[[ "$M_VER" == "$DRIVER_VERSION" ]] \
    || fail "manifest version '$M_VER' is not the driver's version $DRIVER_VERSION"
[[ "$M_PROTO" == "$DRIVER_PROTOCOL" ]] \
    || fail "manifest protocol '$M_PROTO' is not the driver's protocol $DRIVER_PROTOCOL"
[[ -n "$M_ARCHS" ]] || fail "manifest does not declare any architecture"
for want in $M_ARCHS; do
    case " $DRIVER_ARCHS " in
        *" $want "*) : ;;
        *) fail "manifest requires architecture '$want' but the driver has '$DRIVER_ARCHS'" ;;
    esac
done
pass "manifest matches the driver it ships ($M_VER, protocol $M_PROTO, $M_ARCHS)"

# --- 6. transaction script --------------------------------------------------
[[ -f "$TX" ]] || fail "the payload has no transaction script"
[[ -x "$TX" ]] || fail "the transaction script is not executable"
/bin/bash -n "$TX" || fail "the transaction script has a syntax error"
pass "transaction script present, executable, syntactically valid"

# The packaged copy must be the one the tests exercise: a hand-edited variant
# inside the archive would be code nobody has run against a temp directory.
[[ -f "$SOURCE_TX" ]] || fail "the source transaction script is missing: $SOURCE_TX"
TX_SUM="$(/usr/bin/shasum -a 256 "$TX" | awk '{print $1}')"
SRC_SUM="$(/usr/bin/shasum -a 256 "$SOURCE_TX" | awk '{print $1}')"
[[ "$TX_SUM" == "$SRC_SUM" ]] \
    || fail "the packaged transaction script differs from tools/sb_install_transaction.sh"
pass "the transaction script is byte-identical to the tested source"

for stage in PRECHECK STAGING VALIDATING BACKUP_OLD REPLACING VERIFYING SUCCESS ROLLBACK; do
    grep -q "STAGE=\"$stage\"" "$TX" || fail "the transaction never reaches the $stage stage"
done
pass "the transaction implements every stage of the design"

grep -q "ROLLBACK FAILED" "$TX" \
    || fail "a failed rollback would not be reported separately"
grep -q -- "--mode recover" "$TX" \
    || fail "the transaction has no recovery entry point for an interrupted install"
grep -q "transaction.state" "$TX" \
    || fail "the transaction does not record its progress, so an interrupted run cannot be recovered"
pass "a failed rollback is reported and an interrupted run can be recovered"

if grep -q 'set -euo pipefail' "$TX"; then
    fail "the transaction relies on set -e rather than handling each failure"
fi
pass "the transaction does not rely on set -e for its safety"

if grep -Eq 'rm[[:space:]]+-rf[[:space:]]+"?\$DEST' "$TX"; then
    fail "the transaction recursively deletes the destination"
fi
grep -q 'mv "\$DEST"' "$TX" || fail "the transaction never moves the old bundle aside"
pass "the old bundle is moved aside by rename, never recursively deleted"

# --- 7. package scripts -----------------------------------------------------
for script in preinstall postinstall; do
    [[ -f "$SCRIPTS/$script" ]] || fail "missing $script script"
    [[ -x "$SCRIPTS/$script" ]] || fail "$script is not executable"
    /bin/bash -n "$SCRIPTS/$script" || fail "$script has a syntax error"
done
pass "preinstall and postinstall present, executable, syntactically valid"

for script in preinstall postinstall; do
    if grep -Eq 'sudo|curl|wget|https?://' "$SCRIPTS/$script"; then
        fail "$script contains a privileged escape or a network fetch"
    fi
done
pass "no sudo and no network fetch in the package scripts"

# preinstall runs before the payload is written. Anything it deletes is gone
# before there is anything to replace it with.
if grep -Eq 'rm[[:space:]]+-rf[[:space:]]+"?\$TARGET' "$SCRIPTS/preinstall"; then
    fail "preinstall deletes the installed driver before the payload is written"
fi
grep -q "CFBundleIdentifier" "$SCRIPTS/preinstall" \
    || fail "preinstall does not check what is already at the destination"
pass "preinstall checks the destination's identity and deletes nothing"

# --- 7b. version gate, moved in front of the payload (Phase 3.2B) -----------
#
# `installer` unpacks the payload before it runs postinstall. Putting the
# version refusal in postinstall therefore meant a refused package still left a
# new app in /Applications next to the older driver: the package reported
# failure and the machine had still been changed. The comparison now happens in
# preinstall, and it cannot read the payload to learn what it installs, so the
# target version and protocol are written into the script at build time.
#
# What this block proves, statically, is the shape that makes that possible:
# the expectations are literal and baked in, they match the driver this package
# actually carries, the comparison is the same one the transaction makes (or it
# could disagree with it later), and preinstall touches nothing on disk.
# Whether `installer` runs preinstall before unpacking is macOS behaviour, not
# something this file can prove -- see the roundtrip test for the observed order.

gate_fail() {
    if [[ "$ALLOW_LEGACY_PREINSTALL" -eq 1 ]]; then
        echo "note  $* (--allow-legacy-preinstall)" >&2
        return 0
    fi
    fail "$*"
}

PRE="$SCRIPTS/preinstall"
POST="$SCRIPTS/postinstall"

for want in "EXPECTED_ID=\"$DRIVER_ID\"" \
            "EXPECTED_VERSION=\"$DRIVER_VERSION\"" \
            "EXPECTED_PROTOCOL=\"$DRIVER_PROTOCOL\""; do
    grep -qxF "$want" "$PRE" \
        || gate_fail "preinstall does not carry '$want'; it cannot know the target version before the payload exists"
done
for want in "EXPECTED_ID=\"$DRIVER_ID\"" \
            "EXPECTED_VERSION=\"$DRIVER_VERSION\"" \
            "EXPECTED_PROTOCOL=\"$DRIVER_PROTOCOL\""; do
    grep -qxF "$want" "$POST" \
        || gate_fail "postinstall does not carry '$want'; it cannot cross-check the payload's manifest against the package"
done
pass "preinstall and postinstall both carry id/version/protocol baked in at build time"

for want in version_problem version_is_valid version_cmp MAX_COMPARE_DIGITS '10#$x'; do
    grep -qF "$want" "$PRE" \
        || gate_fail "preinstall's comparison is missing '$want', so it does not match the transaction's rules"
done
pass "preinstall compares versions the way the transaction does (bounded segments, no octal)"

grep -qF 'refusing to downgrade' "$PRE" \
    || gate_fail "preinstall would not refuse a driver newer than the package"
grep -qF 'never downgrades the wire format' "$PRE" \
    || gate_fail "preinstall checks the version without checking the protocol first"
pass "preinstall refuses downgrades and puts the protocol ahead of the version"

# The Refusal has to be a real failure: an exit code of 0 would let `installer`
# go on and unpack the payload anyway, which is the bug being fixed.
REFUSE_BODY="$(awk '/^refuse\(\)/,/^}/' "$PRE")"
[[ -n "$REFUSE_BODY" ]] || gate_fail "preinstall has no refuse() helper, so refusals are not funnelled through one place"
grep -q 'exit 1' <<<"$REFUSE_BODY" \
    || gate_fail "preinstall's refusal path does not exit non-zero"
pass "preinstall's refusal path exits non-zero"

# Independence from the payload is the whole point: at preinstall time there is
# no payload on disk, and no transaction state either. Reading either one would
# make the gate silently pass (or crash) instead of refusing.
if grep -Eq 'InstallerPayload|InstallerState|transaction\.state' "$PRE"; then
    gate_fail "preinstall reads the payload or the transaction state, neither of which exists when preinstall runs"
fi
if grep -Eq '^[^#]*transaction\.sh' "$PRE"; then
    gate_fail "preinstall runs the transaction, which belongs to postinstall"
fi
pass "preinstall depends on nothing that is written after it runs"

# preinstall must not write, delete or move anything. A refusal is only safe if
# the machine is in the same state afterwards, and a success is only safe
# because the transaction does the writing.
if grep -Eq '^[^#]*([[:space:]/]|^)(mkdir|cp|mv|rm|touch|chmod|chown|ln)[[:space:]]' "$PRE"; then
    echo "      $(grep -En '^[^#]*([[:space:]/]|^)(mkdir|cp|mv|rm|touch|chmod|chown|ln)[[:space:]]' "$PRE" | head -3 | sed 's/^/      /')" >&2
    gate_fail "preinstall modifies the filesystem; only the transaction may write"
fi
if grep -Eq '^[^#]*>>?[[:space:]]*"?\$(TARGET|PARENT|PLIST)' "$PRE"; then
    gate_fail "preinstall redirects output onto the driver or its parent directory"
fi
pass "preinstall writes nothing outside stderr"

# postinstall keeps its own defence (Phase 3.2B §2.5): if the payload in the
# archive does not describe the driver this package was built for, the install
# stops before the transaction is handed control. That check has to come before
# the state directory is created, or a refused run would leave transaction state
# behind for a package that never started.
M_LINE="$(grep -n 'M_VER" != "\$EXPECTED_VERSION' "$POST" 2>/dev/null | head -1 | cut -d: -f1 || true)"
S_LINE="$(grep -n 'mkdir -p "\$STATE_DIR' "$POST" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [[ -z "$M_LINE" || -z "$S_LINE" ]]; then
    gate_fail "postinstall no longer cross-checks the payload manifest before it starts the transaction"
elif [[ "$M_LINE" -ge "$S_LINE" ]]; then
    gate_fail "postinstall creates its state directory before it validates the payload ($M_LINE >= $S_LINE)"
fi
pass "postinstall cross-checks the payload manifest before creating any state"

grep -q '^exit \$rc$' "$POST" \
    || gate_fail "postinstall does not propagate the transaction's exit status, so a failed install can report success"
pass "postinstall reports failure as failure"

grep -q "transaction.sh" "$SCRIPTS/postinstall" \
    || fail "postinstall does not run the install transaction"
grep -q -- "--mode install" "$SCRIPTS/postinstall" \
    || fail "postinstall does not run the transaction in install mode"
grep -q "manifest.plist" "$SCRIPTS/postinstall" \
    || fail "postinstall does not pass the manifest to the transaction"
pass "postinstall hands over to the transaction script"

# Restarting coreaudiod is a system-wide side effect with audible consequences,
# and the product decided the installer does not take it. The check looks at
# executable lines only, so the comment explaining the absence cannot trip it.
if grep -Eq '^[^#]*(killall|launchctl)' "$SCRIPTS/postinstall"; then
    fail "postinstall restarts CoreAudio or reloads services on its own"
fi
grep -q "does not restart coreaudiod" "$SCRIPTS/postinstall" \
    || fail "postinstall does not tell the user when the driver actually takes effect"
pass "postinstall restarts nothing and states when the driver takes effect"

grep -q 'transaction.lock' "$TX" \
    || fail "the transaction has no exclusive lock, so two runs can rewrite each other's state"
grep -q 'mkdir "$LOCK_DIR"' "$TX" \
    || fail "the lock is not claimed atomically"
grep -q 'acquire_lock' "$TX" \
    || fail "nothing calls the lock acquisition"
grep -q 'release_lock' "$TX" \
    || fail "the lock has no release path"
grep -q 'has recorded no owner' "$TX" \
    || fail "a lock whose pid is not written yet could be mistaken for a dead one"
grep -q 'LOCK_DIR.reclaim' "$TX" \
    || fail "reclaiming a stale lock is not serialised, so two runs can both delete one"
pass "the transaction takes an atomic exclusive lock before touching state"
pass "the lock survives the gap between claiming the directory and recording its owner"

grep -q 'gate_existing_driver' "$TX" \
    || fail "the transaction replaces whatever is at the destination without a version gate"
grep -q 'version_cmp' "$TX" \
    || fail "the transaction has no version comparison"
grep -q 'never downgrades the wire format' "$TX" \
    || fail "the transaction does not put the protocol ahead of the version"
grep -q 'refusing to downgrade' "$TX" \
    || fail "the transaction would install an older driver over a newer one"
grep -q 'MAX_COMPARE_DIGITS' "$TX" \
    || fail "a version segment that overflows the comparison would be compared anyway"
pass "the transaction refuses downgrades and checks the protocol before the version"

grep -q '/bin/sync' "$TX" \
    || fail "the write-ahead state is never flushed, so a crash can leave a stitched-together record"
pass "the write-ahead state is flushed to disk around the rename"

grep -q "chown" "$TX" || fail "nothing sets the driver's ownership"
grep -q "chmod" "$TX" || fail "nothing sets the driver's permissions"
pass "the transaction sets ownership and permissions"

# --- 8. distribution --------------------------------------------------------
DIST_FILE="$(find "$WORK/expanded" -maxdepth 2 -name Distribution | head -1)"
if [[ -n "$DIST_FILE" ]]; then
    grep -q 'enable_localSystem="true"' "$DIST_FILE" || fail "distribution does not target the local system domain"
    grep -q 'min="13.0"' "$DIST_FILE" || fail "distribution does not pin the minimum OS version"
    pass "distribution targets the system domain and macOS 13+"
else
    echo "note  no Distribution file (single flat package)"
fi

echo ""
echo "PASS  $PKG"
echo "      app $APP_VERSION (universal) + driver $DRIVER_VERSION protocol $DRIVER_PROTOCOL (universal)"
echo "      nothing was installed; this check is read-only"
