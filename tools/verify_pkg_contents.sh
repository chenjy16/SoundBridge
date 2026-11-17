#!/bin/bash
#
# Verify that one release ships one driver, in every copy it carries.
#
# Why this exists (Phase 2.2.2-Batch B, extended in B.1 and B.2)
# --------------------------------------------------------------
# A release carries the driver bundle in four places, not two:
#
#   A. dist/SoundBridge.app/Contents/Resources/SoundBridgeDriver.driver
#      the bundle the image is built from, and what a user drags to /Applications
#   B. Payload/Applications/SoundBridge.app/Contents/Resources/SoundBridgeDriver.driver
#      the copy inside the package, used by an install from the app itself
#   C. Payload/Library/Application Support/SoundBridge/InstallerPayload/driver/
#      SoundBridgeDriver.driver
#      the copy the postinstall transaction renames into /Library/Audio/Plug-Ins/HAL
#   D. SoundBridge.app/Contents/Resources/SoundBridgeDriver.driver, inside the
#      mounted image
#      the copy a user gets when they install from the disk image
#
# tools/build_installer_pkg.sh produces 2 and 3 from one source, and
# tools/verify_installer_pkg.sh compares the two *executables*. That leaves the
# rest of the bundle: an Info.plist edited in one copy, a stale resource, a
# symlink pointing somewhere else, or a non-executable binary all reproduce a
# matching executable hash. A was not compared at all before B.1 and D was not
# compared at all before B.2, so a package or an image built from an older bundle
# could pass while the other channel shipped a different driver. This script
# compares the whole tree of every copy present: relative path set, file type,
# size, SHA256, symlink target and permission bits, then the executable, the
# Info.plist and the protocol.
#
# A is mandatory by default: a release payload without the bundle it was built
# from cannot be checked for consistency, and "the image was never compared"
# must not read as PASS. Pass --pkg-only to compare inside the package alone, in
# which case the four-way result is reported as SKIPPED rather than PASS.
#
# D only exists while the image is mounted, and mounting belongs to
# tools/verify_dmg_contents.sh. That script records what it saw in a report file
# (--driver-report) and this one compares it against A, B and C. The manifest for
# D is printed by this script's own --manifest-only mode, so there is one
# implementation of the tree manifest and one comparison, not a second and
# weaker check.
#
# It also checks that every core binary in the package is universal. `lipo -archs`
# is authoritative; `file` is printed alongside it but never used as the verdict,
# because its "universal binary with 2 architectures" text says nothing about
# *which* two.
#
# Everything here is read-only: `pkgutil --expand-full` into a temporary
# directory, then PlistBuddy/lipo/shasum on the extracted files. No `installer`,
# no sudo, no package script.
#
# What is compared, and what is not: POSIX permission bits are compared as the
# strings `stat -f %Sp` prints. ACLs, extended attributes, owner, group, resource
# forks and code signatures are not compared by this script.
#
# Usage
#   tools/verify_pkg_contents.sh                              # A+B+C for dist/
#   tools/verify_pkg_contents.sh dist/SoundBridge-1.1.1.pkg
#   tools/verify_pkg_contents.sh --app dist/Other.app <pkg>   # compare against a different bundle
#   tools/verify_pkg_contents.sh --pkg-only <pkg>             # inside the package only
#   tools/verify_pkg_contents.sh --image-report <file> <pkg>  # and the copy inside the image (D)
#   tools/verify_pkg_contents.sh --manifest-only <driver>     # print the tree manifest and stop
#
# Output (parsed by tools/verify_release_payload.sh)
#   DRIVER_TREE_MATCH=true|false
#   DRIVER_EXECUTABLE_MATCH=true|false
#   DRIVER_INFO_PLIST_MATCH=true|false
#   DRIVER_PROTOCOL_MATCH=true|false
#   DRIVER_THREE_WAY_MATCH=true|false|SKIPPED|NOT_VERIFIED
#   DRIVER_FOUR_WAY_MATCH=true|false|SKIPPED|NOT_VERIFIED
#   ARCHITECTURE=PASS|FAIL
#   exit 0 only when every one of them holds
#
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRIVER_NAME="SoundBridgeDriver.driver"
SUPPORT_REL="Library/Application Support/SoundBridge/InstallerPayload"
HEADER="$ROOT_DIR/packages/shared/include/RFSharedAudio.h"

PKG=""
APP_BUNDLE="$ROOT_DIR/dist/SoundBridge.app"
REQUIRE_EXTERNAL=1
IMAGE_REPORT=""
MANIFEST_ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_BUNDLE="$2"; shift 2 ;;
        --pkg-only) REQUIRE_EXTERNAL=0; shift ;;
        --image-report) IMAGE_REPORT="$2"; shift 2 ;;
        --manifest-only) MANIFEST_ONLY="$2"; shift 2 ;;
        -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        --*) echo "error: unknown option '$1'" >&2; exit 2 ;;
        *) PKG="$1"; shift ;;
    esac
done

fail() { echo "FAIL  $*" >&2; exit 1; }
pass() { echo "ok    $*"; }
info() { echo "      $*"; }

# PlistBuddy answers a missing file on stdout ("File Doesn't Exist, Will
# Create: ...") and a missing key on stderr. Neither is a value, so read through
# here and treat every failure as empty.
plist_read() {
    local path="$1" key="$2"
    [[ -f "$path" ]] || return 0
    /usr/libexec/PlistBuddy -c "Print :$key" "$path" 2>/dev/null || true
}

for tool in /usr/sbin/pkgutil /usr/bin/shasum /usr/bin/stat /usr/bin/lipo \
            /usr/bin/file /usr/libexec/PlistBuddy; do
    [[ -x "$tool" ]] || fail "required tool missing: $tool"
done

# --- tree manifest ----------------------------------------------------------
# One line per entry, sorted by path, in a fixed field order:
#   path <TAB> type <TAB> size <TAB> sha256 <TAB> link-target <TAB> permissions
# Directories are listed too, so a removed subdirectory changes the manifest even
# when every remaining file still matches.
tree_table() {
    local root="$1" out="$2" rel type size sha target perm
    (
        cd "$root" || exit 1
        find . -mindepth 1 -print | LC_ALL=C sort | while IFS= read -r rel; do
            rel="${rel#./}"
            if [[ -L "$rel" ]]; then
                printf '%s\tlink\t-\t-\t%s\t-\n' "$rel" "$(readlink "$rel")"
            elif [[ -d "$rel" ]]; then
                printf '%s\tdir\t-\t-\t-\t%s\n' "$rel" "$(/usr/bin/stat -f '%Sp' "$rel")"
            elif [[ -f "$rel" ]]; then
                size="$(/usr/bin/stat -f '%z' "$rel")"
                perm="$(/usr/bin/stat -f '%Sp' "$rel")"
                sha="$(/usr/bin/shasum -a 256 "$rel" | awk '{print $1}')"
                printf '%s\tfile\t%s\t%s\t-\t%s\n' "$rel" "$size" "$sha" "$perm"
            else
                printf '%s\tother\t-\t-\t-\t-\n' "$rel"
            fi
        done
    ) > "$out"
}

# --manifest-only: describe one driver bundle and stop. tools/verify_dmg_contents.sh
# uses this for the copy inside the image, so both channels are described by the
# same code.
if [[ -n "$MANIFEST_ONLY" ]]; then
    [[ -d "$MANIFEST_ONLY" ]] || { echo "error: not a directory: $MANIFEST_ONLY" >&2; exit 1; }
    tree_table "$MANIFEST_ONLY" /dev/stdout || exit 1
    exit 0
fi

if [[ -z "$PKG" ]]; then
    DEFAULT_APP="$ROOT_DIR/dist/SoundBridge.app"
    # Through plist_read: PlistBuddy answers a missing file on stdout, and that
    # text would end up inside the package name.
    VERSION_FROM_APP="$(plist_read "$DEFAULT_APP/Contents/Info.plist" CFBundleShortVersionString)"
    if [[ -n "$VERSION_FROM_APP" ]]; then
        PKG="$ROOT_DIR/dist/SoundBridge-$VERSION_FROM_APP.pkg"
    else
        PKG="$ROOT_DIR/dist/SoundBridge.pkg"
    fi
fi
[[ -f "$PKG" ]] || fail "package not found: $PKG (build one with tools/build_installer_pkg.sh)"

EXPECTED_PROTOCOL_HEX="$(sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+RF_AUDIO_PROTOCOL_VERSION[[:space:]]+(0x[0-9A-Fa-f]+)[uUlL]*.*$/\1/p' "$HEADER" | head -n 1)"
[[ -n "$EXPECTED_PROTOCOL_HEX" ]] || fail "could not read RF_AUDIO_PROTOCOL_VERSION from $HEADER"
EXPECTED_PROTOCOL_HEX="${EXPECTED_PROTOCOL_HEX#0x}"
EXPECTED_PROTOCOL="$(( 0x${EXPECTED_PROTOCOL_HEX} ))"

echo "Verifying package contents: $PKG"
info "expected driver protocol: 0x$EXPECTED_PROTOCOL_HEX ($EXPECTED_PROTOCOL)"
echo ""

WORK="$(mktemp -d "${TMPDIR:-/tmp}/soundbridge-pkgcontents.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

/usr/sbin/pkgutil --expand-full "$PKG" "$WORK/expanded" >/dev/null 2>&1 \
    || fail "pkgutil --expand-full failed; the archive is unreadable or not a package"

PAYLOAD="$(find "$WORK/expanded" -maxdepth 3 -type d -name Payload | head -1)"
[[ -n "$PAYLOAD" ]] || fail "no expanded payload found in $PKG"

APP="$PAYLOAD/Applications/SoundBridge.app"
DRIVER_IN_APP="$APP/Contents/Resources/$DRIVER_NAME"
DRIVER_STAGED="$PAYLOAD/$SUPPORT_REL/driver/$DRIVER_NAME"

[[ -d "$APP" ]] || fail "the package has no Applications/SoundBridge.app"
[[ -d "$DRIVER_IN_APP" ]] || fail "the packaged app carries no $DRIVER_NAME (app side missing)"
[[ -d "$DRIVER_STAGED" ]] || fail "the package carries no staged $DRIVER_NAME (install side missing)"
pass "both driver copies are present in the package"

# --- the bundle the package was built from ----------------------------------
# The image is made from this bundle, the package carries its own copies. If they
# disagree, one release ships two different drivers depending on how it was
# installed, and nothing else in the pipeline looks at both.
DRIVER_EXTERNAL="$APP_BUNDLE/Contents/Resources/$DRIVER_NAME"
EXTERNAL_PRESENT=0
EXTERNAL_FAIL=0
THREE_WAY="NOT_VERIFIED"
if [[ "$REQUIRE_EXTERNAL" -eq 1 && -d "$DRIVER_EXTERNAL" ]]; then
    EXTERNAL_PRESENT=1
    pass "the app bundle at $APP_BUNDLE carries the third copy"
elif [[ "$REQUIRE_EXTERNAL" -eq 1 ]]; then
    EXTERNAL_FAIL=1
    echo "FAIL  no $DRIVER_NAME in $APP_BUNDLE, the bundle the image is built from" >&2
    echo "      point at it with --app <bundle>, or pass --pkg-only to compare inside the package alone" >&2
else
    THREE_WAY="SKIPPED"
    info "not comparing the bundle in dist/ (--pkg-only); the three-way result is SKIPPED, not PASS"
fi

MANIFEST_APP="$WORK/driver-app.tsv"
MANIFEST_STAGED="$WORK/driver-staged.tsv"
MANIFEST_EXTERNAL="$WORK/driver-external.tsv"
tree_table "$DRIVER_IN_APP" "$MANIFEST_APP" || fail "could not read the driver inside the app"
tree_table "$DRIVER_STAGED" "$MANIFEST_STAGED" || fail "could not read the staged driver"
if [[ "$EXTERNAL_PRESENT" -eq 1 ]]; then
    tree_table "$DRIVER_EXTERNAL" "$MANIFEST_EXTERNAL" || fail "could not read the driver in $APP_BUNDLE"
fi

echo ""
echo "Driver tree (app-embedded copy; every other copy is compared against it)"
printf '  %-40s %-5s %9s %-8s %s\n' "path" "type" "size" "perm" "sha256 / target"
awk -F'\t' '{ printf "  %-40s %-5s %9s %-8s %s\n", $1, $2, $3, $6, ($2=="link" ? "-> " $5 : $4) }' "$MANIFEST_APP"
echo ""

TREE_MATCH=false
TREE_DIFFS=""
if ! cmp -s "$MANIFEST_APP" "$MANIFEST_STAGED"; then
    TREE_DIFFS+="      app-embedded vs staged (both inside the package):"$'\n'
    TREE_DIFFS+="$(diff -u "$MANIFEST_APP" "$MANIFEST_STAGED" | sed -n '1,40p' | sed 's/^/      /')"$'\n'
fi
if [[ "$EXTERNAL_PRESENT" -eq 1 ]] && ! cmp -s "$MANIFEST_APP" "$MANIFEST_EXTERNAL"; then
    TREE_DIFFS+="      app-embedded (package) vs the bundle in dist/:"$'\n'
    TREE_DIFFS+="$(diff -u "$MANIFEST_APP" "$MANIFEST_EXTERNAL" | sed -n '1,40p' | sed 's/^/      /')"$'\n'
fi

if [[ -z "$TREE_DIFFS" ]]; then
    TREE_MATCH=true
    if [[ "$EXTERNAL_PRESENT" -eq 1 ]]; then
        pass "all three driver trees are identical (paths, types, sizes, SHA256, symlinks, permissions)"
    else
        pass "the two driver trees in the package are identical (paths, types, sizes, SHA256, symlinks, permissions)"
    fi
else
    echo "      the driver copies differ:" >&2
    printf '%s' "$TREE_DIFFS" >&2
fi
if [[ "$EXTERNAL_PRESENT" -eq 1 ]]; then
    THREE_WAY="$TREE_MATCH"
fi

# --- per-aspect verdicts ----------------------------------------------------
# Every copy that takes part has to agree, not just the pair inside the package.
driver_executable() {
    local bundle="$1" exe
    exe="$(plist_read "$bundle/Contents/Info.plist" CFBundleExecutable)"
    [[ -n "$exe" ]] || exe="${DRIVER_NAME%.driver}"
    printf '%s' "$bundle/Contents/MacOS/$exe"
}

COPY_LABELS=("app-embedded" "staged")
COPY_BUNDLES=("$DRIVER_IN_APP" "$DRIVER_STAGED")
if [[ "$EXTERNAL_PRESENT" -eq 1 ]]; then
    COPY_LABELS+=("bundle in dist/")
    COPY_BUNDLES=("${COPY_BUNDLES[@]}" "$DRIVER_EXTERNAL")
fi

EXEC_MATCH=true
EXEC_REF=""
EXEC_REF_LABEL=""
for i in "${!COPY_BUNDLES[@]}"; do
    label="${COPY_LABELS[$i]}"
    bundle="${COPY_BUNDLES[$i]}"
    exe="$(driver_executable "$bundle")"
    if [[ ! -f "$exe" ]]; then
        echo "FAIL  the $label driver has no executable at ${exe#"$bundle"/}" >&2
        EXEC_MATCH=false
        continue
    fi
    if [[ ! -x "$exe" ]]; then
        echo "FAIL  the $label driver executable is not executable ($(/usr/bin/stat -f '%Sp' "$exe"))" >&2
        EXEC_MATCH=false
        continue
    fi
    sum="$(/usr/bin/shasum -a 256 "$exe" | awk '{print $1}')"
    if [[ -z "$EXEC_REF" ]]; then
        EXEC_REF="$sum"
        EXEC_REF_LABEL="$label"
        EXEC_REF_BYTES="$(/usr/bin/stat -f '%z' "$exe")"
    elif [[ "$sum" != "$EXEC_REF" ]]; then
        echo "FAIL  driver executables differ: $EXEC_REF ($EXEC_REF_LABEL) vs $sum ($label)" >&2
        EXEC_MATCH=false
    fi
done
if [[ "$EXEC_MATCH" == "true" ]]; then
    pass "the driver executable is byte-identical in every copy compared"
    info "sha256 $EXEC_REF"
    info "size   $EXEC_REF_BYTES bytes"
fi

PLIST_MATCH=true
PLIST_REF=""
PLIST_REF_LABEL=""
for i in "${!COPY_BUNDLES[@]}"; do
    label="${COPY_LABELS[$i]}"
    plist="${COPY_BUNDLES[$i]}/Contents/Info.plist"
    if [[ ! -f "$plist" ]]; then
        echo "FAIL  the $label driver has no Contents/Info.plist" >&2
        PLIST_MATCH=false
        continue
    fi
    sum="$(/usr/bin/shasum -a 256 "$plist" | awk '{print $1}')"
    if [[ -z "$PLIST_REF" ]]; then
        PLIST_REF="$sum"
        PLIST_REF_LABEL="$label"
    elif [[ "$sum" != "$PLIST_REF" ]]; then
        echo "FAIL  driver Info.plist differs: $PLIST_REF ($PLIST_REF_LABEL) vs $sum ($label)" >&2
        PLIST_MATCH=false
    fi
done
if [[ "$PLIST_MATCH" == "true" ]]; then
    pass "driver Info.plist is byte-identical in every copy compared"
    info "sha256 $PLIST_REF"
fi

PROTOCOL_MATCH=true
PROTO_REF=""
PROTO_REF_LABEL=""
for i in "${!COPY_BUNDLES[@]}"; do
    label="${COPY_LABELS[$i]}"
    value="$(plist_read "${COPY_BUNDLES[$i]}/Contents/Info.plist" SBAudioProtocolVersion)"
    if [[ -z "$value" ]]; then
        echo "FAIL  the $label driver declares no SBAudioProtocolVersion" >&2
        PROTOCOL_MATCH=false
        continue
    fi
    if [[ -z "$PROTO_REF" ]]; then
        PROTO_REF="$value"
        PROTO_REF_LABEL="$label"
    elif [[ "$value" != "$PROTO_REF" ]]; then
        echo "FAIL  driver copies declare different protocols: $PROTO_REF ($PROTO_REF_LABEL) vs $value ($label)" >&2
        PROTOCOL_MATCH=false
    fi
done
if [[ "$PROTOCOL_MATCH" == "true" ]]; then
    if [[ "$PROTO_REF" != "$EXPECTED_PROTOCOL" ]]; then
        echo "FAIL  every copy declares protocol $PROTO_REF but the shared header says $EXPECTED_PROTOCOL" >&2
        PROTOCOL_MATCH=false
    else
        pass "driver protocol $PROTO_REF matches in every copy and the shared header"
    fi
fi

# --- the fourth copy: the driver inside the mounted image --------------------
# D is not on this filesystem: tools/verify_dmg_contents.sh mounted the image,
# recorded what it saw and detached again. The report carries the manifest this
# script printed for it (--manifest-only), so the comparison is manifest against
# manifest -- the same fields, the same code, not a weaker second opinion.
FOUR_WAY=""
report_value() {
    awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}
if [[ "$REQUIRE_EXTERNAL" -eq 0 ]]; then
    FOUR_WAY="SKIPPED"
    info "not comparing the driver inside the image (--pkg-only); the four-way result is SKIPPED, not PASS"
elif [[ -z "$IMAGE_REPORT" ]]; then
    FOUR_WAY="SKIPPED"
    info "no --image-report was given, so the driver inside the image was not compared;"
    info "the four-way result is SKIPPED, not PASS (make verify-payload runs the image stage)"
else
    MANIFEST_IMAGE="$WORK/driver-image.tsv"
    : > "$MANIFEST_IMAGE"
    IMAGE_PRESENT=""
    if [[ -f "$IMAGE_REPORT" ]]; then
        IMAGE_PRESENT="$(report_value "$IMAGE_REPORT" DRIVER_PRESENT)"
        awk '/^# --- driver manifest below ---$/ { found = 1; next } found' \
            "$IMAGE_REPORT" > "$MANIFEST_IMAGE"
    fi
    IMAGE_EXEC_SHA256="$(report_value "$IMAGE_REPORT" DRIVER_EXECUTABLE_SHA256)"
    IMAGE_PLIST_SHA256="$(report_value "$IMAGE_REPORT" DRIVER_INFO_PLIST_SHA256)"
    IMAGE_PROTOCOL="$(report_value "$IMAGE_REPORT" DRIVER_PROTOCOL)"

    # Three outcomes, not two: a copy that differs is a FAIL, a copy that was
    # never read is NOT_VERIFIED, and only a complete comparison is a pass.
    FOUR_STATE="ok"
    if [[ ! -f "$IMAGE_REPORT" ]]; then
        echo "FAIL  the image report $IMAGE_REPORT is missing; the copy inside the image was never read" >&2
        FOUR_STATE="unknown"
    elif [[ "$IMAGE_PRESENT" != "true" ]]; then
        echo "FAIL  the image report says the image carries no $DRIVER_NAME" >&2
        FOUR_STATE="unknown"
    elif [[ ! -s "$MANIFEST_IMAGE" ]]; then
        echo "FAIL  the image report carries no driver manifest" >&2
        FOUR_STATE="unknown"
    else
        FOUR_DIFFS=""
        if ! cmp -s "$MANIFEST_APP" "$MANIFEST_IMAGE"; then
            FOUR_DIFFS+="      app-embedded (package) vs the driver inside the image:"$'\n'
            FOUR_DIFFS+="$(diff -u "$MANIFEST_APP" "$MANIFEST_IMAGE" | sed -n '1,40p' | sed 's/^/      /')"$'\n'
            FOUR_STATE="differ"
        fi
        if [[ "$IMAGE_EXEC_SHA256" != "$EXEC_REF" ]]; then
            echo "FAIL  the driver executable inside the image differs: $EXEC_REF ($EXEC_REF_LABEL) vs ${IMAGE_EXEC_SHA256:-<not read>} (inside the image)" >&2
            FOUR_STATE="differ"
        fi
        if [[ "$IMAGE_PLIST_SHA256" != "$PLIST_REF" ]]; then
            echo "FAIL  the driver Info.plist inside the image differs: $PLIST_REF ($PLIST_REF_LABEL) vs ${IMAGE_PLIST_SHA256:-<not read>} (inside the image)" >&2
            FOUR_STATE="differ"
        fi
        if [[ "$IMAGE_PROTOCOL" != "$PROTO_REF" ]]; then
            echo "FAIL  the driver inside the image declares protocol '${IMAGE_PROTOCOL:-<none>}', the package copies declare $PROTO_REF" >&2
            FOUR_STATE="differ"
        fi
        if [[ -n "$FOUR_DIFFS" ]]; then
            echo "      the driver inside the image differs:" >&2
            printf '%s' "$FOUR_DIFFS" >&2
        fi
    fi

    manifest_row() {
        local label="$1" file="$2"
        if [[ -s "$file" ]]; then
            printf '  %-30s %7s  %s\n' "$label" "$(wc -l < "$file" | tr -d ' ')" \
                "$(/usr/bin/shasum -a 256 "$file" | awk '{print $1}')"
        else
            printf '  %-30s %7s  %s\n' "$label" "-" "<not read>"
        fi
    }
    echo ""
    echo "Driver copies, and the manifest each one produced:"
    printf '  %-30s %7s  %s\n' "copy" "entries" "manifest sha256"
    manifest_row "A bundle in dist/" "${MANIFEST_EXTERNAL:-}"
    manifest_row "B app-embedded (package)" "$MANIFEST_APP"
    manifest_row "C staged (package)" "$MANIFEST_STAGED"
    manifest_row "D inside the image" "$MANIFEST_IMAGE"
    echo ""

    case "$FOUR_STATE" in
        ok)
            FOUR_WAY=true
            pass "all four driver trees are identical (paths, types, sizes, SHA256, symlinks, permissions)"
            pass "the executable, the Info.plist and the protocol are the same inside the image as in the package"
            ;;
        differ) FOUR_WAY=false ;;
        *) FOUR_WAY="NOT_VERIFIED" ;;
    esac
fi

DRIVER_VERSION="$(plist_read "$DRIVER_STAGED/Contents/Info.plist" CFBundleShortVersionString)"
APP_VERSION="$(plist_read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
info "versions: app $APP_VERSION, driver $DRIVER_VERSION"
if [[ "$EXTERNAL_PRESENT" -eq 1 ]]; then
    EXTERNAL_APP_VERSION="$(plist_read "$APP_BUNDLE/Contents/Info.plist" CFBundleShortVersionString)"
    info "versions: bundle in dist/ $EXTERNAL_APP_VERSION"
fi

# --- universal binaries inside the package ----------------------------------
# The release ships universal binaries. A single-architecture helper fails to
# load for half the users, and HAL reports that as "the device is missing", not
# as an architecture mismatch.
ARCH_FAILURES=0
ARCH_LINES=""

sparkle_executable() {
    local fw="$1"
    if [[ -f "$fw/Versions/B/Sparkle" ]]; then
        printf '%s' "$fw/Versions/B/Sparkle"
    elif [[ -f "$fw/Versions/Current/Sparkle" ]]; then
        printf '%s' "$fw/Versions/Current/Sparkle"
    fi
}

check_arch() {
    local label="$1" binary="$2" archs required
    if [[ -z "$binary" || ! -f "$binary" ]]; then
        ARCH_LINES+="  $label:"$'\n'"    arm64: FAIL (binary not found)"$'\n'"    x86_64: FAIL (binary not found)"$'\n'
        ARCH_FAILURES=$((ARCH_FAILURES + 1))
        return
    fi
    archs="$(/usr/bin/lipo -archs "$binary" 2>/dev/null || true)"
    if [[ -z "$archs" ]]; then
        ARCH_LINES+="  $label:"$'\n'"    arm64: FAIL (not a Mach-O binary: $(/usr/bin/file -b "$binary" | head -c 60))"$'\n'"    x86_64: FAIL (not a Mach-O binary)"$'\n'
        ARCH_FAILURES=$((ARCH_FAILURES + 1))
        return
    fi
    ARCH_LINES+="  $label:"$'\n'
    for required in arm64 x86_64; do
        if [[ " $archs " == *" $required "* ]]; then
            ARCH_LINES+="    $required: PASS"$'\n'
        else
            ARCH_LINES+="    $required: FAIL (has: $archs)"$'\n'
            ARCH_FAILURES=$((ARCH_FAILURES + 1))
        fi
    done
}

SPARKLE_BIN="$(sparkle_executable "$APP/Contents/Frameworks/Sparkle.framework")"

EXE_APP="$(driver_executable "$DRIVER_IN_APP")"
EXE_STAGED="$(driver_executable "$DRIVER_STAGED")"

check_arch "SoundBridgeApp" "$APP/Contents/MacOS/SoundBridgeApp"
check_arch "Host" "$APP/Contents/MacOS/SoundBridgeHost"
check_arch "Driver (in app)" "$EXE_APP"
check_arch "Driver (staged)" "$EXE_STAGED"
if [[ "$EXTERNAL_PRESENT" -eq 1 ]]; then
    check_arch "Driver (bundle in dist/)" "$(driver_executable "$DRIVER_EXTERNAL")"
fi
check_arch "Sparkle" "$SPARKLE_BIN"

echo ""
echo "ARCH_CHECK (package payload)"
printf '%s' "$ARCH_LINES"

# --- summary ----------------------------------------------------------------
echo ""
echo "DRIVER_TREE_MATCH=$TREE_MATCH"
echo "DRIVER_EXECUTABLE_MATCH=$EXEC_MATCH"
echo "DRIVER_INFO_PLIST_MATCH=$PLIST_MATCH"
echo "DRIVER_PROTOCOL_MATCH=$PROTOCOL_MATCH"
echo "DRIVER_THREE_WAY_MATCH=$THREE_WAY"
echo "DRIVER_FOUR_WAY_MATCH=$FOUR_WAY"
echo "PKG_APP_VERSION=${APP_VERSION:-}"
echo "PKG_DRIVER_VERSION=${DRIVER_VERSION:-}"
if [[ "$ARCH_FAILURES" -eq 0 ]]; then
    echo "ARCHITECTURE=PASS"
else
    echo "ARCHITECTURE=FAIL"
fi

if [[ "$TREE_MATCH" == "true" && "$EXEC_MATCH" == "true" && "$PLIST_MATCH" == "true" \
      && "$PROTOCOL_MATCH" == "true" && "$ARCH_FAILURES" -eq 0 \
      && "$EXTERNAL_FAIL" -eq 0 && "$THREE_WAY" != "false" \
      && "$FOUR_WAY" != "false" && "$FOUR_WAY" != "NOT_VERIFIED" ]]; then
    echo ""
    echo "PASS  $PKG"
    if [[ "$FOUR_WAY" == "true" ]]; then
        echo "      four copies, one driver: the package's two, the bundle in dist/ and the image"
    elif [[ "$THREE_WAY" == "true" ]]; then
        echo "      three copies, one driver: the package's two and the bundle in dist/"
    else
        echo "      the package's two copies are one driver (nothing outside the package was compared)"
    fi
    echo "      every core binary is universal; nothing was installed; this check is read-only"
    exit 0
fi

echo ""
echo "FAIL  $PKG" >&2
exit 1
