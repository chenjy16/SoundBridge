import XCTest
@testable import SoundBridgeApp

// MARK: - Unit Tests for EQController (Task 5)

final class EQUnitTests: XCTestCase {

    // MARK: - 5.1 Preset Construction

    func testPresetHas10Bands() {
        let controller = EQController(testDeviceUID: "test-preset")
        let preset = controller.buildInitialPreset()
        XCTAssertEqual(preset.bands.count, 10)
    }

    func testPresetBassbandsAreLowShelfAndEnabled() {
        let controller = EQController(testDeviceUID: "test-preset")
        let preset = controller.buildInitialPreset()

        // Band 0: 32 Hz, lowShelf, enabled
        XCTAssertEqual(preset.bands[0].frequencyHz, 32)
        XCTAssertEqual(preset.bands[0].filterType, .lowShelf)
        XCTAssertTrue(preset.bands[0].enabled)

        // Band 1: 64 Hz, lowShelf, enabled
        XCTAssertEqual(preset.bands[1].frequencyHz, 64)
        XCTAssertEqual(preset.bands[1].filterType, .lowShelf)
        XCTAssertTrue(preset.bands[1].enabled)

        // Band 2: 125 Hz, lowShelf, enabled
        XCTAssertEqual(preset.bands[2].frequencyHz, 125)
        XCTAssertEqual(preset.bands[2].filterType, .lowShelf)
        XCTAssertTrue(preset.bands[2].enabled)
    }

    func testPresetMidsbandsArePeakAndEnabled() {
        let controller = EQController(testDeviceUID: "test-preset")
        let preset = controller.buildInitialPreset()

        // Band 4: 500 Hz, peak, enabled
        XCTAssertEqual(preset.bands[4].frequencyHz, 500)
        XCTAssertEqual(preset.bands[4].filterType, .peak)
        XCTAssertTrue(preset.bands[4].enabled)

        // Band 5: 1000 Hz, peak, enabled
        XCTAssertEqual(preset.bands[5].frequencyHz, 1000)
        XCTAssertEqual(preset.bands[5].filterType, .peak)
        XCTAssertTrue(preset.bands[5].enabled)
    }

    func testPresetTreblebandsAreHighShelfAndEnabled() {
        let controller = EQController(testDeviceUID: "test-preset")
        let preset = controller.buildInitialPreset()

        // Band 8: 8000 Hz, highShelf, enabled
        XCTAssertEqual(preset.bands[8].frequencyHz, 8000)
        XCTAssertEqual(preset.bands[8].filterType, .highShelf)
        XCTAssertTrue(preset.bands[8].enabled)

        // Band 9: 16000 Hz, highShelf, enabled
        XCTAssertEqual(preset.bands[9].frequencyHz, 16000)
        XCTAssertEqual(preset.bands[9].filterType, .highShelf)
        XCTAssertTrue(preset.bands[9].enabled)
    }

    func testPresetUnusedBandsAreDisabled() {
        let controller = EQController(testDeviceUID: "test-preset")
        let preset = controller.buildInitialPreset()

        // Band 3: 250 Hz, peak, disabled
        XCTAssertEqual(preset.bands[3].frequencyHz, 250)
        XCTAssertEqual(preset.bands[3].filterType, .peak)
        XCTAssertFalse(preset.bands[3].enabled)

        // Band 6: 2000 Hz, peak, disabled
        XCTAssertEqual(preset.bands[6].frequencyHz, 2000)
        XCTAssertEqual(preset.bands[6].filterType, .peak)
        XCTAssertFalse(preset.bands[6].enabled)

        // Band 7: 4000 Hz, peak, disabled
        XCTAssertEqual(preset.bands[7].frequencyHz, 4000)
        XCTAssertEqual(preset.bands[7].filterType, .peak)
        XCTAssertFalse(preset.bands[7].enabled)
    }

    // MARK: - 5.2 EQController Defaults

    func testControllerDefaultBassIsZero() {
        let controller = EQController(testDeviceUID: "test-defaults")
        XCTAssertEqual(controller.bass, 0.0)
    }

    func testControllerDefaultMidsIsZero() {
        let controller = EQController(testDeviceUID: "test-defaults")
        XCTAssertEqual(controller.mids, 0.0)
    }

    func testControllerDefaultTrebleIsZero() {
        let controller = EQController(testDeviceUID: "test-defaults")
        XCTAssertEqual(controller.treble, 0.0)
    }

    func testControllerDefaultIsEnabledTrue() {
        let controller = EQController(testDeviceUID: "test-defaults")
        XCTAssertTrue(controller.isEnabled)
    }

    // MARK: - 5.3 EQ Toggle / Bypass Mapping

    func testBypassTrueWhenDisabled() {
        let controller = EQController(testDeviceUID: "test-bypass")
        controller.isEnabled = false
        // bypass is the inverse of isEnabled
        let bypass = !controller.isEnabled
        XCTAssertTrue(bypass)
    }

    func testBypassFalseWhenEnabled() {
        let controller = EQController(testDeviceUID: "test-bypass")
        controller.isEnabled = true
        let bypass = !controller.isEnabled
        XCTAssertFalse(bypass)
    }

    func testBypassToggleRoundTrip() {
        let controller = EQController(testDeviceUID: "test-bypass")
        // Start enabled → disable → re-enable
        XCTAssertTrue(controller.isEnabled)

        controller.isEnabled = false
        XCTAssertTrue(!controller.isEnabled)  // bypass = true

        controller.isEnabled = true
        XCTAssertFalse(!controller.isEnabled) // bypass = false
    }

    // MARK: - 5.4 UserDefaults Missing → Defaults Used (Boundary 8.3)

    func testLoadFromUserDefaultsMissing_usesDefaults() {
        // Use a unique UID that has never been saved
        let uid = "test-missing-defaults-\(UUID().uuidString)"
        let controller = EQController(testDeviceUID: uid)

        // Ensure nothing is stored
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: EQDefaultsKey.bass(for: uid))
        defaults.removeObject(forKey: EQDefaultsKey.mids(for: uid))
        defaults.removeObject(forKey: EQDefaultsKey.treble(for: uid))
        defaults.removeObject(forKey: EQDefaultsKey.isEnabled(for: uid))

        // Load should fall back to defaults
        controller.loadFromUserDefaults()

        XCTAssertEqual(controller.bass, 0.0)
        XCTAssertEqual(controller.mids, 0.0)
        XCTAssertEqual(controller.treble, 0.0)
        XCTAssertTrue(controller.isEnabled)
    }

    func testLoadFromUserDefaultsPartiallyMissing_usesDefaultsForMissing() {
        let uid = "test-partial-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults.standard

        // Only store bass, leave mids/treble/isEnabled missing
        defaults.set(Float(5.0), forKey: EQDefaultsKey.bass(for: uid))

        let controller = EQController(testDeviceUID: uid)
        controller.loadFromUserDefaults()

        XCTAssertEqual(controller.bass, 5.0)
        XCTAssertEqual(controller.mids, 0.0)    // default
        XCTAssertEqual(controller.treble, 0.0)   // default
        XCTAssertTrue(controller.isEnabled)       // default

        // Cleanup
        defaults.removeObject(forKey: EQDefaultsKey.bass(for: uid))
    }

    // MARK: - 5.5 Change Detection

    func testNoSignificantChange_belowThreshold() {
        let controller = EQController(testDeviceUID: "test-change")
        controller.bass = 1.0
        controller.mids = 2.0
        controller.treble = 3.0
        controller.isEnabled = true
        controller.updateCache()

        // Tiny change below 0.01 dB threshold
        controller.bass = 1.005
        controller.mids = 2.009
        controller.treble = 3.001

        XCTAssertFalse(controller.hasSignificantChange())
    }

    func testSignificantChange_atThreshold() {
        let controller = EQController(testDeviceUID: "test-change")
        controller.bass = 0.0
        controller.mids = 0.0
        controller.treble = 0.0
        controller.isEnabled = true
        controller.updateCache()

        // Exactly at 0.01 dB threshold on bass (from 0.0 avoids float rounding)
        controller.bass = 0.01

        XCTAssertTrue(controller.hasSignificantChange())
    }

    func testSignificantChange_aboveThreshold() {
        let controller = EQController(testDeviceUID: "test-change")
        controller.bass = 0.0
        controller.mids = 0.0
        controller.treble = 0.0
        controller.isEnabled = true
        controller.updateCache()

        controller.treble = 0.5

        XCTAssertTrue(controller.hasSignificantChange())
    }

    func testSignificantChange_bypassToggle() {
        let controller = EQController(testDeviceUID: "test-change")
        controller.bass = 0.0
        controller.mids = 0.0
        controller.treble = 0.0
        controller.isEnabled = true
        controller.updateCache()

        // Only bypass changed (gains unchanged)
        controller.isEnabled = false

        XCTAssertTrue(controller.hasSignificantChange())
    }

    func testNoSignificantChange_identicalState() {
        let controller = EQController(testDeviceUID: "test-change")
        controller.bass = 5.0
        controller.mids = -3.0
        controller.treble = 7.5
        controller.isEnabled = false
        controller.updateCache()

        // No change at all
        XCTAssertFalse(controller.hasSignificantChange())
    }
}
