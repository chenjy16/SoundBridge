/**
 * @file buffer_math.h
 * @brief Buffer-size arithmetic that must not overflow.
 */

#ifndef SOUNDBRIDGE_BUFFER_MATH_H
#define SOUNDBRIDGE_BUFFER_MATH_H

#include <cstddef>
#include <cstdint>
#include <limits>

namespace soundbridge {

/** @brief Number of channels in an interleaved stereo buffer. */
constexpr uint32_t kInterleavedChannels = 2;

/** @brief Size in bytes of one interleaved stereo float sample pair. */
constexpr size_t kInterleavedFrameBytes = kInterleavedChannels * sizeof(float);

/**
 * @brief Byte length of `num_frames` interleaved stereo frames.
 *
 * The conversion to `size_t` happens before any multiplication. Written as
 * `num_frames * 2 * sizeof(float)` the product is evaluated in `uint32_t`
 * arithmetic and wraps modulo 2^32 for `num_frames >= 2^31`, silently
 * truncating the copy. That is unreachable for an audio callback, but the
 * expression is shared by every caller of the interleaved path, so it is
 * computed in one place and covered by a boundary test.
 */
inline size_t interleaved_copy_bytes(uint32_t num_frames) {
    return static_cast<size_t>(num_frames) * kInterleavedFrameBytes;
}

/**
 * @brief True when `num_frames` frames fit in a `uint32_t` byte count.
 *
 * Used only by tests and diagnostics; the copy itself is `size_t`-safe.
 */
inline bool interleaved_byte_count_fits_uint32(uint32_t num_frames) {
    return interleaved_copy_bytes(num_frames) <=
           static_cast<size_t>(std::numeric_limits<uint32_t>::max());
}

} // namespace soundbridge

#endif // SOUNDBRIDGE_BUFFER_MATH_H
