#!/bin/bash
#
# Keep the DSP public headers converged on a single source.
#
# Source of truth: packages/dsp/include/
#
# Generated copies (byte-for-byte identical, never hand-edited):
#   packages/host/Sources/CSoundBridgeDSP/include/soundbridge_dsp.h
#   packages/host/Sources/CSoundBridgeDSP/include/soundbridge_types.h
#
# Why the copy exists at all: SwiftPM targets may only see headers inside their
# own directory, so packages/host needs a local copy next to module.modulemap.
# Before this script existed the copy was maintained by hand and had drifted -
# the host's soundbridge_types.h was missing two fields of soundbridge_stats_t
# (peak_left_db / peak_right_db), which is an ABI mismatch, and the host's
# soundbridge_dsp.h still described reset() as "may allocate" and
# set_sample_rate() as "requires reset". A hand-maintained copy of an ABI header
# is not a documentation problem, so it is generated and checked instead.
#
# Usage:
#   ./tools/sync_dsp_headers.sh          # copy source -> copies
#   ./tools/sync_dsp_headers.sh --check  # verify copies match, exit 1 on drift
#
# No symlinks: the release scripts copy these trees around, so a link would break
# as soon as the tree leaves this checkout. Same reasoning as
# tools/sync_shared_header.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/packages/dsp/include"
DEST_DIR="$ROOT_DIR/packages/host/Sources/CSoundBridgeDSP/include"

HEADERS=(
    "soundbridge_dsp.h"
    "soundbridge_types.h"
)

MODE="sync"
if [[ "${1:-}" == "--check" ]]; then
    MODE="check"
elif [[ -n "${1:-}" ]]; then
    echo "error: unknown argument '$1' (expected --check)" >&2
    exit 2
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "error: header source directory not found: $SOURCE_DIR" >&2
    exit 1
fi

# A stale copy silently changes the struct layout one side of the call compiles
# against. Compare content, not mtime, so a touch does not trigger a false
# failure.
if [[ "$MODE" == "check" ]]; then
    status=0
    for header in "${HEADERS[@]}"; do
        source_file="$SOURCE_DIR/$header"
        copy_file="$DEST_DIR/$header"
        if [[ ! -f "$source_file" ]]; then
            echo "MISSING  ${source_file#$ROOT_DIR/} (source of truth)" >&2
            status=1
            continue
        fi
        if [[ ! -f "$copy_file" ]]; then
            echo "MISSING  ${copy_file#$ROOT_DIR/}" >&2
            status=1
            continue
        fi
        if ! cmp -s "$source_file" "$copy_file"; then
            echo "DRIFT    ${copy_file#$ROOT_DIR/}" >&2
            status=1
        else
            echo "OK       ${copy_file#$ROOT_DIR/}"
        fi
    done

    if [[ $status -ne 0 ]]; then
        echo "" >&2
        echo "DSP public header copies are out of sync with" >&2
        echo "  ${SOURCE_DIR#$ROOT_DIR/}" >&2
        echo "" >&2
        echo "Run ./tools/sync_dsp_headers.sh and re-check." >&2
        exit 1
    fi
    echo "DSP public headers: single source verified (2 files identical)"
    exit 0
fi

for header in "${HEADERS[@]}"; do
    source_file="$SOURCE_DIR/$header"
    copy_file="$DEST_DIR/$header"
    if [[ ! -f "$source_file" ]]; then
        echo "error: source header not found: $source_file" >&2
        exit 1
    fi
    mkdir -p "$DEST_DIR"
    if cmp -s "$source_file" "$copy_file"; then
        echo "unchanged ${copy_file#$ROOT_DIR/}"
    else
        cp "$source_file" "$copy_file"
        echo "synced    ${copy_file#$ROOT_DIR/}"
    fi
done

echo "DSP public headers synced from ${SOURCE_DIR#$ROOT_DIR/}"
