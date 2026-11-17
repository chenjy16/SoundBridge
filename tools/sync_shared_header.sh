#!/bin/bash
#
# Keep the shared-memory protocol header converged on a single source.
#
# Source of truth: packages/shared/include/RFSharedAudio.h
#
# Generated copies (byte-for-byte identical, never hand-edited):
#   packages/driver/include/RFSharedAudio.h
#   packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
#   apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
#
# Usage:
#   ./tools/sync_shared_header.sh          # copy source -> copies
#   ./tools/sync_shared_header.sh --check  # verify copies match, exit 1 on drift
#
# No symlinks: the driver ships as a system bundle and the Swift packages are
# built from trees that get copied around by the release scripts, so a link
# would break as soon as the tree leaves this checkout.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/packages/shared/include/RFSharedAudio.h"

COPIES=(
    "$ROOT_DIR/packages/driver/include/RFSharedAudio.h"
    "$ROOT_DIR/packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h"
    "$ROOT_DIR/apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h"
)

MODE="sync"
if [[ "${1:-}" == "--check" ]]; then
    MODE="check"
elif [[ -n "${1:-}" ]]; then
    echo "error: unknown argument '$1' (expected --check)" >&2
    exit 2
fi

if [[ ! -f "$SOURCE" ]]; then
    echo "error: protocol source not found: $SOURCE" >&2
    exit 1
fi

# A stale copy silently changes the ABI on one side of a process boundary.
# Compare content, not mtime, so a touch does not trigger a false failure.
if [[ "$MODE" == "check" ]]; then
    status=0
    for copy in "${COPIES[@]}"; do
        if [[ ! -f "$copy" ]]; then
            echo "MISSING  ${copy#$ROOT_DIR/}" >&2
            status=1
            continue
        fi
        if ! cmp -s "$SOURCE" "$copy"; then
            echo "DRIFT    ${copy#$ROOT_DIR/}" >&2
            status=1
        else
            echo "OK       ${copy#$ROOT_DIR/}"
        fi
    done

    if [[ $status -ne 0 ]]; then
        echo "" >&2
        echo "Protocol header copies are out of sync with" >&2
        echo "  ${SOURCE#$ROOT_DIR/}" >&2
        echo "" >&2
        echo "Run ./tools/sync_shared_header.sh and re-check." >&2
        exit 1
    fi
    echo "Protocol header: single source verified (4 files identical)"
    exit 0
fi

for copy in "${COPIES[@]}"; do
    mkdir -p "$(dirname "$copy")"
    if cmp -s "$SOURCE" "$copy"; then
        echo "unchanged ${copy#$ROOT_DIR/}"
    else
        cp "$SOURCE" "$copy"
        echo "synced    ${copy#$ROOT_DIR/}"
    fi
done

echo "Protocol header synced from ${SOURCE#$ROOT_DIR/}"
