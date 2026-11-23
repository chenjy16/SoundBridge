/**
 * @file limiter.h
 * @brief Simple soft limiter to prevent clipping
 */

#ifndef SOUNDBRIDGE_LIMITER_H
#define SOUNDBRIDGE_LIMITER_H

#include <cstdint>
#include <cmath>
#include <algorithm>

namespace soundbridge {

/**
 * @brief soft-knee limiter
 *
 * Uses a rational soft-clipping curve with a smooth knee region.
 *
 * This is not a look-ahead limiter, so it's very low latency but may
 * still clip on very fast transients.
 *
 * Transfer function, with T = threshold and K = 0.8 * T:
 *
 *     |x| <= K   ->  y = x
 *     |x| >  K   ->  y = K + (T - K) * s / (1 + s),  s = (|x| - K) / (T - K)
 *
 * Properties: continuous at the knee (y(K) = K), strictly monotonic, sign
 * symmetric, and bounded by T for every finite input. |y| <= T is enforced
 * explicitly, because evaluating the curve in `float` for very large inputs
 * rounds to just above T (measured +1.2e-8 at |x| = 1e30).
 *
 * Only the threshold is stored. The knee start is derived per sample so a
 * concurrent threshold change can never expose a threshold/knee pair taken
 * from two different configurations.
 */
class SoftLimiter {
public:
    /** Fraction of the threshold at which the knee begins. */
    static constexpr float kKneeRatio = 0.8f;

    /**
     * @brief Initialize limiter
     *
     * @param threshold_db Threshold in dB below 0dBFS (e.g., -0.1)
     */
    void init(float threshold_db = -0.1f) {
        setThreshold(threshold_db);
    }

    /**
     * @brief Set limiter threshold
     *
     * @param threshold_db Threshold in dB (typically -6.0 to 0.0)
     */
    void setThreshold(float threshold_db) {
        threshold_ = std::pow(10.0f, threshold_db / 20.0f);
    }

    /** @brief Currently configured linear threshold. */
    float threshold() const { return threshold_; }

    /** @brief Linear level at which the soft knee begins. */
    float kneeStart() const { return threshold_ * kKneeRatio; }

    /**
     * @brief Process one sample (in-place)
     */
    inline float processSample(float input) {
        const float abs_input = std::abs(input);

        // Protect against NaN/Inf (silence rather than propagate)
        if (!std::isfinite(abs_input)) {
            return 0.0f;
        }

        // The knee is derived from the single threshold field, never stored.
        const float threshold = threshold_;
        const float knee_start = threshold * kKneeRatio;

        // Below knee: pass through
        if (abs_input <= knee_start) {
            return input;
        }

        // Above knee: apply the rational soft-limiting curve in double
        // precision. In `float`, (|x| - K) / (T - K) overflows to +Inf for
        // |x| > ~1.7e38 and the curve then evaluates Inf / (1 + Inf) = NaN —
        // the limiter would return NaN for a *finite* input.
        const double knee = static_cast<double>(knee_start);
        const double width = static_cast<double>(threshold) - knee;
        const double scaled = (static_cast<double>(abs_input) - knee) / width;
        double limited = knee + width * (scaled / (1.0 + scaled));

        // Never let the curve report a level above the configured threshold.
        const double ceiling = static_cast<double>(threshold);
        if (!(limited <= ceiling)) {   // also catches a NaN `limited`
            limited = ceiling;
        }

        const float magnitude = static_cast<float>(limited);

        // Preserve sign
        return (input < 0.0f) ? -magnitude : magnitude;
    }

    /**
     * @brief Process stereo sample (in-place)
     */
    inline void processSampleStereo(float* left, float* right) {
        *left = processSample(*left);
        *right = processSample(*right);
    }

    /**
     * @brief Process buffer (planar stereo)
     */
    void processBuffer(
        float* left, float* right,
        uint32_t num_frames
    ) {
        for (uint32_t i = 0; i < num_frames; ++i) {
            left[i] = processSample(left[i]);
            right[i] = processSample(right[i]);
        }
    }

private:
    // Single source of truth for the limiter configuration; the knee start is
    // derived from it, never stored alongside it.
    float threshold_ = 0.99f;    // ~-0.1 dB
};

/**
 * @brief Hard clipper
 *
 * Just clamps values to [-threshold, +threshold].
 * Can cause harsh distortion but is very fast.
 */
class HardClipper {
public:
    void init(float threshold = 1.0f) {
        threshold_ = threshold;
    }

    inline float processSample(float input) {
        return std::clamp(input, -threshold_, threshold_);
    }

    void processBuffer(float* left, float* right, uint32_t num_frames) {
        for (uint32_t i = 0; i < num_frames; ++i) {
            left[i] = processSample(left[i]);
            right[i] = processSample(right[i]);
        }
    }

private:
    float threshold_ = 1.0f;
};

} // namespace soundbridge

#endif // SOUNDBRIDGE_LIMITER_H
