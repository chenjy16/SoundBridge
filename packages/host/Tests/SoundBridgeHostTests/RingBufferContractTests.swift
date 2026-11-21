import XCTest

@testable import SoundBridgeHost
import CSoundBridgeAudio
import Darwin

/// Batch 1 ring contract tests, run against the *production* inline C in
/// `RFSharedAudio.h` (the same code the driver compiles), not a Swift model.
///
/// They pin the frozen Batch 0 protocol contract:
///   - Producer owns W and NEVER touches R (overflow = Drop New).
///   - Consumer owns R and NEVER touches W (underflow = zero-fill tail).
///   - capacity is a power of two; the slot mask addressing wraps correctly,
///     including monotonic indices near UINT64_MAX.
///   - invalid input / corrupt state fail closed instead of guessing.
final class RingBufferContractTests: XCTestCase {

    // MARK: - Fixtures

    private let sampleRate: UInt32 = 48000
    private let channels: UInt32 = 2
    private let durationMs: UInt32 = 100

    // Field offsets inside RFSharedAudio. The static_assert block pins
    // creation_timestamp at 48 and driver_connected at 120; the uint64 members
    // between them pack with no padding, which fixes these offsets by layout:
    // 48 ts, 56 fmt_change, 64 write_index, 72 read_index,
    // 80 total_written, 88 total_read, 96 overrun, 104 underrun, 112 mismatch.
    private let writeIndexOffset = 64
    private let readIndexOffset = 72
    private let totalWrittenOffset = 80
    private let totalReadOffset = 88

    /// Block large enough for the header AND the rounded-up payload.
    ///
    /// Since Batch 2 the ring writer is gated, so the fixture also performs the
    /// two steps a real producer must perform: the Host opens admission, then
    /// the single producer claims its owner token. None of these tests is about
    /// the gateway (see AdmissionGatewayTests); they need a legal writer.
    private func withBlock(_ body: (UnsafeMutablePointer<RFSharedAudio>) throws -> Void) rethrows {
        // Same single source of truth as rf_shared_audio_init: the capacity is
        // the power-of-two rounding of the requested duration (8192 for
        // 48 kHz / 100 ms). Sizing with the raw frame count would truncate the
        // payload that init writes a rounded capacity for.
        let frames = rf_ring_capacity_frames_for(sampleRate, durationMs)
        let byteCount = Int(rf_shared_audio_size(frames, channels, 4))
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { raw.deallocate() }
        let mem = raw.assumingMemoryBound(to: RFSharedAudio.self)
        rf_shared_audio_init(mem, sampleRate, channels, RF_FORMAT_FLOAT32, durationMs)
        XCTAssertEqual(rf_admission_open(mem, ringEpoch), RF_ADMISSION_OK)
        XCTAssertTrue(rf_producer_claim(mem, ownerToken))
        try body(mem)
    }

    /// Admission identity used by this suite's fixture.
    private let ownerToken: UInt64 = 0x0000_01F5_0000_0101
    private let ringEpoch: UInt64 = 0x0BAD_C0DE_0000_0001

    /// The gated producer entry point, with the fixture's owner identity.
    private func ringWrite(
        _ mem: UnsafeMutablePointer<RFSharedAudio>?,
        _ frames: UnsafePointer<Float>?,
        _ count: UInt32,
        _ dropped: UnsafeMutablePointer<UInt32>?
    ) -> UInt32 {
        rf_ring_write(mem, frames, count, ownerToken, ringEpoch, dropped)
    }

    /// The payload starts out as raw allocation garbage; deterministic tests
    /// zero it (frame = capacity * channels * sizeof(float32)).
    private func zeroPayload(_ mem: UnsafeMutablePointer<RFSharedAudio>) {
        let capacity = Int(mem.pointee.ring_capacity_frames)
        memset(UnsafeMutableRawPointer(mem) + Int(RF_SHARED_AUDIO_HEADER_SIZE), 0, capacity * Int(channels) * 4)
    }

    private func loadIndex(_ mem: UnsafeMutablePointer<RFSharedAudio>, _ offset: Int) -> UInt64 {
        UnsafeMutableRawPointer(mem).load(fromByteOffset: offset, as: UInt64.self)
    }

    private func seedIndices(
        _ mem: UnsafeMutablePointer<RFSharedAudio>, write: UInt64, read: UInt64
    ) {
        let raw = UnsafeMutableRawPointer(mem)
        raw.storeBytes(of: write, toByteOffset: writeIndexOffset, as: UInt64.self)
        raw.storeBytes(of: read, toByteOffset: readIndexOffset, as: UInt64.self)
    }

    /// A stereo frame whose left channel encodes the value and the right
    /// channel its negation, so channel pairing is verifiable on read-back.
    private func makeSequence(_ start: Float, _ count: Int) -> [Float] {
        var frames = [Float]()
        frames.reserveCapacity(count * Int(channels))
        for i in 0..<count {
            let v = start + Float(i)
            frames.append(v)
            frames.append(-v)
        }
        return frames
    }

    private func leftChannels(_ interleaved: [Float]) -> [Float] {
        stride(from: 0, to: interleaved.count, by: Int(channels)).map { interleaved[$0] }
    }

    /// Explicit Float range helper: bare `Array(1.0...10.0)` resolves to the
    /// Cocoa overload with Double and fails to compile.
    private func ascending(_ start: Float, through end: Float) -> [Float] {
        stride(from: start, through: end, by: 1).map { $0 }
    }

    // MARK: - Capacity helpers (Batch 1: single source of truth)

    func testCapacityHelperRoundsUpToPowerOfTwo() {
        XCTAssertEqual(rf_ring_capacity_frames_for(48000, 100), 8192)
        XCTAssertEqual(rf_ring_capacity_frames_for(44100, 100), 8192)
        XCTAssertEqual(rf_ring_capacity_frames_for(96000, 100), 16384)
    }

    func testNextPowerOfTwoBoundaries() {
        XCTAssertEqual(rf_next_power_of_two_u32(0), 0)
        XCTAssertEqual(rf_next_power_of_two_u32(1), 1)
        XCTAssertEqual(rf_next_power_of_two_u32(2), 2)
        XCTAssertEqual(rf_next_power_of_two_u32(3), 4)
        XCTAssertEqual(rf_next_power_of_two_u32(4800), 8192)
        XCTAssertEqual(rf_next_power_of_two_u32(1 << 31), 1 << 31)
        XCTAssertEqual(rf_next_power_of_two_u32((1 << 31) + 1), 0, "cannot fit: fail closed")
    }

    func testInitPinsRoundedCapacity() {
        withBlock { mem in
            XCTAssertEqual(mem.pointee.ring_duration_ms, durationMs)
            XCTAssertEqual(mem.pointee.ring_capacity_frames, 8192, "init must store the rounded capacity")
        }
    }

    func testValidateRejectsNonPowerOfTwoOrZeroCapacity() {
        withBlock { mem in
            mem.pointee.ring_capacity_frames = 4800
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_CAPACITY)
            mem.pointee.ring_capacity_frames = 0
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_CAPACITY)
            mem.pointee.ring_capacity_frames = 8192
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)
        }
    }

    // MARK: - FIFO order

    func testFIFOOrderPreservedAcrossSplitReads() {
        withBlock { mem in
            zeroPayload(mem)
            let written = makeSequence(1, 100)
            var dropped: UInt32 = 0
            XCTAssertEqual(ringWrite(mem, written, 100, &dropped), 100)
            XCTAssertEqual(dropped, 0)

            var out = [Float](repeating: .nan, count: 100 * Int(channels))
            var zero: UInt32 = 0
            XCTAssertEqual(rf_ring_read(mem, &out, 30, &zero), 30)
            out.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                XCTAssertEqual(rf_ring_read(mem, base + 30 * Int(channels), 30, &zero), 30)
                XCTAssertEqual(rf_ring_read(mem, base + 60 * Int(channels), 40, &zero), 40)
            }
            XCTAssertEqual(zero, 0)
            XCTAssertEqual(leftChannels(out), ascending(1, through: 100))
            XCTAssertEqual(loadIndex(mem, writeIndexOffset), 100)
            XCTAssertEqual(loadIndex(mem, readIndexOffset), 100)
        }
    }

    func testFullRingWrapsSlotMaskWithoutCorruption() {
        withBlock { mem in
            zeroPayload(mem)
            let capacity = Int(mem.pointee.ring_capacity_frames)

            // Fill the entire ring: the mask wraps from capacity-1 back to 0.
            let first = makeSequence(1, capacity)
            var dropped: UInt32 = 0
            XCTAssertEqual(ringWrite(mem, first, UInt32(capacity), &dropped), UInt32(capacity))

            // Read half, write half again, read everything: the second half
            // lands in slots the mask re-visited.
            var sink = [Float](repeating: 0, count: capacity / 2 * Int(channels))
            var zero: UInt32 = 0
            XCTAssertEqual(rf_ring_read(mem, &sink, UInt32(capacity / 2), &zero), UInt32(capacity / 2))
            let second = makeSequence(Float(capacity) + 1, capacity / 2)
            XCTAssertEqual(ringWrite(mem, second, UInt32(capacity / 2), &dropped), UInt32(capacity / 2))

            var out = [Float](repeating: .nan, count: capacity * Int(channels))
            XCTAssertEqual(rf_ring_read(mem, &out, UInt32(capacity), &zero), UInt32(capacity))
            let expected = ascending(Float(capacity / 2 + 1), through: Float(capacity) + Float(capacity / 2))
            XCTAssertEqual(leftChannels(out), expected, "slot mask wrap must preserve FIFO order: half-consumed old data followed by the re-written slots")
        }
    }

    // MARK: - Overflow: Producer Drop New

    func testOverflowDropsNewFramesAndKeepsOldOnes() {
        withBlock { mem in
            zeroPayload(mem)
            let capacity = Int(mem.pointee.ring_capacity_frames)
            XCTAssertEqual(ringWrite(mem, makeSequence(1, capacity), UInt32(capacity), nil), UInt32(capacity))
            let readBefore = loadIndex(mem, readIndexOffset)

            // Ring is full: a new write must drop ALL new frames, return 0 and
            // leave both the old payload and the consumer index untouched.
            var dropped: UInt32 = 99
            XCTAssertEqual(ringWrite(mem, makeSequence(Float(capacity) + 1, 3), 3, &dropped), 0)
            XCTAssertEqual(dropped, 3)
            XCTAssertEqual(loadIndex(mem, readIndexOffset), readBefore, "producer must never move R")

            var out = [Float](repeating: .nan, count: 2 * Int(channels))
            var zero: UInt32 = 0
            XCTAssertEqual(rf_ring_read(mem, &out, 2, &zero), 2)
            XCTAssertEqual(leftChannels(Array(out[0..<2 * Int(channels)])), [1, 2], "oldest data survives")
            XCTAssertGreaterThanOrEqual(rf_get_overrun_count(mem), 1)
        }
    }

    func testOverflowPartialWriteKeepsWholeFramesTogether() {
        withBlock { mem in
            zeroPayload(mem)
            let capacity = Int(mem.pointee.ring_capacity_frames)
            XCTAssertEqual(ringWrite(mem, makeSequence(1, capacity - 2), UInt32(capacity - 2), nil), UInt32(capacity - 2))

            // free == 2: writing 5 frames writes exactly 2 and drops 3.
            var dropped: UInt32 = 0
            XCTAssertEqual(ringWrite(mem, makeSequence(Float(capacity) - 1, 5), 5, &dropped), 2)
            XCTAssertEqual(dropped, 3)

            var out = [Float](repeating: 0, count: 2 * Int(channels))
            var zero: UInt32 = 0
            XCTAssertEqual(rf_ring_read(mem, &out, 2, &zero), 2)
            let left = leftChannels(Array(out[0..<2 * Int(channels)]))
            // FIFO: the oldest frames come out first; the two frames that fit
            // (8191, 8192) are still buffered behind them, the dropped three
            // (8193-8195) never entered the ring.
            XCTAssertEqual(left, [1, 2], "oldest data survives the partial overflow")
            // Channel pairing: right channel is the negation of its frame.
            for frame in 0..<2 {
                XCTAssertEqual(out[frame * 2 + 1], -left[frame], accuracy: 1e-6)
            }
        }
    }

    func testWriteNeverAdvancesReadIndex() {
        withBlock { mem in
            zeroPayload(mem)
            let capacity = Int(mem.pointee.ring_capacity_frames)
            var dropped: UInt32 = 0
            for chunk in 0..<8 {
                XCTAssertEqual(ringWrite(mem, makeSequence(Float(chunk * 100 + 1), 100), 100, &dropped), UInt32(min(100, capacity)))
                XCTAssertEqual(loadIndex(mem, readIndexOffset), 0, "write #\(chunk) moved R")
            }
        }
    }

    // MARK: - Underflow: zero-fill tail, R only moves by consumed frames

    func testUnderflowReturnsConsumedAndZeroFillsTail() {
        withBlock { mem in
            zeroPayload(mem)
            XCTAssertEqual(ringWrite(mem, makeSequence(1, 3), 3, nil), 3)

            var out = [Float](repeating: .nan, count: 5 * Int(channels))
            var zero: UInt32 = 0
            XCTAssertEqual(rf_ring_read(mem, &out, 5, &zero), 3, "only available frames are consumed")
            XCTAssertEqual(zero, 2, "the tail is the zero-filled legal output area")
            let left = leftChannels(out)
            XCTAssertEqual(Array(left[0..<3]), [1, 2, 3])
            XCTAssertEqual(Array(left[3..<5]), [0, 0])
            XCTAssertEqual(loadIndex(mem, readIndexOffset), 3, "R advances by consumed frames only")
            XCTAssertEqual(loadIndex(mem, writeIndexOffset), 3)
            XCTAssertEqual(rf_get_underrun_frames(mem), 2)
            XCTAssertEqual(rf_get_underrun_count(mem), 1)
        }
    }

    func testEmptyRingConsumesNothing() {
        withBlock { mem in
            zeroPayload(mem)
            var out = [Float](repeating: .nan, count: 4 * Int(channels))
            var zero: UInt32 = 0
            XCTAssertEqual(rf_ring_read(mem, &out, 4, &zero), 0)
            XCTAssertEqual(zero, 4)
            XCTAssertTrue(out.allSatisfy { $0 == 0.0 })
            XCTAssertEqual(loadIndex(mem, readIndexOffset), 0)
        }
    }

    // MARK: - Wraparound near UINT64_MAX (monotonic index arithmetic)

    func testIndicesNearUInt64MaxStillDeliverAcrossWrap() {
        withBlock { mem in
            zeroPayload(mem)
            // Seed W and R so 5 frames are pending and W is 4 from the edge.
            seedIndices(mem, write: UInt64.max - 4, read: UInt64.max - 9)

            XCTAssertEqual(ringWrite(mem, makeSequence(1, 10), 10, nil), 10)
            var out = [Float](repeating: .nan, count: 15 * Int(channels))
            var zero: UInt32 = 0
            XCTAssertEqual(rf_ring_read(mem, &out, 15, &zero), 15)

            let left = leftChannels(out)
            XCTAssertEqual(Array(left[5..<15]), ascending(1, through: 10), "frames written across the wrap read back in order")
            XCTAssertEqual(loadIndex(mem, writeIndexOffset), 5, "W wraps through UINT64_MAX and stays monotonic")
            XCTAssertEqual(loadIndex(mem, readIndexOffset), 5, "R wraps through UINT64_MAX and stays monotonic")
        }
    }

    func testCorruptIndicesFailClosed() {
        withBlock { mem in
            zeroPayload(mem)
            // available = W - R underflows to a huge value when R is ahead: the
            // reader must emit legal silence and never walk into garbage slots.
            seedIndices(mem, write: 100, read: 200)
            let readBefore = loadIndex(mem, readIndexOffset)

            var out = [Float](repeating: .nan, count: 4 * Int(channels))
            var zero: UInt32 = 0
            XCTAssertEqual(rf_ring_read(mem, &out, 4, &zero), 0)
            XCTAssertEqual(zero, 4)
            XCTAssertTrue(out.allSatisfy { $0 == 0.0 })
            XCTAssertEqual(loadIndex(mem, readIndexOffset), readBefore, "corrupt state must not advance R")
            XCTAssertEqual(rf_get_underrun_count(mem), 1)

            // The writer sees the same corruption from its side.
            var dropped: UInt32 = 0
            XCTAssertEqual(ringWrite(mem, makeSequence(1, 4), 4, &dropped), 0)
            XCTAssertEqual(dropped, 4)
        }
    }

    // MARK: - Fail-closed inputs

    func testRingHelpersRejectInvalidCapacityDirectly() {
        withBlock { mem in
            zeroPayload(mem)
            let original = mem.pointee.ring_capacity_frames
            let input = makeSequence(1, 4)
            var out = [Float](repeating: .nan, count: 4 * Int(channels))

            mem.pointee.ring_capacity_frames = 4800  // not a power of two
            var dropped: UInt32 = 99
            var zero: UInt32 = 99
            XCTAssertEqual(ringWrite(mem, input, 4, &dropped), 0)
            XCTAssertEqual(dropped, 0)
            XCTAssertEqual(rf_ring_read(mem, &out, 4, &zero), 0)
            XCTAssertEqual(zero, 4)
            XCTAssertTrue(out.allSatisfy { $0 == 0.0 })

            mem.pointee.ring_capacity_frames = 0
            XCTAssertEqual(ringWrite(mem, input, 4, &dropped), 0)
            XCTAssertEqual(rf_ring_read(mem, &out, 4, &zero), 0)

            mem.pointee.ring_capacity_frames = original
        }
    }

    func testRingHelpersRejectNullAndZeroFrames() {
        withBlock { mem in
            var dropped: UInt32 = 99
            var zero: UInt32 = 99
            var frame: [Float] = [1, -1]
            var out: [Float] = [0, 0]

            XCTAssertEqual(ringWrite(nil, &frame, 1, &dropped), 0)
            XCTAssertEqual(ringWrite(mem, nil, 1, &dropped), 0)
            XCTAssertEqual(ringWrite(mem, &frame, 0, &dropped), 0)
            XCTAssertEqual(rf_ring_read(nil, &out, 1, &zero), 0)
            XCTAssertEqual(rf_ring_read(mem, nil, 1, &zero), 0)
            XCTAssertEqual(rf_ring_read(mem, &out, 0, &zero), 0)
        }
    }

    // MARK: - Index-offset sanity for the seed helpers used above

    /// Guards the raw-offset seeding this suite relies on: writing through the
    /// offsets must land exactly on the atomic W/R pair, proven by behaviour.
    func testSeedOffsetsHitTheAtomicIndices() {
        withBlock { mem in
            zeroPayload(mem)
            seedIndices(mem, write: 10, read: 8)
            var out = [Float](repeating: .nan, count: 2 * Int(channels))
            var zero: UInt32 = 99
            // 2 frames must be "available" only if the seeds really reached W/R.
            XCTAssertEqual(rf_ring_read(mem, &out, 2, &zero), 2)
            XCTAssertEqual(zero, 0)
            XCTAssertEqual(loadIndex(mem, readIndexOffset), 10)
        }
    }

    // MARK: - Real SPSC concurrency

    /// Two real threads: a producer that writes a strictly increasing sequence
    /// and a consumer that verifies FIFO order. Overflow may drop frames (they
    /// are simply absent from the sequence), but a frame that arrives must be
    /// newer than every frame before it, and the accounting identity
    /// written + dropped == offered, consumed == written must hold.
    func testConcurrentProducerConsumerMaintainsFIFOAndAccounting() {
        withBlock { mem in
            zeroPayload(mem)
            let chunkFrames: UInt32 = 512
            let totalFrames: UInt32 = 240_000
            let sentinelValue: Float = Float(totalFrames) + 1

            final class Stats {
                let lock = NSLock()
                var dropped: UInt32 = 0
                var producedSentinel = false
            }
            let stats = Stats()

            let group = DispatchGroup()
            let queue = DispatchQueue(label: "ring-contract-test", attributes: .concurrent)

            group.enter()
            queue.async {
                defer { group.leave() }
                var next: Float = 1
                while next <= Float(totalFrames) {
                    var frames = [Float]()
                    frames.reserveCapacity(Int(chunkFrames) * 2)
                    for _ in 0..<chunkFrames where next <= Float(totalFrames) {
                        frames.append(next)
                        frames.append(-next)
                        next += 1
                    }
                    var dropped: UInt32 = 0
                    _ = self.ringWrite(mem, frames, UInt32(frames.count / 2), &dropped)
                    if dropped > 0 {
                        stats.lock.lock()
                        stats.dropped += dropped
                        stats.lock.unlock()
                    }
                }
                // The sentinel must reach the ring: spin until it fits.
                var sentinel: [Float] = [sentinelValue, -sentinelValue]
                while self.ringWrite(mem, &sentinel, 1, nil) != 1 {
                    sched_yield()
                }
                stats.lock.lock()
                stats.producedSentinel = true
                stats.lock.unlock()
            }

            group.enter()
            queue.async {
                defer { group.leave() }
                var last: Float = 0
                var drainedStreak = 0
                var out = [Float](repeating: 0, count: Int(chunkFrames) * 2)
                while true {
                    var zero: UInt32 = 0
                    let consumed = rf_ring_read(mem, &out, chunkFrames, &zero)
                    if consumed == 0 {
                        stats.lock.lock()
                        let done = stats.producedSentinel
                        stats.lock.unlock()
                        drainedStreak += 1
                        if done && drainedStreak > 1000 { return }
                        sched_yield()
                        continue
                    }
                    drainedStreak = 0
                    for frame in 0..<Int(consumed) {
                        let v = out[frame * 2]
                        if v == 0 { continue }  // zero-filled tail samples
                        if v <= last {
                            XCTFail("FIFO order violated: \(v) after \(last)")
                            return
                        }
                        last = v
                        if v >= sentinelValue { return }
                    }
                }
            }

            let outcome = group.wait(timeout: .now() + 60)
            XCTAssertEqual(outcome, .success, "SPSC stress deadlocked or ran too long")

            let written = loadIndex(mem, totalWrittenOffset)
            let read = loadIndex(mem, totalReadOffset)
            XCTAssertEqual(read, written, "a drained ring must have consumed exactly what was written")
            XCTAssertEqual(written, loadIndex(mem, writeIndexOffset) - loadIndex(mem, readIndexOffset) + read)
            stats.lock.lock()
            let dropped = stats.dropped
            stats.lock.unlock()
            XCTAssertEqual(written + UInt64(dropped), UInt64(totalFrames) + 1, "offered = written + dropped (sentinel included)")
        }
    }
}
