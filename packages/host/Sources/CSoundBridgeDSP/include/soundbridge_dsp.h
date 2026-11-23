/**
 * @file soundbridge_dsp.h
 * @brief Public C API for SoundBridge DSP engine
 *
 * This is the main API for the SoundBridge DSP library. It provides a clean,
 * stable C interface that can be called from C++, Objective-C++, and Swift.
 *
 * Thread Safety:
 * - Engine creation/destruction: NOT thread-safe (call from main thread)
 * - Parameter updates: thread-safe, from any thread, including several at once
 * - Process function: one audio thread at a time
 *
 * How configuration reaches the audio thread:
 * - soundbridge_dsp_apply_preset(), soundbridge_dsp_set_sample_rate() and the
 *   soundbridge_dsp_update_*() setters build a complete configuration
 *   (including the biquad coefficients, computed on the calling thread) and
 *   publish it through a bounded mailbox. They never write state the audio
 *   thread is using.
 * - soundbridge_dsp_process_*() adopts the newest published configuration once,
 *   at the top of the block, and uses nothing else for the rest of that block.
 *   A change made mid-block takes effect at the next boundary, and one block can
 *   never mix two configurations.
 * - Several updates published before one block collapse into the newest one;
 *   configurations are absolute snapshots, so nothing is lost.
 * - Adopting a configuration is a bounded attempt: one load and at most one
 *   compare-exchange. If a publish lands between the two, the block keeps the
 *   configuration it already has and the new one is adopted at the next
 *   boundary. The audio thread never spins waiting for a control thread.
 * - The filter-state clearing in soundbridge_dsp_reset() and the re-derivation
 *   of coefficients for a new sample rate also take effect at the next block
 *   boundary, for the same reason.
 *
 * Realtime Safety:
 * - soundbridge_dsp_process_*() functions are lock-free and allocation-free
 * - soundbridge_dsp_set_bypass() is lock-free
 * - soundbridge_dsp_try_update_eq() is bounded: one token attempt, one publish,
 *   no retry, no allocation, no I/O. It is the entry point for a caller on the
 *   audio thread.
 * - The other configuration setters allocate nothing and perform no I/O, but
 *   they do compute coefficients and wait for a peer publisher to finish. That
 *   wait is a spin loop whose length is set by the scheduler, not by this
 *   library, so those setters are control-thread only.
 * - soundbridge_dsp_create() and soundbridge_dsp_destroy() allocate.
 */

#ifndef SOUNDBRIDGE_DSP_H
#define SOUNDBRIDGE_DSP_H

#include "soundbridge_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Opaque handle to DSP engine instance
 */
typedef struct soundbridge_dsp_engine soundbridge_dsp_engine_t;

// ============================================================================
// Engine Lifecycle
// ============================================================================

/**
 * @brief Create a new DSP engine instance
 *
 * @param sample_rate Sample rate in Hz (typically 44100 or 48000)
 * @return Pointer to engine instance, or NULL on failure
 *
 * @note This function allocates memory. Do NOT call from audio thread.
 * @note Caller must call soundbridge_dsp_destroy() to free resources.
 */
soundbridge_dsp_engine_t* soundbridge_dsp_create(uint32_t sample_rate);

/**
 * @brief Destroy a DSP engine instance
 *
 * @param engine Engine instance to destroy (must not be NULL)
 *
 * @note This function deallocates memory. Do NOT call from audio thread.
 * @note After calling this, the engine pointer is invalid.
 */
void soundbridge_dsp_destroy(soundbridge_dsp_engine_t* engine);

/**
 * @brief Reset engine state (clear filter history)
 *
 * @param engine Engine instance (must not be NULL)
 *
 * @note Useful when seeking in audio or recovering from underrun.
 * @note Statistics (frames processed, peak meters, CPU load) are cleared
 *       immediately. The filter history belongs to the audio thread and is
 *       cleared at the next block boundary, so this is safe to call while
 *       audio is being processed; it does not allocate or block.
 * @note A reset clears filter *history* only. It does not cancel a coefficient
 *       transition already in flight: the target that update recorded is still
 *       reached, because cancelling it would leave the filter at an
 *       intermediate coefficient set that nothing would ever correct.
 * @note A reset is not lost if a preset is applied right after it: it is a
 *       monotonic request, not part of the configuration snapshot.
 */
void soundbridge_dsp_reset(soundbridge_dsp_engine_t* engine);

/**
 * @brief Change sample rate
 *
 * @param engine Engine instance (must not be NULL)
 * @param sample_rate New sample rate in Hz (8000 to 384000)
 * @return SOUNDBRIDGE_OK on success, error code otherwise
 *
 * @note Every coefficient is recomputed for the new rate on the calling thread
 *       and published with the rest of the configuration; the audio thread
 *       re-initialises the smoother, DC blocker and ramp length when it applies
 *       it at the next block boundary. Biquad history is preserved across the
 *       change (only the coefficients change), the DC blocker is re-initialised
 *       because its pole depends on the rate, and the preamp gain in flight is
 *       carried over rather than restarted from silence.
 * @note Safe to call while audio is being processed.
 */
soundbridge_error_t soundbridge_dsp_set_sample_rate(
    soundbridge_dsp_engine_t* engine,
    uint32_t sample_rate
);

// ============================================================================
// Audio Processing (REALTIME-SAFE)
// ============================================================================

/**
 * @brief Process stereo audio (interleaved format)
 *
 * @param engine Engine instance (must not be NULL)
 * @param input Interleaved input buffer [L0, R0, L1, R1, ...]
 * @param output Interleaved output buffer [L0, R0, L1, R1, ...]
 * @param num_frames Number of stereo frames to process
 *
 * @note REALTIME-SAFE: No heap allocations or locks in the processing path
 * @note Buffers must be at least num_frames * 2 samples in size
 * @note Input and output may point to the same buffer (in-place processing)
 */
void soundbridge_dsp_process_interleaved(
    soundbridge_dsp_engine_t* engine,
    const float* input,
    float* output,
    uint32_t num_frames
);

/**
 * @brief Process stereo audio (planar format)
 *
 * @param engine Engine instance (must not be NULL)
 * @param input_left Left channel input buffer
 * @param input_right Right channel input buffer
 * @param output_left Left channel output buffer
 * @param output_right Right channel output buffer
 * @param num_frames Number of frames to process per channel
 *
 * @note REALTIME-SAFE: No heap allocations or locks in the processing path
 * @note Buffers must be at least num_frames samples in size
 * @note Input and output may point to the same buffers (in-place processing)
 */
void soundbridge_dsp_process_planar(
    soundbridge_dsp_engine_t* engine,
    const float* input_left,
    const float* input_right,
    float* output_left,
    float* output_right,
    uint32_t num_frames
);

// ============================================================================
// Preset Management (NOT realtime-safe)
// ============================================================================

/**
 * @brief Apply a complete preset to the engine
 *
 * @param engine Engine instance (must not be NULL)
 * @param preset Preset configuration (must not be NULL)
 * @return SOUNDBRIDGE_OK on success, error code otherwise
 *
 * @note Validated and turned into coefficients on the calling thread, then
 *       published; the audio thread adopts it at the next block boundary. This
 *       is safe while audio is being processed, although it is not realtime-safe
 *       (see the note at the top of this file).
 * @note A preset is a new baseline: every band takes its coefficients
 *       immediately and any ramp in flight is cancelled. The preamp keeps its
 *       own ~10 ms ramp. Use the soundbridge_dsp_update_*() setters for changes
 *       that should be smoothed band by band.
 * @note Call this from the UI thread, not the audio thread.
 */
soundbridge_error_t soundbridge_dsp_apply_preset(
    soundbridge_dsp_engine_t* engine,
    const soundbridge_preset_t* preset
);

/**
 * @brief Get the currently requested preset
 *
 * @param engine Engine instance (must not be NULL)
 * @param preset Pointer to preset struct to fill (must not be NULL)
 * @return SOUNDBRIDGE_OK on success, error code otherwise
 *
 * @note Returns the most recently requested configuration, which is what the
 *       caller last published. It is not necessarily the configuration a block
 *       that is running right now is using: that one is picked up at the next
 *       block boundary. Reading the requested value keeps a read-after-write
 *       in the UI consistent instead of showing a stale value for one block.
 */
soundbridge_error_t soundbridge_dsp_get_preset(
    soundbridge_dsp_engine_t* engine,
    soundbridge_preset_t* preset
);

/**
 * @brief Create a flat preset (all bands disabled, 0dB gain)
 *
 * @param preset Pointer to preset struct to initialize (must not be NULL)
 *
 * @note Useful for creating a baseline preset to modify
 */
void soundbridge_dsp_preset_init_flat(soundbridge_preset_t* preset);

/**
 * @brief Validate preset parameters are within valid ranges
 *
 * @param preset Preset to validate (must not be NULL)
 * @return SOUNDBRIDGE_OK if valid, error code otherwise
 */
soundbridge_error_t soundbridge_dsp_preset_validate(const soundbridge_preset_t* preset);

// ============================================================================
// Realtime Parameter Updates (thread-safe, smoothed)
//
// Each setter folds one change into the published configuration: it updates the
// requested preset, recomputes that band's coefficients, marks the band for
// ramp-in and publishes the complete snapshot. The audio thread applies it at
// the next block boundary, so a setter can run at any time and any thread, and
// a burst of setters collapses into the newest snapshot. Nothing here allocates
// or performs I/O; the cost is one coefficient computation plus one bounded POD
// copy, serialised against other publishers by a short spin.
// ============================================================================

/**
 * @brief Set bypass mode (REALTIME-SAFE)
 *
 * @param engine Engine instance (must not be NULL)
 * @param bypass true to bypass DSP (passthrough), false to process
 *
 * @note REALTIME-SAFE: Uses atomic operation, safe to call from any thread
 * @note Bypass is instant (no ramping) to preserve audio in emergency
 * @note Deliberately not part of the configuration snapshot: it is read once per
 *       block, so an emergency passthrough takes effect immediately rather than
 *       waiting behind a queued configuration
 */
void soundbridge_dsp_set_bypass(soundbridge_dsp_engine_t* engine, bool bypass);

/**
 * @brief Get current bypass state (REALTIME-SAFE)
 *
 * @param engine Engine instance (must not be NULL)
 * @return true if bypassed, false if processing
 */
bool soundbridge_dsp_get_bypass(const soundbridge_dsp_engine_t* engine);

/**
 * @brief Update a single band's gain (thread-safe, smoothed)
 *
 * @param engine Engine instance (must not be NULL)
 * @param band_index Band index (0 to num_bands-1); out-of-range values are ignored
 * @param gain_db New gain in dB (-12.0 to +12.0); non-finite values are ignored
 *
 * @note Safe to call from any thread while audio is processing
 * @note The band ramps to the new coefficients over ~10 ms from the next block
 *       boundary, which is what keeps a gain change free of zipper noise
 * @note Not realtime-safe in the strict sense: it computes coefficients and
 *       serialises with other publishers (see the note at the top of this file)
 */
void soundbridge_dsp_update_band_gain(
    soundbridge_dsp_engine_t* engine,
    uint32_t band_index,
    float gain_db
);

/**
 * @brief Update preamp gain (thread-safe, smoothed)
 *
 * @param engine Engine instance (must not be NULL)
 * @param gain_db New preamp gain in dB (-12.0 to +12.0); non-finite values are ignored
 *
 * @note Safe to call from any thread while audio is processing
 * @note Ramped by the preamp smoother rather than by coefficients, so there is
 *       nothing to mark for band smoothing
 * @note Not realtime-safe in the strict sense: it serialises with other
 *       publishers (see the note at the top of this file)
 */
void soundbridge_dsp_update_preamp(
    soundbridge_dsp_engine_t* engine,
    float gain_db
);

/**
 * @brief Apply a whole ten-band gain set plus the preamp in one bounded step
 *
 * This is the audio-thread entry point for an EQ change. It makes **one**
 * attempt at the publisher token and **one** publish:
 *
 * - Nothing here loops, allocates, logs or waits. If another publisher is
 *   inside the mailbox right now, the attempt is refused immediately.
 * - On refusal nothing has been modified: the engine keeps the configuration it
 *   already has, and the caller should retry with its next block's snapshot.
 *   That is what the Host does, so an EQ change can be delayed by one block but
 *   can never stall the callback.
 * - On success every band below the preset's band count is updated, marked for
 *   the usual ~10 ms coefficient ramp, and one complete configuration is
 *   published. A batch is never half-published: either the token was taken, in
 *   which case all of the bands and the preamp went in together, or none did.
 *
 * Per-value handling matches the individual setters: a non-finite gain leaves
 * that band's last valid value in place (it is not an error, and it does not
 * refuse the batch), and finite values are clamped to -12.0 … +12.0 dB.
 *
 * @param engine Engine instance (must not be NULL)
 * @param band_gains_db SOUNDBRIDGE_MAX_BANDS gains in dB, index = band slot
 * @param preamp_db Preamp gain in dB (-12.0 to +12.0); non-finite is ignored
 * @return true when the batch was published; false when the attempt was refused
 *         or an argument was NULL
 *
 * @note REALTIME-SAFE: bounded work, no allocation, no blocking wait.
 * @note Bypass is not part of this call - soundbridge_dsp_set_bypass() is an
 *       independent lock-free toggle and must still be applied when this
 *       returns false.
 */
bool soundbridge_dsp_try_update_eq(
    soundbridge_dsp_engine_t* engine,
    const float band_gains_db[SOUNDBRIDGE_MAX_BANDS],
    float preamp_db
);

/**
 * @brief Update a band's frequency (thread-safe, smoothed)
 *
 * @param engine Engine instance (must not be NULL)
 * @param band_index Band index (0 to num_bands-1); out-of-range values are ignored
 * @param frequency_hz New center frequency in Hz (20.0 to 20000.0); non-finite
 *        values are ignored
 *
 * @note Safe to call from any thread while audio is processing
 * @note Not realtime-safe: it serialises with other publishers and may wait for one
 * @note Applied with coefficient smoothing at the next block boundary to avoid clicks
 */
void soundbridge_dsp_update_band_frequency(
    soundbridge_dsp_engine_t* engine,
    uint32_t band_index,
    float frequency_hz
);

/**
 * @brief Update a band's Q factor (thread-safe, smoothed)
 *
 * @param engine Engine instance (must not be NULL)
 * @param band_index Band index (0 to num_bands-1); out-of-range values are ignored
 * @param q_factor New Q factor (0.1 to 10.0); non-finite values are ignored
 *
 * @note Safe to call from any thread while audio is processing
 * @note Not realtime-safe: it serialises with other publishers and may wait for one
 * @note Applied with coefficient smoothing at the next block boundary to avoid clicks
 */
void soundbridge_dsp_update_band_q(
    soundbridge_dsp_engine_t* engine,
    uint32_t band_index,
    float q_factor
);

// ============================================================================
// Diagnostics
// ============================================================================

/**
 * @brief Get engine statistics
 *
 * @param engine Engine instance (must not be NULL)
 * @param stats Pointer to stats struct to fill (must not be NULL)
 *
 * @note Safe to call from any thread (reads atomic counters)
 *
 * Level semantics (see soundbridge_stats_t for the full contract):
 * - `peak_left_db` / `peak_right_db` are the engine's *output* peak, i.e. after
 *   the limiter when limiting is enabled.
 * - `peak_left_db_pre_limiter` / `peak_right_db_pre_limiter` are the same
 *   measurement taken before the limiter, so overdrive stays visible.
 * - Positive values are overrange and are reported, not clamped to 0 dBFS.
 * - Values are always finite, never NaN, bounded by
 *   [SOUNDBRIDGE_PEAK_FLOOR_DB, SOUNDBRIDGE_PEAK_CEILING_DB].
 * - `underrun_count` is reserved and always 0; real underrun accounting lives
 *   in the Host's shared-memory ring telemetry.
 */
void soundbridge_dsp_get_stats(
    const soundbridge_dsp_engine_t* engine,
    soundbridge_stats_t* stats
);

/**
 * @brief Get library version string
 *
 * @return Version string of the release this library was built for (e.g.
 *         "1.2.0"), or "0.0.0-dev" for a build that did not get one
 *
 * @note The DSP has no independent version: it is compiled into SoundBridge.app,
 *       so this reports the product version from the repository VERSION file.
 *       tools/verify_version_consistency.sh checks that relationship.
 */
const char* soundbridge_dsp_get_version(void);

// ============================================================================
// Performance Optimizations
// ============================================================================

/**
 * @brief Enable denormal number suppression on current thread
 *
 * Denormal (subnormal) floating-point numbers can cause severe performance
 * degradation (10-100x slowdown) on some CPUs. This function enables
 * hardware flush-to-zero (FTZ) and denormals-are-zero (DAZ) modes.
 *
 * @note This affects only the calling thread
 * @note The process functions apply this themselves on entry, so an audio
 *       thread that only ever calls soundbridge_dsp_process_*() is already
 *       covered. Call it explicitly only if you do other floating-point work
 *       on the same thread and want the mode in place before the first block.
 * @note REALTIME-SAFE: No allocations, just sets CPU flags
 *
 * Example usage:
 * @code
 * // In your audio thread initialization:
 * soundbridge_dsp_enable_denormal_suppression();
 * @endcode
 */
void soundbridge_dsp_enable_denormal_suppression(void);

#ifdef __cplusplus
}
#endif

#endif // SOUNDBRIDGE_DSP_H
