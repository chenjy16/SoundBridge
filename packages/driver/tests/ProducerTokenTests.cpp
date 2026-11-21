// Batch 2 Closure Review — producer token identity tests.
//
// Standalone test (like tests/ControlProtocolTests.cpp): no build-system
// integration, compiled with clang++ directly. See the Closure Review
// Test-Report.md for the exact command.
//
// What this does and does not prove:
//   - It proves the generator never yields the 0 sentinel, falls back to 0 (not
//     to a fixed value) when the randomness source is exhausted, uses both
//     halves of the word, and that the protocol treats a re-claim with the same
//     token as idempotent while a different token is refused.
//   - It does NOT prove mathematical uniqueness: 64 random bits give
//     probabilistic separation (~2^-64 per pair), not a deterministic guarantee.

// Include order matters here: libc++ raises "<atomic> is incompatible with
// <stdatomic.h>" when the C++ standard headers are pulled in *after* a C11
// <stdatomic.h>, and RFSharedAudio.h uses `_Atomic` declarations in C++ too.
// The C++ headers must come first.
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <set>
#include <sys/mman.h>

#include "../src/ProducerToken.hpp"
#include "../include/RFSharedAudio.h"

using soundbridge::GenerateProducerOwnerToken;

static void check(bool condition, const char* label) {
    if (!condition) {
        std::cerr << "FAIL: " << label << '\n';
        std::exit(1);
    }
}

// --- injected randomness sources -------------------------------------------

static void SourceAlwaysZero(void* buffer, size_t size) {
    std::memset(buffer, 0, size);
}

static void SourceFixedValue(void* buffer, size_t size) {
    // 0xDEADBEEF0123456789ABCDEF... truncated to size; the low bytes are what
    // matters, the point is that whatever lands in `token` comes back unchanged.
    const uint64_t value = 0x0BADF00DDEADBEEFull;
    std::memcpy(buffer, &value, size < sizeof(value) ? size : sizeof(value));
}

static int g_zeroDrawsRemaining = 0;

static void SourceZeroThenValue(void* buffer, size_t size) {
    if (g_zeroDrawsRemaining > 0) {
        --g_zeroDrawsRemaining;
        std::memset(buffer, 0, size);
        return;
    }
    SourceFixedValue(buffer, size);
}

// --- fixtures --------------------------------------------------------------

static RFSharedAudio* MakeOpenMapping(uint64_t epoch) {
    const size_t size = sizeof(RFSharedAudio) + 8192 * sizeof(float) * 8;
    void* raw = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    check(raw != MAP_FAILED, "anonymous mapping fixture");
    auto* mem = static_cast<RFSharedAudio*>(raw);
    std::memset(mem, 0, size);
    rf_shared_audio_init(mem, 48000, 2, RF_FORMAT_FLOAT32, 8192);
    check(rf_admission_open(mem, epoch) == RF_ADMISSION_OK, "open mapping fixture");
    return mem;
}

int main() {
    // 1. Default (arc4random) source: never the 0 sentinel, and drawn values
    //    differ. Both halves must carry entropy — a regression to
    //    `(uid << 32) | (31 bits)` would fail the low-half check.
    {
        constexpr int kDraws = 1000;
        std::set<uint64_t> seen;
        std::set<uint32_t> highHalves, lowHalves;
        for (int i = 0; i < kDraws; ++i) {
            const uint64_t token = GenerateProducerOwnerToken();
            check(token != 0, "default source returns a non-zero token");
            seen.insert(token);
            highHalves.insert(static_cast<uint32_t>(token >> 32));
            lowHalves.insert(static_cast<uint32_t>(token & 0xFFFFFFFFu));
        }
        check(static_cast<int>(seen.size()) == kDraws,
              "1000 draws produce distinct tokens (probabilistic, ~2^-64 per pair)");
        check(highHalves.size() > 900, "high half carries entropy");
        check(lowHalves.size() > 900, "low half carries entropy");
    }

    // 2. Exhausted source: fail closed with 0, never a fixed fallback token.
    {
        const uint64_t token = GenerateProducerOwnerToken(SourceAlwaysZero);
        check(token == 0, "exhausted randomness yields 0 (fail closed)");
    }

    // 3. A zero draw is retried instead of being accepted or replaced.
    {
        g_zeroDrawsRemaining = 3;
        const uint64_t token = GenerateProducerOwnerToken(SourceZeroThenValue);
        check(token == 0x0BADF00DDEADBEEFull, "zero draws are retried, not substituted");
        check(g_zeroDrawsRemaining == 0, "retry loop consumed the zero draws");
    }

    // 4. Plumbing: the drawn value reaches the caller unchanged.
    {
        check(GenerateProducerOwnerToken(SourceFixedValue) == 0x0BADF00DDEADBEEFull,
              "fixed source is passed through");
    }

    // 5. Protocol level: the same handler's Stop -> Start keeps its identity.
    {
        RFSharedAudio* mem = MakeOpenMapping(0x0102030405060708ull);
        const uint64_t token = GenerateProducerOwnerToken();
        check(token != 0, "handler identity available");
        check(rf_producer_claim(mem, token), "first claim succeeds");
        check(rf_admission_claim_seq(mem) == 1, "first claim counted once");
        check(rf_producer_release(mem, token), "Stop releases the slot");
        check(rf_producer_owner_token(mem) == 0, "released slot is empty");
        check(rf_producer_claim(mem, token), "Start re-claims with the same token");
        check(rf_producer_owner_token(mem) == token, "re-claim restores the same owner");
        check(rf_admission_claim_seq(mem) == 2, "re-claim is a new claim transition");

        // 6. A different handler instance (different token) is refused.
        const uint64_t other = GenerateProducerOwnerToken();
        check(other != 0 && other != token, "second handler has a different identity");
        check(!rf_producer_claim(mem, other), "second handler cannot take the slot");
        check(rf_producer_owner_token(mem) == token, "owner unchanged after refusal");

        // 7. A 0 token is refused explicitly (fail-closed path used by OnStartIO).
        check(!rf_producer_claim(mem, 0), "zero token is refused");

        munmap(mem, sizeof(RFSharedAudio) + 8192 * sizeof(float) * 8);
    }

    std::cout << "Producer token tests passed\n";
    return 0;
}
