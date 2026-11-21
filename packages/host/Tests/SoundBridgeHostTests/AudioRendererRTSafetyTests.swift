import XCTest
import Darwin
import AudioToolbox
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - P2 Batch 4: the render callback's real-time contract, exercised
//
// What these tests can prove and what they cannot:
//
//   - They call the SAME function CoreAudio calls (`AudioRenderer.render`),
//     with a real `AudioBufferList` and a real shared-memory mapping created by
//     the real `SharedMemoryManager`. Nothing is simulated except the HAL
//     itself, which never enters the picture: no device is opened, no IO thread
//     exists, and the timing of a callback burst is not reproduced.
//   - They therefore prove behaviour (what the callback writes, what it refuses,
//     whether it allocates or moves its scratch buffer), not real-time
//     scheduling. A pass here is not evidence that a real IO thread never
//     misses a deadline; that stays "needs a real macOS run".
//   - `RF_TEST_TONE` is not set, so the callback always reads the ring.

final class AudioRendererRTSafetyTests: XCTestCase {

    private var sandbox: URL!
    private var manager: SharedMemoryManager!
    private let uid = "rt-safety-device-0"

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeRT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let directory = sandbox!
        manager = SharedMemoryManager(
            sessionID: UUID(),
            pathForUID: { "\(directory.path)/soundbridge-\($0)" }
        )
    }

    override func tearDownWithError() throws {
        if manager != nil {
            manager.cleanup()
            manager = nil
        }
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    /// A real mapping, a pre-allocated renderer, and an empty ring.
    ///
    /// `volume == 1` makes the gain stage a bit-perfect passthrough and
    /// `eqBypassed` makes the DSP a `memcpy`, so byte-exact assertions are about
    /// the buffer plumbing rather than about biquad state.
    private struct Fixture {
        let mem: UnsafeMutablePointer<RFSharedAudio>
        let renderer: AudioRenderer
    }

    @discardableResult
    private func makeFixture(
        uid: String? = nil,
        volume: Float = 1.0,
        muted: Bool = false,
        eqBypassed: Bool = true
    ) throws -> Fixture {
        let device = uid ?? self.uid
        XCTAssertEqual(manager.createMemory(for: device, persistence: NoPersistence()), .created)
        let mem = try XCTUnwrap(manager.getMemory(for: device))
        manager.publishVolumeState(for: device, scalar: volume, muted: muted)

        if eqBypassed {
            var snapshot = RFEQSnapshot()
            snapshot.bypass = true
            rf_store_eq_snapshot(mem, &snapshot)
        }

        drainRing(mem)
        return Fixture(mem: mem, renderer: AudioRenderer(memoryManager: manager))
    }

    /// Consume the pre-publish prefill so a test sees exactly the frames it wrote.
    private func drainRing(_ mem: UnsafeMutablePointer<RFSharedAudio>) {
        let capacity = Int(mem.pointee.ring_capacity_frames)
        let channels = Int(mem.pointee.channels)
        guard capacity > 0, channels > 0 else { return }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        defer { scratch.deallocate() }
        var zeroFilled: UInt32 = 0
        while rf_ring_read(mem, scratch, UInt32(capacity), &zeroFilled) > 0 {}
    }

    /// Producer-side fill, bypassing admission (this is a fixture, not a driver).
    private func writeFrames(
        _ mem: UnsafeMutablePointer<RFSharedAudio>,
        frames: Int,
        sample: (Int, Int) -> Float
    ) {
        let channels = Int(mem.pointee.channels)
        let interleaved = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
        defer { interleaved.deallocate() }
        for frame in 0..<frames {
            for channel in 0..<channels {
                interleaved[frame * channels + channel] = sample(frame, channel)
            }
        }
        var dropped: UInt32 = 0
        let written = rf_ring_write_unchecked(mem, interleaved, UInt32(frames), &dropped)
        XCTAssertEqual(written, UInt32(frames), "fixture failed to stage frames in the ring")
    }

    // MARK: - Output buffer list helper

    /// A real (non-interleaved) `AudioBufferList`, one planar buffer per channel,
    /// owned and freed automatically at the end of the test scope.
    ///
    /// `allocated` is the real allocation; `reported` is what `mDataByteSize`
    /// claims. The two differ only in the short-buffer test, where the gap is a
    /// guard region the callback must not touch.
    private final class OutputBuffers {
        let list: UnsafeMutableAudioBufferListPointer
        private let storage: [UnsafeMutableRawPointer]
        private let allocatedFloats: Int

        init(channels: Int, frames: Int, reported: Int? = nil, initial: Float = 0) {
            let capacity = frames
            let advertised = reported ?? frames
            self.allocatedFloats = capacity
            self.list = AudioBufferList.allocate(maximumBuffers: channels)
            list.count = channels

            var storage: [UnsafeMutableRawPointer] = []
            for index in 0..<channels {
                let raw = UnsafeMutableRawPointer.allocate(
                    byteCount: capacity * MemoryLayout<Float>.size,
                    alignment: MemoryLayout<Float>.alignment
                )
                raw.initializeMemory(as: Float.self, repeating: initial, count: capacity)
                storage.append(raw)
                list[index] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(advertised * MemoryLayout<Float>.size),
                    mData: raw
                )
            }
            self.storage = storage
        }

        deinit {
            for raw in storage { raw.deallocate() }
            free(list.unsafeMutablePointer)
        }

        func samples(_ channel: Int) -> UnsafeMutablePointer<Float> {
            list[channel].mData!.assumingMemoryBound(to: Float.self)
        }

        /// Every resident float in every channel is zero.
        func allZero() -> Bool {
            (0..<list.count).allSatisfy { channel in
                (0..<allocatedFloats).allSatisfy { samples(channel)[$0] == 0 }
            }
        }
    }

    // MARK: - 1. The normal callback

    func testNormalCallbackCopiesRingContentChannelByChannel() throws {
        let fixture = try makeFixture()
        // Distinct per channel, well below the limiter knee.
        writeFrames(fixture.mem, frames: 512) { _, channel in channel == 0 ? 0.25 : -0.5 }

        let output = OutputBuffers(channels: 2, frames: 512)
        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 512)

        let left = output.samples(0)
        let right = output.samples(1)
        for frame in 0..<512 {
            XCTAssertEqual(left[frame], 0.25, accuracy: 1e-7, "left @\(frame)")
            XCTAssertEqual(right[frame], -0.5, accuracy: 1e-7, "right @\(frame)")
        }

        let diagnostics = fixture.renderer.takeDiagnostics()
        XCTAssertEqual(diagnostics.memoryUnavailable, 0)
        XCTAssertEqual(diagnostics.capacityExceeded, 0)
        XCTAssertEqual(diagnostics.channelMismatch, 0)
        XCTAssertEqual(diagnostics.underrunFrames, 0)
        XCTAssertEqual(diagnostics.firstPass?.frames, 512)
        XCTAssertEqual(diagnostics.firstPass?.channels, 2)
    }

    func testCapacityDerivesFromTheFrozenRingHelper() {
        let renderer = AudioRenderer(memoryManager: manager)
        XCTAssertEqual(
            renderer.renderCapacityFrames,
            Int(rf_ring_capacity_frames_for(SoundBridgeConfig.maxSupportedSampleRate,
                                            SoundBridgeConfig.defaultDurationMs))
        )
        XCTAssertEqual(renderer.renderCapacityChannels, 8, "the header documents 1-8 channels")
        XCTAssertGreaterThanOrEqual(
            renderer.renderCapacityFrames,
            Int(rf_ring_capacity_frames_for(48_000, SoundBridgeConfig.defaultDurationMs)),
            "capacity at the top rate must cover the capacity at the running rate"
        )
    }

    // MARK: - 2. Boundaries

    func testMaximumFrameCountIsAcceptedAndTheTailIsSilent() throws {
        let fixture = try makeFixture()
        let ringCapacity = Int(fixture.mem.pointee.ring_capacity_frames)
        writeFrames(fixture.mem, frames: ringCapacity) { _, _ in 0.1 }

        let frames = fixture.renderer.renderCapacityFrames
        XCTAssertGreaterThan(frames, ringCapacity, "the fixture must exercise the zero-filled tail")

        let output = OutputBuffers(channels: 2, frames: frames)
        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: UInt32(frames))

        for frame in 0..<ringCapacity {
            XCTAssertEqual(output.samples(0)[frame], 0.1, accuracy: 1e-7)
            XCTAssertEqual(output.samples(1)[frame], 0.1, accuracy: 1e-7)
        }
        for frame in ringCapacity..<frames {
            XCTAssertEqual(output.samples(0)[frame], 0, "tail @\(frame) must be silent")
            XCTAssertEqual(output.samples(1)[frame], 0)
        }

        let diagnostics = fixture.renderer.takeDiagnostics()
        XCTAssertEqual(diagnostics.capacityExceeded, 0, "the maximum block is legal")
        XCTAssertEqual(diagnostics.underrunFrames, UInt64(frames - ringCapacity))
    }

    func testBlockLargerThanCapacityIsRefusedWithSilence() throws {
        let fixture = try makeFixture()
        let frames = fixture.renderer.renderCapacityFrames + 1
        let output = OutputBuffers(channels: 2, frames: frames)

        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: UInt32(frames))

        XCTAssertTrue(output.allZero())
        XCTAssertEqual(fixture.renderer.takeDiagnostics().capacityExceeded, 1)
    }

    func testNineChannelBlockExceedsTheABIChannelCeiling() throws {
        let fixture = try makeFixture()
        let output = OutputBuffers(channels: 9, frames: 64)

        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 64)

        XCTAssertTrue(output.allZero())
        XCTAssertEqual(fixture.renderer.takeDiagnostics().capacityExceeded, 1)
    }

    func testEightChannelBlockThatTheRingCannotServeIsSilence() throws {
        // The mapping is stereo, so an 8-channel block cannot be deinterleaved
        // from it. The guard turns that into silence instead of reading unrelated
        // samples, which is also what keeps the stereo-only DSP off it.
        let fixture = try makeFixture()
        let output = OutputBuffers(channels: 8, frames: 64)

        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 64)

        XCTAssertTrue(output.allZero())
        let diagnostics = fixture.renderer.takeDiagnostics()
        XCTAssertEqual(diagnostics.channelMismatch, 1)
        XCTAssertEqual(diagnostics.capacityExceeded, 0, "8 channels is legal; the mapping is not")
    }

    // MARK: - 3. Ring behaviour

    func testEmptyRingProducesSilenceAndCountsTheUnderrun() throws {
        let fixture = try makeFixture()
        let output = OutputBuffers(channels: 2, frames: 512)

        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 512)

        XCTAssertTrue(output.allZero())
        let diagnostics = fixture.renderer.takeDiagnostics()
        XCTAssertEqual(diagnostics.underrunFrames, 512)
        XCTAssertEqual(diagnostics.memoryUnavailable, 0)
    }

    func testRingUnderflowZeroFillsOnlyTheTail() throws {
        let fixture = try makeFixture()
        writeFrames(fixture.mem, frames: 300) { frame, _ in Float(frame) / 10_000.0 }

        let output = OutputBuffers(channels: 2, frames: 512)
        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 512)

        for frame in 0..<300 {
            XCTAssertEqual(output.samples(0)[frame], Float(frame) / 10_000.0, accuracy: 1e-9)
            XCTAssertEqual(output.samples(1)[frame], Float(frame) / 10_000.0, accuracy: 1e-9)
        }
        for frame in 300..<512 {
            XCTAssertEqual(output.samples(0)[frame], 0)
            XCTAssertEqual(output.samples(1)[frame], 0)
        }
        XCTAssertEqual(fixture.renderer.takeDiagnostics().underrunFrames, 212)
    }

    func testShortOutputBufferIsNeverWrittenPastItsCapacity() throws {
        // CoreAudio never hands over a short buffer, but a truncating write is
        // exactly the failure mode that would corrupt a neighbouring allocation.
        let fixture = try makeFixture()
        writeFrames(fixture.mem, frames: 512) { _, _ in 0.2 }

        let guardCount = 128
        let output = OutputBuffers(channels: 2, frames: 100 + guardCount, reported: 100)
        for channel in 0..<2 {
            for index in 100..<(100 + guardCount) {
                output.samples(channel)[index] = 99.0
            }
        }

        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 512)

        for channel in 0..<2 {
            for index in 0..<100 {
                XCTAssertEqual(output.samples(channel)[index], 0.2, accuracy: 1e-7)
            }
            for index in 100..<(100 + guardCount) {
                XCTAssertEqual(output.samples(channel)[index], 99.0, "guard word overwritten @\(index)")
            }
        }
    }

    // MARK: - 4. DSP stage

    func testDSPRunsOnStereoAndStaysBounded() throws {
        let fixture = try makeFixture(eqBypassed: false)
        writeFrames(fixture.mem, frames: 256) { index, _ in index % 2 == 0 ? 0.5 : -0.5 }

        let output = OutputBuffers(channels: 2, frames: 256)
        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 256)

        var nonZero = 0
        for channel in 0..<2 {
            for frame in 0..<256 {
                let value = output.samples(channel)[frame]
                XCTAssertTrue(value.isFinite)
                XCTAssertLessThanOrEqual(abs(value), 1.0, "the limiter must keep the block inside full scale")
                if value != 0 { nonZero += 1 }
            }
        }
        XCTAssertGreaterThan(nonZero, 0, "the DSP path must actually produce audio")
        XCTAssertEqual(fixture.renderer.takeDiagnostics().firstPass?.channels, 2)
        XCTAssertFalse(fixture.renderer.takeDiagnostics().dspBypassed)
    }

    func testDSPIsSkippedWhenTheInstrumentationCannotFeedIt() throws {
        // A channel-count mismatch means `soundbridge_dsp_process_interleaved`
        // (which indexes `i * 2`) would read the wrong samples, so the block is
        // refused before the DSP is reached. The DSP must not have altered it.
        let fixture = try makeFixture(eqBypassed: false)
        let output = OutputBuffers(channels: 4, frames: 64)

        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 64)

        XCTAssertTrue(output.allZero())
        XCTAssertEqual(fixture.renderer.takeDiagnostics().channelMismatch, 1)
    }

    // MARK: - 5. Missing memory, mute, shutdown

    func testMissingMappingProducesSilenceAndIsCounted() {
        let renderer = AudioRenderer(memoryManager: manager)
        let output = OutputBuffers(channels: 2, frames: 128)

        renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 128)

        XCTAssertTrue(output.allZero())
        XCTAssertEqual(renderer.takeDiagnostics().memoryUnavailable, 1)
    }

    func testMutedMappingProducesHardSilence() throws {
        let fixture = try makeFixture(muted: true)
        writeFrames(fixture.mem, frames: 128) { _, _ in 0.9 }

        let output = OutputBuffers(channels: 2, frames: 128)
        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 128)

        XCTAssertTrue(output.allZero())
    }

    func testCleanupStopsTheRenderPathBeforeReleasingAnything() throws {
        let fixture = try makeFixture()
        writeFrames(fixture.mem, frames: 128) { _, _ in 0.3 }
        let output = OutputBuffers(channels: 2, frames: 128)
        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 128)
        XCTAssertEqual(output.samples(0)[0], 0.3, accuracy: 1e-7)

        manager.cleanup()

        let snapshot = manager.renderPathSnapshot
        XCTAssertNil(snapshot.publishedPointer)
        XCTAssertFalse(snapshot.holdsMapping)
        XCTAssertEqual(snapshot.inFlight, 0)

        let after = OutputBuffers(channels: 2, frames: 128, initial: 7.0)
        fixture.renderer.render(bufferList: after.list.unsafeMutablePointer, frameCount: 128)
        XCTAssertTrue(after.allZero(), "a stopped render path must emit silence, not stale audio")
        XCTAssertEqual(fixture.renderer.takeDiagnostics().memoryUnavailable, 1)
    }

    // MARK: - 6. Mapping retirement (§4.3 / §5.2)

    func testRetirementWaitsForTheInFlightCallback() throws {
        let fixture = try makeFixture()
        let mem = fixture.mem
        let expectedSampleRate = mem.pointee.sample_rate
        writeFrames(mem, frames: 256) { _, _ in 0.4 }

        // Stand in for a callback that is inside the mapping.
        XCTAssertTrue(manager.enterRenderMemory() == mem)
        XCTAssertEqual(manager.renderPathSnapshot.inFlight, 1)

        manager.removeMemory(for: self.uid)

        // The slot must keep the mapping: the callback still holds the pointer.
        let during = manager.renderPathSnapshot
        XCTAssertEqual(during.publishedPointer, mem, "publication must be deferred, not applied")
        XCTAssertTrue(during.holdsMapping)
        XCTAssertTrue(during.hasDeferredPublication)
        XCTAssertEqual(mem.pointee.sample_rate, expectedSampleRate, "the bytes must still be mapped")

        // A render during the deferred publication still reads the old mapping:
        // that is the whole point of waiting for quiescence instead of unmapping
        // on the control thread.
        let output = OutputBuffers(channels: 2, frames: 256)
        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 256)
        XCTAssertEqual(output.samples(0)[0], 0.4, accuracy: 1e-7,
                       "the retired-but-in-flight mapping must still deliver audio")

        manager.exitRenderMemory()
        manager.drainDeferredRenderPublication()

        let after = manager.renderPathSnapshot
        XCTAssertNil(after.publishedPointer)
        XCTAssertFalse(after.holdsMapping)
        XCTAssertFalse(after.hasDeferredPublication)
        XCTAssertEqual(after.inFlight, 0)
    }

    func testDeferredPublicationIsReleasedByTheHeartbeatDrain() throws {
        let fixture = try makeFixture()
        let mem = fixture.mem

        XCTAssertEqual(manager.enterRenderMemory() == mem, true)
        manager.removeMemory(for: self.uid)
        XCTAssertTrue(manager.renderPathSnapshot.hasDeferredPublication)

        // What `startHeartbeat`'s timer body does, without the timer's timing.
        manager.drainDeferredRenderPublication()
        XCTAssertTrue(manager.renderPathSnapshot.hasDeferredPublication,
                      "a drain with a callback still inside must not release the mapping")

        manager.exitRenderMemory()
        manager.drainDeferredRenderPublication()
        XCTAssertFalse(manager.renderPathSnapshot.hasDeferredPublication)
        XCTAssertNil(manager.renderPathSnapshot.publishedPointer)
    }

    /// The documented last resort, and the only runtime trace of it.
    ///
    /// Shutdown gives an in-flight callback `cleanupWaitTimeout` to leave and
    /// then releases the mapping anyway. `renderRetireTimeouts` is what turns
    /// "we unmapped under a reader" from an error line into a number a test can
    /// assert on; without it the branch would be unobservable.
    func testRenderPathRetireTimeoutIsCountedWhenACallbackOutlivesCleanup() throws {
        let fixture = try makeFixture()
        XCTAssertTrue(manager.enterRenderMemory() == fixture.mem)
        XCTAssertEqual(manager.renderPathSnapshot.retireTimeouts, 0)

        // Deliberately holds the lease across `cleanup()`. Nothing below
        // dereferences `fixture.mem` again -- the bytes are gone by design.
        manager.cleanup()

        XCTAssertEqual(manager.renderPathSnapshot.retireTimeouts, 1)
        XCTAssertNil(manager.renderPathSnapshot.publishedPointer)
        XCTAssertFalse(manager.renderPathSnapshot.holdsMapping)

        manager.exitRenderMemory()
        XCTAssertEqual(manager.renderPathSnapshot.inFlight, 0)
    }

    func testPreferredUIDSelectsThePublishedMapping() throws {
        let first = try makeFixture(uid: "device-a")
        let second = try makeFixture(uid: "device-b")

        manager.setPreferredRenderUID("device-b")
        XCTAssertEqual(manager.renderPathSnapshot.publishedPointer, second.mem)

        manager.setPreferredRenderUID("device-a")
        XCTAssertEqual(manager.renderPathSnapshot.publishedPointer, first.mem)

        manager.setPreferredRenderUID(nil)
        XCTAssertNotNil(manager.renderPathSnapshot.publishedPointer,
                        "without a preference the single mapping is still published")
    }

    // MARK: - 7. No allocation, no reallocation

    func testContinuousCallbacksReuseTheScratchBuffer() throws {
        let fixture = try makeFixture(volume: 0.6)
        let address = fixture.renderer.renderBufferBaseAddress
        let output = OutputBuffers(channels: 2, frames: 256)

        for _ in 0..<1_000 {
            fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 256)
        }

        XCTAssertEqual(fixture.renderer.renderBufferBaseAddress, address,
                       "the callback moved its scratch buffer: something allocated inside it")
        let diagnostics = fixture.renderer.takeDiagnostics()
        XCTAssertEqual(diagnostics.capacityExceeded, 0)
        XCTAssertEqual(diagnostics.channelMismatch, 0)
        XCTAssertEqual(diagnostics.memoryUnavailable, 0)
    }

    func testSteadyStateCallbacksDoNotAllocate() throws {
        // `malloc_zone_statistics` reports the sanitizer's own bookkeeping when
        // the binary is instrumented, not the callback's allocations, so the
        // measurement is only meaningful in a plain build.
        try XCTSkipIf(sanitizerIsActive(), "malloc counters are not the callback's under a sanitizer")

        let fixture = try makeFixture(volume: 0.6)
        writeFrames(fixture.mem, frames: 256) { _, _ in 0.1 }
        let output = OutputBuffers(channels: 2, frames: 256)

        // Warm up: the first pass records the buffer shape and takes the EQ
        // snapshot for the first time, which is allowed to be the odd one out.
        fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 256)

        var before = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &before)
        for _ in 0..<500 {
            fixture.renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: 256)
        }
        var after = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &after)

        XCTAssertEqual(
            after.blocks_in_use, before.blocks_in_use,
            "a steady-state callback allocated \(Int(after.blocks_in_use) - Int(before.blocks_in_use)) block(s)"
        )
    }

    /// ASan/TSan replace the allocator, so `malloc_zone_statistics` stops being
    /// a measure of what the code under test allocated.
    private func sanitizerIsActive() -> Bool {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return dlsym(defaultHandle, "__asan_init") != nil
            || dlsym(defaultHandle, "__tsan_init") != nil
    }
}

private final class NoPersistence: VolumeStatePersisting {
    func loadIfPresent(uid: String) -> DeviceVolumeState? { nil }
    func save(uid: String, volume: Float, muted: Bool) {}
}
