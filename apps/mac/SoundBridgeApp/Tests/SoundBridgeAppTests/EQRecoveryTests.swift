import XCTest
import Combine
import Darwin
import CSoundBridgeAudio
@testable import SoundBridgeApp

// MARK: - EQ recovery across mapping incarnations
//
// Gate 3's defect: the persisted EQ was restored into the UI but never written
// into the mapping the Host had created before the menu bar view existed.
// `mappingPublished` is a PassthroughSubject, so a publication that happened
// before the controller subscribed was lost, and nothing retried it.
//
// Every test below reads the EQ block out of the *real* mapping the Host would
// create (see `SharedMemoryFixture`), through the same SeqLock reader the Host
// uses — not through a mock that merely records a call. That is what makes
// "applied", "not applied" and "applied to the wrong incarnation" separable.

extension FixtureIncarnation {
    /// `eq_sequence` is the SeqLock counter `rf_store_eq_snapshot` advances by 2
    /// on every write. The test is the only writer here, so a plain load is
    /// enough to tell "written again" from "untouched". Offset 152 is pinned by
    /// the `static_assert` in RFSharedAudio.h.
    var eqSequence: UInt32 {
        UnsafeRawPointer(pointer).advanced(by: 152).load(as: UInt32.self)
    }
}

final class EQRecoveryTests: XCTestCase {

    private var fixture: SharedMemoryFixture!
    private var manager: SharedMemoryMappingManager!
    private var deviceUID: String!

    override func setUp() {
        super.setUp()
        fixture = SharedMemoryFixture(name: "eq-recovery-\(UUID().uuidString)")
        manager = SharedMemoryMappingManager(pathForUID: { [path = fixture.path] _ in path })
        // `revalidate()` resolves the device through this closure; without it the
        // timer-driven path would have nothing to check and never retire.
        manager.deviceUIDProvider = { "eq-recovery-device" }
        deviceUID = "eq-recovery-\(UUID().uuidString)"
        clearDefaults()
    }

    override func tearDown() {
        manager?.stop()
        manager = nil
        fixture?.teardown()
        fixture = nil
        clearDefaults()
        deviceUID = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func seed(bass: Float, mids: Float, treble: Float, enabled: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(bass, forKey: EQDefaultsKey.bass(for: deviceUID))
        defaults.set(mids, forKey: EQDefaultsKey.mids(for: deviceUID))
        defaults.set(treble, forKey: EQDefaultsKey.treble(for: deviceUID))
        defaults.set(enabled, forKey: EQDefaultsKey.isEnabled(for: deviceUID))
    }

    private func clearDefaults() {
        guard let deviceUID else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: EQDefaultsKey.bass(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.mids(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.treble(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.isEnabled(for: deviceUID))
    }

    @discardableResult
    private func publishAndAttach() throws -> FixtureIncarnation {
        let incarnation = try fixture.publish()
        let outcome = manager.attachSynchronously(path: fixture.path)
        XCTAssertTrue(outcome.didAttach, "fixture publish must attach, got \(outcome)")
        return incarnation
    }

    /// Run the main queue (where `mappingPublished` is delivered) until `condition`
    /// holds or the deadline passes.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func expectedBands(bass: Float, mids: Float, treble: Float) -> [Float] {
        EQController.computeBandGains(bass: bass, mids: mids, treble: treble)
    }

    // MARK: - 1. Mapping already exists when the controller is created

    func testPersistedEQIsAppliedToAMappingThatAlreadyExists() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        let incarnation = try publishAndAttach()

        let controller = EQController(deviceUID: deviceUID, mapping: manager)

        // Persisted, UI and published values must agree.
        XCTAssertEqual(controller.bass, 6, accuracy: 0.0001)
        XCTAssertEqual(controller.mids, -3, accuracy: 0.0001)
        XCTAssertEqual(controller.treble, 2, accuracy: 0.0001)
        XCTAssertTrue(controller.isAppliedToCurrentMapping)
        XCTAssertEqual(controller.lastAppliedGeneration, manager.currentGeneration)

        XCTAssertEqual(incarnation.bandGains, expectedBands(bass: 6, mids: -3, treble: 2))
        XCTAssertEqual(incarnation.eqSnapshot?.bypass, false)
        XCTAssertGreaterThan(incarnation.eqSequence, 0, "a write must advance the SeqLock counter")
    }

    // MARK: - 2. Mapping appears after the controller exists

    func testEQIsAppliedWhenTheMappingAppearsAfterTheController() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)

        let controller = EQController(deviceUID: deviceUID, mapping: manager)
        XCTAssertFalse(controller.isAppliedToCurrentMapping, "nothing is applied before a mapping exists")
        XCTAssertNil(controller.lastAppliedGeneration)

        let incarnation = try publishAndAttach()

        XCTAssertTrue(waitUntil { controller.isAppliedToCurrentMapping })
        XCTAssertEqual(controller.lastAppliedGeneration, manager.currentGeneration)
        XCTAssertEqual(incarnation.bandGains, expectedBands(bass: 6, mids: -3, treble: 2))
    }

    // MARK: - 3. Host restart: new inode/epoch/session gets the values again

    func testANewIncarnationGetsTheCurrentValuesAndTheRetiredOneStopsReceivingThem() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        let first = try publishAndAttach()
        let controller = EQController(deviceUID: deviceUID, mapping: manager)
        XCTAssertTrue(controller.isAppliedToCurrentMapping)

        // The user moves the slider; the live incarnation takes it.
        controller.bass = -9
        XCTAssertEqual(controller.flushToSharedMemory(), .written(generation: manager.currentGeneration))
        let expectedAfterUserChange = expectedBands(bass: -9, mids: -3, treble: 2)
        XCTAssertEqual(first.bandGains, expectedAfterUserChange)
        let sequenceAfterUserChange = first.eqSequence

        // The Host restarts: a different inode, epoch and session at the same path.
        let second = try publishAndAttach()
        XCTAssertNotEqual(second.identity.inode, first.identity.inode)

        XCTAssertTrue(waitUntil { controller.lastAppliedGeneration == manager.currentGeneration })
        XCTAssertEqual(second.bandGains, expectedAfterUserChange, "a new incarnation must be restored from the newest values")

        // A later write lands in the new incarnation only.
        controller.bass = 12
        XCTAssertEqual(controller.flushToSharedMemory(), .written(generation: manager.currentGeneration))
        XCTAssertEqual(second.bandGains, expectedBands(bass: 12, mids: -3, treble: 2))

        XCTAssertEqual(first.eqSequence, sequenceAfterUserChange, "a retired incarnation must never be written again")
        XCTAssertEqual(first.bandGains, expectedAfterUserChange)
    }

    // MARK: - 4. Repeated attach of the same incarnation is a no-op

    func testARepeatedAttachDoesNotRewriteTheSameIncarnation() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        let incarnation = try publishAndAttach()
        let controller = EQController(deviceUID: deviceUID, mapping: manager)

        let generation = manager.currentGeneration
        let sequenceAfterRecovery = incarnation.eqSequence
        XCTAssertTrue(controller.isAppliedToCurrentMapping)

        for _ in 0..<3 {
            XCTAssertTrue(manager.attachSynchronously(path: fixture.path).isCurrent)
        }
        _ = waitUntil(timeout: 0.2) { false }

        XCTAssertEqual(manager.currentGeneration, generation, "a duplicate notification must not create a new generation")
        XCTAssertEqual(incarnation.eqSequence, sequenceAfterRecovery, "the same incarnation must not be written twice")
    }

    // MARK: - 5. The newest value wins over the restored one

    func testTheNewestValueWinsOverTheRestoredValue() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        _ = try publishAndAttach()
        let controller = EQController(deviceUID: deviceUID, mapping: manager)

        controller.bass = -9
        controller.flushToSharedMemory()

        let second = try publishAndAttach()
        XCTAssertTrue(waitUntil { controller.lastAppliedGeneration == manager.currentGeneration })

        XCTAssertEqual(second.bandGains, expectedBands(bass: -9, mids: -3, treble: 2),
                       "the recovery must publish the current slider values, not the values loaded at launch")
    }

    // MARK: - 6. Without a mapping nothing is claimed as applied

    func testWithoutAMappingNothingIsClaimedAsApplied() {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)

        let controller = EQController(deviceUID: deviceUID, mapping: manager)

        XCTAssertFalse(controller.isAppliedToCurrentMapping)
        XCTAssertNil(controller.lastAppliedGeneration)
        XCTAssertEqual(controller.flushToSharedMemory(), .unavailable)
        XCTAssertFalse(controller.isAppliedToCurrentMapping, "a skipped write must not be reported as applied")
        XCTAssertNil(controller.lastAppliedGeneration)
        XCTAssertEqual(controller.bass, 6, accuracy: 0.0001, "the value stays available for the next incarnation")
    }

    // MARK: - 7. Retiring the mapping withdraws the claim

    func testRetiringTheMappingWithdrawsTheAppliedClaim() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        _ = try publishAndAttach()
        let controller = EQController(deviceUID: deviceUID, mapping: manager)
        XCTAssertTrue(controller.isAppliedToCurrentMapping)

        fixture.removePublishedFile()
        manager.revalidate()

        XCTAssertTrue(waitUntil { !controller.isAppliedToCurrentMapping })
        XCTAssertNil(controller.lastAppliedGeneration)
        XCTAssertFalse(manager.isAvailable)
    }

    // MARK: - 8. A disabled EQ is restored as bypass

    func testADisabledEQIsRestoredAsBypass() throws {
        seed(bass: 0, mids: 0, treble: 0, enabled: false)
        let incarnation = try publishAndAttach()

        let controller = EQController(deviceUID: deviceUID, mapping: manager)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.isAppliedToCurrentMapping)
        XCTAssertEqual(incarnation.eqSnapshot?.bypass, true)
    }
}
