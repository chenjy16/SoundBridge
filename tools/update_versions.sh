#!/bin/bash
# Update component versions
# Usage:
#   ./tools/update_versions.sh [version] [--app-only|--driver-only|--host-only] [--require-all]
#   If version not provided, extracts from latest git tag (v1.0.5 -> 1.0.5)
#   Without flags, updates all components
#   --require-all checks every target before writing anything: a missing or
#   unparseable target aborts the run with nothing modified, instead of warning
#   and leaving the components on different versions.
#
#   --require-all guarantees the pre-check, not the write phase. The targets are
#   written one after another, so a failure after the check passed leaves the
#   earlier targets on the new version and the rest on the old one. That case
#   exits non-zero and lists the files it already changed (see the ERR trap
#   below); it is reported, not rolled back.
#
#   Every write is read back, because PlistBuddy exits 0 when it cannot write:
#   on a read-only file it prints 'Error Opening Destination ... [Permission
#   denied]' and returns success. Trusting that status is how a version update
#   used to report 'OK' while the file kept its old value.

set -e
# -E: without it the ERR trap does not run inside functions, so a write that
# failed inside one of the helpers below would exit non-zero without saying
# which files it had already changed.
set -E

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Parse arguments
VERSION=""
UPDATE_APP=true
UPDATE_DRIVER=true
UPDATE_HOST=true
REQUIRE_ALL=false

for arg in "$@"; do
    case $arg in
        --require-all)
            REQUIRE_ALL=true
            ;;
        --app-only)
            UPDATE_DRIVER=false
            UPDATE_HOST=false
            ;;
        --driver-only)
            UPDATE_APP=false
            UPDATE_HOST=false
            ;;
        --host-only)
            UPDATE_APP=false
            UPDATE_DRIVER=false
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$arg"
            fi
            ;;
    esac
done

# Determine version if not provided.
#
# Resolution order, and why it is not just the git tag any more:
#
#   1. the version argument                      (explicit always wins)
#   2. $SB_VERSION                               (CI passes the release tag here)
#   3. the repository's VERSION file             (what a local build ships)
#   4. the newest git tag                        (legacy fallback)
#
# The tag used to be the only source. That breaks as soon as a tag exists that
# is ahead of the version being prepared: `git describe --tags --abbrev=0` then
# returns it, and `make build` rewrites every component to it without anyone
# asking. The VERSION file is the checkout's own answer, so a release is prepared
# by editing one file instead of by hoping the tag order is right.
VERSION_SOURCE="argument"
if [ -z "$VERSION" ]; then
    if [ -n "${SB_VERSION:-}" ]; then
        VERSION="$SB_VERSION"
        VERSION_SOURCE="SB_VERSION"
    elif [ -f "$PROJECT_ROOT/VERSION" ]; then
        VERSION="$( tr -d '[:space:]' < "$PROJECT_ROOT/VERSION" )"
        VERSION_SOURCE="VERSION file"
    else
        GIT_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v1.0.0")
        VERSION="${GIT_TAG#v}"  # Remove 'v' prefix
        VERSION_SOURCE="git tag $GIT_TAG"
    fi
fi

# The installer's preinstall gate compares dot-separated numbers, so a version
# with a suffix ("1.2.0-beta") would be written into CFBundleShortVersionString
# and then rejected at install time, long after this run reported success.
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
    echo "ERROR: version '$VERSION' (from $VERSION_SOURCE) is not dot-separated digits." >&2
    echo "The installer gate compares numeric segments, so a suffix would be refused at install time." >&2
    exit 2
fi

echo "INFO: Updating component versions to: $VERSION (from $VERSION_SOURCE)"
echo ""

# ── Strict pre-flight (--require-all) ─────────────────────────────────────────
#
# Every check below runs before the first write. A target that is missing or
# cannot be rewritten would otherwise produce the worst outcome of all: this
# script reports success, some components are on the new version, and the rest
# are on the old one. The app then refuses the driver at install time, long
# after the run that was supposed to be the fix.
PROBLEM_COUNT=0
problem() {
    PROBLEM_COUNT=$((PROBLEM_COUNT + 1))
    printf '  - %s\n' "$1" >&2
}

# Extract the protocol version from the shared header, or print nothing. The
# header is the single source of truth; it is read, never duplicated here.
protocol_hex_from() {
    sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+RF_AUDIO_PROTOCOL_VERSION[[:space:]]+(0x[0-9A-Fa-f]+)[uUlL]*.*$/\1/p' "$1" | head -n 1
}

check_plist_target() {
    local rel="$1" path="$PROJECT_ROOT/$1"
    if [ ! -f "$path" ]; then
        problem "$rel is missing"
    elif [ ! -w "$path" ]; then
        problem "$rel is not writable"
    elif ! /usr/libexec/PlistBuddy -c "Print" "$path" >/dev/null 2>&1; then
        problem "$rel is not a property list PlistBuddy can read"
    fi
}

check_file_target() {
    local rel="$1" path="$PROJECT_ROOT/$1"
    if [ ! -f "$path" ]; then
        problem "$rel is missing"
    elif [ ! -w "$path" ]; then
        problem "$rel is not writable"
    fi
}

check_cmake_target() {
    local rel="$1" path="$PROJECT_ROOT/$1"
    if [ ! -f "$path" ]; then
        problem "$rel is missing"
    elif [ ! -w "$path" ]; then
        problem "$rel is not writable"
    elif ! grep -q 'project(SoundBridgeDriver VERSION ' "$path"; then
        problem "$rel has no 'project(SoundBridgeDriver VERSION ...)' line for sed to rewrite"
    fi
}

check_protocol_target() {
    local rel="$1" path="$PROJECT_ROOT/$1" hex
    if [ ! -f "$path" ]; then
        problem "$rel is missing"
        return
    fi
    hex="$(protocol_hex_from "$path")"
    if [ -z "$hex" ]; then
        problem "$rel does not define RF_AUDIO_PROTOCOL_VERSION, so SBAudioProtocolVersion would be left stale"
    fi
}

if [ "$REQUIRE_ALL" = true ]; then
    echo "Checking every version target before writing anything (--require-all)..."
    if [ "$UPDATE_APP" = true ]; then
        check_plist_target "apps/mac/SoundBridgeApp/Info.plist"
    fi
    if [ "$UPDATE_DRIVER" = true ]; then
        check_plist_target "packages/driver/Info.plist"
        check_file_target "packages/driver/VERSION"
        check_cmake_target "packages/driver/CMakeLists.txt"
        check_protocol_target "packages/shared/include/RFSharedAudio.h"
    fi
    if [ "$UPDATE_HOST" = true ]; then
        check_plist_target "packages/host/Info.plist"
    fi
    if [ "$PROBLEM_COUNT" -gt 0 ]; then
        echo "ERROR: --require-all: $PROBLEM_COUNT problem(s) found; no file was written." >&2
        echo "Continuing would have left the components on different versions." >&2
        echo "Fix the paths above, or run without --require-all for the old warn-and-continue behaviour." >&2
        exit 1
    fi
    echo "OK: all targets are present and updatable"
    echo ""
fi

# ── Write phase ──────────────────────────────────────────────────────────────
#
# Each target is rewritten in turn. If one of them fails after the pre-check
# passed, the ones before it stay on the new version. That is not a transaction
# and this script does not pretend otherwise: the guarantee is that the failure
# is loud, has a non-zero status, and names exactly which files changed.
#
# 'Changed' means the value was read back and matched. PlistBuddy returns 0 for
# a write it could not perform, so its status says nothing about the file; the
# only evidence worth recording is the file's own contents afterwards.
WRITTEN=""
note_written() {
    WRITTEN="$WRITTEN
  - $1"
}

# Read a plist value back, or print nothing. Used to confirm a write landed.
plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

# Set a plist key and fail unless the file really holds that value afterwards.
# The type is passed to the Add form only: Set keeps whatever type the key has.
set_plist_value() {
    local path="$1" key="$2" value="$3" type="$4" actual
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$path" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$path"
    actual="$(plist_value "$path" "$key")"
    if [ "$actual" != "$value" ]; then
        echo "  Error: $path was not updated: :$key is '${actual:-<missing>}', expected '$value'." >&2
        echo "   PlistBuddy can exit 0 without writing (read-only file, ACL, or a" >&2
        echo "   key it cannot address), so this was verified by reading the file back." >&2
        return 1
    fi
}

# Same idea for the two plain-text targets.
write_text_value() {
    local path="$1" value="$2" actual
    printf '%s\n' "$value" > "$path"
    actual="$(cat "$path" 2>/dev/null)"
    if [ "$actual" != "$value" ]; then
        echo "  Error: $path does not contain '$value' after writing it (it has '$actual')." >&2
        return 1
    fi
}

write_cmake_version() {
    local path="$1" version="$2"
    if grep -q "project(SoundBridgeDriver VERSION $version" "$path"; then
        return 0
    fi
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if ! sed -i '' "s/project(SoundBridgeDriver VERSION [0-9][0-9.]*/project(SoundBridgeDriver VERSION $version/" "$path"; then
            echo "  Error: sed could not rewrite the project() line in $path." >&2
            return 1
        fi
    else
        if ! sed -i "s/project(SoundBridgeDriver VERSION [0-9][0-9.]*/project(SoundBridgeDriver VERSION $version/" "$path"; then
            echo "  Error: sed could not rewrite the project() line in $path." >&2
            return 1
        fi
    fi
    if ! grep -q "project(SoundBridgeDriver VERSION $version" "$path"; then
        echo "  Error: $path still has no 'project(SoundBridgeDriver VERSION $version' line after sed." >&2
        return 1
    fi
}

report_partial_write() {
    local code=$?
    echo "" >&2
    echo "ERROR: the version update stopped part-way (exit $code)." >&2
    if [ -n "$WRITTEN" ]; then
        echo "These targets were already rewritten:$WRITTEN" >&2
        echo "The remaining targets were not touched." >&2
    else
        echo "No target had been rewritten when it stopped." >&2
    fi
    echo "--require-all guarantees the pre-check only; the write phase has no rollback." >&2
    echo "Re-run once the cause is fixed, or restore the files listed above." >&2
    exit "$code"
}
trap report_partial_write ERR

# Update SoundBridgeApp Info.plist
if [ "$UPDATE_APP" = true ]; then
    APP_PLIST="$PROJECT_ROOT/apps/mac/SoundBridgeApp/Info.plist"
    if [ -f "$APP_PLIST" ]; then
        set_plist_value "$APP_PLIST" "CFBundleShortVersionString" "$VERSION" string
        set_plist_value "$APP_PLIST" "CFBundleVersion" "$VERSION" string
        echo "OK: Updated apps/mac/SoundBridgeApp/Info.plist"
        note_written "apps/mac/SoundBridgeApp/Info.plist"
    else
        echo "WARN: $APP_PLIST not found"
    fi
fi

# Update SoundBridgeDriver Info.plist and VERSION file
if [ "$UPDATE_DRIVER" = true ]; then
    DRIVER_PLIST="$PROJECT_ROOT/packages/driver/Info.plist"
    if [ -f "$DRIVER_PLIST" ]; then
        set_plist_value "$DRIVER_PLIST" "CFBundleShortVersionString" "$VERSION" string
        set_plist_value "$DRIVER_PLIST" "CFBundleVersion" "$VERSION" string
        note_written "packages/driver/Info.plist"
        echo "OK: Updated packages/driver/Info.plist"

        # Mirror the shared-memory protocol version into the bundle metadata.
        # The app reads this key to reject a driver built against a different
        # layout before it copies over it. The header is the single source of
        # truth, so the value is extracted rather than duplicated here.
        SHARED_HEADER="$PROJECT_ROOT/packages/shared/include/RFSharedAudio.h"
        if [ -f "$SHARED_HEADER" ]; then
            PROTOCOL_HEX=$(protocol_hex_from "$SHARED_HEADER")
            if [ -n "$PROTOCOL_HEX" ]; then
                PROTOCOL_DEC=$((PROTOCOL_HEX))
                set_plist_value "$DRIVER_PLIST" "SBAudioProtocolVersion" "$PROTOCOL_DEC" integer
                echo "OK: Synced SBAudioProtocolVersion=$PROTOCOL_DEC ($PROTOCOL_HEX) into packages/driver/Info.plist"
            else
                echo "WARN: RF_AUDIO_PROTOCOL_VERSION not found in $SHARED_HEADER"
            fi
        else
            echo "WARN: $SHARED_HEADER not found - SBAudioProtocolVersion left unchanged"
        fi

        # Update VERSION file
        write_text_value "$PROJECT_ROOT/packages/driver/VERSION" "$VERSION"
        echo "OK: Updated packages/driver/VERSION"
        note_written "packages/driver/VERSION"
    else
        echo "WARN: $DRIVER_PLIST not found"
    fi
fi

# Update SoundBridgeHost Info.plist
if [ "$UPDATE_HOST" = true ]; then
    HOST_PLIST="$PROJECT_ROOT/packages/host/Info.plist"
    if [ -f "$HOST_PLIST" ]; then
        set_plist_value "$HOST_PLIST" "CFBundleShortVersionString" "$VERSION" string
        set_plist_value "$HOST_PLIST" "CFBundleVersion" "$VERSION" string
        echo "OK: Updated packages/host/Info.plist"
        note_written "packages/host/Info.plist"
    else
        echo "WARN: $HOST_PLIST not found (will be created next)"
    fi
fi

# Update driver CMakeLists.txt version
if [ "$UPDATE_DRIVER" = true ]; then
    DRIVER_CMAKE="$PROJECT_ROOT/packages/driver/CMakeLists.txt"
    if [ -f "$DRIVER_CMAKE" ]; then
        # CMake only accepts numeric versions (major.minor.patch) - strip any suffix like "-internal"
        CMAKE_VERSION=$(echo "$VERSION" | sed 's/-.*//')
        # Write the version into the project() line, then confirm it landed.
        write_cmake_version "$DRIVER_CMAKE" "$CMAKE_VERSION"
        echo "OK: Updated packages/driver/CMakeLists.txt"
        note_written "packages/driver/CMakeLists.txt"
    else
        echo "WARN: $DRIVER_CMAKE not found"
    fi
fi

echo ""
echo "OK: Version update complete"
echo ""
echo "Updated components:"
if [ "$UPDATE_APP" = true ]; then
    echo "  - App: $VERSION (apps/mac/SoundBridgeApp/Info.plist)"
fi
if [ "$UPDATE_DRIVER" = true ]; then
    echo "  - Driver: $VERSION (packages/driver/Info.plist, CMakeLists.txt, VERSION)"
fi
if [ "$UPDATE_HOST" = true ]; then
    echo "  - Host: $VERSION (packages/host/Info.plist)"
fi
