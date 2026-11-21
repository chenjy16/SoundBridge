// Batch 3 Closure Fix -- CallbackGate admission / drain / retirement tests.
//
// Standalone test, compiled with clang++ directly (like
// tests/ControlProtocolTests.cpp and tests/ProducerTokenTests.cpp). See
// Test-Report.md for the exact commands and recorded results.
//
// Determinism policy
// ------------------
// Every ordering the proof distinguishes is produced by an atomic rendezvous
// (WaitUntil / release flags), never by "sleep and hope". The protocol has a
// single atomic word, so the only two orderings that exist between a reader's
// fetch_add and a closer's fetch_or are "closer first" and "reader first" in the
// modification order M; T1 and T3 construct exactly those two, and that is a
// complete case analysis, not a sample.
//
// Where an interleaving of the *old* two-word protocol cannot be constructed
// because the single-word protocol makes it unreachable (a reader that has
// observed "open" but has not yet counted itself), the test does not fake it.
// It tests the reachable endpoints and says so -- see T2.
//
// What this does NOT prove: the C++ memory model argument itself. That lives in
// CallbackGate-Memory-Model-Proof.md. A concurrent test can only fail to find a
// violation; it can never establish the absence of one.

// Include order matters: libc++ raises "<atomic> is incompatible with
// <stdatomic.h>" when the C++ standard headers are pulled in *after* a C11
// <stdatomic.h>, which RFSharedAudio.h uses. C++ headers first.
#include <array>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <sys/mman.h>

#include "../src/MappingRetirement.hpp"

using soundbridge::CallbackGate;
using soundbridge::DrainAck;
using soundbridge::DrainOutcome;
using soundbridge::MappingQuarantine;
using soundbridge::RetiredRevisionMatches;
using soundbridge::SharedMemoryMapping;

static void check(bool condition, const char* label) {
    if (!condition) {
        std::cerr << "FAIL: " << label << '\n';
        std::exit(1);
    }
}

static void SleepMicros(int micros) {
    std::this_thread::sleep_for(std::chrono::microseconds(micros));
}

static int64_t NowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch()).count();
}

// Spin-free rendezvous: waits for a condition instead of assuming an ordering.
// Returns false on timeout so a broken implementation fails the run instead of
// hanging the harness.
template <typename Pred>
static bool WaitUntil(Pred predicate, int budgetMs = 5000) {
    const int64_t deadline = NowMs() + budgetMs;
    while (!predicate()) {
        if (NowMs() >= deadline) return false;
        SleepMicros(50);
    }
    return true;
}

static constexpr uint32_t kFrames = 8192;
static constexpr size_t kMappingSize = sizeof(RFSharedAudio) + kFrames * sizeof(float) * 8;

static std::shared_ptr<SharedMemoryMapping> MakeMapping(uint64_t epoch) {
    void* raw = mmap(nullptr, kMappingSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    check(raw != MAP_FAILED, "anonymous mapping fixture");
    auto* mem = static_cast<RFSharedAudio*>(raw);
    std::memset(mem, 0, kMappingSize);
    // 50 ms at 48 kHz rounds to a 4096-frame ring, which fits kMappingSize.
    rf_shared_audio_init(mem, 48000, 2, RF_FORMAT_FLOAT32, 50);
    check(rf_admission_open(mem, epoch) == RF_ADMISSION_OK, "open mapping fixture");
    return std::make_shared<SharedMemoryMapping>(mem, kMappingSize);
}

// Poison bytes: a retired mapping is filled with kRetiredByte so a reader that
// should have been refused is caught by a data check instead of a SIGSEGV. The
// page stays mapped here on purpose -- the test is about admission, not about
// whether munmap itself is sound.
static constexpr unsigned char kLiveByte = 0x5A;
static constexpr unsigned char kRetiredByte = 0xDD;

// Mirrors UniversalAudioHandler::RetireMapping() so the *sequencing* rules can
// be tested without linking libASPL: close + drain, clear the published pointer,
// then unmap (provable) or quarantine (not provable). controlMutex stands in for
// the handler's io_mutex_.
struct RetireModel {
    CallbackGate gate;
    std::atomic<RFSharedAudio*> published{nullptr};
    std::atomic<uint64_t> revision{0};
    std::shared_ptr<SharedMemoryMapping> owner;
    std::mutex controlMutex;
    std::atomic<int> munmaps{0};
    std::atomic<int> quarantines{0};

    void Publish(std::shared_ptr<SharedMemoryMapping> mapping) {
        revision.fetch_add(1, std::memory_order_acq_rel);
        owner = std::move(mapping);
        published.store(owner->memory(), std::memory_order_release);
        gate.Open();
    }

    DrainAck Retire(const char* reason, std::chrono::milliseconds budget) {
        std::lock_guard<std::mutex> lock(controlMutex);
        const uint64_t rev = revision.load(std::memory_order_acquire);
        if (published.load(std::memory_order_acquire) == nullptr) {
            gate.Close();
            return DrainAck{rev, 0, DrainOutcome::NothingToRetire};
        }
        const DrainAck ack =
            gate.CloseAndDrain(rev, 0, std::chrono::steady_clock::now() + budget);
        published.store(nullptr, std::memory_order_release);
        if (ack.Drained()) {
            if (owner) {
                owner.reset();  // munmap
                munmaps.fetch_add(1);
            }
        } else if (owner) {
            MappingQuarantine::Retain(std::move(owner), rev, 0, reason);
            quarantines.fetch_add(1);
        }
        return ack;
    }
};

int main() {
    // =======================================================================
    // A. Protocol invariants (deterministic, no threads)
    // =======================================================================

    // A1. A fresh gate admits nothing. A callback arriving before a mapping is
    //     published must be refused, not run against a null pointer.
    {
        CallbackGate gate;
        check(!gate.IsOpen(), "A1 gate starts closed");
        check(gate.RawStateForTesting() == CallbackGate::kClosedBit,
              "A1 initial word is CLOSED with a zero count");
        check(!gate.TryEnter(), "A1 closed gate refuses admission");
        check(gate.ActiveCount() == 0, "A1 refused callback is not counted");
        check(gate.RawStateForTesting() == CallbackGate::kClosedBit,
              "A1 a refused callback leaves the word untouched");
    }

    // A2. Accounting: one Enter pairs with exactly one Leave.
    {
        CallbackGate gate;
        gate.Open();
        check(gate.IsOpen(), "A2 open gate reports open");
        check(gate.TryEnter(), "A2 open gate admits");
        check(gate.ActiveCount() == 1, "A2 admitted callback is counted once");
        gate.Leave();
        check(gate.ActiveCount() == 0, "A2 Leave balances Enter");
        check(gate.RawStateForTesting() == 0, "A2 drained gate is open with a zero count");
    }

    // A3. An idle gate has nothing to wait for.
    {
        CallbackGate gate;
        const DrainAck ack = gate.CloseAndDrain(
            1, 1, std::chrono::steady_clock::now() + std::chrono::milliseconds(10));
        check(ack.outcome == DrainOutcome::Drained,
              "A3 closing an idle gate drains trivially");
        check(ack.Drained(), "A3 the ACK reports Drained");
        check(!gate.TryEnter(), "A3 closing an idle gate still closes admission");
        check(gate.RawStateForTesting() == CallbackGate::kClosedBit,
              "A3 an idle drain leaves CLOSED with a zero count");
    }

    // A4. An old ACK can never be reused for a new incarnation.
    {
        const DrainAck old{1, 100, DrainOutcome::Drained};
        check(RetiredRevisionMatches(old, 1), "A4 ACK matches the incarnation it was made for");
        check(!RetiredRevisionMatches(old, 2), "A4 ACK does not match the next incarnation");
        check(!RetiredRevisionMatches(old, 0), "A4 ACK does not match a cleared stamp");
        check(!RetiredRevisionMatches(DrainAck{}, 0), "A4 revision 0 never matches");
    }

    // =======================================================================
    // T1. "Reader paused after the first open check, closer runs first"
    //
    // In the single-word protocol the admission decision and the counter update
    // are the same RMW, so the reachable counterpart of that pause is: the
    // closer's fetch_or precedes the reader's fetch_add in M. The reader must be
    // refused and the already-retired mapping must never be handed to it.
    // =======================================================================
    {
        CallbackGate gate;
        std::atomic<RFSharedAudio*> published{nullptr};
        std::atomic<bool> closerDone{false};
        auto mapping = MakeMapping(0x1111);
        std::memset(mapping->memory(), kLiveByte, kMappingSize);

        gate.Open();
        published.store(mapping->memory(), std::memory_order_release);

        std::atomic<bool> readerResumed{false};
        std::atomic<bool> readerAdmitted{false};
        std::atomic<bool> readerSawLiveMapping{false};

        std::thread reader([&] {
            // The pause: the reader does not attempt admission until the closer
            // has completely finished (close + drain + pointer clear + unmap).
            const bool released = WaitUntil([&] {
                return closerDone.load(std::memory_order_acquire);
            });
            check(released, "T1 closer finished before the reader resumed");
            readerResumed.store(true, std::memory_order_release);

            const bool admitted = gate.TryEnter();
            readerAdmitted.store(admitted, std::memory_order_release);
            if (admitted) {
                // Wrongly admitted: the mapping is already retired and poisoned.
                const auto* bytes =
                    reinterpret_cast<const unsigned char*>(mapping->memory());
                readerSawLiveMapping.store(bytes[0] == kLiveByte, std::memory_order_release);
                gate.Leave();
            }
        });

        // Closer side, in M order before the reader's fetch_add.
        const DrainAck ack = gate.CloseAndDrain(
            1, 0x1111, std::chrono::steady_clock::now() + std::chrono::milliseconds(250));
        check(ack.Drained(), "T1 the idle incarnation drains");
        published.store(nullptr, std::memory_order_release);
        std::memset(mapping->memory(), kRetiredByte, kMappingSize);  // "released"
        closerDone.store(true, std::memory_order_release);

        reader.join();
        check(readerResumed.load(std::memory_order_acquire), "T1 the reader actually resumed");
        check(!readerAdmitted.load(std::memory_order_acquire),
              "T1 a reader resuming after the close is refused admission");
        check(!readerSawLiveMapping.load(std::memory_order_acquire),
              "T1 a retired mapping is never handed to a reader");
        check(gate.RawStateForTesting() == CallbackGate::kClosedBit,
              "T1 the refused reader left no residue in the state word");
        check(published.load(std::memory_order_acquire) == nullptr,
              "T1 no published pointer survives the retirement");
    }

    // =======================================================================
    // T2. "Reader counted, closer must not be able to ACK"
    //
    // Limitation, stated deliberately: with one atomic word there is no state in
    // which the gate looks open to the reader but closed to the counter, so the
    // literal "incremented but not yet past the second open check" pause cannot
    // be constructed -- that is the defect the rewrite removed. What is
    // reachable, and what the closer must handle, is an admitted reader whose
    // fetch_sub has not happened yet. T2a/T2b pin both endpoints of that state.
    // =======================================================================

    // T2a. Abort path leaves no residue: the reader's RMW pair runs entirely
    //      while the gate is closed, and the word must return to CLOSED|0.
    {
        CallbackGate gate;
        gate.Close();

        constexpr int kThreads = 4;
        std::array<std::atomic<bool>, kThreads> refused{};
        std::vector<std::thread> threads;
        for (int i = 0; i < kThreads; ++i) {
            threads.emplace_back([&, i] {
                refused[i].store(!gate.TryEnter(), std::memory_order_release);
            });
        }
        for (auto& t : threads) t.join();
        for (int i = 0; i < kThreads; ++i) {
            check(refused[i].load(std::memory_order_acquire),
                  "T2a every reader on a closed gate is refused");
        }
        check(gate.RawStateForTesting() == CallbackGate::kClosedBit,
              "T2a concurrent aborts leave the word exactly CLOSED|0");
        check(gate.ActiveCount() == 0, "T2a no aborted reader stays counted");
    }

    // T2b. A closer that observes a non-zero count must not ACK. The reader is
    //      parked with its admission held while the closer burns a short budget;
    //      the only possible outcome is TimedOut, and the drain is provable only
    //      after the reader's own fetch_sub.
    {
        CallbackGate gate;
        gate.Open();

        std::atomic<bool> readerInside{false};
        std::atomic<bool> releaseReader{false};
        std::thread reader([&] {
            check(gate.TryEnter(), "T2b reader admitted");
            readerInside.store(true, std::memory_order_release);
            const bool released = WaitUntil([&] {
                return releaseReader.load(std::memory_order_acquire);
            });
            check(released, "T2b reader released by the test, not by a timeout");
            gate.Leave();
        });
        check(WaitUntil([&] { return readerInside.load(std::memory_order_acquire); }),
              "T2b reader reached the admitted region");

        const DrainAck ack = gate.CloseAndDrain(
            42, 7, std::chrono::steady_clock::now() + std::chrono::milliseconds(120));
        check(ack.outcome == DrainOutcome::TimedOut,
              "T2b an admitted reader makes the drain unprovable");
        check(!ack.Drained(), "T2b TimedOut is never reported as Drained");
        check(ack.revision == 42 && ack.epoch == 7, "T2b the ACK still names its incarnation");
        check(gate.ActiveCount() == 1, "T2b the counter, not the clock, decided");

        releaseReader.store(true, std::memory_order_release);
        reader.join();
        check(gate.ActiveCount() == 0, "T2b the late Leave is still accounted");
        check(gate.RawStateForTesting() == CallbackGate::kClosedBit,
              "T2b the word ends at CLOSED|0");

        // Now the same incarnation is provable.
        const DrainAck second = gate.CloseAndDrain(
            42, 7, std::chrono::steady_clock::now() + std::chrono::milliseconds(250));
        check(second.Drained(), "T2b the drain becomes provable once the reader left");
    }

    // =======================================================================
    // T3. "Reader successfully admitted and parked inside the mapping"
    //
    // The closer must not produce an ACK while the admission is held, must
    // refuse new callbacks meanwhile, and must produce the ACK only after the
    // reader left -- carrying the incarnation it was asked about.
    //
    // Honest scope note: "no ACK has appeared yet" can only be observed over a
    // bounded window; no test can prove a negative about the future. The proof
    // obligation is O2/O4 in MappingRetirement.hpp. What this test adds is that
    // the closer's exit condition really is the counter: ActiveCount() is
    // asserted non-zero for the whole window in which no ACK exists.
    // =======================================================================
    {
        CallbackGate gate;
        gate.Open();

        std::atomic<bool> callbackInside{false};
        std::atomic<bool> releaseCallback{false};
        std::thread reader([&] {
            const bool admitted = gate.TryEnter();
            check(admitted, "T3 reader admitted before the close");
            callbackInside.store(true, std::memory_order_release);
            const bool released = WaitUntil([&] {
                return releaseCallback.load(std::memory_order_acquire);
            });
            check(released, "T3 reader released by the test");
            gate.Leave();
        });
        check(WaitUntil([&] { return callbackInside.load(std::memory_order_acquire); }),
              "T3 reader is inside the mapping");

        std::atomic<bool> ackProduced{false};
        DrainAck ack{};
        std::thread closer([&] {
            ack = gate.CloseAndDrain(77, 0xABCDEF01ull,
                                     std::chrono::steady_clock::now() + std::chrono::seconds(5));
            ackProduced.store(true, std::memory_order_release);
        });

        SleepMicros(150 * 1000);
        check(!ackProduced.load(std::memory_order_acquire),
              "T3 no ACK while a callback is still inside the mapping");
        check(gate.ActiveCount() == 1, "T3 the closer's exit condition is still false");
        check(!gate.IsOpen(), "T3 admission is closed during the drain");
        check(!gate.TryEnter(), "T3 a new callback is refused during the drain");
        check(gate.ActiveCount() == 1, "T3 the refused callback did not perturb the count");

        releaseCallback.store(true, std::memory_order_release);
        closer.join();
        reader.join();

        check(ackProduced.load(std::memory_order_acquire), "T3 ACK is produced after the reader left");
        check(ack.Drained(), "T3 the ACK reports Drained");
        check(ack.revision == 77, "T3 the ACK is bound to the requested revision");
        check(ack.epoch == 0xABCDEF01ull, "T3 the ACK is bound to the requested epoch");
        check(gate.ActiveCount() == 0, "T3 no callback remains admitted");
        check(gate.RawStateForTesting() == CallbackGate::kClosedBit,
              "T3 the word ends at CLOSED|0");
    }

    // =======================================================================
    // T4. Four concurrent readers, each released individually.
    //
    // While any reader is inside, no ACK. The last Leave is what licenses it.
    // =======================================================================
    {
        constexpr int kReaders = 4;
        CallbackGate gate;
        gate.Open();

        std::array<std::atomic<bool>, kReaders> releaseReader{};
        std::atomic<int> admittedCount{0};
        std::atomic<int> insideCount{0};
        std::atomic<bool> closerRunning{false};
        std::atomic<bool> ackProduced{false};
        DrainAck ack{};

        std::vector<std::thread> readers;
        for (int i = 0; i < kReaders; ++i) {
            readers.emplace_back([&, i] {
                check(gate.TryEnter(), "T4 reader admitted");
                admittedCount.fetch_add(1, std::memory_order_acq_rel);
                insideCount.fetch_add(1, std::memory_order_acq_rel);
                const bool released = WaitUntil([&] {
                    return releaseReader[i].load(std::memory_order_acquire);
                });
                check(released, "T4 reader released by the test");
                insideCount.fetch_sub(1, std::memory_order_acq_rel);
                gate.Leave();
            });
        }

        check(WaitUntil([&] {
                  return admittedCount.load(std::memory_order_acquire) == kReaders;
              }),
              "T4 all readers are admitted before the close");
        check(gate.ActiveCount() == kReaders, "T4 every admitted reader contributes a count");

        std::thread closer([&] {
            closerRunning.store(true, std::memory_order_release);
            ack = gate.CloseAndDrain(4, 0x44,
                                     std::chrono::steady_clock::now() + std::chrono::seconds(5));
            ackProduced.store(true, std::memory_order_release);
        });
        check(WaitUntil([&] { return closerRunning.load(std::memory_order_acquire); }),
              "T4 the closer is running");
        SleepMicros(50 * 1000);
        check(!gate.TryEnter(), "T4 admission is closed for new readers");
        check(!ackProduced.load(std::memory_order_acquire), "T4 no ACK while all four are inside");

        // Release one at a time: the ACK must stay absent until the last exit.
        for (int i = 0; i < kReaders; ++i) {
            releaseReader[i].store(true, std::memory_order_release);
            const int remaining = kReaders - 1 - i;
            check(WaitUntil([&] {
                      return insideCount.load(std::memory_order_acquire) == remaining;
                  }),
                  "T4 each reader is released deterministically");
            if (remaining > 0) {
                SleepMicros(30 * 1000);
                check(!ackProduced.load(std::memory_order_acquire),
                      "T4 an ACK is withheld while any reader is still inside");
                check(gate.ActiveCount() == remaining,
                      "T4 the count tracks the readers that are still inside");
            }
        }

        closer.join();
        for (auto& t : readers) t.join();

        check(ackProduced.load(std::memory_order_acquire), "T4 the ACK appears after the last exit");
        check(ack.Drained(), "T4 the ACK reports Drained");
        check(ack.revision == 4 && ack.epoch == 0x44, "T4 the ACK names its incarnation");
        check(gate.ActiveCount() == 0, "T4 no reader remains admitted");
    }

    // =======================================================================
    // T5. Concurrent Close / repeated Retire.
    // =======================================================================

    // T5a. Two closers on the same incarnation: both may report Drained (the ACK
    //      is idempotent), and the state word must not be corrupted.
    {
        CallbackGate gate;
        gate.Open();
        std::atomic<int> drainedCount{0};
        std::array<DrainAck, 2> acks{};
        std::array<std::thread, 2> closers;
        for (int i = 0; i < 2; ++i) {
            closers[i] = std::thread([&, i] {
                acks[i] = gate.CloseAndDrain(
                    9, 0x99, std::chrono::steady_clock::now() + std::chrono::seconds(2));
                if (acks[i].Drained()) drainedCount.fetch_add(1, std::memory_order_relaxed);
            });
        }
        for (auto& t : closers) t.join();
        check(drainedCount.load() == 2, "T5a both concurrent closers observe a drained gate");
        check(acks[0].revision == 9 && acks[1].revision == 9,
              "T5a both ACKs name the same incarnation");
        check(gate.RawStateForTesting() == CallbackGate::kClosedBit,
              "T5a concurrent closes leave CLOSED|0");
    }

    // T5b. Repeated retire: the mapping is unmapped exactly once, later retires
    //      report NothingToRetire, and no ACK ever names another incarnation.
    {
        RetireModel model;
        model.Publish(MakeMapping(0x5B0));

        constexpr int kThreads = 4;
        std::array<DrainAck, kThreads> acks{};
        std::array<std::thread, kThreads> threads;
        for (int i = 0; i < kThreads; ++i) {
            threads[i] = std::thread([&, i] {
                acks[i] = model.Retire("device-removed", std::chrono::milliseconds(250));
            });
        }
        for (auto& t : threads) t.join();

        int drained = 0;
        int nothingToRetire = 0;
        for (const auto& ack : acks) {
            if (ack.Drained()) ++drained;
            if (ack.outcome == DrainOutcome::NothingToRetire) ++nothingToRetire;
            check(ack.revision == 1, "T5b every ACK names the retired incarnation");
        }
        check(drained == 1, "T5b exactly one concurrent retire proves the drain");
        check(nothingToRetire == kThreads - 1,
              "T5b the later retires see nothing left to retire");
        check(model.munmaps.load() == 1, "T5b the mapping is unmapped exactly once");
        check(model.quarantines.load() == 0, "T5b a proven drain never quarantines");
        check(model.published.load(std::memory_order_acquire) == nullptr,
              "T5b the published pointer is cleared before the unmap returns");
        check(model.gate.RawStateForTesting() == CallbackGate::kClosedBit,
              "T5b repeated retires leave CLOSED|0");

        // A fifth, sequential retire is still idempotent.
        const DrainAck again = model.Retire("device-removed", std::chrono::milliseconds(50));
        check(again.outcome == DrainOutcome::NothingToRetire,
              "T5b retiring an already retired mapping is a no-op");
        check(model.munmaps.load() == 1, "T5b the no-op retire does not unmap again");
    }

    // T5c. Close vs enter hammer. This is a *stress* test, not a deterministic
    //      proof: it can only fail to find a violation. It is kept because it
    //      exercises the abort path at volume, where a leaked +1 would show up
    //      as an unprovable drain.
    {
        CallbackGate gate;
        gate.Open();

        constexpr int kThreads = 4;
        std::atomic<bool> stop{false};
        std::atomic<bool> drainReturned{false};
        std::atomic<long long> admitted{0};
        std::atomic<int> admittedAfterDrain{0};

        std::vector<std::thread> workers;
        workers.reserve(kThreads);
        for (int i = 0; i < kThreads; ++i) {
            workers.emplace_back([&] {
                while (!stop.load(std::memory_order_acquire)) {
                    if (gate.TryEnter()) {
                        if (drainReturned.load(std::memory_order_acquire)) {
                            admittedAfterDrain.fetch_add(1, std::memory_order_relaxed);
                        }
                        admitted.fetch_add(1, std::memory_order_relaxed);
                        gate.Leave();
                    }
                }
            });
        }

        SleepMicros(40 * 1000);
        const DrainAck ack = gate.CloseAndDrain(
            11, 22, std::chrono::steady_clock::now() + std::chrono::seconds(2));
        drainReturned.store(true, std::memory_order_release);

        check(ack.Drained(), "T5c the hammer drain is provable with a generous budget");
        check(ack.revision == 11 && ack.epoch == 22, "T5c the hammer ACK names its incarnation");

        // Stop the hammer before reading the counter. A closed gate refuses a
        // reader by fetch_add-then-fetch_sub, so a rejected reader briefly raises
        // the count (obligation O5). That is a delay for the closer, never a
        // safety issue -- the rejected reader never touches the mapping -- but it
        // means ActiveCount() can read non-zero for as long as callbacks keep
        // arriving at a closed gate.
        stop.store(true, std::memory_order_release);
        for (auto& worker : workers) worker.join();

        check(gate.ActiveCount() == 0, "T5c no callback remains admitted once the hammer stops");
        check(gate.RawStateForTesting() == CallbackGate::kClosedBit,
              "T5c the word settles at CLOSED|0 after the drain");
        check(admitted.load() > 0, "T5c the hammer actually admitted callbacks");
        check(admittedAfterDrain.load() == 0,
              "T5c no callback is admitted once the gate is closed and drained");
    }

    // =======================================================================
    // T6. Reopen / new incarnation isolation.
    // =======================================================================

    // T6a. The old ACK cannot be applied to the new incarnation, and a callback
    //      admitted on B sees B.
    {
        RetireModel model;
        model.Publish(MakeMapping(0x6A));
        check(model.gate.TryEnter(), "T6a callback admitted on incarnation A");
        check(model.published.load(std::memory_order_acquire) == model.owner->memory(),
              "T6a the callback sees incarnation A");
        model.gate.Leave();

        const DrainAck ackA = model.Retire("replace", std::chrono::milliseconds(250));
        check(ackA.Drained(), "T6a incarnation A is provably drained");
        check(ackA.revision == 1, "T6a A's ACK names A");

        model.Publish(MakeMapping(0x6B));
        check(model.revision.load() == 2, "T6a the replacement advances the stamp");
        check(!RetiredRevisionMatches(ackA, model.revision.load()),
              "T6a A's ACK cannot be applied to B");

        check(model.gate.TryEnter(), "T6a callback admitted on incarnation B");
        check(model.published.load(std::memory_order_acquire) == model.owner->memory(),
              "T6a the callback sees incarnation B");
        model.gate.Leave();

        const DrainAck ackB = model.Retire("replace", std::chrono::milliseconds(250));
        check(ackB.Drained(), "T6a incarnation B is provably drained");
        check(ackB.revision == 2 && ackB.revision != ackA.revision,
              "T6a B's ACK names B, not A");
        check(model.munmaps.load() == 2, "T6a each drained incarnation is unmapped once");
    }

    // T6b. Deliberate consequence of the design: a callback that never returns
    //      keeps its +1 across Open(), so B is still admitted (liveness) but B's
    //      own drain can never be proven and must not be reported as Drained.
    {
        CallbackGate gate;
        gate.Open();
        check(gate.TryEnter(), "T6b the hung callback is admitted on A");
        // ... and never leaves.

        const DrainAck ackA = gate.CloseAndDrain(
            1, 0x6C, std::chrono::steady_clock::now() + std::chrono::milliseconds(60));
        check(ackA.outcome == DrainOutcome::TimedOut, "T6b A is not provable (hung callback)");

        gate.Open();  // publish B: clears CLOSED, preserves the stale count
        check(gate.TryEnter(), "T6b the new incarnation still admits callbacks (liveness)");
        gate.Leave();
        check(gate.ActiveCount() == 1, "T6b the stale admission from A is still counted");

        const DrainAck ackB = gate.CloseAndDrain(
            2, 0x6D, std::chrono::steady_clock::now() + std::chrono::milliseconds(60));
        check(!ackB.Drained(), "T6b a stale admission makes B's drain unprovable for ever");
        check(ackB.revision == 2, "T6b B's ACK still names B");
    }

    // =======================================================================
    // Q. Quarantine keeps the mapping mapped forever.
    // =======================================================================
    {
        const size_t size = 64 * 1024;
        void* raw = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        check(raw != MAP_FAILED, "Q quarantine fixture mapping");
        std::memset(raw, kLiveByte, size);

        const size_t before = MappingQuarantine::Count();
        MappingQuarantine::Retain(nullptr, 1, 1, "null is ignored");
        check(MappingQuarantine::Count() == before, "Q a null mapping is not retained");

        auto mapping = std::make_shared<SharedMemoryMapping>(static_cast<RFSharedAudio*>(raw), size);
        MappingQuarantine::Retain(std::move(mapping), 5, 77, "drain-timeout");
        check(MappingQuarantine::Count() == before + 1, "Q an unproven mapping is retained");

        const auto* bytes = static_cast<const unsigned char*>(raw);
        check(bytes[0] == kLiveByte && bytes[size - 1] == kLiveByte,
              "Q a quarantined mapping stays mapped and readable (never munmapped)");

        const auto snapshot = MappingQuarantine::Snapshot();
        check(!snapshot.empty(), "Q quarantine metadata is recorded");
        check(snapshot.back().revision == 5 && snapshot.back().epoch == 77 &&
                  snapshot.back().reason == "drain-timeout",
              "Q quarantine metadata records the incarnation and the reason");

        // Retaining the same mapping twice is impossible through this API: the
        // shared_ptr is moved in, so the caller has no second handle to submit.
        check(MappingQuarantine::Count() == before + 1, "Q no duplicate retention");
    }

    // =======================================================================
    // D. Device-removal model (§8.2) and mapping replacement (§8.3).
    // =======================================================================
    {
        RetireModel model;
        auto mappingA = MakeMapping(0x1111);
        model.Publish(std::move(mappingA));

        check(model.gate.TryEnter(), "D callback admitted on incarnation A");
        RFSharedAudio* seenA = model.published.load(std::memory_order_acquire);
        check(seenA != nullptr && seenA->sample_rate == 48000, "D incarnation A is usable");
        model.gate.Leave();

        // Device removal does not go through StopIO: retire is the only path.
        const DrainAck ackA = model.Retire("device-removed", std::chrono::milliseconds(250));
        check(ackA.Drained(), "D incarnation A is provably drained before unmapping");
        check(model.published.load(std::memory_order_acquire) == nullptr,
              "D no published pointer survives the retirement");
        check(!model.gate.TryEnter(), "D a late callback on the removed device is refused");
        check(model.munmaps.load() == 1 && model.quarantines.load() == 0,
              "D a proven retirement unmaps and does not quarantine");
    }

    // =======================================================================
    // L. Long-running quarantine must not block a new incarnation (§8.5 / P0-C).
    // =======================================================================
    {
        const size_t before = MappingQuarantine::Count();
        auto stuck = MakeMapping(0x3333);
        MappingQuarantine::Retain(std::move(stuck), 100, 0x3333, "hung-callback");

        CallbackGate gate;
        std::atomic<uint64_t> revision{100};
        revision.fetch_add(1, std::memory_order_acq_rel);
        gate.Open();
        check(revision.load() == 101, "L a retained mapping does not stall the next incarnation");
        check(gate.TryEnter(), "L the new incarnation admits callbacks while the old one is parked");
        gate.Leave();
        check(MappingQuarantine::Count() == before + 1, "L the parked mapping is still retained");
    }

    std::cout << "Mapping retirement tests passed\n";
    return 0;
}
