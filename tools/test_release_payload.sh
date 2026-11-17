#!/bin/bash
#
# Damage tests for the release-payload verifiers (Phase 2.2.2 - Batch B).
#
# A verifier that never fails proves nothing. Each section below takes a copy of
# a real artifact, damages exactly one thing, and asserts that the matching
# verifier notices, names the damage, and exits non-zero. dist/ is only ever
# read: every fixture is built in a scratch directory and thrown away.
#
# Sections
#   B-1  package: a modified driver file, a missing executable, a changed
#        Info.plist, a diverging symlink target, a removed subdirectory, an
#        extra file, a permission change, a changed protocol -- inside the
#        package and in the third copy in dist/
#   B-2  package: a single-architecture driver
#   B-3  packager: versioned naming, a failed run that must not destroy the
#        previous image, the pre-check, and the bundle make and the packager
#        both use; both backends
#   B-4  image: missing Sparkle, missing driver, wrong payload version, wrong
#        file name version, single-architecture host, a missing file, the host
#        version evidence level, a SIGTERM and a SIGINT in the middle of a
#        mount, an injected detach failure, and a SIGKILL that no trap can catch
#   B-5  unified entry point: PASS, NOT_VERIFIED and FAIL summaries
#   B-6  the fourth copy: the driver inside the image, compared with the other
#        three -- a modified executable, a deleted file, an extra file, a
#        symlink, a permission change, an Info.plist, a protocol, a corrupt
#        image, an image without the app and an image without the driver; plus
#        a bundle in dist/ that differs while the image still matches
#
# Needs hdiutil and the real artifacts in dist/. Prints "passed: N failed: N"
# and exits non-zero if anything failed. The verifier paths can be overridden
# (VERIFY_PKG, VERIFY_DMG, VERIFY_ALL, CREATE_DMG) so a deliberately broken copy
# of a script can be run against the same suite.
#
# Usage
#   tools/test_release_payload.sh              # run everything
#   KEEP_SCRATCH=1 tools/test_release_payload.sh   # keep the fixtures for a look
#
set -uo pipefail

case "${1:-}" in
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    "") : ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/soundbridge-batchb.XXXXXX")" || exit 1
mkdir -p "$T/fixtures" "$T/dmgout"
# The DMG verifier mounts under TMPDIR; pointing it here is what lets the mount
# hygiene section look for a volume that a run failed to unmount.
export TMPDIR="$T"

cleanup_scratch() {
    if [[ "${KEEP_SCRATCH:-0}" == "1" ]]; then
        echo "scratch kept at $T"
    else
        rm -rf "$T"
    fi
}
trap cleanup_scratch EXIT

VERIFY_PKG="${VERIFY_PKG:-$ROOT/tools/verify_pkg_contents.sh}"
VERIFY_DMG="${VERIFY_DMG:-$ROOT/tools/verify_dmg_contents.sh}"
VERIFY_ALL="${VERIFY_ALL:-$ROOT/tools/verify_release_payload.sh}"
CREATE_DMG="${CREATE_DMG:-$ROOT/tools/create_dmg.sh}"

REAL_PKG="$ROOT/dist/SoundBridge-1.1.1.pkg"
REAL_DMG="$ROOT/dist/SoundBridge-1.1.1.dmg"
REAL_APP="$ROOT/dist/SoundBridge.app"

PASSED=0
FAILED=0
ok()   { PASSED=$((PASSED + 1)); echo "  ok   $*"; }
bad()  { FAILED=$((FAILED + 1)); echo "  FAIL $*"; }
is()   { if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else bad "$1: expected '$3', got '$2'"; fi; }
has()  { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1: '$2' not found in $3"; fi; }
hasnt(){ if grep -qF -- "$2" "$3"; then bad "$1: '$2' unexpectedly present"; else ok "$1"; fi; }
section() { echo ""; echo "== $1 =="; }

PKG_OUT="$T/pkg.out"
DMG_OUT="$T/dmg.out"

run_pkg() { local rc=0; "$VERIFY_PKG" "$@" > "$PKG_OUT" 2>&1 || rc=$?; echo "$rc"; }
run_dmg() { local rc=0; "$VERIFY_DMG" "$@" > "$DMG_OUT" 2>&1 || rc=$?; echo "$rc"; }

# ---------------------------------------------------------------- PKG fixtures
APP_DRIVER=""
STAGED=""

mutate_pkg() {   # <name> <mutator function>
    local name="$1" fn="$2" d="$T/expand-$1"
    rm -rf "$d"
    /usr/sbin/pkgutil --expand-full "$REAL_PKG" "$d" >/dev/null 2>&1 || { bad "expand failed for $name"; return 1; }
    APP_DRIVER="$d/SoundBridge.pkg/Payload/Applications/SoundBridge.app/Contents/Resources/SoundBridgeDriver.driver"
    STAGED="$d/SoundBridge.pkg/Payload/Library/Application Support/SoundBridge/InstallerPayload/driver/SoundBridgeDriver.driver"
    "$fn" || bad "mutator $fn failed"
    /usr/sbin/pkgutil --flatten "$d" "$T/fixtures/$name.pkg" >/dev/null 2>&1 || bad "flatten failed for $name"
    rm -rf "$d"
}

m_modfile()    { printf 'X' >> "$STAGED/Contents/MacOS/SoundBridgeDriver"; }
# The second copy, the one inside the packaged app: it is built by the same
# step as the staged copy, so a test that only damages the staged one cannot see
# a defect that affects only this side.
m_modapp()     { printf 'X' >> "$APP_DRIVER/Contents/MacOS/SoundBridgeDriver"; }
m_noexec()     { rm -f "$STAGED/Contents/MacOS/SoundBridgeDriver"; }
m_plist()      { /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9.9' "$STAGED/Contents/Info.plist" >/dev/null; }
# Both copies get a symlink that resolves, with a different target on each side:
# pkgutil --flatten drops dangling links, and the point of the case is that the
# target string differs while every file stays identical.
m_symlink()    { ln -s Contents "$APP_DRIVER/Variants"; ln -s Contents/MacOS "$STAGED/Variants"; }
m_nosubdir()   { rm -rf "$STAGED/Contents/MacOS"; }
m_extrafile()  { mkdir -p "$STAGED/Contents/Resources"; printf 'extra\n' > "$STAGED/Contents/Resources/extra.txt"; }
# 700 keeps the executable readable and runnable by its owner, so the change is
# a permission difference and nothing else: the bytes still match everywhere.
m_perm()       { /bin/chmod 700 "$STAGED/Contents/MacOS/SoundBridgeDriver"; }
m_protocol()   { /usr/libexec/PlistBuddy -c 'Set :SBAudioProtocolVersion 999' "$STAGED/Contents/Info.plist" >/dev/null; }
m_singlearch() {
    /usr/bin/lipo -thin arm64 -output "$T/thin-driver" "$STAGED/Contents/MacOS/SoundBridgeDriver" >/dev/null 2>&1
    /bin/cp "$T/thin-driver" "$STAGED/Contents/MacOS/SoundBridgeDriver"
    /bin/chmod 755 "$STAGED/Contents/MacOS/SoundBridgeDriver"
}

echo "Building fixtures from $REAL_PKG and $REAL_DMG"
for pair in "modfile:m_modfile" "modapp:m_modapp" "noexec:m_noexec" "plistbad:m_plist" "symlink:m_symlink" \
            "nosubdir:m_nosubdir" "extrafile:m_extrafile" "perm:m_perm" \
            "protocol:m_protocol" "singlearch:m_singlearch"; do
    mutate_pkg "${pair%%:*}" "${pair##*:}"
done

section "B-1: PKG driver consistency"
rc="$(run_pkg "$REAL_PKG")"
is "normal package exits 0" "$rc" "0"
is "normal package tree match"      "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=true"
is "normal package executable match" "$(grep -m1 '^DRIVER_EXECUTABLE_MATCH=' "$PKG_OUT")" "DRIVER_EXECUTABLE_MATCH=true"
is "normal package plist match"      "$(grep -m1 '^DRIVER_INFO_PLIST_MATCH=' "$PKG_OUT")" "DRIVER_INFO_PLIST_MATCH=true"
is "normal package protocol match"   "$(grep -m1 '^DRIVER_PROTOCOL_MATCH=' "$PKG_OUT")" "DRIVER_PROTOCOL_MATCH=true"

rc="$(run_pkg "$T/fixtures/modfile.pkg")"
is "modified driver file exits non-zero" "$rc" "1"
is "modified driver file breaks the tree" "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=false"
is "modified driver file breaks the executable" "$(grep -m1 '^DRIVER_EXECUTABLE_MATCH=' "$PKG_OUT")" "DRIVER_EXECUTABLE_MATCH=false"
has "modified driver file names the executable" "driver executables differ" "$PKG_OUT"

rc="$(run_pkg "$T/fixtures/modapp.pkg")"
is "a modified copy inside the packaged app exits non-zero" "$rc" "1"
is "a modified copy inside the packaged app breaks the tree" "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=false"
is "a modified copy inside the packaged app breaks the executable" "$(grep -m1 '^DRIVER_EXECUTABLE_MATCH=' "$PKG_OUT")" "DRIVER_EXECUTABLE_MATCH=false"
has "the differing executable is named" "driver executables differ" "$PKG_OUT"

rc="$(run_pkg "$T/fixtures/noexec.pkg")"
is "missing driver executable exits non-zero" "$rc" "1"
is "missing driver executable breaks the tree" "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=false"
is "missing driver executable breaks the executable check" "$(grep -m1 '^DRIVER_EXECUTABLE_MATCH=' "$PKG_OUT")" "DRIVER_EXECUTABLE_MATCH=false"
has "missing driver executable is named" "has no executable at Contents/MacOS/SoundBridgeDriver" "$PKG_OUT"

rc="$(run_pkg "$T/fixtures/plistbad.pkg")"
is "modified Info.plist exits non-zero" "$rc" "1"
is "modified Info.plist breaks the plist check" "$(grep -m1 '^DRIVER_INFO_PLIST_MATCH=' "$PKG_OUT")" "DRIVER_INFO_PLIST_MATCH=false"
has "modified Info.plist is named" "driver Info.plist differs" "$PKG_OUT"

rc="$(run_pkg "$T/fixtures/symlink.pkg")"
is "diverging symlink target exits non-zero" "$rc" "1"
is "diverging symlink target breaks the tree" "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=false"
is "diverging symlink leaves the executable matching" "$(grep -m1 '^DRIVER_EXECUTABLE_MATCH=' "$PKG_OUT")" "DRIVER_EXECUTABLE_MATCH=true"
has "diverging symlink shows both targets" "Variants" "$PKG_OUT"

rc="$(run_pkg "$T/fixtures/nosubdir.pkg")"
is "removed driver subdirectory exits non-zero" "$rc" "1"
is "removed driver subdirectory breaks the tree" "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=false"

rc="$(run_pkg "$T/fixtures/extrafile.pkg")"
is "an extra file in the package exits non-zero" "$rc" "1"
is "an extra file in the package breaks the tree" "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=false"

rc="$(run_pkg "$T/fixtures/perm.pkg")"
is "a permission change in the package exits non-zero" "$rc" "1"
is "a permission change in the package breaks the tree" "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=false"
is "a permission change leaves the executable content matching" "$(grep -m1 '^DRIVER_EXECUTABLE_MATCH=' "$PKG_OUT")" "DRIVER_EXECUTABLE_MATCH=true"

rc="$(run_pkg "$T/fixtures/protocol.pkg")"
is "a changed protocol in the package exits non-zero" "$rc" "1"
is "a changed protocol in the package breaks the protocol check" "$(grep -m1 '^DRIVER_PROTOCOL_MATCH=' "$PKG_OUT")" "DRIVER_PROTOCOL_MATCH=false"
has "the changed protocol is named" "driver copies declare different protocols" "$PKG_OUT"

# --- the third copy: the bundle in dist/ ------------------------------------
# The package's two copies can agree while the bundle the image is built from
# carries a different driver. Each fixture below damages a small stand-in for
# that bundle and points the package check at it with --app. Only the two things
# the check reads from a bundle are built: Contents/Info.plist and the driver.
APP_FIX="$T/appfix"
mkdir -p "$APP_FIX"
EXT_DRIVER=""
mk_appfix() {   # <name> <mutator function>
    local name="$1" fn="$2" d="$APP_FIX/$1/SoundBridge.app"
    rm -rf "$APP_FIX/$1"
    mkdir -p "$d/Contents/Resources"
    /bin/cp "$REAL_APP/Contents/Info.plist" "$d/Contents/Info.plist" || { bad "copy failed for $name"; return 1; }
    /usr/bin/ditto "$REAL_APP/Contents/Resources/SoundBridgeDriver.driver" \
        "$d/Contents/Resources/SoundBridgeDriver.driver" || { bad "ditto failed for $name"; return 1; }
    EXT_DRIVER="$d/Contents/Resources/SoundBridgeDriver.driver"
    "$fn" || bad "mutator $fn failed"
}

x_modfile()   { printf 'X' >> "$EXT_DRIVER/Contents/MacOS/SoundBridgeDriver"; }
x_nodriver()  { rm -rf "$EXT_DRIVER"; }
x_noplist()   { rm -f "$EXT_DRIVER/Contents/Info.plist"; }
x_extrafile() { mkdir -p "$EXT_DRIVER/Contents/Resources"; printf 'extra\n' > "$EXT_DRIVER/Contents/Resources/extra.txt"; }
x_symlink()   { ln -s Contents/MacOS "$EXT_DRIVER/Variants"; }
x_perm()      { /bin/chmod 700 "$EXT_DRIVER/Contents/MacOS/SoundBridgeDriver"; }
x_plist()     { /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9.9' "$EXT_DRIVER/Contents/Info.plist" >/dev/null; }
x_protocol()  { /usr/libexec/PlistBuddy -c 'Set :SBAudioProtocolVersion 999' "$EXT_DRIVER/Contents/Info.plist" >/dev/null; }

for pair in "xmodfile:x_modfile" "xnodriver:x_nodriver" "xnoplist:x_noplist" "xextrafile:x_extrafile" \
            "xsymlink:x_symlink" "xperm:x_perm" "xplist:x_plist" "xprotocol:x_protocol"; do
    mk_appfix "${pair%%:*}" "${pair##*:}"
done

section "B-1: the three copies (the third one in dist/)"
rc="$(run_pkg "$REAL_PKG")"
is "all three copies agree" "$(grep -m1 '^DRIVER_THREE_WAY_MATCH=' "$PKG_OUT")" "DRIVER_THREE_WAY_MATCH=true"
has "the three-way pass is stated" "all three driver trees are identical" "$PKG_OUT"
has "the executable match covers every copy" "byte-identical in every copy compared" "$PKG_OUT"

rc="$(run_pkg --app "$APP_FIX/xmodfile/SoundBridge.app" "$REAL_PKG")"
is "a changed driver in dist/ exits non-zero" "$rc" "1"
is "a changed driver in dist/ breaks the three-way match" "$(grep -m1 '^DRIVER_THREE_WAY_MATCH=' "$PKG_OUT")" "DRIVER_THREE_WAY_MATCH=false"
has "the differing copy is named" "bundle in dist/" "$PKG_OUT"

rc="$(run_pkg --app "$APP_FIX/xnoplist/SoundBridge.app" "$REAL_PKG")"
is "a missing Info.plist in dist/ exits non-zero" "$rc" "1"
has "the missing Info.plist copy is named" "the bundle in dist/ driver has no Contents/Info.plist" "$PKG_OUT"

rc="$(run_pkg --app "$APP_FIX/xextrafile/SoundBridge.app" "$REAL_PKG")"
is "an extra file in dist/ exits non-zero" "$rc" "1"
is "an extra file in dist/ breaks the tree" "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=false"

rc="$(run_pkg --app "$APP_FIX/xsymlink/SoundBridge.app" "$REAL_PKG")"
is "a symlink only in dist/ exits non-zero" "$rc" "1"
is "a symlink only in dist/ breaks the tree" "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=false"

rc="$(run_pkg --app "$APP_FIX/xperm/SoundBridge.app" "$REAL_PKG")"
is "a permission change in dist/ exits non-zero" "$rc" "1"
is "a permission change in dist/ breaks the tree" "$(grep -m1 '^DRIVER_TREE_MATCH=' "$PKG_OUT")" "DRIVER_TREE_MATCH=false"
is "a permission change in dist/ leaves the executable matching" "$(grep -m1 '^DRIVER_EXECUTABLE_MATCH=' "$PKG_OUT")" "DRIVER_EXECUTABLE_MATCH=true"

rc="$(run_pkg --app "$APP_FIX/xplist/SoundBridge.app" "$REAL_PKG")"
is "a changed Info.plist in dist/ exits non-zero" "$rc" "1"
is "a changed Info.plist in dist/ breaks the plist check" "$(grep -m1 '^DRIVER_INFO_PLIST_MATCH=' "$PKG_OUT")" "DRIVER_INFO_PLIST_MATCH=false"

rc="$(run_pkg --app "$APP_FIX/xprotocol/SoundBridge.app" "$REAL_PKG")"
is "a different protocol in dist/ exits non-zero" "$rc" "1"
is "a different protocol in dist/ breaks the protocol check" "$(grep -m1 '^DRIVER_PROTOCOL_MATCH=' "$PKG_OUT")" "DRIVER_PROTOCOL_MATCH=false"

rc="$(run_pkg --pkg-only "$REAL_PKG")"
is "--pkg-only still exits 0" "$rc" "0"
is "--pkg-only reports the three-way result as skipped" "$(grep -m1 '^DRIVER_THREE_WAY_MATCH=' "$PKG_OUT")" "DRIVER_THREE_WAY_MATCH=SKIPPED"
has "--pkg-only says the skip is not a pass" "the three-way result is SKIPPED, not PASS" "$PKG_OUT"

rc="$(run_pkg --app "$T/no-such-app/SoundBridge.app" "$REAL_PKG")"
is "a missing bundle in dist/ exits non-zero" "$rc" "1"
has "the missing bundle is named" "the bundle the image is built from" "$PKG_OUT"

rc="$(run_pkg --app "$APP_FIX/xnodriver/SoundBridge.app" "$REAL_PKG")"
is "a bundle in dist/ without a driver exits non-zero" "$rc" "1"
has "the driver-less bundle in dist/ is named" "the bundle the image is built from" "$PKG_OUT"
has "the driver-less bundle points at --pkg-only" "--pkg-only" "$PKG_OUT"

section "B-2: universal binaries in the package"
rc="$(run_pkg "$T/fixtures/singlearch.pkg")"
is "single-architecture driver exits non-zero" "$rc" "1"
is "single-architecture driver fails ARCHITECTURE" "$(grep -m1 '^ARCHITECTURE=' "$PKG_OUT")" "ARCHITECTURE=FAIL"
has "the failing binary is named" "Driver (staged):" "$PKG_OUT"
has "the missing architecture is named" "x86_64: FAIL (has: arm64)" "$PKG_OUT"

section "B-1/B-2: missing package"
rc="$(run_pkg "$T/fixtures/does-not-exist.pkg")"
is "missing package exits non-zero" "$rc" "1"
has "missing package is named" "package not found" "$PKG_OUT"

# ---------------------------------------------------------------- DMG fixtures
DMG_APP=""
D_DRIVER=""
mk_dmg() {   # <name> <mutator function>
    local name="$1" fn="$2" d="$T/app-$1"
    rm -rf "$d"; mkdir -p "$d"
    /usr/bin/ditto "$REAL_APP" "$d/SoundBridge.app" || { bad "ditto failed for $name"; return 1; }
    DMG_APP="$d/SoundBridge.app"
    D_DRIVER="$DMG_APP/Contents/Resources/SoundBridgeDriver.driver"
    "$fn" || bad "mutator $fn failed"
    /usr/bin/hdiutil create -quiet -volname SoundBridge -srcfolder "$d" -format UDZO \
        "$T/fixtures/$name.dmg" >/dev/null 2>&1 || bad "hdiutil create failed for $name"
    rm -rf "$d"
}

d_nosparkle()   { rm -rf "$DMG_APP/Contents/Frameworks/Sparkle.framework"; }
d_nodriver()    { rm -rf "$DMG_APP/Contents/Resources/SoundBridgeDriver.driver"; }
d_badversion()  { /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.0' "$DMG_APP/Contents/Info.plist" >/dev/null; }
d_singlearch()  {
    /usr/bin/lipo -thin arm64 -output "$T/thin-host" "$DMG_APP/Contents/MacOS/SoundBridgeHost" >/dev/null 2>&1
    /bin/cp "$T/thin-host" "$DMG_APP/Contents/MacOS/SoundBridgeHost"
    /bin/chmod 755 "$DMG_APP/Contents/MacOS/SoundBridgeHost"
}

for pair in "nosparkle:d_nosparkle" "nodriver:d_nodriver" "badversion:d_badversion" "singlearch:d_singlearch"; do
    mk_dmg "${pair%%:*}" "${pair##*:}"
done
cp "$REAL_DMG" "$T/fixtures/SoundBridge-1.2.0.dmg"

# --- the driver inside the image, one defect per image (MV-4 to MV-10) -----
# Each of these leaves the app otherwise whole, so the image check still passes
# its structure block and only the driver comparison can notice.
d_mv4driver()    { printf 'X' >> "$D_DRIVER/Contents/MacOS/SoundBridgeDriver"; }
d_mv5rmplist()   { rm -f "$D_DRIVER/Contents/Info.plist"; }
d_mv6extrafile() { mkdir -p "$D_DRIVER/Contents/Resources"; printf 'extra\n' > "$D_DRIVER/Contents/Resources/extra.txt"; }
d_mv7symlink()   { ln -s Contents "$D_DRIVER/Variants"; }
d_mv8perm()      { /bin/chmod 700 "$D_DRIVER/Contents/MacOS/SoundBridgeDriver"; }
d_mv9plist()     { /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9.9' "$D_DRIVER/Contents/Info.plist" >/dev/null; }
d_mv10protocol() { /usr/libexec/PlistBuddy -c 'Set :SBAudioProtocolVersion 999' "$D_DRIVER/Contents/Info.plist" >/dev/null; }

for pair in "mv4driver:d_mv4driver" "mv5rmplist:d_mv5rmplist" "mv6extrafile:d_mv6extrafile" \
            "mv7symlink:d_mv7symlink" "mv8perm:d_mv8perm" "mv9plist:d_mv9plist" \
            "mv10protocol:d_mv10protocol"; do
    mk_dmg "${pair%%:*}" "${pair##*:}"
done

# MV-11: a file that is not a disk image at all.
printf 'this is not a disk image\n' > "$T/fixtures/mv11corrupt.dmg"

# MV-12: a valid image whose root holds no app.
mk_dmg_noapp() {
    local d="$T/noapp"
    rm -rf "$d"; mkdir -p "$d"
    printf 'not an application\n' > "$d/readme.txt"
    /usr/bin/hdiutil create -quiet -volname SoundBridge -srcfolder "$d" -format UDZO \
        "$T/fixtures/mv12noapp.dmg" >/dev/null 2>&1 || bad "hdiutil create failed for noapp"
    rm -rf "$d"
}
mk_dmg_noapp

section "B-4: DMG contents"
rc="$(run_dmg "$REAL_DMG")"
is "normal image exits 0" "$rc" "0"
is "normal image structure" "$(grep -m1 '^DMG_STRUCTURE=' "$DMG_OUT")" "DMG_STRUCTURE=PASS"
is "normal image versions" "$(grep -m1 '^VERSION_CONSISTENCY=' "$DMG_OUT")" "VERSION_CONSISTENCY=PASS"
is "normal image architecture" "$(grep -m1 '^ARCHITECTURE=' "$DMG_OUT")" "ARCHITECTURE=PASS"
is "normal image mounted" "$(grep -m1 '^DMG_MOUNTED=' "$DMG_OUT")" "DMG_MOUNTED=true"
is "normal image detached" "$(grep -m1 '^DMG_DETACHED=' "$DMG_OUT")" "DMG_DETACHED=true"
# The host ships as a bare executable. What the run may report is the version it
# was built from, labelled as such -- never a version read out of the binary.
is "the host value comes from the source plist" "$(grep -m1 '^HOST_SOURCE_VERSION=' "$DMG_OUT")" "HOST_SOURCE_VERSION=1.1.1"
has "the host evidence level is stated" "HOST_VERSION_EVIDENCE=Source Verified (packages/host/Info.plist" "$DMG_OUT"
has "the report says the host binary carries no version" "no version metadata in the executable" "$DMG_OUT"
is "the app version is read from the bundle" "$(grep -m1 '^APP_BUNDLE_VERSION=' "$DMG_OUT")" "APP_BUNDLE_VERSION=1.1.1"
is "the protocol is read from the driver bundle" "$(grep -m1 '^PROTOCOL_VERSION=' "$DMG_OUT")" "PROTOCOL_VERSION=131328"

rc="$(run_dmg "$T/fixtures/nosparkle.dmg")"
is "image without Sparkle exits non-zero" "$rc" "1"
has "image without Sparkle names the framework" "Sparkle.framework is missing" "$DMG_OUT"
is "a failing image is still detached" "$(grep -m1 '^DMG_DETACHED=' "$DMG_OUT")" "DMG_DETACHED=true"

rc="$(run_dmg "$T/fixtures/nodriver.dmg")"
is "image without the driver exits non-zero" "$rc" "1"
has "image without the driver names it" "driver bundle is missing" "$DMG_OUT"
is "the driver-less image is detached" "$(grep -m1 '^DMG_DETACHED=' "$DMG_OUT")" "DMG_DETACHED=true"

rc="$(run_dmg --expect-version 1.1.1 "$T/fixtures/badversion.dmg")"
is "image with the wrong payload version exits non-zero" "$rc" "1"
is "image with the wrong payload version fails versions" "$(grep -m1 '^VERSION_CONSISTENCY=' "$DMG_OUT")" "VERSION_CONSISTENCY=FAIL"
has "the wrong app version is named" "app version is '1.0.0', expected 1.1.1" "$DMG_OUT"

rc="$(run_dmg --expect-version 1.1.1 "$T/fixtures/SoundBridge-1.2.0.dmg")"
is "image with the wrong file name exits non-zero" "$rc" "1"
has "the wrong file name is named" "file name declares '1.2.0' but the payload is 1.1.1" "$DMG_OUT"

rc="$(run_dmg --expect-version 1.1.1 "$T/fixtures/singlearch.dmg")"
is "image with a single-architecture host exits non-zero" "$rc" "1"
is "image with a single-architecture host fails ARCHITECTURE" "$(grep -m1 '^ARCHITECTURE=' "$DMG_OUT")" "ARCHITECTURE=FAIL"
has "the failing image binary is named" "Host:" "$DMG_OUT"
has "the image missing architecture is named" "x86_64: FAIL (has: arm64)" "$DMG_OUT"

section "B-4: missing image and interrupted mount"
rc="$(run_dmg "$T/fixtures/does-not-exist.dmg")"
is "missing image exits non-zero" "$rc" "1"
has "missing image is named" "disk image not found" "$DMG_OUT"

TERM_LOG="$T/term.log"
: > "$TERM_LOG"
SB_DMG_VERIFY_HOLD=4 "$VERIFY_DMG" "$REAL_DMG" > "$TERM_LOG" 2>&1 &
VERIFY_PID=$!
mounted=0
for _ in $(seq 1 100); do
    if grep -q 'mounted read-only' "$TERM_LOG" 2>/dev/null; then mounted=1; break; fi
    sleep 0.1
done
is "the interrupted run reached its mount" "$mounted" "1"
kill -TERM "$VERIFY_PID" 2>/dev/null
rc=0
wait "$VERIFY_PID" || rc=$?
is "SIGTERM ends the run with 143" "$rc" "143"
is "SIGTERM still detaches the volume" "$(grep -m1 '^DMG_DETACHED=' "$TERM_LOG")" "DMG_DETACHED=true"
leftover="$(/usr/bin/hdiutil info | grep -c "dist/SoundBridge-1.1.1.dmg")"
is "no image is left attached" "$leftover" "0"

section "B-4: SIGINT, a failing detach, and a signal no trap can catch"
INT_LOG="$T/int.log"
: > "$INT_LOG"
# A background job of a non-interactive shell inherits SIGINT ignored, and a
# signal ignored on entry cannot be trapped. Job control gives the job default
# handlers, which is what a real Ctrl-C delivers.
set -m
SB_DMG_VERIFY_HOLD=4 "$VERIFY_DMG" "$REAL_DMG" > "$INT_LOG" 2>&1 &
VERIFY_PID=$!
set +m
mounted=0
for _ in $(seq 1 100); do
    if grep -q 'mounted read-only' "$INT_LOG" 2>/dev/null; then mounted=1; break; fi
    sleep 0.1
done
is "the interrupted run reached its mount" "$mounted" "1"
# The whole group, the way a terminal delivers Ctrl-C.
kill -INT -- -"$VERIFY_PID" 2>/dev/null || kill -INT "$VERIFY_PID" 2>/dev/null
rc=0
wait "$VERIFY_PID" || rc=$?
is "SIGINT ends the run with 130" "$rc" "130"
is "SIGINT still detaches the volume" "$(grep -m1 '^DMG_DETACHED=' "$INT_LOG")" "DMG_DETACHED=true"

# A detach that fails must not be reported as a clean run: the checks all pass,
# and the exit code still has to be non-zero.
DETACH_LOG="$T/detachfail.log"
rc=0
SB_DMG_DETACH_FAIL=1 "$VERIFY_DMG" "$REAL_DMG" > "$DETACH_LOG" 2>&1 || rc=$?
is "an injected detach failure exits non-zero" "$rc" "1"
is "an injected detach failure is not reported as detached" "$(grep -m1 '^DMG_DETACHED=' "$DETACH_LOG")" "DMG_DETACHED=false"
has "the detach failure is named" "detach failure injected" "$DETACH_LOG"
is "the injected failure leaves nothing attached" "$(/usr/bin/hdiutil info | grep -c "dist/SoundBridge-1.1.1.dmg")" "0"

# SIGKILL is the boundary of what a shell trap can do. The run is killed with no
# chance to clean up, the volume stays attached, and this script frees it. What
# is proven here is that the trap cannot run -- not that a crash or a power cut
# was survived.
KILL_LOG="$T/kill.log"
: > "$KILL_LOG"
SB_DMG_VERIFY_HOLD=6 "$VERIFY_DMG" "$REAL_DMG" > "$KILL_LOG" 2>&1 &
VERIFY_PID=$!
mounted=0
for _ in $(seq 1 100); do
    if grep -q 'mounted read-only' "$KILL_LOG" 2>/dev/null; then mounted=1; break; fi
    sleep 0.1
done
is "the killed run reached its mount" "$mounted" "1"
KILL_MNT="$(sed -n 's/^mounted read-only at \(.*\) (\/dev\/disk.*$/\1/p' "$KILL_LOG")"
kill -KILL "$VERIFY_PID" 2>/dev/null
rc=0
wait "$VERIFY_PID" || rc=$?
is "SIGKILL ends the run with 137" "$rc" "137"
is "no cleanup ran after SIGKILL" "$(grep -c '^DMG_DETACHED=' "$KILL_LOG")" "0"
is "the volume is still attached after SIGKILL" "$(/usr/bin/hdiutil info | grep -F 'image-path' | grep -cF "$REAL_DMG")" "1"
if [[ -n "$KILL_MNT" ]]; then
    /usr/bin/hdiutil detach "$KILL_MNT" -force >/dev/null 2>&1
    rmdir "$KILL_MNT" 2>/dev/null
    ok "the test freed the volume SIGKILL left behind"
fi
is "nothing is left attached after the test frees it" "$(/usr/bin/hdiutil info | grep -c "dist/SoundBridge-1.1.1.dmg")" "0"

# ---------------------------------------------------------------- B-3 naming
section "B-3: DMG naming and build path"
APP100="$T/app-1.0.0"
rm -rf "$APP100"
/usr/bin/ditto "$REAL_APP" "$APP100"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.0.0' "$APP100/Contents/Info.plist" >/dev/null 2>&1

BUILD_LOG="$T/build.log"
rc=0
SB_DIST_DIR="$T/dmgout" APP_BUNDLE="$APP100" "$CREATE_DMG" --backend hdiutil > "$BUILD_LOG" 2>&1 || rc=$?
is "packaging an overridden bundle exits 0" "$rc" "0"
is "the name carries the bundle's version" "$([[ -f "$T/dmgout/SoundBridge-1.0.0.dmg" ]] && echo yes || echo no)" "yes"
is "the backend is reported" "$(grep -m1 '^DMG_BACKEND=' "$BUILD_LOG")" "DMG_BACKEND=hdiutil"
is "the version is reported" "$(grep -m1 '^DMG_VERSION=' "$BUILD_LOG")" "DMG_VERSION=1.0.0"
hasnt "no unversioned image name is used" "SoundBridge.dmg" "$BUILD_LOG"

BEFORE="$(/usr/bin/shasum -a 256 "$T/dmgout/SoundBridge-1.0.0.dmg" | awk '{print $1}')"
rc=0
SB_DIST_DIR="$T/dmgout" "$CREATE_DMG" --app "$T/no-such-app.app" > "$T/build-fail.log" 2>&1 || rc=$?
is "packaging a missing bundle exits non-zero" "$rc" "1"
AFTER="$(/usr/bin/shasum -a 256 "$T/dmgout/SoundBridge-1.0.0.dmg" | awk '{print $1}')"
is "a failed run leaves the previous image bytes intact" "$AFTER" "$BEFORE"

BROKEN="$T/broken.app"
rm -rf "$BROKEN"
/usr/bin/ditto "$REAL_APP" "$BROKEN"
rm -f "$BROKEN/Contents/MacOS/SoundBridgeHost"
rc=0
make -s -C "$ROOT" dmg-precheck APP_BUNDLE="$BROKEN" > "$T/precheck.log" 2>&1 || rc=$?
is "the pre-check rejects a bundle without a host" "$rc" "2"
has "the pre-check names the missing host" "SoundBridgeHost is missing" "$T/precheck.log"

make -n -C "$ROOT" dmg-precheck APP_BUNDLE=dist/scratch.app > "$T/n1.log" 2>&1
make -n -C "$ROOT" dmg APP_BUNDLE=dist/scratch.app > "$T/n2.log" 2>&1
has "the pre-check reads APP_BUNDLE" 'bundle="dist/scratch.app"' "$T/n2.log"
has "the packager receives the same APP_BUNDLE" 'APP_BUNDLE="dist/scratch.app"' "$T/n2.log"

# --- the create-dmg backend, exercised through a stand-in -------------------
# create-dmg is not installed on this machine, so that backend cannot be run for
# real. A stand-in on PATH records how it is called and writes a file where the
# real tool would: that proves the two backends share the version, the bundle and
# the naming rule, without claiming the real tool was exercised.
FAKE_BIN="$T/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/create-dmg" <<'FAKE'
#!/bin/bash
set -u
printf '%s\n' "$@" > "${FAKE_CREATE_DMG_ARGS:-/dev/null}"
if [ "${FAKE_CREATE_DMG_FAIL:-0}" = "1" ]; then
    echo "stand-in create-dmg: refusing on purpose" >&2
    exit 1
fi
args=("$@")
n=${#args[@]}
dmg="${args[$((n - 2))]}"
src="${args[$((n - 1))]}"
mkdir -p "$(dirname "$dmg")"
printf 'stand-in image of %s\n' "$src" > "$dmg"
FAKE
/bin/chmod +x "$FAKE_BIN/create-dmg"

FAKE_ARGS="$T/fake-args.log"
rc=0
PATH="$FAKE_BIN:$PATH" FAKE_CREATE_DMG_ARGS="$FAKE_ARGS" \
    SB_DIST_DIR="$T/dmgout" APP_BUNDLE="$APP100" "$CREATE_DMG" --backend create-dmg \
    > "$T/build-cd.log" 2>&1 || rc=$?
is "the create-dmg backend exits 0" "$rc" "0"
is "the create-dmg backend is reported, not downgraded" \
    "$(grep -m1 '^DMG_BACKEND=' "$T/build-cd.log")" "DMG_BACKEND=create-dmg"
is "the create-dmg backend uses the same name" \
    "$([[ -f "$T/dmgout/SoundBridge-1.0.0.dmg" ]] && echo yes || echo no)" "yes"
is "the create-dmg backend is given the same bundle" "$(tail -1 "$FAKE_ARGS")" "$APP100"
has "create-dmg writes into the staging directory" ".dmg-staging." "$FAKE_ARGS"
is "create-dmg is handed the final file name" \
    "$(grep -F 'SoundBridge-1.0.0.dmg' "$FAKE_ARGS" | head -1 | awk -F/ '{print $NF}')" "SoundBridge-1.0.0.dmg"

CD_BEFORE="$(/usr/bin/shasum -a 256 "$T/dmgout/SoundBridge-1.0.0.dmg" | awk '{print $1}')"
rc=0
PATH="$FAKE_BIN:$PATH" FAKE_CREATE_DMG_FAIL=1 FAKE_CREATE_DMG_ARGS="$FAKE_ARGS" \
    SB_DIST_DIR="$T/dmgout" APP_BUNDLE="$APP100" "$CREATE_DMG" --backend create-dmg \
    > "$T/build-cd-fail.log" 2>&1 || rc=$?
is "a failing create-dmg exits non-zero" "$rc" "1"
has "a failing create-dmg says nothing was replaced" \
    "Nothing in $T/dmgout was replaced" "$T/build-cd-fail.log"
CD_AFTER="$(/usr/bin/shasum -a 256 "$T/dmgout/SoundBridge-1.0.0.dmg" | awk '{print $1}')"
is "a failing create-dmg leaves the previous image intact" "$CD_AFTER" "$CD_BEFORE"
is "a failing create-dmg leaves no staging directory" \
    "$(ls -d "$T/dmgout"/.dmg-staging.* 2>/dev/null | wc -l | tr -d ' ')" "0"

# ------------------------------------------------ the fourth copy (B-6)
# The image check records the driver it found (--driver-report); the package
# check compares that with the other three (--image-report). Driving the two
# scripts this way is what tools/verify_release_payload.sh does, so the four-way
# path is exercised without a whole payload run.
# The report path is derived from the image name, so it can be recomputed in
# the parent shell: run_four_way runs inside $( ), and a path it assigned would
# not survive that subshell.
image_report_path() { printf '%s/report-%s.tsv' "$T" "$(basename "$1" .dmg)"; }

run_four_way() {   # <dmg> -> exit code of the package check; writes $DMG_OUT, $PKG_OUT
    local dmg="$1" report rc=0
    report="$(image_report_path "$dmg")"
    rm -f "$report"
    "$VERIFY_DMG" --driver-report "$report" "$dmg" > "$DMG_OUT" 2>&1
    "$VERIFY_PKG" --image-report "$report" "$REAL_PKG" > "$PKG_OUT" 2>&1 || rc=$?
    echo "$rc"
}

section "B-6: the fourth copy, the driver inside the image"
IMG_REPORT="$(image_report_path "$REAL_DMG")"
rc="$(run_four_way "$REAL_DMG")"
is "four copies on the real artifacts exit 0" "$rc" "0"
is "all four copies agree" "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=true"
has "the four-way pass is stated" "all four driver trees are identical" "$PKG_OUT"
has "the report names the copy inside the image" "D inside the image" "$PKG_OUT"
# The claim rests on the manifest digest, so check it against the manifest the
# package check prints for the bundle in dist/: same code, same bytes.
DIST_MANIFEST_SHA="$("$VERIFY_PKG" --manifest-only "$REAL_APP/Contents/Resources/SoundBridgeDriver.driver" \
    | /usr/bin/shasum -a 256 | awk '{print $1}')"
is "the image report describes the same tree as the bundle in dist/" \
    "$(grep -m1 '^DRIVER_TREE_SHA256=' "$IMG_REPORT" | cut -d= -f2)" "$DIST_MANIFEST_SHA"
is "the report counts every entry in the tree" \
    "$(grep -m1 '^DRIVER_TREE_ENTRIES=' "$IMG_REPORT" | cut -d= -f2)" "4"
is "the report carries the executable hash" \
    "$(grep -m1 '^DRIVER_EXECUTABLE_SHA256=' "$IMG_REPORT" | cut -d= -f2 | wc -c | tr -d ' ')" "65"
is "the report carries the protocol" \
    "$(grep -m1 '^DRIVER_PROTOCOL=' "$IMG_REPORT" | cut -d= -f2)" "131328"

# The bundle named with --app takes part even when the image is in play. A
# driver that differs in dist/ must not be able to hide behind an image whose
# copy still matches the package: the run fails, and the failing copy is named.
rc=0
"$VERIFY_PKG" --app "$APP_FIX/xmodfile/SoundBridge.app" --image-report "$IMG_REPORT" "$REAL_PKG" \
    > "$PKG_OUT" 2>&1 || rc=$?
is "a different driver in dist/, with an image report, exits non-zero" "$rc" "1"
is "the copy inside the image is not blamed for the difference in dist/" \
    "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=true"
is "the copy in dist/ breaks the three-way match" \
    "$(grep -m1 '^DRIVER_THREE_WAY_MATCH=' "$PKG_OUT")" "DRIVER_THREE_WAY_MATCH=false"
has "the differing copy in dist/ is named" "bundle in dist/" "$PKG_OUT"

rc="$(run_four_way "$T/fixtures/mv4driver.dmg")"
is "MV-4: a modified driver in the image exits non-zero" "$rc" "1"
is "MV-4: a modified driver in the image breaks the four-way match" \
    "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=false"
has "MV-4: the image executable difference is named" "the driver executable inside the image differs" "$PKG_OUT"

rc="$(run_four_way "$T/fixtures/mv5rmplist.dmg")"
is "MV-5: a missing file inside the image exits non-zero" "$rc" "1"
is "MV-5: a missing file inside the image breaks the four-way match" \
    "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=false"
has "MV-5: the missing Info.plist inside the image is named" "the driver Info.plist inside the image differs" "$PKG_OUT"
has "MV-5: the missing file shows up in the tree diff" "Contents/Info.plist" "$PKG_OUT"

rc="$(run_four_way "$T/fixtures/mv6extrafile.dmg")"
is "MV-6: an extra file inside the image exits non-zero" "$rc" "1"
is "MV-6: an extra file inside the image breaks the four-way match" \
    "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=false"
has "MV-6: the extra file shows up in the tree diff" "extra.txt" "$PKG_OUT"

rc="$(run_four_way "$T/fixtures/mv7symlink.dmg")"
is "MV-7: a symlink inside the image exits non-zero" "$rc" "1"
is "MV-7: a symlink inside the image breaks the four-way match" \
    "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=false"
has "MV-7: the symlink shows up in the tree diff" "Variants" "$PKG_OUT"

rc="$(run_four_way "$T/fixtures/mv8perm.dmg")"
is "MV-8: a permission change inside the image exits non-zero" "$rc" "1"
is "MV-8: a permission change inside the image breaks the four-way match" \
    "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=false"
has "MV-8: the permission difference is in the tree diff" "Contents/MacOS/SoundBridgeDriver" "$PKG_OUT"
hasnt "MV-8: a permission change is not called a content difference" "executable inside the image differs" "$PKG_OUT"

rc="$(run_four_way "$T/fixtures/mv9plist.dmg")"
is "MV-9: a different Info.plist inside the image exits non-zero" "$rc" "1"
is "MV-9: it breaks the four-way match" "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=false"
has "MV-9: the Info.plist difference is named" "the driver Info.plist inside the image differs" "$PKG_OUT"

rc="$(run_four_way "$T/fixtures/mv10protocol.dmg")"
is "MV-10: a different protocol inside the image exits non-zero" "$rc" "1"
is "MV-10: it breaks the four-way match" "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=false"
has "MV-10: the protocol difference is named" "declares protocol" "$PKG_OUT"

# MV-11, MV-12 and MV-13: no copy was read at all. That is missing evidence, so
# the verdict is NOT_VERIFIED -- calling it a difference would claim a comparison
# that never happened.
rc="$(run_four_way "$T/fixtures/mv11corrupt.dmg")"
is "MV-11: a file that is not a disk image exits non-zero" "$rc" "1"
is "MV-11: it is NOT_VERIFIED rather than false" \
    "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=NOT_VERIFIED"
has "MV-11: the report says the image carries no driver" "the image report says the image carries no" "$PKG_OUT"

rc="$(run_four_way "$T/fixtures/mv12noapp.dmg")"
is "MV-12: an image without the app exits non-zero" "$rc" "1"
is "MV-12: it is NOT_VERIFIED rather than false" \
    "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=NOT_VERIFIED"

rc="$(run_four_way "$T/fixtures/nodriver.dmg")"
is "MV-13: an image without the driver exits non-zero" "$rc" "1"
is "MV-13: it is NOT_VERIFIED rather than false" \
    "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=NOT_VERIFIED"

rc=0
"$VERIFY_PKG" --image-report "$T/no-such-report.tsv" "$REAL_PKG" > "$PKG_OUT" 2>&1 || rc=$?
is "a missing image report exits non-zero" "$rc" "1"
is "a missing image report is NOT_VERIFIED" "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=NOT_VERIFIED"
has "a missing image report is named" "was never read" "$PKG_OUT"

# Not asking is not the same as passing: a package-only run says SKIPPED.
rc="$(run_pkg "$REAL_PKG")"
is "a package-only run reports the four-way as skipped" "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=SKIPPED"
has "the skip is stated as not a pass" "SKIPPED, not PASS" "$PKG_OUT"
rc="$(run_pkg --pkg-only --image-report "$IMG_REPORT" "$REAL_PKG")"
is "--pkg-only ignores an image report" "$(grep -m1 '^DRIVER_FOUR_WAY_MATCH=' "$PKG_OUT")" "DRIVER_FOUR_WAY_MATCH=SKIPPED"

# The bundle the image check compares against is the one it was given.
section "B-6: the bundle the image is checked against"
rc="$(run_dmg --app "$APP100" "$REAL_DMG")"
is "a named bundle sets the expected version" "$rc" "1"
has "the named bundle's version is the one compared" "app version is '1.1.1', expected 1.0.0" "$DMG_OUT"

rc="$(run_dmg --app "$T/no-such-app/SoundBridge.app" "$REAL_DMG")"
is "a named bundle that does not exist exits non-zero" "$rc" "1"
has "there is no silent fallback for a named bundle" "there is no fallback to dist/" "$DMG_OUT"

rc="$(run_dmg --app "$REAL_APP" "$REAL_DMG")"
is "the real bundle still passes when named explicitly" "$rc" "0"

# ---------------------------------------------------------------- B-5 entry
section "B-5: unified entry point"
ALL_OUT="$T/all.out"
rc=0; "$VERIFY_ALL" > "$ALL_OUT" 2>&1 || rc=$?
is "the unified entry exits 0 on the real artifacts" "$rc" "0"
is "PKG_STRUCTURE" "$(grep -m1 '^  PKG_STRUCTURE=' "$ALL_OUT")" "  PKG_STRUCTURE=PASS"
is "DRIVER_CONSISTENCY" "$(grep -m1 '^  DRIVER_CONSISTENCY=' "$ALL_OUT")" "  DRIVER_CONSISTENCY=PASS"
is "ARCHITECTURE" "$(grep -m1 '^  ARCHITECTURE=' "$ALL_OUT")" "  ARCHITECTURE=PASS"
is "DMG_STRUCTURE" "$(grep -m1 '^  DMG_STRUCTURE=' "$ALL_OUT")" "  DMG_STRUCTURE=PASS"
is "VERSION_CONSISTENCY" "$(grep -m1 '^  VERSION_CONSISTENCY=' "$ALL_OUT")" "  VERSION_CONSISTENCY=PASS"
is "ARTIFACT_INTEGRITY" "$(grep -m1 '^  ARTIFACT_INTEGRITY=' "$ALL_OUT")" "  ARTIFACT_INTEGRITY=PASS"
is "OVERALL_RESULT" "$(grep -m1 '^OVERALL_RESULT=' "$ALL_OUT")" "OVERALL_RESULT=PASS"
is "the summary reports the four-way match" "$(grep -m1 '^  DRIVER_FOUR_WAY=' "$ALL_OUT")" "  DRIVER_FOUR_WAY=true"

rc=0; "$VERIFY_ALL" --skip-dmg > "$T/all-skipdmg.out" 2>&1 || rc=$?
is "skipping the image exits non-zero" "$rc" "1"
is "a skipped stage is NOT_VERIFIED" "$(grep -m1 '^  DMG_STRUCTURE=' "$T/all-skipdmg.out")" "  DMG_STRUCTURE=NOT_VERIFIED"
has "the overall result is not PASS" "OVERALL_RESULT=NOT_VERIFIED" "$T/all-skipdmg.out"
is "a skipped image leaves the four-way comparison skipped" \
    "$(grep -m1 '^  DRIVER_FOUR_WAY=' "$T/all-skipdmg.out")" "  DRIVER_FOUR_WAY=SKIPPED"

rc=0; "$VERIFY_ALL" --pkg "$T/fixtures/does-not-exist.pkg" > "$T/all-nopkg.out" 2>&1 || rc=$?
is "a missing package exits non-zero" "$rc" "1"
is "a missing package is NOT_VERIFIED" "$(grep -m1 '^  PKG_STRUCTURE=' "$T/all-nopkg.out")" "  PKG_STRUCTURE=NOT_VERIFIED"

rc=0; "$VERIFY_ALL" --pkg "$T/fixtures/modfile.pkg" > "$T/all-badpkg.out" 2>&1 || rc=$?
is "a damaged package exits non-zero" "$rc" "1"
is "a damaged package fails DRIVER_CONSISTENCY" "$(grep -m1 '^  DRIVER_CONSISTENCY=' "$T/all-badpkg.out")" "  DRIVER_CONSISTENCY=FAIL"
has "the overall result is FAIL" "OVERALL_RESULT=FAIL" "$T/all-badpkg.out"

# --- a payload run over a damaged or unreadable image (MV-14) ---------------
# The name has to match so the run fails for the driver reason, not because of a
# rename; only the image stage sees a different file.
mkdir -p "$T/mvdmg" "$T/corruptdir"
cp "$T/fixtures/mv4driver.dmg" "$T/mvdmg/SoundBridge-1.1.1.dmg"
cp "$T/fixtures/mv11corrupt.dmg" "$T/corruptdir/SoundBridge-1.1.1.dmg"

rc=0; "$VERIFY_ALL" --dmg "$T/mvdmg/SoundBridge-1.1.1.dmg" > "$T/all-baddmg.out" 2>&1 || rc=$?
is "an image with a different driver exits non-zero" "$rc" "1"
is "it fails DRIVER_CONSISTENCY" "$(grep -m1 '^  DRIVER_CONSISTENCY=' "$T/all-baddmg.out")" "  DRIVER_CONSISTENCY=FAIL"
is "the summary reports the failed four-way" "$(grep -m1 '^  DRIVER_FOUR_WAY=' "$T/all-baddmg.out")" "  DRIVER_FOUR_WAY=false"
has "the overall result is FAIL" "OVERALL_RESULT=FAIL" "$T/all-baddmg.out"

# MV-14: the detach fails though every check passed, and that is still a failure.
rc=0; SB_DMG_DETACH_FAIL=1 "$VERIFY_ALL" > "$T/all-detach.out" 2>&1 || rc=$?
is "MV-14: a failing detach exits non-zero" "$rc" "1"
is "MV-14: the image stage is FAIL" "$(grep -m1 '^  DMG_STRUCTURE=' "$T/all-detach.out")" "  DMG_STRUCTURE=FAIL"
has "MV-14: the overall result is FAIL" "OVERALL_RESULT=FAIL" "$T/all-detach.out"

# An image that cannot be read at all: the image stage fails, and the driver
# stage says NOT_VERIFIED rather than claiming a difference nobody saw.
rc=0; "$VERIFY_ALL" --dmg "$T/corruptdir/SoundBridge-1.1.1.dmg" > "$T/all-corrupt.out" 2>&1 || rc=$?
is "an unreadable image exits non-zero" "$rc" "1"
is "an unreadable image fails the image stage" "$(grep -m1 '^  DMG_STRUCTURE=' "$T/all-corrupt.out")" "  DMG_STRUCTURE=FAIL"
is "an unreadable image leaves the driver stage NOT_VERIFIED" \
    "$(grep -m1 '^  DRIVER_CONSISTENCY=' "$T/all-corrupt.out")" "  DRIVER_CONSISTENCY=NOT_VERIFIED"
has "the overall result is FAIL" "OVERALL_RESULT=FAIL" "$T/all-corrupt.out"

# --- the same bundle reaches every verification target --------------------
make -n -C "$ROOT" verify-pkg APP_BUNDLE=dist/scratch.app > "$T/n3.log" 2>&1
has "verify-pkg receives APP_BUNDLE" 'verify_pkg_contents.sh --app "dist/scratch.app"' "$T/n3.log"
make -n -C "$ROOT" verify-dmg APP_BUNDLE=dist/scratch.app > "$T/n4.log" 2>&1
has "verify-dmg receives APP_BUNDLE" 'verify_dmg_contents.sh --app "dist/scratch.app"' "$T/n4.log"
make -n -C "$ROOT" verify-payload APP_BUNDLE=dist/scratch.app > "$T/n5.log" 2>&1
has "verify-payload receives APP_BUNDLE" 'verify_release_payload.sh --app "dist/scratch.app"' "$T/n5.log"

section "mount hygiene"
leftover_mounts=0
for m in "$T"/soundbridge-dmg.*; do
    [[ -d "$m" ]] || continue
    leftover_mounts=$((leftover_mounts + 1))
    /usr/bin/hdiutil detach "$m" -force >/dev/null 2>&1
    rmdir "$m" 2>/dev/null
    bad "a verify run left a mount point behind: $m"
done
if [[ "$leftover_mounts" -eq 0 ]]; then ok "no verify run left a mount point behind"; fi
images="$(/usr/bin/hdiutil info | grep -c 'SoundBridge-1.1.1.dmg')"
is "no SoundBridge image is still attached" "$images" "0"

echo ""
echo "----------------------------------------"
echo "passed: $PASSED   failed: $FAILED"
[[ "$FAILED" -eq 0 ]] || exit 1
