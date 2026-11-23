/**
 * @file test_engine.cpp
 * @brief Tests for full DSP engine
 */

#include "test_utils.h"
#include "soundbridge_dsp.h"
#include "cpu_util.h"

#include <atomic>
#include <chrono>
#include <limits>
#include <thread>

using namespace dsp_test;

// Test seam implemented in engine.cpp. The publisher token is private to the
// engine, so holding it from the outside is the only way to make the bounded
// publish path's refusal observable instead of hypothetical. Declared here
// rather than in a public header: it is not part of the API.
namespace soundbridge {
namespace test_support {
void hold_publisher_token(soundbridge_dsp_engine_t* engine);
void release_publisher_token(soundbridge_dsp_engine_t* engine);
} // namespace test_support
} // namespace soundbridge

namespace {

// Steady-state gain of the engine at `frequency`, in dB.
//
// One full second is processed and the first quarter discarded so the preamp
// and coefficient ramps (10 ms) have settled long before the measurement
// window. Callers must disable the limiter: it would otherwise compress the
// test sine and mask the EQ response under test.
double measure_engine_gain_db(
    soundbridge_dsp_engine_t* engine,
    float frequency,
    float sample_rate
) {
    const size_t total = static_cast<size_t>(sample_rate);
    const auto input = generate_sine(total, frequency, sample_rate);
    std::vector<float> out_left(total);
    std::vector<float> out_right(total);

    soundbridge_dsp_process_planar(
        engine,
        input.data(), input.data(),
        out_left.data(), out_right.data(),
        static_cast<uint32_t>(total)
    );

    const size_t skip = total / 4;
    const std::vector<float> settled_in(input.begin() + skip, input.end());
    const std::vector<float> settled_out(out_left.begin() + skip, out_left.end());

    const double in_rms = measure_rms(settled_in);
    const double out_rms = measure_rms(settled_out);
    return 20.0 * std::log10(out_rms / in_rms);
}

} // namespace

TEST(engine_create_destroy) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_dsp_destroy(engine);

    PASS();
}

TEST(engine_invalid_sample_rate) {
    // Too low
    auto* engine1 = soundbridge_dsp_create(1000);
    ASSERT(engine1 == nullptr);

    // Too high
    auto* engine2 = soundbridge_dsp_create(500000);
    ASSERT(engine2 == nullptr);

    PASS();
}

TEST(engine_bypass_is_bit_perfect) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    // Enable bypass
    soundbridge_dsp_set_bypass(engine, true);
    ASSERT_EQ(soundbridge_dsp_get_bypass(engine), true);

    // Generate test signal
    auto input_left = generate_sine(1000, 1000.0f, 48000.0f);
    auto input_right = input_left;
    std::vector<float> output_left(input_left.size());
    std::vector<float> output_right(input_right.size());

    // Process in bypass mode (planar)
    soundbridge_dsp_process_planar(
        engine,
        input_left.data(), input_right.data(),
        output_left.data(), output_right.data(),
        input_left.size()
    );

    // Output should be identical to input (bit-perfect)
    ASSERT(signals_identical(input_left, output_left));
    ASSERT(signals_identical(input_right, output_right));

    soundbridge_dsp_destroy(engine);
    PASS();
}

TEST(engine_bypass_interleaved_is_bit_perfect) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_dsp_set_bypass(engine, true);

    // Generate interleaved test signal
    std::vector<float> input(2000); // 1000 frames stereo
    for (size_t i = 0; i < 1000; i++) {
        float sample = std::sin(2.0f * M_PI * 1000.0f * i / 48000.0f);
        input[i * 2] = sample;     // Left
        input[i * 2 + 1] = sample; // Right
    }

    std::vector<float> output(input.size());

    // Process
    soundbridge_dsp_process_interleaved(
        engine,
        input.data(),
        output.data(),
        1000 // num_frames
    );

    // Output should be identical
    ASSERT(signals_identical(input, output));

    soundbridge_dsp_destroy(engine);
    PASS();
}

TEST(engine_apply_flat_preset) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);

    auto result = soundbridge_dsp_apply_preset(engine, &preset);
    ASSERT_EQ(result, SOUNDBRIDGE_OK);

    soundbridge_dsp_destroy(engine);
    PASS();
}

TEST(engine_process_with_flat_preset) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    // Apply flat preset
    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);
    soundbridge_dsp_apply_preset(engine, &preset);

    // Disable bypass
    soundbridge_dsp_set_bypass(engine, false);

    // Generate test signal
    auto input_left = generate_sine(4800, 1000.0f, 48000.0f);
    auto input_right = input_left;
    std::vector<float> output_left(input_left.size());
    std::vector<float> output_right(input_right.size());

    // Process
    soundbridge_dsp_process_planar(
        engine,
        input_left.data(), input_right.data(),
        output_left.data(), output_right.data(),
        input_left.size()
    );

    // With flat preset, output should be very similar to input
    // (might not be bit-perfect due to smoothing, but should be close)
    float input_rms = measure_rms(input_left);
    float output_rms = measure_rms(output_left);

    ASSERT_NEAR(output_rms, input_rms, 0.1f);

    soundbridge_dsp_destroy(engine);
    PASS();
}

TEST(engine_peak_filter_boosts_signal) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    // Create preset with +6dB peak at 1kHz
    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);

    preset.num_bands = 1;
    preset.bands[0].enabled = true;
    preset.bands[0].frequency_hz = 1000.0f;
    preset.bands[0].gain_db = 6.0f;
    preset.bands[0].q_factor = 2.0f;
    preset.bands[0].type = SOUNDBRIDGE_FILTER_PEAK;

    soundbridge_dsp_apply_preset(engine, &preset);
    soundbridge_dsp_set_bypass(engine, false);

    // Generate 1kHz test signal
    auto input_left = generate_sine(4800, 1000.0f, 48000.0f);
    auto input_right = input_left;
    std::vector<float> output_left(input_left.size());
    std::vector<float> output_right(input_right.size());

    // Process
    soundbridge_dsp_process_planar(
        engine,
        input_left.data(), input_right.data(),
        output_left.data(), output_right.data(),
        input_left.size()
    );

    float input_rms = measure_rms(input_left);
    float output_rms = measure_rms(output_left);

    // Output should be louder (boosted)
    ASSERT(output_rms > input_rms * 1.5f); // At least +3.5dB

    soundbridge_dsp_destroy(engine);
    PASS();
}

TEST(engine_limiter_prevents_clipping) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    // Create preset with significant boost
    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);

    preset.preamp_db = 12.0f; // +12dB preamp (will clip without limiter)
    preset.limiter_enabled = true;
    preset.limiter_threshold_db = -0.1f;

    soundbridge_dsp_apply_preset(engine, &preset);
    soundbridge_dsp_set_bypass(engine, false);

    // Generate loud test signal
    auto input_left = generate_sine(4800, 1000.0f, 48000.0f);
    auto input_right = input_left;
    std::vector<float> output_left(input_left.size());
    std::vector<float> output_right(input_right.size());

    // Process
    soundbridge_dsp_process_planar(
        engine,
        input_left.data(), input_right.data(),
        output_left.data(), output_right.data(),
        input_left.size()
    );

    // Peak should not exceed threshold
    float peak = measure_peak(output_left);
    ASSERT(peak <= 1.0f); // Should not clip

    soundbridge_dsp_destroy(engine);
    PASS();
}

TEST(engine_update_band_gain_realtime) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    // Create preset with one band
    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);

    preset.num_bands = 1;
    preset.bands[0].enabled = true;
    preset.bands[0].frequency_hz = 1000.0f;
    preset.bands[0].gain_db = 0.0f; // Start at 0dB
    preset.bands[0].q_factor = 1.0f;
    preset.bands[0].type = SOUNDBRIDGE_FILTER_PEAK;

    soundbridge_dsp_apply_preset(engine, &preset);
    soundbridge_dsp_set_bypass(engine, false);

    // Update gain in realtime
    soundbridge_dsp_update_band_gain(engine, 0, 6.0f); // Change to +6dB

    // Generate test signal
    auto input_left = generate_sine(4800, 1000.0f, 48000.0f);
    auto input_right = input_left;
    std::vector<float> output_left(input_left.size());
    std::vector<float> output_right(input_right.size());

    // Process
    soundbridge_dsp_process_planar(
        engine,
        input_left.data(), input_right.data(),
        output_left.data(), output_right.data(),
        input_left.size()
    );

    // Check output is boosted
    float input_rms = measure_rms(input_left);
    float output_rms = measure_rms(output_left);

    ASSERT(output_rms > input_rms * 1.3f);

    soundbridge_dsp_destroy(engine);
    PASS();
}

TEST(engine_statistics_tracking) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_stats_t stats;
    soundbridge_dsp_get_stats(engine, &stats);

    // Initial stats
    ASSERT_EQ(stats.frames_processed, 0);
    ASSERT_EQ(stats.sample_rate, 48000);
    ASSERT_EQ(stats.bypass_active, false);

    // Process some audio
    auto input_left = generate_sine(1000, 1000.0f, 48000.0f);
    auto input_right = input_left;
    std::vector<float> output_left(input_left.size());
    std::vector<float> output_right(input_right.size());

    soundbridge_dsp_process_planar(
        engine,
        input_left.data(), input_right.data(),
        output_left.data(), output_right.data(),
        input_left.size()
    );

    // Check stats updated
    soundbridge_dsp_get_stats(engine, &stats);
    ASSERT_EQ(stats.frames_processed, 1000);

    soundbridge_dsp_destroy(engine);
    PASS();
}

TEST(engine_reset_clears_state) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    // Apply preset with filter
    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);
    preset.num_bands = 1;
    preset.bands[0].enabled = true;
    preset.bands[0].frequency_hz = 1000.0f;
    preset.bands[0].gain_db = 6.0f;
    preset.bands[0].q_factor = 2.0f;
    preset.bands[0].type = SOUNDBRIDGE_FILTER_PEAK;

    soundbridge_dsp_apply_preset(engine, &preset);
    soundbridge_dsp_set_bypass(engine, false);

    // Process some audio to build up filter state
    auto signal_left = generate_sine(1000, 1000.0f, 48000.0f);
    auto signal_right = signal_left;
    std::vector<float> output_left(signal_left.size());
    std::vector<float> output_right(signal_right.size());

    soundbridge_dsp_process_planar(
        engine,
        signal_left.data(), signal_right.data(),
        output_left.data(), output_right.data(),
        signal_left.size()
    );

    // Reset
    soundbridge_dsp_reset(engine);

    // Stats should be cleared
    soundbridge_stats_t stats;
    soundbridge_dsp_get_stats(engine, &stats);
    ASSERT_EQ(stats.frames_processed, 0);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Regression for audit finding B3.
//
// preset_validate() only bounds a band to 20 Hz..20 kHz and never looks at the
// sample rate, so a preset that is legal at 48 kHz is out of band at 22.05 kHz:
// a high shelf centred above fs/2 puts both poles outside the unit circle and
// the filter state diverges. Before the Nyquist clamp in calculateCoeffs() this
// block produced inf/NaN within a few hundred frames.
TEST(engine_band_above_nyquist_stays_finite) {
    auto* engine = soundbridge_dsp_create(22050);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);
    preset.preamp_db = 0.0f;
    preset.bands[0].enabled = true;
    preset.bands[0].frequency_hz = 16000.0f;  // above 22050 / 2
    preset.bands[0].gain_db = 12.0f;
    preset.bands[0].q_factor = 0.7f;
    preset.bands[0].type = SOUNDBRIDGE_FILTER_HIGH_SHELF;

    // The band is legal on its own terms; validation is not the fix.
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    auto input = generate_sine(2048, 1000.0f, 22050.0f);
    std::vector<float> output_left(input.size());
    std::vector<float> output_right(input.size());

    soundbridge_dsp_process_planar(
        engine,
        input.data(), input.data(),
        output_left.data(), output_right.data(),
        static_cast<uint32_t>(input.size())
    );

    for (size_t i = 0; i < output_left.size(); i++) {
        ASSERT(std::isfinite(output_left[i]));
        ASSERT(std::isfinite(output_right[i]));
    }

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Regression for audit finding A3.
//
// ParameterSmoother::init() zeroes current_ and target_, so re-initialising the
// preamp smoother on a sample-rate change used to ramp the gain back up from
// silence: a 46-70 ms dip on every following block. set_sample_rate() now
// carries the current gain across the re-init.
TEST(engine_sample_rate_change_preserves_preamp) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);
    preset.preamp_db = -6.0f;         // linear gain 0.5
    preset.limiter_enabled = false;
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    // Let the preamp ramp settle: 1 s at a 10 ms time constant is ~100 time
    // constants, far inside the 1e-4 stability epsilon.
    auto settle = generate_sine(48000, 100.0f, 48000.0f);
    std::vector<float> scratch(settle.size());
    soundbridge_dsp_process_planar(
        engine,
        settle.data(), settle.data(),
        scratch.data(), scratch.data(),
        static_cast<uint32_t>(settle.size())
    );

    ASSERT_EQ(soundbridge_dsp_set_sample_rate(engine, 44100), SOUNDBRIDGE_OK);

    // The first block after the change must already carry the full gain. A
    // 100 Hz sine reaches its peak 110 frames in, still inside this block; a
    // smoother restarting from zero only reaches ~22% of target by then, so the
    // measured peak would be ~0.11 instead of ~0.5.
    auto probe = generate_sine(256, 100.0f, 44100.0f);
    std::vector<float> probe_left(probe.size());
    std::vector<float> probe_right(probe.size());
    soundbridge_dsp_process_planar(
        engine,
        probe.data(), probe.data(),
        probe_left.data(), probe_right.data(),
        static_cast<uint32_t>(probe.size())
    );

    ASSERT(measure_peak(probe_left) > 0.45f);
    ASSERT(measure_peak(probe_right) > 0.45f);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Audit finding F-09.
//
// A freshly created engine installs the flat preset (10 band slots, none
// enabled) while num_active_bands started at 0, so every update_band_*() call
// was dropped by the `band_index >= num_active_bands` guard and the UI's edits
// silently vanished until a preset was re-applied.
TEST(engine_default_state_is_consistent) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset;
    ASSERT_EQ(soundbridge_dsp_get_preset(engine, &preset), SOUNDBRIDGE_OK);
    ASSERT_EQ(preset.num_bands, static_cast<uint32_t>(SOUNDBRIDGE_MAX_BANDS));

    // Active band slot is not the same thing as enabled EQ band: all ten slots
    // exist, none of them filter.
    for (uint32_t i = 0; i < preset.num_bands; i++) {
        ASSERT(!preset.bands[i].enabled);
    }

    // The update must be recorded even while the band is disabled.
    soundbridge_dsp_update_band_gain(engine, 0, 6.0f);
    ASSERT_EQ(soundbridge_dsp_get_preset(engine, &preset), SOUNDBRIDGE_OK);
    ASSERT_NEAR(preset.bands[0].gain_db, 6.0f, 1e-6);

    // The last slot must be reachable too, not just band 0.
    soundbridge_dsp_update_band_gain(engine, SOUNDBRIDGE_MAX_BANDS - 1, -3.0f);
    ASSERT_EQ(soundbridge_dsp_get_preset(engine, &preset), SOUNDBRIDGE_OK);
    ASSERT_NEAR(preset.bands[SOUNDBRIDGE_MAX_BANDS - 1].gain_db, -3.0f, 1e-6);

    // Separately: with a band actually enabled the audio path applies the gain.
    // Limiter off so the measurement is the EQ response, not limiter gain.
    soundbridge_dsp_preset_init_flat(&preset);
    preset.bands[0].enabled = true;
    preset.bands[0].frequency_hz = 1000.0f;
    preset.bands[0].gain_db = 6.0f;
    preset.bands[0].q_factor = 1.0f;
    preset.bands[0].type = SOUNDBRIDGE_FILTER_PEAK;
    preset.limiter_enabled = false;
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 6.0, 0.2);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Audit finding F-06.
//
// Clamping a non-finite gain is worse than ignoring it: std::min(12.0f, NaN)
// evaluates to 12.0f, so a NaN would have been applied as the maximum boost.
// The setters must reject NaN/Inf and keep the previous valid value.
TEST(engine_realtime_parameter_rejects_non_finite) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);
    preset.bands[0].enabled = true;
    preset.bands[0].frequency_hz = 1000.0f;
    preset.bands[0].gain_db = 0.0f;
    preset.bands[0].q_factor = 1.0f;
    preset.bands[0].type = SOUNDBRIDGE_FILTER_PEAK;
    preset.limiter_enabled = false;
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    const double before_db = measure_engine_gain_db(engine, 1000.0f, 48000.0f);
    ASSERT_NEAR(before_db, 0.0, 0.2);

    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();

    for (float bad : {nan, inf, -inf}) {
        soundbridge_dsp_update_band_gain(engine, 0, bad);
        soundbridge_dsp_update_band_frequency(engine, 0, bad);
        soundbridge_dsp_update_band_q(engine, 0, bad);
        soundbridge_dsp_update_preamp(engine, bad);

        soundbridge_preset_t live;
        ASSERT_EQ(soundbridge_dsp_get_preset(engine, &live), SOUNDBRIDGE_OK);
        ASSERT(live.bands[0].gain_db == 0.0f);
        ASSERT(live.bands[0].frequency_hz == 1000.0f);
        ASSERT(live.bands[0].q_factor == 1.0f);
        ASSERT(live.preamp_db == 0.0f);
    }

    // The rejected values must not have reached the audio path either.
    const double after_db = measure_engine_gain_db(engine, 1000.0f, 48000.0f);
    ASSERT_NEAR(after_db, before_db, 0.05);

    // Finite out-of-range values keep the old behaviour: clamped, not dropped.
    soundbridge_dsp_update_band_gain(engine, 0, 1000.0f);
    soundbridge_dsp_update_band_q(engine, 0, 1e6f);
    soundbridge_dsp_update_band_frequency(engine, 0, 1e6f);
    soundbridge_dsp_update_preamp(engine, -1000.0f);

    ASSERT_EQ(soundbridge_dsp_get_preset(engine, &preset), SOUNDBRIDGE_OK);
    ASSERT_NEAR(preset.bands[0].gain_db, 12.0f, 1e-6);
    ASSERT_NEAR(preset.bands[0].q_factor, 10.0f, 1e-6);
    ASSERT_NEAR(preset.bands[0].frequency_hz, 20000.0f, 1e-3);
    ASSERT_NEAR(preset.preamp_db, -12.0f, 1e-6);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Audit finding F-07.
//
// A non-finite input sample must be contained at the stage that sees it. Before
// the guards a single NaN travelled through the whole chain untouched and, in
// the DC blocker, poisoned the recursive state permanently. The limiter is
// disabled here so it cannot hide the result by zeroing the sample itself.
TEST(engine_non_finite_input_stays_finite) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);
    preset.bands[0].enabled = true;
    preset.bands[0].frequency_hz = 1000.0f;
    preset.bands[0].gain_db = 6.0f;
    preset.bands[0].q_factor = 1.0f;
    preset.bands[0].type = SOUNDBRIDGE_FILTER_PEAK;
    preset.limiter_enabled = false;
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();

    std::vector<float> poisoned = generate_sine(512, 1000.0f, 48000.0f);
    poisoned[100] = nan;
    poisoned[200] = inf;
    poisoned[300] = -inf;

    std::vector<float> out_left(poisoned.size());
    std::vector<float> out_right(poisoned.size());

    soundbridge_dsp_process_planar(
        engine,
        poisoned.data(), poisoned.data(),
        out_left.data(), out_right.data(),
        static_cast<uint32_t>(poisoned.size())
    );

    for (size_t i = 0; i < poisoned.size(); i++) {
        ASSERT(std::isfinite(out_left[i]));
        ASSERT(std::isfinite(out_right[i]));
    }

    // The chain must not be wedged: after the bad block the steady-state
    // response has to come back, not silence and not NaN.
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 6.0, 0.3);

    // Same story through the interleaved entry point and a flat preset, where
    // the DC blocker is the only stage left to catch the sample.
    soundbridge_dsp_preset_init_flat(&preset);
    preset.limiter_enabled = false;
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);

    std::vector<float> interleaved = generate_sine(512, 1000.0f, 48000.0f);
    std::vector<float> interleaved_in(interleaved.size() * 2);
    for (size_t i = 0; i < interleaved.size(); i++) {
        interleaved_in[i * 2] = interleaved[i];
        interleaved_in[i * 2 + 1] = -interleaved[i];
    }
    interleaved_in[2 * 50] = nan;
    interleaved_in[2 * 150] = inf;

    std::vector<float> interleaved_out(interleaved_in.size());
    soundbridge_dsp_process_interleaved(
        engine,
        interleaved_in.data(),
        interleaved_out.data(),
        static_cast<uint32_t>(interleaved.size())
    );

    for (size_t i = 0; i < interleaved_out.size(); i++) {
        ASSERT(std::isfinite(interleaved_out[i]));
    }

    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 0.0, 0.2);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Audit finding F-08.
//
// The old conversion had a floor but no ceiling, so an extreme peak was reported
// as a physically impossible level, and there was nothing stopping a NaN or an
// infinity from reaching the caller. The contract now is: dBFS, positive values
// are overrange and are reported rather than clamped, the value is always
// finite, and silence reads as the documented floor.
TEST(engine_stats_peak_reports_overrange) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);
    preset.preamp_db = 12.0f;   // linear 3.98x
    preset.limiter_enabled = false;
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    auto input = generate_sine(4800, 1000.0f, 48000.0f);
    std::vector<float> out_left(input.size());
    std::vector<float> out_right(input.size());

    soundbridge_dsp_process_planar(
        engine,
        input.data(), input.data(),
        out_left.data(), out_right.data(),
        static_cast<uint32_t>(input.size())
    );

    soundbridge_stats_t stats;
    soundbridge_dsp_get_stats(engine, &stats);

    // ~+12 dBFS: above full scale, and it must say so. Clamping to 0 dBFS here
    // is audit finding F-08 and destroys the only overdrive indication the
    // engine has.
    ASSERT(std::isfinite(stats.peak_left_db));
    ASSERT(std::isfinite(stats.peak_right_db));
    ASSERT(stats.peak_left_db > 6.0f);
    ASSERT(stats.peak_left_db < 20.0f);
    ASSERT(stats.peak_right_db > 6.0f);
    ASSERT(stats.peak_right_db < 20.0f);
    ASSERT(stats.peak_left_db <= SOUNDBRIDGE_PEAK_CEILING_DB);
    ASSERT(stats.peak_right_db <= SOUNDBRIDGE_PEAK_CEILING_DB);

    // Silence: the documented floor, never NaN and never -infinity.
    soundbridge_dsp_reset(engine);
    soundbridge_dsp_get_stats(engine, &stats);
    ASSERT(stats.peak_left_db == SOUNDBRIDGE_PEAK_FLOOR_DB);
    ASSERT(stats.peak_right_db == SOUNDBRIDGE_PEAK_FLOOR_DB);
    ASSERT(stats.peak_left_db_pre_limiter == SOUNDBRIDGE_PEAK_FLOOR_DB);
    ASSERT(stats.peak_right_db_pre_limiter == SOUNDBRIDGE_PEAK_FLOOR_DB);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Audit finding F-08, extreme half: a huge but finite peak must produce a large
// finite dBFS value, not a NaN, not an infinity, and not a wrapped number.
TEST(engine_stats_peak_is_finite_for_extreme_input) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);
    preset.preamp_db = 12.0f;
    preset.limiter_enabled = false;
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    // 3e37 * 3.98 is 1.2e38: still finite, about 761 dBFS.
    std::vector<float> huge(256, 3.0e37f);
    std::vector<float> out_left(huge.size());
    std::vector<float> out_right(huge.size());

    soundbridge_dsp_process_planar(
        engine,
        huge.data(), huge.data(),
        out_left.data(), out_right.data(),
        static_cast<uint32_t>(huge.size())
    );

    soundbridge_stats_t stats;
    soundbridge_dsp_get_stats(engine, &stats);

    ASSERT(std::isfinite(stats.peak_left_db));
    ASSERT(std::isfinite(stats.peak_right_db));
    ASSERT(stats.peak_left_db > 0.0f);
    ASSERT(stats.peak_left_db <= SOUNDBRIDGE_PEAK_CEILING_DB);
    ASSERT(stats.peak_right_db <= SOUNDBRIDGE_PEAK_CEILING_DB);

    // The dB value has to be usable as an exponent: a consumer doing
    // pow(10, db/20) must not overflow float.
    ASSERT(std::isfinite(std::pow(10.0f, stats.peak_left_db / 20.0f)));

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Audit finding F-12.
//
// The peak meters are sampled after the limiter, so with limiting on they can
// never exceed the threshold and cannot show how hard the engine is driven.
// The post-limiter value keeps its meaning; a second, pre-limiter pair is added
// rather than redefining the existing field, and both processing paths are
// checked because each has its own meter code.
TEST(engine_stats_pre_limiter_peak_sees_overdrive) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);
    preset.preamp_db = 12.0f;
    preset.limiter_enabled = true;
    preset.limiter_threshold_db = -0.1f;
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    auto input = generate_sine(4800, 1000.0f, 48000.0f);
    std::vector<float> out_left(input.size());
    std::vector<float> out_right(input.size());
    soundbridge_stats_t stats;

    // Planar path.
    soundbridge_dsp_process_planar(
        engine,
        input.data(), input.data(),
        out_left.data(), out_right.data(),
        static_cast<uint32_t>(input.size())
    );
    soundbridge_dsp_get_stats(engine, &stats);

    ASSERT(stats.peak_left_db <= 0.0f);
    ASSERT(stats.peak_left_db >= -1.0f);
    ASSERT(stats.peak_right_db <= 0.0f);
    ASSERT(stats.peak_left_db_pre_limiter > 6.0f);
    ASSERT(stats.peak_right_db_pre_limiter > 6.0f);

    // Interleaved path: same numbers, its own meter code.
    soundbridge_dsp_reset(engine);
    std::vector<float> interleaved_in(input.size() * 2);
    for (size_t i = 0; i < input.size(); i++) {
        interleaved_in[i * 2] = input[i];
        interleaved_in[i * 2 + 1] = input[i];
    }
    std::vector<float> interleaved_out(interleaved_in.size());

    soundbridge_dsp_process_interleaved(
        engine,
        interleaved_in.data(),
        interleaved_out.data(),
        static_cast<uint32_t>(input.size())
    );
    soundbridge_dsp_get_stats(engine, &stats);

    ASSERT(stats.peak_left_db <= 0.0f);
    ASSERT(stats.peak_right_db <= 0.0f);
    ASSERT(stats.peak_left_db_pre_limiter > 6.0f);
    ASSERT(stats.peak_right_db_pre_limiter > 6.0f);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Audit finding F-13.
//
// The engine cannot observe the IO cycle's deadline, so `underrun_count` cannot
// be a real counter here. Rather than let a permanently-zero field imply "no
// underruns ever", it is documented as reserved and the real accounting lives in
// the Host's shared-memory ring telemetry. This test pins the documented
// behaviour so a future change has to come with a documentation change.
TEST(engine_stats_underrun_count_stays_reserved) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    auto input = generate_sine(1024, 1000.0f, 48000.0f);
    std::vector<float> out_left(input.size());
    std::vector<float> out_right(input.size());

    soundbridge_dsp_process_planar(
        engine,
        input.data(), input.data(),
        out_left.data(), out_right.data(),
        static_cast<uint32_t>(input.size())
    );

    soundbridge_stats_t stats;
    soundbridge_dsp_get_stats(engine, &stats);
    ASSERT_EQ(stats.underrun_count, 0u);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Audit finding F-15.
//
// FTZ/DAZ is per-thread CPU state. `create()` runs on the control thread, so the
// audio thread used to run with denormals enabled; the process entry points now
// set the mode themselves. The assertion is made on a thread whose mode was
// explicitly cleared first, so it proves the process call did it and not the
// constructor or thread inheritance.
#if defined(__aarch64__) || defined(__arm64__) || defined(_M_ARM64) || \
    defined(__x86_64__) || defined(__i386__)

namespace {

/// True when flush-to-zero (and, on x86, denormals-are-zero) is active.
bool denormal_mode_enabled() {
#if defined(__aarch64__) || defined(__arm64__) || defined(_M_ARM64)
    uint64_t fpcr;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
    return ((fpcr >> 24) & 1u) != 0;
#else
    // FTZ is MXCSR bit 15, DAZ is bit 6.
    return (static_cast<unsigned>(_mm_getcsr()) & 0x8040u) == 0x8040u;
#endif
}

} // namespace

TEST(engine_denormal_suppression_applies_to_the_calling_thread) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    std::atomic<bool> had_mode_before{true};
    std::atomic<bool> has_mode_after{false};

    std::thread worker([&] {
        soundbridge::disable_denormal_suppression();
        had_mode_before.store(denormal_mode_enabled());

        std::vector<float> buffer(256, 0.25f);
        soundbridge_dsp_process_interleaved(
            engine,
            buffer.data(), buffer.data(),
            static_cast<uint32_t>(buffer.size() / 2)
        );

        has_mode_after.store(denormal_mode_enabled());
    });
    worker.join();

    ASSERT(!had_mode_before.load());   // the fixture really did clear it
    ASSERT(has_mode_after.load());     // process_* put it back

    soundbridge_dsp_destroy(engine);
    PASS();
}

#endif

// ---------------------------------------------------------------------------
// Concurrency (audit findings F-02 - F-05)
//
// What these tests can and cannot prove, stated rather than implied:
//
//   - They prove liveness and stability: thousands of parameter changes and
//     preset switches issued from other threads while a block loop runs must
//     never corrupt the output, must never wedge the engine, and must leave the
//     newest configuration in force once the producers stop.
//   - They do NOT prove per-block configuration atomicity by inspection of the
//     output: the audible result is determined by the coefficients, and a
//     coefficient set always arrives whole, so a mixed configuration can look
//     exactly like one of the legitimate ones. Atomicity rests on two things
//     that are checked elsewhere - config_mailbox_* proves the snapshot is
//     never torn, and apply_config() runs to completion at the block boundary
//     before the first sample is touched.
//   - ThreadSanitizer is the tool that proves the absence of data races; these
//     tests are what give it something to chew on.
// ---------------------------------------------------------------------------

namespace {

/// A one-band preset: `gain_db` at 1 kHz, limiter off so the measurement is the
/// EQ response rather than the limiter's.
soundbridge_preset_t single_band_preset(float gain_db) {
    soundbridge_preset_t preset;
    soundbridge_dsp_preset_init_flat(&preset);
    preset.num_bands = 1;
    preset.bands[0].enabled = true;
    preset.bands[0].frequency_hz = 1000.0f;
    preset.bands[0].gain_db = gain_db;
    preset.bands[0].q_factor = 1.0f;
    preset.bands[0].type = SOUNDBRIDGE_FILTER_PEAK;
    preset.limiter_enabled = false;
    return preset;
}

/// One 512-frame interleaved 1 kHz block at 0.05 amplitude.
std::vector<float> steady_test_block() {
    std::vector<float> block(512 * 2);
    for (uint32_t i = 0; i < 512; i++) {
        const float sample = 0.05f * std::sin(2.0f * M_PI * 1000.0f * i / 48000.0f);
        block[i * 2] = sample;
        block[i * 2 + 1] = sample;
    }
    return block;
}

/// Gain of one interleaved 1 kHz block, measured over that block alone.
///
/// Unlike measure_engine_gain_db(), which discards the settling window, this
/// shows what the coefficients were doing *inside* the block - which is what a
/// coefficient transition makes observable.
double measure_block_gain_db(soundbridge_dsp_engine_t* engine, uint32_t frames) {
    std::vector<float> in(frames * 2);
    std::vector<float> out(frames * 2);
    for (uint32_t i = 0; i < frames; i++) {
        const float sample = 0.05f * std::sin(
            2.0f * M_PI * 1000.0f * static_cast<float>(i) / 48000.0f);
        in[i * 2] = sample;
        in[i * 2 + 1] = sample;
    }

    soundbridge_dsp_process_interleaved(engine, in.data(), out.data(), frames);

    double in_energy = 0.0;
    double out_energy = 0.0;
    for (uint32_t i = 0; i < frames; i++) {
        in_energy += static_cast<double>(in[i * 2]) * static_cast<double>(in[i * 2]);
        out_energy += static_cast<double>(out[i * 2]) * static_cast<double>(out[i * 2]);
    }
    return 10.0 * std::log10(out_energy / in_energy);
}

} // namespace

// Thousands of updates with no process call in between must coalesce to the
// newest one - not queue up, not apply an arbitrary intermediate value, and not
// lose the last update because the mailbox was "full".
TEST(engine_saturated_mailbox_applies_only_the_newest_update) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset = single_band_preset(0.0f);
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    for (int i = 0; i < 20000; i++) {
        soundbridge_dsp_update_band_gain(engine, 0, (i % 2 == 0) ? -12.0f : 12.0f);
    }
    soundbridge_dsp_update_band_gain(engine, 0, 9.0f);

    // The queued value is what the caller asked for, before it is applied: a
    // reader must not see a stale value for up to a block.
    soundbridge_preset_t live;
    ASSERT_EQ(soundbridge_dsp_get_preset(engine, &live), SOUNDBRIDGE_OK);
    ASSERT_NEAR(live.bands[0].gain_db, 9.0f, 1e-6);

    // And it is what the audio path applies on its next block.
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 9.0, 0.3);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// The Host's render callback stages EQ changes on the IO thread immediately
// before it processes; this is that shape, with the updates coming from a
// different thread at an unbounded rate.
TEST(engine_updates_from_another_thread_are_applied) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset = single_band_preset(0.0f);
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    std::atomic<bool> stop{false};
    std::thread producer([&] {
        float gain = 0.0f;
        while (!stop.load(std::memory_order_relaxed)) {
            gain = (gain == 0.0f) ? 6.0f : 0.0f;
            soundbridge_dsp_update_band_gain(engine, 0, gain);
            soundbridge_dsp_update_preamp(engine, gain * 0.5f);
        }
    });

    const std::vector<float> block = steady_test_block();
    std::vector<float> out(block.size());
    bool all_finite = true;

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(120);
    while (std::chrono::steady_clock::now() < deadline) {
        soundbridge_dsp_process_interleaved(engine, block.data(), out.data(), 512);
        for (float sample : out) {
            if (!std::isfinite(sample)) all_finite = false;
        }
    }

    stop.store(true, std::memory_order_relaxed);
    producer.join();

    ASSERT(all_finite);

    // The newest update wins once the storm ends.
    soundbridge_dsp_update_band_gain(engine, 0, 6.0f);
    soundbridge_dsp_update_preamp(engine, 0.0f);
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 6.0, 0.3);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Two threads applying different presets while the block loop runs. Preset
// application is the heaviest publish there is (ten bands, coefficient
// recomputation), so this is the worst case for the publisher token.
TEST(engine_concurrent_preset_switching_settles_on_the_last_preset) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    const soundbridge_preset_t boosted = single_band_preset(12.0f);
    const soundbridge_preset_t flat = single_band_preset(-12.0f);

    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &flat), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    std::atomic<bool> stop{false};
    std::thread first([&] {
        while (!stop.load(std::memory_order_relaxed)) {
            soundbridge_dsp_apply_preset(engine, &boosted);
        }
    });
    std::thread second([&] {
        while (!stop.load(std::memory_order_relaxed)) {
            soundbridge_dsp_apply_preset(engine, &flat);
        }
    });

    const std::vector<float> block = steady_test_block();
    std::vector<float> out(block.size());
    bool all_finite = true;
    float peak = 0.0f;

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(120);
    while (std::chrono::steady_clock::now() < deadline) {
        soundbridge_dsp_process_interleaved(engine, block.data(), out.data(), 512);
        for (float sample : out) {
            if (!std::isfinite(sample)) all_finite = false;
            peak = std::max(peak, std::abs(sample));
        }
    }

    stop.store(true, std::memory_order_relaxed);
    first.join();
    second.join();

    ASSERT(all_finite);
    // Snapping coefficients while the filter holds state produces a transient,
    // so this is a divergence bound rather than an exact level. A configuration
    // that was applied half-way through a block, or a coefficient set mixed
    // across two sample rates, would blow past it.
    ASSERT(peak < 12.0f);

    // After the storm the last published preset is the one in force.
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &boosted), SOUNDBRIDGE_OK);
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 12.0, 0.3);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// A reset must not be swallowed by a preset published right behind it.
//
// This is the order every frequency-response test uses (`reset(); apply();`),
// and it is exactly what a "reset flag rides in the configuration" design would
// get wrong: the preset would carry reset=false and overwrite the request.
TEST(engine_reset_survives_a_following_preset) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset = single_band_preset(12.0f);
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    // Build up real filter state: a resonant band plus the DC blocker's history.
    auto tone = generate_sine(4096, 1000.0f, 48000.0f);
    std::vector<float> out_left(tone.size());
    std::vector<float> out_right(tone.size());
    soundbridge_dsp_process_planar(
        engine,
        tone.data(), tone.data(),
        out_left.data(), out_right.data(),
        static_cast<uint32_t>(tone.size())
    );

    // Reset, then immediately publish a flat preset. Both land in the same block.
    soundbridge_dsp_reset(engine);
    soundbridge_dsp_preset_init_flat(&preset);
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);

    // If the reset were honoured, every stage starts from zero and silence in
    // is silence out - exactly. A surviving DC-blocker or biquad history would
    // ring out for thousands of samples (the DC blocker's pole is ~0.9993).
    std::vector<float> silence(512, 0.0f);
    std::vector<float> silence_left(512);
    std::vector<float> silence_right(512);
    soundbridge_dsp_process_planar(
        engine,
        silence.data(), silence.data(),
        silence_left.data(), silence_right.data(),
        static_cast<uint32_t>(silence.size())
    );

    for (size_t i = 0; i < silence.size(); i++) {
        ASSERT_EQ(silence_left[i], 0.0f);
        ASSERT_EQ(silence_right[i], 0.0f);
    }

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Review finding R2.
//
// reset() used to clear the biquad delay line *and* cancel the coefficient
// transition. When the two land in the same block boundary - update first, reset
// second - apply_config() has already recorded the update's target in
// `applied_coeffs`, so the cancelled ramp leaves the filter at an interpolated
// coefficient set that no later update corrects: the change-detection
// comparison reports "already at the target".
//
// Against the previous implementation this test measured 0.0 dB, permanently.
TEST(engine_reset_does_not_cancel_a_pending_coefficient_ramp) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset = single_band_preset(0.0f);
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);

    // Adopt the flat preset, so the baseline a later update is compared against
    // is the flat coefficient set.
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 0.0, 0.2);

    // Queue a smoothed +12 dB update, then ask for a reset before the block
    // that would have adopted it.
    soundbridge_dsp_update_band_gain(engine, 0, 12.0f);
    soundbridge_dsp_reset(engine);

    // The band must still arrive at +12 dB.
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 12.0, 0.3);

    // And the reset really did clear the filter history: with the coefficients
    // untouched, silence in is exactly silence out.
    soundbridge_dsp_reset(engine);
    std::vector<float> silence(512, 0.0f);
    std::vector<float> left(512);
    std::vector<float> right(512);
    soundbridge_dsp_process_planar(
        engine,
        silence.data(), silence.data(),
        left.data(), right.data(),
        static_cast<uint32_t>(silence.size())
    );
    for (size_t i = 0; i < left.size(); i++) {
        ASSERT_EQ(left[i], 0.0f);
        ASSERT_EQ(right[i], 0.0f);
    }

    soundbridge_dsp_destroy(engine);
    PASS();
}

// Review finding R4.
//
// A preset whose target coefficients equal the applied baseline must still be
// applied, because "a preset is a new baseline" includes cancelling the ramp in
// flight. A publish that coalesces into the same pending snapshot (latest wins)
// must not erase that. Equality-skipping is only valid for smoothed updates.
TEST(engine_preset_snap_survives_a_coalesced_publish) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    // Start far from the target so the mid-ramp coefficients stay measurably
    // away from it.
    soundbridge_preset_t preset = single_band_preset(-12.0f);
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), -12.0, 0.3);

    // A smoothed update towards +12 dB: the applied baseline now records the
    // +12 dB coefficients while the filter is still near -12 dB.
    soundbridge_dsp_update_band_gain(engine, 0, 12.0f);
    (void)measure_block_gain_db(engine, 64);   // ~13 % of the 10 ms ramp

    // A preset with the same target, then a preamp update that coalesces into
    // the same pending snapshot.
    preset = single_band_preset(12.0f);
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_update_preamp(engine, 0.0f);

    // The next block must have snapped: the corrected implementation measures
    // 11.4 dB here (the block includes the coefficient step's short settling
    // transient). Without the fix the ramp kept running and it measured 7.8 dB.
    ASSERT_NEAR(measure_block_gain_db(engine, 256), 12.0, 1.5);

    // Ordinary updates still ramp rather than snap: a 12 dB change is not
    // allowed to arrive in the first block.
    soundbridge_dsp_update_band_gain(engine, 0, 0.0f);
    ASSERT(measure_block_gain_db(engine, 64) > 6.0);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// F-02, producer side.
//
// The render callback used to publish its EQ change by calling eleven blocking
// setters: ten update_band_gain() and one update_preamp(), each taking the
// publisher token with a spin loop. A control thread preempted inside its own
// publish would stall the callback for as long as the scheduler kept it
// off-CPU, which contradicts the callback's documented "no blocking wait".
//
// soundbridge_dsp_try_update_eq() is the bounded replacement: one token
// attempt, one publish, no retry. This test covers the value path.
TEST(engine_try_update_eq_publishes_the_whole_batch) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset = single_band_preset(0.0f);
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 0.0, 0.2);

    float gains[SOUNDBRIDGE_MAX_BANDS] = {};
    gains[0] = 12.0f;

    ASSERT(soundbridge_dsp_try_update_eq(engine, gains, 0.0f));
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 12.0, 0.3);

    // The preamp travels in the same publish, not in a second one.
    ASSERT(soundbridge_dsp_try_update_eq(engine, gains, -6.0f));
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 6.0, 0.3);

    // A non-finite band gain keeps that band's last valid value, exactly like
    // the per-band setter; it neither refuses the batch nor poisons it.
    gains[0] = std::numeric_limits<float>::quiet_NaN();
    ASSERT(soundbridge_dsp_try_update_eq(engine, gains, -6.0f));
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 6.0, 0.3);

    // A batch never widens or narrows the active band count.
    soundbridge_preset_t applied;
    soundbridge_dsp_get_preset(engine, &applied);
    ASSERT_EQ(applied.num_bands, 1u);

    soundbridge_dsp_destroy(engine);
    PASS();
}

// F-02, producer side: the refusal path.
//
// The seam holds the engine's token, so "a peer is publishing right now" is a
// real state rather than a race the test hopes to hit. The attempt must return
// false immediately and change nothing; the retry the caller makes on its next
// block must then succeed. If the implementation ever went back to a blocking
// acquisition this test would hang instead of failing - a louder outcome than a
// flaky one, which is why the seam is used at all.
TEST(engine_try_update_eq_is_refused_while_a_peer_holds_the_token) {
    auto* engine = soundbridge_dsp_create(48000);
    ASSERT(engine != nullptr);

    soundbridge_preset_t preset = single_band_preset(0.0f);
    ASSERT_EQ(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK);
    soundbridge_dsp_set_bypass(engine, false);
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 0.0, 0.2);

    float gains[SOUNDBRIDGE_MAX_BANDS] = {};
    gains[0] = 12.0f;

    soundbridge::test_support::hold_publisher_token(engine);
    const bool published = soundbridge_dsp_try_update_eq(engine, gains, 0.0f);
    soundbridge::test_support::release_publisher_token(engine);

    ASSERT(!published);

    // The refused attempt published nothing: the engine is still at 0 dB.
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 0.0, 0.2);

    // Next block's retry succeeds.
    ASSERT(soundbridge_dsp_try_update_eq(engine, gains, 0.0f));
    ASSERT_NEAR(measure_engine_gain_db(engine, 1000.0f, 48000.0f), 12.0, 0.3);

    // A missing argument is a refusal, not a crash.
    ASSERT(!soundbridge_dsp_try_update_eq(nullptr, gains, 0.0f));
    ASSERT(!soundbridge_dsp_try_update_eq(engine, nullptr, 0.0f));

    soundbridge_dsp_destroy(engine);
    PASS();
}
