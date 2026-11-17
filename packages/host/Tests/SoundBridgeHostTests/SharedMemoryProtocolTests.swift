import XCTest

@testable import SoundBridgeHost
import CSoundBridgeAudio

/// Exercises the shared-memory protocol through `CSoundBridgeAudio` — i.e. the
/// *same* inline C that the driver compiles, not a Swift re-implementation.
///
/// This is why `rf_validate_header()` and `rf_sync_driver_volume_state()` live
/// in `RFSharedAudio.h`: the driver's `ValidateConnection()` and its
/// `OnStartIO` handshake are thin wrappers around them, so the assertions here
/// describe driver behaviour rather than a parallel test model.
final class SharedMemoryProtocolTests: XCTestCase {

    // MARK: - Fixtures

    private let sampleRate: UInt32 = 48000
    private let channels: UInt32 = 2
    private let durationMs: UInt32 = 100

    /// Allocate a block large enough for the header *and* the audio payload,
    /// so ring-buffer helpers stay in bounds.
    private func withBlock(_ body: (UnsafeMutablePointer<RFSharedAudio>) throws -> Void) rethrows {
        let frames = rf_frames_for_duration(sampleRate, durationMs)
        let byteCount = Int(rf_shared_audio_size(frames, channels, 4))
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { raw.deallocate() }
        let mem = raw.assumingMemoryBound(to: RFSharedAudio.self)
        rf_shared_audio_init(mem, sampleRate, channels, RF_FORMAT_FLOAT32, durationMs)
        try body(mem)
    }

    // MARK: - 6. Protocol identity (driver and Host built from one source)

    func testProtocolConstantsArePinned() {
        XCTAssertEqual(RF_AUDIO_PROTOCOL_VERSION, 0x0002_0100)
        XCTAssertEqual(RF_SHARED_AUDIO_HEADER_SIZE, 256)
        XCTAssertEqual(MemoryLayout<RFSharedAudio>.size, 256)
        XCTAssertEqual(MemoryLayout<RFEQSnapshot>.size, 48)
        XCTAssertEqual(MemoryLayout<RFVolumeStateSnapshot>.size, 24)
    }

    /// Every offset is pinned by `static_assert`/`_Static_assert` inside
    /// `RFSharedAudio.h`, which both the driver (C++) and this module (C) must
    /// compile through — a moved field breaks the driver build.
    ///
    /// Swift cannot see the `_Atomic` members at all (ClangImporter drops
    /// them), so the offsets it can assert directly are the plain ones. The
    /// total size is the important one: every accessor's pointer arithmetic
    /// depends on `sizeof(RFSharedAudio)` being the fixed header length.
    func testLayoutVisibleFromSwift() {
        XCTAssertEqual(MemoryLayout<RFSharedAudio>.size, 256)
        XCTAssertEqual(MemoryLayout<RFSharedAudio>.alignment, 8)
        XCTAssertEqual(MemoryLayout<RFSharedAudio>.offset(of: \.protocol_version), 0)
        XCTAssertEqual(MemoryLayout<RFSharedAudio>.offset(of: \.header_size), 4)
        XCTAssertEqual(MemoryLayout<RFSharedAudio>.offset(of: \.sample_rate), 8)
        XCTAssertEqual(MemoryLayout<RFSharedAudio>.offset(of: \.channels), 12)
        XCTAssertEqual(MemoryLayout<RFSharedAudio>.offset(of: \.creation_timestamp), 48)
        // eq_snapshot at 156 is the anchor the Phase 2.1 state block was laid
        // out behind: 156 + 48 = 204 = volume_mode.
        XCTAssertEqual(MemoryLayout<RFSharedAudio>.offset(of: \.eq_snapshot), 156)
    }

    func testVolumeTaperConstantsMatchProtocolHeader() {
        XCTAssertEqual(RF_VOLUME_DB_MIN, -VolumeTaper.rangeDB)
        XCTAssertEqual(RF_VOLUME_DB_MAX, 0.0)
        XCTAssertEqual(RF_VOLUME_DB_MAX - RF_VOLUME_DB_MIN, VolumeTaper.rangeDB)
        XCTAssertEqual(RF_VOLUME_RAW_MIN, 0)
        XCTAssertEqual(RF_VOLUME_RAW_MAX, Int32(VolumeTaper.rawSteps))
        XCTAssertEqual(VolumeMode.software.protocolValue, RF_VOLUME_MODE_SOFTWARE)
        XCTAssertEqual(VolumeMode.hardware.protocolValue, RF_VOLUME_MODE_HARDWARE)
    }

    func testFreshBlockIsValidButUncommitted() {
        withBlock { mem in
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)
            XCTAssertFalse(rf_is_volume_state_initialized(mem))
            XCTAssertEqual(rf_get_state_revision(mem), 0)
            XCTAssertEqual(rf_get_volume_mode(mem), RF_VOLUME_MODE_SOFTWARE)

            // Seeded value is present, but must not be readable as authoritative.
            XCTAssertEqual(rf_load_volume_scalar(mem), 0.35, accuracy: 1e-6)
            var snapshot = RFVolumeStateSnapshot()
            XCTAssertFalse(rf_read_volume_state(mem, &snapshot))
        }
    }

    // MARK: - 7. Protocol version mismatch

    func testProtocolVersionMismatchIsRejected() {
        withBlock { mem in
            mem.pointee.protocol_version = 0x0002_0000  // previous ABI
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_PROTOCOL_VERSION)
            XCTAssertEqual(
                String(cString: rf_validate_result_string(RF_VALIDATE_PROTOCOL_VERSION)),
                "protocol version mismatch"
            )
        }
    }

    // MARK: - 8. Struct size mismatch

    func testHeaderSizeMismatchIsRejected() {
        withBlock { mem in
            mem.pointee.header_size = 264  // the pre-2.1 struct size
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_HEADER_SIZE)
        }
    }

    func testUnsupportedSampleRateAndChannelsAreRejected() {
        withBlock { mem in
            mem.pointee.sample_rate = 22050
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_SAMPLE_RATE)
            mem.pointee.sample_rate = sampleRate

            mem.pointee.channels = 0
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_CHANNELS)
            mem.pointee.channels = UInt32(RF_MAX_CHANNELS) + 1
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_CHANNELS)
            mem.pointee.channels = channels
            XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)
        }
    }

    func testNullHeaderIsRejected() {
        XCTAssertEqual(rf_validate_header(nil), RF_VALIDATE_NULL)
    }

    // MARK: - 3. IO start must not overwrite a committed volume

    func testDriverIOStartAdoptsCommittedVolume() {
        withBlock { mem in
            // The Host has already published the user's volume.
            rf_publish_volume_state(mem, 0.62, false, RF_VOLUME_MODE_SOFTWARE)
            let revisionBefore = rf_get_state_revision(mem)

            // A freshly built VolumeControl sits at its default (scalar 1.0).
            var adopted = RFVolumeStateSnapshot()
            let outcome = rf_sync_driver_volume_state(mem, 1.0, false, &adopted)

            XCTAssertEqual(outcome, RF_VOLUME_SYNC_ADOPTED)
            XCTAssertEqual(adopted.scalar, 0.62, accuracy: 1e-6, "IO start reset the volume")
            XCTAssertEqual(adopted.revision, revisionBefore)
            XCTAssertEqual(rf_load_volume_scalar(mem), 0.62, accuracy: 1e-6)
            XCTAssertEqual(rf_get_state_revision(mem), revisionBefore, "a read must not bump the revision")
        }
    }

    func testDriverIOStartKeepsMuteState() {
        withBlock { mem in
            rf_publish_volume_state(mem, 0.45, true, RF_VOLUME_MODE_SOFTWARE)

            var adopted = RFVolumeStateSnapshot()
            XCTAssertEqual(rf_sync_driver_volume_state(mem, 1.0, false, &adopted), RF_VOLUME_SYNC_ADOPTED)
            XCTAssertEqual(adopted.scalar, 0.45, accuracy: 1e-6)
            XCTAssertEqual(adopted.muted, 1)
        }
    }

    // MARK: - 4. IO stop/start and VolumeControl rebuild keep the volume

    func testDriverIOStartSurvivesControlRebuild() {
        withBlock { mem in
            rf_publish_volume_state(mem, 0.31, false, RF_VOLUME_MODE_SOFTWARE)

            // Three start/stop cycles, each with controls rebuilt to 1.0.
            for cycle in 1...3 {
                var adopted = RFVolumeStateSnapshot()
                XCTAssertEqual(
                    rf_sync_driver_volume_state(mem, 1.0, false, &adopted),
                    RF_VOLUME_SYNC_ADOPTED,
                    "cycle \(cycle) reseeded instead of adopting"
                )
                XCTAssertEqual(adopted.scalar, 0.31, accuracy: 1e-6, "cycle \(cycle) lost the volume")
            }
            XCTAssertEqual(rf_get_state_revision(mem), 1, "restarts must not publish new revisions")
        }
    }

    // MARK: - First launch / uncommitted block

    func testDriverIOStartSeedsUncommittedBlockExactlyOnce() {
        withBlock { mem in
            // Host applied 0.8 through the HAL control before IO started; the
            // block itself has never been committed.
            var seeded = RFVolumeStateSnapshot()
            XCTAssertEqual(rf_sync_driver_volume_state(mem, 0.8, false, &seeded), RF_VOLUME_SYNC_SEEDED)
            XCTAssertEqual(seeded.scalar, 0.8, accuracy: 1e-6)
            XCTAssertEqual(seeded.revision, 1)
            XCTAssertEqual(seeded.mode, RF_VOLUME_MODE_SOFTWARE)
            XCTAssertTrue(rf_is_volume_state_initialized(mem))

            // Second start must adopt, not reseed.
            var adopted = RFVolumeStateSnapshot()
            XCTAssertEqual(rf_sync_driver_volume_state(mem, 1.0, false, &adopted), RF_VOLUME_SYNC_ADOPTED)
            XCTAssertEqual(adopted.scalar, 0.8, accuracy: 1e-6)
            XCTAssertEqual(rf_get_state_revision(mem), 1)
        }
    }

    func testDriverIOStartSeedingSanitisesControlValue() {
        withBlock { mem in
            var seeded = RFVolumeStateSnapshot()
            XCTAssertEqual(rf_sync_driver_volume_state(mem, .nan, false, &seeded), RF_VOLUME_SYNC_SEEDED)
            XCTAssertEqual(seeded.scalar, 0.35, accuracy: 1e-6, "NaN must collapse to the safe default")
            XCTAssertTrue(rf_load_volume_scalar(mem).isFinite)
        }
    }

    func testDriverIOStartSeedingHonoursMute() {
        withBlock { mem in
            var seeded = RFVolumeStateSnapshot()
            XCTAssertEqual(rf_sync_driver_volume_state(mem, 0.5, true, &seeded), RF_VOLUME_SYNC_SEEDED)
            XCTAssertEqual(seeded.muted, 1)
        }
    }

    // MARK: - Rejection leaves the block untouched

    func testDriverIOStartRejectsIncompatibleHeaderWithoutWriting() {
        withBlock { mem in
            rf_publish_volume_state(mem, 0.5, false, RF_VOLUME_MODE_SOFTWARE)
            let revision = rf_get_state_revision(mem)
            mem.pointee.protocol_version = 0x0002_0101  // build from the future

            var untouched = RFVolumeStateSnapshot()
            untouched.scalar = -1
            XCTAssertEqual(
                rf_sync_driver_volume_state(mem, 0.9, false, &untouched),
                RF_VOLUME_SYNC_REJECTED
            )
            XCTAssertEqual(untouched.scalar, -1, "rejected call must not fill the snapshot")
            XCTAssertEqual(rf_load_volume_scalar(mem), 0.5, accuracy: 1e-6, "rejected call wrote to the block")
            XCTAssertEqual(rf_get_state_revision(mem), revision)
        }
    }

    // MARK: - 10. Revision ownership

    func testPublishAdvancesRevisionByOne() {
        withBlock { mem in
            var expected: UInt64 = 0
            for scalar in [Float(0.1), 0.2, 0.3] {
                rf_publish_volume_state(mem, scalar, false, RF_VOLUME_MODE_SOFTWARE)
                expected += 1
                XCTAssertEqual(rf_get_state_revision(mem), expected)
            }
        }
    }

    /// The driver's realtime path writes the transport fields only; it must not
    /// be able to forge a commit by bumping the revision itself.
    func testTransportWriteDoesNotCommit() {
        withBlock { mem in
            rf_store_volume_scalar(mem, 0.7)
            rf_store_mute_state(mem, 0)

            XCTAssertEqual(rf_load_volume_scalar(mem), 0.7, accuracy: 1e-6)
            XCTAssertFalse(rf_is_volume_state_initialized(mem))
            XCTAssertEqual(rf_get_state_revision(mem), 0)

            var snapshot = RFVolumeStateSnapshot()
            XCTAssertFalse(rf_read_volume_state(mem, &snapshot))
        }
    }

    // MARK: - Cross-language sanitisation

    /// The C and Swift sanitisers must agree exactly; a divergence here would
    /// mean the driver accepts values the renderer rejects (or vice versa).
    func testSanitiserAgreesWithSwift() {
        let inputs: [Float] = [.nan, .infinity, -.infinity, -1.0, 0.0, 0.35, 1.0, 2.0]
        for value in inputs {
            XCTAssertEqual(
                rf_sanitize_volume_scalar(value, 0.35),
                VolumeTaper.sanitize(value, fallback: 0.35),
                "C/Swift sanitiser divergence for \(value)"
            )
        }
    }

    // MARK: - underrun_frames accounting

    func testUnderrunFramesAccumulate() {
        withBlock { mem in
            XCTAssertEqual(rf_get_underrun_frames(mem), 0)

            var output = [Float](repeating: 1.0, count: 128 * Int(channels))
            let requested: UInt32 = 128
            output.withUnsafeMutableBufferPointer { buffer in
                _ = rf_ring_read(mem, buffer.baseAddress, requested)
            }

            XCTAssertEqual(rf_get_underrun_frames(mem), requested, "silence frames must be accounted")
            XCTAssertEqual(rf_get_underrun_count(mem), 1)
            XCTAssertTrue(output.allSatisfy { $0 == 0.0 }, "underrun must emit silence, not stale data")
        }
    }
}
