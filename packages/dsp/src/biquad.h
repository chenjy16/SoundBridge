/**
 * @file biquad.h
 * @brief Self-contained biquad filter using RBJ cookbook formulas
 */

#ifndef SOUNDBRIDGE_BIQUAD_H
#define SOUNDBRIDGE_BIQUAD_H

#include "soundbridge_types.h"
#include <cmath>
#include <cstring>

namespace soundbridge {

static constexpr float PI = 3.14159265358979323846f;

/**
 * @brief Highest band frequency allowed, as a fraction of the sample rate.
 *
 * 0.45 rather than 0.5 leaves margin before the shelf poles reach z = -1 at
 * fs/2; at 0.5 the coefficients are still finite but critically placed, and at
 * any rate slightly above it the state diverges. See calculateCoeffs().
 */
static constexpr float kMaxNormalisedFrequency = 0.45f;

/**
 * @brief Biquad filter coefficients
 */
struct BiquadCoeffs {
    float b0, b1, b2;  // Numerator coefficients
    float a1, a2;      // Denominator coefficients (a0 is normalized to 1.0)
};

/**
 * @brief Biquad filter state (per channel)
 */
struct BiquadState {
    float z1 = 0.0f;  // Delay line state 1
    float z2 = 0.0f;  // Delay line state 2
};

/**
 * @brief Single biquad filter section
 */
class Biquad {
public:
    /**
     * @brief Initialize filter
     */
    void init() {
        reset();
        setCoeffsFlat();
    }

    /**
     * @brief Clear the delay line only, leaving a coefficient transition in
     *        flight untouched.
     *
     * This is the "the stream restarted" reset. The engine uses it for
     * soundbridge_dsp_reset(): a reset must not cancel a coefficient change
     * whose target has already been recorded in the applied configuration
     * baseline, because the filter would then sit permanently at whatever
     * interpolated coefficient set it happened to hold - the change-detection
     * comparison would see "already at the target" and no later update would
     * put it right.
     */
    void resetHistory() {
        state_left_ = {};
        state_right_ = {};
    }

    /**
     * @brief Full reset: clear the delay line and cancel any coefficient
     *        transition.
     *
     * Used by init() and by anything that deliberately wants to discard the
     * update in flight. A caller that wants the filter to still land on the
     * coefficients it was ramping towards wants resetHistory() instead.
     */
    void reset() {
        resetHistory();
        transition_remaining_ = 0;
    }

    /**
     * @brief Set coefficients to flat response (passthrough)
     */
    void setCoeffsFlat() {
        coeffs_.b0 = 1.0f;
        coeffs_.b1 = 0.0f;
        coeffs_.b2 = 0.0f;
        coeffs_.a1 = 0.0f;
        coeffs_.a2 = 0.0f;
        transition_remaining_ = 0;
    }

    /**
     * @brief Set coefficients from band configuration (instant, no smoothing)
     */
    void setCoeffs(const soundbridge_band_t& band, float sample_rate) {
        setCoeffsInstant(calculateCoeffs(band, sample_rate));
    }

    /**
     * @brief Apply already-computed coefficients instantly, cancelling any ramp.
     *
     * The engine precomputes coefficients on the publishing thread and hands
     * them to the audio thread in one configuration snapshot, so this is the
     * entry point the processing path uses.
     */
    void setCoeffsInstant(const BiquadCoeffs& coeffs) {
        if (isFinite(coeffs)) {
            coeffs_ = coeffs;
        } else {
            setCoeffsFlat();
        }
        transition_remaining_ = 0;
    }

    /**
     * @brief Set coefficients with linear interpolation to prevent zipper noise
     *
     * Linearly interpolates from current coefficients to target over
     * transition_samples. Zero overhead once transition completes.
     *
     * @param band Band configuration
     * @param sample_rate Sample rate in Hz
     * @param transition_samples Number of samples to interpolate over (~10ms)
     */
    void setCoeffsSmooth(const soundbridge_band_t& band, float sample_rate, int transition_samples) {
        rampCoeffsTo(calculateCoeffs(band, sample_rate), transition_samples);
    }

    /**
     * @brief Ramp towards already-computed coefficients.
     *
     * Same interpolation as setCoeffsSmooth(), without the coefficient
     * calculation. A ramp started while another is in flight continues from the
     * interpolated current value, so back-to-back updates stay continuous.
     */
    void rampCoeffsTo(const BiquadCoeffs& target, int transition_samples) {
        if (!isFinite(target)) {
            setCoeffsFlat();
            return;
        }
        target_coeffs_ = target;

        if (transition_samples <= 0) {
            coeffs_ = target_coeffs_;
            transition_remaining_ = 0;
            return;
        }

        const float inv_n = 1.0f / static_cast<float>(transition_samples);
        coeffs_delta_.b0 = (target_coeffs_.b0 - coeffs_.b0) * inv_n;
        coeffs_delta_.b1 = (target_coeffs_.b1 - coeffs_.b1) * inv_n;
        coeffs_delta_.b2 = (target_coeffs_.b2 - coeffs_.b2) * inv_n;
        coeffs_delta_.a1 = (target_coeffs_.a1 - coeffs_.a1) * inv_n;
        coeffs_delta_.a2 = (target_coeffs_.a2 - coeffs_.a2) * inv_n;
        transition_remaining_ = transition_samples;
    }

    /**
     * @brief Coefficients a band would use at @p sample_rate, without touching state.
     *
     * Public so a publisher can build a whole configuration off the audio
     * thread; the result is re-checked by setCoeffsInstant()/rampCoeffsTo().
     */
    static BiquadCoeffs computeCoeffs(const soundbridge_band_t& band, float sample_rate) {
        return calculateCoeffs(band, sample_rate);
    }

    /**
     * @brief Process one sample (stereo)
     */
    inline void processSample(float in_l, float in_r, float* out_l, float* out_r) {
        *out_l = processSampleMono(in_l, state_left_);
        *out_r = processSampleMono(in_r, state_right_);
    }

    /**
     * @brief Process buffer (planar stereo)
     */
    void processBuffer(
        const float* in_l, const float* in_r,
        float* out_l, float* out_r,
        uint32_t num_frames
    ) {
        for (uint32_t i = 0; i < num_frames; i++) {
            out_l[i] = processSampleMono(in_l[i], state_left_);
            out_r[i] = processSampleMono(in_r[i], state_right_);
        }
    }

    /**
     * @brief Check if all coefficients are finite (not NaN or Inf)
     */
    static bool isFinite(const BiquadCoeffs& c) {
        return std::isfinite(c.b0) && std::isfinite(c.b1) && std::isfinite(c.b2)
            && std::isfinite(c.a1) && std::isfinite(c.a2);
    }

private:
    /**
     * @brief Process one sample (mono) using Direct Form 2 Transposed
     *
     * During coefficient transitions, linearly interpolates coefficients
     * per sample to prevent zipper noise. Zero overhead when stable.
     */
    inline float processSampleMono(float input, BiquadState& state) {
        // Interpolate coefficients during transition (branch predicted not-taken when stable)
        if (transition_remaining_ > 0) {
            coeffs_.b0 += coeffs_delta_.b0;
            coeffs_.b1 += coeffs_delta_.b1;
            coeffs_.b2 += coeffs_delta_.b2;
            coeffs_.a1 += coeffs_delta_.a1;
            coeffs_.a2 += coeffs_delta_.a2;
            if (--transition_remaining_ == 0) {
                // Snap to target to prevent float drift
                coeffs_ = target_coeffs_;
            }
        }

        float output = coeffs_.b0 * input + state.z1;
        state.z1 = coeffs_.b1 * input - coeffs_.a1 * output + state.z2;
        state.z2 = coeffs_.b2 * input - coeffs_.a2 * output;

        // Protect against NaN/Inf from filter state blowup.
        //
        // Reset the state so a blown-up section cannot stay blown up, and emit
        // silence rather than the offending input: returning `input` would let a
        // non-finite sample travel through every remaining stage and reach the
        // output buffer untouched, which is the opposite of what this guard is for.
        if (!std::isfinite(output)) {
            state.z1 = 0.0f;
            state.z2 = 0.0f;
            return 0.0f;
        }

        return output;
    }

    /**
     * @brief Calculate biquad coefficients from band parameters
     *
     * Based on Robert Bristow-Johnson cookbook formulas.
     * Uses a bandwidth warp term in the alpha calculation to reduce
     * high-frequency bandwidth cramping.
     * https://www.w3.org/TR/audio-eq-cookbook/
     */
    static BiquadCoeffs calculateCoeffs(const soundbridge_band_t& band, float sample_rate) {
        BiquadCoeffs c;

        // Nyquist guard.
        //
        // preset_validate() only bounds a band to 20 Hz..20 kHz and never looks
        // at the sample rate, so a preset legal at 48 kHz is illegal at 24 kHz:
        // once the normalised frequency reaches pi (f == fs/2) the shelf
        // coefficients put both poles on z = -1, and above it they move outside
        // the unit circle and the filter state diverges exponentially. The
        // per-sample non-finite guard in processSampleMono() only catches the
        // symptom one sample at a time.
        //
        // Clamping here rather than in preset validation is deliberate: every
        // coefficient path (apply_preset, update_band_gain, set_sample_rate)
        // comes through this function, so one clamp covers all of them, and the
        // clamp follows the rate when the rate changes.
        const float rate = (sample_rate > 0.0f) ? sample_rate : 48000.0f;
        const float max_freq = rate * kMaxNormalisedFrequency;
        const float freq = std::fmin(std::fmax(band.frequency_hz, 1.0f), max_freq);
        const float gain_db = band.gain_db;
        const float Q = band.q_factor;

        const float w0 = 2.0f * PI * freq / rate;
        const float cos_w0 = std::cos(w0);
        const float sin_w0 = std::sin(w0);

        // Enhanced bandwidth prewarping for peak filters
        // This compensates for bandwidth cramping at high frequencies
        // Warp factor approaches 1.0 at low frequencies, increases at high frequencies
        const float warp_factor = (w0 < 0.01f) ? 1.0f : w0 / std::sin(w0);
        const float alpha = sin_w0 / (2.0f * Q * warp_factor);

        const float A = std::pow(10.0f, gain_db / 40.0f); // Sqrt of gain

        switch (band.type) {
            case SOUNDBRIDGE_FILTER_PEAK: {
                // Parametric peaking EQ with enhanced bandwidth prewarping
                const float a0 = 1.0f + alpha / A;
                c.b0 = (1.0f + alpha * A) / a0;
                c.b1 = (-2.0f * cos_w0) / a0;
                c.b2 = (1.0f - alpha * A) / a0;
                c.a1 = (-2.0f * cos_w0) / a0;
                c.a2 = (1.0f - alpha / A) / a0;
                break;
            }

            case SOUNDBRIDGE_FILTER_LOW_SHELF: {
                // Low shelf.
                const float beta = std::sqrt(A) / Q;
                const float a0 = (A + 1.0f) + (A - 1.0f) * cos_w0 + beta * sin_w0;

                c.b0 = (A * ((A + 1.0f) - (A - 1.0f) * cos_w0 + beta * sin_w0)) / a0;
                c.b1 = (2.0f * A * ((A - 1.0f) - (A + 1.0f) * cos_w0)) / a0;
                c.b2 = (A * ((A + 1.0f) - (A - 1.0f) * cos_w0 - beta * sin_w0)) / a0;
                c.a1 = (-2.0f * ((A - 1.0f) + (A + 1.0f) * cos_w0)) / a0;
                c.a2 = ((A + 1.0f) + (A - 1.0f) * cos_w0 - beta * sin_w0) / a0;
                break;
            }

            case SOUNDBRIDGE_FILTER_HIGH_SHELF: {
                // High shelf.
                const float beta = std::sqrt(A) / Q;
                const float a0 = (A + 1.0f) - (A - 1.0f) * cos_w0 + beta * sin_w0;

                c.b0 = (A * ((A + 1.0f) + (A - 1.0f) * cos_w0 + beta * sin_w0)) / a0;
                c.b1 = (-2.0f * A * ((A - 1.0f) + (A + 1.0f) * cos_w0)) / a0;
                c.b2 = (A * ((A + 1.0f) + (A - 1.0f) * cos_w0 - beta * sin_w0)) / a0;
                c.a1 = (2.0f * ((A - 1.0f) - (A + 1.0f) * cos_w0)) / a0;
                c.a2 = ((A + 1.0f) - (A - 1.0f) * cos_w0 - beta * sin_w0) / a0;
                break;
            }

            case SOUNDBRIDGE_FILTER_LOW_PASS: {
                // Low-pass filter
                const float a0 = 1.0f + alpha;
                c.b0 = ((1.0f - cos_w0) / 2.0f) / a0;
                c.b1 = (1.0f - cos_w0) / a0;
                c.b2 = ((1.0f - cos_w0) / 2.0f) / a0;
                c.a1 = (-2.0f * cos_w0) / a0;
                c.a2 = (1.0f - alpha) / a0;
                break;
            }

            case SOUNDBRIDGE_FILTER_HIGH_PASS: {
                // High-pass filter
                const float a0 = 1.0f + alpha;
                c.b0 = ((1.0f + cos_w0) / 2.0f) / a0;
                c.b1 = (-(1.0f + cos_w0)) / a0;
                c.b2 = ((1.0f + cos_w0) / 2.0f) / a0;
                c.a1 = (-2.0f * cos_w0) / a0;
                c.a2 = (1.0f - alpha) / a0;
                break;
            }

            case SOUNDBRIDGE_FILTER_NOTCH: {
                // Notch filter
                const float a0 = 1.0f + alpha;
                c.b0 = 1.0f / a0;
                c.b1 = (-2.0f * cos_w0) / a0;
                c.b2 = 1.0f / a0;
                c.a1 = (-2.0f * cos_w0) / a0;
                c.a2 = (1.0f - alpha) / a0;
                break;
            }

            case SOUNDBRIDGE_FILTER_BAND_PASS: {
                // Band-pass filter
                const float a0 = 1.0f + alpha;
                c.b0 = alpha / a0;
                c.b1 = 0.0f;
                c.b2 = -alpha / a0;
                c.a1 = (-2.0f * cos_w0) / a0;
                c.a2 = (1.0f - alpha) / a0;
                break;
            }

            default:
                // Fallback to flat response
                c.b0 = 1.0f;
                c.b1 = 0.0f;
                c.b2 = 0.0f;
                c.a1 = 0.0f;
                c.a2 = 0.0f;
                break;
        }

        return c;
    }

    BiquadCoeffs coeffs_;
    BiquadCoeffs target_coeffs_;
    BiquadCoeffs coeffs_delta_;
    int transition_remaining_ = 0;
    BiquadState state_left_;
    BiquadState state_right_;
};

} // namespace soundbridge

/**
 * @brief Identity coefficients: the band passes its input through unchanged.
 *
 * Also what a disabled band slot carries. Keeping a disabled slot flat - rather
 * than holding the last response it had - means a staging mistake (processing a
 * band whose slot is not enabled) is silent instead of being a filter nobody
 * asked for.
 */
inline soundbridge::BiquadCoeffs flatBiquadCoeffs() {
    soundbridge::BiquadCoeffs c;
    c.b0 = 1.0f;
    c.b1 = 0.0f;
    c.b2 = 0.0f;
    c.a1 = 0.0f;
    c.a2 = 0.0f;
    return c;
}

/**
 * @brief Coefficients for a band slot at @p sample_rate.
 *
 * Disabled bands get the identity; an enabled band whose coefficients came back
 * non-finite gets the identity too, so a configuration is always applicable.
 */
inline soundbridge::BiquadCoeffs bandBiquadCoeffs(
    const soundbridge_band_t& band,
    float sample_rate
) {
    if (!band.enabled) return flatBiquadCoeffs();

    const soundbridge::BiquadCoeffs c = soundbridge::Biquad::computeCoeffs(band, sample_rate);
    return soundbridge::Biquad::isFinite(c) ? c : flatBiquadCoeffs();
}

/** @brief True when two coefficient sets are bit-for-bit equal. */
inline bool biquadCoeffsEqual(
    const soundbridge::BiquadCoeffs& a,
    const soundbridge::BiquadCoeffs& b
) {
    return a.b0 == b.b0 && a.b1 == b.b1 && a.b2 == b.b2
        && a.a1 == b.a1 && a.a2 == b.a2;
}

#endif // SOUNDBRIDGE_BIQUAD_H
