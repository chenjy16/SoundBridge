import XCTest
import Darwin
import AudioToolbox
@testable import SoundBridgeHost
import CSoundBridgeAudio
import CSoundBridgeDSP

// MARK: - Phase B: Host + CoreAudio realtime cost measurement
//
// WHAT THIS MEASURES AND WHAT IT DOES NOT
//
//   - Two different things are measured and they are never mixed:
//       (a) the REAL render function `AudioRenderer.render(bufferList:frameCount:)`
//           driven in-process with a real shared-memory mapping, a real
//           `AudioBufferList` and a real DSP engine. The code under test is
//           byte-for-byte the code CoreAudio calls; only the HAL and the IO
//           thread are absent.
//       (b) component micro-benchmarks on the same C entry points the callback
//           calls (`soundbridge_dsp_try_update_eq`,
//           `soundbridge_dsp_process_interleaved`, `rf_load_eq_snapshot_safe`),
//           so a whole-callback delta can be attributed to a component.
//   - Neither is a real CoreAudio measurement. A synthetic burst proves work and
//     cost shape; it does not prove that a real IO thread meets its deadline
//     under a real scheduler and a real device.
//   - Nothing here asserts a threshold. It prints numbers. Deadline utilisation
//     is `frames / sample_rate`, a property of the configuration, not an
//     invented safety limit.
//
// TWO MEASUREMENT NOTES THAT MATTER
//
//   - One `SharedMemoryManager` per scenario. The render gate publishes a single
//     mapping, chosen as "preferred UID, else the first mapping that exists"
//     (`SharedMemoryManager.refreshRenderMemory`). Several mappings in one
//     manager therefore make the gate's choice arbitrary, and a renderer can
//     read a mapping the fixture is not feeding. Each scenario below owns its
//     manager *and* names its mapping as the preferred render UID.
//   - `mach_absolute_time` advances in 41.67 ns ticks here, so per-call
//     quantiles are meaningless for a 100 ns call. Component costs are reported
//     as the mean over a long loop; quantiles are reported only where the event
//     is large enough for them to mean something.
//
// HOW TO RUN
//
//   SB_RT_MEASURE=1 swift test -c release \
//     --filter HostRealtimeMeasurementTests
//
// The suite skips itself otherwise, so `make test-host` stays fast.

final class HostRealtimeMeasurementTests: XCTestCase {

    private var sandbox: URL!
    private var timebaseNumer: UInt64 = 1
    private var timebaseDenom: UInt64 = 1

    /// 48 kHz, 2 channels, 512 frames per callback: 10.667 ms of audio.
    private let sampleRate: UInt32 = 48000
    private let frames: UInt32 = 512
    private let steadyBlocks = 20_000
    private let eqBlocks = 20_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SB_RT_MEASURE"] == "1",
            "Realtime measurement suite: set SB_RT_MEASURE=1 to run it"
        )

        var timebase = mach_timebase_info_data_t()
        XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
        timebaseNumer = UInt64(timebase.numer)
        timebaseDenom = UInt64(timebase.denom)

        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeMeasure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private final class PlanarBuffers {
        let list: UnsafeMutableAudioBufferListPointer
        private let storage: [UnsafeMutableRawPointer]

        init(channels: Int, frames: Int) {
            self.list = AudioBufferList.allocate(maximumBuffers: channels)
            list.count = channels
            var storage: [UnsafeMutableRawPointer] = []
            for index in 0..<channels {
                let raw = UnsafeMutableRawPointer.allocate(
                    byteCount: frames * MemoryLayout<Float>.size,
                    alignment: MemoryLayout<Float>.alignment
                )
                raw.initializeMemory(as: Float.self, repeating: 0, count: frames)
                storage.append(raw)
                list[index] = AudioBuffer(
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

    private struct Harness {
        let manager: SharedMemoryManager
        let mem: UnsafeMutablePointer<RFSharedAudio>
        let renderer: AudioRenderer
        let output: PlanarBuffers
        let staging: UnsafeMutablePointer<Float>
        let channels: Int
        let ringCapacity: Int
    }

    /// Every scenario gets its own manager and its own mapping, and names that
    /// mapping as the render path's preferred one. Without this the shared render
    /// gate can serve a *different* mapping than the fixture feeds.
    private func makeHarness(device: String) throws -> Harness {
        let directory = sandbox.appendingPathComponent(device, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SharedMemoryManager(
            sessionID: UUID(),
            pathForUID: { "\(directory.path)/soundbridge-\($0)" }
        )

        XCTAssertEqual(manager.createMemory(for: device, persistence: NoPersistence()), .created)
        let mem = try XCTUnwrap(manager.getMemory(for: device))
        manager.setPreferredRenderUID(device)
        manager.publishVolumeState(for: device, scalar: 1.0, muted: false)

        var snapshot = RFEQSnapshot()
        snapshot.bypass = false
        snapshot.preamp = 0
        withUnsafeMutablePointer(to: &snapshot.bands) { pointer in
            pointer.withMemoryRebound(to: Float.self, capacity: 10) { bands in
                for band in 0..<10 { bands[band] = 0 }
            }
        }
        rf_store_eq_snapshot(mem, &snapshot)

        let channels = Int(mem.pointee.channels)
        let ringCapacity = Int(mem.pointee.ring_capacity_frames)

        let staging = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity * channels)
        staging.initialize(repeating: 0, count: ringCapacity * channels)
        for frame in 0..<ringCapacity {
            let value = 0.3 * sinf(2 * Float.pi * 440 * Float(frame) / Float(sampleRate))
            for channel in 0..<channels { staging[frame * channels + channel] = value }
        }
        var dropped: UInt32 = 0
        _ = rf_ring_write_unchecked(mem, staging, UInt32(ringCapacity / 2), &dropped)

        let renderer = AudioRenderer(memoryManager: manager)
        // Sized for the largest block the frame-size sweep asks for.
        let output = PlanarBuffers(channels: channels, frames: 4096)
        return Harness(
            manager: manager, mem: mem, renderer: renderer, output: output,
            staging: staging, channels: channels, ringCapacity: ringCapacity
        )
    }

    private func release(_ harness: Harness) {
        harness.manager.cleanup()
        harness.staging.deinitialize(count: harness.ringCapacity * harness.channels)
        harness.staging.deallocate()
    }

    /// Exactly what a real producer does between two callbacks: hand the ring a
    /// block. Kept off the timed region on purpose.
    private func topUp(_ harness: Harness, frameCount: UInt32? = nil) {
        var dropped: UInt32 = 0
        _ = rf_ring_write_unchecked(
            harness.mem, harness.staging, frameCount ?? frames, &dropped)
    }

    private func storeSnapshot(
        _ harness: Harness, band0: Float, allBands: Float?, preamp: Float
    ) {
        var snapshot = RFEQSnapshot()
        snapshot.bypass = false
        snapshot.preamp = preamp
        withUnsafeMutablePointer(to: &snapshot.bands) { pointer in
            pointer.withMemoryRebound(to: Float.self, capacity: 10) { bands in
                for band in 0..<10 { bands[band] = allBands ?? band0 }
            }
        }
        rf_store_eq_snapshot(harness.mem, &snapshot)
    }

    /// One timed callback. The stamp pair is the same instrumentation the
    /// production histogram uses, so the overhead is identical.
    private func timedBlock(_ harness: Harness, frameCount: UInt32? = nil) -> UInt64 {
        let start = mach_absolute_time()
        harness.renderer.render(
            bufferList: harness.output.list.unsafeMutablePointer,
            frameCount: frameCount ?? frames)
        return mach_absolute_time() &- start
    }

    // MARK: - Reporting helpers

    private func microseconds(_ tick: UInt64) -> Double {
        Double(tick) * Double(timebaseNumer) / Double(timebaseDenom) / 1_000.0
    }

    private struct Distribution {
        let label: String
        let ticks: [UInt64]
        let frames: UInt32
        let sampleRate: UInt32
        let timebase: (UInt64, UInt64)

        private func microseconds(_ tick: UInt64) -> Double {
            Double(tick) * Double(timebase.0) / Double(timebase.1) / 1_000.0
        }

        var deadlineMicroseconds: Double {
            Double(frames) / Double(sampleRate) * 1_000_000.0
        }

        func quantile(_ q: Double) -> Double {
            guard !ticks.isEmpty else { return 0 }
            let index = min(ticks.count - 1, max(0, Int(q * Double(ticks.count))))
            return microseconds(ticks[index])
        }

        var overDeadline: Int { ticks.filter { microseconds($0) > deadlineMicroseconds }.count }

        var utilisation: Double {
            guard deadlineMicroseconds > 0 else { return 0 }
            return quantile(0.99) / deadlineMicroseconds * 100.0
        }

        func line(extra: String = "") -> String {
            let p50 = quantile(0.50), p95 = quantile(0.95)
            let p99 = quantile(0.99), p999 = quantile(0.999)
            let maxUs = microseconds(ticks.max() ?? 0)
            let minUs = microseconds(ticks.min() ?? 0)
            return String(
                format: "| %@ | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %d | %.1f%% |%@",
                label, ticks.count, minUs, p50, p95, p99, p999, maxUs,
                deadlineMicroseconds, overDeadline, utilisation, extra.isEmpty ? "" : " " + extra
            )
        }
    }

    private func distribution(
        _ label: String, _ ticks: [UInt64], frames: UInt32 = 0
    ) -> Distribution {
        Distribution(
            label: label, ticks: ticks.sorted(),
            frames: frames == 0 ? self.frames : frames,
            sampleRate: sampleRate, timebase: (timebaseNumer, timebaseDenom)
        )
    }

    private func printHeader(_ title: String) {
        print("")
        print("### \(title)")
        print("")
        print("| scenario | n | min us | p50 us | p95 us | p99 us | p99.9 us | max us | deadline us | over | p99 of deadline | notes |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    }

    private func architecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private func fmt(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f", value)
    }

    /// `kCoeffRampSeconds = 0.01f` in `engine.cpp`: the length of the coefficient
    /// ramp that `apply_config` starts whenever a band's coefficients change.
    /// Restated here because it is not exported through the C header.
    private var coeffRampSamples: Int { Int(0.01 * Double(sampleRate)) }

    /// Mean cost of one call, from one stamp pair around the whole loop. The
    /// only trustworthy statistic at 41.67 ns tick granularity.
    private func meanNanoseconds(
        _ iterations: Int, _ body: () -> Void
    ) -> Double {
        let start = mach_absolute_time()
        for _ in 0..<iterations { body() }
        let elapsed = mach_absolute_time() &- start
        let nanoseconds = Double(elapsed) * Double(timebaseNumer) / Double(timebaseDenom)
        return nanoseconds / Double(iterations)
    }

    private final class Flag {
        private let lock = NSLock()
        private var storage = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }

    // MARK: - B1. Whole callback, through the real render function

    func testWholeCallbackDistributions() throws {
        let deadline = Double(frames) / Double(sampleRate) * 1_000_000.0
        print("")
        print("# Phase B — whole-callback distributions through `AudioRenderer.render`")
        print("")
        print("- sample rate: \(sampleRate) Hz")
        print("- frames per callback: \(frames)")
        print("- channels: 2")
        print("- callback deadline: \(String(format: "%.1f", deadline)) us")
        print("- architecture: \(architecture())")
        print("- build: release (`swift test -c release`)")
        print("- instrumentation: one `mach_absolute_time()` pair per callback around "
              + "`AudioRenderer.render`, plus the production histogram in the same call")
        print("- scenario length: \(steadyBlocks) callbacks "
              + "(\(String(format: "%.1f", Double(steadyBlocks) * Double(frames) / Double(sampleRate))) s of audio)")
        print("- this is in-process replay, **not** a real CoreAudio IO thread")

        printHeader("B1.1 Steady state and parameter-change scenarios")

        // 1. No parameter change.
        do {
            let harness = try makeHarness(device: "steady")
            defer { release(harness) }
            storeSnapshot(harness, band0: 0, allBands: 0, preamp: 0)
            for _ in 0..<50 { topUp(harness); _ = timedBlock(harness) }
            var ticks: [UInt64] = []
            ticks.reserveCapacity(steadyBlocks)
            for _ in 0..<steadyBlocks {
                topUp(harness)
                ticks.append(timedBlock(harness))
            }
            print(distribution("no parameter change", ticks).line())
            let production = harness.renderer.takeTimingSnapshot()
            print("")
            print("production histogram cross-check (same run): n=\(production.observations) "
                  + "p50=\(fmt(production.p50Microseconds))us p95=\(fmt(production.p95Microseconds))us "
                  + "p99=\(fmt(production.p99Microseconds))us max=\(fmt(production.maxMicroseconds))us "
                  + "saturated=\(production.maxIsSaturated) overBudget=\(production.overBudget)")
            let report = harness.renderer.takeDiagnostics()
            print("diagnostics: memoryUnavailable=\(report.memoryUnavailable) "
                  + "capacityExceeded=\(report.capacityExceeded) "
                  + "channelMismatch=\(report.channelMismatch) "
                  + "underrunFrames=\(report.underrunFrames) "
                  + "dspFrames=\(report.dsp.framesProcessed) "
                  + "cpu=\(String(format: "%.2f", report.dsp.cpuLoadPercent))%")
        }

        // 2. One band changes every callback.
        do {
            let harness = try makeHarness(device: "one-band")
            defer { release(harness) }
            for _ in 0..<50 { topUp(harness); _ = timedBlock(harness) }
            var ticks: [UInt64] = []
            ticks.reserveCapacity(eqBlocks)
            for iteration in 0..<eqBlocks {
                topUp(harness)
                storeSnapshot(
                    harness, band0: Float(iteration % 13) * 0.5 - 3.0, allBands: nil, preamp: 0)
                ticks.append(timedBlock(harness))
            }
            print(distribution("one band changes every callback", ticks).line())
        }

        // 3. All ten bands change every callback.
        do {
            let harness = try makeHarness(device: "ten-bands")
            defer { release(harness) }
            for _ in 0..<50 { topUp(harness); _ = timedBlock(harness) }
            var ticks: [UInt64] = []
            ticks.reserveCapacity(eqBlocks)
            for iteration in 0..<eqBlocks {
                topUp(harness)
                storeSnapshot(
                    harness, band0: 0, allBands: Float(iteration % 13) * 0.5 - 3.0, preamp: 0)
                ticks.append(timedBlock(harness))
            }
            print(distribution("ten bands change every callback", ticks).line())
        }

        // 4. Preamp only.
        do {
            let harness = try makeHarness(device: "preamp")
            defer { release(harness) }
            for _ in 0..<50 { topUp(harness); _ = timedBlock(harness) }
            var ticks: [UInt64] = []
            ticks.reserveCapacity(eqBlocks)
            for iteration in 0..<eqBlocks {
                topUp(harness)
                storeSnapshot(
                    harness, band0: 0, allBands: 0, preamp: Float(iteration % 9) * 0.5 - 2.0)
                ticks.append(timedBlock(harness))
            }
            print(distribution("preamp changes every callback", ticks).line())
        }

        // 7. Another thread rewrites the snapshot continuously: the seqlock is
        //    under real contention and every block sees a changed snapshot.
        do {
            let harness = try makeHarness(device: "writer-contention")
            defer { release(harness) }
            for _ in 0..<50 { topUp(harness); _ = timedBlock(harness) }

            let stop = Flag()
            let group = DispatchGroup()
            let mem = harness.mem
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                var iteration = 0
                while !stop.value {
                    var snapshot = RFEQSnapshot()
                    snapshot.bypass = false
                    snapshot.preamp = 0
                    withUnsafeMutablePointer(to: &snapshot.bands) { pointer in
                        pointer.withMemoryRebound(to: Float.self, capacity: 10) { bands in
                            for band in 0..<10 { bands[band] = Float((iteration + band) % 9) - 4 }
                        }
                    }
                    rf_store_eq_snapshot(mem, &snapshot)
                    iteration += 1
                }
            }

            var ticks: [UInt64] = []
            ticks.reserveCapacity(eqBlocks)
            for _ in 0..<eqBlocks {
                topUp(harness)
                ticks.append(timedBlock(harness))
            }
            stop.value = true
            XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
            print(distribution("snapshot rewritten by another thread", ticks).line())
        }

        // 8. High CPU: every core oversubscribed while callbacks run.
        do {
            let harness = try makeHarness(device: "high-cpu")
            defer { release(harness) }
            storeSnapshot(harness, band0: 0, allBands: 0, preamp: 0)
            for _ in 0..<50 { topUp(harness); _ = timedBlock(harness) }

            let stop = Flag()
            let group = DispatchGroup()
            let hogs = ProcessInfo.processInfo.activeProcessorCount * 2
            for _ in 0..<hogs {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    var accumulator: UInt64 = 0
                    while !stop.value { for i in 0..<10_000 { accumulator &+= UInt64(i) } }
                    if accumulator == 1 { print("unreachable") }
                }
            }

            var ticks: [UInt64] = []
            ticks.reserveCapacity(steadyBlocks)
            for _ in 0..<steadyBlocks {
                topUp(harness)
                ticks.append(timedBlock(harness))
            }
            stop.value = true
            XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
            print(distribution("steady state, \(hogs) CPU hogs", ticks).line())
        }

        printHeader("B1.2 Frame-size sweep (steady state vs. ten-band update)")
        for size in [UInt32(64), UInt32(128), UInt32(512), UInt32(1024)] {
            let blocks = max(2_000, min(20_000, 2_000_000 / Int(size)))
            do {
                let harness = try makeHarness(device: "sweep-\(size)")
                defer { release(harness) }
                storeSnapshot(harness, band0: 0, allBands: 0, preamp: 0)
                for _ in 0..<30 {
                    topUp(harness, frameCount: size)
                    _ = timedBlock(harness, frameCount: size)
                }
                var steady: [UInt64] = []
                steady.reserveCapacity(blocks)
                for _ in 0..<blocks {
                    topUp(harness, frameCount: size)
                    steady.append(timedBlock(harness, frameCount: size))
                }
                print(distribution("steady, \(size) frames", steady, frames: size).line())
                var changing: [UInt64] = []
                changing.reserveCapacity(blocks)
                for iteration in 0..<blocks {
                    topUp(harness, frameCount: size)
                    storeSnapshot(
                        harness, band0: 0, allBands: Float(iteration % 13) * 0.5 - 3.0, preamp: 0)
                    changing.append(timedBlock(harness, frameCount: size))
                }
                print(distribution("ten bands, \(size) frames", changing, frames: size).line())
            }
        }
        print("")
    }

    // MARK: - B2. Component decomposition

    func testComponentCosts() throws {
        print("")
        print("# Phase B — component costs on the real C entry points")
        print("")
        print("- sample rate: \(sampleRate) Hz")
        print("- architecture: \(architecture())")
        print("- build: release")
        print("- `mach_absolute_time` tick: "
              + String(format: "%.2f ns", Double(timebaseNumer) / Double(timebaseDenom))
              + " — means over a long loop, not per-call quantiles")
        print("")

        print("### B2.1 Mean cost per call")
        print("")
        print("| component | bands | n | mean ns | mean us | notes |")
        print("|---|---|---|---|---|---|")

        for bands in [UInt32(10), UInt32(1)] {
            let engine = try makeEngine(bands: bands)
            defer { soundbridge_dsp_destroy(engine) }

            var preset = soundbridge_preset_t()
            XCTAssertEqual(soundbridge_dsp_get_preset(engine, &preset), SOUNDBRIDGE_OK)
            print("| engine preset num_bands | \(preset.num_bands) | — | — | — | "
                  + "reported from `soundbridge_dsp_get_preset`, so the band count below is real |")

            let count = Int(frames) * 2
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            defer { buffer.deallocate() }
            for i in 0..<count { buffer[i] = sinf(Float(i) * 0.01) * 0.3 }
            for _ in 0..<200 { soundbridge_dsp_process_interleaved(engine, buffer, buffer, frames) }

            let processIterations = 20_000
            let processMean = meanNanoseconds(processIterations) {
                soundbridge_dsp_process_interleaved(engine, buffer, buffer, frames)
            }
            print(String(
                format: "| process_interleaved | %d | %d | %.0f | %.2f | 512 frames, both channels |",
                bands, processIterations, processMean, processMean / 1_000.0))

            let gains = [Float](repeating: 0, count: Int(SOUNDBRIDGE_MAX_BANDS))
            let updateIterations = 20_000
            var published = 0
            let updateMean = meanNanoseconds(updateIterations) {
                let ok = gains.withUnsafeBufferPointer {
                    soundbridge_dsp_try_update_eq(engine, $0.baseAddress!, 0)
                }
                if ok { published += 1 }
            }
            XCTAssertEqual(published, updateIterations, "an uncontended publisher must never be refused")
            print(String(
                format: "| try_update_eq (accepted) | %d | %d | %.0f | %.2f | recompute + one publish |",
                bands, updateIterations, updateMean, updateMean / 1_000.0))

            // The block that follows a real EQ change. `apply_config` starts a
            // 10 ms coefficient ramp (`kCoeffRampSeconds`) when the coefficients
            // differ, so every sample of the next 480 frames takes the
            // interpolation branch. This is what the whole-callback delta
            // between "steady" and "ten bands change" is actually made of; the
            // coefficient arithmetic itself is the `try_update_eq` row above.
            var rampedGains = [Float](repeating: 0, count: Int(SOUNDBRIDGE_MAX_BANDS))
            var rampIteration = 0
            let combinedIterations = 10_000
            let combinedMean = meanNanoseconds(combinedIterations) {
                rampIteration += 1
                for band in 0..<Int(bands) {
                    rampedGains[band] = Float((rampIteration + band) % 13) * 0.5 - 3.0
                }
                _ = rampedGains.withUnsafeBufferPointer {
                    soundbridge_dsp_try_update_eq(engine, $0.baseAddress!, 0)
                }
                soundbridge_dsp_process_interleaved(engine, buffer, buffer, frames)
            }
            print(String(
                format: "| try_update_eq + process_interleaved | %d | %d | %.0f | %.2f | "
                    + "one changed block, ramp active for %d of 512 frames |",
                bands, combinedIterations, combinedMean, combinedMean / 1_000.0,
                coeffRampSamples))
            print(String(
                format: "|   of which the ramp branch | %d | — | %.0f | %.2f | "
                    + "remainder after subtracting the two rows above |",
                bands, combinedMean - processMean - updateMean,
                (combinedMean - processMean - updateMean) / 1_000.0))
        }

        let harness = try makeHarness(device: "seqlock")
        defer { release(harness) }
        var out = RFEQSnapshot()
        let seqlockIterations = 200_000
        var quietRefusals = 0
        let seqlockMean = meanNanoseconds(seqlockIterations) {
            if !rf_load_eq_snapshot_safe(harness.mem, &out) { quietRefusals += 1 }
        }
        print(String(
            format: "| rf_load_eq_snapshot_safe (no writer) | — | %d | %.1f | %.3f | "
                + "48-byte copy + two acquire loads, gave up %d times |",
            seqlockIterations, seqlockMean, seqlockMean / 1_000.0, quietRefusals))

        // The same reader with a writer rewriting the snapshot as fast as it can.
        // `rf_load_eq_snapshot_safe` allows four attempts and then returns false,
        // so this row is where the cost of F-HC-02 can actually be seen.
        do {
            let stop = Flag()
            let group = DispatchGroup()
            let mem = harness.mem
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                var iteration = 0
                while !stop.value {
                    var snapshot = RFEQSnapshot()
                    snapshot.bypass = false
                    snapshot.preamp = 0
                    withUnsafeMutablePointer(to: &snapshot.bands) { pointer in
                        pointer.withMemoryRebound(to: Float.self, capacity: 10) { bands in
                            for band in 0..<10 { bands[band] = Float((iteration + band) % 9) - 4 }
                        }
                    }
                    rf_store_eq_snapshot(mem, &snapshot)
                    iteration += 1
                }
            }
            var busyRefusals = 0
            let contendedIterations = 200_000
            let contendedMean = meanNanoseconds(contendedIterations) {
                if !rf_load_eq_snapshot_safe(harness.mem, &out) { busyRefusals += 1 }
            }
            stop.value = true
            XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
            print(String(
                format: "| rf_load_eq_snapshot_safe (writer active) | — | %d | %.1f | %.3f | "
                    + "gave up after 4 attempts %d times (%.3f%%) |",
                contendedIterations, contendedMean, contendedMean / 1_000.0,
                busyRefusals, Double(busyRefusals) / Double(contendedIterations) * 100.0))
        }

        print("")
        print("### B2.2 Refusal path under real token contention")
        print("")

        let engine = try makeEngine(bands: 10)
        defer { soundbridge_dsp_destroy(engine) }

        let stop = Flag()
        let group = DispatchGroup()
        let flatPreset = self.flatPreset(bands: 10)
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            var preset = flatPreset
            var iteration = 0
            while !stop.value {
                preset.preamp_db = Float(iteration % 5) * 0.5
                _ = soundbridge_dsp_apply_preset(engine, &preset)
                iteration += 1
            }
        }

        var gains = [Float](repeating: 0, count: Int(SOUNDBRIDGE_MAX_BANDS))
        var acceptedCount = 0, refusedCount = 0, retrySucceeded = 0
        var acceptedTicks: UInt64 = 0, refusedTicks: UInt64 = 0
        let iterations = 60_000

        for iteration in 0..<iterations {
            gains[0] = Float(iteration % 13) * 0.5 - 3.0
            let start = mach_absolute_time()
            let first = gains.withUnsafeBufferPointer {
                soundbridge_dsp_try_update_eq(engine, $0.baseAddress!, 0)
            }
            let elapsed = mach_absolute_time() &- start
            if first {
                acceptedCount += 1
                acceptedTicks &+= elapsed
            } else {
                refusedCount += 1
                refusedTicks &+= elapsed
                let retry = gains.withUnsafeBufferPointer {
                    soundbridge_dsp_try_update_eq(engine, $0.baseAddress!, 0)
                }
                if retry { retrySucceeded += 1 }
            }
        }
        stop.value = true
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)

        let total = max(1, acceptedCount + refusedCount)
        print(String(format: "- refusal rate: %.2f%% (%d of %d single attempts)",
                     Double(refusedCount) / Double(total) * 100.0, refusedCount, total))
        print("- a second immediate attempt succeeded for \(retrySucceeded) of "
              + "\(refusedCount) refused attempts")
        print("")
        print("| bucket | n | mean ns | mean us | notes |")
        print("|---|---|---|---|---|")
        if acceptedCount > 0 {
            let mean = Double(acceptedTicks) * Double(timebaseNumer) / Double(timebaseDenom)
                / Double(acceptedCount)
            print(String(format: "| accepted | %d | %.0f | %.2f | recompute + publish |",
                         acceptedCount, mean, mean / 1_000.0))
        }
        if refusedCount > 0 {
            let mean = Double(refusedTicks) * Double(timebaseNumer) / Double(timebaseDenom)
                / Double(refusedCount)
            print(String(format: "| refused | %d | %.0f | %.2f | one failed exchange and return |",
                         refusedCount, mean, mean / 1_000.0))
        }
        print("")
    }

    // MARK: - Engine helpers

    private func flatPreset(bands: UInt32) -> soundbridge_preset_t {
        var preset = soundbridge_preset_t()
        preset.num_bands = bands
        preset.preamp_db = 0
        preset.limiter_enabled = true
        withUnsafeMutablePointer(to: &preset.bands) { pointer in
            pointer.withMemoryRebound(to: soundbridge_band_t.self, capacity: 10) { slots in
                for index in 0..<10 {
                    slots[index].frequency_hz = 1000
                    slots[index].gain_db = 0
                    slots[index].q_factor = 1.0
                    slots[index].type = SOUNDBRIDGE_FILTER_PEAK
                    slots[index].enabled = true
                }
            }
        }
        return preset
    }

    private func makeEngine(bands: UInt32) throws -> OpaquePointer {
        let engine = try XCTUnwrap(soundbridge_dsp_create(sampleRate))
        var preset = self.flatPreset(bands: bands)
        XCTAssertEqual(soundbridge_dsp_apply_preset(engine, &preset), SOUNDBRIDGE_OK)
        soundbridge_dsp_set_bypass(engine, false)
        return engine
    }
}

private final class NoPersistence: VolumeStatePersisting {
    func loadIfPresent(uid: String) -> DeviceVolumeState? { nil }
    func save(uid: String, volume: Float, muted: Bool) {}
}
