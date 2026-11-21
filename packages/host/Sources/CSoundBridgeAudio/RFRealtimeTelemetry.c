/**
 * @file RFRealtimeTelemetry.c
 * @brief Implementation of the Host's realtime callback latency histogram.
 *
 * See `include/RFRealtimeTelemetry.h` for the threading contract. The short
 * version: `rf_rt_hist_observe` is the only function the audio callback may
 * call, and it is one relaxed atomic increment plus two conditional ones.
 *
 * The struct is defined here rather than in the header so Swift sees an opaque
 * handle. Swift has no portable way to lay out C `_Atomic` arrays, and nothing
 * on the Swift side needs to look inside: it allocates the handle once, records
 * through `observe`, and reads aggregates.
 */

#include "RFRealtimeTelemetry.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct rf_rt_latency_histogram {
    /** Observations per bucket; the last slot is the overflow bucket. */
    _Atomic uint64_t buckets[RF_RT_LATENCY_SLOT_COUNT];
    /** Total observations recorded since the last reset. */
    _Atomic uint64_t observations;
    /** Observations whose duration exceeded the caller's per-callback budget. */
    _Atomic uint64_t over_budget;
    /** Summed excess nanoseconds, for a coarse severity gauge. */
    _Atomic uint64_t over_budget_excess_ns;
};

/* No hidden padding: the Swift side allocates nothing itself, but a test pins
   the size so a future field addition cannot silently change the footprint. */
_Static_assert(
    sizeof(struct rf_rt_latency_histogram) == RF_RT_LATENCY_SLOT_COUNT * 8 + 24,
    "rf_rt_latency_histogram must not carry hidden padding");

rf_rt_latency_histogram* rf_rt_hist_create(void) {
    rf_rt_latency_histogram* hist = (rf_rt_latency_histogram*)calloc(
        1, sizeof(struct rf_rt_latency_histogram));
    return hist;
}

void rf_rt_hist_destroy(rf_rt_latency_histogram* hist) {
    free(hist);
}

void rf_rt_hist_reset(rf_rt_latency_histogram* hist) {
    if (hist == NULL) return;
    for (size_t i = 0; i < RF_RT_LATENCY_SLOT_COUNT; i++) {
        atomic_store_explicit(&hist->buckets[i], 0, memory_order_relaxed);
    }
    atomic_store_explicit(&hist->observations, 0, memory_order_relaxed);
    atomic_store_explicit(&hist->over_budget, 0, memory_order_relaxed);
    atomic_store_explicit(&hist->over_budget_excess_ns, 0, memory_order_relaxed);
}

uint64_t rf_rt_histogram_size(void) {
    return (uint64_t)sizeof(struct rf_rt_latency_histogram);
}

int rf_rt_histogram_is_lock_free(const rf_rt_latency_histogram* hist) {
    if (hist == NULL) return 0;
    return atomic_is_lock_free(&hist->buckets[0])
        && atomic_is_lock_free(&hist->observations);
}

uint32_t rf_rt_hist_bucket_for(uint64_t ns) {
    const uint64_t index = ns / RF_RT_LATENCY_BUCKET_WIDTH_NS;
    if (index >= RF_RT_LATENCY_BUCKET_COUNT) return RF_RT_LATENCY_OVERFLOW_BUCKET;
    return (uint32_t)index;
}

void rf_rt_hist_observe(rf_rt_latency_histogram* hist, uint64_t ns, uint64_t budget_ns) {
    if (hist == NULL) return;
    const uint32_t bucket = rf_rt_hist_bucket_for(ns);
    atomic_fetch_add_explicit(&hist->buckets[bucket], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&hist->observations, 1, memory_order_relaxed);
    if (budget_ns != 0 && ns > budget_ns) {
        atomic_fetch_add_explicit(&hist->over_budget, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &hist->over_budget_excess_ns, ns - budget_ns, memory_order_relaxed);
    }
}

uint64_t rf_rt_hist_observations(const rf_rt_latency_histogram* hist) {
    if (hist == NULL) return 0;
    return atomic_load_explicit(
        (_Atomic uint64_t*)&hist->observations, memory_order_relaxed);
}

uint64_t rf_rt_hist_over_budget(const rf_rt_latency_histogram* hist) {
    if (hist == NULL) return 0;
    return atomic_load_explicit(
        (_Atomic uint64_t*)&hist->over_budget, memory_order_relaxed);
}

uint64_t rf_rt_hist_over_budget_excess_ns(const rf_rt_latency_histogram* hist) {
    if (hist == NULL) return 0;
    return atomic_load_explicit(
        (_Atomic uint64_t*)&hist->over_budget_excess_ns, memory_order_relaxed);
}

uint64_t rf_rt_hist_bucket_count(const rf_rt_latency_histogram* hist, uint32_t bucket) {
    if (hist == NULL || bucket >= RF_RT_LATENCY_SLOT_COUNT) return 0;
    return atomic_load_explicit(
        (_Atomic uint64_t*)&hist->buckets[bucket], memory_order_relaxed);
}

uint64_t rf_rt_hist_bucket_lower_ns(uint32_t bucket) {
    if (bucket >= RF_RT_LATENCY_BUCKET_COUNT) return UINT64_MAX;
    return (uint64_t)bucket * RF_RT_LATENCY_BUCKET_WIDTH_NS;
}

uint64_t rf_rt_hist_bucket_upper_ns(uint32_t bucket) {
    if (bucket >= RF_RT_LATENCY_BUCKET_COUNT) return UINT64_MAX;
    return ((uint64_t)bucket + 1) * RF_RT_LATENCY_BUCKET_WIDTH_NS - 1;
}

uint32_t rf_rt_hist_first_bucket(const rf_rt_latency_histogram* hist) {
    if (hist == NULL) return RF_RT_HISTOGRAM_EMPTY;
    for (uint32_t i = 0; i < RF_RT_LATENCY_SLOT_COUNT; i++) {
        if (rf_rt_hist_bucket_count(hist, i) != 0) return i;
    }
    return RF_RT_HISTOGRAM_EMPTY;
}

uint32_t rf_rt_hist_last_bucket(const rf_rt_latency_histogram* hist) {
    if (hist == NULL) return RF_RT_HISTOGRAM_EMPTY;
    for (uint32_t i = RF_RT_LATENCY_SLOT_COUNT; i > 0; i--) {
        if (rf_rt_hist_bucket_count(hist, i - 1) != 0) return i - 1;
    }
    return RF_RT_HISTOGRAM_EMPTY;
}

uint32_t rf_rt_hist_quantile_bucket(const rf_rt_latency_histogram* hist, uint32_t percentile_bp) {
    if (hist == NULL) return RF_RT_HISTOGRAM_EMPTY;
    const uint64_t total = rf_rt_hist_observations(hist);
    if (total == 0) return RF_RT_HISTOGRAM_EMPTY;
    if (percentile_bp > 10000) percentile_bp = 10000;

    /* Rank of the requested percentile, 1-based: the smallest rank whose
       cumulative count reaches it. Integer only, so this is exact. */
    uint64_t rank = ((uint64_t)percentile_bp * total + 9999) / 10000;
    if (rank == 0) rank = 1;

    uint64_t cumulative = 0;
    for (uint32_t i = 0; i < RF_RT_LATENCY_SLOT_COUNT; i++) {
        cumulative += rf_rt_hist_bucket_count(hist, i);
        if (cumulative >= rank) return i;
    }
    return rf_rt_hist_last_bucket(hist);
}

/* ======================================================================== */
/* Render-path counters                                                     */
/* ======================================================================== */

struct rf_rt_render_counters {
    _Atomic uint64_t refusals[RF_RT_REFUSAL_COUNT];
    _Atomic uint64_t underrun_frames;
    _Atomic uint64_t silence_fallbacks;
    /* Published after the fields above. See the header's ordering note. */
    _Atomic int first_pass_recorded;
    _Atomic uint32_t first_pass_frames;
    _Atomic uint32_t first_pass_channels;
    _Atomic uint32_t first_pass_bytes[4];
};

/* 3 * 8 + 2 * 8 + 4 + 4 + 4 + 16 = 68, padded to 8 -> 72. Pinned so a future
   field addition cannot silently grow the footprint past what the Host
   allocates once at construction. */
_Static_assert(
    sizeof(struct rf_rt_render_counters) <= 128,
    "rf_rt_render_counters must stay small");

rf_rt_render_counters* rf_rt_counters_create(void) {
    return (rf_rt_render_counters*)calloc(1, sizeof(struct rf_rt_render_counters));
}

void rf_rt_counters_destroy(rf_rt_render_counters* counters) {
    free(counters);
}

void rf_rt_counters_note_refusal(rf_rt_render_counters* counters, rf_rt_refusal reason) {
    if (counters == NULL || reason < 0 || reason >= RF_RT_REFUSAL_COUNT) return;
    atomic_fetch_add_explicit(&counters->refusals[reason], 1, memory_order_relaxed);
}

void rf_rt_counters_note_underrun(rf_rt_render_counters* counters, uint32_t frames) {
    if (counters == NULL) return;
    atomic_fetch_add_explicit(&counters->underrun_frames, frames, memory_order_relaxed);
}

void rf_rt_counters_note_silence_fallback(rf_rt_render_counters* counters) {
    if (counters == NULL) return;
    atomic_fetch_add_explicit(&counters->silence_fallbacks, 1, memory_order_relaxed);
}

void rf_rt_counters_record_first_pass(
    rf_rt_render_counters* counters, uint32_t frames, uint32_t channels,
    const uint32_t* bytes, uint32_t byteCount) {
    if (counters == NULL) return;
    if (byteCount > 4) byteCount = 4;
    for (uint32_t i = 0; i < 4; i++) {
        atomic_store_explicit(
            &counters->first_pass_bytes[i], i < byteCount ? bytes[i] : 0,
            memory_order_relaxed);
    }
    atomic_store_explicit(&counters->first_pass_frames, frames, memory_order_relaxed);
    atomic_store_explicit(&counters->first_pass_channels, channels, memory_order_relaxed);
    /* Release: the reader that sees this flag sees the fields above. */
    atomic_store_explicit(&counters->first_pass_recorded, 1, memory_order_release);
}

void rf_rt_counters_read(const rf_rt_render_counters* counters, rf_rt_render_snapshot* out) {
    if (out == NULL) return;
    memset(out, 0, sizeof(*out));
    if (counters == NULL) return;

    for (int i = 0; i < RF_RT_REFUSAL_COUNT; i++) {
        out->refusals[i] = atomic_load_explicit(
            (_Atomic uint64_t*)&counters->refusals[i], memory_order_relaxed);
    }
    out->underrun_frames = atomic_load_explicit(
        (_Atomic uint64_t*)&counters->underrun_frames, memory_order_relaxed);
    out->silence_fallbacks = atomic_load_explicit(
        (_Atomic uint64_t*)&counters->silence_fallbacks, memory_order_relaxed);

    /* Acquire pairs with the release store above, so a set flag implies the
       fields are the ones the writer published. */
    if (atomic_load_explicit(
            (_Atomic int*)&counters->first_pass_recorded, memory_order_acquire) != 0) {
        out->first_pass_recorded = 1;
        out->first_pass_frames = atomic_load_explicit(
            (_Atomic uint32_t*)&counters->first_pass_frames, memory_order_relaxed);
        out->first_pass_channels = atomic_load_explicit(
            (_Atomic uint32_t*)&counters->first_pass_channels, memory_order_relaxed);
        for (int i = 0; i < 4; i++) {
            out->first_pass_bytes[i] = atomic_load_explicit(
                (_Atomic uint32_t*)&counters->first_pass_bytes[i], memory_order_relaxed);
        }
    }
}

int rf_rt_counters_is_lock_free(const rf_rt_render_counters* counters) {
    if (counters == NULL) return 0;
    return atomic_is_lock_free(&counters->underrun_frames)
        && atomic_is_lock_free(&counters->refusals[0])
        && atomic_is_lock_free(&counters->first_pass_recorded);
}

/* ======================================================================== */
/* Lock-free render gate                                                    */
/* ======================================================================== */

struct rf_rt_render_gate {
    _Atomic(void*) published;
    _Atomic uint64_t in_flight;
};

_Static_assert(sizeof(struct rf_rt_render_gate) == 16, "rf_rt_render_gate must be two words");

rf_rt_render_gate* rf_rt_gate_create(void) {
    return (rf_rt_render_gate*)calloc(1, sizeof(struct rf_rt_render_gate));
}

void rf_rt_gate_destroy(rf_rt_render_gate* gate) {
    free(gate);
}

void* rf_rt_gate_enter(rf_rt_render_gate* gate) {
    if (gate == NULL) return NULL;
    /* Announce the reader first, then read. A publisher that observes the
       increase refuses to swap, so the pointer this load returns cannot be
       released while the lease is held. */
    atomic_fetch_add_explicit(&gate->in_flight, 1, memory_order_seq_cst);
    void* pointer = atomic_load_explicit(&gate->published, memory_order_seq_cst);
    if (pointer == NULL) {
        /* Nothing to read: undo the announcement instead of leaving a lease
           that would keep a future publication deferred forever. */
        atomic_fetch_sub_explicit(&gate->in_flight, 1, memory_order_seq_cst);
    }
    return pointer;
}

void rf_rt_gate_exit(rf_rt_render_gate* gate) {
    if (gate == NULL) return;
    atomic_fetch_sub_explicit(&gate->in_flight, 1, memory_order_seq_cst);
}

int rf_rt_gate_try_publish(rf_rt_render_gate* gate, void* next) {
    if (gate == NULL) return 0;
    /* A lease outstanding before the swap is the documented deferral case:
       the caller keeps `next` and retries once the callback leaves. */
    if (atomic_load_explicit(&gate->in_flight, memory_order_seq_cst) != 0) {
        return 0;
    }
    /* No rollback here. A reader that entered between the check and this
       exchange may already hold `previous`, and putting the pointer back
       cannot retract it -- the caller would then free a page a lease is
       reading. Once the exchange has happened the publication stands, and it
       is `rf_rt_gate_in_flight() == 0` that tells the caller `previous` has no
       reader left: an exiting lease is visible because it is ordered before
       this load in release/acquire terms. */
    atomic_exchange_explicit(&gate->published, next, memory_order_seq_cst);
    return 1;
}

void rf_rt_gate_force_publish(rf_rt_render_gate* gate, void* next) {
    if (gate == NULL) return;
    atomic_store_explicit(&gate->published, next, memory_order_seq_cst);
}

void* rf_rt_gate_current(const rf_rt_render_gate* gate) {
    if (gate == NULL) return NULL;
    return atomic_load_explicit(
        (_Atomic(void*)*)&gate->published, memory_order_seq_cst);
}

uint64_t rf_rt_gate_in_flight(const rf_rt_render_gate* gate) {
    if (gate == NULL) return 0;
    return atomic_load_explicit(
        (_Atomic uint64_t*)&gate->in_flight, memory_order_seq_cst);
}

int rf_rt_gate_is_lock_free(const rf_rt_render_gate* gate) {
    if (gate == NULL) return 0;
    return atomic_is_lock_free(&gate->in_flight)
        && atomic_is_lock_free(&gate->published);
}
