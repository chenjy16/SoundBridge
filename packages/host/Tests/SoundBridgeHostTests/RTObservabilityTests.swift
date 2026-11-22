import XCTest
import Darwin
import AudioToolbox
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - P3 Batch 1.5: the observability layer itself
//
// What these tests can and cannot prove:
//
//   - They exercise the exact functions the audio callback calls
//     (`rf_rt_hist_observe`, `rf_rt_counters_*`, `rf_rt_gate_enter/exit`) and
//     the callback itself (`AudioRenderer.render`).
//   - "No lock" is asserted structurally: the counters and the gate report
//     `atomic_is_lock_free`, and no Swift-side lock exists on the path any more.
//     The gate's swap/read protocol is additionally stressed with real `mmap`
//     pages that are `munmap`ped after a successful swap — under ASan that turns
//     a use-after-release into a reported fault instead of a silent read.
//   - They do NOT prove real-time scheduling. A callback that never misses its
//     deadline on a real IO thread stays a real-machine question (P3-1).

final class RTObservabilityTests: XCTestCase {

    // MARK: - Latency histogram

    func testHistogramStartsEmpty() throws {
        let histogram = try XCTUnwrap(rf_rt_hist_create())
        defer { rf_rt_hist_destroy(histogram) }

        XCTAssertEqual(rf_rt_hist_observations(histogram), 0)
        XCTAssertEqual(rf_rt_hist_first_bucket(histogram), RF_RT_HISTOGRAM_EMPTY)
        XCTAssertEqual(rf_rt_hist_last_bucket(histogram), RF_RT_HISTOGRAM_EMPTY)
        XCTAssertEqual(rf_rt_hist_quantile_bucket(histogram, 5000), RF_RT_HISTOGRAM_EMPTY)
    }

    func testHistogramRecordsQuantilesAndExtremes() throws {
        let histogram = try XCTUnwrap(rf_rt_hist_create())
        defer { rf_rt_hist_destroy(histogram) }

        // 90 observations at 100 us, 9 at 500 us, 1 at 2 ms.
        for _ in 0..<90 { rf_rt_hist_observe(histogram, 100_000, 0) }
        for _ in 0..<9 { rf_rt_hist_observe(histogram, 500_000, 0) }
        rf_rt_hist_observe(histogram, 2_000_000, 0)

        XCTAssertEqual(rf_rt_hist_observations(histogram), 100)
        XCTAssertEqual(rf_rt_hist_bucket_count(histogram, 50), 90)   // 100 us / 2 us
        XCTAssertEqual(rf_rt_hist_bucket_count(histogram, 250), 9)   // 500 us / 2 us

        // Bucket width is 2 us, so each answer is within one bucket.
        let p50 = rf_rt_hist_bucket_lower_ns(rf_rt_hist_quantile_bucket(histogram, 5000))
        let p95 = rf_rt_hist_bucket_lower_ns(rf_rt_hist_quantile_bucket(histogram, 9500))
        let p99 = rf_rt_hist_bucket_lower_ns(rf_rt_hist_quantile_bucket(histogram, 9900))
        XCTAssertGreaterThanOrEqual(p50, 99_000)
        XCTAssertLessThanOrEqual(p50, 101_999)
        XCTAssertGreaterThanOrEqual(p95, 499_000)
        XCTAssertLessThanOrEqual(p95, 501_999)
        XCTAssertGreaterThanOrEqual(p99, 499_000)
        XCTAssertLessThanOrEqual(p99, 501_999)

        let min = rf_rt_hist_bucket_lower_ns(rf_rt_hist_first_bucket(histogram))
        let max = rf_rt_hist_bucket_upper_ns(rf_rt_hist_last_bucket(histogram))
        XCTAssertEqual(min, 100_000)
        XCTAssertGreaterThanOrEqual(max, 2_000_000)
        XCTAssertLessThan(max, 2_002_000)
    }

    func testHistogramSaturatesInTheOverflowBucket() throws {
        let histogram = try XCTUnwrap(rf_rt_hist_create())
        defer { rf_rt_hist_destroy(histogram) }

        let ceiling = UInt64(RF_RT_LATENCY_BUCKET_COUNT) * UInt64(RF_RT_LATENCY_BUCKET_WIDTH_NS)
        XCTAssertEqual(ceiling, 16_384_000, "the documented ceiling is 16.384 ms")

        rf_rt_hist_observe(histogram, ceiling, 0)
        XCTAssertEqual(rf_rt_hist_last_bucket(histogram), UInt32(RF_RT_LATENCY_OVERFLOW_BUCKET))
        XCTAssertEqual(rf_rt_hist_bucket_lower_ns(UInt32(RF_RT_LATENCY_OVERFLOW_BUCKET)), UInt64.max)
        XCTAssertEqual(rf_rt_hist_bucket_upper_ns(UInt32(RF_RT_LATENCY_OVERFLOW_BUCKET)), UInt64.max)
    }

    func testHistogramCountsOverBudgetObservations() throws {
        let histogram = try XCTUnwrap(rf_rt_hist_create())
        defer { rf_rt_hist_destroy(histogram) }

        let budget: UInt64 = 10_667_000     // 512 frames @ 48 kHz
        rf_rt_hist_observe(histogram, budget - 1, budget)
        rf_rt_hist_observe(histogram, budget + 1_000, budget)
        rf_rt_hist_observe(histogram, budget + 3_000, budget)

        XCTAssertEqual(rf_rt_hist_over_budget(histogram), 2)
        XCTAssertEqual(rf_rt_hist_over_budget_excess_ns(histogram), 4_000)
        XCTAssertEqual(rf_rt_hist_observations(histogram), 3)
    }

    func testHistogramIsLockFree() throws {
        let histogram = try XCTUnwrap(rf_rt_hist_create())
        defer { rf_rt_hist_destroy(histogram) }
        XCTAssertNotEqual(rf_rt_histogram_is_lock_free(histogram), 0)
    }

    func testHistogramRemainsReadableWhileAnotherThreadObserves() throws {
        let histogram = try XCTUnwrap(rf_rt_hist_create())
        defer { rf_rt_hist_destroy(histogram) }

        let writes = 20_000
        let finished = expectation(description: "observer finished")
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 0..<writes {
                rf_rt_hist_observe(histogram, UInt64(50_000 + (i % 1_000)), 0)
            }
            finished.fulfill()
        }

        // The reader is the control thread: it walks the buckets while the
        // writer keeps incrementing. It must never block the writer, and the
        // final total must still be exact because each observation is one
        // relaxed increment on exactly one bucket.
        var reads = 0
        while reads < 2_000 {
            _ = rf_rt_hist_quantile_bucket(histogram, 9900)
            _ = rf_rt_hist_last_bucket(histogram)
            reads += 1
        }

        wait(for: [finished], timeout: 30)
        XCTAssertEqual(rf_rt_hist_observations(histogram), UInt64(writes))
    }

    // MARK: - Render counters

    func testCountersRecordRefusalsUnderrunsAndSilence() throws {
        let counters = try XCTUnwrap(rf_rt_counters_create())
        defer { rf_rt_counters_destroy(counters) }

        rf_rt_counters_note_refusal(counters, RF_RT_REFUSAL_MEMORY_UNAVAILABLE)
        rf_rt_counters_note_refusal(counters, RF_RT_REFUSAL_CAPACITY_EXCEEDED)
        rf_rt_counters_note_refusal(counters, RF_RT_REFUSAL_CHANNEL_MISMATCH)
        rf_rt_counters_note_refusal(counters, RF_RT_REFUSAL_CHANNEL_MISMATCH)
        rf_rt_counters_note_underrun(counters, 128)
        rf_rt_counters_note_underrun(counters, 84)
        rf_rt_counters_note_silence_fallback(counters)

        var snapshot = rf_rt_render_snapshot()
        rf_rt_counters_read(counters, &snapshot)
        XCTAssertEqual(snapshot.refusals.0, 1)
        XCTAssertEqual(snapshot.refusals.1, 1)
        XCTAssertEqual(snapshot.refusals.2, 2)
        XCTAssertEqual(snapshot.underrun_frames, 212)
        XCTAssertEqual(snapshot.silence_fallbacks, 1)
        XCTAssertEqual(snapshot.first_pass_recorded, 0)
    }

    func testCountersPublishTheFirstPassRecord() throws {
        let counters = try XCTUnwrap(rf_rt_counters_create())
        defer { rf_rt_counters_destroy(counters) }

        let bytes: [UInt32] = [2048, 2048, 0, 0]
        bytes.withUnsafeBufferPointer { buffer in
            rf_rt_counters_record_first_pass(counters, 512, 2, buffer.baseAddress, 4)
        }

        var snapshot = rf_rt_render_snapshot()
        rf_rt_counters_read(counters, &snapshot)
        XCTAssertEqual(snapshot.first_pass_recorded, 1)
        XCTAssertEqual(snapshot.first_pass_frames, 512)
        XCTAssertEqual(snapshot.first_pass_channels, 2)
        XCTAssertEqual(snapshot.first_pass_bytes.0, 2048)
        XCTAssertEqual(snapshot.first_pass_bytes.1, 2048)
        XCTAssertEqual(snapshot.first_pass_bytes.2, 0)
    }

    func testCountersAreLockFree() throws {
        let counters = try XCTUnwrap(rf_rt_counters_create())
        defer { rf_rt_counters_destroy(counters) }
        XCTAssertNotEqual(rf_rt_counters_is_lock_free(counters), 0)
    }

    // MARK: - Render gate

    func testGateHandsOutNothingBeforeAPublication() throws {
        let gate = try XCTUnwrap(rf_rt_gate_create())
        defer { rf_rt_gate_destroy(gate) }

        XCTAssertNil(rf_rt_gate_enter(gate))
        XCTAssertEqual(rf_rt_gate_in_flight(gate), 0,
                       "a refused entry must not leave a lease behind")
    }

    func testGatePublishesAndHandsOutThePointer() throws {
        let gate = try XCTUnwrap(rf_rt_gate_create())
        let page = try ScratchPage(fill: 0x11)
        defer {
            rf_rt_gate_force_publish(gate, nil)
            page.unmap()
            rf_rt_gate_destroy(gate)
        }

        XCTAssertEqual(rf_rt_gate_try_publish(gate, page.pointer), 1)
        XCTAssertEqual(rf_rt_gate_current(gate), page.pointer)

        let entered = try XCTUnwrap(rf_rt_gate_enter(gate))
        XCTAssertEqual(entered, page.pointer)
        XCTAssertEqual(rf_rt_gate_in_flight(gate), 1)
        XCTAssertEqual(entered.load(as: UInt8.self), 0x11)
        rf_rt_gate_exit(gate)
        XCTAssertEqual(rf_rt_gate_in_flight(gate), 0)
    }

    func testGateDefersPublicationWhileALeaseIsHeld() throws {
        let gate = try XCTUnwrap(rf_rt_gate_create())
        let first = try ScratchPage(fill: 0x22)
        let second = try ScratchPage(fill: 0x33)
        defer {
            rf_rt_gate_force_publish(gate, nil)
            first.unmap()
            second.unmap()
            rf_rt_gate_destroy(gate)
        }

        XCTAssertEqual(rf_rt_gate_try_publish(gate, first.pointer), 1)
        XCTAssertEqual(rf_rt_gate_enter(gate), first.pointer)

        // A callback is inside: the swap must be refused, and the published
        // pointer must stay on the mapping the lease holder is reading.
        XCTAssertEqual(rf_rt_gate_try_publish(gate, second.pointer), 0)
        XCTAssertEqual(rf_rt_gate_current(gate), first.pointer)

        // The deferred publication is retried by the control thread once the
        // lease is gone.
        rf_rt_gate_exit(gate)
        XCTAssertEqual(rf_rt_gate_try_publish(gate, second.pointer), 1)
        XCTAssertEqual(rf_rt_gate_current(gate), second.pointer)
        XCTAssertEqual(rf_rt_gate_enter(gate), second.pointer)
        rf_rt_gate_exit(gate)
    }

    func testGateForcePublishIgnoresLeases() throws {
        let gate = try XCTUnwrap(rf_rt_gate_create())
        let page = try ScratchPage(fill: 0x44)
        defer {
            page.unmap()
            rf_rt_gate_destroy(gate)
        }

        XCTAssertEqual(rf_rt_gate_try_publish(gate, page.pointer), 1)
        XCTAssertEqual(rf_rt_gate_enter(gate), page.pointer)

        // Shutdown only: the pointer stops being handed out even though a lease
        // is outstanding. `renderRetireTimeouts` records that it happened.
        rf_rt_gate_force_publish(gate, nil)
        XCTAssertNil(rf_rt_gate_current(gate))
        XCTAssertNil(rf_rt_gate_enter(gate))
        rf_rt_gate_exit(gate)
        XCTAssertEqual(rf_rt_gate_in_flight(gate), 0)
    }

    func testGateIsLockFree() throws {
        let gate = try XCTUnwrap(rf_rt_gate_create())
        defer { rf_rt_gate_destroy(gate) }
        XCTAssertNotEqual(rf_rt_gate_is_lock_free(gate), 0)
    }

    /// The protocol test that matters: readers hold a lease on a real page while
    /// the publisher swaps and, once the leases are gone, `munmap`s the page it
    /// replaced.
    ///
    /// A protocol bug is a use-after-`munmap`. Under ASan the page is unmapped
    /// behind the reader and the touch faults (this test found exactly that bug
    /// in the first, roll-back version of `rf_rt_gate_try_publish`); in a plain
    /// build it is usually a segfault, which is still louder than a wrong number.
    func testGateSurvivesConcurrentSwapsAndReads() throws {
        let gate = try XCTUnwrap(rf_rt_gate_create())
        var current = try ScratchPage(fill: 0x01)
        XCTAssertEqual(rf_rt_gate_try_publish(gate, current.pointer), 1)

        let readers = 4
        let iterationsPerReader = 20_000
        let swaps = 400
        let group = DispatchGroup()

        for _ in 0..<readers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                for i in 0..<iterationsPerReader {
                    guard let pointer = rf_rt_gate_enter(gate) else { continue }
                    // Touch the page: this is what the sanitizer watches.
                    XCTAssertNotEqual(pointer.load(as: UInt8.self), 0xFF)
                    if i % 1_000 == 0 { pointer.storeBytes(of: UInt8(0x01), as: UInt8.self) }
                    rf_rt_gate_exit(gate)
                }
            }
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            for attempt in 0..<swaps {
                guard let next = try? ScratchPage(fill: UInt8(attempt & 0x7F) | 0x01) else { continue }
                if rf_rt_gate_try_publish(gate, next.pointer) == 1 {
                    let retired = current
                    current = next
                    // The swap stands, so no future `enter` can hand out the
                    // retired page; a reader already inside it keeps the lease
                    // count above zero until it is done. Waiting here is what a
                    // control thread is allowed to do and the audio thread is
                    // not.
                    while rf_rt_gate_in_flight(gate) != 0 { usleep(20) }
                    retired.unmap()
                } else {
                    // Never published: the caller still owns it.
                    next.unmap()
                }
                usleep(50)
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(rf_rt_gate_in_flight(gate), 0)
        XCTAssertEqual(rf_rt_gate_current(gate), current.pointer)

        rf_rt_gate_force_publish(gate, nil)
        current.unmap()
        rf_rt_gate_destroy(gate)
    }

    // MARK: - The callback records every block

    func testEveryCallbackBlockIsMeasured() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeObservability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let directory = sandbox
        let manager = SharedMemoryManager(
            sessionID: UUID(),
            pathForUID: { "\(directory.path)/soundbridge-\($0)" }
        )
        defer { manager.cleanup() }

        let uid = "observability-device-0"
        XCTAssertEqual(manager.createMemory(for: uid, persistence: NoPersistence()), .created)
        let mem = try XCTUnwrap(manager.getMemory(for: uid))

        let renderer = AudioRenderer(memoryManager: manager)
        let output = PlanarBuffers(channels: 2, frames: 256)

        // Consume the creation-time prefill so the counters below describe the
        // synthetic blocks and nothing else.
        drainRing(mem)

        let blocks = 200
        for _ in 0..<blocks {
            renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 256)
        }

        let timing = renderer.takeTimingSnapshot()
        XCTAssertEqual(timing.observations, UInt64(blocks),
                       "every block, including a refused one, must be measured")

        // The counters the callback writes must agree with the number of blocks.
        let diagnostics = renderer.takeDiagnostics()
        XCTAssertEqual(Int(diagnostics.underrunFrames), blocks * 256,
                       "an empty ring reports every frame as an underrun")
        XCTAssertEqual(diagnostics.silenceFallbacks, UInt64(blocks))
        XCTAssertEqual(diagnostics.memoryUnavailable, 0)

        // Everything below reads the clock. Under a sanitizer every instrumented
        // block costs far more than 16.384 ms, so these assertions would measure
        // the instrumentation instead of the callback: the histogram saturates,
        // the overflow counter moves and the quantiles collapse into the top
        // bucket. Counting is this test's job under ASan/TSan; the wall-clock
        // shape is asserted in a plain build.
        guard !sanitizerIsActive() else { return }

        XCTAssertFalse(timing.maxIsSaturated)
        XCTAssertEqual(timing.overBudget, 0, "a synthetic block is far below 256 frames / 48 kHz")

        let min = try XCTUnwrap(timing.minMicroseconds)
        let p50 = try XCTUnwrap(timing.p50Microseconds)
        let p95 = try XCTUnwrap(timing.p95Microseconds)
        let p99 = try XCTUnwrap(timing.p99Microseconds)
        let max = try XCTUnwrap(timing.maxMicroseconds)
        XCTAssertLessThanOrEqual(min, p50)
        XCTAssertLessThanOrEqual(p50, p95)
        XCTAssertLessThanOrEqual(p95, p99)
        XCTAssertLessThanOrEqual(p99, max)

        // The budget is derived from the mapping's own rate and the block size.
        XCTAssertLessThan(max, 10_000, "a 256-frame callback at 48 kHz has a 5.333 ms budget")
    }

    // MARK: - DSP parameters under the real producer/consumer split

    /// The shape the product actually runs: the App publishes EQ parameter
    /// snapshots and ring frames from another process while the Host callback
    /// reads them and pushes them into the DSP engine.
    ///
    /// Nothing here calls `soundbridge_dsp_update_*` from a second thread -- the
    /// engine has exactly one writer, the IO thread. What is concurrent is the
    /// snapshot, which is what the seqlock in `rf_store_eq_snapshot` covers. Run
    /// under TSan this test is the evidence that the split has no data race.
    func testEQUpdatesAndRingWritesDoNotRaceTheCallback() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeObservability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let directory = sandbox
        let manager = SharedMemoryManager(
            sessionID: UUID(),
            pathForUID: { "\(directory.path)/soundbridge-\($0)" }
        )
        defer { manager.cleanup() }

        let uid = "observability-dsp-0"
        XCTAssertEqual(manager.createMemory(for: uid, persistence: NoPersistence()), .created)
        let mem = try XCTUnwrap(manager.getMemory(for: uid))
        manager.publishVolumeState(for: uid, scalar: 0.8, muted: false)

        let renderer = AudioRenderer(memoryManager: manager)
        let output = PlanarBuffers(channels: 2, frames: 256)
        let channels = Int(mem.pointee.channels)
        drainRing(mem)

        let blocks = 400
        let producer = ProducerFlag()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            let staging = UnsafeMutablePointer<Float>.allocate(capacity: 256 * channels)
            defer { staging.deallocate() }
            var iteration = 0
            while !producer.isFinished {
                for frame in 0..<256 {
                    for channel in 0..<channels {
                        staging[frame * channels + channel] = Float((frame + iteration) % 64) / 64 - 0.5
                    }
                }
                var dropped: UInt32 = 0
                _ = rf_ring_write_unchecked(mem, staging, 256, &dropped)

                // Every field the callback mirrors into the engine moves.
                var snapshot = RFEQSnapshot()
                snapshot.bypass = (iteration % 2 == 0)
                snapshot.preamp = Float(iteration % 7) - 3
                withUnsafeMutablePointer(to: &snapshot.bands) { pointer in
                    pointer.withMemoryRebound(to: Float.self, capacity: 10) { bands in
                        for band in 0..<10 { bands[band] = Float(band) + Float(iteration % 5) }
                    }
                }
                rf_store_eq_snapshot(mem, &snapshot)
                iteration += 1
            }
            producer.iterations = iteration
        }

        for _ in 0..<blocks {
            renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 256)
        }
        producer.isFinished = true
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)

        let timing = renderer.takeTimingSnapshot()
        XCTAssertEqual(timing.observations, UInt64(blocks), "every block is measured under contention")
        // The 16.384 ms ceiling is a fact about an uninstrumented build. ASan and
        // TSan slow a block down by an order of magnitude, so a saturated max
        // says "the instrumented process was slow", not "the callback is late".
        if !sanitizerIsActive() {
            XCTAssertFalse(timing.maxIsSaturated)
        }

        let diagnostics = renderer.takeDiagnostics()
        XCTAssertLessThan(Int(diagnostics.underrunFrames), blocks * 256,
                          "the producer kept the ring fed, so the DSP ran")
        XCTAssertEqual(diagnostics.memoryUnavailable, 0)
        XCTAssertGreaterThan(producer.iterations, 0, "the producer published at least one snapshot")
    }

    // MARK: - Helpers

    private func sanitizerIsActive() -> Bool {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return dlsym(defaultHandle, "__asan_init") != nil
            || dlsym(defaultHandle, "__tsan_init") != nil
    }

    /// Empty the ring so a test sees exactly the frames it stages itself.
    private func drainRing(_ mem: UnsafeMutablePointer<RFSharedAudio>) {
        let capacity = Int(mem.pointee.ring_capacity_frames)
        let channels = Int(mem.pointee.channels)
        guard capacity > 0, channels > 0 else { return }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        defer { scratch.deallocate() }
        var zeroFilled: UInt32 = 0
        while rf_ring_read(mem, scratch, UInt32(capacity), &zeroFilled) > 0 {}
    }

    /// A page-backed scratch region whose lifetime the test controls, so the
    /// gate's "release only when no lease is held" promise is testable with a
    /// real `munmap` instead of a boolean.
    private final class ScratchPage {
        let pointer: UnsafeMutableRawPointer
        let size: Int

        init(fill: UInt8, size: Int = 4096) throws {
            self.size = size
            let raw = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
            guard let raw, raw != UnsafeMutableRawPointer(bitPattern: -1) else {
                throw XCTSkip("mmap failed")
            }
            pointer = raw
            memset(raw, Int32(fill), size)
        }

        func unmap() {
            munmap(pointer, size)
        }
    }

    private final class PlanarBuffers {
        let list: UnsafeMutableAudioBufferListPointer
        private let storage: [UnsafeMutableRawPointer]

        init(channels: Int, frames: Int) {
            list = AudioBufferList.allocate(maximumBuffers: channels)
            list.count = channels
            var storage: [UnsafeMutableRawPointer] = []
            for _ in 0..<channels {
                let raw = UnsafeMutableRawPointer.allocate(
                    byteCount: frames * MemoryLayout<Float>.size,
                    alignment: MemoryLayout<Float>.alignment
                )
                raw.initializeMemory(as: Float.self, repeating: 0, count: frames)
                storage.append(raw)
                list[storage.count - 1] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: raw
                )
            }
            self.storage = storage
        }

        deinit {
            for raw in storage { raw.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }
}

private final class NoPersistence: VolumeStatePersisting {
    func loadIfPresent(uid: String) -> DeviceVolumeState? { nil }
    func save(uid: String, volume: Float, muted: Bool) {}
}

/// Test-only coordination between the producer thread and the test thread. The
/// lock is on the fixture side and never on the audio path.
private final class ProducerFlag {
    private let lock = NSLock()
    private var finished = false
    private var count = 0

    var isFinished: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
        set {
            lock.lock()
            finished = newValue
            lock.unlock()
        }
    }

    var iterations: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        set {
            lock.lock()
            count = newValue
            lock.unlock()
        }
    }
}
