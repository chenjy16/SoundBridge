#!/bin/bash
#
# Phase 3.2B/3.2D: exercise the installer's version gate without installing.
#
# `installer` unpacks the payload before it runs postinstall, so a version
# refusal placed in postinstall still left the new app in /Applications next to
# the older driver. The comparison now lives in preinstall, which runs before
# anything is written -- and therefore cannot read the payload to learn which
# driver it is about to install. The targets it compares against are baked into
# the script at build time; this test is what proves the baked values are there,
# that they match the driver the package actually carries, and that the
# comparison behaves the same way the transaction does.
#
# How it runs without installing anything:
#
#   1. The package is expanded with `pkgutil --expand-full` into mktemp.
#   2. preinstall and postinstall are copied and their three absolute paths
#      (/Library/Audio/Plug-Ins/HAL/..., InstallerPayload, InstallerState) are
#      rewritten into the temporary root. The rewrite is asserted to touch those
#      lines and nothing else, so the body under test is the shipped body.
#   3. preinstall runs against a fake HAL directory holding a fake driver whose
#      version, bundle id or plist is whatever the case needs.
#
# postinstall is run only for the paths that must refuse before the transaction
# starts. Its success path needs root: the transaction chowns the staged copy to
# root:wheel before it moves anything into place, and a normal user cannot. That
# path is covered by test_installer_pkg_roundtrip.sh, which passes `--owner`.
#
# Nothing here calls sudo, `installer`, `/usr/bin/ditto` on a system path, or
# touches /Library/Audio/Plug-Ins/HAL. The package is never installed.
#
# Usage
#   tools/test_installer_preinstall.sh build/p32/SoundBridge-1.1.1.pkg
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="${1:-}"

DRIVER_NAME="SoundBridgeDriver.driver"
HAL_REL="Library/Audio/Plug-Ins/HAL"
SUPPORT_REL="Library/Application Support/SoundBridge"
PAYLOAD_REL="$SUPPORT_REL/InstallerPayload"
STATE_REL="$SUPPORT_REL/InstallerState"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 2; }

[[ -n "$PKG" ]] || die "usage: $0 <path-to.pkg>"
[[ -f "$PKG" ]] || die "package not found: $PKG"
[[ -x /usr/sbin/pkgutil ]] || die "pkgutil is missing"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sb-preinstall.XXXXXX")" || die "cannot create a temp dir"
cleanup() { /bin/rm -rf "$WORK"; }
trap cleanup EXIT

/usr/sbin/pkgutil --expand-full "$PKG" "$WORK/expanded" >/dev/null 2>&1 \
    || die "pkgutil --expand-full failed"

SCRIPTS="$(find "$WORK/expanded" -maxdepth 3 -type d -name Scripts | head -1)"
PAYLOAD="$(find "$WORK/expanded" -maxdepth 3 -type d -name Payload | head -1)"
[[ -n "$SCRIPTS" && -n "$PAYLOAD" ]] || die "the package has no scripts or no payload"

SRC_PRE="$SCRIPTS/preinstall"
SRC_POST="$SCRIPTS/postinstall"
[[ -f "$SRC_PRE" && -f "$SRC_POST" ]] || die "the package has no preinstall or no postinstall"

STAGE="$PAYLOAD/$PAYLOAD_REL"
SRC_TX="$STAGE/transaction.sh"
SRC_MANIFEST="$STAGE/manifest.plist"
SRC_DRIVER="$STAGE/driver/$DRIVER_NAME"
APP_BUNDLE="$PAYLOAD/Applications/SoundBridge.app"
for f in "$SRC_TX" "$SRC_MANIFEST" "$SRC_DRIVER" "$APP_BUNDLE"; do
    [[ -e "$f" ]] || die "the payload is missing $(basename "$f")"
done

# The values the gate compares against. If these are not in the script, the
# package predates 3.2B and every case below would be testing a gate that is not
# there -- so say that plainly instead of recording false passes.
EXPECTED_ID="$(/usr/bin/sed -nE 's/^EXPECTED_ID="(.*)"$/\1/p' "$SRC_PRE" | head -1)"
EXPECTED_VERSION="$(/usr/bin/sed -nE 's/^EXPECTED_VERSION="(.*)"$/\1/p' "$SRC_PRE" | head -1)"
EXPECTED_PROTOCOL="$(/usr/bin/sed -nE 's/^EXPECTED_PROTOCOL="(.*)"$/\1/p' "$SRC_PRE" | head -1)"
[[ -n "$EXPECTED_ID" && -n "$EXPECTED_VERSION" && -n "$EXPECTED_PROTOCOL" ]] \
    || die "preinstall does not carry EXPECTED_ID/EXPECTED_VERSION/EXPECTED_PROTOCOL; this package has no pre-payload gate to test"

echo "Testing the pre-payload gate in $PKG"
echo "  baked target: $EXPECTED_ID $EXPECTED_VERSION protocol $EXPECTED_PROTOCOL"
echo ""

# --- fixture versions are derived from the package ---------------------------
#
# They used to be written out as "1.1.2" and "1.2.0". That made the suite pass
# only while the package was 1.1.1: as soon as the same cases ran against a
# 1.2.0 package, the driver fixture labelled "newer" was older than the package,
# the gate correctly allowed the upgrade, and the test called a correct answer a
# failure. Deriving the fixtures keeps the downgrade protection asserted at
# whatever version the package happens to carry, instead of pinning the test to
# a release that has already shipped.
vcmp() {
    local a="$1" b="$2" i n x y
    local -a pa pb
    IFS='.' read -r -a pa <<<"$a"
    IFS='.' read -r -a pb <<<"$b"
    n=${#pa[@]}
    [[ ${#pb[@]} -gt $n ]] && n=${#pb[@]}
    for ((i = 0; i < n; i++)); do
        x="${pa[i]:-0}"
        y="${pb[i]:-0}"
        x=$((10#$x))
        y=$((10#$y))
        if ((x < y)); then echo -1; return 0; fi
        if ((x > y)); then echo 1; return 0; fi
    done
    echo 0
}

IFS='.' read -r V_MAJ V_MIN V_PAT <<<"$EXPECTED_VERSION"
V_MAJ="${V_MAJ:-0}"
V_MIN="${V_MIN:-0}"
V_PAT="${V_PAT:-0}"

NEWER_VERSION="$V_MAJ.$((V_MIN + 1)).0"
if [[ "$V_MIN" -gt 0 ]]; then
    OLDER_VERSION="$V_MAJ.$((V_MIN - 1)).0"
elif [[ "$V_PAT" -gt 0 ]]; then
    OLDER_VERSION="$V_MAJ.0.$((V_PAT - 1))"
else
    OLDER_VERSION="0.9.0"
fi

# Both fixtures have to sit on the side of the package they claim to.
[[ "$(vcmp "$OLDER_VERSION" "$EXPECTED_VERSION")" == "-1" ]] \
    || die "derived OLDER_VERSION $OLDER_VERSION is not older than $EXPECTED_VERSION"
[[ "$(vcmp "$NEWER_VERSION" "$EXPECTED_VERSION")" == "1" ]] \
    || die "derived NEWER_VERSION $NEWER_VERSION is not newer than $EXPECTED_VERSION"

echo "  fixtures: older=$OLDER_VERSION  package=$EXPECTED_VERSION  newer=$NEWER_VERSION"
echo ""

# --- fixture helpers ---------------------------------------------------------

digest() {
    if [[ ! -e "$1" && ! -L "$1" ]]; then echo "absent"; return 0; fi
    (
        cd "$1" || exit 1
        find . -print | LC_ALL=C sort | while IFS= read -r f; do
            if [[ -L "$f" ]]; then
                printf 'l %s -> %s\n' "$f" "$(readlink "$f")"
            elif [[ -d "$f" ]]; then
                printf 'd %s\n' "$f"
            else
                printf 'f %s %s\n' "$f" "$(/usr/bin/shasum -a 256 "$f" | /usr/bin/awk '{print $1}')"
            fi
        done
    ) | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

# Rewrite only the three absolute paths. Anything else changing would mean the
# body under test is not the body that ships.
rewrite_preinstall() {
    local src="$1" dest="$2" root="$3"
    /usr/bin/sed \
        -e "s|^TARGET=\"/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver\"\$|TARGET=\"$root/$HAL_REL/$DRIVER_NAME\"|" \
        -e "s|^PARENT=\"/Library/Audio/Plug-Ins/HAL\"\$|PARENT=\"$root/$HAL_REL\"|" \
        "$src" >"$dest"
}

rewrite_postinstall() {
    local src="$1" dest="$2" root="$3"
    /usr/bin/sed \
        -e "s|^PAYLOAD_DIR=\"/Library/Application Support/SoundBridge/InstallerPayload\"\$|PAYLOAD_DIR=\"$root/$PAYLOAD_REL\"|" \
        -e "s|^STATE_DIR=\"/Library/Application Support/SoundBridge/InstallerState\"\$|STATE_DIR=\"$root/$STATE_REL\"|" \
        -e "s|^TARGET=\"/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver\"\$|TARGET=\"$root/$HAL_REL/$DRIVER_NAME\"|" \
        "$src" >"$dest"
}

# stage_driver ROOT VERSION [ID]
#
# Builds a fake installed driver by copying the real bundle out of the archive
# and setting the version (and optionally the bundle id) in its plist.
stage_driver() {
    local root="$1" version="$2" id="${3:-$EXPECTED_ID}"
    local dest="$root/$HAL_REL/$DRIVER_NAME"
    /bin/mkdir -p "$root/$HAL_REL" || return 1
    /usr/bin/ditto "$SRC_DRIVER" "$dest" || return 1
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
        "$dest/Contents/Info.plist" >/dev/null 2>&1 || return 1
    if [[ -n "$id" ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" \
            "$dest/Contents/Info.plist" >/dev/null 2>&1 || return 1
    fi
    return 0
}

# --- the rewrite is limited to the paths -------------------------------------

pre_drift="$WORK/drift-pre.sh"
rewrite_preinstall "$SRC_PRE" "$pre_drift" "$WORK/none"
changed="$(/usr/bin/diff "$SRC_PRE" "$pre_drift" | /usr/bin/grep -c '^[<>]')"
if [[ "$changed" == "4" ]]; then
    pass "preinstall: only TARGET and PARENT are rewritten, the rest is the shipped body"
else
    fail "preinstall: rewriting changed $changed lines, expected 4 (2 lines in, 2 out)"
fi

post_drift="$WORK/drift-post.sh"
rewrite_postinstall "$SRC_POST" "$post_drift" "$WORK/none"
changed="$(/usr/bin/diff "$SRC_POST" "$post_drift" | /usr/bin/grep -c '^[<>]')"
if [[ "$changed" == "6" ]]; then
    pass "postinstall: only PAYLOAD_DIR, STATE_DIR and TARGET are rewritten"
else
    fail "postinstall: rewriting changed $changed lines, expected 6 (3 lines in, 3 out)"
fi

# --- preinstall cases --------------------------------------------------------
#
# run_pre CASE_DIR EXPECTED_RC EXPECTED_TEXT WHEN
#
# WHEN is one of: present | absent -- whether a driver should be at the
# destination afterwards. Every case additionally asserts that neither the HAL
# directory nor /Applications changed, which is the property that makes a
# refusal safe.

run_pre() {
    local label="$1" root="$2" want_rc="$3" want_text="$4" want_state="$5"
    local script="$WORK/pre-$label.sh" log="$WORK/pre-$label.log" rc
    local hal_before app_before

    rewrite_preinstall "$SRC_PRE" "$script" "$root"
    /bin/mkdir -p "$root/Applications"
    hal_before="$(digest "$root/$HAL_REL")"
    app_before="$(digest "$root/Applications")"

    /bin/bash "$script" >"$log" 2>&1
    rc=$?

    if [[ "$rc" == "$want_rc" ]]; then
        pass "$label: exits $rc"
    else
        fail "$label: exits $rc, expected $want_rc — $(/usr/bin/tail -2 "$log" | /usr/bin/tr '\n' ' ')"
    fi

    if [[ -n "$want_text" ]]; then
        if /usr/bin/grep -qF "$want_text" "$log"; then
            pass "$label: says '$want_text'"
        else
            fail "$label: does not say '$want_text' — $(/usr/bin/head -3 "$log" | /usr/bin/tr '\n' ' ')"
        fi
    fi

    if [[ "$(digest "$root/$HAL_REL")" == "$hal_before" ]]; then
        pass "$label: the driver on disk is byte-identical afterwards"
    else
        fail "$label: preinstall modified the HAL directory"
    fi
    if [[ "$(digest "$root/Applications")" == "$app_before" ]]; then
        pass "$label: nothing was written into Applications"
    else
        fail "$label: preinstall wrote into Applications"
    fi

    case "$want_state" in
        present)
            [[ -d "$root/$HAL_REL/$DRIVER_NAME" ]] \
                && pass "$label: the installed driver is still there" \
                || fail "$label: the installed driver disappeared"
            ;;
        absent)
            [[ ! -e "$root/$HAL_REL/$DRIVER_NAME" ]] \
                && pass "$label: no driver was created" \
                || fail "$label: a driver appeared at the destination"
            ;;
    esac
}

# 1. No driver at all: first install.
R="$WORK/pre-1"
/bin/mkdir -p "$R/$HAL_REL"
run_pre "no-driver" "$R" 0 "first install" absent

# 2. Older driver: upgrade.
R="$WORK/pre-2"
stage_driver "$R" "$OLDER_VERSION" || die "cannot stage the $OLDER_VERSION fixture"
run_pre "upgrade-$OLDER_VERSION" "$R" 0 "upgrade" present

# 2b. The version already in the field.
#
# 1.1.2 is what the machines that installed a build have today, so the answer
# for it is worth asserting by name rather than only through the derived
# fixtures. What that answer is depends on the package: older than it is an
# upgrade, equal is a reinstall, and only a package below 1.1.2 may refuse.
R="$WORK/pre-112"
stage_driver "$R" "1.1.2" || die "cannot stage the 1.1.2 fixture"
case "$(vcmp "1.1.2" "$EXPECTED_VERSION")" in
    -1)
        run_pre "installed-1.1.2" "$R" 0 "upgrade" present
        pass "installed-1.1.2: 1.1.2 -> $EXPECTED_VERSION is an upgrade, so it is allowed"
        ;;
     0)
        run_pre "installed-1.1.2" "$R" 0 "reinstall" present
        pass "installed-1.1.2: 1.1.2 is this package's version, so it is a reinstall"
        ;;
     *)
        run_pre "installed-1.1.2" "$R" 1 "refusing to downgrade" present
        pass "installed-1.1.2: 1.1.2 is newer than $EXPECTED_VERSION, so it is refused"
        ;;
esac

# 3. Same version: whatever the existing policy is, it is not a refusal.
R="$WORK/pre-3"
stage_driver "$R" "$EXPECTED_VERSION" || die "cannot stage the same-version fixture"
run_pre "same-version" "$R" 0 "reinstall" present

# 4. Newer driver: the case this phase exists for.
R="$WORK/pre-4"
stage_driver "$R" "$NEWER_VERSION" || die "cannot stage the $NEWER_VERSION fixture"
run_pre "downgrade-$NEWER_VERSION" "$R" 1 "refusing to downgrade" present

# 5. Newer driver, and the refusal has to say the machine was left alone.
R="$WORK/pre-5"
stage_driver "$R" "$NEWER_VERSION" || die "cannot stage the $NEWER_VERSION fixture"
run_pre "newer-leaves-machine-alone" "$R" 1 "nothing was written" present

# 6. Something else owns the destination.
R="$WORK/pre-6"
stage_driver "$R" "$EXPECTED_VERSION" "" || die "cannot stage the foreign-bundle fixture"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.not.soundbridge" \
    "$R/$HAL_REL/$DRIVER_NAME/Contents/Info.plist" >/dev/null 2>&1 \
    || die "cannot set the foreign bundle id"
run_pre "foreign-bundle" "$R" 1 "belongs to 'com.example.not.soundbridge'" present

# 7. The version cannot be read.
R="$WORK/pre-7"
stage_driver "$R" "$EXPECTED_VERSION" || die "cannot stage the unreadable-version fixture"
/usr/libexec/PlistBuddy -c "Delete :CFBundleShortVersionString" \
    "$R/$HAL_REL/$DRIVER_NAME/Contents/Info.plist" >/dev/null 2>&1 \
    || die "cannot delete the version key"
run_pre "unreadable-version" "$R" 1 "no CFBundleShortVersionString" present

# 8. The bundle is there but is not a driver bundle.
R="$WORK/pre-8"
/bin/mkdir -p "$R/$HAL_REL/$DRIVER_NAME"
run_pre "no-plist" "$R" 1 "no Contents/Info.plist" present

# 9. Leading zeros must compare as numbers, not as octal.
#    The installed driver is 1.08.0: segment 2 is 8, which is above the package's
#    segment 2, so the correct answer is "refuse, it is newer". An implementation
#    that let bash read 08 as octal would either error out or produce a nonsense
#    comparison.
R="$WORK/pre-9"
stage_driver "$R" "1.08.0" || die "cannot stage the leading-zero fixture"
run_pre "leading-zero" "$R" 1 "newer than this package's" present

# 10. A segment too long to compare without wrapping is refused, not compared.
#     The version repeats the package's own segments and only then adds the
#     oversized one, so the digit limit is what the gate trips over rather than
#     the version ordering.
R="$WORK/pre-10"
stage_driver "$R" "$EXPECTED_VERSION.1234567890" || die "cannot stage the long-segment fixture"
run_pre "long-segment" "$R" 1 "more than the 9" present

# 11. A version string that is not dot-separated digits.
R="$WORK/pre-11"
stage_driver "$R" "1.1.1-beta" || die "cannot stage the non-numeric fixture"
run_pre "non-numeric" "$R" 1 "not dot-separated digits" present

# --- 12. the protocol outranks the version -----------------------------------
#
# A package must never move the shared-memory wire format backwards, even if the
# version number happens to go up. The fixture declares a protocol above the one
# this package carries, so the refusal below is the protocol rule and has to name
# it rather than fall through to the version comparison.
R="$WORK/pre-12"
stage_driver "$R" "$NEWER_VERSION" || die "cannot stage the protocol fixture"
/usr/libexec/PlistBuddy -c "Set :SBAudioProtocolVersion $((EXPECTED_PROTOCOL + 1))" \
    "$R/$HAL_REL/$DRIVER_NAME/Contents/Info.plist" >/dev/null 2>&1 \
    || die "cannot raise the fixture protocol"
script="$WORK/pre-protocol.sh"
log="$WORK/pre-protocol.log"
rewrite_preinstall "$SRC_PRE" "$script" "$R"
/bin/bash "$script" >"$log" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && /usr/bin/grep -qF "never downgrades the wire format" "$log"; then
    pass "newer-protocol: refused with the protocol rule, not the version rule"
else
    fail "newer-protocol: exit $rc and no protocol refusal — $(/usr/bin/tail -2 "$log" | /usr/bin/tr '\n' ' ')"
fi

# --- 13. ordering: a refusal happens before the payload is written -----------
#
# macOS runs preinstall, then unpacks the payload, then runs postinstall. This
# block mirrors that order against a temp root so the consequence can be
# asserted: when preinstall refuses, the app never appears. The order itself is
# the installer's documented behaviour; proving it on this machine would need a
# real `installer -pkg` run, which this phase does not allow.
R="$WORK/sim-newer"
stage_driver "$R" "$NEWER_VERSION" || die "cannot stage the simulated-install fixture"
/bin/mkdir -p "$R/Applications"
script="$WORK/sim-pre.sh"
log="$WORK/sim-pre.log"
rewrite_preinstall "$SRC_PRE" "$script" "$R"

if /bin/bash "$script" >"$log" 2>&1; then
    # Mirror the installer: preinstall allowed the install, so the payload would
    # be unpacked next.
    /usr/bin/ditto "$APP_BUNDLE" "$R/Applications/SoundBridge.app"
    fail "simulated install over $NEWER_VERSION: preinstall allowed the install to continue"
else
    pass "simulated install over $NEWER_VERSION: preinstall refuses, so the payload stage is never reached"
fi
if [[ ! -e "$R/Applications/SoundBridge.app" ]]; then
    pass "simulated install over $NEWER_VERSION: no app was written"
else
    fail "simulated install over $NEWER_VERSION: an app was written despite the refusal"
fi
if [[ ! -e "$R/$STATE_REL" ]]; then
    pass "simulated install over $NEWER_VERSION: no installer state was created"
else
    fail "simulated install over $NEWER_VERSION: preinstall created installer state"
fi

# The same order on an upgrade has to reach the payload stage, or the case above
# would pass for the wrong reason (a gate that refuses everything).
R="$WORK/sim-older"
stage_driver "$R" "$OLDER_VERSION" || die "cannot stage the simulated-upgrade fixture"
/bin/mkdir -p "$R/Applications"
script="$WORK/sim-up.sh"
log="$WORK/sim-up.log"
rewrite_preinstall "$SRC_PRE" "$script" "$R"
if /bin/bash "$script" >"$log" 2>&1; then
    pass "simulated install over $OLDER_VERSION: preinstall allows the upgrade through"
else
    fail "simulated install over $OLDER_VERSION: preinstall refused an upgrade — $(/usr/bin/tail -2 "$log" | /usr/bin/tr '\n' ' ')"
fi

# --- 14. postinstall keeps its own defence -----------------------------------
#
# preinstall cannot see the payload, so it compares against values baked in at
# build time. postinstall can see the payload, so it cross-checks the manifest
# against those same values. If the archive was assembled from mismatched parts
# -- or a payload was swapped between the two scripts -- the install stops
# before the transaction is handed control, and before any state is created.

prepare_post_root() {
    local root="$1"
    /bin/mkdir -p "$root/$PAYLOAD_REL" "$root/$HAL_REL"
    /usr/bin/ditto "$STAGE" "$root/$PAYLOAD_REL" || return 1
    /usr/bin/ditto "$SRC_DRIVER" "$root/$HAL_REL/$DRIVER_NAME" || return 1
    return 0
}

run_post() {
    local label="$1" root="$2"
    local script="$WORK/post-$label.sh" log="$WORK/post-$label.log"
    rewrite_postinstall "$SRC_POST" "$script" "$root"
    /bin/bash "$script" >"$log" 2>&1
    echo $?
}

# 14a. The manifest describes a different driver than the package was built for.
R="$WORK/post-mismatch"
prepare_post_root "$R" || die "cannot stage the postinstall fixture"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" \
    "$R/$PAYLOAD_REL/manifest.plist" >/dev/null 2>&1 \
    || die "cannot tamper with the manifest"
hal_before="$(digest "$R/$HAL_REL")"
rc="$(run_post "mismatch" "$R")"
log="$WORK/post-mismatch.log"
if [[ "$rc" != "0" ]]; then
    pass "manifest-mismatch: postinstall exits $rc"
else
    fail "manifest-mismatch: postinstall reported success"
fi
if /usr/bin/grep -qF "does not match the package" "$log"; then
    pass "manifest-mismatch: says the payload does not match the package"
else
    fail "manifest-mismatch: the reason is not in the output — $(/usr/bin/head -3 "$log" | /usr/bin/tr '\n' ' ')"
fi
if /usr/bin/grep -qF "the driver on disk was not modified" "$log"; then
    pass "manifest-mismatch: states that the driver was left alone"
else
    fail "manifest-mismatch: does not state that the driver was left alone"
fi
if /usr/bin/grep -qF "installed its driver" "$log"; then
    fail "manifest-mismatch: claimed the driver was installed"
else
    pass "manifest-mismatch: never claims the driver was installed"
fi
if [[ ! -e "$R/$STATE_REL" ]]; then
    pass "manifest-mismatch: no installer state was created"
else
    fail "manifest-mismatch: postinstall created installer state before validating the payload"
fi
if [[ "$(digest "$R/$HAL_REL")" == "$hal_before" ]]; then
    pass "manifest-mismatch: the driver on disk is byte-identical afterwards"
else
    fail "manifest-mismatch: the driver on disk changed"
fi

# 14b. The payload is incomplete -- the transaction script is missing.
R="$WORK/post-incomplete"
prepare_post_root "$R" || die "cannot stage the incomplete fixture"
/bin/rm -f "$R/$PAYLOAD_REL/transaction.sh"
rc="$(run_post "incomplete" "$R")"
log="$WORK/post-incomplete.log"
if [[ "$rc" != "0" ]] && /usr/bin/grep -qF "payload is incomplete" "$log"; then
    pass "incomplete-payload: postinstall refuses with 'payload is incomplete'"
else
    fail "incomplete-payload: exit $rc without that message — $(/usr/bin/head -3 "$log" | /usr/bin/tr '\n' ' ')"
fi
if [[ ! -e "$R/$STATE_REL" ]]; then
    pass "incomplete-payload: no installer state was created"
else
    fail "incomplete-payload: postinstall created installer state for a payload it rejected"
fi

# 14c. The control case: an intact payload reaches the transaction.
#
# The transaction chowns the staged copy to root:wheel, which a normal user
# cannot do, so it stops at VALIDATING and refuses. What this case proves is the
# part postinstall is responsible for: it does not report success when the
# transaction fails, and it leaves the state behind to be diagnosed.
R="$WORK/post-control"
prepare_post_root "$R" || die "cannot stage the control fixture"
hal_before="$(digest "$R/$HAL_REL")"
rc="$(run_post "control" "$R")"
log="$WORK/post-control.log"
if [[ "$rc" != "0" ]]; then
    pass "control: the install reports failure (exit $rc) instead of success"
else
    pass "control: the install completed — running as root, so the transaction could set ownership"
fi
if /usr/bin/grep -qF "installed its driver" "$log"; then
    if [[ "$rc" == "0" ]]; then
        pass "control: success is claimed only when the transaction succeeded"
    else
        fail "control: claimed the driver was installed although the transaction failed"
    fi
else
    pass "control: no success claim in the output"
fi
if [[ "$rc" != "0" ]]; then
    if [[ -e "$R/$STATE_REL/log" ]]; then
        pass "control: the failed install left a log to diagnose"
    else
        fail "control: the failed install left no log"
    fi
    state_file="$R/$STATE_REL/transaction.state"
    if [[ -e "$state_file" ]]; then
        if /usr/bin/grep -q 'stage=success' "$state_file"; then
            fail "control: the state file of a failed install says success"
        else
            pass "control: the state file records the failure, not success"
        fi
    else
        fail "control: no transaction state was left for a failed install"
    fi
    if [[ "$(digest "$R/$HAL_REL")" == "$hal_before" ]]; then
        pass "control: the failed install left the driver untouched"
    else
        fail "control: the failed install changed the driver"
    fi
fi

# 15. The comparison in preinstall is the comparison the transaction runs.
#
# preinstall cannot read the payload, so it carries its own copy of
# version_problem / version_is_valid / version_cmp, baked in at build time from
# the same rules as tools/sb_install_transaction.sh. Two copies of a decision
# this important drift silently: the gate and the transaction would then disagree
# about what "newer" means, and the second check would stop being a second
# opinion. This compares the two bodies in the package, comments and blank lines
# removed, so editing one copy without the other fails here instead of on a
# user's machine.
compare_block() {
    /usr/bin/awk '
        /^MAX_COMPARE_DIGITS=/ { on = 1 }
        on && /^(refuse|gate_existing_driver|env_problem)\(\)/ { exit }
        on { print }
    ' "$1" | /usr/bin/grep -Ev '^[[:space:]]*(#|$)'
}

pre_cmp="$(compare_block "$SRC_PRE")"
tx_cmp="$(compare_block "$SRC_TX")"
pre_cmp_lines="$(printf '%s\n' "$pre_cmp" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

if [[ -z "$pre_cmp" || -z "$tx_cmp" ]]; then
    fail "shared-comparison: could not read the comparison out of preinstall or the transaction"
elif [[ "$pre_cmp_lines" -lt 20 ]]; then
    fail "shared-comparison: only $pre_cmp_lines lines were extracted; the block boundaries moved"
elif [[ "$pre_cmp" == "$tx_cmp" ]]; then
    pass "shared-comparison: preinstall and the transaction compare versions with the same $pre_cmp_lines lines"
else
    diff_out="$(/usr/bin/diff -u <(printf '%s\n' "$tx_cmp") <(printf '%s\n' "$pre_cmp") | /usr/bin/head -12 | /usr/bin/tr '\n' '|')"
    fail "shared-comparison: the two comparisons have drifted apart -- $diff_out"
fi

# The rules the extraction must not have dropped: 1.1 == 1.1.0, decimal leading
# zeros, a per-segment digit limit and a dot-separated-digits-only grammar.
missing=""
for rule in ':-0' '10#' 'MAX_COMPARE_DIGITS' '^[0-9]+(\.[0-9]+)*$'; do
    if ! /usr/bin/grep -qF "$rule" <<<"$pre_cmp"; then
        missing="$missing [$rule]"
    fi
done
if [[ -z "$missing" ]]; then
    pass "shared-comparison: the extracted block still carries the four version rules"
else
    fail "shared-comparison: the extracted block is missing$missing"
fi

echo ""
echo "──────────────────────────────────────────────"
printf 'installer gate assertions: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
echo "the gate in $PKG refuses what it must; nothing was installed"
exit 0
