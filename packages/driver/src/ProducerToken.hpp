// Producer owner token generation (Batch 2, hardened in the Batch 2 Closure Review).
//
// A mapping incarnation accepts exactly one producer owner. The token is the
// identity a driver handler claims with, and it must be:
//   - stable for the whole life of one handler, so Stop -> Start re-claims the
//     same slot idempotently instead of creating a second producer;
//   - different for every handler instance and every driver process;
//   - never zero, because 0 is the "no owner" sentinel in the shared header;
//   - not derived from anything two processes can predict or share
//     deterministically (a per-process counter or a fixed uid cannot do that).
//
// The previous revision packed `(uid << 32) | (boot_nonce + counter | 1)`. That
// left only ~31 bits of real entropy in the low half (arc4random32 plus a
// counter, then `| 1` forced bit 0), and inside one boot the pair
// (uid, counter) made the token deterministic. The uid does not need to be
// re-encoded here: the mapping path already carries it
// (/tmp/soundbridge-<uid>-<device>) and OpenSharedMemory() refuses a file whose
// st_uid differs from the driver's owner uid, so two users can never contend
// for the same mapping in the first place.
//
// This lives in its own header (rather than in Plugin.cpp's anonymous
// namespace) so the closure-review tests can exercise the real generator.

#pragma once

#include <cstddef>
#include <cstdint>
#include <stdlib.h>  // arc4random_buf

namespace soundbridge {

// Randomness source, injectable so tests can drive the failure path. The default
// is arc4random_buf: the Darwin CSPRNG, which never fails and never blocks.
using ProducerTokenRandomSource = void (*)(void* buffer, size_t size);

inline void DefaultProducerTokenRandomSource(void* buffer, size_t size) {
    arc4random_buf(buffer, size);
}

// Returns a non-zero 64-bit token, or 0 if the source could not produce one
// within a bounded number of attempts. 0 is a failure result, not a token:
// callers must refuse to claim with it rather than fall back to a fixed value.
inline uint64_t GenerateProducerOwnerToken(
    ProducerTokenRandomSource source = DefaultProducerTokenRandomSource)
{
    constexpr int kMaxAttempts = 8;
    for (int attempt = 0; attempt < kMaxAttempts; ++attempt) {
        uint64_t token = 0;
        source(&token, sizeof(token));
        if (token != 0) {
            return token;
        }
    }
    return 0;
}

}  // namespace soundbridge
