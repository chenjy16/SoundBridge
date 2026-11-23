#ifndef RF_SHARED_AUDIO_H
#define RF_SHARED_AUDIO_H

// ============================================================================
// SoundBridge shared-memory protocol — SINGLE SOURCE OF TRUTH.
//
// This file is the only place where the wire format may be edited.
// The three copies consumed by the build are generated from this file by
// `tools/sync_shared_header.sh` and must never be edited by hand:
//
//   packages/driver/include/RFSharedAudio.h
//   packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
//   apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
//
// `make protocol-check` (and CI) fails when a copy drifts from this file.
// ============================================================================

#include <stdint.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <assert.h>
#include <math.h>
#include <time.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Protocol version
//
// Bumped to 0x00020100 for 1.2.0 because Phase 2.1 changed the ABI:
//   - `_reserved` sizing bug fixed (header is now exactly 256 bytes,
//     it was 264 before because the base offset for the expression was wrong)
//   - new state fields inserted into the reserved area (see below)
//
// Bumped to 0x00020200 for Phase 2.2 / Batch 2: the admission gateway adds a
// 64-byte block at offset 256 and the fixed header grows 256 -> 320 bytes. The
// layout change is the reason for the bump, not a side effect of it.
//
// The driver compares this value for EXACT equality (Plugin.cpp,
// ValidateConnection). A version mismatch is a hard connection refusal,
// never a best-effort attach: reading a layout you do not know is how you
// get silent data corruption in an audio path.
// ============================================================================
#define RF_AUDIO_PROTOCOL_VERSION 0x00020200

// ============================================================================
// Admission gateway states (Batch 2)
//
// CLOSED  -> no producer may write. The state a freshly initialized mapping
//            is in, and the state a Host leaves behind after tearing it down.
// OPEN    -> exactly one producer owner may write (the holder of
//            producer_owner_token). Set by the Host, never by the driver.
// CLOSING -> the Host has revoked admission; producers must stop writing but
//            in-flight callbacks may still be running. This is NOT a drain
//            proof and NOT permission to unmap or reuse the mapping.
//
// Any other value is invalid and every helper fails closed on it.
// ============================================================================
#define RF_ADMISSION_CLOSED 0u
#define RF_ADMISSION_OPEN 1u
#define RF_ADMISSION_CLOSING 2u

// Audio format types
typedef enum {
    RF_FORMAT_FLOAT32 = 0,
    RF_FORMAT_FLOAT64 = 1,
    RF_FORMAT_INT16 = 2,
    RF_FORMAT_INT24 = 3,
    RF_FORMAT_INT32 = 4
} RFAudioFormat;

// Supported nominal sample rates.
static const uint32_t RF_SUPPORTED_SAMPLE_RATES[] = {
    44100,   // 44.1 kHz
    48000,   // 48 kHz
    88200,   // 88.2 kHz
    96000,   // 96 kHz
    176400,  // 176.4 kHz
    192000   // 192 kHz
};
#define RF_NUM_SAMPLE_RATES 6

// Channel configuration
#define RF_MAX_CHANNELS 8  // Up to 7.1 channel layouts

// Ring buffer duration limits (sample-rate independent).
#define RF_RING_DURATION_MS_MIN 20
#define RF_RING_DURATION_MS_MAX 100
#define RF_RING_DURATION_MS_DEFAULT 100

// ============================================================================
// Volume mode
//
// Phase 2.1 only builds the state model; HARDWARE routing is NOT implemented
// yet (that is Phase 2.2). The field exists now so the ABI does not have to
// change twice.
// ============================================================================
#define RF_VOLUME_MODE_SOFTWARE 0u  // Host applies gain in its render callback
#define RF_VOLUME_MODE_HARDWARE 1u  // Host writes the physical device's dB value

// ============================================================================
// Volume taper constants — MUST stay in sync with the Host-side mirror in
// packages/host/Sources/SoundBridgeHost/Audio/VolumeTaper.swift and with the
// driver's aspl::VolumeControlParameters.
//
// Target curve, verified against libASPL's VolumeCurve implementation:
//
//     raw   = round(sqrt(s) * RF_VOLUME_RAW_RANGE)      (VolumeCurve.cpp)
//     dB    = RF_VOLUME_DB_MIN + (raw - RF_VOLUME_RAW_MIN) * dBPerRaw
//           = 48 * sqrt(s) - 48
//
// TRAP: libASPL applies the Pow2 transfer function ONLY when
// `(MaxDecibelVolume - MinDecibelVolume) > 30.0f` (VolumeCurve.cpp,
// ConvertRawToScalar / ConvertScalarToRaw). At 48 dB we are inside the
// non-linear branch. If anyone shrinks this range to 30 dB or below, the
// curve silently degrades to linear and every Host-side gain becomes wrong
// by up to ~29 dB without a single compile error. The static_assert below
// turns that into a build failure. Do not remove it.
// ============================================================================
#define RF_VOLUME_DB_MIN   (-48.0f)
#define RF_VOLUME_DB_MAX   (0.0f)
#define RF_VOLUME_DB_RANGE (RF_VOLUME_DB_MAX - RF_VOLUME_DB_MIN)  // 48.0f
#define RF_VOLUME_RAW_MIN  0
#define RF_VOLUME_RAW_MAX  48
#define RF_VOLUME_RAW_RANGE (RF_VOLUME_RAW_MAX - RF_VOLUME_RAW_MIN)  // 48

#ifdef __cplusplus
    static_assert(RF_VOLUME_DB_RANGE > 30.0f,
        "libASPL only applies the Pow2 volume transfer function when the dB "
        "range exceeds 30 dB. Below that the curve silently becomes linear "
        "and disagrees with the Host gain stage.");
#else
    _Static_assert(RF_VOLUME_DB_RANGE > 30.0f,
        "libASPL only applies the Pow2 volume transfer function when the dB "
        "range exceeds 30 dB. Below that the curve silently becomes linear "
        "and disagrees with the Host gain stage.");
#endif

// ============================================================================
// Fixed header size.
//
// `header_size` in the struct below carries this exact value. It is the size
// of the fixed header only — the audio payload lives in the flexible array
// member `audio_data[]` and is sized separately by `rf_shared_audio_size()`.
//
// The previous revision computed `_reserved` as `256 - 148 - sizeof(snapshot)`
// while `eq_snapshot` actually starts at offset 156, which made the header 264
// bytes instead of the 256 the comment promised. Phase 2.1 fixes the base and
// pins every offset with static_assert so this cannot drift again.
//
// Batch 2 (Phase 2.2) appends a 64-byte admission block after the untouched
// 28-byte `_reserved` area, so the fixed header is now 320 bytes. `_reserved`
// (the Phase 6A marker + Host session UUID) did NOT move: every pre-Batch-2
// field keeps its offset.
// ============================================================================
#define RF_SHARED_AUDIO_HEADER_SIZE 320u

// Calculate frames for given sample rate and duration
static inline uint32_t rf_frames_for_duration(uint32_t sample_rate, uint32_t duration_ms) {
    return (sample_rate * duration_ms) / 1000;
}

/**
 * Next power of two of a 32-bit value.
 *
 * Returns 0 when the next power of two would not fit in uint32_t; callers
 * must treat 0 as "capacity cannot be represented" and fail closed.
 */
static inline uint32_t rf_next_power_of_two_u32(uint32_t n) {
    if (n == 0) return 0;
    if (n > (1u << 31)) return 0;
    uint32_t p = 1u;
    while (p < n) p <<= 1;
    return p;
}

/**
 * Ring capacity for a requested duration, rounded UP to a power of two.
 *
 * Batch 0 contract: ring_capacity_frames must be > 0 and a power of two so
 * the slot mask (capacity - 1) is exact and every capacity-dependent check
 * (validate, size, prefill) sees the SAME single source of truth. The
 * requested duration stays in ring_duration_ms; the actual capacity may
 * exceed the requested frame count (e.g. 48 kHz / 100 ms requests 4800
 * frames, the ring holds 8192). Returns 0 if the rounded capacity cannot be
 * represented, which every caller must treat as init failure.
 */
static inline uint32_t rf_ring_capacity_frames_for(uint32_t sample_rate, uint32_t duration_ms) {
    return rf_next_power_of_two_u32(rf_frames_for_duration(sample_rate, duration_ms));
}

/**
 * EQ snapshot for cross-process communication.
 * Written by App (30Hz), read by Host in render loop.
 * Simple memcpy — no locking needed at this frequency/size.
 */
typedef struct {
    float bands[10];    // 10-band gain values in dB
    float preamp;       // Auto-gain compensation in dB
    bool bypass;        // true = EQ bypassed
    uint8_t _pad[3];   // Align to 48 bytes
} RFEQSnapshot;

/**
 * Snapshot of the volume state block, returned by rf_read_volume_state().
 *
 * This exists because Swift cannot touch C11 `_Atomic` members directly, and so
 * that the four related fields are returned as one value instead of four.
 *
 * Consistency, stated precisely: the fields belong to a single commit only if no
 * commit started while they were being read, which rf_read_volume_state()
 * narrows by re-reading `state_revision` after the payload and retrying when it
 * moved. The residual window is the publish order itself —
 * rf_publish_volume_state() writes the values, then bumps the revision, so a
 * reader racing the *middle* of one publish can pair new values with the
 * previous revision. Closing that requires a seqlock (bump before and after),
 * which would double every revision value and break interop with a 1.1.x driver
 * that only bumps once; it is therefore a protocol decision, not a bug fix.
 */
typedef struct {
    float scalar;      // 0.0 - 1.0, the value the Host gain stage must use
    int32_t muted;     // 0 = unmuted, 1 = muted
    uint32_t mode;     // RF_VOLUME_MODE_SOFTWARE / RF_VOLUME_MODE_HARDWARE
    uint64_t revision; // state_revision at the time of the read
} RFVolumeStateSnapshot;

/**
 * Shared memory protocol header plus flexible audio payload.
 *
 * ABI rules (enforced by the static_assert block below):
 *   - every field offset is pinned,
 *   - the fixed header is exactly RF_SHARED_AUDIO_HEADER_SIZE bytes,
 *   - adding or moving a field requires bumping RF_AUDIO_PROTOCOL_VERSION.
 */
typedef struct {
    // ===== PROTOCOL INFO =====
    uint32_t protocol_version;        // RF_AUDIO_PROTOCOL_VERSION
    uint32_t header_size;             // RF_SHARED_AUDIO_HEADER_SIZE (= sizeof(RFSharedAudio))

    // ===== AUDIO FORMAT (negotiated) =====
    uint32_t sample_rate;             // Current sample rate (44100-192000)
    uint32_t channels;                // Current channel count (1-8)
    uint32_t format;                  // RFAudioFormat enum value
    uint32_t bytes_per_sample;        // Bytes per single sample (4 for float32, etc.)
    uint32_t bytes_per_frame;         // bytes_per_sample * channels

    // ===== RING BUFFER CONFIG =====
    uint32_t ring_capacity_frames;    // Total frames in ring buffer
    uint32_t ring_duration_ms;        // Duration in milliseconds

    // ===== CAPABILITY FLAGS =====
    uint32_t driver_capabilities;     // Bit flags for driver features
    uint32_t host_capabilities;       // Bit flags for host features

    // ===== TIMING & SYNC =====
    uint64_t creation_timestamp;      // Unix timestamp
    _Atomic uint64_t format_change_counter;  // Increments on format change

    // ===== ATOMIC INDICES =====
    _Atomic uint64_t write_index;     // Producer write position (frames)
    _Atomic uint64_t read_index;      // Consumer read position (frames)

    // ===== STATISTICS =====
    _Atomic uint64_t total_frames_written;
    _Atomic uint64_t total_frames_read;
    _Atomic uint64_t overrun_count;
    _Atomic uint64_t underrun_count;
    _Atomic uint64_t format_mismatch_count;  // Format negotiation failures

    // ===== STATUS FLAGS =====
    _Atomic uint32_t driver_connected;   // 1 if driver is connected
    _Atomic uint32_t host_connected;     // 1 if host is connected
    _Atomic uint64_t driver_heartbeat;   // Incremented by driver write callbacks
    _Atomic uint64_t host_heartbeat;     // Incremented by host heartbeat timer

    // ===== VOLUME CONTROL =====
    _Atomic float   volume_scalar;       // 0.0 - 1.0, default 0.35
    _Atomic int32_t mute_state;          // 0 = unmuted, 1 = muted

    // ===== EQ CONTROL =====
    _Atomic uint32_t eq_sequence;        // SeqLock: even = idle, odd = writing
    RFEQSnapshot eq_snapshot;            // 48 bytes — written by App, read by Host

    // ===== VOLUME STATE MODEL (Phase 2.1) =====
    //
    // Ownership: the Host process is the authoritative writer of
    // `volume_mode`, `state_initialized` and `state_revision`.
    //
    // The single exception is the driver's first-time bootstrap: when and only
    // when `state_initialized == 0`, the driver may call
    // rf_publish_volume_state() once to seed the block. It runs inside
    // OnStartIO under io_mutex_, and because `state_initialized` latches to 1
    // the bootstrap can never run twice for the same mapping.
    //
    // The driver's realtime volume path (SoundBridgeVolumeControl::
    // SetRawValueImpl) writes `volume_scalar` / `mute_state` only. It never
    // touches revision or the initialized flag, so it cannot forge a commit.
    _Atomic uint32_t volume_mode;        // RF_VOLUME_MODE_* — default SOFTWARE
    _Atomic uint32_t state_initialized;  // 0 = seed defaults only, 1 = committed
    uint32_t state_pad0;                 // explicit padding: keeps state_revision 8-byte aligned
    _Atomic uint64_t state_revision;     // +1 on every committed volume state change
    _Atomic uint32_t underrun_frames;    // cumulative frames of silence inserted on underrun

    // Reserved bytes for forward-compatible header growth.
    // Phase 6A 使用前 20 字节保存标识和 Host UUID；旧读写者忽略这些字节。
    //
    // Batch 2 froze the size at 28 (offset 228, ending exactly where the
    // admission block starts at 256) instead of deriving it from
    // RF_SHARED_AUDIO_HEADER_SIZE — otherwise growing the header would have
    // swallowed the admission fields below.
    uint8_t _reserved[28];

    // ===== ADMISSION GATEWAY (Batch 2) =====
    //
    // One mapping incarnation has at most ONE valid producer owner. The Host
    // creates the mapping, initializes it CLOSED and publishes it OPEN; the
    // driver claims the single owner slot with a token that encodes its uid.
    // Producer writes are refused unless admission is OPEN and the caller
    // holds that exact token (see rf_ring_write).
    //
    // See Batch-2-Admission-Protocol.md for the state machine, the claim /
    // release rules and why CLOSED is not a drain proof.
    _Atomic uint32_t admission_state;       // RF_ADMISSION_CLOSED / _OPEN / _CLOSING
    uint32_t admission_pad0;                // explicit padding: keeps the block 8-byte aligned
    _Atomic uint64_t admission_epoch;       // mapping incarnation token; written by the Host before OPEN
    _Atomic uint64_t producer_owner_token;  // 0 = no producer owner; else the claiming token
    _Atomic uint64_t admission_claim_seq;   // successful claim transitions (diagnostics only)
    uint8_t _reserved2[32];                 // future drain ACK / quarantine (Batch 3+), zero for now

    // ===== RING BUFFER DATA =====
    // Interleaved audio data in the negotiated format
    // Size is: ring_capacity_frames * channels * bytes_per_sample
    // This MUST be the last field (flexible array member)
    uint8_t audio_data[];

} RFSharedAudio;

// ============================================================================
// ABI layout assertions
//
// These are the contract between the driver (C++), the Host (Swift) and the
// App (Swift). If any of them fires, the protocol changed and
// RF_AUDIO_PROTOCOL_VERSION must be bumped deliberately — not "fixed" by
// editing the number on the right-hand side.
// ============================================================================
#if defined(__cplusplus)
    static_assert(offsetof(RFSharedAudio, protocol_version) == 0,   "protocol_version moved");
    static_assert(offsetof(RFSharedAudio, header_size) == 4,        "header_size moved");
    static_assert(offsetof(RFSharedAudio, creation_timestamp) == 48, "creation_timestamp moved");
    static_assert(offsetof(RFSharedAudio, driver_connected) == 120, "driver_connected moved");
    static_assert(offsetof(RFSharedAudio, host_connected) == 124,   "host_connected moved");
    static_assert(offsetof(RFSharedAudio, driver_heartbeat) == 128, "driver_heartbeat moved");
    static_assert(offsetof(RFSharedAudio, host_heartbeat) == 136,   "host_heartbeat moved");
    static_assert(offsetof(RFSharedAudio, volume_scalar) == 144,    "volume_scalar moved");
    static_assert(offsetof(RFSharedAudio, mute_state) == 148,       "mute_state moved");
    static_assert(offsetof(RFSharedAudio, eq_sequence) == 152,      "eq_sequence moved");
    static_assert(offsetof(RFSharedAudio, eq_snapshot) == 156,      "eq_snapshot moved");
    static_assert(offsetof(RFSharedAudio, volume_mode) == 204,      "volume_mode moved");
    static_assert(offsetof(RFSharedAudio, state_initialized) == 208, "state_initialized moved");
    static_assert(offsetof(RFSharedAudio, state_revision) == 216,   "state_revision moved");
    static_assert(offsetof(RFSharedAudio, underrun_frames) == 224,  "underrun_frames moved");
    static_assert(offsetof(RFSharedAudio, _reserved) == 228,        "_reserved moved");
    static_assert(offsetof(RFSharedAudio, admission_state) == 256,  "admission_state moved");
    static_assert(offsetof(RFSharedAudio, admission_epoch) == 264,  "admission_epoch moved");
    static_assert(offsetof(RFSharedAudio, producer_owner_token) == 272, "producer_owner_token moved");
    static_assert(offsetof(RFSharedAudio, admission_claim_seq) == 280,  "admission_claim_seq moved");
    static_assert(offsetof(RFSharedAudio, _reserved2) == 288,       "_reserved2 moved");
    static_assert(offsetof(RFSharedAudio, audio_data) == RF_SHARED_AUDIO_HEADER_SIZE,
        "fixed header size does not match RF_SHARED_AUDIO_HEADER_SIZE");
    static_assert(sizeof(RFSharedAudio) == RF_SHARED_AUDIO_HEADER_SIZE,
        "sizeof(RFSharedAudio) must equal the fixed header size");
    static_assert(sizeof(RFEQSnapshot) == 48, "RFEQSnapshot must stay 48 bytes");
    static_assert(sizeof(RFVolumeStateSnapshot) == 24, "RFVolumeStateSnapshot layout changed");
    // RT contract: the admission fields are read inside the audio callback. If
    // any of them were not lock-free, the atomic would become a libatomic call
    // (a lock) in the render path — exactly the priority inversion the gateway
    // exists to prevent. These asserts are compile-time on every target.
    static_assert(ATOMIC_INT_LOCK_FREE == 2, "admission_state must be lock-free on every target");
    static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "admission epoch / owner token must be lock-free");
#else
    _Static_assert(offsetof(RFSharedAudio, protocol_version) == 0,   "protocol_version moved");
    _Static_assert(offsetof(RFSharedAudio, header_size) == 4,        "header_size moved");
    _Static_assert(offsetof(RFSharedAudio, creation_timestamp) == 48, "creation_timestamp moved");
    _Static_assert(offsetof(RFSharedAudio, driver_connected) == 120, "driver_connected moved");
    _Static_assert(offsetof(RFSharedAudio, host_connected) == 124,   "host_connected moved");
    _Static_assert(offsetof(RFSharedAudio, driver_heartbeat) == 128, "driver_heartbeat moved");
    _Static_assert(offsetof(RFSharedAudio, host_heartbeat) == 136,   "host_heartbeat moved");
    _Static_assert(offsetof(RFSharedAudio, volume_scalar) == 144,    "volume_scalar moved");
    _Static_assert(offsetof(RFSharedAudio, mute_state) == 148,       "mute_state moved");
    _Static_assert(offsetof(RFSharedAudio, eq_sequence) == 152,      "eq_sequence moved");
    _Static_assert(offsetof(RFSharedAudio, eq_snapshot) == 156,      "eq_snapshot moved");
    _Static_assert(offsetof(RFSharedAudio, volume_mode) == 204,      "volume_mode moved");
    _Static_assert(offsetof(RFSharedAudio, state_initialized) == 208, "state_initialized moved");
    _Static_assert(offsetof(RFSharedAudio, state_revision) == 216,   "state_revision moved");
    _Static_assert(offsetof(RFSharedAudio, underrun_frames) == 224,  "underrun_frames moved");
    _Static_assert(offsetof(RFSharedAudio, _reserved) == 228,        "_reserved moved");
    _Static_assert(offsetof(RFSharedAudio, admission_state) == 256,  "admission_state moved");
    _Static_assert(offsetof(RFSharedAudio, admission_epoch) == 264,  "admission_epoch moved");
    _Static_assert(offsetof(RFSharedAudio, producer_owner_token) == 272, "producer_owner_token moved");
    _Static_assert(offsetof(RFSharedAudio, admission_claim_seq) == 280,  "admission_claim_seq moved");
    _Static_assert(offsetof(RFSharedAudio, _reserved2) == 288,       "_reserved2 moved");
    _Static_assert(offsetof(RFSharedAudio, audio_data) == RF_SHARED_AUDIO_HEADER_SIZE,
        "fixed header size does not match RF_SHARED_AUDIO_HEADER_SIZE");
    _Static_assert(sizeof(RFSharedAudio) == RF_SHARED_AUDIO_HEADER_SIZE,
        "sizeof(RFSharedAudio) must equal the fixed header size");
    _Static_assert(sizeof(RFEQSnapshot) == 48, "RFEQSnapshot must stay 48 bytes");
    _Static_assert(sizeof(RFVolumeStateSnapshot) == 24, "RFVolumeStateSnapshot layout changed");
    _Static_assert(ATOMIC_INT_LOCK_FREE == 2, "admission_state must be lock-free on every target");
    _Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "admission epoch / owner token must be lock-free");
#endif

// Session 扩展只在新建且尚未发布的映射上写入一次；发布后不可修改。
// UUID 使用 RFC 4122 的 16 字节顺序，与控制文件中的 UUID 对应。
#define RF_HOST_SESSION_SIZE 16u
static inline void rf_set_host_session(RFSharedAudio* mem, const uint8_t* uuid) {
    static const uint8_t marker[4] = {'S', 'B', '6', 'A'};
    memcpy(mem->_reserved, marker, sizeof(marker));
    memcpy(mem->_reserved + sizeof(marker), uuid, RF_HOST_SESSION_SIZE);
}

static inline bool rf_host_session_matches(const RFSharedAudio* mem, const uint8_t* uuid) {
    static const uint8_t marker[4] = {'S', 'B', '6', 'A'};
    return mem != NULL && uuid != NULL &&
        memcmp(mem->_reserved, marker, sizeof(marker)) == 0 &&
        memcmp(mem->_reserved + sizeof(marker), uuid, RF_HOST_SESSION_SIZE) == 0;
}

// Capability flags
#define RF_CAP_MULTI_SAMPLE_RATE    (1 << 0)  // Supports multiple sample rates
#define RF_CAP_MULTI_FORMAT         (1 << 1)  // Supports multiple formats
#define RF_CAP_MULTI_CHANNEL        (1 << 2)  // Supports multiple channel counts
#define RF_CAP_SAMPLE_RATE_CONVERT  (1 << 3)  // Has sample rate converter
#define RF_CAP_FORMAT_CONVERT       (1 << 4)  // Has format converter
#define RF_CAP_AUTO_RECONNECT       (1 << 5)  // Supports auto-reconnect
#define RF_CAP_HEARTBEAT_MONITOR    (1 << 6)  // Monitors connection health

/**
 * Calculate total size needed for shared memory
 */
static inline size_t rf_shared_audio_size(uint32_t capacity_frames,
                                              uint32_t channels,
                                              uint32_t bytes_per_sample) {
    return sizeof(RFSharedAudio) + (capacity_frames * channels * bytes_per_sample);
}

/**
 * Initialize shared memory with format specification
 *
 * The volume block is left in the "seed defaults, not yet committed" state:
 * `volume_scalar` holds the safe default but `state_initialized == 0`, so the
 * driver knows it must not treat it as an authoritative user setting.
 */
static inline void rf_shared_audio_init(
    RFSharedAudio* mem,
    uint32_t sample_rate,
    uint32_t channels,
    RFAudioFormat format,
    uint32_t duration_ms)
{
    memset(mem, 0, sizeof(RFSharedAudio));
    // Note: memset zeroes eq_snapshot (bands=0, preamp=0, bypass=false)

    mem->protocol_version = RF_AUDIO_PROTOCOL_VERSION;
    mem->header_size = RF_SHARED_AUDIO_HEADER_SIZE;

    // Audio format
    mem->sample_rate = sample_rate;
    mem->channels = channels;
    mem->format = format;

    // Calculate bytes per sample based on format
    switch (format) {
        case RF_FORMAT_FLOAT32: mem->bytes_per_sample = 4; break;
        case RF_FORMAT_FLOAT64: mem->bytes_per_sample = 8; break;
        case RF_FORMAT_INT16:   mem->bytes_per_sample = 2; break;
        case RF_FORMAT_INT24:   mem->bytes_per_sample = 3; break;
        case RF_FORMAT_INT32:   mem->bytes_per_sample = 4; break;
        default:                mem->bytes_per_sample = 4; break;
    }

    mem->bytes_per_frame = mem->bytes_per_sample * channels;

    // Ring buffer sizing (power of two, single source of truth — see
    // rf_ring_capacity_frames_for). A 0 result means the capacity cannot be
    // represented; callers check ring_capacity_frames before publishing.
    mem->ring_capacity_frames = rf_ring_capacity_frames_for(sample_rate, duration_ms);
    mem->ring_duration_ms = duration_ms;

    // Capabilities - driver advertises what it supports
    mem->driver_capabilities =
        RF_CAP_MULTI_SAMPLE_RATE |
        RF_CAP_MULTI_FORMAT |
        RF_CAP_MULTI_CHANNEL |
        RF_CAP_FORMAT_CONVERT |
        RF_CAP_AUTO_RECONNECT |
        RF_CAP_HEARTBEAT_MONITOR;

    mem->creation_timestamp = (uint64_t)time(NULL);

    // Initialize atomics
    atomic_store(&mem->format_change_counter, 0);
    atomic_store(&mem->write_index, 0);
    atomic_store(&mem->read_index, 0);
    atomic_store(&mem->total_frames_written, 0);
    atomic_store(&mem->total_frames_read, 0);
    atomic_store(&mem->overrun_count, 0);
    atomic_store(&mem->underrun_count, 0);
    atomic_store(&mem->format_mismatch_count, 0);
    atomic_store(&mem->driver_connected, 0);
    atomic_store(&mem->host_connected, 1);  // Host creates the memory
    atomic_store(&mem->driver_heartbeat, 0);
    atomic_store(&mem->host_heartbeat, 0);

    // Volume control defaults (seeded, NOT committed — see state_initialized)
    atomic_init(&mem->volume_scalar, 0.35f);
    atomic_init(&mem->mute_state, 0);

    // EQ SeqLock
    atomic_init(&mem->eq_sequence, 0);

    // Volume state model: defaults only, no committed state yet
    atomic_init(&mem->volume_mode, RF_VOLUME_MODE_SOFTWARE);
    atomic_init(&mem->state_initialized, 0u);
    mem->state_pad0 = 0;
    atomic_init(&mem->state_revision, 0);
    atomic_init(&mem->underrun_frames, 0);

    // Admission gateway (Batch 2): a new mapping starts CLOSED with no epoch
    // and no producer owner. The Host must call rf_admission_open() after the
    // mapping is fully initialized (and, in practice, after the pre-publish
    // prefill) but before it is published. memset above already zeroed these;
    // the explicit atomic_init documents the initial state as a contract, not
    // an accident of zero-fill (RF_ADMISSION_CLOSED is 0 by design).
    atomic_init(&mem->admission_state, RF_ADMISSION_CLOSED);
    mem->admission_pad0 = 0;
    atomic_init(&mem->admission_epoch, 0);
    atomic_init(&mem->producer_owner_token, 0);
    atomic_init(&mem->admission_claim_seq, 0);
}

/**
 * Check if sample rate is supported
 */
static inline bool rf_is_sample_rate_supported(uint32_t sample_rate) {
    for (int i = 0; i < RF_NUM_SAMPLE_RATES; i++) {
        if (RF_SUPPORTED_SAMPLE_RATES[i] == sample_rate) {
            return true;
        }
    }
    return false;
}

/**
 * Result of rf_validate_header().
 */
typedef enum {
    RF_VALIDATE_OK = 0,
    RF_VALIDATE_NULL = 1,
    RF_VALIDATE_PROTOCOL_VERSION = 2,
    RF_VALIDATE_HEADER_SIZE = 3,
    RF_VALIDATE_SAMPLE_RATE = 4,
    RF_VALIDATE_CHANNELS = 5,
    RF_VALIDATE_CAPACITY = 6,
    RF_VALIDATE_ADMISSION = 7
} RFValidateResult;

/**
 * Validate a mapped header before either side reads or writes it.
 *
 * This is the single implementation of the connection contract: the driver
 * calls it from Plugin.cpp (ValidateConnection) and the Host test suite calls
 * it through CSoundBridgeAudio, so the rules cannot drift between the two
 * languages.
 *
 * `header_size` is the fixed-header byte count (RF_SHARED_AUDIO_HEADER_SIZE),
 * NOT the total mapping length. A mismatch here means the other side was built
 * against a different struct layout and must be refused, never attached
 * best-effort: guessing an unknown layout corrupts an audio path silently.
 */
static inline RFValidateResult rf_validate_header(const RFSharedAudio* mem) {
    if (mem == NULL) {
        return RF_VALIDATE_NULL;
    }
    if (mem->protocol_version != RF_AUDIO_PROTOCOL_VERSION) {
        return RF_VALIDATE_PROTOCOL_VERSION;
    }
    if (mem->header_size != RF_SHARED_AUDIO_HEADER_SIZE) {
        return RF_VALIDATE_HEADER_SIZE;
    }
    if (!rf_is_sample_rate_supported(mem->sample_rate)) {
        return RF_VALIDATE_SAMPLE_RATE;
    }
    if (mem->channels == 0 || mem->channels > RF_MAX_CHANNELS) {
        return RF_VALIDATE_CHANNELS;
    }
    // Ring capacity must be a usable power of two: the slot addressing uses
    // (capacity - 1) as a mask, and a zero or non-power-of-two capacity would
    // make every ring helper undefined (previously a `% 0` UB on a corrupt
    // header). Fail closed instead of guessing.
    if (mem->ring_capacity_frames == 0 ||
        (mem->ring_capacity_frames & (mem->ring_capacity_frames - 1u)) != 0u) {
        return RF_VALIDATE_CAPACITY;
    }
    // Admission must hold one of the three defined values. CLOSED is valid
    // (a mapping is published CLOSED only if the Host failed before opening
    // it, and the driver answers that by refusing every write), but a value
    // nobody defines means we cannot reason about the gateway at all — fail
    // closed rather than let an unknown state be treated as "not OPEN".
    const uint32_t admission = atomic_load_explicit(&mem->admission_state, memory_order_acquire);
    if (admission != RF_ADMISSION_CLOSED && admission != RF_ADMISSION_OPEN &&
        admission != RF_ADMISSION_CLOSING) {
        return RF_VALIDATE_ADMISSION;
    }
    return RF_VALIDATE_OK;
}

/**
 * Human-readable form of RFValidateResult, for logs on both sides.
 */
static inline const char* rf_validate_result_string(RFValidateResult result) {
    switch (result) {
        case RF_VALIDATE_OK:               return "ok";
        case RF_VALIDATE_NULL:             return "null header";
        case RF_VALIDATE_PROTOCOL_VERSION: return "protocol version mismatch";
        case RF_VALIDATE_HEADER_SIZE:      return "header size mismatch";
        case RF_VALIDATE_SAMPLE_RATE:      return "unsupported sample rate";
        case RF_VALIDATE_CHANNELS:         return "invalid channel count";
        case RF_VALIDATE_CAPACITY:         return "invalid ring capacity";
        case RF_VALIDATE_ADMISSION:        return "invalid admission state";
        default:                           return "unknown validation result";
    }
}

// ============================================================================
// ADMISSION GATEWAY (Batch 2)
//
// Control split — one writer per field, no shared ownership:
//   Host   : admission_state transitions (CLOSED -> OPEN -> CLOSING -> CLOSED)
//            and admission_epoch. It is the only writer of both.
//   Driver : producer_owner_token only, through rf_producer_claim() /
//            rf_producer_release(). It can never open admission itself.
//
// Memory ordering:
//   The Host stores the epoch, then publishes OPEN with a release CAS, so a
//   driver that acquire-loads OPEN also sees a fully initialized header. The
//   claim CAS is acq_rel: everything the owner writes afterwards is ordered
//   after the claim, and the next release is ordered after its last write.
//
// What this does NOT prove: CLOSING is not a drain. Closing refuses new
// writes; it says nothing about a callback already past the check. Drain ACK
// and mapping retirement belong to the next batch.
// ============================================================================

/**
 * Result of an admission transition or a producer claim.
 */
typedef enum {
    RF_ADMISSION_OK = 0,
    RF_ADMISSION_ERR_NULL = 1,   // NULL header / NULL token
    RF_ADMISSION_ERR_STATE = 2,  // illegal current state or illegal transition
    RF_ADMISSION_ERR_EPOCH = 3,  // epoch is zero (no incarnation identity)
    RF_ADMISSION_ERR_OWNED = 4   // the owner slot belongs to someone else
} RFAdmissionResult;

static inline const char* rf_admission_result_string(RFAdmissionResult result) {
    switch (result) {
        case RF_ADMISSION_OK:          return "ok";
        case RF_ADMISSION_ERR_NULL:    return "null argument";
        case RF_ADMISSION_ERR_STATE:   return "illegal admission state transition";
        case RF_ADMISSION_ERR_EPOCH:   return "zero admission epoch";
        case RF_ADMISSION_ERR_OWNED:   return "mapping already owned by another producer";
        default:                       return "unknown admission result";
    }
}

/** Current admission state; any undefined value is returned as-is so callers can fail closed. */
static inline uint32_t rf_admission_state(const RFSharedAudio* mem) {
    if (mem == NULL) { return RF_ADMISSION_CLOSED; }
    return atomic_load_explicit(&mem->admission_state, memory_order_acquire);
}

/** Mapping incarnation token published by the Host. 0 means "never opened". */
static inline uint64_t rf_admission_epoch(const RFSharedAudio* mem) {
    if (mem == NULL) { return 0; }
    return atomic_load_explicit(&mem->admission_epoch, memory_order_acquire);
}

/** The producer owner token, or 0 when no producer has claimed this mapping. */
static inline uint64_t rf_producer_owner_token(const RFSharedAudio* mem) {
    if (mem == NULL) { return 0; }
    return atomic_load_explicit(&mem->producer_owner_token, memory_order_acquire);
}

/** Number of successful claim transitions (diagnostics; never used for admission). */
static inline uint64_t rf_admission_claim_seq(const RFSharedAudio* mem) {
    if (mem == NULL) { return 0; }
    return atomic_load_explicit(&mem->admission_claim_seq, memory_order_acquire);
}

/**
 * Monotonic producer cursor in frames. Read-only: the only writer is
 * rf_ring_write_unchecked, and exposing a setter would break the single-writer
 * contract the whole ring depends on.
 */
static inline uint64_t rf_ring_write_index(const RFSharedAudio* mem) {
    if (mem == NULL) { return 0; }
    return atomic_load_explicit(&mem->write_index, memory_order_acquire);
}

/** Monotonic consumer cursor in frames. Read-only, same reasoning. */
static inline uint64_t rf_ring_read_index(const RFSharedAudio* mem) {
    if (mem == NULL) { return 0; }
    return atomic_load_explicit(&mem->read_index, memory_order_acquire);
}

/**
 * Host only: publish the mapping incarnation and move CLOSED -> OPEN.
 *
 * The epoch is written first, while the mapping is still CLOSED, so no
 * producer can be running against a half-updated incarnation. Re-opening an
 * already OPEN mapping is refused: an epoch must never change under a live
 * owner.
 *
 * The state is therefore checked BEFORE the epoch is stored. Storing first
 * would let a second opener clobber the incarnation identity of a mapping a
 * producer has already claimed under — the open would still be refused, but
 * the damage (a permanently unbindable owner token) would already be done.
 */
static inline RFAdmissionResult rf_admission_open(RFSharedAudio* mem, uint64_t epoch) {
    if (mem == NULL) { return RF_ADMISSION_ERR_NULL; }
    if (epoch == 0) { return RF_ADMISSION_ERR_EPOCH; }
    if (atomic_load_explicit(&mem->admission_state, memory_order_acquire) != RF_ADMISSION_CLOSED) {
        return RF_ADMISSION_ERR_STATE;
    }
    atomic_store_explicit(&mem->admission_epoch, epoch, memory_order_release);
    uint32_t expected = RF_ADMISSION_CLOSED;
    if (!atomic_compare_exchange_strong_explicit(
            &mem->admission_state, &expected, RF_ADMISSION_OPEN,
            memory_order_acq_rel, memory_order_acquire)) {
        return RF_ADMISSION_ERR_STATE;
    }
    return RF_ADMISSION_OK;
}

/**
 * Host only: revoke admission (OPEN -> CLOSING). Idempotent for CLOSING and
 * already-CLOSED mappings. Does NOT stop a callback that is already running.
 */
static inline RFAdmissionResult rf_admission_begin_close(RFSharedAudio* mem) {
    if (mem == NULL) { return RF_ADMISSION_ERR_NULL; }
    uint32_t expected = RF_ADMISSION_OPEN;
    if (atomic_compare_exchange_strong_explicit(
            &mem->admission_state, &expected, RF_ADMISSION_CLOSING,
            memory_order_acq_rel, memory_order_acquire)) {
        return RF_ADMISSION_OK;
    }
    if (expected == RF_ADMISSION_CLOSING || expected == RF_ADMISSION_CLOSED) {
        return RF_ADMISSION_OK;
    }
    return RF_ADMISSION_ERR_STATE;
}

/**
 * Host only: finish the close (CLOSING -> CLOSED). Refuses to skip CLOSING so
 * every teardown passes through the state the next batch will attach a drain
 * proof to. CLOSED is idempotent for the same reason.
 */
static inline RFAdmissionResult rf_admission_finalize_close(RFSharedAudio* mem) {
    if (mem == NULL) { return RF_ADMISSION_ERR_NULL; }
    uint32_t expected = RF_ADMISSION_CLOSING;
    if (atomic_compare_exchange_strong_explicit(
            &mem->admission_state, &expected, RF_ADMISSION_CLOSED,
            memory_order_acq_rel, memory_order_acquire)) {
        return RF_ADMISSION_OK;
    }
    if (expected == RF_ADMISSION_CLOSED) {
        return RF_ADMISSION_OK;
    }
    return RF_ADMISSION_ERR_STATE;
}

/**
 * Driver only, non-realtime (OnStartIO): claim the single producer slot.
 *
 * Succeeds only when admission is OPEN and the owner slot is either empty
 * (first claim) or already holds this exact token (the same handler restarting
 * IO — idempotent, never a second producer). A different token is refused:
 * another handler, another device instance or another process must not write
 * into this mapping.
 *
 * The post-CAS re-read covers the race where the Host closes admission while
 * the claim is in flight; the claim is rolled back rather than leaving an
 * owner on a closed mapping.
 */
static inline bool rf_producer_claim(RFSharedAudio* mem, uint64_t token) {
    if (mem == NULL || token == 0) { return false; }
    if (atomic_load_explicit(&mem->admission_state, memory_order_acquire) != RF_ADMISSION_OPEN) {
        return false;
    }
    uint64_t expected = 0;
    if (atomic_compare_exchange_strong_explicit(
            &mem->producer_owner_token, &expected, token,
            memory_order_acq_rel, memory_order_acquire)) {
        if (atomic_load_explicit(&mem->admission_state, memory_order_acquire) != RF_ADMISSION_OPEN) {
            uint64_t owned = token;
            atomic_compare_exchange_strong_explicit(
                &mem->producer_owner_token, &owned, (uint64_t)0,
                memory_order_acq_rel, memory_order_acquire);
            return false;
        }
        atomic_fetch_add_explicit(&mem->admission_claim_seq, 1, memory_order_release);
        return true;
    }
    // expected now holds the current owner. Same token = this producer already
    // owns the slot (Stop -> Start on the same handler): idempotent success.
    return expected == token;
}

/**
 * Driver only, non-realtime: give the owner slot back after the handler can
 * prove it will not write again (see Plugin.cpp OnStopIO). Only the current
 * owner may release; releasing a token you do not hold is a no-op.
 */
static inline bool rf_producer_release(RFSharedAudio* mem, uint64_t token) {
    if (mem == NULL || token == 0) { return false; }
    uint64_t expected = token;
    return atomic_compare_exchange_strong_explicit(
        &mem->producer_owner_token, &expected, (uint64_t)0,
        memory_order_acq_rel, memory_order_acquire);
}

/**
 * Realtime-safe admission check (three acquire loads, no CAS, no allocation).
 *
 * This is what rf_ring_write consults on every callback. It answers a single
 * question: may THIS token write into THIS incarnation right now? It is
 * deliberately read-only so a producer cannot mutate the gateway from the
 * render thread.
 *
 * The epoch comparison is what binds the owner identity to the mapping
 * incarnation: the token alone is stable across mappings for one handler, so
 * without it a token would remain "valid" on a mapping it was never claimed
 * for. The producer records the epoch it claimed under and passes it here.
 */
static inline bool rf_producer_may_write(
    const RFSharedAudio* mem, uint64_t token, uint64_t epoch)
{
    if (mem == NULL || token == 0 || epoch == 0) { return false; }
    if (atomic_load_explicit(&mem->admission_state, memory_order_acquire) != RF_ADMISSION_OPEN) {
        return false;
    }
    if (atomic_load_explicit(&mem->admission_epoch, memory_order_acquire) != epoch) {
        return false;
    }
    return atomic_load_explicit(&mem->producer_owner_token, memory_order_acquire) == token;
}

/**
 * Get bytes per sample for a format
 */
static inline uint32_t rf_bytes_per_sample(RFAudioFormat format) {
    switch (format) {
        case RF_FORMAT_FLOAT32: return 4;
        case RF_FORMAT_FLOAT64: return 8;
        case RF_FORMAT_INT16:   return 2;
        case RF_FORMAT_INT24:   return 3;
        case RF_FORMAT_INT32:   return 4;
        default:                return 4;
    }
}

/**
 * Check if both sides are connected and healthy
 */
static inline bool rf_is_connection_healthy(const RFSharedAudio* mem) {
    // "Connected" only means anything on a header both sides agree on. Without
    // this check a stale, foreign or uninitialised mapping can report healthy
    // because four unrelated words happen to be non-zero. rf_validate_header()
    // also covers mem == NULL.
    if (rf_validate_header(mem) != RF_VALIDATE_OK) {
        return false;
    }

    uint32_t driver_conn = atomic_load(&mem->driver_connected);
    uint32_t host_conn = atomic_load(&mem->host_connected);

    if (driver_conn == 0 || host_conn == 0) {
        return false;
    }

    // Check heartbeats (should be incrementing)
    uint64_t driver_hb = atomic_load(&mem->driver_heartbeat);
    uint64_t host_hb = atomic_load(&mem->host_heartbeat);

    // Both should be non-zero if connection is established
    return (driver_hb > 0 && host_hb > 0);
}

/**
 * Ring write implementation WITHOUT the admission gate.
 *
 * Only two callers may use it, both of which own the mapping exclusively:
 *   - rf_ring_write()          after it verified OPEN + owner token (the
 *                              driver's only producer path);
 *   - rf_ring_prefill_before_publish() during host-side initialization.
 *
 * Do not call it from new code: the gate is what enforces the single
 * producer invariant, and this function cannot.
 *
 * Single-writer contract (Batch 1): this function is the ONLY place
 * write_index advances, and it NEVER touches read_index — the old Drop-Old
 * path that advanced the consumer's index from the producer side is gone.
 *
 * Overflow: frames that do not fit are DROPPED (the new ones), already
 * buffered data is never overwritten, the consumer is never blocked.
 *
 * SPSC ordering:
 *   load read_index (acquire)        -> reuse only space the consumer freed
 *   write payload (plain stores)     -> happens-before the W publish below
 *   store write_index (release)      -> publishes the new payload
 *
 * Returns the number of frames actually written. *out_dropped (may be NULL)
 * receives the number of dropped input frames. A return of 0 with dropped == 0
 * means the call was rejected (NULL args, num_frames == 0, invalid capacity):
 * fail-closed, nothing was accepted. Frames are written whole: both channels
 * of a frame land together or neither does.
 */
static inline uint32_t rf_ring_write_unchecked(
    RFSharedAudio* mem,
    const float* input_frames,  // Always float32 input
    uint32_t num_frames,
    uint32_t* out_dropped)
{
    if (mem == NULL || input_frames == NULL || num_frames == 0) {
        if (out_dropped) *out_dropped = 0;
        return 0;
    }

    // Defensive capacity check: rf_validate_header enforces this too, but the
    // ring helpers must never rely on the caller having validated (the mask
    // below turns a non-power-of-two capacity into out-of-bounds slots).
    const uint32_t capacity = mem->ring_capacity_frames;
    if (capacity == 0 || (capacity & (capacity - 1u)) != 0u) {
        if (out_dropped) *out_dropped = 0;
        return 0;
    }
    const uint32_t slot_mask = capacity - 1u;

    const uint64_t write_idx = atomic_load_explicit(&mem->write_index, memory_order_relaxed);
    const uint64_t read_idx = atomic_load_explicit(&mem->read_index, memory_order_acquire);
    const uint64_t used = write_idx - read_idx;

    // Corrupted state (indices inconsistent beyond wraparound arithmetic):
    // treat as no room instead of deriving a bogus payload offset.
    if (used > capacity) {
        if (out_dropped) *out_dropped = num_frames;
        atomic_fetch_add(&mem->overrun_count, 1);
        return 0;
    }

    const uint64_t free_frames = capacity - used;
    const uint32_t writable = (num_frames <= free_frames) ? num_frames : (uint32_t)free_frames;
    const uint32_t dropped = num_frames - writable;

    // Write payload with format conversion (plain stores; published by the
    // release store to write_index below)
    for (uint32_t frame = 0; frame < writable; frame++) {
        uint32_t ring_pos = (uint32_t)((write_idx + frame) & slot_mask);
        uint8_t* dest = &mem->audio_data[ring_pos * mem->bytes_per_frame];

        for (uint32_t ch = 0; ch < mem->channels; ch++) {
            float sample = input_frames[frame * mem->channels + ch];

            switch (mem->format) {
                case RF_FORMAT_FLOAT32: {
                    float* ptr = (float*)dest;
                    ptr[ch] = sample;
                    break;
                }
                case RF_FORMAT_FLOAT64: {
                    double* ptr = (double*)dest;
                    ptr[ch] = (double)sample;
                    break;
                }
                case RF_FORMAT_INT16: {
                    int16_t* ptr = (int16_t*)dest;
                    // Clamp to [-1.0, 1.0] and scale to int16 range
                    if (sample > 1.0f) sample = 1.0f;
                    if (sample < -1.0f) sample = -1.0f;
                    ptr[ch] = (int16_t)(sample * 32767.0f);
                    break;
                }
                case RF_FORMAT_INT32: {
                    int32_t* ptr = (int32_t*)dest;
                    if (sample > 1.0f) sample = 1.0f;
                    if (sample < -1.0f) sample = -1.0f;
                    ptr[ch] = (int32_t)(sample * 2147483647.0f);
                    break;
                }
                case RF_FORMAT_INT24: {
                    // 24-bit packed (3 bytes)
                    if (sample > 1.0f) sample = 1.0f;
                    if (sample < -1.0f) sample = -1.0f;
                    int32_t val24 = (int32_t)(sample * 8388607.0f);
                    uint8_t* ptr = dest + (ch * 3);
                    ptr[0] = (val24 >> 0) & 0xFF;
                    ptr[1] = (val24 >> 8) & 0xFF;
                    ptr[2] = (val24 >> 16) & 0xFF;
                    break;
                }
            }
        }
    }

    // Publish W only after the payload above has been written (release).
    atomic_store_explicit(&mem->write_index, write_idx + writable, memory_order_release);
    atomic_fetch_add(&mem->total_frames_written, writable);
    if (dropped > 0) {
        atomic_fetch_add(&mem->overrun_count, 1);
    }
    if (out_dropped) *out_dropped = dropped;

    return writable;
}

/**
 * Host-side pre-publish prefill (initialization only, never a producer path).
 *
 * Refuses to run unless the mapping is still CLOSED with no owner: that is the
 * window between rf_shared_audio_init() and rf_admission_open(), while the
 * staging inode is private and no reader or writer can observe it. Once the
 * mapping is published OPEN this returns 0 and writes nothing, which is what
 * makes "Stop -> Start never re-fills" true by construction rather than by
 * convention.
 */
static inline uint32_t rf_ring_prefill_before_publish(
    RFSharedAudio* mem,
    const float* input_frames,
    uint32_t num_frames,
    uint32_t* out_dropped)
{
    if (mem == NULL || input_frames == NULL || num_frames == 0) {
        if (out_dropped) *out_dropped = 0;
        return 0;
    }
    if (atomic_load_explicit(&mem->admission_state, memory_order_acquire) != RF_ADMISSION_CLOSED ||
        atomic_load_explicit(&mem->producer_owner_token, memory_order_acquire) != 0) {
        if (out_dropped) *out_dropped = 0;
        return 0;
    }
    return rf_ring_write_unchecked(mem, input_frames, num_frames, out_dropped);
}

/**
 * Write frames to ring buffer (Producer side) — THE producer entry point.
 *
 * Admission gate (Batch 2): the call is refused unless
 *   - admission_state == OPEN,
 *   - admission_epoch == epoch (this is the incarnation the caller claimed),
 *     and
 *   - producer_owner_token == owner_token (this caller is the one owner).
 * That check is three acquire loads (lock-free, no CAS, allocation-free), so
 * it is safe inside the audio callback. A refused call writes NOTHING: W, R,
 * payload and statistics are untouched, and *out_dropped reports num_frames so
 * the caller can tell "admission refused" from "invalid argument" (0/0).
 *
 * Overflow policy, SPSC ordering and the return value are documented on
 * rf_ring_write_unchecked(), which this function gates and delegates to.
 */
static inline uint32_t rf_ring_write(
    RFSharedAudio* mem,
    const float* input_frames,
    uint32_t num_frames,
    uint64_t owner_token,
    uint64_t epoch,
    uint32_t* out_dropped)
{
    if (mem == NULL || input_frames == NULL || num_frames == 0) {
        if (out_dropped) *out_dropped = 0;
        return 0;
    }
    if (!rf_producer_may_write(mem, owner_token, epoch)) {
        if (out_dropped) *out_dropped = num_frames;
        return 0;
    }
    return rf_ring_write_unchecked(mem, input_frames, num_frames, out_dropped);
}

/**
 * Read frames from ring buffer (Consumer side).
 *
 * Single-reader contract (Batch 1): this function is the ONLY place
 * read_index advances, and it never touches write_index.
 *
 * SPSC ordering:
 *   load write_index (acquire) -> the payload below W becomes visible
 *   read payload (plain loads)
 *   store read_index (release) -> frees those slots to the producer
 *
 * Underrun: the tail of the legal output area [consumed, num_frames) is
 * zero-filled; zero-filled frames are NOT counted as consumed. Returns the
 * number of frames actually consumed; *out_zero_filled (may be NULL) receives
 * the zero-filled frame count. Returns 0 for NULL args / num_frames == 0
 * without touching the ring; an invalid capacity also fails closed (all
 * silence, nothing consumed).
 */
static inline uint32_t rf_ring_read(
    RFSharedAudio* mem,
    float* output_frames,  // Always float32 output
    uint32_t num_frames,
    uint32_t* out_zero_filled)
{
    if (mem == NULL || output_frames == NULL || num_frames == 0) {
        if (out_zero_filled) *out_zero_filled = 0;
        return 0;
    }

    // Defensive capacity check, same rationale as rf_ring_write.
    const uint32_t capacity = mem->ring_capacity_frames;
    if (capacity == 0 || (capacity & (capacity - 1u)) != 0u) {
        for (uint32_t i = 0; i < num_frames * mem->channels; i++) {
            output_frames[i] = 0.0f;
        }
        if (out_zero_filled) *out_zero_filled = num_frames;
        return 0;
    }
    const uint32_t slot_mask = capacity - 1u;

    const uint64_t write_idx = atomic_load_explicit(&mem->write_index, memory_order_acquire);
    const uint64_t read_idx = atomic_load_explicit(&mem->read_index, memory_order_relaxed);
    const uint64_t available = write_idx - read_idx;

    // Corrupted state: never read garbage slots; emit the legal silence and
    // account it as underrun without advancing R into unmapped territory.
    if (available > capacity) {
        for (uint32_t i = 0; i < num_frames * mem->channels; i++) {
            output_frames[i] = 0.0f;
        }
        atomic_fetch_add(&mem->underrun_count, 1);
        atomic_fetch_add(&mem->underrun_frames, num_frames);
        if (out_zero_filled) *out_zero_filled = num_frames;
        return 0;
    }

    const uint32_t frames_to_read =
        (available >= (uint64_t)num_frames) ? num_frames : (uint32_t)available;

    // Read payload with format conversion (plain loads; made visible by the
    // producer's release store to write_index, acquired above)
    for (uint32_t frame = 0; frame < frames_to_read; frame++) {
        uint32_t ring_pos = (uint32_t)((read_idx + frame) & slot_mask);
        const uint8_t* src = &mem->audio_data[ring_pos * mem->bytes_per_frame];

        for (uint32_t ch = 0; ch < mem->channels; ch++) {
            float sample = 0.0f;

            switch (mem->format) {
                case RF_FORMAT_FLOAT32: {
                    const float* ptr = (const float*)src;
                    sample = ptr[ch];
                    break;
                }
                case RF_FORMAT_FLOAT64: {
                    const double* ptr = (const double*)src;
                    sample = (float)ptr[ch];
                    break;
                }
                case RF_FORMAT_INT16: {
                    const int16_t* ptr = (const int16_t*)src;
                    sample = (float)ptr[ch] / 32768.0f;
                    break;
                }
                case RF_FORMAT_INT32: {
                    const int32_t* ptr = (const int32_t*)src;
                    sample = (float)ptr[ch] / 2147483648.0f;
                    break;
                }
                case RF_FORMAT_INT24: {
                    const uint8_t* ptr = src + (ch * 3);
                    int32_t val24 = (int32_t)((ptr[0] << 0) | (ptr[1] << 8) | (ptr[2] << 16));
                    // Sign extend from 24 to 32 bits
                    if (val24 & 0x800000) {
                        val24 |= 0xFF000000;
                    }
                    sample = (float)val24 / 8388608.0f;
                    break;
                }
            }

            output_frames[frame * mem->channels + ch] = sample;
        }
    }

    // Zero-fill the remaining legal output area; these frames are NOT
    // consumed and do not advance R.
    const uint32_t zero_filled = num_frames - frames_to_read;
    if (zero_filled > 0) {
        atomic_fetch_add(&mem->underrun_count, 1);
        atomic_fetch_add(&mem->underrun_frames, zero_filled);
        for (uint32_t frame = frames_to_read; frame < num_frames; frame++) {
            for (uint32_t ch = 0; ch < mem->channels; ch++) {
                output_frames[frame * mem->channels + ch] = 0.0f;
            }
        }
    }

    // Publish R only after the payload above has been read (release).
    atomic_store_explicit(&mem->read_index, read_idx + frames_to_read, memory_order_release);
    atomic_fetch_add(&mem->total_frames_read, frames_to_read);

    if (out_zero_filled) *out_zero_filled = zero_filled;
    return frames_to_read;
}

/**
 * Update heartbeat (call every ~1 second)
 */
static inline void rf_update_driver_heartbeat(RFSharedAudio* mem) {
    atomic_fetch_add(&mem->driver_heartbeat, 1);
    atomic_store(&mem->driver_connected, 1);
}

static inline void rf_update_host_heartbeat(RFSharedAudio* mem) {
    atomic_fetch_add(&mem->host_heartbeat, 1);
    atomic_store(&mem->host_connected, 1);
}

// ===== CONNECTION STATE ACCESSORS =====
// Read-only views of the connection fields. They exist so the Host (Swift) can
// observe driver attachment and heartbeat liveness without reaching into
// `_Atomic` members, which the Swift importer cannot model. Only readers live
// here: the write side stays in rf_update_* so the invariants that keep
// `driver_connected` truthful (set on validate, cleared on disconnect) remain in
// one place.

/**
 * 1 once the driver has validated our header (it sets this in ValidateConnection,
 * which only runs from its IO callback) and 0 after it disconnects.
 */
static inline uint32_t rf_get_driver_connected(const RFSharedAudio* mem) {
    if (mem == NULL) { return 0; }
    return atomic_load_explicit(&mem->driver_connected, memory_order_acquire);
}

/**
 * Incremented by the driver's write callback, i.e. a value that only advances
 * while audio is actually being produced.
 */
static inline uint64_t rf_get_driver_heartbeat(const RFSharedAudio* mem) {
    if (mem == NULL) { return 0; }
    return atomic_load_explicit(&mem->driver_heartbeat, memory_order_acquire);
}

/**
 * Incremented by the Host's heartbeat timer, once per second.
 */
static inline uint64_t rf_get_host_heartbeat(const RFSharedAudio* mem) {
    if (mem == NULL) { return 0; }
    return atomic_load_explicit(&mem->host_heartbeat, memory_order_acquire);
}

// ===== PROCESS COORDINATION =====
// The single-instance lock path is a contract between the Host (which holds the
// lock) and the App (which asks "is a Host already running?"). Both sides derive
// it from these two pieces so the paths cannot drift apart into two different
// files, which would make the App's question unanswerable rather than wrong.
//
// The lock is an exclusive flock on an open descriptor, not the existence of the
// file: a Host killed by SIGKILL leaves the file behind and the lock released.
// The trailing ".lock" also keeps the file clear of the App's /tmp/soundbridge-*
// cleanup sweep.
#define RF_INSTANCE_LOCK_PATH_PREFIX "/tmp/soundbridge-host-"
#define RF_INSTANCE_LOCK_PATH_SUFFIX ".lock"

// ===== VOLUME CONTROL ACCESSORS =====
// Driver (writer) side: use memory_order_release to ensure all prior writes
// are visible to the host before the volume/mute value is published.
// Host (reader) side: use memory_order_acquire to ensure the volume/mute
// value is read before any dependent audio processing.
// This guarantees correct cross-process visibility on ARM/Apple Silicon.

/**
 * Read volume_scalar with acquire semantics (Host/reader side)
 */
static inline float rf_load_volume_scalar(RFSharedAudio* mem) {
    return atomic_load_explicit(&mem->volume_scalar, memory_order_acquire);
}

/**
 * Read mute_state with acquire semantics (Host/reader side)
 */
static inline int32_t rf_load_mute_state(RFSharedAudio* mem) {
    return atomic_load_explicit(&mem->mute_state, memory_order_acquire);
}

/**
 * Write volume_scalar with release semantics (Driver/writer side)
 *
 * NOTE: this is the *raw transport* write used by the driver's HAL control
 * path. It does NOT commit a state revision. Use rf_publish_volume_state()
 * when you mean "this is now the authoritative state".
 */
static inline void rf_store_volume_scalar(RFSharedAudio* mem, float value) {
    atomic_store_explicit(&mem->volume_scalar, value, memory_order_release);
}

/**
 * Write mute_state with release semantics (Driver/writer side)
 *
 * See the note on rf_store_volume_scalar().
 */
static inline void rf_store_mute_state(RFSharedAudio* mem, int32_t value) {
    atomic_store_explicit(&mem->mute_state, value, memory_order_release);
}

// ===== VOLUME STATE MODEL ACCESSORS (Phase 2.1) =====

/**
 * Clamp / sanitise a volume scalar coming from CoreAudio, persistence or a
 * shared-memory read.
 *
 * Rule, identical to `VolumeTaper.sanitize` on the Host side:
 *   - finite values in [0, 1] pass through unchanged,
 *   - finite values outside [0, 1] are clamped to the nearest bound,
 *   - non-finite values (NaN, ±Inf) are corruption rather than a user choice,
 *     so they collapse to the caller's fallback instead of clamping. Mapping
 *     +Inf to 1.0 would turn a corrupt read into full-scale output.
 *   - a non-finite fallback itself collapses to 0.0, so NaN cannot leak
 *     through the fallback path.
 *
 * `VolumeTaperTests` / `SharedMemoryProtocolTests` assert the two
 * implementations agree on NaN, ±Inf and out-of-range inputs.
 */
static inline float rf_sanitize_volume_scalar(float value, float fallback) {
    const float safe_fallback = isfinite(fallback)
        ? (fallback < 0.0f ? 0.0f : (fallback > 1.0f ? 1.0f : fallback))
        : 0.0f;

    if (!isfinite(value)) {
        return safe_fallback;
    }
    if (value < 0.0f) return 0.0f;
    if (value > 1.0f) return 1.0f;
    return value;
}

/**
 * Query whether the volume state block holds a committed state.
 * Acquire so that a reader who sees 1 also sees the published values.
 */
static inline bool rf_is_volume_state_initialized(const RFSharedAudio* mem) {
    if (mem == NULL) return false;
    return atomic_load_explicit(
        (_Atomic uint32_t*)&mem->state_initialized, memory_order_acquire) != 0u;
}

/**
 * Read the committed volume state.
 * Returns false if the block has never been committed; in that case `out` is
 * left untouched and the caller must fall back to its own defaults.
 *
 * The four loads are bracketed by two `state_revision` reads. If a commit
 * landed while they were in flight the values may come from two generations —
 * a scalar from before the commit and a mode from after it — so the pass is
 * retried. Bounded at RF_VOLUME_READ_ATTEMPTS because the Host publishes at UI
 * rate, not continuously; after that the last read is returned rather than
 * "no state", since reporting an unavailable state would reset the volume.
 *
 * Non-RT only: this loop is for the Host, the App's diagnostics and the
 * driver's IO-start handshake, never for a render callback.
 */
#define RF_VOLUME_READ_ATTEMPTS 4

static inline bool rf_read_volume_state(const RFSharedAudio* mem,
                                        RFVolumeStateSnapshot* out) {
    if (mem == NULL || out == NULL) return false;

    RFVolumeStateSnapshot snapshot = {0.0f, 0, 0u, 0u};

    for (int attempt = 0; attempt < RF_VOLUME_READ_ATTEMPTS; ++attempt) {
        if (!rf_is_volume_state_initialized(mem)) return false;

        const uint64_t before = atomic_load_explicit(
            (_Atomic uint64_t*)&mem->state_revision, memory_order_acquire);

        snapshot.scalar = atomic_load_explicit(
            (_Atomic float*)&mem->volume_scalar, memory_order_acquire);
        snapshot.muted = atomic_load_explicit(
            (_Atomic int32_t*)&mem->mute_state, memory_order_acquire);
        snapshot.mode = atomic_load_explicit(
            (_Atomic uint32_t*)&mem->volume_mode, memory_order_acquire);

        const uint64_t after = atomic_load_explicit(
            (_Atomic uint64_t*)&mem->state_revision, memory_order_acquire);

        if (before == after) {
            snapshot.revision = after;
            *out = snapshot;
            return true;
        }
    }

    // Contended on every attempt: a tearing writer. Return the last observed
    // values with the revision they were read against, and leave the caller to
    // decide; do not claim the state is missing.
    snapshot.revision = atomic_load_explicit(
        (_Atomic uint64_t*)&mem->state_revision, memory_order_acquire);
    *out = snapshot;
    return true;
}

/**
 * Commit a volume state.
 *
 * Ordering: values first, then revision, then the initialized latch (all
 * release). A reader that sees `state_initialized == 1` is therefore
 * guaranteed to see the values that accompanied the commit.
 *
 * This is the ONLY function allowed to raise `state_revision`, and it is
 * called by the Host (authoritative writer) and by the driver exactly once
 * for the first-time bootstrap.
 */
static inline void rf_publish_volume_state(RFSharedAudio* mem,
                                           float scalar,
                                           bool muted,
                                           uint32_t mode) {
    const float safe_scalar = rf_sanitize_volume_scalar(scalar, 0.35f);

    atomic_store_explicit(&mem->volume_scalar, safe_scalar, memory_order_release);
    atomic_store_explicit(&mem->mute_state, muted ? 1 : 0, memory_order_release);
    atomic_store_explicit(&mem->volume_mode, mode, memory_order_release);
    atomic_fetch_add_explicit(&mem->state_revision, 1, memory_order_release);
    atomic_store_explicit(&mem->state_initialized, 1u, memory_order_release);
}

/**
 * Read the current revision (0 if never committed).
 */
static inline uint64_t rf_get_state_revision(const RFSharedAudio* mem) {
    return atomic_load_explicit(
        (_Atomic uint64_t*)&mem->state_revision, memory_order_acquire);
}

/**
 * Read the current volume mode without requiring a committed state.
 */
static inline uint32_t rf_get_volume_mode(const RFSharedAudio* mem) {
    return atomic_load_explicit(
        (_Atomic uint32_t*)&mem->volume_mode, memory_order_acquire);
}

// ===== DRIVER IO-START VOLUME HANDSHAKE (Phase 2.1-C) =====

/**
 * Outcome of rf_sync_driver_volume_state().
 */
typedef enum {
    RF_VOLUME_SYNC_ADOPTED = 0,  // committed state existed; the block wins
    RF_VOLUME_SYNC_SEEDED = 1,   // block was uncommitted; seeded from the controls
    RF_VOLUME_SYNC_REJECTED = 2  // invalid header; block left untouched
} RFVolumeSyncOutcome;

/**
 * Decide which volume state the driver's controls must adopt when IO starts.
 *
 * This lives in the shared header rather than in Plugin.cpp so the Host test
 * suite executes the same branch the driver does: "IO start must never reset a
 * committed volume to a HAL control default" is then covered by tests instead
 * of by a second copy of the logic written inside a test.
 *
 *   committed state (state_initialized == 1)
 *       -> ADOPTED. `out_state` receives the committed snapshot. A rebuilt
 *          VolumeControl sits at MaxRawVolume (scalar 1.0), so the caller must
 *          push `out_state` INTO its controls.
 *   uncommitted state (state_initialized == 0)
 *       -> SEEDED. The block is committed from the controls' current values
 *          (whatever the Host applied before IO started), and `out_state`
 *          describes the state that was just committed.
 *   invalid header
 *       -> REJECTED. Nothing is read and nothing is written; `out_state` is
 *          left untouched. Callers must not treat this as a usable volume.
 */
static inline RFVolumeSyncOutcome rf_sync_driver_volume_state(
    RFSharedAudio* mem,
    float control_scalar,
    bool control_muted,
    RFVolumeStateSnapshot* out_state)
{
    if (rf_validate_header(mem) != RF_VALIDATE_OK) {
        return RF_VOLUME_SYNC_REJECTED;
    }

    RFVolumeStateSnapshot snapshot;
    if (rf_read_volume_state(mem, &snapshot)) {
        if (out_state != NULL) *out_state = snapshot;
        return RF_VOLUME_SYNC_ADOPTED;
    }

    const float seeded_scalar = rf_sanitize_volume_scalar(control_scalar, 0.35f);
    rf_publish_volume_state(mem, seeded_scalar, control_muted, RF_VOLUME_MODE_SOFTWARE);
    if (out_state != NULL) {
        out_state->scalar   = seeded_scalar;
        out_state->muted    = control_muted ? 1 : 0;
        out_state->mode     = RF_VOLUME_MODE_SOFTWARE;
        out_state->revision = rf_get_state_revision(mem);
    }
    return RF_VOLUME_SYNC_SEEDED;
}

// ===== EQ SNAPSHOT ACCESSORS =====

/**
 * Write EQ snapshot with SeqLock (App/writer side).
 * Odd sequence = write in progress; even = idle.
 */
static inline void rf_store_eq_snapshot(RFSharedAudio* mem, const RFEQSnapshot* snapshot) {
    uint32_t seq = atomic_load_explicit(&mem->eq_sequence, memory_order_relaxed);
    atomic_store_explicit(&mem->eq_sequence, seq + 1, memory_order_release);
    memcpy((void*)&mem->eq_snapshot, snapshot, sizeof(RFEQSnapshot));
    atomic_store_explicit(&mem->eq_sequence, seq + 2, memory_order_release);
}

/**
 * Read EQ snapshot with SeqLock (Host/reader side).
 * Retries if a write was in progress. Returns false if stuck (should not happen).
 */
static inline bool rf_load_eq_snapshot_safe(const RFSharedAudio* mem, RFEQSnapshot* out) {
    for (int attempt = 0; attempt < 4; attempt++) {
        uint32_t seq1 = atomic_load_explicit(
            (_Atomic uint32_t*)&mem->eq_sequence, memory_order_acquire);
        if (seq1 & 1) continue;  // Writer active, retry
        memcpy(out, (const void*)&mem->eq_snapshot, sizeof(RFEQSnapshot));
        uint32_t seq2 = atomic_load_explicit(
            (_Atomic uint32_t*)&mem->eq_sequence, memory_order_acquire);
        if (seq1 == seq2) return true;  // Consistent read
    }
    return false;  // Gave up — caller should use previous snapshot
}

/**
 * Legacy reader: discards the result of rf_load_eq_snapshot_safe().
 *
 * On failure `out` is left untouched, which for a zero-initialised snapshot
 * means the caller would apply 0 dB on every band. New code must call
 * rf_load_eq_snapshot_safe() and skip the update when it returns false.
 */
static inline void rf_load_eq_snapshot(const RFSharedAudio* mem, RFEQSnapshot* out) {
    rf_load_eq_snapshot_safe(mem, out);
}

/**
 * Check if format change is needed
 * Returns true if current format doesn't match requested format
 */
static inline bool rf_needs_format_change(
    const RFSharedAudio* mem,
    uint32_t new_sample_rate,
    uint32_t new_channels,
    RFAudioFormat new_format)
{
    return (mem->sample_rate != new_sample_rate ||
            mem->channels != new_channels ||
            mem->format != new_format);
}

// ===== TELEMETRY ACCESSORS =====
// Swift cannot access C11 _Atomic fields directly. These helpers
// provide safe read access for telemetry logging from Swift.

static inline uint64_t rf_get_underrun_count(const RFSharedAudio* mem) {
    return atomic_load((_Atomic uint64_t*)&mem->underrun_count);
}

static inline uint64_t rf_get_overrun_count(const RFSharedAudio* mem) {
    return atomic_load((_Atomic uint64_t*)&mem->overrun_count);
}

static inline uint32_t rf_get_underrun_frames(const RFSharedAudio* mem) {
    return atomic_load((_Atomic uint32_t*)&mem->underrun_frames);
}

#ifdef __cplusplus
}
#endif

#endif // RF_SHARED_AUDIO_H
