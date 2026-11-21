#!/bin/bash
#
# Tests for the unsigned release policy.
#
# Two halves, deliberately separate:
#
#   Static  -- the repository still contains no way to sign anything. These read
#              the workflow, the Makefile and the tools, and fail if a signing,
#              notarization or appcast command has crept back in.
#
#   Fixture -- tools/verify_signatures.sh and tools/verify_unsigned_release.sh
#              actually refuse the states they are supposed to refuse. A small
#              app bundle is built in a temporary directory from a C file, so the
#              arm64 test runs on any Mac without touching dist/, without a
#              certificate and without signing anything for real.
#
# Nothing here signs, notarizes, installs, or talks to CoreAudio. The only
# `codesign` calls are read-only (`-dv`) plus one shim used to *fake* a sealed
# bundle so the verifier's refusal can be tested.
#
# Usage
#   ./tools/test_unsigned_release.sh
#
# Exit codes
#   0  every check passed
#   1  at least one check failed
#   2  the test environment is unusable (no clang, no tools/)
#
set -uo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
MAKEFILE="$ROOT_DIR/Makefile"
TOOLS="$ROOT_DIR/tools"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CHECKS=0
FAILS=0

section() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
}
ok()   { CHECKS=$((CHECKS + 1)); echo -e "  ${GREEN}PASS${NC}  $1"; }
no()   { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); echo -e "  ${RED}FAIL${NC}  $1"; }
info() { echo "  INFO  $1"; }

is() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then ok "$desc"; else no "$desc (got '$got', want '$want')"; fi
}

has() {
    local desc="$1" pattern="$2" file="$3"
    if grep -Eq -- "$pattern" "$file" 2>/dev/null; then
        ok "$desc"
    else
        no "$desc (no match for /$pattern/ in ${file#"$ROOT_DIR"/})"
    fi
}

hasnt() {
    local desc="$1" pattern="$2" file="$3"
    if grep -Eq -- "$pattern" "$file" 2>/dev/null; then
        no "$desc (found /$pattern/ in ${file#"$ROOT_DIR"/})"
        grep -En -- "$pattern" "$file" 2>/dev/null | head -3 | sed 's/^/        /'
    else
        ok "$desc"
    fi
}

for f in "$WORKFLOW" "$MAKEFILE" "$TOOLS/codesign.sh" "$TOOLS/verify_signatures.sh"; do
    if [ ! -f "$f" ]; then
        echo "error: missing ${f#"$ROOT_DIR"/}; run this from a checkout" >&2
        exit 2
    fi
done

T="$(mktemp -d "${TMPDIR:-/tmp}/soundbridge-unsigned-tests.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

echo "=== test_unsigned_release ==="
echo "  root: $ROOT_DIR"

# The static scans below run on comment-stripped copies. The workflow and the
# stubs explain *why* there is no `codesign`/`productsign`/appcast step, and a
# scan that fired on that prose would force the explanation out of the file.
strip_comments() { grep -v '^[[:space:]]*#' "$1" > "$2" 2>/dev/null || : ; }
WF_CODE="$T/workflow.code"
MK_CODE="$T/makefile.code"
strip_comments "$WORKFLOW" "$WF_CODE"
strip_comments "$MAKEFILE" "$MK_CODE"

# ─────────────────────────────────────────────────────────────────────────────
section "S-01: the release workflow names no signing, notarization or feed tool"
# ─────────────────────────────────────────────────────────────────────────────
hasnt "no codesign invocation"        '(^|[^a-z-])codesign[[:space:]]+(--sign|-s[[:space:]]|-[a-z]*s)' "$WF_CODE"
hasnt "no notarytool"                 'notarytool' "$WF_CODE"
hasnt "no stapler"                    'stapler' "$WF_CODE"
hasnt "no productsign"                'productsign' "$WF_CODE"
hasnt "no keychain/certificate import" 'security[[:space:]]+(import|find-identity|create-keychain)' "$WF_CODE"
hasnt "no hardened-runtime flag"      '--options[[:space:]]+runtime' "$WF_CODE"
hasnt "no Sparkle appcast step"       'appcast' "$WF_CODE"
hasnt "no Sparkle key secret"         'SPARKLE_ED_' "$WF_CODE"
hasnt "no SUPublicEDKey secret"       'SUPublicEDKey' "$WF_CODE"
hasnt "no 'make sign' step"           'make[[:space:]]+sign' "$WF_CODE"

# ─────────────────────────────────────────────────────────────────────────────
section "S-02: the checks that must survive are still in the workflow"
# ─────────────────────────────────────────────────────────────────────────────
has "tag/VERSION agreement is checked"  'Verify VERSION file matches the release tag' "$WORKFLOW"
has "component versions are pinned"     'update_versions\.sh' "$WORKFLOW"
has "version consistency is rechecked"  'verify_version_consistency\.sh' "$WORKFLOW"
has "protocol layout is checked"        'make protocol-check' "$WORKFLOW"
has "universal DSP build"               'CMAKE_OSX_ARCHITECTURES="arm64;x86_64"' "$WORKFLOW"
has "installer package is verified"     'verify_installer_pkg\.sh' "$WORKFLOW"
has "package contents are compared"     'verify_pkg_contents\.sh' "$WORKFLOW"
has "packaged driver is verified"       'verify_pkg_driver\.sh' "$WORKFLOW"
has "four-way payload check"            'verify_release_payload\.sh' "$WORKFLOW"
has "checksums are generated"           'SHA256SUMS\.txt' "$WORKFLOW"
has "checksums are re-verified"         'shasum[[:space:]]+-a[[:space:]]+256[[:space:]]+-c' "$WORKFLOW"
has "asset list is asserted"            'Verify Release Assets' "$WORKFLOW"
has "upload cannot silently miss files" 'fail_on_unmatched_files:[[:space:]]*true' "$WORKFLOW"
has "unsigned gate runs on the release" 'verify_unsigned_release\.sh' "$WF_CODE"
has "unsigned policy tests run in CI"   'make[[:space:]]+test-unsigned|test_unsigned_release\.sh' "$WF_CODE"

# ─────────────────────────────────────────────────────────────────────────────
section "S-03: the Makefile has no signing step left in the release path"
# ─────────────────────────────────────────────────────────────────────────────
hasnt "the help text does not advertise signing" 'make sign[[:space:]]+-' "$MK_CODE"
hasnt "test target no longer runs codesign tests" 'test-codesign' "$MK_CODE"
hasnt "no target calls notarize.sh"               '\./tools/notarize\.sh' "$MK_CODE"

# `sign:` is kept so an old habit fails loudly, and it must be the only reference
# to the refusing stub -- a second one would be a signing path nobody documented.
is "codesign.sh is referenced exactly once" \
    "$(grep -c 'tools/codesign\.sh' "$MK_CODE" 2>/dev/null || echo 0)" "1"
has "the sign: target still exists and refuses" '^sign:' "$MK_CODE"
has "sign: runs the refusing stub" '^\t@\./tools/codesign\.sh' "$MK_CODE"

REL_LINE="$(grep -E '^release:' "$MK_CODE" | head -1)"
FULL_LINE="$(grep -E '^full-release:' "$MK_CODE" | head -1)"
case "$REL_LINE" in
    *" sign"*) no "release: does not depend on sign ($REL_LINE)" ;;
    *)         ok "release: does not depend on sign" ;;
esac
case "$FULL_LINE" in
    *" sign"*) no "full-release: does not depend on sign ($FULL_LINE)" ;;
    *)         ok "full-release: does not depend on sign" ;;
esac
has "the test target runs the unsigned tests" 'test-unsigned' "$MAKEFILE"
has "the release path asserts unsigned state" 'verify-unsigned|verify_signatures\.sh' "$MAKEFILE"

# ─────────────────────────────────────────────────────────────────────────────
section "S-04: the signing entry points refuse to run"
# ─────────────────────────────────────────────────────────────────────────────
for pair in "codesign.sh:" "codesign.sh:--adhoc" "notarize.sh:" "generate_appcast.sh:"; do
    script="${pair%%:*}"
    args="${pair#*:}"
    if [ ! -x "$TOOLS/$script" ]; then
        no "$script is executable"
        continue
    fi
    # shellcheck disable=SC2086
    "$TOOLS/$script" $args >/dev/null 2>&1
    is "$script $args exits 2 (refuses to sign)" "$?" "2"
done

for script in codesign.sh notarize.sh generate_appcast.sh; do
    "$TOOLS/$script" --help >/dev/null 2>&1
    is "$script --help exits 0" "$?" "0"
done

has "codesign.sh explains the policy refusal" 'code signing is disabled' "$TOOLS/codesign.sh"
has "notarize.sh explains the policy refusal" 'notarization is disabled' "$TOOLS/notarize.sh"
has "generate_appcast.sh explains the policy" 'appcast generation is disabled' "$TOOLS/generate_appcast.sh"

# ─────────────────────────────────────────────────────────────────────────────
section "S-05: no script performs a signing codesign operation"
# ─────────────────────────────────────────────────────────────────────────────
# Comments are stripped again here: the stubs explain which commands they used to
# run, and that prose must not be mistaken for a call. This test file is skipped
# as well, because it contains the patterns themselves.
scan_tools() {
    local pattern="$1" f base stripped hits=""
    for f in "$TOOLS"/*.sh; do
        base="$(basename "$f")"
        [ "$base" = "test_unsigned_release.sh" ] && continue
        stripped="$T/scan.$base"
        grep -v '^[[:space:]]*#' "$f" > "$stripped" 2>/dev/null || :
        if grep -Eq -- "$pattern" "$stripped" 2>/dev/null; then
            hits="${hits}$(grep -En -- "$pattern" "$stripped" | sed "s|^|tools/$base:|")"$'\n'
        fi
    done
    printf '%s' "$hits"
}

SIGNING_CALLS="$(scan_tools 'codesign[[:space:]]+(--sign|-s[[:space:]])|codesign[[:space:]]+.*--options[[:space:]]+runtime')"
if [ -z "$SIGNING_CALLS" ]; then
    ok "no tools/ script passes --sign to codesign"
else
    no "a tools/ script still signs"
    printf '%s\n' "$SIGNING_CALLS" | head -5 | sed 's/^/        /'
fi

LEGACY_CALLS="$(scan_tools 'xcrun[[:space:]]+notarytool|xcrun[[:space:]]+stapler|/usr/bin/productsign|security[[:space:]]+find-identity')"
if [ -z "$LEGACY_CALLS" ]; then
    ok "no tools/ script calls notarytool, stapler, productsign or find-identity"
else
    no "a tools/ script still calls a legacy signing tool"
    printf '%s\n' "$LEGACY_CALLS" | head -5 | sed 's/^/        /'
fi

PUBKEY_AT_REST="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
    "$ROOT_DIR/apps/mac/SoundBridgeApp/Info.plist" 2>/dev/null || true)"
is "Info.plist ships an empty SUPublicEDKey" "$PUBKEY_AT_REST" ""

# ─────────────────────────────────────────────────────────────────────────────
section "S-06: the bundler cannot introduce a Sparkle key"
# ─────────────────────────────────────────────────────────────────────────────
# create_app_bundle.sh used to copy SPARKLE_ED_PUBLIC_KEY into the bundle. An
# inherited environment variable would re-enable the update path without anyone
# editing a file, so the script now fails instead of injecting.
strip_comments "$TOOLS/create_app_bundle.sh" "$T/bundle.code"
hasnt "the bundler never sets a non-empty SUPublicEDKey" \
    'Set[[:space:]]+:SUPublicEDKey[[:space:]]+\$SPARKLE' "$T/bundle.code"
has "the bundler refuses an inherited SPARKLE_ED_PUBLIC_KEY" \
    'SPARKLE_ED_PUBLIC_KEY is set, but this project publishes an' "$T/bundle.code"
has "the bundler pins SUEnableAutomaticChecks to false" \
    'Set :SUEnableAutomaticChecks false' "$T/bundle.code"
has "the bundler fails if automatic checks survive" \
    'SUEnableAutomaticChecks' "$T/bundle.code"

# ─────────────────────────────────────────────────────────────────────────────
section "F-00: fixture setup"
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v clang >/dev/null 2>&1; then
    echo "error: clang is required to build the fixture binary" >&2
    exit 2
fi

make_fixture() {
    local dir="$1" pubkey="${2:-}" autochecks="${3:-false}"
    if [ "$autochecks" = "true" ]; then AUTO_XML='<true/>'; else AUTO_XML='<false/>'; fi
    rm -rf "$dir"
    mkdir -p "$dir/Contents/MacOS" "$dir/Contents/Resources"
    printf 'int main(void) { return 0; }\n' > "$T/hello.c"
    clang -O2 -o "$dir/Contents/MacOS/SoundBridgeApp" "$T/hello.c" 2>/dev/null \
        || return 1
    cat > "$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.soundbridge.unsigned.fixture</string>
    <key>CFBundleExecutable</key><string>SoundBridgeApp</string>
    <key>CFBundleShortVersionString</key><string>1.2.0</string>
    <key>SUEnableAutomaticChecks</key>${AUTO_XML}
    <key>SUPublicEDKey</key><string>${pubkey}</string>
</dict>
</plist>
PLIST
    return 0
}

FIXTURE="$T/SoundBridge.app"
if make_fixture "$FIXTURE"; then
    ok "fixture app bundle built without any signing step"
else
    no "fixture app bundle could not be built"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "F-01: an unsigned fixture passes the app assertion"
# ─────────────────────────────────────────────────────────────────────────────
OUT="$T/f01.log"
"$TOOLS/verify_signatures.sh" "$FIXTURE" > "$OUT" 2>&1
is "verify_signatures.sh accepts an unsigned bundle" "$?" "0"
has "it reports the machine-readable verdict" '^UNSIGNED_APP=PASS' "$OUT"
has "it counts no signing identity"           '^UNSIGNED_APP_WITH_AUTHORITY=0' "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "F-02: a sealed bundle is refused"
# ─────────────────────────────────────────────────────────────────────────────
# The shim answers `--verify` with success and delegates everything else, so the
# verifier sees a bundle that 'passes' verification without anything being
# signed. That is the state the assertion exists to catch.
SHIM="$T/shim"
mkdir -p "$SHIM"
cat > "$SHIM/codesign" <<'SHIM_EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        --verify) exit 0 ;;
    esac
done
exec /usr/bin/codesign "$@"
SHIM_EOF
chmod +x "$SHIM/codesign"

SEALED="$T/Sealed.app"
make_fixture "$SEALED" >/dev/null 2>&1
OUT="$T/f02.log"
PATH="$SHIM:$PATH" "$TOOLS/verify_signatures.sh" "$SEALED" > "$OUT" 2>&1
is "a bundle that verifies as signed is refused" "$?" "1"
has "the refusal names the seal" 'passes .codesign --verify --strict' "$OUT"
has "the verdict is FAIL"        '^UNSIGNED_APP=FAIL' "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "F-03: a bundle with a Sparkle public key is refused"
# ─────────────────────────────────────────────────────────────────────────────
KEYED="$T/Keyed.app"
make_fixture "$KEYED" "dGVzdC1rZXk=" >/dev/null 2>&1
OUT="$T/f03.log"
"$TOOLS/verify_signatures.sh" "$KEYED" > "$OUT" 2>&1
is "SUPublicEDKey set is refused" "$?" "1"
has "the refusal names the key"   'SUPublicEDKey' "$OUT"
has "the verdict is FAIL"         '^UNSIGNED_APP=FAIL' "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "F-03b: a bundle that announces automatic checks is refused"
# ─────────────────────────────────────────────────────────────────────────────
# An empty key stops Sparkle from starting; it does not stop the app from
# telling the user updates are checked automatically. The plist must say false.
AUTO="$T/Auto.app"
make_fixture "$AUTO" "" "true" >/dev/null 2>&1
OUT="$T/f03b.log"
"$TOOLS/verify_signatures.sh" "$AUTO" > "$OUT" 2>&1
is "SUEnableAutomaticChecks=true is refused" "$?" "1"
has "the refusal names the plist key" 'SUEnableAutomaticChecks=true' "$OUT"
has "the verdict is FAIL"             '^UNSIGNED_APP=FAIL' "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "F-03c: a seal is attributed to whoever produced it"
# ─────────────────────────────────────────────────────────────────────────────
# Sparkle arrives from SwiftPM already sealed. Counting it as a vendor artifact
# is correct; reporting a Driver seal the same way would hide a signing step
# this repository performed.
VENDOR="$T/Vendor.app"
make_fixture "$VENDOR" >/dev/null 2>&1
mkdir -p "$VENDOR/Contents/Frameworks/Sparkle.framework/Versions/B/_CodeSignature"
printf 'vendor\n' > "$VENDOR/Contents/Frameworks/Sparkle.framework/Versions/B/_CodeSignature/CodeResources"
OUT="$T/f03c.log"
"$TOOLS/verify_signatures.sh" "$VENDOR" > "$OUT" 2>&1
is "a Sparkle vendor seal does not fail the assertion" "$?" "0"
has "the vendor seal is reported by path" 'sparkle vendor seal: Contents/Frameworks/Sparkle.framework' "$OUT"
has "one vendor seal is counted"          '^UNSIGNED_APP_SEALED_VENDOR_BUNDLES=1' "$OUT"
has "no project seal is counted"          '^UNSIGNED_APP_SEALED_PROJECT_BUNDLES=0' "$OUT"

PROJ="$T/Project.app"
make_fixture "$PROJ" >/dev/null 2>&1
mkdir -p "$PROJ/Contents/PlugIns/SoundBridgeDriver.driver/Contents/_CodeSignature"
printf 'ours\n' > "$PROJ/Contents/PlugIns/SoundBridgeDriver.driver/Contents/_CodeSignature/CodeResources"
OUT="$T/f03d.log"
"$TOOLS/verify_signatures.sh" "$PROJ" > "$OUT" 2>&1
is "a seal anywhere else fails the assertion" "$?" "1"
has "the project's own seal is named as such" 'seal produced by this repository' "$OUT"
has "one project seal is counted"             '^UNSIGNED_APP_SEALED_PROJECT_BUNDLES=1' "$OUT"
has "the vendor count stays zero"             '^UNSIGNED_APP_SEALED_VENDOR_BUNDLES=0' "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "F-04: the release gate fails when an appcast is present"
# ─────────────────────────────────────────────────────────────────────────────
DIST="$T/dist"
mkdir -p "$DIST/appcast"
cp -R "$FIXTURE" "$DIST/SoundBridge.app"
printf '<rss/>\n' > "$DIST/appcast/appcast.xml"

OUT="$T/f04.log"
"$TOOLS/verify_unsigned_release.sh" --app "$DIST/SoundBridge.app" --dist "$DIST" > "$OUT" 2>&1
is "an appcast makes the release gate fail" "$?" "1"
has "the appcast is named"                  '^UNSIGNED_APPCAST=PRESENT' "$OUT"
has "the release verdict is FAIL"           '^UNSIGNED_RELEASE=FAIL' "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "F-05: missing artifacts fail the release gate"
# ─────────────────────────────────────────────────────────────────────────────
# The gate used to report PASS while the package and the image were absent, and
# labelled them NOT_PRESENT. A release assertion that passes on two thirds of
# the release is worth nothing, so absence is a failure now.
rm -rf "$DIST/appcast"
OUT="$T/f05.log"
"$TOOLS/verify_unsigned_release.sh" --app "$DIST/SoundBridge.app" > "$OUT" 2>&1
is "a run with no package and no image fails" "$?" "1"
has "the absent package is reported as MISSING" '^UNSIGNED_PKG=MISSING' "$OUT"
has "the absent image is reported as MISSING"   '^UNSIGNED_DMG=MISSING' "$OUT"
has "the release verdict is FAIL"               '^UNSIGNED_RELEASE=FAIL' "$OUT"
hasnt "NOT_PRESENT is no longer a passing state" '^UNSIGNED_(PKG|DMG)=NOT_PRESENT' "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "F-06: an explicit artifact path that does not exist fails"
# ─────────────────────────────────────────────────────────────────────────────
# Naming a path on the command line is a statement about which file to check. It
# must never degrade into "check whatever the default location holds".
OUT="$T/f06.log"
"$TOOLS/verify_unsigned_release.sh" --app "$DIST/SoundBridge.app" \
    --pkg "$T/absent/SoundBridge-1.2.0.pkg" \
    --dmg "$T/absent/SoundBridge-1.2.0.dmg" > "$OUT" 2>&1
is "explicit paths that do not exist fail the gate" "$?" "1"
has "the package failure names the explicit path" \
    'the package named on the command line does not exist' "$OUT"
has "the image failure names the explicit path" \
    'the disk image named on the command line does not exist' "$OUT"
hasnt "the explicit run is not reported as a missing default" 'no --pkg given' "$OUT"
has "the release verdict is FAIL" '^UNSIGNED_RELEASE=FAIL' "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "F-07: an explicit app path is honoured, never replaced"
# ─────────────────────────────────────────────────────────────────────────────
# $DIST holds a valid bundle. Pointing --app somewhere else must check that
# place: silently falling back to dist/SoundBridge.app would make the gate
# certify a bundle the caller never asked about.
OUT="$T/f07.log"
"$TOOLS/verify_unsigned_release.sh" --app "$T/nowhere/SoundBridge.app" > "$OUT" 2>&1
is "a missing explicit app bundle is a usage error" "$?" "2"
has "the refusal says nothing falls back" \
    'Nothing falls back to dist/SoundBridge.app' "$OUT"

# A historical artifact is likewise checked where it lives. This one carries a
# Sparkle key, so the gate must fail on the old bundle rather than pass on the
# good one that sits in $DIST.
HIST="$T/historical-dist"
mkdir -p "$HIST"
make_fixture "$HIST/SoundBridge.app" "b2xkLWtleQ==" >/dev/null 2>&1
OUT="$T/f07b.log"
"$TOOLS/verify_unsigned_release.sh" --app "$HIST/SoundBridge.app" --dist "$HIST" > "$OUT" 2>&1
is "a historical bundle is judged on its own contents" "$?" "1"
has "the historical bundle is the one refused" 'the app bundle is not unsigned' "$OUT"
has "the historical app verdict is FAIL"       'UNSIGNED_APP=FAIL' "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "F-08: a present, unsigned package and image pass"
# ─────────────────────────────────────────────────────────────────────────────
# pkgbuild and hdiutil produce these without any signing identity, so the
# positive path can be exercised for real instead of being asserted on trust.
PKGROOT="$T/pkgroot"
mkdir -p "$PKGROOT/Applications"
cp -R "$FIXTURE" "$PKGROOT/Applications/SoundBridge.app"
if pkgbuild --root "$PKGROOT" --identifier com.soundbridge.unsigned.fixture \
        --version 1.2.0 --install-location / \
        "$DIST/SoundBridge-1.2.0.pkg" >/dev/null 2>&1; then
    ok "an unsigned package was built with pkgbuild"
else
    no "pkgbuild could not build the fixture package"
fi
DMGROOT="$T/dmgroot"
mkdir -p "$DMGROOT"
cp -R "$FIXTURE" "$DMGROOT/SoundBridge.app"
if hdiutil create -quiet -volname SoundBridge -srcfolder "$DMGROOT" -ov \
        -format UDZO "$DIST/SoundBridge-1.2.0.dmg" >/dev/null 2>&1; then
    ok "an unsigned disk image was built with hdiutil"
else
    no "hdiutil could not build the fixture image"
fi
OUT="$T/f08.log"
"$TOOLS/verify_unsigned_release.sh" --app "$DIST/SoundBridge.app" \
    --pkg "$DIST/SoundBridge-1.2.0.pkg" \
    --dmg "$DIST/SoundBridge-1.2.0.dmg" > "$OUT" 2>&1
is "a present unsigned package and image pass" "$?" "0"
has "the package verdict is UNSIGNED" '^UNSIGNED_PKG=UNSIGNED' "$OUT"
has "the image verdict is UNSIGNED"   '^UNSIGNED_DMG=UNSIGNED' "$OUT"
has "the release verdict is PASS"     '^UNSIGNED_RELEASE=PASS' "$OUT"

# ─────────────────────────────────────────────────────────────────────────────
section "Result"
# ─────────────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "PASS: $CHECKS checks, 0 failures (unsigned release policy)"
    exit 0
else
    echo "FAIL: $CHECKS checks, $FAILS failure(s) (unsigned release policy)"
    exit 1
fi
