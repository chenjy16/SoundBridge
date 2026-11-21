import XCTest

@testable import SoundBridgeHost
import CSoundBridgeAudio
import Darwin

/// Batch 2 admission gateway / producer ownership tests, run against the
/// *production* inline C in `RFSharedAudio.h` — the same code the driver
/// compiles into its realtime path.
///
/// They pin the frozen Batch 2 contract:
///   - a mapping starts CLOSED with epoch 0 and no owner;
///   - only the Host moves CLOSED -> OPEN -> CLOSING -> CLOSED, and only the
///     driver claims the single owner slot;
///   - a producer may write only while the mapping is OPEN, the epoch matches
///     the incarnation it claimed, AND it holds the owner token;
///   - every refusal leaves W, R, payload and statistics untouched.
final class AdmissionGatewayTests: XCTestCase {

    // MARK: - Fixtures

    private let sampleRate: UInt32 = 48000
    private let channels: UInt32 = 2
    private let durationMs: UInt32 = 100

    // Pinned by the static_assert block in RFSharedAudio.h.
    private let writeIndexOffset = 64
    private let readIndexOffset = 72
    private let totalWrittenOffset = 80
    private let totalReadOffset = 88
    private let overrunOffset = 96
    private let admissionStateOffset = 256
    private let admissionEpochOffset = 264
    private let ownerTokenOffset = 272
    private let payloadOffset = Int(RF_SHARED_AUDIO_HEADER_SIZE)

    private let epochA: UInt64 = 0x1111_2222_3333_4444
    private let epochB: UInt64 = 0x5555_6666_7777_8888
    private let tokenA: UInt64 = 0x0000_01F5_0000_0001
    private let tokenB: UInt64 = 0x0000_01F5_0000_0003

    /// Allocated exactly like the Host does: header + the rounded-up payload.
    private func withMapping(_ body: (UnsafeMutablePointer<RFSharedAudio>) throws -> Void) rethrows {
        let frames = rf_ring_capacity_frames_for(sampleRate, durationMs)
        let byteCount = Int(rf_shared_audio_size(frames, channels, 4))
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { raw.deallocate() }
        let mem = raw.assumingMemoryBound(to: RFSharedAudio.self)
        rf_shared_audio_init(mem, sampleRate, channels, RF_FORMAT_FLOAT32, durationMs)
        memset(raw + payloadOffset, 0, Int(frames) * Int(channels) * 4)
        try body(mem)
    }

    private func withOpenMapping(
        epoch: UInt64,
        _ body: (UnsafeMutablePointer<RFSharedAudio>) throws -> Void
    ) rethrows {
        try withMapping { mem in
            XCTAssertEqual(rf_admission_open(mem, epoch), RF_ADMISSION_OK)
            try body(mem)
        }
    }

    // MARK: - Raw access (only for corrupt-state and "untouched" assertions)

    private func loadU64(_ mem: UnsafeMutablePointer<RFSharedAudio>, _ offset: Int) -> UInt64 {
        UnsafeMutableRawPointer(mem).load(fromByteOffset: offset, as: UInt64.self)
    }

    private func storeU32(_ mem: UnsafeMutablePointer<RFSharedAudio>, _ offset: Int, _ value: UInt32) {
        UnsafeMutableRawPointer(mem).storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
    }

    private func storeU64(_ mem: UnsafeMutablePointer<RFSharedAudio>, _ offset: Int, _ value: UInt64) {
        UnsafeMutableRawPointer(mem).storeBytes(of: value, toByteOffset: offset, as: UInt64.self)
    }

    private func ringSnapshot(_ mem: UnsafeMutablePointer<RFSharedAudio>)
        -> (write: UInt64, read: UInt64, written: UInt64, read_total: UInt64, overruns: UInt64) {
        (loadU64(mem, writeIndexOffset), loadU64(mem, readIndexOffset),
         loadU64(mem, totalWrittenOffset), loadU64(mem, totalReadOffset),
         loadU64(mem, overrunOffset))
    }

    private func payloadIsSilent(_ mem: UnsafeMutablePointer<RFSharedAudio>, frames: Int) -> Bool {
        let bytes = UnsafeRawPointer(mem) + payloadOffset
        for i in 0..<(frames * Int(channels) * 4) where bytes.load(fromByteOffset: i, as: UInt8.self) != 0 {
            return false
        }
        return true
    }

    private func stereoFrames(_ start: Float, _ count: Int) -> [Float] {
        var frames = [Float]()
        frames.reserveCapacity(count * Int(channels))
        for i in 0..<count {
            let v = start + Float(i)
            frames.append(v)
            frames.append(-v)
        }
        return frames
    }

    // MARK: - 8.1 Admission state machine

    func testNewMappingIsClosedWithNoEpochAndNoOwner() {
        withMapping { mem in
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_CLOSED)
            XCTAssertEqual(rf_admission_epoch(mem), 0)
            XCTAssertEqual(rf_producer_owner_token(mem), 0)
            XCTAssertEqual(rf_admission_claim_seq(mem), 0)
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)
        }
    }

    func testOpenPublishesEpochAndMovesToOpen() {
        withMapping { mem in
            XCTAssertEqual(rf_admission_open(mem, epochA), RF_ADMISSION_OK)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_OPEN)
            XCTAssertEqual(rf_admission_epoch(mem), epochA)
        }
    }

    func testOpenRejectsZeroEpochAndLeavesMappingClosed() {
        withMapping { mem in
            XCTAssertEqual(rf_admission_open(mem, 0), RF_ADMISSION_ERR_EPOCH)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_CLOSED)
            XCTAssertEqual(rf_admission_epoch(mem), 0)
        }
    }

    func testOpenRefusedWhileAlreadyOpenKeepsLiveEpoch() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertEqual(rf_admission_open(mem, epochB), RF_ADMISSION_ERR_STATE)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_OPEN)
            XCTAssertEqual(rf_admission_epoch(mem), epochA,
                           "a second opener must not clobber the live incarnation")
        }
    }

    func testOpenRefusedAfterBeginCloseKeepsEpoch() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_CLOSING)
            XCTAssertEqual(rf_admission_open(mem, epochB), RF_ADMISSION_ERR_STATE)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_CLOSING)
            XCTAssertEqual(rf_admission_epoch(mem), epochA)
        }
    }

    func testBeginCloseIsIdempotentAndSafeOnClosedMapping() {
        withMapping { mem in
            XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_CLOSED)
        }
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
            XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_CLOSING)
        }
    }

    func testFinalizeCloseRequiresClosing() {
        // OPEN -> CLOSED must not be possible: every teardown goes through the
        // state the next batch attaches a drain proof to.
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertEqual(rf_admission_finalize_close(mem), RF_ADMISSION_ERR_STATE)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_OPEN)
        }
        withMapping { mem in
            XCTAssertEqual(rf_admission_finalize_close(mem), RF_ADMISSION_OK)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_CLOSED)
        }
    }

    func testFullLifecycleClosedOpenClosingClosed() {
        withMapping { mem in
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_CLOSED)
            XCTAssertEqual(rf_admission_open(mem, epochA), RF_ADMISSION_OK)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_OPEN)
            XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_CLOSING)
            XCTAssertEqual(rf_admission_finalize_close(mem), RF_ADMISSION_OK)
            XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_CLOSED)
        }
    }

    func testUnknownAdmissionStateFailsHeaderValidation() {
        withMapping { mem in
            storeU32(mem, admissionStateOffset, 0xDEAD_BEEF)
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_ADMISSION)
        }
    }

    func testValidateAcceptsEveryDefinedAdmissionState() {
        withMapping { mem in
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)  // CLOSED
            XCTAssertEqual(rf_admission_open(mem, epochA), RF_ADMISSION_OK)
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)  // OPEN
            XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)  // CLOSING
        }
    }

    func testOldProtocolVersionIsRefusedNotCoerced() {
        withMapping { mem in
            mem.pointee.protocol_version = 0x0002_0100  // Batch 1 value
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_PROTOCOL_VERSION)
        }
    }

    // MARK: - 5. Producer ownership: claim / release

    func testClaimSucceedsOnOpenMapping() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            XCTAssertEqual(rf_producer_owner_token(mem), tokenA)
            XCTAssertEqual(rf_admission_claim_seq(mem), 1)
        }
    }

    func testClaimRefusedWhileClosed() {
        withMapping { mem in
            XCTAssertFalse(rf_producer_claim(mem, tokenA))
            XCTAssertEqual(rf_producer_owner_token(mem), 0)
            XCTAssertEqual(rf_admission_claim_seq(mem), 0)
        }
    }

    func testClaimRefusedWhileClosing() {
        withMapping { mem in
            XCTAssertEqual(rf_admission_open(mem, epochA), RF_ADMISSION_OK)
            XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
            XCTAssertFalse(rf_producer_claim(mem, tokenA))
            XCTAssertEqual(rf_producer_owner_token(mem), 0)
        }
    }

    func testClaimRefusedForZeroToken() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertFalse(rf_producer_claim(mem, 0))
            XCTAssertEqual(rf_producer_owner_token(mem), 0)
        }
    }

    func testSecondHandlerWithDifferentTokenIsRefused() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            XCTAssertFalse(rf_producer_claim(mem, tokenB),
                           "a second handler on the same mapping must not take over")
            XCTAssertEqual(rf_producer_owner_token(mem), tokenA)
            XCTAssertEqual(rf_admission_claim_seq(mem), 1)
        }
    }

    func testReclaimWithSameTokenIsIdempotent() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            XCTAssertTrue(rf_producer_claim(mem, tokenA), "Stop -> Start on the same handler re-claims")
            XCTAssertEqual(rf_admission_claim_seq(mem), 1, "idempotent re-claim is not a second producer")
        }
    }

    func testReleaseOnlyAffectsTheOwner() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            XCTAssertFalse(rf_producer_release(mem, tokenB), "a non-owner release is a no-op")
            XCTAssertEqual(rf_producer_owner_token(mem), tokenA)
            XCTAssertTrue(rf_producer_release(mem, tokenA))
            XCTAssertEqual(rf_producer_owner_token(mem), 0)
        }
    }

    func testCleanReleaseAllowsNextHandlerToClaim() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            XCTAssertTrue(rf_producer_release(mem, tokenA))
            XCTAssertTrue(rf_producer_claim(mem, tokenB))
            XCTAssertEqual(rf_producer_owner_token(mem), tokenB)
            XCTAssertEqual(rf_admission_claim_seq(mem), 2)
        }
    }

    func testClosingWithoutReleaseKeepsStaleOwnerAndBlocksTakeover() {
        // Conservative teardown: the Host revokes admission but cannot prove
        // the old callback exited, so the owner record stays and nobody else
        // may claim. Safe > smooth.
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
            XCTAssertFalse(rf_producer_claim(mem, tokenB))
            XCTAssertFalse(rf_producer_claim(mem, tokenA), "a closed mapping is not reopened by claiming")
            XCTAssertEqual(rf_producer_owner_token(mem), tokenA)
        }
    }

    // MARK: - 5. Write gate (real ring effects, not just return values)

    func testOwnerWriteReachesTheConsumer() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            let input = stereoFrames(1, 32)
            var dropped: UInt32 = 0
            let written = rf_ring_write(mem, input, 32, tokenA, epochA, &dropped)
            XCTAssertEqual(written, 32)
            XCTAssertEqual(dropped, 0)
            XCTAssertEqual(loadU64(mem, writeIndexOffset), 32)

            var out = [Float](repeating: .nan, count: 32 * Int(channels))
            var zeroFilled: UInt32 = 0
            let read = rf_ring_read(mem, &out, 32, &zeroFilled)
            XCTAssertEqual(read, 32)
            XCTAssertEqual(zeroFilled, 0)
            XCTAssertEqual(out, input, "what the owner wrote is what the consumer reads")
        }
    }

    func testWriteRefusedWhileClosedChangesNothing() {
        withMapping { mem in
            let before = ringSnapshot(mem)
            var dropped: UInt32 = 0
            let written = rf_ring_write(mem, stereoFrames(1, 16), 16, tokenA, epochA, &dropped)
            XCTAssertEqual(written, 0)
            XCTAssertEqual(dropped, 16, "a refused write reports its frames as dropped")
            XCTAssertEqual(ringSnapshot(mem).write, before.write)
            XCTAssertEqual(ringSnapshot(mem).read, before.read)
            XCTAssertEqual(ringSnapshot(mem).written, before.written)
            XCTAssertEqual(ringSnapshot(mem).read_total, before.read_total)
            XCTAssertEqual(ringSnapshot(mem).overruns, before.overruns)
            XCTAssertTrue(payloadIsSilent(mem, frames: 16))
        }
    }

    func testWriteRefusedWhileClosing() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            let before = ringSnapshot(mem)
            XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
            var dropped: UInt32 = 0
            let written = rf_ring_write(mem, stereoFrames(1, 16), 16, tokenA, epochA, &dropped)
            XCTAssertEqual(written, 0)
            XCTAssertEqual(dropped, 16)
            XCTAssertEqual(ringSnapshot(mem).write, before.write)
            XCTAssertTrue(payloadIsSilent(mem, frames: 16))
        }
    }

    func testWriteRefusedWhenOpenButUnowned() {
        withOpenMapping(epoch: epochA) { mem in
            let before = ringSnapshot(mem)
            var dropped: UInt32 = 0
            let written = rf_ring_write(mem, stereoFrames(1, 16), 16, tokenA, epochA, &dropped)
            XCTAssertEqual(written, 0, "OPEN alone is not permission: the slot must be claimed")
            XCTAssertEqual(dropped, 16)
            XCTAssertEqual(ringSnapshot(mem).write, before.write)
            XCTAssertTrue(payloadIsSilent(mem, frames: 16))
        }
    }

    func testWriteRefusedForNonOwnerToken() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            var dropped: UInt32 = 0
            let written = rf_ring_write(mem, stereoFrames(1, 16), 16, tokenB, epochA, &dropped)
            XCTAssertEqual(written, 0)
            XCTAssertEqual(dropped, 16)
            XCTAssertEqual(loadU64(mem, writeIndexOffset), 0)
            XCTAssertTrue(payloadIsSilent(mem, frames: 16))
        }
    }

    func testWriteRefusedWhenIncarnationEpochDiffers() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            // Simulate the mapping being rebound to another incarnation while
            // this producer still holds the old token/epoch pair.
            storeU64(mem, admissionEpochOffset, epochB)
            var dropped: UInt32 = 0
            let written = rf_ring_write(mem, stereoFrames(1, 16), 16, tokenA, epochA, &dropped)
            XCTAssertEqual(written, 0, "owner identity is bound to its incarnation epoch")
            XCTAssertEqual(dropped, 16)
            XCTAssertEqual(loadU64(mem, writeIndexOffset), 0)
            XCTAssertTrue(payloadIsSilent(mem, frames: 16))
        }
    }

    func testWriteRefusedAfterRelease() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            XCTAssertTrue(rf_producer_release(mem, tokenA))
            var dropped: UInt32 = 0
            let written = rf_ring_write(mem, stereoFrames(1, 16), 16, tokenA, epochA, &dropped)
            XCTAssertEqual(written, 0)
            XCTAssertEqual(loadU64(mem, writeIndexOffset), 0)
        }
    }

    func testProducerMayWriteMatchesTheGate() {
        withMapping { mem in
            XCTAssertFalse(rf_producer_may_write(mem, tokenA, epochA))
            XCTAssertEqual(rf_admission_open(mem, epochA), RF_ADMISSION_OK)
            XCTAssertFalse(rf_producer_may_write(mem, tokenA, epochA), "no owner yet")
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            XCTAssertTrue(rf_producer_may_write(mem, tokenA, epochA))
            XCTAssertFalse(rf_producer_may_write(mem, tokenB, epochA))
            XCTAssertFalse(rf_producer_may_write(mem, tokenA, epochB))
            XCTAssertFalse(rf_producer_may_write(mem, 0, epochA))
            XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
            XCTAssertFalse(rf_producer_may_write(mem, tokenA, epochA))
        }
    }

    // MARK: - Prefill lifecycle

    func testPrefillRefusedOnceAdmissionIsOpen() {
        withOpenMapping(epoch: epochA) { mem in
            let before = ringSnapshot(mem)
            var dropped: UInt32 = 0
            let written = rf_ring_prefill_before_publish(mem, stereoFrames(1, 16), 16, &dropped)
            XCTAssertEqual(written, 0, "Stop -> Start must never re-fill a live mapping")
            XCTAssertEqual(ringSnapshot(mem).write, before.write)
            XCTAssertEqual(dropped, 0)
        }
    }

    func testPrefillRefusedAfterOwnerClaimsWithoutOpen() {
        // Even in the CLOSED window a claimed slot blocks the prefill.
        withMapping { mem in
            storeU64(mem, ownerTokenOffset, tokenA)
            var dropped: UInt32 = 0
            XCTAssertEqual(rf_ring_prefill_before_publish(mem, stereoFrames(1, 16), 16, &dropped), 0)
            XCTAssertEqual(loadU64(mem, writeIndexOffset), 0)
        }
    }

    func testPrefillWorksExactlyOnceBeforePublish() {
        withMapping { mem in
            var dropped: UInt32 = 0
            XCTAssertEqual(rf_ring_prefill_before_publish(mem, stereoFrames(1, 16), 16, &dropped), 16)
            XCTAssertEqual(loadU64(mem, writeIndexOffset), 16)
            XCTAssertEqual(rf_admission_open(mem, epochA), RF_ADMISSION_OK)
            XCTAssertEqual(rf_ring_prefill_before_publish(mem, stereoFrames(100, 16), 16, &dropped), 0)
            XCTAssertEqual(loadU64(mem, writeIndexOffset), 16, "the second prefill must not touch W")
        }
    }

    // MARK: - 8.2 Concurrency: at most one owner

    func testConcurrentClaimsElectExactlyOneOwner() {
        withOpenMapping(epoch: epochA) { mem in
            let contenders = 16
            let start = DispatchSemaphore(value: 0)
            let finished = DispatchGroup()
            let lock = NSLock()
            var winners: [UInt64] = []
            let queue = DispatchQueue(label: "admission.claims", attributes: .concurrent)

            for i in 0..<contenders {
                queue.async(group: finished) {
                    start.wait()
                    let token = self.tokenA + UInt64(i) * 2
                    if rf_producer_claim(mem, token) {
                        lock.lock()
                        winners.append(token)
                        lock.unlock()
                    }
                }
            }
            for _ in 0..<contenders { start.signal() }
            XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)

            XCTAssertEqual(winners.count, 1, "at most one producer owner per incarnation")
            XCTAssertEqual(rf_producer_owner_token(mem), winners.first)
            XCTAssertEqual(rf_admission_claim_seq(mem), 1)
        }
    }

    func testConcurrentClaimsAndReleasesNeverYieldTwoOwners() {
        withOpenMapping(epoch: epochA) { mem in
            let start = DispatchSemaphore(value: 0)
            let finished = DispatchGroup()
            let lock = NSLock()
            var observedOwners = Set<UInt64>()
            var violations = 0
            let queue = DispatchQueue(label: "admission.churn", attributes: .concurrent)

            for i in 0..<4 {
                queue.async(group: finished) {
                    start.wait()
                    let token = self.tokenA + UInt64(i) * 2
                    for _ in 0..<500 {
                        if rf_producer_claim(mem, token) {
                            // While we believe we own the slot, it must be ours.
                            let owner = rf_producer_owner_token(mem)
                            lock.lock()
                            observedOwners.insert(owner)
                            if owner != token { violations += 1 }
                            lock.unlock()
                            _ = rf_producer_release(mem, token)
                        }
                    }
                }
            }
            for _ in 0..<4 { start.signal() }
            XCTAssertEqual(finished.wait(timeout: .now() + 60), .success)

            XCTAssertEqual(violations, 0, "a claim must never be observed under another token")
            XCTAssertLessThanOrEqual(observedOwners.count, 4)
            XCTAssertEqual(rf_producer_owner_token(mem), 0, "the last holder released")
        }
    }

    func testNonOwnerWriterNeverAdvancesTheRing() {
        withOpenMapping(epoch: epochA) { mem in
            XCTAssertTrue(rf_producer_claim(mem, tokenA))
            let start = DispatchSemaphore(value: 0)
            let finished = DispatchGroup()
            let queue = DispatchQueue(label: "admission.writers", attributes: .concurrent)

            // One owner thread writing, one intruder thread hammering the gate.
            queue.async(group: finished) {
                start.wait()
                var dropped: UInt32 = 0
                for _ in 0..<200 {
                    _ = rf_ring_write(mem, self.stereoFrames(1, 8), 8, self.tokenA, self.epochA, &dropped)
                }
            }
            queue.async(group: finished) {
                start.wait()
                var dropped: UInt32 = 0
                for _ in 0..<200 {
                    _ = rf_ring_write(mem, self.stereoFrames(-1, 8), 8, self.tokenB, self.epochA, &dropped)
                }
            }
            for _ in 0..<2 { start.signal() }
            XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)

            XCTAssertEqual(loadU64(mem, writeIndexOffset), 1600,
                           "only the owner's 200 x 8 frames may land")
            XCTAssertEqual(loadU64(mem, readIndexOffset), 0, "the producer never moves R")
        }
    }
}
