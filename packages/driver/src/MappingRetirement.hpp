// Mapping retirement primitives (Batch 3, revised by Batch 3 Closure Fix).
//
// Batch 3 Closure Fix changed the CallbackGate protocol from two atomic
// objects (an admission flag plus a reader counter with a second check) to a
// single atomic state word. See the proof block below for why: the two-word
// form needed a seq_cst total-order argument across two objects, and it had a
// real window in which a reader had already loaded "open" but had not yet
// incremented the counter. The single word removes that window instead of
// reasoning about it.
//
// One mapping incarnation may be entered by realtime callbacks (the HAL write
// callback) and retired by control threads (StopIO, device removal, destructor).
// Batch 2 proved only that the StopIO path is safe: DoIOOperation and StopIO
// share libASPL's per-device ioMutex_, so release-then-unmap cannot overlap a
// write callback. Device removal, an out-of-order StopIO and the destructor do
// not hold that mutex, so they need their own, self-contained proof.
//
// The protocol is a single atomic word per gate:
//
//     state_  =  [ CLOSED : bit 31 ][ admitted callbacks : bits 0..30 ]
//
//   reader (RT)                        closer (any non-RT thread)
//   -----------                        ---------------------------
//   prev = state_.fetch_add(1)         state_.fetch_or(CLOSED)
//   if (prev & CLOSED):                while (count(state_) != 0):
//       state_.fetch_sub(1)  // abort     poll, bounded by a deadline
//       return false                   -> Drained only when count reads 0
//   ... access mapping ...
//   state_.fetch_sub(1)                (the counter is the authority;
//                                       the clock only decides "not proven")
//
// The check and the increment are one indivisible operation, so "closed" and
// "counted" can never disagree: there is no load/increment window to argue
// about. Everything below is stated over the modification order M of state_
// and needs no seq_cst total order and no fences.
//
// Facts used (C++20 [atomics.order], [intro.races]):
//
//   L1  An RMW reads the value of the side effect immediately preceding it in
//       M, and performs its own write immediately after it.
//   L2  A load sequenced after a write to the same object cannot read a value
//       that precedes that write in M (write-read coherence).
//   L3  A release sequence headed by a release RMW consists of that RMW and
//       every following RMW on the same object, so an acquire RMW that reads
//       any of them synchronizes with it.
//
// Obligations:
//
//   O1  Definition: a reader is "admitted" from the instant its fetch_add
//       returns a `previous` with CLOSED clear, until its own fetch_sub. Only
//       that reader can perform that fetch_sub, so an admitted reader's +1 is
//       present in the count for its whole admitted interval.
//
//   O2  The closer's fetch_or(CLOSED) is either M-before or M-after a given
//       fetch_add.
//         - If M-after: by L1 the reader's `previous` already had CLOSED set,
//           so it aborts and never touches the mapping (see O3).
//         - If M-before: by L2 the closer's next poll reads a modification no
//           earlier than its own fetch_or in M, and by O1 that count still
//           contains the reader's +1 until that reader subtracts. The closer
//           therefore cannot read 0 while this reader is admitted.
//
//   O3  Abort path: a reader that sees CLOSED set in `previous` subtracts its
//       own increment and returns false without loading the mapping pointer.
//
//   O4  Monotonicity: after fetch_or(CLOSED), (a) no new reader can become
//       admitted (O2 first bullet), and (b) admitted readers only decrease.
//       Therefore "the closer reads count == 0" is a stable property, and it
//       implies no reader is admitted -- hence none is inside the mapping.
//       That, and only that, licenses munmap.
//
//   O5  A reader that aborts can still briefly raise the count (it subtracts
//       right after), so the closer may need one extra poll. That is a delay,
//       never a correctness issue: the extra reader provably never touches the
//       mapping.
//
// Publication ordering (why a reader that is admitted after a reopen sees the
// new mapping): the handler stores the new pointer with release semantics
// before Open() clears CLOSED. Open() is a release RMW, the reader's fetch_add
// is an acquire RMW reading a later member of the same release sequence (L3),
// so the pointer store happens-before the reader's own load of it.
//
// Consequences, all deliberate:
//   - The RT side does one acq_rel fetch_add on the happy path and one acq_rel
//     fetch_sub on the way out. On arm64 both are a single LSE instruction
//     (ldaddal); no barrier, no retry loop, no CAS. The abort path adds one
//     more fetch_sub, and it is only taken when the gate is closed.
//   - There is no condition variable and no notification at all, so there is
//     no lost wakeup to reason about; the counter is the authority and the
//     sleep in the closer is only a poll interval.
//   - The deadline never decides that a drain happened. It only chooses
//     between "provably drained" (counter reached 0) and "not proven"
//     (counter still non-zero), and "not proven" must never be followed by
//     munmap -- that is what QUARANTINED is for.
//   - A callback that never returns stays counted forever. That does not block
//     new mappings from being published (liveness), but it does mean every
//     later drain of this handler is unprovable and ends in quarantine.

#pragma once

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ControlProtocol.hpp"

namespace soundbridge {

// Result of closing a mapping incarnation.
enum class DrainOutcome {
    // Nothing was admitted when the gate closed, or every admitted callback
    // returned before the deadline. The counter -- never the clock -- decided
    // this.
    Drained,
    // The deadline expired while at least one callback was still inside. This
    // means "unproven", not "unsafe but probably fine": the mapping must not
    // be unmapped.
    TimedOut,
    // No mapping was published, so there was nothing to retire.
    NothingToRetire
};

// A drain acknowledgement, pinned to the incarnation it was produced for.
//
// `revision` is a handler-local, monotonically increasing stamp assigned when a
// mapping is published. `epoch` is the Host's admission epoch observed for that
// mapping. A new incarnation always carries a higher revision, so an ACK from an
// old incarnation can never be mistaken for a new one -- see
// RetiredRevisionMatches() below.
struct DrainAck {
    uint64_t revision = 0;
    uint64_t epoch = 0;
    DrainOutcome outcome = DrainOutcome::NothingToRetire;

    bool Drained() const noexcept { return outcome == DrainOutcome::Drained; }
};

// Admission + drain for a single mapping incarnation.
//
// Starts closed: a callback that arrives before a mapping is published is
// refused instead of running against a null pointer.
//
// One atomic word holds both facts the closer needs:
//
//     bit 31     CLOSED -- admission is shut for the current incarnation
//     bits 0-30  number of callbacks currently admitted
//
// Holding them in one word is what makes the proof short: the reader's
// "is it open?" decision and its "count me in" write are the same RMW, so no
// execution exists in which the gate looks closed to the counter while looking
// open to the reader.
class CallbackGate {
public:
    static constexpr uint32_t kClosedBit = 1u << 31;
    static constexpr uint32_t kCountMask = ~kClosedBit;

    // Only one atomic type is on the realtime path of this class. If it ever
    // stops being lock-free the gate would take a lock inside the HAL write
    // callback, which is unacceptable; fail the build instead. This says
    // nothing about wait-freedom -- fetch_add may still lose a cache line to
    // another core -- only that no lock is involved.
    static_assert(std::atomic<uint32_t>::is_always_lock_free,
                  "CallbackGate state word must be lock-free on the target ABI");

    CallbackGate() noexcept = default;
    CallbackGate(const CallbackGate&) = delete;
    CallbackGate& operator=(const CallbackGate&) = delete;

    // Realtime side. Returns true only if the caller may now touch the mapping.
    //
    // Exactly one RMW on the happy path. The abort path (gate closed) performs
    // a second RMW to undo the increment; it is taken only when there is no
    // mapping to write to, so its cost never lands in a rendering block.
    bool TryEnter() noexcept {
        const uint32_t previous = state_.fetch_add(1, std::memory_order_acq_rel);
        if (previous & kClosedBit) {
            state_.fetch_sub(1, std::memory_order_acq_rel);
            return false;
        }
        // Two billion simultaneously admitted callbacks cannot happen, but a
        // silent wrap into the CLOSED bit would turn a saturated counter into
        // an "always closed" gate, so fail loudly in debug builds.
        assert((previous & kCountMask) != kCountMask &&
               "callback admission counter saturated");
        return true;
    }

    // Realtime side. Must be called exactly once for every TryEnter() == true.
    void Leave() noexcept {
        const uint32_t previous = state_.fetch_sub(1, std::memory_order_acq_rel);
        assert((previous & kCountMask) != 0 && "callback admission counter underflow");
        (void)previous;
    }

    int32_t ActiveCount() const noexcept {
        return static_cast<int32_t>(state_.load(std::memory_order_acquire) & kCountMask);
    }

    bool IsOpen() const noexcept {
        return (state_.load(std::memory_order_acquire) & kClosedBit) == 0;
    }

    // Non-realtime side. Opens admission for a freshly published mapping.
    //
    // Clears CLOSED and *preserves* the count. Deliberately does not assert
    // that the counter is zero: a mapping is only quarantined when a callback
    // never returned, and that callback is still counted; it may stay counted
    // for the rest of the process's life. Aborting a debug build on a hung
    // callback would turn "cannot prove it is safe" into "crash", and the
    // conservative outcome is what we want: every later drain observes the
    // stale admission, fails to prove a drain, and quarantines its own
    // incarnation instead of unmapping it.
    //
    // Must be called after the new mapping pointer is published (release), so
    // that an admitted reader sees that pointer (see the header comment).
    void Open() noexcept {
        state_.fetch_and(~kClosedBit, std::memory_order_acq_rel);
    }

    // Non-realtime side. Closes admission, then waits for admitted callbacks to
    // leave. Never returns Drained unless the counter actually reached zero.
    DrainAck CloseAndDrain(uint64_t revision, uint64_t epoch,
                           std::chrono::steady_clock::time_point deadline) noexcept {
        state_.fetch_or(kClosedBit, std::memory_order_acq_rel);
        while ((state_.load(std::memory_order_acquire) & kCountMask) != 0) {
            if (std::chrono::steady_clock::now() >= deadline) {
                return DrainAck{revision, epoch, DrainOutcome::TimedOut};
            }
            // Poll interval only: the counter above is the proof.
            std::this_thread::sleep_for(std::chrono::microseconds(50));
        }
        return DrainAck{revision, epoch, DrainOutcome::Drained};
    }

    // Non-realtime side. Closes admission without waiting for a drain.
    //
    // Used when there is nothing published to drain (a callback admitted here
    // would find no mapping), and by the tests to stage the close/enter race.
    // Never treat this as a drain proof: only CloseAndDrain() may return an
    // ACK that says Drained.
    void Close() noexcept { state_.fetch_or(kClosedBit, std::memory_order_acq_rel); }

    // Raw word, for tests that need to assert the gate left no residue (no
    // leaked admission, CLOSED exactly as expected). Not used in production.
    uint32_t RawStateForTesting() const noexcept {
        return state_.load(std::memory_order_acquire);
    }

private:
    // Starts CLOSED with a zero count.
    std::atomic<uint32_t> state_{kClosedBit};
};

// True when `ack` describes the mapping the handler currently has published.
//
// After retirement the revision is unchanged, so the ACK still matches; once the
// next incarnation is published the revision advances and every earlier ACK
// fails this check. That is the "an old ACK must never be reused" rule.
inline bool RetiredRevisionMatches(const DrainAck& ack, uint64_t currentRevision) noexcept {
    return ack.revision != 0 && ack.revision == currentRevision;
}

// Mappings that could not be proven drained.
//
// A quarantined mapping is kept mapped for the life of the process and is never
// touched again: no reads, no writes, no munmap. Keeping the address range
// mapped is what makes "a callback that we could not observe might still be
// inside" harmless -- the page stays valid, so even a misbehaving callback
// cannot fault on it. The cost is virtual address space, which is the cheap
// side of this trade.
//
// This is intentionally not a garbage collector: nothing here ever decides that
// a quarantined mapping became safe, because nothing can prove that for a
// callback that never returned.
class MappingQuarantine {
public:
    struct Entry {
        uint64_t revision;
        uint64_t epoch;
        std::string reason;
    };

    // Takes ownership of `mapping`; the caller must have already cleared its
    // own pointer to the mapping.
    static void Retain(std::shared_ptr<SharedMemoryMapping> mapping,
                       uint64_t revision, uint64_t epoch, const char* reason) {
        if (!mapping) return;
        std::lock_guard<std::mutex> lock(Mutex());
        Entries().push_back(std::move(mapping));
        Metadata().push_back(Entry{revision, epoch, reason ? reason : ""});
    }

    static size_t Count() {
        std::lock_guard<std::mutex> lock(Mutex());
        return Entries().size();
    }

    static std::vector<Entry> Snapshot() {
        std::lock_guard<std::mutex> lock(Mutex());
        return Metadata();
    }

private:
    // Function-local statics: initialised on first use by a non-realtime
    // thread, never touched by a callback.
    static std::mutex& Mutex() {
        static std::mutex mutex;
        return mutex;
    }
    static std::vector<std::shared_ptr<SharedMemoryMapping>>& Entries() {
        static std::vector<std::shared_ptr<SharedMemoryMapping>> entries;
        return entries;
    }
    static std::vector<Entry>& Metadata() {
        static std::vector<Entry> metadata;
        return metadata;
    }
};

}  // namespace soundbridge
