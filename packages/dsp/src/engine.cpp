/**
 * @file engine.cpp
 * @brief Main DSP engine implementation
 *
 * Implements the public C API defined in soundbridge_dsp.h.
 * The engine is self-contained and does not require external DSP libraries.
 *
 * Thread ownership (audit findings F-02 through F-05)
 * --------------------------------------------------
 * The engine is split into three regions:
 *
 *  1. **Audio-thread exclusive** - biquad coefficients and interpolation state,
 *     the preamp smoother, the limiter's runtime threshold, the DC blocker, the
 *     applied preset and the rate in force. Written only by apply_config(),
 *     which only process_*() calls, and only at a block boundary.
 *  2. **Published atomics** - bypass, the reset request counter, the applied
 *     sample rate, and the statistics counters. Written by either side, read
 *     with relaxed/release-acquire as documented per field.
 *  3. **Publishing side** - the mailbox, the publisher token and the shadow
 *     configuration (the last *requested* configuration). Guarded by the token.
 *
 * Parameter updates never touch region 1. They validate, fold the change into
 * the shadow, precompute the affected band's coefficients at the shadow's own
 * sample rate, and publish one complete EngineConfig. The audio thread replaces
 * its whole region-1 state from that snapshot, so a block can never run with a
 * coefficient from one configuration and a band table from another.
 */

#include "soundbridge_dsp.h"
#include "biquad.h"
#include "smoothing.h"
#include "limiter.h"
#include "dc_blocker.h"
#include "cpu_util.h"
#include "buffer_math.h"
#include "config_mailbox.h"

#include <cstring>
#include <cmath>
#include <atomic>
#include <array>
#include <chrono>
#include <limits>

using namespace soundbridge;

// ============================================================================
// Meter helpers
// ============================================================================

namespace {

/**
 * @brief Fold one block's peak into a decaying meter.
 *
 * Attack is instantaneous and release is exponential with a time constant that
 * is independent of both sample rate and block size. The value is clamped into
 * the finite float range *before* it is stored: +Inf could never come back down
 * (Inf * decay is still Inf), so a single blow-up would pin the meter at
 * infinity for the rest of the session.
 *
 * NaN is handled before the clamp because std::min(FLT_MAX, NaN) evaluates to
 * FLT_MAX - the same trap as F-06, where a corrupted value would be reported as
 * the maximum level. A NaN measurement means "no measurement", not "+771 dBFS".
 */
float update_peak_meter(
    std::atomic<float>& meter,
    float block_peak,
    float decay,
    std::memory_order order
) {
    const float decayed = meter.load(order) * decay;
    const float next = std::max(block_peak, decayed);
    const float clamped = std::isnan(next)
        ? 0.0f
        : std::min(next, std::numeric_limits<float>::max());

    meter.store(clamped, order);
    return clamped;
}

/**
 * @brief Convert a linear peak to dBFS under the documented stats contract.
 *
 * Floor at SOUNDBRIDGE_PEAK_FLOOR_DB, ceiling at SOUNDBRIDGE_PEAK_CEILING_DB,
 * and never NaN or infinite. Note what is deliberately *absent*: there is no
 * clamp to 0 dBFS. A signal 12 dB into the limiter has to read as +12 dB, or the
 * meter cannot answer the only question it is displayed to answer.
 */
float linear_to_dbfs(float linear) {
    // `!(x > 0)` is true for 0, -0 and NaN.
    if (!(linear > 0.0f)) return SOUNDBRIDGE_PEAK_FLOOR_DB;

    const double db = 20.0 * std::log10(static_cast<double>(linear));

    if (!(db > static_cast<double>(SOUNDBRIDGE_PEAK_FLOOR_DB))) {
        return SOUNDBRIDGE_PEAK_FLOOR_DB;
    }
    if (!(db < static_cast<double>(SOUNDBRIDGE_PEAK_CEILING_DB))) {
        return SOUNDBRIDGE_PEAK_CEILING_DB;
    }
    return static_cast<float>(db);
}

/// Preamp ramp time constant. Also the coefficient-ramp duration below.
constexpr float kPreampRampMs = 10.0f;

/// Coefficient ramp duration, as a fraction of one second.
constexpr float kCoeffRampSeconds = 0.01f;

/// Peak meter release time constant.
constexpr float kPeakDecayTimeMs = 300.0f;

/// DC blocker corner frequency.
constexpr float kDcBlockerHz = 5.0f;

} // namespace

// ============================================================================
// Engine Internal Structure
// ============================================================================

struct soundbridge_dsp_engine {
    // ------------------------------------------------------------------
    // Region 1: audio-thread exclusive state.
    // Written only by apply_config()/reset handling, only from process_*(),
    // only at a block boundary. Never read by a control thread.
    // ------------------------------------------------------------------

    /// Sample rate in force for the block currently being processed.
    uint32_t sample_rate;

    /// EQ bands (each biquad handles stereo).
    std::array<Biquad, SOUNDBRIDGE_MAX_BANDS> bands;

    /**
     * Coefficients currently commanded into each biquad slot.
     *
     * This is the change-detection baseline, and it is deliberately the
     * *coefficients* rather than the band parameters: the biquads for slots at
     * or beyond `current_preset.num_bands` are never touched, so a parameter
     * baseline could claim "unchanged" for a slot whose filter is something else
     * entirely.
     */
    BiquadCoeffs applied_coeffs[SOUNDBRIDGE_MAX_BANDS];

    /**
     * The applied preset. `num_bands` is the active band count - there is no
     * separate field to disagree with it (F-09).
     */
    soundbridge_preset_t current_preset;

    /// Preamp gain ramp.
    ParameterSmoother preamp_smoother;

    /// Coefficient interpolation duration in samples (~10ms at the live rate).
    int coeff_transition_samples;

    /// Soft limiter and its runtime configuration.
    SoftLimiter limiter;
    bool limiter_enabled;

    /// DC blocker (prevents DC offset buildup from cascaded filters).
    StereoDCBlocker dc_blocker;

    // ------------------------------------------------------------------
    // Region 3: publishing side. Guarded by `token`; the mailbox is the only
    // thing the audio thread reads here.
    // ------------------------------------------------------------------

    ConfigMailbox mailbox;

    PublisherToken token;

    /// Last *requested* configuration. Source for every publish and for
    /// get_preset(), which is why a queued update is visible immediately even
    /// though the audio thread has not applied it yet.
    EngineConfig shadow;

    // ------------------------------------------------------------------
    // Region 2: atomics.
    // ------------------------------------------------------------------

    /// Bypass. Kept separate from the configuration on purpose: it must stay
    /// available as an emergency passthrough and must not wait behind a
    /// configuration hand-off. Read once per block, so a block still sees a
    /// single value.
    std::atomic<bool> bypass;

    /// Sample rate currently applied on the audio thread (for diagnostics).
    std::atomic<uint32_t> applied_sample_rate;

    /**
     * Monotonic count of requested filter-state resets.
     *
     * A counter rather than a flag: a flag would be consumed by whichever
     * configuration arrived next, and `reset(); apply_preset();` - the order
     * every frequency-response test uses - would silently drop the reset.
     */
    std::atomic<uint32_t> reset_requests;

    /// Reset count the audio thread has already honoured (audio thread only).
    uint32_t resets_applied;

    // Statistics.
    std::atomic<uint64_t> frames_processed;
    std::atomic<uint32_t> underrun_count;
    std::atomic<float> cpu_load_percent;
    std::atomic<float> peak_left;
    std::atomic<float> peak_right;

    /// Pre-limiter peak meters (linear). Captured before the limiter so the
    /// diagnostics can still tell "at the threshold" from "12 dB into it".
    std::atomic<float> peak_left_pre_limiter;
    std::atomic<float> peak_right_pre_limiter;

    soundbridge_dsp_engine(uint32_t sr)
        : sample_rate(sr)
        , current_preset()
        , coeff_transition_samples(static_cast<int>(static_cast<float>(sr) * kCoeffRampSeconds))
        , limiter_enabled(true)
        , bypass(false)
        , applied_sample_rate(sr)
        , reset_requests(0)
        , resets_applied(0)
        , frames_processed(0)
        , underrun_count(0)
        , cpu_load_percent(0.0f)
        , peak_left(0.0f)
        , peak_right(0.0f)
        , peak_left_pre_limiter(0.0f)
        , peak_right_pre_limiter(0.0f)
    {
        // Enable denormal suppression for this thread as a convenience.
        // The process functions re-apply it on their own thread (F-15).
        enable_denormal_suppression();

        // The documented start state: the flat preset (ten slots, none enabled)
        // plus the engine's own default of a limited output.
        // preset_init_flat() leaves limiter_enabled false for "transparent
        // testing", but an engine that is clipping by default is a worse
        // surprise than one that is limiting by default, so the applied preset
        // records true. This has to be recorded *in the preset*: the first
        // configuration to arrive carries the preset's own limiter flag, and a
        // disagreement between the field and the live limiter would make that
        // arrival silently change the behaviour.
        soundbridge_dsp_preset_init_flat(&current_preset);
        current_preset.limiter_enabled = true;

        for (auto& bq : bands) {
            bq.init();  // clears state and installs identity coefficients
        }
        for (auto& coeffs : applied_coeffs) {
            coeffs = flatBiquadCoeffs();
        }

        preamp_smoother.init(static_cast<float>(sample_rate), kPreampRampMs);
        preamp_smoother.setValue(1.0f);  // 0 dB = gain of 1.0

        limiter.init(current_preset.limiter_threshold_db);
        dc_blocker.init(static_cast<float>(sample_rate), kDcBlockerHz);

        // The publishing side starts out agreeing with the audio thread, so the
        // first publish carries a complete, correct snapshot.
        shadow.preset = current_preset;
        shadow.sample_rate = sample_rate;
        shadow.clear_smoothing();
        shadow.snap_all_bands = false;
        for (uint32_t i = 0; i < SOUNDBRIDGE_MAX_BANDS; i++) {
            shadow.coeffs[i] = applied_coeffs[i];
        }
    }
};

// ============================================================================
// Configuration application (audio thread, block boundary)
// ============================================================================

namespace {

/**
 * @brief Recompute every band slot's coefficients from the config's own state.
 *
 * Runs on the publishing thread. The config carries the results, so the audio
 * thread never has to decide which sample rate a coefficient belongs to.
 */
void refresh_config_coeffs(EngineConfig& config) {
    const float rate = static_cast<float>(config.sample_rate);
    for (uint32_t i = 0; i < SOUNDBRIDGE_MAX_BANDS; i++) {
        config.coeffs[i] = bandBiquadCoeffs(config.preset.bands[i], rate);
    }
}

/**
 * @brief Apply one complete configuration to the audio thread's private state.
 *
 * Called only from process_*(), only at a block boundary, with the mailbox
 * config that the audio thread now owns exclusively.
 */
void apply_config(soundbridge_dsp_engine_t* engine, const EngineConfig& config) {
    const bool rate_changed = config.sample_rate != engine->sample_rate;

    if (rate_changed) {
        // ParameterSmoother::init() zeroes current_ and target_, so
        // re-initialising mid-playback would ramp the preamp back up from
        // silence (46-70 ms of level dip on the next block). Carry the current
        // gain across: the ramp state is what the listener is hearing right
        // now, and it stays valid because only the time base changed.
        const float preamp_gain = engine->preamp_smoother.getCurrent();

        engine->sample_rate = config.sample_rate;
        engine->preamp_smoother.init(static_cast<float>(config.sample_rate), kPreampRampMs);
        engine->preamp_smoother.setValue(preamp_gain);
        engine->coeff_transition_samples =
            static_cast<int>(static_cast<float>(config.sample_rate) * kCoeffRampSeconds);
        engine->dc_blocker.init(static_cast<float>(config.sample_rate), kDcBlockerHz);

        engine->applied_sample_rate.store(config.sample_rate, std::memory_order_release);
    }

    // A rate change re-derives every coefficient, so it is a snap by nature.
    const bool snap = rate_changed || config.snap_all_bands;
    const uint32_t band_count = config.preset.num_bands;

    for (uint32_t i = 0; i < band_count; i++) {
        // Coefficients that already match the applied baseline are only a
        // reason to do nothing when the update is a smoothed one: the band is
        // at the requested coefficients and whatever ramp is in flight is
        // heading for the same target. A non-smooth entry - a preset, or the
        // residue of one after a later publish coalesced into the same
        // snapshot - must still be applied, because "a preset is a new
        // baseline" includes cancelling the ramp in flight even when the
        // endpoint happens to coincide (review finding R4).
        if (!snap && config.is_smooth(i) &&
            biquadCoeffsEqual(config.coeffs[i], engine->applied_coeffs[i])) {
            continue;
        }

        if (snap || !config.is_smooth(i)) {
            engine->bands[i].setCoeffsInstant(config.coeffs[i]);
        } else {
            engine->bands[i].rampCoeffsTo(config.coeffs[i], engine->coeff_transition_samples);
        }
        engine->applied_coeffs[i] = config.coeffs[i];
    }

    // Both are idempotent, so they are set unconditionally; a "did it change?"
    // test here could disagree with the smoother's own notion of its target.
    engine->preamp_smoother.setTarget(db_to_gain(config.preset.preamp_db));
    engine->limiter_enabled = config.preset.limiter_enabled;
    if (engine->limiter_enabled) {
        engine->limiter.setThreshold(config.preset.limiter_threshold_db);
    }

    engine->current_preset = config.preset;
}

/**
 * @brief Take the pending configuration, if any, and honour pending resets.
 *
 * Called at the top of both process entry points, before anything reads the
 * configuration. Nothing inside a block re-reads either source, so a publish
 * that lands mid-block takes effect at the next boundary and never half-way
 * through a buffer.
 */
void sync_config(soundbridge_dsp_engine_t* engine) {
    EngineConfig incoming;
    if (engine->mailbox.consume(incoming)) {
        apply_config(engine, incoming);
    }

    // Filter-history clears are a monotonic request rather than part of the
    // configuration: a reset must not be swallowed by a preset that was
    // published after it, and two resets before the same block are one event.
    //
    // resetHistory(), not reset(): the configuration above may have just
    // started a coefficient ramp and recorded its target in `applied_coeffs`.
    // Cancelling that ramp here would leave the biquad at interpolated
    // coefficients that no future update corrects, because the change-detection
    // comparison already points at the target (review finding R2).
    const uint32_t requested = engine->reset_requests.load(std::memory_order_acquire);
    if (requested != engine->resets_applied) {
        for (auto& bq : engine->bands) {
            bq.resetHistory();
        }
        engine->dc_blocker.reset();

        // Snap the preamp ramp to its target. getTarget() is the gain the
        // applied preset asks for, so this is where the smoother settles;
        // leaving it mid-ramp would make the first block after a reset start
        // from a stale gain.
        engine->preamp_smoother.setValue(engine->preamp_smoother.getTarget());

        engine->resets_applied = requested;
    }
}

} // namespace

// ============================================================================
// Engine Lifecycle
// ============================================================================

soundbridge_dsp_engine_t* soundbridge_dsp_create(uint32_t sample_rate) {
    if (sample_rate < 8000 || sample_rate > 384000) {
        return nullptr; // Invalid sample rate
    }

    try {
        return new soundbridge_dsp_engine(sample_rate);
    } catch (...) {
        return nullptr;
    }
}

void soundbridge_dsp_destroy(soundbridge_dsp_engine_t* engine) {
    if (engine) {
        delete engine;
    }
}

void soundbridge_dsp_reset(soundbridge_dsp_engine_t* engine) {
    if (!engine) return;

    // Statistics are published atomics that no thread owns, so they are cleared
    // here, immediately: a single-threaded caller that resets and then reads the
    // meters must see zeroed ones.
    //
    // The peak meters and the CPU estimate are published to the UI as "what the
    // engine is doing right now"; a reset that left them at their last values
    // would report audio that is no longer being processed.
    engine->frames_processed.store(0, std::memory_order_relaxed);
    engine->underrun_count.store(0, std::memory_order_relaxed);
    engine->peak_left.store(0.0f, std::memory_order_relaxed);
    engine->peak_right.store(0.0f, std::memory_order_relaxed);
    engine->peak_left_pre_limiter.store(0.0f, std::memory_order_relaxed);
    engine->peak_right_pre_limiter.store(0.0f, std::memory_order_relaxed);
    engine->cpu_load_percent.store(0.0f, std::memory_order_relaxed);

    // The filter history, on the other hand, belongs to the audio thread. Ask
    // for it to be cleared at the next block boundary instead of reaching into
    // state another thread may be using.
    engine->reset_requests.fetch_add(1, std::memory_order_release);
}

soundbridge_error_t soundbridge_dsp_set_sample_rate(
    soundbridge_dsp_engine_t* engine,
    uint32_t sample_rate
) {
    if (!engine) return SOUNDBRIDGE_ERROR_NULL_POINTER;
    if (sample_rate < 8000 || sample_rate > 384000) {
        return SOUNDBRIDGE_ERROR_INVALID_PARAM;
    }

    // The new rate is folded into the shadow and published; every coefficient in
    // the config is recomputed for it, and the audio thread re-initialises the
    // smoother, the DC blocker and the transition length when it applies the
    // config. Nothing shared is written here, so this is safe while the render
    // callback is running - the caller no longer has to stop it first.
    PublisherLock lock(engine->token);
    engine->shadow.sample_rate = sample_rate;
    refresh_config_coeffs(engine->shadow);
    engine->mailbox.publish(engine->shadow);

    return SOUNDBRIDGE_OK;
}

// ============================================================================
// Audio Processing (REALTIME-SAFE)
// ============================================================================

void soundbridge_dsp_process_interleaved(
    soundbridge_dsp_engine_t* engine,
    const float* input,
    float* output,
    uint32_t num_frames
) {
    if (!engine || !input || !output || num_frames == 0) return;

    // FTZ/DAZ are per-thread architectural state, and create() runs on whichever
    // thread constructed the engine - in the Host that is the control thread,
    // not the CoreAudio IO thread. Doing it here costs a few register writes per
    // block and is the only way to guarantee that the thread actually running
    // the filters has it. A thread_local "already applied" flag would trade that
    // for a TLS lookup, and on first access inside a dynamically loaded library
    // a TLS lookup is allowed to take a lock, which the audio thread may not do.
    enable_denormal_suppression();

    // Start CPU timing
    auto start_time = std::chrono::high_resolution_clock::now();

    // Block boundary: adopt the newest published configuration, then let go of
    // the mailbox for the rest of the block.
    sync_config(engine);

    // One bypass decision for the whole block.
    if (engine->bypass.load(std::memory_order_relaxed)) {
        // Passthrough
        if (input != output) {
            std::memcpy(output, input, soundbridge::interleaved_copy_bytes(num_frames));
        }

        // Decay peak meters so they don't hold stale values
        const float peak_decay_samples =
            kPeakDecayTimeMs * static_cast<float>(engine->sample_rate) / 1000.0f;
        const float peak_decay = std::exp(-static_cast<float>(num_frames) / peak_decay_samples);
        engine->peak_left.store(engine->peak_left.load(std::memory_order_relaxed) * peak_decay, std::memory_order_relaxed);
        engine->peak_right.store(engine->peak_right.load(std::memory_order_relaxed) * peak_decay, std::memory_order_relaxed);
        engine->peak_left_pre_limiter.store(engine->peak_left_pre_limiter.load(std::memory_order_relaxed) * peak_decay, std::memory_order_relaxed);
        engine->peak_right_pre_limiter.store(engine->peak_right_pre_limiter.load(std::memory_order_relaxed) * peak_decay, std::memory_order_relaxed);

        engine->frames_processed.fetch_add(num_frames, std::memory_order_relaxed);
        return;
    }

    // The configuration for this whole block, captured once.
    const soundbridge_preset_t& preset = engine->current_preset;
    const uint32_t active_bands = preset.num_bands;

    // Peak detection
    float buffer_peak_left = 0.0f;
    float buffer_peak_right = 0.0f;
    float buffer_peak_pre_left = 0.0f;
    float buffer_peak_pre_right = 0.0f;

    // Check if preamp smoother has settled (skip per-sample ticks when stable)
    const bool preamp_stable = engine->preamp_smoother.isStable();
    const float preamp_gain_cached = preamp_stable ? engine->preamp_smoother.getCurrent() : 0.0f;

    // Process each frame
    for (uint32_t i = 0; i < num_frames; i++) {
        // Deinterleave
        float left = input[i * 2];
        float right = input[i * 2 + 1];

        // Apply preamp (skip smoother ticks when stable)
        const float preamp_gain = preamp_stable ? preamp_gain_cached : engine->preamp_smoother.next();
        left *= preamp_gain;
        right *= preamp_gain;

        // Process through EQ bands
        for (uint32_t band = 0; band < active_bands; band++) {
            if (preset.bands[band].enabled) {
                // Each biquad processes both channels
                engine->bands[band].processSample(left, right, &left, &right);
            }
        }

        // Remove DC offset (prevents buildup from cascaded filters)
        engine->dc_blocker.processStereo(left, right, &left, &right);

        // Pre-limiter peak: measured before limiting so overdrive stays visible
        // even while the limiter holds the output at its threshold (F-12).
        buffer_peak_pre_left = std::max(buffer_peak_pre_left, std::abs(left));
        buffer_peak_pre_right = std::max(buffer_peak_pre_right, std::abs(right));

        // Apply limiter if enabled
        if (engine->limiter_enabled) {
            engine->limiter.processSampleStereo(&left, &right);
        }

        // Track output peak levels
        buffer_peak_left = std::max(buffer_peak_left, std::abs(left));
        buffer_peak_right = std::max(buffer_peak_right, std::abs(right));

        // Interleave output
        output[i * 2] = left;
        output[i * 2 + 1] = right;
    }

    // Update peak meters with sample-rate-independent exponential decay
    // Decay time constant: 300ms (meter falls to ~37% of peak in 300ms)
    const float peak_decay_samples =
        kPeakDecayTimeMs * static_cast<float>(engine->sample_rate) / 1000.0f;
    const float peak_decay = std::exp(-static_cast<float>(num_frames) / peak_decay_samples);

    // Attack: instant rise to new peak
    // Decay: exponential fall (consistent regardless of buffer size)
    update_peak_meter(engine->peak_left, buffer_peak_left, peak_decay,
                      std::memory_order_relaxed);
    update_peak_meter(engine->peak_right, buffer_peak_right, peak_decay,
                      std::memory_order_relaxed);
    update_peak_meter(engine->peak_left_pre_limiter, buffer_peak_pre_left, peak_decay,
                      std::memory_order_relaxed);
    update_peak_meter(engine->peak_right_pre_limiter, buffer_peak_pre_right, peak_decay,
                      std::memory_order_relaxed);

    // End CPU timing and calculate load
    auto end_time = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> elapsed = end_time - start_time;

    // Calculate available time for this buffer (in seconds)
    double available_time = static_cast<double>(num_frames) / static_cast<double>(engine->sample_rate);

    // Calculate CPU load as percentage
    float instant_load = static_cast<float>((elapsed.count() / available_time) * 100.0);

    // Buffer-size-independent EMA: smoothing time constant ~500ms
    constexpr float cpu_smooth_time_ms = 500.0f;
    const float cpu_smooth_samples = cpu_smooth_time_ms * static_cast<float>(engine->sample_rate) / 1000.0f;
    const float cpu_alpha = 1.0f - std::exp(-static_cast<float>(num_frames) / cpu_smooth_samples);
    float current_load = engine->cpu_load_percent.load(std::memory_order_relaxed);
    float smoothed_load = current_load + cpu_alpha * (instant_load - current_load);
    engine->cpu_load_percent.store(smoothed_load, std::memory_order_relaxed);

    // Update statistics
    engine->frames_processed.fetch_add(num_frames, std::memory_order_relaxed);
}

void soundbridge_dsp_process_planar(
    soundbridge_dsp_engine_t* engine,
    const float* input_left,
    const float* input_right,
    float* output_left,
    float* output_right,
    uint32_t num_frames
) {
    if (!engine || !input_left || !input_right || !output_left || !output_right || num_frames == 0) {
        return;
    }

    // Per-thread FPU state; see the note in process_interleaved.
    enable_denormal_suppression();

    // Start CPU timing
    auto start_time = std::chrono::high_resolution_clock::now();

    // Block boundary: adopt the newest published configuration (see the
    // interleaved entry point).
    sync_config(engine);

    // One bypass decision for the whole block.
    if (engine->bypass.load(std::memory_order_relaxed)) {
        // Passthrough
        if (input_left != output_left) {
            std::memcpy(output_left, input_left, num_frames * sizeof(float));
        }
        if (input_right != output_right) {
            std::memcpy(output_right, input_right, num_frames * sizeof(float));
        }

        // Decay peak meters so they don't hold stale values
        const float peak_decay_samples =
            kPeakDecayTimeMs * static_cast<float>(engine->sample_rate) / 1000.0f;
        const float peak_decay = std::exp(-static_cast<float>(num_frames) / peak_decay_samples);
        engine->peak_left.store(engine->peak_left.load(std::memory_order_relaxed) * peak_decay, std::memory_order_relaxed);
        engine->peak_right.store(engine->peak_right.load(std::memory_order_relaxed) * peak_decay, std::memory_order_relaxed);
        engine->peak_left_pre_limiter.store(engine->peak_left_pre_limiter.load(std::memory_order_relaxed) * peak_decay, std::memory_order_relaxed);
        engine->peak_right_pre_limiter.store(engine->peak_right_pre_limiter.load(std::memory_order_relaxed) * peak_decay, std::memory_order_relaxed);

        engine->frames_processed.fetch_add(num_frames, std::memory_order_relaxed);
        return;
    }

    // The configuration for this whole block, captured once.
    const soundbridge_preset_t& preset = engine->current_preset;
    const uint32_t active_bands = preset.num_bands;

    // Copy input to output first (we'll process in-place)
    if (input_left != output_left) {
        std::memcpy(output_left, input_left, num_frames * sizeof(float));
    }
    if (input_right != output_right) {
        std::memcpy(output_right, input_right, num_frames * sizeof(float));
    }

    // Apply preamp (skip smoother ticks when stable)
    const bool preamp_stable = engine->preamp_smoother.isStable();
    if (preamp_stable) {
        const float gain = engine->preamp_smoother.getCurrent();
        for (uint32_t i = 0; i < num_frames; i++) {
            output_left[i] *= gain;
            output_right[i] *= gain;
        }
    } else {
        for (uint32_t i = 0; i < num_frames; i++) {
            const float preamp_gain = engine->preamp_smoother.next();
            output_left[i] *= preamp_gain;
            output_right[i] *= preamp_gain;
        }
    }

    // Process through EQ bands
    for (uint32_t band = 0; band < active_bands; band++) {
        if (preset.bands[band].enabled) {
            // Each biquad processes both channels
            engine->bands[band].processBuffer(
                output_left, output_right,
                output_left, output_right,
                num_frames
            );
        }
    }

    // Remove DC offset (prevents buildup from cascaded filters)
    engine->dc_blocker.processBuffer(
        output_left, output_right,
        output_left, output_right,
        num_frames
    );

    // Pre-limiter peak: measured before limiting so overdrive stays visible
    // even while the limiter holds the output at its threshold (F-12).
    float buffer_peak_pre_left = 0.0f;
    float buffer_peak_pre_right = 0.0f;
    for (uint32_t i = 0; i < num_frames; i++) {
        buffer_peak_pre_left = std::max(buffer_peak_pre_left, std::abs(output_left[i]));
        buffer_peak_pre_right = std::max(buffer_peak_pre_right, std::abs(output_right[i]));
    }

    // Apply limiter if enabled
    if (engine->limiter_enabled) {
        engine->limiter.processBuffer(output_left, output_right, num_frames);
    }

    // Peak detection (post-limiter output)
    float buffer_peak_left = 0.0f;
    float buffer_peak_right = 0.0f;
    for (uint32_t i = 0; i < num_frames; i++) {
        buffer_peak_left = std::max(buffer_peak_left, std::abs(output_left[i]));
        buffer_peak_right = std::max(buffer_peak_right, std::abs(output_right[i]));
    }

    // Update peak meters with sample-rate-independent exponential decay
    const float peak_decay_samples =
        kPeakDecayTimeMs * static_cast<float>(engine->sample_rate) / 1000.0f;
    const float peak_decay = std::exp(-static_cast<float>(num_frames) / peak_decay_samples);

    // Attack: instant rise to new peak
    // Decay: exponential fall (consistent regardless of buffer size)
    update_peak_meter(engine->peak_left, buffer_peak_left, peak_decay,
                      std::memory_order_relaxed);
    update_peak_meter(engine->peak_right, buffer_peak_right, peak_decay,
                      std::memory_order_relaxed);
    update_peak_meter(engine->peak_left_pre_limiter, buffer_peak_pre_left, peak_decay,
                      std::memory_order_relaxed);
    update_peak_meter(engine->peak_right_pre_limiter, buffer_peak_pre_right, peak_decay,
                      std::memory_order_relaxed);

    // End CPU timing and calculate load
    auto end_time = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> elapsed = end_time - start_time;

    // Calculate available time for this buffer (in seconds)
    double available_time = static_cast<double>(num_frames) / static_cast<double>(engine->sample_rate);

    // Calculate CPU load as percentage
    float instant_load = static_cast<float>((elapsed.count() / available_time) * 100.0);

    // Buffer-size-independent EMA: smoothing time constant ~500ms
    constexpr float cpu_smooth_time_ms = 500.0f;
    const float cpu_smooth_samples = cpu_smooth_time_ms * static_cast<float>(engine->sample_rate) / 1000.0f;
    const float cpu_alpha = 1.0f - std::exp(-static_cast<float>(num_frames) / cpu_smooth_samples);
    float current_load = engine->cpu_load_percent.load(std::memory_order_relaxed);
    float smoothed_load = current_load + cpu_alpha * (instant_load - current_load);
    engine->cpu_load_percent.store(smoothed_load, std::memory_order_relaxed);

    // Update statistics
    engine->frames_processed.fetch_add(num_frames, std::memory_order_relaxed);
}

// ============================================================================
// Preset Management (publisher side)
// ============================================================================

soundbridge_error_t soundbridge_dsp_apply_preset(
    soundbridge_dsp_engine_t* engine,
    const soundbridge_preset_t* preset
) {
    if (!engine || !preset) {
        return SOUNDBRIDGE_ERROR_NULL_POINTER;
    }

    // Validate on the calling thread; the audio thread only ever sees a
    // configuration that already passed.
    soundbridge_error_t err = soundbridge_dsp_preset_validate(preset);
    if (err != SOUNDBRIDGE_OK) {
        return err;
    }

    PublisherLock lock(engine->token);

    // Assignment, not memcpy: the old code guarded against memcpy() with
    // identical source and destination, which assignment makes impossible to
    // get wrong.
    engine->shadow.preset = *preset;

    // Coefficients are computed here, at the shadow's own rate, and travel with
    // the configuration - the audio thread never has to know which rate a
    // coefficient was derived for.
    refresh_config_coeffs(engine->shadow);

    // A preset is a new baseline rather than a nudge: every band takes its
    // coefficients immediately and any ramp in flight is cancelled.
    engine->shadow.snap_all_bands = true;
    engine->shadow.clear_smoothing();
    engine->mailbox.publish(engine->shadow);
    engine->shadow.snap_all_bands = false;

    return SOUNDBRIDGE_OK;
}

soundbridge_error_t soundbridge_dsp_get_preset(
    soundbridge_dsp_engine_t* engine,
    soundbridge_preset_t* preset
) {
    if (!engine || !preset) {
        return SOUNDBRIDGE_ERROR_NULL_POINTER;
    }

    // The requested configuration, not the applied one: an update that has been
    // queued but not yet consumed must be visible to the caller that just made
    // it (and to any reader), otherwise the UI would read back stale values for
    // up to one block.
    PublisherLock lock(engine->token);
    *preset = engine->shadow.preset;
    return SOUNDBRIDGE_OK;
}

// ============================================================================
// Realtime Parameter Updates (publisher side)
//
// These fold one change into the shadow configuration, recompute the affected
// band's coefficients, and publish the complete snapshot. The audio thread
// picks the newest snapshot up at its next block boundary.
// ============================================================================

void soundbridge_dsp_set_bypass(soundbridge_dsp_engine_t* engine, bool bypass) {
    if (engine) {
        engine->bypass.store(bypass, std::memory_order_relaxed);
    }
}

bool soundbridge_dsp_get_bypass(const soundbridge_dsp_engine_t* engine) {
    return engine ? engine->bypass.load(std::memory_order_relaxed) : true;
}

void soundbridge_dsp_update_band_gain(
    soundbridge_dsp_engine_t* engine,
    uint32_t band_index,
    float gain_db
) {
    if (!engine) return;

    // Reject non-finite values instead of clamping them. std::min(12.0f, NaN)
    // evaluates to 12.0f, so clamping a NaN would map it to the *maximum*
    // permitted boost — the loudest possible response to a corrupted parameter.
    // preset_validate() already rejects non-finite values; the realtime setters
    // must apply the same policy and keep the previous valid value.
    if (!std::isfinite(gain_db)) return;

    // Clamp gain
    gain_db = std::max(-12.0f, std::min(12.0f, gain_db));

    PublisherLock lock(engine->token);

    // Band slots are 0..num_bands-1; that count is the requested one, so an
    // update is never dropped just because the audio thread has not applied the
    // preset it came with yet.
    if (band_index >= engine->shadow.preset.num_bands) return;

    soundbridge_band_t& band = engine->shadow.preset.bands[band_index];
    band.gain_db = gain_db;
    engine->shadow.coeffs[band_index] =
        bandBiquadCoeffs(band, static_cast<float>(engine->shadow.sample_rate));

    // Smoothly interpolate coefficients to prevent zipper noise
    engine->shadow.set_smooth(band_index);
    engine->mailbox.publish(engine->shadow);
}

void soundbridge_dsp_update_preamp(
    soundbridge_dsp_engine_t* engine,
    float gain_db
) {
    if (!engine) return;

    // Reject non-finite values (see soundbridge_dsp_update_band_gain).
    if (!std::isfinite(gain_db)) return;

    // Clamp gain
    gain_db = std::max(-12.0f, std::min(12.0f, gain_db));

    PublisherLock lock(engine->token);
    engine->shadow.preset.preamp_db = gain_db;

    // The preamp is always smoothed by its own ramp, so there is no coefficient
    // to recompute and no band to mark.
    engine->mailbox.publish(engine->shadow);
}

bool soundbridge_dsp_try_update_eq(
    soundbridge_dsp_engine_t* engine,
    const float band_gains_db[SOUNDBRIDGE_MAX_BANDS],
    float preamp_db
) {
    if (!engine || !band_gains_db) return false;

    // One attempt, no loop. A refusal is not an error: a control-thread
    // publisher is inside publish() right now, and an audio callback must not
    // wait for that thread to be scheduled again. Nothing below has run yet, so
    // a refusal leaves the requested configuration and the published one as
    // they were.
    PublisherTryLock lock(engine->token);
    if (!lock.locked()) return false;

    // Same slot rule as the per-band setter: slots 0..num_bands-1, where the
    // count is the *requested* one, so an update is never dropped just because
    // the audio thread has not applied the preset it came with yet.
    const uint32_t band_count = engine->shadow.preset.num_bands;
    for (uint32_t i = 0; i < band_count; i++) {
        const float gain_db = band_gains_db[i];
        if (!std::isfinite(gain_db)) continue;  // keep the last valid value

        soundbridge_band_t& band = engine->shadow.preset.bands[i];
        band.gain_db = std::max(-12.0f, std::min(12.0f, gain_db));
        engine->shadow.coeffs[i] =
            bandBiquadCoeffs(band, static_cast<float>(engine->shadow.sample_rate));

        // Smoothed, exactly as ten individual update_band_gain() calls would
        // be: the batch changes how many publishes a batch costs, not whether
        // a change ramps.
        engine->shadow.set_smooth(i);
    }

    if (std::isfinite(preamp_db)) {
        engine->shadow.preset.preamp_db = std::max(-12.0f, std::min(12.0f, preamp_db));
    }

    // One publish for the whole batch. Ten band setters plus a preamp setter
    // would coalesce to this same snapshot, at the cost of eleven copies and
    // eleven exchanges on the audio thread.
    engine->mailbox.publish(engine->shadow);
    return true;
}

void soundbridge_dsp_update_band_frequency(
    soundbridge_dsp_engine_t* engine,
    uint32_t band_index,
    float frequency_hz
) {
    if (!engine) return;

    // Reject non-finite values (see soundbridge_dsp_update_band_gain).
    if (!std::isfinite(frequency_hz)) return;

    // Clamp frequency
    frequency_hz = std::max(20.0f, std::min(20000.0f, frequency_hz));

    PublisherLock lock(engine->token);

    if (band_index >= engine->shadow.preset.num_bands) return;

    soundbridge_band_t& band = engine->shadow.preset.bands[band_index];
    band.frequency_hz = frequency_hz;
    engine->shadow.coeffs[band_index] =
        bandBiquadCoeffs(band, static_cast<float>(engine->shadow.sample_rate));

    engine->shadow.set_smooth(band_index);
    engine->mailbox.publish(engine->shadow);
}

void soundbridge_dsp_update_band_q(
    soundbridge_dsp_engine_t* engine,
    uint32_t band_index,
    float q_factor
) {
    if (!engine) return;

    // Reject non-finite values (see soundbridge_dsp_update_band_gain).
    if (!std::isfinite(q_factor)) return;

    // Clamp Q factor
    q_factor = std::max(0.1f, std::min(10.0f, q_factor));

    PublisherLock lock(engine->token);

    if (band_index >= engine->shadow.preset.num_bands) return;

    soundbridge_band_t& band = engine->shadow.preset.bands[band_index];
    band.q_factor = q_factor;
    engine->shadow.coeffs[band_index] =
        bandBiquadCoeffs(band, static_cast<float>(engine->shadow.sample_rate));

    engine->shadow.set_smooth(band_index);
    engine->mailbox.publish(engine->shadow);
}

// ============================================================================
// Diagnostics
// ============================================================================

void soundbridge_dsp_get_stats(
    const soundbridge_dsp_engine_t* engine,
    soundbridge_stats_t* stats
) {
    if (!engine || !stats) return;

    stats->frames_processed = engine->frames_processed.load(std::memory_order_relaxed);
    stats->underrun_count = engine->underrun_count.load(std::memory_order_relaxed);
    stats->cpu_load_percent = engine->cpu_load_percent.load(std::memory_order_relaxed);
    stats->bypass_active = engine->bypass.load(std::memory_order_relaxed);

    // The rate the audio thread is actually rendering at, not the one a caller
    // may have requested and not yet had applied.
    stats->sample_rate = engine->applied_sample_rate.load(std::memory_order_acquire);

    // Convert peak levels from linear to dBFS. linear_to_dbfs() owns the floor,
    // the ceiling and the NaN handling, so every level field follows the same
    // documented contract; in particular a level above full scale is reported as
    // a positive dBFS value instead of being clamped to 0 (F-08).
    stats->peak_left_db = linear_to_dbfs(
        engine->peak_left.load(std::memory_order_relaxed));
    stats->peak_right_db = linear_to_dbfs(
        engine->peak_right.load(std::memory_order_relaxed));
    stats->peak_left_db_pre_limiter = linear_to_dbfs(
        engine->peak_left_pre_limiter.load(std::memory_order_relaxed));
    stats->peak_right_db_pre_limiter = linear_to_dbfs(
        engine->peak_right_pre_limiter.load(std::memory_order_relaxed));
}

// ============================================================================
// Performance Optimizations
// ============================================================================

void soundbridge_dsp_enable_denormal_suppression(void) {
    enable_denormal_suppression();
}

// ============================================================================
// Test support
// ============================================================================
//
// "The bounded path refuses instead of waiting" can only be *observed* if
// something else is inside the token, and the engine's token is private. Holding
// it from the outside is the narrowest seam that makes that state reachable.
//
// Not declared in any public header and not part of the C ABI: these are C++
// symbols in a test-only namespace, and nothing in the library calls them.
namespace soundbridge {
namespace test_support {

void hold_publisher_token(soundbridge_dsp_engine_t* engine) {
    if (engine) engine->token.lock();
}

void release_publisher_token(soundbridge_dsp_engine_t* engine) {
    if (engine) engine->token.unlock();
}

} // namespace test_support
} // namespace soundbridge
