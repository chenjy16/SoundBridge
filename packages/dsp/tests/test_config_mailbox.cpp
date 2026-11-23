/**
 * @file test_config_mailbox.cpp
 * @brief Tests for the configuration mailbox (audit findings F-02 - F-05)
 *
 * The mailbox is the only place where two threads touch the same memory in the
 * whole engine, so it gets its own tests: delivery, latest-wins coalescing, and
 * - the one that matters - that a consumer can never observe a *mixture* of two
 * configurations.
 *
 * The tearing tests work by deriving every field of an EngineConfig from a
 * single tag. A snapshot that mixed a newer write with an older one would fail
 * the cross-check between the tag recovered from one field and the rest.
 */

#include "test_utils.h"
#include "config_mailbox.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <thread>
#include <vector>

using namespace soundbridge;

namespace {

/// Every field is a deterministic function of `tag`.
void fill_config(EngineConfig& config, uint32_t tag) {
    config.sample_rate = 48000u + (tag % 1000u);
    config.smooth_bands = tag & 0x3FFu;
    config.snap_all_bands = (tag & 1u) != 0;

    config.preset.num_bands = SOUNDBRIDGE_MAX_BANDS;
    config.preset.preamp_db = static_cast<float>(tag % 1000u);
    config.preset.limiter_enabled = (tag % 3u) != 0;
    config.preset.limiter_threshold_db = -static_cast<float>(tag % 7u);

    // 64 bytes spread across the struct: a torn copy shows two different tags.
    for (size_t i = 0; i < sizeof(config.preset.name); i++) {
        config.preset.name[i] = static_cast<char>('a' + ((tag + i) % 26u));
    }

    for (uint32_t i = 0; i < SOUNDBRIDGE_MAX_BANDS; i++) {
        config.preset.bands[i].gain_db = static_cast<float>(tag * 10u + i);
        config.preset.bands[i].q_factor = static_cast<float>(tag % 97u);
        config.coeffs[i].b0 = static_cast<float>(tag);
        config.coeffs[i].b1 = 1.0f;
        config.coeffs[i].b2 = 2.0f;
        config.coeffs[i].a1 = 3.0f;
        config.coeffs[i].a2 = 4.0f;
    }
}

/// The tag the snapshot claims, recovered from a field on its own.
uint32_t tag_of(const EngineConfig& config) {
    return static_cast<uint32_t>(config.coeffs[0].b0);
}

/// True when every field agrees with `tag`; false means the copy was torn.
bool config_matches_tag(const EngineConfig& config, uint32_t tag) {
    if (config.sample_rate != 48000u + (tag % 1000u)) return false;
    if (config.smooth_bands != (tag & 0x3FFu)) return false;
    if (config.snap_all_bands != ((tag & 1u) != 0)) return false;
    if (config.preset.num_bands != SOUNDBRIDGE_MAX_BANDS) return false;
    if (config.preset.preamp_db != static_cast<float>(tag % 1000u)) return false;
    if (config.preset.limiter_enabled != ((tag % 3u) != 0)) return false;
    if (config.preset.limiter_threshold_db != -static_cast<float>(tag % 7u)) return false;

    for (size_t i = 0; i < sizeof(config.preset.name); i++) {
        if (config.preset.name[i] != static_cast<char>('a' + ((tag + i) % 26u))) {
            return false;
        }
    }

    for (uint32_t i = 0; i < SOUNDBRIDGE_MAX_BANDS; i++) {
        if (config.preset.bands[i].gain_db != static_cast<float>(tag * 10u + i)) return false;
        if (config.preset.bands[i].q_factor != static_cast<float>(tag % 97u)) return false;
        if (config.coeffs[i].b0 != static_cast<float>(tag)) return false;
        if (config.coeffs[i].b1 != 1.0f || config.coeffs[i].b2 != 2.0f) return false;
        if (config.coeffs[i].a1 != 3.0f || config.coeffs[i].a2 != 4.0f) return false;
    }

    return true;
}

} // namespace

TEST(config_mailbox_starts_empty) {
    ConfigMailbox mailbox;
    EngineConfig out;

    ASSERT(!mailbox.consume(out));

    PASS();
}

TEST(config_mailbox_delivers_a_published_configuration) {
    ConfigMailbox mailbox;
    EngineConfig config;
    fill_config(config, 7);
    mailbox.publish(config);

    EngineConfig out;
    ASSERT(mailbox.consume(out));
    ASSERT(config_matches_tag(out, 7));

    // Only one configuration was pending; the second consume has nothing.
    ASSERT(!mailbox.consume(out));

    PASS();
}

// A newer publish displaces a pending one: the mailbox holds one configuration
// and never grows, so "full" is not a state it can be in.
TEST(config_mailbox_coalesces_to_the_newest_pending_configuration) {
    ConfigMailbox mailbox;
    EngineConfig config;
    EngineConfig out;

    fill_config(config, 1);
    mailbox.publish(config);
    ASSERT(mailbox.consume(out));
    ASSERT(config_matches_tag(out, 1));

    for (uint32_t tag = 2; tag <= 6; tag++) {
        fill_config(config, tag);
        mailbox.publish(config);
    }

    ASSERT(mailbox.consume(out));
    ASSERT(config_matches_tag(out, 6));   // 2..5 were superseded, not queued
    ASSERT(!mailbox.consume(out));

    PASS();
}

TEST(config_mailbox_survives_sustained_saturation) {
    ConfigMailbox mailbox;
    EngineConfig config;

    for (uint32_t tag = 0; tag < 50000; tag++) {
        fill_config(config, tag);
        mailbox.publish(config);
    }

    EngineConfig out;
    ASSERT(mailbox.consume(out));
    ASSERT(config_matches_tag(out, 49999));   // the newest survives all 50k
    ASSERT(!mailbox.consume(out));

    PASS();
}

// Single producer, single consumer, both spinning as fast as they can.
//
// Every consumed snapshot must be internally consistent, and the last one
// consumed must be the last one published: the mailbox must never leave the
// consumer holding a stale configuration after the producer has stopped.
//
// Tags stop at 1e6 because the tag is round-tripped through a float field; above
// 2^24 a float can no longer represent every integer and the tag would stop
// being recoverable (that ceiling is a property of the test's encoding, not of
// the mailbox).
TEST(config_mailbox_never_tears_a_snapshot) {
    constexpr uint32_t kTagLimit = 1000000;

    ConfigMailbox mailbox;
    std::atomic<bool> stop_requested{false};
    std::atomic<bool> producer_done{false};
    std::atomic<uint32_t> published{0};

    std::thread producer([&] {
        uint32_t tag = 0;
        while (!stop_requested.load(std::memory_order_relaxed) && tag < kTagLimit) {
            EngineConfig config;
            fill_config(config, tag);
            mailbox.publish(config);
            tag++;
        }
        published.store(tag, std::memory_order_release);
        producer_done.store(true, std::memory_order_release);
    });

    bool all_whole = true;
    uint32_t consumed = 0;
    uint32_t last_tag = 0;

    EngineConfig out;
    while (!producer_done.load(std::memory_order_acquire)) {
        if (!mailbox.consume(out)) continue;
        const uint32_t tag = tag_of(out);
        if (!config_matches_tag(out, tag)) {
            std::cerr << "torn snapshot: recovered tag " << tag << std::endl;
            all_whole = false;
            stop_requested.store(true);
            break;
        }
        last_tag = tag;
        consumed++;
    }
    producer.join();

    if (all_whole) {
        while (mailbox.consume(out)) {
            const uint32_t tag = tag_of(out);
            if (!config_matches_tag(out, tag)) {
                std::cerr << "torn snapshot (drain): recovered tag " << tag << std::endl;
                all_whole = false;
                break;
            }
            last_tag = tag;
            consumed++;
        }
    }

    ASSERT(all_whole);
    ASSERT(consumed > 0);
    ASSERT_EQ(last_tag, published.load() - 1u);

    PASS();
}

// Many producers, one consumer, which is the shape the public API promises:
// "parameter updates are thread safe, callable from any thread". The engine
// serializes publishers with PublisherToken; this is that arrangement.
TEST(config_mailbox_multi_producer_keeps_every_snapshot_whole) {
    constexpr uint32_t kProducers = 4;
    constexpr uint32_t kPerProducer = 20000;

    ConfigMailbox mailbox;
    PublisherToken token;
    std::vector<std::thread> producers;
    producers.reserve(kProducers);

    for (uint32_t producer = 0; producer < kProducers; producer++) {
        producers.emplace_back([&, producer] {
            for (uint32_t n = 0; n < kPerProducer; n++) {
                EngineConfig config;
                fill_config(config, producer + n * kProducers);

                PublisherLock lock(token);
                mailbox.publish(config);
            }
        });
    }

    bool all_whole = true;
    uint32_t consumed = 0;

    // Consume while the producers run, then drain after they are joined.
    for (uint32_t round = 0; round < 20000; round++) {
        EngineConfig out;
        if (!mailbox.consume(out)) continue;
        const uint32_t tag = tag_of(out);
        if (!config_matches_tag(out, tag)) {
            all_whole = false;
            break;
        }
        consumed++;
    }

    for (auto& producer : producers) {
        producer.join();
    }

    if (all_whole) {
        EngineConfig out;
        while (mailbox.consume(out)) {
            const uint32_t tag = tag_of(out);
            if (!config_matches_tag(out, tag)) {
                all_whole = false;
                break;
            }
            consumed++;
        }
    }

    ASSERT(all_whole);
    ASSERT(consumed > 0);

    PASS();
}

// The triple buffer's whole safety argument is that the three slot indices are
// always distinct. Run a long publish/consume alternation and check that the
// consumer's view keeps changing (i.e. publishes are not being written into the
// slot it is about to read) and stays whole.
TEST(config_mailbox_indices_stay_distinct_over_time) {
    ConfigMailbox mailbox;
    EngineConfig config;
    EngineConfig out;

    uint32_t expected_next = 0;
    for (uint32_t step = 0; step < 100000; step++) {
        fill_config(config, step);
        mailbox.publish(config);

        ASSERT(mailbox.consume(out));
        ASSERT(config_matches_tag(out, step));
        ASSERT_EQ(tag_of(out), step);
        expected_next = step + 1;
    }

    ASSERT_EQ(expected_next, 100000u);

    PASS();
}

// ---------------------------------------------------------------------------
// Consumer bounded-work semantics (review finding R3)
// ---------------------------------------------------------------------------

namespace soundbridge {

/// Test-only view of the mailbox's ownership word and single-attempt entry
/// point. ConfigMailbox declares this a friend; the engine never uses it.
struct ConfigMailboxTestAccess {
    static uint32_t state_of(const ConfigMailbox& mailbox) {
        return mailbox.state_.load(std::memory_order_acquire);
    }

    static bool has_pending(const ConfigMailbox& mailbox) {
        return (state_of(mailbox) & config_mailbox_detail::kHasNew) != 0;
    }

    /// The consumer's one ownership attempt, started from an `expected` state
    /// word that a publisher has already invalidated - the execution a real
    /// consumer hits when a publish lands between its load and its exchange.
    static bool attempt_from(
        ConfigMailbox& mailbox,
        EngineConfig& out,
        uint32_t expected
    ) {
        return mailbox.try_consume(out, expected);
    }
};

} // namespace soundbridge

// The consumer makes one bounded attempt. When that attempt loses the race it
// must return false without touching `out`, without clearing the pending flag,
// and the next block boundary must collect the publication. A retry loop inside
// the call would instead let a hot producer keep the audio thread spinning.
TEST(config_mailbox_failed_attempt_leaves_the_update_pending) {
    ConfigMailbox mailbox;
    EngineConfig config;
    fill_config(config, 11);
    mailbox.publish(config);

    // The state word a consumer would have loaded a moment ago.
    uint32_t stale_state = ConfigMailboxTestAccess::state_of(mailbox);

    // A producer lands in between: tag 12 is now the pending publication.
    fill_config(config, 12);
    mailbox.publish(config);

    // The attempt from the stale word loses the exchange.
    EngineConfig out;
    fill_config(out, 999);   // sentinel: a failed attempt must not write `out`
    ASSERT(!ConfigMailboxTestAccess::attempt_from(mailbox, out, stale_state));
    ASSERT_EQ(tag_of(out), 999u);

    // The publication is still pending, untouched.
    ASSERT(ConfigMailboxTestAccess::has_pending(mailbox));

    // And the next block boundary collects it, exactly once.
    ASSERT(mailbox.consume(out));
    ASSERT(config_matches_tag(out, 12));
    ASSERT(!ConfigMailboxTestAccess::has_pending(mailbox));
    ASSERT(!mailbox.consume(out));

    PASS();
}

// Nothing pending is a false return as well, and it must not depend on an
// exchange having been attempted (a mailbox that spun on an empty state word
// would still be wrong).
TEST(config_mailbox_empty_state_is_a_false_return) {
    ConfigMailbox mailbox;
    EngineConfig out;

    ASSERT(!ConfigMailboxTestAccess::has_pending(mailbox));
    ASSERT(!mailbox.consume(out));

    // An attempt from a state word without the pending flag is also a false
    // return, not a read of an unpublished slot.
    fill_config(out, 77);
    ASSERT(!ConfigMailboxTestAccess::attempt_from(
        mailbox, out, ConfigMailboxTestAccess::state_of(mailbox)));
    ASSERT_EQ(tag_of(out), 77u);

    PASS();
}

// The publisher token's bounded form, which is what the audio-thread publish
// path uses. One attempt: it is refused rather than queued behind the holder,
// and a refused attempt must not release a token it never took.
TEST(publisher_token_try_lock_is_bounded_and_exclusive) {
    PublisherToken token;

    ASSERT(token.tryLock());
    ASSERT(!token.tryLock());   // held: refused, not waited for
    token.unlock();

    // Released: the next attempt succeeds, and the failed attempt above did not
    // leave anything behind.
    ASSERT(token.tryLock());
    token.unlock();

    // A refused RAII holder "unlocks" nothing: the peer's section stays intact.
    {
        PublisherLock peer(token);
        PublisherTryLock refused(token);
        ASSERT(!refused.locked());
    }
    ASSERT(token.tryLock());
    token.unlock();

    // A granted RAII holder does release.
    {
        PublisherTryLock granted(token);
        ASSERT(granted.locked());
    }
    ASSERT(token.tryLock());
    token.unlock();

    PASS();
}
