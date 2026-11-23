import XCTest
import Darwin
import AudioToolbox
@testable import SoundBridgeHost
import CSoundBridgeAudio
import CSoundBridgeDSP

// MARK: - Phase D: stress and soak on the Host render path
//
// WHAT THIS IS
//
//   Eight scenario classes run against the real `AudioRenderer.render` and a
//   real shared-memory mapping, at release optimisation. Each one reports what
//   it did and what it cost; none of them asserts an invented realtime
//   threshold. The only assertions are correctness ones: the callback never
//   refuses a block it should have served, the DSP frame count matches the
//   frames handed to it, and nothing is left in a bad state afterwards.
//
// WHAT THIS IS NOT
//
//   Not a real CoreAudio soak. There is no IO thread, no device and no thermal
//   load from a real audio stack. `underrunFrames` here measures the ring, i.e.
//   whether the fixture kept the producer ahead of the consumer; a zero DSP
//   underrun count is not evidence that audio was uninterrupted on hardware.
//   The per-scenario report says so again where it matters.
//
// RSS is the *test process*. The menu bar Host is a different process with a
// different footprint; treat the delta as "does this path leak", not as the
// Host's memory.
//
// HOW TO RUN
//
//   SB_RT_SOAK=1 swift test -c release --filter HostRealtimeSoakTests
//
// `SB_RT_SOAK_SCALE=<n>` multiplies every scenario length (default 1, 0.1 is a
// smoke test). The suite skips itself otherwise, so `make test-host` stays fast.

final class HostRealtimeSoakTests: XCTestCase {

    private var sandbox: URL!
    private var timebaseNumer: UInt64 = 1
    private var timebaseDenom: UInt64 = 1
    private var scale: Double = 1.0

    private let sampleRate: UInt32 = 48000
    private let frames: UInt32 = 512

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SB_RT_SOAK"] == "1",
            "Soak suite: set SB_RT_SOAK=1 to run it"
        )
        if let raw = ProcessInfo.processInfo.environment["SB_RT_SOAK_SCALE"],
           let value = Double(raw), value > 0 {
            scale = value
        }

        var timebase = mach_timebase_info_data_t()
        XCTAssertEqual(mach_timebase_info(&timebase), KERN_SUCCESS)
        timebaseNumer = UInt64(timebase.numer)
        timebaseDenom = UInt64(timebase.denom)

        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeSoak-\(UUID().uuidString)", isDirectory: true)
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

    /// One manager, one mapping, named as the preferred render UID, so the
    /// shared render gate cannot serve a mapping the fixture is not feeding.
    private func makeManager(_ device: String) throws -> (SharedMemoryManager, String) {
        let directory = sandbox.appendingPathComponent(device, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SharedMemoryManager(
            sessionID: UUID(),
            pathForUID: { "\(directory.path)/soundbridge-\($0)" }
        )
        XCTAssertEqual(manager.createMemory(for: device, persistence: NoPersistence()), .created)
        manager.setPreferredRenderUID(device)
        let mem = try XCTUnwrap(manager.getMemory(for: device))
        manager.publishVolumeState(for: device, scalar: 1.0, muted: false)
        storeFlatEQ(mem)
        // Start empty: this suite is about lifecycle, the signal is filler.
        drain(mem)
        return (manager, directory.path)
    }

    private func storeFlatEQ(_ mem: UnsafeMutablePointer<RFSharedAudio>) {
        var snapshot = RFEQSnapshot()
        snapshot.bypass = false
        snapshot.preamp = 0
        withUnsafeMutablePointer(to: &snapshot.bands) { pointer in
            pointer.withMemoryRebound(to: Float.self, capacity: 10) { bands in
                for band in 0..<10 { bands[band] = 0 }
            }
        }
        rf_store_eq_snapshot(mem, &snapshot)
    }

    private func storeEQ(
        _ mem: UnsafeMutablePointer<RFSharedAudio>, seed: Int,
        preamp: Float = 0, bypass: Bool = false
    ) {
        var snapshot = RFEQSnapshot()
        snapshot.bypass = bypass
        snapshot.preamp = preamp
        withUnsafeMutablePointer(to: &snapshot.bands) { pointer in
            pointer.withMemoryRebound(to: Float.self, capacity: 10) { bands in
                for band in 0..<10 { bands[band] = Float((seed + band) % 13) * 0.5 - 3.0 }
            }
        }
        rf_store_eq_snapshot(mem, &snapshot)
    }

    private func drain(_ mem: UnsafeMutablePointer<RFSharedAudio>) {
        let capacity = Int(mem.pointee.ring_capacity_frames)
        let channels = Int(mem.pointee.channels)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        defer { scratch.deallocate() }
        var written: UInt32 = 0
        while rf_ring_read(mem, scratch, UInt32(capacity), &written) > 0 {}
    }

    private func feed(
        _ mem: UnsafeMutablePointer<RFSharedAudio>, frames count: UInt32,
        staging: UnsafeMutablePointer<Float>, capacity: Int
    ) {
        XCTAssertLessThanOrEqual(Int(count), capacity, "the fixture buffer must cover the block")
        var dropped: UInt32 = 0
        _ = rf_ring_write_unchecked(mem, staging, count, &dropped)
    }

    private struct Scenario {
        let manager: SharedMemoryManager
        let mem: UnsafeMutablePointer<RFSharedAudio>
        let renderer: AudioRenderer
        let output: PlanarBuffers
        let staging: UnsafeMutablePointer<Float>
        let stagingCapacity: Int
        let channels: Int
    }

    private func makeScenario(device: String) throws -> Scenario {
        let (manager, _) = try makeManager(device)
        let mem = try XCTUnwrap(manager.getMemory(for: device))
        let channels = Int(mem.pointee.channels)
        let capacity = Int(mem.pointee.ring_capacity_frames)
        let staging = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        staging.initialize(repeating: 0, count: capacity * channels)
        for frame in 0..<capacity {
            let value = 0.3 * sinf(2 * Float.pi * 440 * Float(frame) / Float(sampleRate))
            for channel in 0..<channels { staging[frame * channels + channel] = value }
        }
        return Scenario(
            manager: manager, mem: mem,
            renderer: AudioRenderer(memoryManager: manager),
            output: PlanarBuffers(channels: channels, frames: 4096),
            staging: staging, stagingCapacity: capacity, channels: channels
        )
    }

    private func release(_ scenario: Scenario) {
        scenario.manager.cleanup()
        scenario.staging.deinitialize(count: scenario.stagingCapacity * scenario.channels)
        scenario.staging.deallocate()
    }

    // MARK: - Reporting helpers

    private func microseconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebaseNumer) / Double(timebaseDenom) / 1_000.0
    }

    private func megabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / (1024.0 * 1024.0)
    }

    /// Resident size of *this* process. The menu bar Host is a different process.
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private func callbacks(_ base: Int) -> Int {
        max(64, Int(Double(base) * scale))
    }

    private struct SoakResult {
        var blocks: Int = 0
        var ticks: [UInt64] = []
        var overruns = 0
    }

    /// Runs `blocks` callbacks, feeding one block ahead of each, and returns the
    /// per-callback cost distribution. The feed is outside the timed region, as a
    /// real producer's write would be.
    private func run(
        _ scenario: Scenario, blocks: Int, frameCount: UInt32? = nil,
        every nth: Int = 1, _ mutate: ((Int) -> Void)? = nil
    ) -> SoakResult {
        let count = frameCount ?? frames
        var result = SoakResult()
        result.ticks.reserveCapacity(blocks)
        // Warm up the caches, the coefficient ramps and the denormal state.
        for _ in 0..<32 {
            feed(scenario.mem, frames: count, staging: scenario.staging,
                 capacity: scenario.stagingCapacity)
            scenario.renderer.render(
                bufferList: scenario.output.list.unsafeMutablePointer, frameCount: count)
        }
        for iteration in 0..<blocks {
            if let mutate, iteration % nth == 0 { mutate(iteration) }
            feed(scenario.mem, frames: count, staging: scenario.staging,
                 capacity: scenario.stagingCapacity)
            let start = mach_absolute_time()
            scenario.renderer.render(
                bufferList: scenario.output.list.unsafeMutablePointer, frameCount: count)
            result.ticks.append(mach_absolute_time() &- start)
        }
        result.blocks = blocks
        let deadline = Double(count) / Double(sampleRate) * 1_000_000.0
        result.overruns = result.ticks.filter { microseconds($0) > deadline }.count
        return result
    }

    private func report(_ label: String, _ result: SoakResult, frameCount: UInt32? = nil) {
        let count = frameCount ?? frames
        let sorted = result.ticks.sorted()
        let deadline = Double(count) / Double(sampleRate) * 1_000_000.0
        func q(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return microseconds(sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))])
        }
        print(String(
            format: "| %@ | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %d | %.2f%% |",
            label, result.blocks, q(0.50), q(0.95), q(0.99),
            microseconds(sorted.last ?? 0), deadline, result.overruns,
            q(0.99) / deadline * 100.0))
    }

    private func tableHeader(_ title: String) {
        print("")
        print("### \(title)")
        print("")
        print("| scenario | callbacks | p50 us | p95 us | p99 us | max us | deadline us | over deadline | p99 of deadline |")
        print("|---|---|---|---|---|---|---|---|---|")
    }

    // MARK: - D1. Steady soak with periodic EQ updates

    /// The scenario that would show a leak: one render path, one mapping, tens of
    /// thousands of callbacks, a parameter change every so often, and RSS sampled
    /// along the way. Nothing is recreated, so any growth is the steady-state path.
    func testSoakSteadyStateWithPeriodicEQ() throws {
        let blocks = callbacks(200_000)
        let scenario = try makeScenario(device: "soak-steady")
        defer { release(scenario) }

        print("")
        print("# Phase D — Host render path stress and soak")
        print("")
        print("- sample rate: \(sampleRate) Hz, \(frames) frames per callback, 2 channels")
        print("- build: release (`swift test -c release`), arm64")
        print("- scenario length: \(blocks) callbacks = "
              + String(format: "%.1f", Double(blocks) * Double(frames) / Double(sampleRate) / 60.0)
              + " min of audio")
        print("- this is in-process replay, **not** a real CoreAudio IO thread")
        print("")

        let baseline = residentBytes()
        var checkpoints: [UInt64] = []
        var ticks: [UInt64] = []
        ticks.reserveCapacity(blocks)
        let checkpointEvery = max(1, blocks / 10)

        for _ in 0..<32 {
            feed(scenario.mem, frames: frames, staging: scenario.staging,
                 capacity: scenario.stagingCapacity)
            scenario.renderer.render(
                bufferList: scenario.output.list.unsafeMutablePointer, frameCount: frames)
        }

        for iteration in 0..<blocks {
            if iteration % 64 == 0 { storeEQ(scenario.mem, seed: iteration / 64) }
            feed(scenario.mem, frames: frames, staging: scenario.staging,
                 capacity: scenario.stagingCapacity)
            let start = mach_absolute_time()
            scenario.renderer.render(
                bufferList: scenario.output.list.unsafeMutablePointer, frameCount: frames)
            ticks.append(mach_absolute_time() &- start)
            if iteration % checkpointEvery == 0 { checkpoints.append(residentBytes()) }
        }
        checkpoints.append(residentBytes())

        let deadline = Double(frames) / Double(sampleRate) * 1_000_000.0
        let sorted = ticks.sorted()
        func q(_ p: Double) -> Double {
            microseconds(sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))])
        }
        let diagnostics = scenario.renderer.takeDiagnostics()
        let production = scenario.renderer.takeTimingSnapshot()

        print("### D1 Steady soak, EQ change every 64 callbacks")
        print("")
        print("| metric | value |")
        print("|---|---|")
        print("| callbacks | \(blocks) |")
        print(String(format: "| p50 / p95 / p99 / max (us) | %.1f / %.1f / %.1f / %.1f |",
                     q(0.50), q(0.95), q(0.99), microseconds(sorted.last ?? 0)))
        print(String(format: "| callback deadline (us) | %.1f |", deadline))
        print("| callbacks over deadline | \(ticks.filter { microseconds($0) > deadline }.count) |")
        print("| production histogram p99 / max (us) | "
              + "\(production.p99Microseconds.map { String(format: "%.1f", $0) } ?? "n/a") / "
              + "\(production.maxMicroseconds.map { String(format: "%.1f", $0) } ?? "n/a")"
              + "\(production.maxIsSaturated ? " (saturated)" : "") |")
        print("| production over-budget blocks | \(production.overBudget) |")
        print("| ring underrun frames | \(diagnostics.underrunFrames) |")
        print("| DSP frames processed | \(diagnostics.dsp.framesProcessed) |")
        print(String(format: "| DSP cpu load (engine EMA) | %.3f%% |", diagnostics.dsp.cpuLoadPercent))
        print("| refusals (memory / capacity / channels) | "
              + "\(diagnostics.memoryUnavailable) / \(diagnostics.capacityExceeded) / \(diagnostics.channelMismatch) |")
        print(String(format: "| RSS at start (test process) | %.1f MB |", megabytes(baseline)))
        print("| RSS checkpoints (MB) | "
              + checkpoints.map { String(format: "%.1f", megabytes($0)) }.joined(separator: " -> ")
              + " |")
        let growth = Int64(checkpoints.last ?? 0) - Int64(checkpoints.first ?? 0)
        print(String(format: "| RSS delta first to last (MB) | %+.1f |", megabytes(UInt64(abs(growth)))))
        print("")
        print("Ring underruns are a producer/consumer property of this fixture, not a "
              + "statement about hardware audio. A zero DSP underrun count is not "
              + "evidence that audio was uninterrupted.")
        print("")

        XCTAssertEqual(diagnostics.memoryUnavailable, 0, "a live mapping must never be refused")
        XCTAssertEqual(diagnostics.channelMismatch, 0)
        XCTAssertEqual(diagnostics.dsp.framesProcessed, UInt64(blocks + 32) * UInt64(frames),
                       "every callback's frames must reach the DSP")
    }

    // MARK: - D2. Parameter storm

    /// A snapshot rewritten on every single block, plus preamp movement and a
    /// bypass toggle now and then: the worst case for the change-detection and
    /// ramp paths.
    func testSoakParameterStorm() throws {
        let blocks = callbacks(100_000)
        let scenario = try makeScenario(device: "soak-storm")
        defer { release(scenario) }

        tableHeader("D2 Parameter storm: snapshot rewritten every callback")
        let result = run(scenario, blocks: blocks) { iteration in
            // Bypass is a field of the snapshot, so toggling it is the same
            // publish path the settings window uses.
            self.storeEQ(
                scenario.mem, seed: iteration,
                preamp: Float(iteration % 9) * 0.5 - 2.0,
                bypass: (iteration / 5000) % 2 == 1)
        }
        report("every block changes (10 bands + preamp, bypass toggles)", result)
        print("")

        let diagnostics = scenario.renderer.takeDiagnostics()
        let production = scenario.renderer.takeTimingSnapshot()
        print("diagnostics: dspFrames=\(diagnostics.dsp.framesProcessed) "
              + "underrunFrames=\(diagnostics.underrunFrames) "
              + "refusals=\(diagnostics.memoryUnavailable)/\(diagnostics.capacityExceeded)"
              + "/\(diagnostics.channelMismatch)")
        print("production histogram: n=\(production.observations) "
              + "overBudget=\(production.overBudget) saturated=\(production.maxIsSaturated)")
        print("")
        XCTAssertEqual(diagnostics.memoryUnavailable, 0)
        XCTAssertEqual(diagnostics.dsp.framesProcessed, UInt64(blocks + 32) * UInt64(frames))
    }

    // MARK: - D3. Render path churn

    /// Start/stop over one live mapping, the way a device switch or a settings
    /// change does it. The mapping outlives every engine.
    func testSoakRenderPathChurn() throws {
        let cycles = callbacks(400)
        let (manager, _) = try makeManager("soak-churn-path")
        let mem = try XCTUnwrap(manager.getMemory(for: "soak-churn-path"))
        let channels = Int(mem.pointee.channels)
        let capacity = Int(mem.pointee.ring_capacity_frames)
        let staging = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        staging.initialize(repeating: 0, count: capacity * channels)
        defer {
            staging.deinitialize(count: capacity * channels)
            staging.deallocate()
            manager.cleanup()
        }

        var failures = 0
        var mismatches = 0
        for _ in 0..<cycles {
            let output = PlanarBuffers(channels: channels, frames: Int(frames))
            let renderer = AudioRenderer(memoryManager: manager)
            var dropped: UInt32 = 0
            _ = rf_ring_write_unchecked(mem, staging, frames, &dropped)
            renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: frames)
            let snapshot = renderer.takeDiagnostics()
            failures += Int(snapshot.memoryUnavailable)
            mismatches += snapshot.dsp.framesProcessed == UInt64(frames) ? 0 : 1
        }

        print("")
        print("### D3 Render path churn: \(cycles) create/render/destroy cycles over one mapping")
        print("")
        print("- refusals (a live mapping was unavailable): \(failures)")
        print("- cycles where the DSP did not see all \(frames) frames: \(mismatches)")
        print("")
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(mismatches, 0)
    }

    // MARK: - D4. Sample-rate churn

    /// Repeated rate changes on an idle path. Each one must succeed, and each new
    /// rate must be adopted at the next block boundary.
    func testSoakSampleRateChurn() throws {
        let cycles = callbacks(200)
        let scenario = try makeScenario(device: "soak-churn-rate")
        defer { release(scenario) }

        let rates: [UInt32] = [44_100, 48_000, 96_000, 192_000]
        var refused = 0
        var notAdopted = 0
        for cycle in 0..<cycles {
            let target = rates[cycle % rates.count]
            if !scenario.renderer.updateSampleRate(target) {
                refused += 1
                continue
            }
            feed(scenario.mem, frames: frames, staging: scenario.staging,
                 capacity: scenario.stagingCapacity)
            scenario.renderer.render(
                bufferList: scenario.output.list.unsafeMutablePointer, frameCount: frames)
            if scenario.renderer.takeDiagnostics().dsp.sampleRate != target {
                notAdopted += 1
            }
        }

        print("")
        print("### D4 Sample-rate churn: \(cycles) changes across \(rates.count) rates")
        print("")
        print("- changes refused on an idle path: \(refused)")
        print("- changes not adopted on the next block: \(notAdopted)")
        print("")
        XCTAssertEqual(refused, 0, "an idle render path must accept a rebuild")
        XCTAssertEqual(notAdopted, 0)
    }

    // MARK: - D5. Device removal / reappearance churn

    /// The mapping is deleted and recreated under the same UID while a renderer
    /// keeps calling. The callback must refuse cleanly while the mapping is gone
    /// and resume when it comes back, with no stale pointer anywhere.
    func testSoakDeviceRemovalAndReappearance() throws {
        let uid = "soak-hotplug"
        let cycles = callbacks(150)
        let (manager, _) = try makeManager(uid)
        defer { manager.cleanup() }
        let renderer = AudioRenderer(memoryManager: manager)
        let output = PlanarBuffers(channels: 2, frames: Int(frames))

        var refusedWhileGone = 0
        var servedAfterReturn = 0
        var badPointer = 0

        for _ in 0..<cycles {
            // Gone: the callback must refuse rather than read a dead mapping.
            manager.removeMemory(for: uid)
            renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: frames)
            refusedWhileGone = Int(renderer.takeDiagnostics().memoryUnavailable)

            // Back: same UID, new incarnation.
            let origin = manager.createMemory(for: uid, persistence: NoPersistence())
            if origin == nil { badPointer += 1; continue }
            guard let mem = manager.getMemory(for: uid) else { badPointer += 1; continue }
            storeFlatEQ(mem)
            var dropped: UInt32 = 0
            let staging = UnsafeMutablePointer<Float>.allocate(
                capacity: Int(frames) * Int(mem.pointee.channels))
            staging.initialize(repeating: 0.2, count: Int(frames) * Int(mem.pointee.channels))
            _ = rf_ring_write_unchecked(mem, staging, frames, &dropped)
            let before = renderer.takeDiagnostics().dsp.framesProcessed
            renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: frames)
            staging.deinitialize(count: Int(frames) * Int(mem.pointee.channels))
            staging.deallocate()
            if renderer.takeDiagnostics().dsp.framesProcessed - before == UInt64(frames) {
                servedAfterReturn += 1
            }
        }

        print("")
        print("### D5 Device removal / reappearance: \(cycles) cycles")
        print("")
        print("- refusal counted on the callback that ran with no mapping: \(refusedWhileGone)")
        print("- cycles where the mapping could not be recreated: \(badPointer)")
        print("- cycles where the returned mapping served the DSP: \(servedAfterReturn)")
        print("")
        print("The renderer keeps no pointer across callbacks: the mapping is entered "
              + "and left inside one callback, so a removal between two callbacks cannot "
              + "leave it holding freed memory.")
        print("")
        XCTAssertEqual(badPointer, 0)
        XCTAssertEqual(servedAfterReturn, cycles)
    }

    // MARK: - D6. Hostile writer

    /// Another thread rewrites the snapshot as fast as it can while the callback
    /// runs. This is the seqlock under maximum pressure: the reader may give up
    /// and keep the previous snapshot, but it must never block or tear.
    func testSoakHostileWriterContention() throws {
        let blocks = callbacks(100_000)
        let scenario = try makeScenario(device: "soak-writer")
        defer { release(scenario) }

        final class Flag {
            private let lock = NSLock()
            private var storage = false
            var value: Bool {
                get { lock.lock(); defer { lock.unlock() }; return storage }
                set { lock.lock(); storage = newValue; lock.unlock() }
            }
        }

        let stop = Flag()
        let group = DispatchGroup()
        let mem = scenario.mem
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
                        for band in 0..<10 {
                            bands[band] = Float((iteration + band) % 9) - 4
                        }
                    }
                }
                rf_store_eq_snapshot(mem, &snapshot)
                iteration += 1
            }
        }

        tableHeader("D6 Hostile writer: another thread rewrites the snapshot continuously")
        let result = run(scenario, blocks: blocks)
        stop.value = true
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)
        report("callback with a writer spinning on the snapshot", result)

        let diagnostics = scenario.renderer.takeDiagnostics()
        print("")
        print("diagnostics: dspFrames=\(diagnostics.dsp.framesProcessed) "
              + "underrunFrames=\(diagnostics.underrunFrames) refusals=\(diagnostics.memoryUnavailable)")
        print("")
        XCTAssertEqual(diagnostics.memoryUnavailable, 0)
        XCTAssertEqual(diagnostics.dsp.framesProcessed, UInt64(blocks + 32) * UInt64(frames))
    }

    // MARK: - D7. CPU oversubscription

    /// Every core oversubscribed while callbacks run. The point is the tail, not
    /// the median: this is where a preempted caller shows up.
    func testSoakHighCPULoad() throws {
        let blocks = callbacks(100_000)
        let scenario = try makeScenario(device: "soak-cpu")
        defer { release(scenario) }

        final class Flag {
            private let lock = NSLock()
            private var storage = false
            var value: Bool {
                get { lock.lock(); defer { lock.unlock() }; return storage }
                set { lock.lock(); storage = newValue; lock.unlock() }
            }
        }

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

        tableHeader("D7 High CPU: \(hogs) hogs on \(ProcessInfo.processInfo.activeProcessorCount) cores")
        let result = run(scenario, blocks: blocks) { iteration in
            if iteration % 256 == 0 { self.storeEQ(scenario.mem, seed: iteration / 256) }
        }
        stop.value = true
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success)
        report("callbacks under \(hogs) CPU hogs, EQ every 256", result)

        let diagnostics = scenario.renderer.takeDiagnostics()
        let production = scenario.renderer.takeTimingSnapshot()
        print("")
        print("production histogram under load: n=\(production.observations) "
              + "p99=\(production.p99Microseconds.map { String(format: "%.1f", $0) } ?? "n/a")us "
              + "max=\(production.maxMicroseconds.map { String(format: "%.1f", $0) } ?? "n/a")us "
              + "overBudget=\(production.overBudget)")
        print("diagnostics: refusals=\(diagnostics.memoryUnavailable) "
              + "underrunFrames=\(diagnostics.underrunFrames)")
        print("")
        XCTAssertEqual(diagnostics.memoryUnavailable, 0)
    }

    // MARK: - D8. Buffer-size variation

    /// The block size changes every callback, as it does when a device changes
    /// its IO buffer. Nothing may be sized for the previous block.
    func testSoakBufferSizeVariation() throws {
        let blocks = callbacks(60_000)
        let scenario = try makeScenario(device: "soak-buffersize")
        defer { release(scenario) }

        let sizes: [UInt32] = [32, 64, 128, 256, 512, 1024, 2048]
        print("")
        print("### D8 Buffer-size variation: block size changes every callback")
        print("")
        print("- sizes cycled: \(sizes.map(String.init).joined(separator: ", "))")
        print("")

        for _ in 0..<32 {
            feed(scenario.mem, frames: 512, staging: scenario.staging,
                 capacity: scenario.stagingCapacity)
            scenario.renderer.render(
                bufferList: scenario.output.list.unsafeMutablePointer, frameCount: 512)
        }

        var ticks: [UInt64] = []
        ticks.reserveCapacity(blocks)
        for iteration in 0..<blocks {
            let size = sizes[iteration % sizes.count]
            if iteration % 32 == 0 { storeEQ(scenario.mem, seed: iteration / 32) }
            feed(scenario.mem, frames: size, staging: scenario.staging,
                 capacity: scenario.stagingCapacity)
            let start = mach_absolute_time()
            scenario.renderer.render(
                bufferList: scenario.output.list.unsafeMutablePointer, frameCount: size)
            ticks.append(mach_absolute_time() &- start)
        }

        let sorted = ticks.sorted()
        let diagnostics = scenario.renderer.takeDiagnostics()
        print("| metric | value |")
        print("|---|---|")
        print("| callbacks | \(blocks) |")
        print(String(format: "| p50 / p99 / max (us) | %.1f / %.1f / %.1f |",
                     microseconds(sorted[sorted.count / 2]),
                     microseconds(sorted[min(sorted.count - 1, Int(0.99 * Double(sorted.count)))]),
                     microseconds(sorted.last ?? 0)))
        print("| refusals (memory / capacity / channels) | "
              + "\(diagnostics.memoryUnavailable) / \(diagnostics.capacityExceeded) / "
              + "\(diagnostics.channelMismatch) |")
        print("| DSP frames processed | \(diagnostics.dsp.framesProcessed) |")
        print("")
        let expected = (0..<blocks).reduce(UInt64(0)) {
            $0 + UInt64(sizes[$1 % sizes.count])
        } + 32 * 512
        XCTAssertEqual(diagnostics.memoryUnavailable, 0)
        XCTAssertEqual(diagnostics.capacityExceeded, 0)
        XCTAssertEqual(diagnostics.dsp.framesProcessed, expected)
    }
}

private final class NoPersistence: VolumeStatePersisting {
    func loadIfPresent(uid: String) -> DeviceVolumeState? { nil }
    func save(uid: String, volume: Float, muted: Bool) {}
}
