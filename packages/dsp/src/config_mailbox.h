/**
 * @file config_mailbox.h
 * @brief Bounded, lock-free hand-off of one complete engine configuration.
 *
 * Why this file exists (audit findings F-02 through F-05)
 * -----------------------------------------------------
 * Every parameter of the engine used to be written straight into the same
 * struct the audio thread was reading: `apply_preset()` copied a preset into
 * `current_preset` while `process_*()` walked the band list, `set_sample_rate()`
 * rewrote `sample_rate` (and every coefficient computed from it) under a running
 * callback, and the limiter threshold was read per sample from a field the
 * control thread could change. None of those are torn-free, and a torn read is
 * not a "rare glitch": a half-updated band table is a different filter with a
 * different response, and a threshold read between two writes can be a value
 * that was never a legal threshold.
 *
 * The replacement is the shape an audio engine is supposed to have:
 *
 *   control thread(s)                     audio thread
 *   ----------------                      ------------
 *   build a COMPLETE config  --mailbox--> take the newest config at a block
 *   (validate, compute coeffs)            boundary, then own it exclusively
 *
 * Ownership after the hand-off is total: everything the audio thread mutates
 * (biquad coefficients and interpolation state, the smoother, the limiter
 * runtime threshold, the DC blocker, the applied preset) is private to it.
 * Nothing outside `process_*()` writes those fields, and the audio thread never
 * writes anything a control thread reads except the atomics in the engine
 * (`frames_processed`, the peak meters, `applied_sample_rate`, ...).
 *
 * The queue is the classic *triple buffer*: three slots and a single atomic
 * word holding front/middle/back at two bits each plus a "new data" flag. The
 * three indices are always a permutation of {0,1,2}, so:
 *   - the producer writes into `back`, which is never `front`;
 *   - the consumer reads `front`, which is never `back`;
 *   - no slot is ever written while it is being read.
 * That invariant is what a two-buffer + generation counter cannot give you: with
 * two slots the producer has no place to write while the consumer reads, so it
 * either blocks, overwrites the buffer under the reader's feet, or relies on a
 * check-then-read race that the generation counter cannot close.
 *
 * Defined behaviours
 * ------------------
 * - **Updates faster than consumption**: the mailbox holds exactly one pending
 *   config. A newer publish displaces the pending one (latest wins), so nothing
 *   queues up and nothing grows. Configs are absolute snapshots, never deltas,
 *   so skipping intermediates loses no information.
 * - **"Mailbox full"**: cannot happen. There is no queue depth to exceed, no
 *   allocation and no back-pressure on either side.
 * - **Consumer is bounded, not merely lock-free**: `consume()` performs one
 *   load and at most one compare-exchange. If that exchange fails - a producer
 *   published between the load and the exchange - the block keeps the
 *   configuration it already has and the pending publication is retried at the
 *   next block boundary. The audio thread never spins, so the work it does at a
 *   block boundary does not depend on what the control threads are doing.
 *   Lock-freedom alone would not give that: a loop that retries on failure can
 *   be kept failing indefinitely by a publisher that keeps winning.
 * - **Producer**: serialized by PublisherToken (see below), one bounded POD copy
 *   and one compare-exchange. No allocation, no syscall, no I/O.
 * - **Per-block consistency**: `process_*()` consumes once, at the top of the
 *   block, and everything a block reads afterwards (band parameters, band count,
 *   preamp, limiter settings, sample rate) comes from that one snapshot. A
 *   publish that lands mid-block is simply not seen until the next boundary, so
 *   a block cannot mix two configurations. Nothing in the render loop re-reads
 *   the mailbox, and the consumer copies into its own state before the first
 *   sample, so the "whole block" property follows from the shape of the call
 *   rather than from any additional synchronisation.
 *
 * Single producer or many?
 * ------------------------
 * The mailbox itself is single-producer: two producers writing "the back slot"
 * at once would both write the same slot. The public API, however, promises that
 * parameter updates may be called "from any thread", so the engine serializes
 * publishers with PublisherToken instead of quietly redefining the contract as
 * SPSC. The token is held across one copy of a ~500 byte POD; a producer that
 * arrives while another is inside waits for that copy, and nothing else.
 *
 * When the audio thread is itself a publisher (the Host's render callback
 * stages EQ changes from the shared-memory snapshot before it processes), it
 * must not take the blocking form of the token: `lock()` spins until the peer
 * finishes, and a control thread preempted inside its critical section would
 * stall the callback for as long as the scheduler keeps it off-CPU. That is a
 * property of the token, not of the copy, so the "bounded by one POD copy"
 * reasoning does not apply to it.
 *
 * The bounded form is `tryLock()`: one compare-exchange, no loop. It is what
 * `soundbridge_dsp_try_update_eq()` uses, which is the entry point the Host's
 * render callback calls. A failed attempt means a control-thread publisher is
 * inside `publish()` right now; the callback keeps the configuration it already
 * has and retries with the next block's snapshot, so the audio thread never
 * waits for another thread to be scheduled.
 *
 * A strictly wait-free producer path would still need per-producer slots. No
 * caller needs that: the audio thread is now bounded, and control threads are
 * allowed to wait.
 */

#ifndef SOUNDBRIDGE_CONFIG_MAILBOX_H
#define SOUNDBRIDGE_CONFIG_MAILBOX_H

#include "soundbridge_types.h"
#include "biquad.h"

#include <atomic>
#include <cstdint>
#include <thread>

namespace soundbridge {

/**
 * @brief A complete, self-contained engine configuration.
 *
 * Carries *derived* data on purpose: the biquad coefficients are computed by the
 * publisher, at the sample rate carried in the same struct. That is what makes
 * the hand-off atomic in the only sense that matters - the audio thread can
 * never mix coefficients computed for one rate with a rate field from another
 * update, because it never computes them.
 */
struct EngineConfig {
    /** Requested preset (band table, preamp, limiter, active band count). */
    soundbridge_preset_t preset;

    /**
     * Coefficients for every band slot, computed at `sample_rate`.
     *
     * A disabled band's entry is the identity (passthrough): the band is not
     * processed, and keeping its coefficients flat means enabling it later
     * cannot resurrect whatever response it happened to carry before.
     */
    BiquadCoeffs coeffs[SOUNDBRIDGE_MAX_BANDS];

    /** Sample rate this configuration - and therefore `coeffs` - is valid at. */
    uint32_t sample_rate = 48000;

    /** Bit i set: band i changed and should be ramped, not snapped. */
    uint32_t smooth_bands = 0;

    /**
     * Recompute every band without ramping, cancelling any ramp in flight.
     *
     * Set by a preset application (a preset is a new baseline, not a nudge) and
     * by nothing else; `sample_rate` changes force a snap on their own.
     */
    bool snap_all_bands = false;

    void set_smooth(uint32_t band) {
        if (band < SOUNDBRIDGE_MAX_BANDS) smooth_bands |= (1u << band);
    }
    bool is_smooth(uint32_t band) const {
        return band < SOUNDBRIDGE_MAX_BANDS && ((smooth_bands >> band) & 1u) != 0;
    }
    void clear_smoothing() { smooth_bands = 0; }
};

namespace config_mailbox_detail {

constexpr uint32_t kSlotMask = 0x3u;
constexpr uint32_t kMiddleShift = 2;
constexpr uint32_t kBackShift = 4;
constexpr uint32_t kHasNew = 1u << 8;

} // namespace config_mailbox_detail

/**
 * @brief Three-slot, single-consumer mailbox for EngineConfig.
 *
 * See the file header for the ownership and memory-ordering argument. The short
 * version of the ordering: the publisher writes the slot before a release
 * compare-exchange, the consumer reads the slot after an acquire
 * compare-exchange on the same word, so a config is only ever visible whole.
 */
class ConfigMailbox {
public:
    ConfigMailbox() noexcept
        : state_((0u << 0) |
                 (1u << config_mailbox_detail::kMiddleShift) |
                 (2u << config_mailbox_detail::kBackShift)) {}

    ConfigMailbox(const ConfigMailbox&) = delete;
    ConfigMailbox& operator=(const ConfigMailbox&) = delete;

    /**
     * @brief Publish a configuration. Producer side; callers are serialized by
     *        PublisherToken, never by this class.
     *
     * Never blocks and never allocates. If a previous publish has not been
     * consumed yet, that older configuration is dropped: the newest state is
     * the only one worth applying.
     */
    void publish(const EngineConfig& config) noexcept {
        using namespace config_mailbox_detail;

        uint32_t state = state_.load(std::memory_order_acquire);
        for (;;) {
            // The back slot is never the front slot, so this write cannot race
            // with a consumer reading the configuration it is using.
            const uint32_t back = (state >> kBackShift) & kSlotMask;
            slots_[back] = config;

            const uint32_t middle = (state >> kMiddleShift) & kSlotMask;
            const uint32_t front = state & kSlotMask;
            const uint32_t desired = front | (back << kMiddleShift) |
                                    (middle << kBackShift) | kHasNew;

            if (state_.compare_exchange_weak(state, desired,
                                             std::memory_order_acq_rel,
                                             std::memory_order_acquire)) {
                return;
            }
            // A failed exchange reloaded `state`; the slot that is the back slot
            // may be a different one now, so the loop rewrites the config there.
        }
    }

    /**
     * @brief Take the newest published configuration, if any. Consumer side.
     *
     * @param out Receives the configuration when this returns true.
     * @return false when nothing new has been published since the last call, or
     *         when the single ownership attempt lost a race with a producer. In
     *         both cases the audio thread keeps the configuration it already has
     *         and a pending publication stays pending for the next block.
     *
     * Never blocks, never allocates, never spins: one load, at most one
     * compare-exchange. See "Consumer is bounded" in the file header.
     */
    bool consume(EngineConfig& out) noexcept {
        return try_consume(out, state_.load(std::memory_order_acquire));
    }

private:
    /**
     * @brief One ownership attempt, from a caller-supplied state word.
     *
     * `expected` is taken by value, so a failed exchange leaves `state_`
     * exactly as the producer left it: the pending flag and the three indices
     * are unchanged and the publication is retried at the next block boundary.
     */
    bool try_consume(EngineConfig& out, uint32_t expected) noexcept {
        using namespace config_mailbox_detail;

        if ((expected & kHasNew) == 0) return false;

        const uint32_t front = expected & kSlotMask;
        const uint32_t middle = (expected >> kMiddleShift) & kSlotMask;
        const uint32_t back = (expected >> kBackShift) & kSlotMask;

        // Promote middle to front and demote front to middle. The pending flag
        // is cleared by the same exchange, so a publish that lands after this
        // point sets it again.
        const uint32_t desired = middle | (front << kMiddleShift) |
                                (back << kBackShift);

        if (!state_.compare_exchange_strong(expected, desired,
                                            std::memory_order_acq_rel,
                                            std::memory_order_acquire)) {
            return false;
        }

        // `middle` is the front slot as of the exchange. The producer can only
        // write the back slot, so this copy cannot tear.
        out = slots_[middle];
        return true;
    }

    /**
     * Test seam: an attempt started from a state word a publisher has already
     * invalidated is the only way to force the failed-exchange path
     * deterministically. Inspection and tests only; the engine never uses it.
     */
    friend struct ConfigMailboxTestAccess;

    std::atomic<uint32_t> state_;
    EngineConfig slots_[3];
};

/**
 * @brief Serializes control-side publishers; offers a bounded form for audio threads.
 *
 * Deliberately *not* used by the consumer: the audio thread never takes this
 * token when it consumes the mailbox. A caller on an audio thread uses
 * `tryLock()` (via PublisherTryLock), which attempts once and is refused rather
 * than waited on; see the file header for what that does and does not bound.
 */
class PublisherToken {
public:
    /**
     * @brief Blocking acquisition. Control threads only.
     *
     * Spins (with `yield`) until the holder releases. The wait is bounded only
     * by how long the holder's thread is scheduled to run, which is not
     * something this class can bound, so this must not be called from an audio
     * callback.
     */
    void lock() noexcept {
        while (busy_.exchange(true, std::memory_order_acquire)) {
            while (busy_.load(std::memory_order_relaxed)) {
                std::this_thread::yield();
            }
        }
    }

    /**
     * @brief Bounded acquisition: one attempt, no loop. Realtime-safe.
     *
     * @return true when the token was taken; false when a peer holds it, in
     *         which case nothing was acquired and nothing was written.
     */
    bool tryLock() noexcept {
        return !busy_.exchange(true, std::memory_order_acquire);
    }

    void unlock() noexcept { busy_.store(false, std::memory_order_release); }

private:
    std::atomic<bool> busy_{false};
};

/** @brief RAII holder for PublisherToken. */
class PublisherLock {
public:
    explicit PublisherLock(PublisherToken& token) noexcept : token_(token) {
        token_.lock();
    }
    ~PublisherLock() { token_.unlock(); }

    PublisherLock(const PublisherLock&) = delete;
    PublisherLock& operator=(const PublisherLock&) = delete;

private:
    PublisherToken& token_;
};

/**
 * @brief RAII holder for the bounded acquisition path.
 *
 * `locked()` says whether the token was actually taken; the destructor releases
 * it only in that case, so a refused attempt cannot unlock somebody else's
 * critical section.
 */
class PublisherTryLock {
public:
    explicit PublisherTryLock(PublisherToken& token) noexcept
        : token_(token), locked_(token.tryLock()) {}

    ~PublisherTryLock() {
        if (locked_) token_.unlock();
    }

    bool locked() const noexcept { return locked_; }

    PublisherTryLock(const PublisherTryLock&) = delete;
    PublisherTryLock& operator=(const PublisherTryLock&) = delete;

private:
    PublisherToken& token_;
    bool locked_;
};

} // namespace soundbridge

#endif // SOUNDBRIDGE_CONFIG_MAILBOX_H
