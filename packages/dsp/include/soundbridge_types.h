/**
 * @file soundbridge_types.h
 * @brief Type definitions for SoundBridge DSP library
 *
 * This file contains POD (Plain Old Data) types that are safe to use across
 * C, C++, Objective-C, and Swift boundaries. No templates, no C++ classes,
 * no virtual functions.
 */

#ifndef SOUNDBRIDGE_TYPES_H
#define SOUNDBRIDGE_TYPES_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Maximum number of EQ bands supported
 */
#define SOUNDBRIDGE_MAX_BANDS 10

/**
 * @brief Filter types for EQ bands
 */
typedef enum {
    SOUNDBRIDGE_FILTER_PEAK = 0,      // Parametric peak/dip (bell curve)
    SOUNDBRIDGE_FILTER_LOW_SHELF,     // Low shelf (boost/cut bass)
    SOUNDBRIDGE_FILTER_HIGH_SHELF,    // High shelf (boost/cut treble)
    SOUNDBRIDGE_FILTER_LOW_PASS,      // Low-pass filter
    SOUNDBRIDGE_FILTER_HIGH_PASS,     // High-pass filter
    SOUNDBRIDGE_FILTER_NOTCH,         // Notch filter (narrow rejection)
    SOUNDBRIDGE_FILTER_BAND_PASS      // Band-pass filter
} soundbridge_filter_type_t;

/**
 * @brief Configuration for a single EQ band
 */
typedef struct {
    float frequency_hz;             // Center frequency in Hz (20 - 20000)
    float gain_db;                  // Gain in dB (-12.0 to +12.0)
    float q_factor;                 // Q factor (0.1 to 10.0, default 1.0)
    soundbridge_filter_type_t type;   // Filter type
    bool enabled;                   // Band enabled/bypassed
} soundbridge_band_t;

/**
 * @brief Complete EQ preset configuration
 */
typedef struct {
    soundbridge_band_t bands[SOUNDBRIDGE_MAX_BANDS];  // Array of EQ bands
    uint32_t num_bands;             // Number of active bands (1-10)
    float preamp_db;                // Global preamp gain (-12.0 to +12.0)
    bool limiter_enabled;           // Enable soft limiter after EQ
    float limiter_threshold_db;     // Limiter threshold (-6.0 to 0.0)
    char name[64];                  // Preset name (null-terminated)
} soundbridge_preset_t;

/**
 * @brief Error codes returned by DSP functions
 */
typedef enum {
    SOUNDBRIDGE_OK = 0,               // Success
    SOUNDBRIDGE_ERROR_INVALID_PARAM,  // Invalid parameter value
    SOUNDBRIDGE_ERROR_NULL_POINTER,   // Null pointer passed
    SOUNDBRIDGE_ERROR_OUT_OF_MEMORY,  // Memory allocation failed
    SOUNDBRIDGE_ERROR_INVALID_STATE,  // Operation invalid in current state
    SOUNDBRIDGE_ERROR_UNSUPPORTED     // Feature not supported
} soundbridge_error_t;

/**
 * @brief Lowest level reported by the engine's dBFS fields
 *
 * Silence, denormal residue and anything below this report exactly this value.
 */
#define SOUNDBRIDGE_PEAK_FLOOR_DB (-120.0f)

/**
 * @brief Highest level reported by the engine's dBFS fields
 *
 * This is the dBFS equivalent of FLT_MAX (20*log10(FLT_MAX) = 770.6) rounded up.
 * It exists so the diagnostic can never hand a consumer something it cannot
 * exponentiate, not to hide overrange.
 */
#define SOUNDBRIDGE_PEAK_CEILING_DB (771.0f)

/**
 * @brief DSP engine statistics (for diagnostics)
 *
 * Level contract shared by every *_db field:
 *
 * - The unit is dBFS relative to a full-scale sample of 1.0. 0.0 is full scale.
 * - **Positive values are meaningful.** They mean the signal exceeded full
 *   scale and are reported as such rather than clamped to 0 dBFS: "+12 dB into
 *   the limiter" and "just at the limiter" are different problems, and this
 *   struct is the only place the difference is visible. A consumer that draws a
 *   bar over [-120, 0] must clamp the top end itself; the engine does not lie
 *   about the level to make drawing easier.
 * - Silence reports SOUNDBRIDGE_PEAK_FLOOR_DB, never -infinity.
 * - The value is bounded by SOUNDBRIDGE_PEAK_CEILING_DB above, and is never
 *   NaN or infinite, so it is always safe to use as an exponent.
 *
 * ABI policy - read this before adding a field
 * --------------------------------------------
 * The compatibility this library promises is **source compatibility**: it is
 * shipped as a static archive built from this tree, and every consumer is
 * rebuilt against these same headers at the same time. There is no promise of
 * binary compatibility between an object file compiled against one version of
 * these headers and a library built from another. (That is a statement about
 * the current product contract, not a property of static linking: a static
 * archive is just as capable of being linked against a stale layout.)
 *
 * The rules that follow from it:
 *
 * - **Append only.** Never reorder, remove, resize or retype an existing field.
 *   New fields go at the end, so the offsets a caller already knows stay put.
 *   The two pre-limiter metrics below were added this way: they sit at offsets
 *   32 and 36 of what was a 32-byte struct, and every earlier field kept its
 *   offset.
 * - **Rebuild every consumer, or do not link.** soundbridge_dsp_get_stats()
 *   has no size argument and writes sizeof(soundbridge_stats_t) bytes into the
 *   caller's struct. A caller compiled against an older, smaller struct that is
 *   then linked against a newer library is an out-of-bounds write, and a caller
 *   compiled against a newer struct linked against an older library reads two
 *   fields the library never wrote. Keeping the copies of this header identical
 *   (tools/sync_dsp_headers.sh --check, wired into `make protocol-check`) is the
 *   gate that stops the second half of that pair from arising by accident.
 * - **If binary compatibility is ever required**, add a versioned entry point
 *   that takes the caller's struct size (or a version number) and fills only
 *   what fits, instead of widening an existing function's write range.
 *
 * @note peak_*_db is the peak of the signal the engine *outputs*, i.e. after
 *       the limiter when limiting is enabled. It therefore cannot exceed the
 *       limiter threshold. peak_*_db_pre_limiter is the same measurement taken
 *       before the limiter and is what shows how hard the engine is being
 *       driven.
 */
typedef struct {
    uint64_t frames_processed;      // Total frames processed
    /**
     * Reserved. Always 0; nothing in the engine increments it.
     *
     * The DSP engine cannot observe the IO cycle's deadline, so it cannot
     * detect a buffer underrun on its own. The real count lives in the
     * shared-memory ring telemetry on the Host side
     * (`rf_get_underrun_count` / `rf_get_underrun_frames` in RFSharedAudio.h),
     * which is the only place the information exists. The field is kept, and
     * documented here, so the struct layout stays stable and so a reader is
     * never left believing a permanently-zero counter means "no underruns".
     */
    uint32_t underrun_count;
    float cpu_load_percent;         // Estimated CPU load (0.0 - 100.0)
    bool bypass_active;             // Currently in bypass mode
    uint32_t sample_rate;           // Current sample rate
    float peak_left_db;             // Output peak, left (dBFS; see contract above)
    float peak_right_db;            // Output peak, right (dBFS; see contract above)
    // Appended after the original fields so the layout of everything above is
    // unchanged. Same dBFS contract as peak_*_db.
    float peak_left_db_pre_limiter;  // Peak before the limiter, left channel
    float peak_right_db_pre_limiter; // Peak before the limiter, right channel
} soundbridge_stats_t;

#ifdef __cplusplus
// The append-only policy above, made machine-checked. Appending a field means
// updating the expected size here; changing an offset below means the policy
// was broken.
static_assert(sizeof(soundbridge_stats_t) == 40,
              "soundbridge_stats_t changed size: read the ABI policy above "
              "before touching this assertion");
static_assert(offsetof(soundbridge_stats_t, frames_processed) == 0, "field moved");
static_assert(offsetof(soundbridge_stats_t, underrun_count) == 8, "field moved");
static_assert(offsetof(soundbridge_stats_t, cpu_load_percent) == 12, "field moved");
static_assert(offsetof(soundbridge_stats_t, bypass_active) == 16, "field moved");
static_assert(offsetof(soundbridge_stats_t, sample_rate) == 20, "field moved");
static_assert(offsetof(soundbridge_stats_t, peak_left_db) == 24, "field moved");
static_assert(offsetof(soundbridge_stats_t, peak_right_db) == 28, "field moved");
static_assert(offsetof(soundbridge_stats_t, peak_left_db_pre_limiter) == 32, "field moved");
static_assert(offsetof(soundbridge_stats_t, peak_right_db_pre_limiter) == 36, "field moved");
#endif

#ifdef __cplusplus
}
#endif

#endif // SOUNDBRIDGE_TYPES_H
