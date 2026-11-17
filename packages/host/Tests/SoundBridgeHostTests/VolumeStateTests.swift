import XCTest

@testable import SoundBridgeHost

/// Covers the Phase 2.1-B volume state model and the 2.1-E state test list:
/// default initialisation, persistence recovery, restart recovery,
/// uninitialised-state rejection and revision monotonicity.
///
/// Everything here is pure Swift: no CoreAudio, no mapped file, no driver.
final class VolumeStateTests: XCTestCase {

    // MARK: - Fakes

    /// In-memory stand-in for `VolumePersistence`. The real class is only a
    /// debounced JSON file; what the state model needs from it is exactly
    /// "give me what the user last chose, or nil".
    private final class FakePersistence: VolumeStatePersisting {
        var storage: [String: DeviceVolumeState] = [:]
        private(set) var saveCallCount = 0

        func loadIfPresent(uid: String) -> DeviceVolumeState? {
            storage[uid]
        }

        func save(uid: String, volume: Float, muted: Bool) {
            saveCallCount += 1
            storage[uid] = DeviceVolumeState(volumeScalar: volume, isMuted: muted)
        }
    }

    let deviceUID = "test-device-uid"

    // MARK: - 1. Default state

    func testSeedStateIsNotInitialized() {
        let seed = VolumeState.seed
        XCTAssertEqual(seed.requestedScalar, 0.35)
        XCTAssertFalse(seed.initialized, "the seed must never claim to be committed")
        XCTAssertEqual(seed.revision, 0)
        XCTAssertEqual(seed.mode, .software)
        XCTAssertEqual(seed.appliedGain, VolumeTaper.gain(forScalar: 0.35), accuracy: 1e-6)
    }

    func testDefaultScalarIsSharedByAllThreeDefinitions() {
        // VolumeState.defaultScalar, VolumePersistence.defaultVolume and the
        // rf_shared_audio_init() seed (0.35f) must not drift apart.
        XCTAssertEqual(VolumeState.defaultScalar, 0.35)
        XCTAssertEqual(VolumePersistence.defaultVolume, VolumeState.defaultScalar)
    }

    func testFreshStoreResolvesToSafeDefault() {
        let resolution = VolumeStateResolver.resolve(persisted: nil, recovered: nil)
        XCTAssertEqual(resolution.source, .safeDefault)
        XCTAssertEqual(resolution.scalar, VolumeState.defaultScalar)
        XCTAssertFalse(resolution.muted)
        XCTAssertEqual(resolution.mode, .software)

        let store = VolumeStateStore()
        XCTAssertFalse(store.snapshot.initialized)
    }

    // MARK: - 2. Persisted recovery

    func testPersistedVolumeWinsOverEverything() {
        let persistence = FakePersistence()
        persistence.save(uid: deviceUID, volume: 0.62, muted: false)

        let resolution = VolumeStateResolver.resolve(
            persisted: persistence.loadIfPresent(uid: deviceUID),
            recovered: RFVolumeStateSnapshotLike(scalar: 0.10, muted: true, mode: 1, initialized: true)
        )

        XCTAssertEqual(resolution.source, .persisted)
        XCTAssertEqual(resolution.scalar, 0.62, accuracy: 1e-6)
        XCTAssertFalse(resolution.muted)
        // Phase 2.1 never selects HARDWARE, even when the recovered block asks
        // for it: the capability model lands in Phase 2.2.
        XCTAssertEqual(resolution.mode, .software)
    }

    func testPersistedMuteStateSurvives() {
        let resolution = VolumeStateResolver.resolve(
            persisted: DeviceVolumeState(volumeScalar: 0.4, isMuted: true),
            recovered: nil
        )
        XCTAssertEqual(resolution.source, .persisted)
        XCTAssertTrue(resolution.muted)
        XCTAssertEqual(resolution.scalar, 0.4, accuracy: 1e-6)
    }

    func testPersistedGarbageIsSanitised() {
        let nan = VolumeStateResolver.resolve(
            persisted: DeviceVolumeState(volumeScalar: .nan, isMuted: false),
            recovered: nil
        )
        XCTAssertEqual(nan.scalar, VolumeState.defaultScalar)

        let tooLoud = VolumeStateResolver.resolve(
            persisted: DeviceVolumeState(volumeScalar: 4.0, isMuted: false),
            recovered: nil
        )
        XCTAssertEqual(tooLoud.scalar, 1.0)

        let negative = VolumeStateResolver.resolve(
            persisted: DeviceVolumeState(volumeScalar: -3.0, isMuted: false),
            recovered: nil
        )
        XCTAssertEqual(negative.scalar, 0.0)
    }

    // MARK: - 9. Uncommitted state is not authoritative

    func testUninitializedRecoveredStateIsIgnored() {
        let resolution = VolumeStateResolver.resolve(
            persisted: nil,
            recovered: RFVolumeStateSnapshotLike(scalar: 0.90, muted: false, mode: 0, initialized: false)
        )

        XCTAssertEqual(resolution.source, .safeDefault, "an uncommitted block must not become the volume")
        XCTAssertEqual(resolution.scalar, VolumeState.defaultScalar)
    }

    // MARK: - 5. Host restart recovery

    func testRecoveredStateUsedWhenNothingPersisted() {
        let resolution = VolumeStateResolver.resolve(
            persisted: nil,
            recovered: RFVolumeStateSnapshotLike(scalar: 0.55, muted: false, mode: 0, initialized: true)
        )

        XCTAssertEqual(resolution.source, .recovered)
        XCTAssertEqual(resolution.scalar, 0.55, accuracy: 1e-6)
        XCTAssertFalse(resolution.muted)
    }

    func testRecoveredStateIsSanitisedToo() {
        let resolution = VolumeStateResolver.resolve(
            persisted: nil,
            recovered: RFVolumeStateSnapshotLike(scalar: .nan, muted: false, mode: 0, initialized: true)
        )
        XCTAssertEqual(resolution.scalar, VolumeState.defaultScalar)
    }

    func testStoreAdoptsRecoveredStateOnlyOnce() {
        let store = VolumeStateStore()
        let adopted = store.adoptIfUninitialized(
            .committed(scalar: 0.55, muted: false, mode: .software, revision: 7)
        )
        XCTAssertTrue(adopted)
        XCTAssertEqual(store.snapshot.requestedScalar, 0.55, accuracy: 1e-6)

        // A second adoption must not clobber an already-initialized store.
        let adoptedAgain = store.adoptIfUninitialized(
            .committed(scalar: 0.10, muted: false, mode: .software, revision: 8)
        )
        XCTAssertFalse(adoptedAgain)
        XCTAssertEqual(store.snapshot.requestedScalar, 0.55, accuracy: 1e-6)
    }

    // MARK: - 10. Revision monotonicity

    func testInitializeAlwaysBumpsRevision() {
        let store = VolumeStateStore()
        XCTAssertEqual(store.snapshot.revision, 0)

        let first = store.initialize(scalar: 0.42, muted: false)
        XCTAssertEqual(first.revision, 1)
        XCTAssertTrue(first.initialized)

        // Re-initialising for a different device must publish a new revision
        // even when the scalar is identical: the state's owner changed.
        let second = store.initialize(scalar: 0.42, muted: false)
        XCTAssertEqual(second.revision, 2)
    }

    func testCommitBumpsRevisionOnlyOnRealChange() {
        let store = VolumeStateStore()
        store.initialize(scalar: 0.42, muted: false)

        XCTAssertEqual(store.commit(scalar: 0.50, muted: false).revision, 2)
        XCTAssertEqual(store.commit(scalar: 0.60, muted: false).revision, 3)
        XCTAssertEqual(store.commit(scalar: 0.60, muted: true).revision, 4)

        // Identical state: a 60 Hz slider drag must not inflate the counter.
        XCTAssertEqual(store.commit(scalar: 0.60, muted: true).revision, 4)
        XCTAssertEqual(store.commit(scalar: 0.60, muted: true).revision, 4)
    }

    func testCommitIsMonotonicAndFinite() {
        let store = VolumeStateStore()
        store.initialize(scalar: 0.5, muted: false)

        var last = store.snapshot.revision
        // Finite but out-of-range values are clamped and do move the revision.
        let values: [Float] = [0.1, 0.9, 0.3, 2.0, -1.0]
        for value in values {
            let state = store.commit(scalar: value, muted: false)
            XCTAssertGreaterThan(state.revision, last)
            XCTAssertTrue(state.requestedScalar.isFinite)
            XCTAssertGreaterThanOrEqual(state.requestedScalar, 0.0)
            XCTAssertLessThanOrEqual(state.requestedScalar, 1.0)
            last = state.revision
        }
    }

    /// NaN and ±Inf are corruption, not user intent: they fall back to the
    /// currently committed scalar and must not disturb the revision.
    func testPathologicalInputCannotDisturbState() {
        let store = VolumeStateStore()
        let seeded = store.initialize(scalar: 0.42, muted: false)

        for hostile in [Float.nan, .infinity, -.infinity] {
            let state = store.commit(scalar: hostile, muted: false)
            XCTAssertEqual(state.requestedScalar, seeded.requestedScalar, accuracy: 1e-6)
            XCTAssertEqual(state.revision, seeded.revision)
            XCTAssertTrue(state.appliedGain.isFinite)
        }
    }

    func testCommitRejectsNaNWithoutMovingRevision() {
        let store = VolumeStateStore()
        let seeded = store.initialize(scalar: 0.42, muted: false)

        let afterNaN = store.commit(scalar: .nan, muted: false)
        XCTAssertEqual(afterNaN.requestedScalar, seeded.requestedScalar, accuracy: 1e-6)
        XCTAssertEqual(afterNaN.revision, seeded.revision, "a rejected value must not advance the revision")
    }

    // MARK: - Applied gain derivation

    func testCommittedStateRecomputesGain() {
        let state = VolumeState.committed(scalar: 0.25, muted: false, mode: .software, revision: 3)
        XCTAssertEqual(state.appliedGain, VolumeTaper.gain(forScalar: 0.25), accuracy: 1e-6)
        XCTAssertTrue(state.initialized)
    }

    func testCommittedStateSanitisesScalar() {
        let state = VolumeState.committed(scalar: .nan, muted: false, mode: .software, revision: 1)
        XCTAssertEqual(state.requestedScalar, VolumeState.defaultScalar)
        XCTAssertTrue(state.appliedGain.isFinite)
    }

    // MARK: - Mode model

    func testVolumeModeProtocolValues() {
        XCTAssertEqual(VolumeMode.software.protocolValue, 0)
        XCTAssertEqual(VolumeMode.hardware.protocolValue, 1)
        XCTAssertEqual(VolumeMode(protocolValue: 0), .software)
        XCTAssertEqual(VolumeMode(protocolValue: 1), .hardware)
        // Unknown wire values must degrade to SOFTWARE, never to HARDWARE.
        XCTAssertEqual(VolumeMode(protocolValue: 99), .software)
    }
}
