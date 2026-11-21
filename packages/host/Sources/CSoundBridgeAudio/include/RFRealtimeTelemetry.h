/**
 * @file RFRealtimeTelemetry.h
 * @brief Realtime-safe callback latency measurement for the Host process.
 *
 * SCOPE — this header is NOT part of the cross-process shared-memory protocol.
 *
 *   - `RFSharedAudio.h` is the protocol: it is copied byte-for-byte into the
 *     driver, the App and the host, and changing it changes an ABI.
 *   - This file is host-only instrumentation. It is compiled into the Host
 *     alone, it holds process-local heap memory, and nothing here appears in a
 *     mapping. Adding or removing it cannot change the protocol version, the
 *     header size, the driver, or the App.
 *
 * WHY A HISTOGRAM AND NOT MIN/MAX COUNTERS
 *
 *   The audio callback must not allocate, lock, log or retry unboundedly. A
 *   running "min" needs a compare-and-swap loop that gives up or spins, and so
 *   does a "max"; both are retry loops of unbounded length under contention.
 *   A fixed-width histogram costs exactly one `atomic_fetch_add` per
 *   observation, has no retry at all, and still yields min / max / p50 / p95 /
 *   p99 with a known resolution.
 *
 * RESOLUTION
 *
 *   `RF_RT_LATENCY_BUCKET_WIDTH_NS` is 2 microseconds. Bucket `i` covers
 *   `[i*2us, (i+1)*2us)` up to `RF_RT_LATENCY_BUCKET_COUNT` buckets; everything
 *   slower lands in the single overflow bucket. The ceiling is therefore
 *   16.384 ms, which is above the 10.667 ms budget of a 512-frame callback at
 *   48 kHz: an over-budget callback is reported with its real value instead of
 *   saturating. Only a callback slower than 16.384 ms reports as ">= 16.384 ms".
 *
 * THREADING CONTRACT
 *
 *   REALTIME-SAFE (callable from the CoreAudio IO thread):
 *     rf_rt_hist_observe, rf_rt_counters_* note/record calls, rf_rt_gate_enter,
 *     rf_rt_gate_exit
 *
 *   NOT REALTIME-SAFE (control thread only):
 *     every create / destroy / reset / publish / reader, because the readers
 *     walk thousands of counters and the publishers wait for quiescence.
 *
 *   The readers are lock-free with respect to the callback, but they read a
 *   moving target: a percentile is a snapshot of the window since the last
 *   reset, not an atomic view of one instant.
 *
 * MEMORY
 *
 *   One histogram is `(8192 + 1) * 8 + 24 = 65568` bytes, allocated once at
 *   renderer construction and never grown. The counters are 96 bytes and the
 *   gate is 16 bytes.
 */

#ifndef RF_REALTIME_TELEMETRY_H
#define RF_REALTIME_TELEMETRY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Opaque handle. The layout is private to `RFRealtimeTelemetry.c`. */
typedef struct rf_rt_latency_histogram rf_rt_latency_histogram;

/** Bucket width in nanoseconds. 2 microseconds. */
#define RF_RT_LATENCY_BUCKET_WIDTH_NS 2000ULL

/** Number of buckets below the overflow bucket. 8192 * 2 us = 16.384 ms. */
#define RF_RT_LATENCY_BUCKET_COUNT 8192

/** Index of the bucket that collects everything at or above the last bucket. */
#define RF_RT_LATENCY_OVERFLOW_BUCKET RF_RT_LATENCY_BUCKET_COUNT

/** Total bucket slots, including the overflow slot. */
#define RF_RT_LATENCY_SLOT_COUNT (RF_RT_LATENCY_BUCKET_COUNT + 1)

/** Returned by the readers when the histogram holds no observations. */
#define RF_RT_HISTOGRAM_EMPTY 0xFFFFFFFFu

/**
 * @brief Allocate and zero a histogram.
 * @return NULL when allocation fails.
 * @note NOT realtime-safe. Call once, from the control thread, before the
 *       renderer is connected to an audio unit.
 */
rf_rt_latency_histogram* rf_rt_hist_create(void);

/** @brief Free a histogram. NOT realtime-safe; never call with a live callback. */
void rf_rt_hist_destroy(rf_rt_latency_histogram* hist);

/** @brief Clear every counter. NOT realtime-safe. */
void rf_rt_hist_reset(rf_rt_latency_histogram* hist);

/** Bytes one histogram occupies. */
uint64_t rf_rt_histogram_size(void);

/** Non-zero when the platform implements the counters without a lock. */
int rf_rt_histogram_is_lock_free(const rf_rt_latency_histogram* hist);

/** Bucket index a duration of `ns` nanoseconds belongs to. Pure arithmetic. */
uint32_t rf_rt_hist_bucket_for(uint64_t ns);

/**
 * @brief Record one callback duration.
 *
 * REALTIME-SAFE. One relaxed atomic increment on a single bucket, plus two on
 * fixed scalars when the observation is over budget. No allocation, no lock,
 * no retry loop, no syscall, no floating point.
 *
 * `budget_ns == 0` disables the over-budget classification for this call; the
 * refusal paths use it because the mapping's sample rate is not known there.
 */
void rf_rt_hist_observe(rf_rt_latency_histogram* hist, uint64_t ns, uint64_t budget_ns);

/** Total observations since the last reset. Control thread. */
uint64_t rf_rt_hist_observations(const rf_rt_latency_histogram* hist);

/** Observations above their budget. Control thread. */
uint64_t rf_rt_hist_over_budget(const rf_rt_latency_histogram* hist);

/** Summed excess nanoseconds of the over-budget observations. Control thread. */
uint64_t rf_rt_hist_over_budget_excess_ns(const rf_rt_latency_histogram* hist);

/** Count recorded in one bucket. Control thread. */
uint64_t rf_rt_hist_bucket_count(const rf_rt_latency_histogram* hist, uint32_t bucket);

/** Lower bound in nanoseconds of a bucket, or UINT64_MAX for the overflow slot. */
uint64_t rf_rt_hist_bucket_lower_ns(uint32_t bucket);

/** Upper bound in nanoseconds of a bucket, or UINT64_MAX for the overflow slot. */
uint64_t rf_rt_hist_bucket_upper_ns(uint32_t bucket);

/** Lowest non-empty bucket, or RF_RT_HISTOGRAM_EMPTY. Control thread. */
uint32_t rf_rt_hist_first_bucket(const rf_rt_latency_histogram* hist);

/** Highest non-empty bucket, or RF_RT_HISTOGRAM_EMPTY. Control thread. */
uint32_t rf_rt_hist_last_bucket(const rf_rt_latency_histogram* hist);

/**
 * @brief Bucket containing the `percentile_bp`-th percentile (basis points).
 *
 * `percentile_bp` is 0..10000, so 5000 is p50 and 9900 is p99. Returns
 * RF_RT_HISTOGRAM_EMPTY when there are no observations.
 *
 * The answer is a bucket, so the error is at most one bucket width below the
 * last bucket, and unbounded inside the overflow bucket. Callers must report
 * the overflow bucket as ">= 16.384 ms", never as a precise value.
 *
 * NOT realtime-safe: walks up to 8193 atomics.
 */
uint32_t rf_rt_hist_quantile_bucket(const rf_rt_latency_histogram* hist, uint32_t percentile_bp);

/* ======================================================================== */
/* Render-path counters                                                     */
/* ======================================================================== */

/**
 * @brief Per-callback counters that used to live behind an `os_unfair_lock`.
 *
 * The audio callback may not wait on a lock: a control thread holding it can be
 * preempted for an unbounded time, and "the critical section is short" says
 * nothing about how long the waiter waits. Every field here is a C11 atomic, so
 * the note calls are single lock-free read-modify-write instructions with no
 * retry loop and no owner to wait for.
 *
 * The first-pass record needs no compare-and-swap: only the renderer's own
 * callback calls `rf_rt_counters_record_first_pass`, and it does so once
 * (guarded by its own render-thread-local flag), so the writer is unique.
 * Publication order is store-fields-then-flag (release) and the reader is
 * load-flag-then-fields (acquire), which is what makes the reader see a
 * complete record instead of a half-written one.
 */
typedef struct rf_rt_render_counters rf_rt_render_counters;

/** Why the render callback refused to produce audio. */
typedef enum {
    RF_RT_REFUSAL_MEMORY_UNAVAILABLE = 0,
    RF_RT_REFUSAL_CAPACITY_EXCEEDED = 1,
    RF_RT_REFUSAL_CHANNEL_MISMATCH = 2,
    RF_RT_REFUSAL_COUNT = 3
} rf_rt_refusal;

/** One consistent read of the counters. Control thread only. */
typedef struct {
    uint64_t refusals[RF_RT_REFUSAL_COUNT];
    uint64_t underrun_frames;
    uint64_t silence_fallbacks;
    int first_pass_recorded;
    uint32_t first_pass_frames;
    uint32_t first_pass_channels;
    uint32_t first_pass_bytes[4];
} rf_rt_render_snapshot;

/** Allocate zeroed counters. NOT realtime-safe. NULL when allocation fails. */
rf_rt_render_counters* rf_rt_counters_create(void);

/** Free them. NOT realtime-safe; never call with a live callback. */
void rf_rt_counters_destroy(rf_rt_render_counters* counters);

/** Record one refused block. REALTIME-SAFE. */
void rf_rt_counters_note_refusal(rf_rt_render_counters* counters, rf_rt_refusal reason);

/** Add the zero-filled (underrun) frames of one block. REALTIME-SAFE. */
void rf_rt_counters_note_underrun(rf_rt_render_counters* counters, uint32_t frames);

/** Record a silence fallback that was not one of the three refusals. REALTIME-SAFE. */
void rf_rt_counters_note_silence_fallback(rf_rt_render_counters* counters);

/**
 * Record the device's buffer shape, once. REALTIME-SAFE, single writer.
 *
 * `byteCount` is clamped to 4; `bytes` may be NULL when it is 0.
 */
void rf_rt_counters_record_first_pass(
    rf_rt_render_counters* counters, uint32_t frames, uint32_t channels,
    const uint32_t* bytes, uint32_t byteCount);

/** Copy the counters out. Control thread only. */
void rf_rt_counters_read(const rf_rt_render_counters* counters, rf_rt_render_snapshot* out);

/** Non-zero when every counter is lock-free on this platform. */
int rf_rt_counters_is_lock_free(const rf_rt_render_counters* counters);

/* ======================================================================== */
/* Lock-free render gate                                                    */
/* ======================================================================== */

/**
 * @brief What the render callback reads, without a lock on either side.
 *
 * Replaces the `os_unfair_lock` pair the callback used to take on every entry
 * and exit. The callback now performs two lock-free atomics per block (one
 * increment, one decrement) and one load; it never waits for a control thread.
 *
 * PROTOCOL
 *
 *   Reader: `enter` increments `in_flight` and then loads `published`. If that
 *   load is NULL the increment is undone and the caller emits silence.
 *
 *   Publisher (control thread, serialised by its own lock): publishes only when
 *   `in_flight == 0`, in which case the pointer is swapped and the publication
 *   stands. A lease that was already outstanding defers the swap, which is the
 *   semantics the mapping lifecycle depends on (the callback keeps reading the
 *   old mapping until it is quiescent).
 *
 *   The swap is never rolled back. A reader that entered between the check and
 *   the exchange may already hold the previous pointer, and restoring the
 *   pointer would not retract that lease -- the caller would then free a page a
 *   callback is reading. So the previous pointer is retired instead, and the
 *   caller releases it only once `rf_rt_gate_in_flight()` reads 0.
 *
 *   Why this is safe: after the exchange the gate never hands out `previous`
 *   again (it only hands out what `published` holds). A lease counted in that
 *   0 must therefore have been taken before the exchange, and since its exit is
 *   ordered after its own page access, a 0 read means every such reader is
 *   finished. Readers entering later can only reach the new pointer.
 */
typedef struct rf_rt_render_gate rf_rt_render_gate;

/** Allocate a gate with nothing published. NOT realtime-safe. */
rf_rt_render_gate* rf_rt_gate_create(void);

/** Free it. NOT realtime-safe; never call with a live callback. */
void rf_rt_gate_destroy(rf_rt_render_gate* gate);

/**
 * @brief Take a lease and read the published pointer.
 * REALTIME-SAFE. Wait-free apart from the atomic instruction itself.
 */
void* rf_rt_gate_enter(rf_rt_render_gate* gate);

/** Release the lease taken by `enter`. REALTIME-SAFE. */
void rf_rt_gate_exit(rf_rt_render_gate* gate);

/**
 * @brief Publish `next` if the render path is idle.
 * @return 1 when published, 0 when deferred (the published pointer is unchanged
 *         and `next` was never handed out, so the caller still owns it).
 * @note Control thread only. On success the previous pointer may still have
 *       readers: the caller must keep it alive until `rf_rt_gate_in_flight()`
 *       reads 0.
 */
int rf_rt_gate_try_publish(rf_rt_render_gate* gate, void* next);

/**
 * @brief Publish `next` unconditionally, ignoring leases.
 * @note Shutdown only: the caller accepts that a callback may still be inside.
 */
void rf_rt_gate_force_publish(rf_rt_render_gate* gate, void* next);

/** The published pointer. Control thread only. */
void* rf_rt_gate_current(const rf_rt_render_gate* gate);

/** Leases currently held. Control thread only. */
uint64_t rf_rt_gate_in_flight(const rf_rt_render_gate* gate);

/** Non-zero when the gate is lock-free on this platform. */
int rf_rt_gate_is_lock_free(const rf_rt_render_gate* gate);

#ifdef __cplusplus
}
#endif

#endif /* RF_REALTIME_TELEMETRY_H */
