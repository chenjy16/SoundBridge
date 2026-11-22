import XCTest
import Darwin
import CSoundBridgeAudio
@testable import SoundBridgeApp

// MARK: - P1-2: the EQ the user last set is the EQ that comes back
//
// 1.2.0 lost the *last* value of every adjustment. The only code that saved was
// inside the 30 Hz throttled sink, behind its "nothing changed" early return,
// and `BasicEQView` calls `flushToSharedMemory()` when the slider is released —
// which advanced the change-detection cache without saving. The delivery still
// in flight then looked like a no-op, so the position the user let go of was the
// one value that could not survive a restart.
//
// Two things are proved here, and they are different claims:
//
//   * the stored state is the last value the user set (persistence), and
//   * that stored state is what the DSP block receives (restoration), read
//     through a second mapping of the published file exactly like the Host
//     reads it, rather than from the writer's own view.

final class EQPersistenceTests: XCTestCase {

    private var fixture: SharedMemoryFixture!
    private var manager: SharedMemoryMappingManager!
    private var deviceUID: String!

    override func setUp() {
        super.setUp()
        fixture = SharedMemoryFixture(name: "eq-persist-\(UUID().uuidString)")
        manager = SharedMemoryMappingManager(pathForUID: { [path = fixture.path] _ in path })
        manager.deviceUIDProvider = { "eq-persist-device" }
        deviceUID = "eq-persist-\(UUID().uuidString)"
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

    private func clearDefaults() {
        guard let deviceUID else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: EQDefaultsKey.state(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.bass(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.mids(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.treble(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.isEnabled(for: deviceUID))
    }

    /// What `UserDefaults` holds, decoded the same way the controller decodes it.
    private func stored() -> EQPersistedState {
        let raw = UserDefaults.standard.dictionary(forKey: EQDefaultsKey.state(for: deviceUID)) ?? [:]
        return EQPersistedState.decode(raw)
    }

    private func storedRaw() -> [String: Any]? {
        UserDefaults.standard.dictionary(forKey: EQDefaultsKey.state(for: deviceUID))
    }

    /// A controller with no mapping: the "Host is not running" case, where
    /// UserDefaults is the only copy that survives.
    private func detachedController() -> EQController {
        EQController(deviceUID: deviceUID, mapping: nil)
    }

    @discardableResult
    private func publishAndAttach() throws -> FixtureIncarnation {
        let incarnation = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(path: fixture.path).didAttach)
        return incarnation
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Read the EQ block through a second mapping of the published path — what
    /// the Host's own process does. Deliberately not the writer's view.
    private func readPublishedEQ() throws -> RFEQSnapshot? {
        let fd = open(fixture.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0, "published mapping must exist")
        defer { close(fd) }

        var info = stat()
        XCTAssertEqual(fstat(fd, &info), 0)
        let size = Int(info.st_size)
        guard size > 0, let raw = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), raw != MAP_FAILED else {
            throw XCTSkip("could not map the published file")
        }
        defer { munmap(raw, size) }

        let memory = raw.assumingMemoryBound(to: RFSharedAudio.self)
        var snapshot = RFEQSnapshot()
        return rf_load_eq_snapshot_safe(memory, &snapshot) ? snapshot : nil
    }

    private func bands(of snapshot: RFEQSnapshot) -> [Float] {
        var copy = snapshot
        return withUnsafeBytes(of: &copy.bands) { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - The state that is stored

    func testTheLastStateSurvivesAnAppRestart() {
        let before = detachedController()
        before.bass = 3.0
        before.mids = -2.0
        before.treble = 1.5
        before.isEnabled = false
        before.saveToUserDefaults()

        let after = detachedController()

        XCTAssertEqual(after.bass, 3.0, accuracy: 1e-6)
        XCTAssertEqual(after.mids, -2.0, accuracy: 1e-6)
        XCTAssertEqual(after.treble, 1.5, accuracy: 1e-6)
        XCTAssertFalse(after.isEnabled)
    }

    /// The exact 1.2.0 sequence: a drag the throttle already delivered once, then
    /// a release that flushes a newer value and lands it.
    func testTheReleasedSliderPositionIsPersistedImmediately() throws {
        _ = try publishAndAttach()
        let controller = EQController(deviceUID: deviceUID, mapping: manager)

        controller.bass = 1.0
        XCTAssertTrue(waitUntil { abs(self.stored().bass - 1.0) < 1e-6 },
                      "the throttled delivery is the baseline the bug hid behind")

        controller.bass = 4.0
        // What the release does. The write lands, so the cache moves to 4.0 and
        // the throttled delivery still in flight becomes a no-op.
        XCTAssertEqual(controller.flushToSharedMemory(),
                       .written(generation: manager.currentGeneration))

        XCTAssertEqual(stored().bass, 4.0, accuracy: 1e-6,
                       "the position the user released at must be on disk, not the one before it")
    }

    func testAResetIsPersistedImmediately() {
        let controller = detachedController()
        controller.bass = 5.0
        controller.mids = -4.0
        controller.treble = 2.0
        controller.saveToUserDefaults()

        controller.reset()

        XCTAssertEqual(stored(), EQPersistedState(bass: 0, mids: 0, treble: 0,
                                                 isEnabled: controller.isEnabled))
    }

    func testAllFourValuesAreStoredTogetherUnderOneKey() {
        let controller = detachedController()
        controller.bass = 1.0
        controller.mids = 2.0
        controller.treble = 3.0
        controller.isEnabled = false
        controller.saveToUserDefaults()

        let raw = storedRaw()
        XCTAssertEqual(raw?["bass"] as? Float, 1.0)
        XCTAssertEqual(raw?["mids"] as? Float, 2.0)
        XCTAssertEqual(raw?["treble"] as? Float, 3.0)
        XCTAssertEqual(raw?["enabled"] as? Bool, false)

        // One key means one replacement: a crash cannot pair the gains of one
        // drag with the bypass flag of another.
        let legacyKeys = [EQDefaultsKey.bass(for: deviceUID), EQDefaultsKey.mids(for: deviceUID),
                          EQDefaultsKey.treble(for: deviceUID), EQDefaultsKey.isEnabled(for: deviceUID)]
        for key in legacyKeys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key),
                         "the 1.2.0 layout must not be written any more")
        }
    }

    func testADeviceWithNoStoredStateStartsFlat() {
        let controller = detachedController()

        XCTAssertEqual(controller.bass, 0)
        XCTAssertEqual(controller.mids, 0)
        XCTAssertEqual(controller.treble, 0)
        XCTAssertTrue(controller.isEnabled)
    }

    func testThe1_2_0LayoutIsAdoptedAndRewrittenOnce() {
        let defaults = UserDefaults.standard
        defaults.set(Float(3.0), forKey: EQDefaultsKey.bass(for: deviceUID))
        defaults.set(Float(-1.0), forKey: EQDefaultsKey.mids(for: deviceUID))
        defaults.set(Float(0.5), forKey: EQDefaultsKey.treble(for: deviceUID))
        defaults.set(false, forKey: EQDefaultsKey.isEnabled(for: deviceUID))

        let controller = detachedController()

        XCTAssertEqual(controller.bass, 3.0, accuracy: 1e-6, "an upgrade must not flatten the EQ")
        XCTAssertEqual(controller.mids, -1.0, accuracy: 1e-6)
        XCTAssertEqual(controller.treble, 0.5, accuracy: 1e-6)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(storedRaw(), "the adopted state is written in the current shape")
    }

    // MARK: - Corrupt and hostile data

    func testOneUnreadableFieldKeepsTheOthers() {
        let defaults = UserDefaults.standard
        defaults.set(["bass": "loud", "mids": 2.0, "treble": 1.0, "enabled": false] as [String: Any],
                     forKey: EQDefaultsKey.state(for: deviceUID))

        let controller = detachedController()

        XCTAssertEqual(controller.bass, 0, "only the unusable field falls back")
        XCTAssertEqual(controller.mids, 2.0, accuracy: 1e-6)
        XCTAssertEqual(controller.treble, 1.0, accuracy: 1e-6)
        XCTAssertFalse(controller.isEnabled)
    }

    func testANonFiniteGainIsRejected() {
        let state = EQPersistedState.decode([
            "bass": NSNumber(value: Double.nan),
            "mids": NSNumber(value: Double.infinity),
            "treble": NSNumber(value: 2.0),
            "enabled": NSNumber(value: true),
        ])

        // `clampGain` cannot repair these: every comparison with NaN is false.
        XCTAssertEqual(state.bass, 0)
        XCTAssertEqual(state.mids, 0)
        XCTAssertEqual(state.treble, 2.0, accuracy: 1e-6)
    }

    func testAnOutOfRangeGainIsClampedRatherThanDiscarded() {
        let state = EQPersistedState.decode([
            "bass": NSNumber(value: 99.0),
            "mids": NSNumber(value: -40.0),
        ])

        XCTAssertEqual(state.bass, 12.0)
        XCTAssertEqual(state.mids, -12.0)
    }

    func testABooleanIsNotAcceptedAsAGain() {
        let state = EQPersistedState.decode([
            "bass": NSNumber(value: true),
            "mids": NSNumber(value: 1.5),
        ])

        XCTAssertEqual(state.bass, 0, "a boolean would otherwise read as 1.0 dB")
        XCTAssertEqual(state.mids, 1.5, accuracy: 1e-6)
    }

    func testANonBooleanBypassFlagFallsBackToEnabled() {
        let state = EQPersistedState.decode(["enabled": "yes"])

        XCTAssertTrue(state.isEnabled, "enabled is the state the user can see and correct")
    }

    func testAMissingFieldFallsBackToItsDefault() {
        let state = EQPersistedState.decode(["mids": NSNumber(value: -3.0)])

        XCTAssertEqual(state.bass, 0)
        XCTAssertEqual(state.mids, -3.0, accuracy: 1e-6)
        XCTAssertEqual(state.treble, 0)
        XCTAssertTrue(state.isEnabled)
    }

    // MARK: - The restored value reaching the DSP

    func testARestoredValueIsWrittenIntoTheSharedMemoryBlock() throws {
        let author = detachedController()
        author.bass = 3.0
        author.mids = -1.5
        author.treble = 4.0
        author.isEnabled = false
        author.saveToUserDefaults()

        _ = try publishAndAttach()

        // A new controller, as after a relaunch: the values come from disk.
        let restored = EQController(deviceUID: deviceUID, mapping: manager)

        XCTAssertEqual(restored.bass, 3.0, accuracy: 1e-6)
        XCTAssertTrue(restored.isAppliedToCurrentMapping)

        let snapshot = try XCTUnwrap(try readPublishedEQ(), "the EQ block must be readable")
        XCTAssertEqual(bands(of: snapshot),
                       EQController.computeBandGains(bass: 3.0, mids: -1.5, treble: 4.0),
                       "the restored state must be the state the DSP reads")
        XCTAssertTrue(snapshot.bypass, "the restored bypass flag must reach the DSP too")
    }

    func testAHostRestartReappliesTheRestoredValue() throws {
        let author = detachedController()
        author.bass = -6.0
        author.mids = 2.5
        author.treble = 1.0
        author.saveToUserDefaults()

        let first = try publishAndAttach()
        // Held for the whole test: the writer is what re-applies into the next
        // incarnation, and its sink dies with it.
        let writer = EQController(deviceUID: deviceUID, mapping: manager)
        let expected = EQController.computeBandGains(bass: -6, mids: 2.5, treble: 1)
        XCTAssertEqual(first.bandGains, expected)

        // The Host exits and publishes a new inode on the same path.
        let second = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(path: fixture.path).didAttach)
        XCTAssertTrue(waitUntil { second.bandGains == expected },
                      "a Host restart must not flatten the EQ")
        XCTAssertTrue(writer.isAppliedToCurrentMapping)
    }

    func testAnUnavailableMappingDoesNotLoseTheState() {
        let controller = detachedController()
        controller.bass = 2.0
        controller.mids = -2.0
        controller.treble = 0.5

        XCTAssertEqual(controller.flushToSharedMemory(), .unavailable)
        XCTAssertFalse(controller.isAppliedToCurrentMapping,
                       "nothing was written, so nothing may be claimed as applied")

        XCTAssertEqual(stored().bass, 2.0, accuracy: 1e-6,
                       "persistence must not depend on a mapping existing")
        XCTAssertEqual(stored().mids, -2.0, accuracy: 1e-6)
        XCTAssertEqual(stored().treble, 0.5, accuracy: 1e-6)
    }
}
