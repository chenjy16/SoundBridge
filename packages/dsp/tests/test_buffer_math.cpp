/**
 * @file test_buffer_math.cpp
 * @brief Overflow tests for interleaved buffer-size arithmetic
 *
 * Audit finding F-17: `num_frames * 2 * sizeof(float)` is evaluated in
 * `uint32_t` arithmetic, so the product wraps modulo 2^32 for any frame count
 * at or above 2^31. These tests exercise the size computation with synthetic
 * boundary values instead of allocating gigabyte buffers.
 */

#include "test_utils.h"
#include "buffer_math.h"

#include <cstdint>
#include <limits>

using namespace soundbridge;

TEST(buffer_math_copy_bytes_does_not_wrap) {
    ASSERT_EQ(kInterleavedChannels, uint32_t(2));
    ASSERT_EQ(kInterleavedFrameBytes, size_t(8));

    ASSERT_EQ(interleaved_copy_bytes(0), size_t(0));
    ASSERT_EQ(interleaved_copy_bytes(1), size_t(8));
    ASSERT_EQ(interleaved_copy_bytes(4096), size_t(32768));

    // 2^31 frames is exactly where the uint32_t product wraps to zero.
    ASSERT_EQ(interleaved_copy_bytes(0x80000000u), size_t(17179869184ull));

    // One frame less still overflows uint32_t, but must not overflow size_t.
    ASSERT_EQ(interleaved_copy_bytes(0x7FFFFFFFu), size_t(17179869176ull));

    // Largest representable frame count.
    ASSERT_EQ(interleaved_copy_bytes(std::numeric_limits<uint32_t>::max()),
              size_t(34359738360ull));

    PASS();
}

TEST(buffer_math_uint32_fit_predicate) {
    // 8 * 536870911 = 4294967288, one byte below UINT32_MAX.
    ASSERT(interleaved_byte_count_fits_uint32(0));
    ASSERT(interleaved_byte_count_fits_uint32(1));
    ASSERT(interleaved_byte_count_fits_uint32(4096));
    ASSERT(interleaved_byte_count_fits_uint32(536870911u));

    // 8 * 536870912 = 4294967296, one byte above UINT32_MAX.
    ASSERT(!interleaved_byte_count_fits_uint32(536870912u));
    ASSERT(!interleaved_byte_count_fits_uint32(0x80000000u));
    ASSERT(!interleaved_byte_count_fits_uint32(std::numeric_limits<uint32_t>::max()));

    PASS();
}

TEST(buffer_math_wrapping_expression_differs) {
    // Document the defect the helper replaces: the multiply by two happens in
    // uint32_t, so 2^31 frames collapses to a zero-byte copy. Unsigned wrap is
    // well defined, so this is a deterministic check, not undefined behaviour.
    const uint32_t frames = 0x80000000u;
    const size_t wrapping = static_cast<size_t>(frames * 2 * sizeof(float));

    ASSERT_EQ(wrapping, size_t(0));
    ASSERT(interleaved_copy_bytes(frames) != wrapping);

    PASS();
}
