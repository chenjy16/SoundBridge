/**
 * @file test_limiter.cpp
 * @brief Numerical safety tests for the soft limiter
 *
 * These tests pin the contract that made audit findings F-10 / F-11 possible:
 * for every finite input the output is finite and its magnitude never exceeds
 * the configured threshold, not even by one ULP. The curve used to be evaluated
 * in `float`, where (|x| - K) / (T - K) overflows to +Inf for |x| > ~1.7e38 and
 * the result is NaN for a *finite* input; small overshoots also appeared for
 * moderately large inputs because the whole curve was rounded to float.
 */

#include "test_utils.h"
#include "limiter.h"

#include <cmath>
#include <limits>

using namespace soundbridge;

TEST(limiter_passes_normal_audio_unchanged) {
    SoftLimiter limiter;
    limiter.init(-0.1f);

    const float threshold = limiter.threshold();
    ASSERT(threshold > 0.98f && threshold < 1.0f);
    ASSERT(limiter.kneeStart() < threshold);

    // Everything at or below the knee start is a bit-exact passthrough.
    const float below_knee[] = {0.0f, -0.0f, 1e-6f, -1e-6f, 0.1f, -0.1f,
                                0.5f, -0.5f, 0.7f, -0.7f};
    for (float x : below_knee) {
        ASSERT(limiter.processSample(x) == x);
    }

    PASS();
}

TEST(limiter_knee_is_continuous) {
    SoftLimiter limiter;
    limiter.init(-0.1f);

    const float knee = limiter.kneeStart();
    const float threshold = limiter.threshold();

    // Step across the knee by a small relative amount: the curve must stay
    // continuous there, otherwise every sample crossing the knee clicks.
    const float eps = 1e-5f * knee;
    const float below = limiter.processSample(knee - eps);
    const float above = limiter.processSample(knee + eps);

    ASSERT(above >= below);
    ASSERT_NEAR(above - below, 0.0, static_cast<double>(1e-4f * threshold));

    PASS();
}

TEST(limiter_is_monotonic) {
    SoftLimiter limiter;
    limiter.init(-0.1f);

    const int steps = 2000;
    const float max_input = 3.0f * limiter.threshold();
    float previous = 0.0f;

    for (int i = 0; i <= steps; i++) {
        const float x = max_input * static_cast<float>(i) / static_cast<float>(steps);
        const float y = limiter.processSample(x);

        ASSERT(std::isfinite(y));
        ASSERT(y >= previous);
        ASSERT(y <= limiter.threshold());

        previous = y;
    }

    PASS();
}

TEST(limiter_never_exceeds_threshold) {
    SoftLimiter limiter;
    limiter.init(-0.1f);

    const float threshold = limiter.threshold();

    // Normal range up to and past the knee, then the extremes that used to
    // produce NaN through float overflow.
    const float magnitudes[] = {
        0.0f, 0.5f, 0.8f, 0.99f,
        1.0f, 1.0f + 1e-6f, 1.01f, 1.5f, 2.0f, 10.0f,
        1e3f, 1e6f, 1e30f, 1e38f,
        std::numeric_limits<float>::max()
    };

    for (float magnitude : magnitudes) {
        const float positive = limiter.processSample(magnitude);
        const float negative = limiter.processSample(-magnitude);

        ASSERT(std::isfinite(positive));
        ASSERT(std::isfinite(negative));

        // No one-ULP overshoot is permitted.
        ASSERT(std::abs(positive) <= threshold);
        ASSERT(std::abs(negative) <= threshold);

        // Sign symmetry, including for the extremes.
        ASSERT(positive == -negative);
    }

    // A large finite input must be limited, not silently muted: the curve
    // approaches the threshold from below as |x| grows. Inputs just past the
    // knee legitimately sit well under the threshold - a soft knee without
    // makeup gain works that way - so the bound is only meaningful far out.
    const float huge[] = {
        10.0f, 1e3f, 1e6f, 1e30f, 1e38f,
        std::numeric_limits<float>::max()
    };
    for (float magnitude : huge) {
        ASSERT(std::abs(limiter.processSample(magnitude)) > 0.95f * threshold);
    }

    PASS();
}

TEST(limiter_non_finite_returns_silence) {
    SoftLimiter limiter;
    limiter.init(-0.1f);

    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();

    ASSERT(limiter.processSample(nan) == 0.0f);
    ASSERT(limiter.processSample(inf) == 0.0f);
    ASSERT(limiter.processSample(-inf) == 0.0f);

    PASS();
}

TEST(limiter_threshold_change_moves_knee) {
    SoftLimiter limiter;

    // The knee must be derived from the single threshold value rather than
    // stored next to it: a stored pair can be observed half-updated, which is
    // audit finding F-05.
    limiter.setThreshold(-6.0f);
    ASSERT_NEAR(limiter.threshold(), 0.5011872, 1e-6);
    ASSERT_NEAR(limiter.kneeStart(),
                static_cast<double>(limiter.threshold()) * SoftLimiter::kKneeRatio,
                1e-6);

    limiter.setThreshold(0.0f);
    ASSERT_NEAR(limiter.threshold(), 1.0, 1e-6);
    ASSERT_NEAR(limiter.kneeStart(),
                static_cast<double>(limiter.threshold()) * SoftLimiter::kKneeRatio,
                1e-6);

    // And the new threshold is the new bound.
    const float out = limiter.processSample(1e30f);
    ASSERT(std::isfinite(out));
    ASSERT(out <= limiter.threshold());

    PASS();
}

TEST(limiter_process_buffer_is_never_non_finite) {
    SoftLimiter limiter;
    limiter.init(-0.1f);

    const float threshold = limiter.threshold();
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float inf = std::numeric_limits<float>::infinity();

    std::vector<float> left(64);
    std::vector<float> right(64);
    for (size_t i = 0; i < left.size(); i++) {
        left[i] = (i % 7 == 0) ? nan : (i % 5 == 0) ? inf : -inf;
        right[i] = static_cast<float>(i) * 1e34f;
    }
    left[1] = 0.5f;
    right[1] = -0.5f;

    limiter.processBuffer(left.data(), right.data(), static_cast<uint32_t>(left.size()));

    for (size_t i = 0; i < left.size(); i++) {
        ASSERT(std::isfinite(left[i]));
        ASSERT(std::isfinite(right[i]));
        ASSERT(std::abs(left[i]) <= threshold);
        ASSERT(std::abs(right[i]) <= threshold);
    }

    PASS();
}
