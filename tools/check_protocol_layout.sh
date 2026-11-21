#!/usr/bin/env bash
#
# Compile-time proof that the single protocol source is internally consistent,
# independent of the driver and Host builds.
#
# `tools/sync_shared_header.sh --check` proves the four copies are identical;
# this script proves the file they are identical *to* still describes the same
# ABI: struct size, field offsets and protocol version.
#
# Everything asserted here also exists as a static_assert inside the header, so
# this mostly guards against the header being edited into something that only
# compiles in one language, and prints the layout table for the release report.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INCLUDE_DIR="$ROOT/packages/shared/include"
HEADER="$INCLUDE_DIR/RFSharedAudio.h"

if [[ ! -f "$HEADER" ]]; then
    echo "FAIL: single protocol source missing: $HEADER" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/layout_probe.c" <<'EOF'
#include "RFSharedAudio.h"
#include <stdio.h>

/* The protocol version is part of the contract, not an implementation detail:
 * a bump must be deliberate, so pin the literal here as well. */
#if RF_AUDIO_PROTOCOL_VERSION != 0x00020200
#error "RF_AUDIO_PROTOCOL_VERSION changed; bump the Host/driver together and update the release notes"
#endif

#if RF_SHARED_AUDIO_HEADER_SIZE != 320
#error "RF_SHARED_AUDIO_HEADER_SIZE changed; every offset below must be re-derived"
#endif

/* `header_size` in the struct carries the fixed-header length, so the two
 * numbers must be the same quantity, not two independent ones. */
_Static_assert(sizeof(RFSharedAudio) == RF_SHARED_AUDIO_HEADER_SIZE,
               "sizeof(RFSharedAudio) must equal RF_SHARED_AUDIO_HEADER_SIZE");

typedef struct {
    const char* name;
    size_t offset;
    size_t size;
} FieldRow;

int main(void) {
    const FieldRow rows[] = {
        {"protocol_version",    offsetof(RFSharedAudio, protocol_version),    sizeof(uint32_t)},
        {"header_size",         offsetof(RFSharedAudio, header_size),         sizeof(uint32_t)},
        {"sample_rate",         offsetof(RFSharedAudio, sample_rate),         sizeof(uint32_t)},
        {"channels",            offsetof(RFSharedAudio, channels),            sizeof(uint32_t)},
        {"format",              offsetof(RFSharedAudio, format),              sizeof(uint32_t)},
        {"bytes_per_sample",    offsetof(RFSharedAudio, bytes_per_sample),    sizeof(uint32_t)},
        {"bytes_per_frame",     offsetof(RFSharedAudio, bytes_per_frame),     sizeof(uint32_t)},
        {"ring_capacity_frames",offsetof(RFSharedAudio, ring_capacity_frames),sizeof(uint32_t)},
        {"ring_duration_ms",    offsetof(RFSharedAudio, ring_duration_ms),    sizeof(uint32_t)},
        {"driver_capabilities", offsetof(RFSharedAudio, driver_capabilities), sizeof(uint32_t)},
        {"host_capabilities",   offsetof(RFSharedAudio, host_capabilities),   sizeof(uint32_t)},
        {"creation_timestamp",  offsetof(RFSharedAudio, creation_timestamp),  sizeof(uint64_t)},
        {"format_change_counter",offsetof(RFSharedAudio, format_change_counter), sizeof(uint64_t)},
        {"write_index",         offsetof(RFSharedAudio, write_index),         sizeof(uint64_t)},
        {"read_index",          offsetof(RFSharedAudio, read_index),          sizeof(uint64_t)},
        {"total_frames_written",offsetof(RFSharedAudio, total_frames_written),sizeof(uint64_t)},
        {"total_frames_read",   offsetof(RFSharedAudio, total_frames_read),   sizeof(uint64_t)},
        {"overrun_count",       offsetof(RFSharedAudio, overrun_count),       sizeof(uint64_t)},
        {"underrun_count",      offsetof(RFSharedAudio, underrun_count),      sizeof(uint64_t)},
        {"format_mismatch_count",offsetof(RFSharedAudio, format_mismatch_count), sizeof(uint64_t)},
        {"driver_connected",    offsetof(RFSharedAudio, driver_connected),    sizeof(uint32_t)},
        {"host_connected",      offsetof(RFSharedAudio, host_connected),      sizeof(uint32_t)},
        {"driver_heartbeat",    offsetof(RFSharedAudio, driver_heartbeat),    sizeof(uint64_t)},
        {"host_heartbeat",      offsetof(RFSharedAudio, host_heartbeat),      sizeof(uint64_t)},
        {"volume_scalar",       offsetof(RFSharedAudio, volume_scalar),       sizeof(float)},
        {"mute_state",          offsetof(RFSharedAudio, mute_state),          sizeof(int32_t)},
        {"eq_sequence",         offsetof(RFSharedAudio, eq_sequence),         sizeof(uint32_t)},
        {"eq_snapshot",         offsetof(RFSharedAudio, eq_snapshot),         sizeof(RFEQSnapshot)},
        {"volume_mode",         offsetof(RFSharedAudio, volume_mode),         sizeof(uint32_t)},
        {"state_initialized",   offsetof(RFSharedAudio, state_initialized),   sizeof(uint32_t)},
        {"state_pad0",          offsetof(RFSharedAudio, state_pad0),          sizeof(uint32_t)},
        {"state_revision",      offsetof(RFSharedAudio, state_revision),      sizeof(uint64_t)},
        {"underrun_frames",     offsetof(RFSharedAudio, underrun_frames),     sizeof(uint32_t)},
        {"_reserved",           offsetof(RFSharedAudio, _reserved),           sizeof(((RFSharedAudio*)0)->_reserved)},
        /* Batch 2 admission gateway */
        {"admission_state",     offsetof(RFSharedAudio, admission_state),     sizeof(uint32_t)},
        {"admission_pad0",      offsetof(RFSharedAudio, admission_pad0),      sizeof(uint32_t)},
        {"admission_epoch",     offsetof(RFSharedAudio, admission_epoch),     sizeof(uint64_t)},
        {"producer_owner_token",offsetof(RFSharedAudio, producer_owner_token),sizeof(uint64_t)},
        {"admission_claim_seq", offsetof(RFSharedAudio, admission_claim_seq), sizeof(uint64_t)},
        {"_reserved2",          offsetof(RFSharedAudio, _reserved2),          sizeof(((RFSharedAudio*)0)->_reserved2)},
    };

    printf("protocol version : 0x%08X\n", RF_AUDIO_PROTOCOL_VERSION);
    printf("header size      : %u bytes\n", RF_SHARED_AUDIO_HEADER_SIZE);
    printf("sizeof(struct)   : %zu bytes\n", sizeof(RFSharedAudio));
    printf("alignof(struct)  : %zu bytes\n", (size_t)_Alignof(RFSharedAudio));
    printf("audio_data offset: %zu bytes\n", offsetof(RFSharedAudio, audio_data));
    printf("volume taper     : %d raw steps, %.1f dB range (Pow2 branch requires > 30 dB)\n",
           RF_VOLUME_RAW_RANGE, (double)RF_VOLUME_DB_RANGE);
    printf("\n%-22s %8s %6s\n", "field", "offset", "size");
    printf("%-22s %8s %6s\n", "-----", "------", "----");
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        printf("%-22s %8zu %6zu\n", rows[i].name, rows[i].offset, rows[i].size);
    }
    return 0;
}
EOF

echo "Protocol layout check"
echo "====================="

clang -std=c11 -Wall -Wextra -Werror \
    -I "$INCLUDE_DIR" \
    "$TMP_DIR/layout_probe.c" -o "$TMP_DIR/layout_probe"
echo "C11 compile:  OK"

# Same translation unit through a C++ compiler: the header must stay valid in
# both languages, because the driver builds it as C++ and the Host as C.
printf '#include "RFSharedAudio.h"\nint main() { return (int)sizeof(RFSharedAudio); }\n' \
    > "$TMP_DIR/cxx_probe.cpp"
clang++ -std=c++17 -Wall -Wextra -Werror \
    -I "$INCLUDE_DIR" -c "$TMP_DIR/cxx_probe.cpp" -o "$TMP_DIR/cxx_probe.o"
echo "C++17 compile: OK"

"$TMP_DIR/layout_probe"

# The driver bundle advertises the protocol it was built against, and the app's
# install gate refuses a driver whose number differs. That only works while the
# two agree: a stale plist would make the gate demand a reinstall of a driver
# that still reports the old number, forever. Checked, not trusted.
DRIVER_PLIST="$ROOT/packages/driver/Info.plist"
HEADER_HEX=$(sed -nE 's/^[[:space:]]*#[[:space:]]*define[[:space:]]+RF_AUDIO_PROTOCOL_VERSION[[:space:]]+(0x[0-9A-Fa-f]+)[uUlL]*.*$/\1/p' "$HEADER" | head -n 1)
if [[ -z "$HEADER_HEX" ]]; then
    echo "FAIL: could not read RF_AUDIO_PROTOCOL_VERSION from $HEADER" >&2
    exit 1
fi
HEADER_DEC=$((HEADER_HEX))

if [[ ! -f "$DRIVER_PLIST" ]]; then
    echo "FAIL: driver Info.plist missing: $DRIVER_PLIST" >&2
    exit 1
fi

PLIST_DEC=$(/usr/libexec/PlistBuddy -c "Print :SBAudioProtocolVersion" "$DRIVER_PLIST" 2>/dev/null || echo "")
if [[ "$PLIST_DEC" != "$HEADER_DEC" ]]; then
    echo "FAIL: packages/driver/Info.plist declares SBAudioProtocolVersion='${PLIST_DEC:-<missing>}' but the header says $HEADER_HEX ($HEADER_DEC)." >&2
    echo "      The app would reject every driver it installs. Resync with:" >&2
    echo "        /usr/libexec/PlistBuddy -c 'Set :SBAudioProtocolVersion $HEADER_DEC' packages/driver/Info.plist" >&2
    echo "      or run ./tools/update_versions.sh, which does it automatically." >&2
    exit 1
fi
echo "Driver plist:   OK (SBAudioProtocolVersion=$PLIST_DEC)"
