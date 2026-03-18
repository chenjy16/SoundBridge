import XCTest
import SwiftCheck
@testable import SoundBridgeApp

// MARK: - Custom Generators

/// Generator for EQ gain values in the valid range [-12.0, 12.0]
let eqGainGen: Gen<Float> = Float.arbitrary.map { EQController.clampGain($0) }

/// Generator for wide-range floats to test clamping (avoids NaN/Inf)
let wideFloatGen: Gen<Float> = Gen<Float>.fromElements(in: -100.0...100.0)

/// Generator for display-range floats [-12.0, 12.0]
let displayGainGen: Gen<Float> = Gen<Float>.fromElements(in: -12.0...12.0)

// MARK: - Helper to clean up UserDefaults for a device UID

private func cleanupDefaults(for uid: String) {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: EQDefaultsKey.bass(for: uid))
    defaults.removeObject(forKey: EQDefaultsKey.mids(for: uid))
    defaults.removeObject(forKey: EQDefaultsKey.treble(for: uid))
    defaults.removeObject(forKey: EQDefaultsKey.isEnabled(for: uid))
}

// MARK: - Property-Based Tests for EQController

final class EQPropertyTests: XCTestCase {

    // MARK: - Property 1: Weighted Band Mapping Correctness
    // **Validates: Requirements 2.1, 3.1, 4.1**

    func testProperty1_weightedBandMappingCorrectness() {
        let label = "Feature: basic-eq-view, Property 1: Weighted Band Mapping correctness"
        property(label) <- forAll(eqGainGen, eqGainGen, eqGainGen) {
            (bass: Float, mids: Float, treble: Float) in

            let gains = EQController.computeBandGains(bass: bass, mids: mids, treble: treble)

            // Bass bands (concentrated: 0.5, 1.0, 1.5)
            let band0OK = gains[0] == bass * 0.5
            let band1OK = gains[1] == bass * 1.0
            let band2OK = gains[2] == bass * 1.5

            // Mids bands (0.6, 1.2)
            let band4OK = gains[4] == mids * 0.6
            let band5OK = gains[5] == mids * 1.2

            // Treble bands (0.4, 1.3)
            let band8OK = gains[8] == treble * 0.4
            let band9OK = gains[9] == treble * 1.3

            // Unused bands always 0.0
            let band3OK = gains[3] == 0.0
            let band6OK = gains[6] == 0.0
            let band7OK = gains[7] == 0.0

            return band0OK && band1OK && band2OK
                && band3OK
                && band4OK && band5OK
                && band6OK && band7OK
                && band8OK && band9OK
        }
    }

    // MARK: - Property 2: Gain Value Range Invariant
    // **Validates: Requirements 1.4**

    func testProperty2_gainValueRangeInvariant() {
        let label = "Feature: basic-eq-view, Property 2: Gain value range invariant"
        property(label) <- forAll(wideFloatGen) { (raw: Float) in
            let clamped = EQController.clampGain(raw)
            return clamped >= -12.0 && clamped <= 12.0
        }
    }

    // MARK: - Property 3: Auto Gain Compensation Formula
    // **Validates: Requirements 6.3**

    func testProperty3_autoGainCompensationFormula() {
        let label = "Feature: basic-eq-view, Property 3: Auto gain compensation disabled (always 0)"
        property(label) <- forAll(eqGainGen, eqGainGen, eqGainGen) {
            (bass: Float, mids: Float, treble: Float) in

            let preamp = EQController.computeAutoGainCompensation(
                bass: bass, mids: mids, treble: treble
            )

            // Auto gain compensation is disabled — always returns 0.0
            return preamp == 0.0
        }
    }

    // MARK: - Property 4: Reset Zeroes State
    // **Validates: Requirements 6.2, 6.3**

    func testProperty4_resetZeroesState() {
        let label = "Feature: basic-eq-view, Property 4: Reset zeroes state"
        // Reuse a single controller instance to avoid ObservableObject allocation overhead
        let controller = EQController(testDeviceUID: "test-reset")

        property(label) <- forAll(eqGainGen, eqGainGen, eqGainGen) {
            (bass: Float, mids: Float, treble: Float) in

            controller.bass = bass
            controller.mids = mids
            controller.treble = treble

            controller.reset()

            let bassZero = controller.bass == 0.0
            let midsZero = controller.mids == 0.0
            let trebleZero = controller.treble == 0.0

            // After reset, auto gain compensation should also be 0.0
            let preamp = EQController.computeAutoGainCompensation(
                bass: controller.bass, mids: controller.mids, treble: controller.treble
            )
            let preampZero = preamp == 0.0

            return bassZero && midsZero && trebleZero && preampZero
        }
    }

    // MARK: - Property 5: Persistence Round-Trip Consistency
    // **Validates: Requirements 8.1, 8.2**

    func testProperty5_persistenceRoundTripConsistency() {
        let label = "Feature: basic-eq-view, Property 5: Persistence round-trip consistency"
        // Use a single pair of controllers: one to save, one to restore
        let uid = "test-persist-pbt-\(UUID().uuidString)"
        let saver = EQController(testDeviceUID: uid)
        let restorer = EQController(testDeviceUID: uid)

        property(label) <- forAll(eqGainGen, eqGainGen, eqGainGen, Bool.arbitrary) {
            (bass: Float, mids: Float, treble: Float, enabled: Bool) in

            saver.bass = bass
            saver.mids = mids
            saver.treble = treble
            saver.isEnabled = enabled

            saver.saveToUserDefaults()

            // Load into the restorer from the same UID
            restorer.loadFromUserDefaults()

            let bassMatch = restorer.bass == bass
            let midsMatch = restorer.mids == mids
            let trebleMatch = restorer.treble == treble
            let enabledMatch = restorer.isEnabled == enabled

            return bassMatch && midsMatch && trebleMatch && enabledMatch
        }

        cleanupDefaults(for: uid)
    }

    // MARK: - Property 6: Initialization Idempotency
    // **Validates: Requirements 5.1, 5.2, 5.3**

    func testProperty6_initializationIdempotency() {
        let label = "Feature: basic-eq-view, Property 6: Initialization idempotency"
        // Reuse a single controller instance
        let controller = EQController(testDeviceUID: "test-idempotent")

        property(label) <- forAll(eqGainGen, eqGainGen, eqGainGen) {
            (bass: Float, mids: Float, treble: Float) in

            controller.bass = bass
            controller.mids = mids
            controller.treble = treble

            let preset1 = controller.buildInitialPreset()
            let preset2 = controller.buildInitialPreset()

            // Verify both presets are identical
            let nameMatch = preset1.name == preset2.name
            let preampMatch = preset1.preampDb == preset2.preampDb
            let limiterMatch = preset1.limiterEnabled == preset2.limiterEnabled
            let limiterThresholdMatch = preset1.limiterThresholdDb == preset2.limiterThresholdDb
            let bandCountMatch = preset1.bands.count == preset2.bands.count

            var bandsMatch = true
            for i in 0..<min(preset1.bands.count, preset2.bands.count) {
                let b1 = preset1.bands[i]
                let b2 = preset2.bands[i]
                if b1.frequencyHz != b2.frequencyHz ||
                   b1.gainDb != b2.gainDb ||
                   b1.qFactor != b2.qFactor ||
                   b1.filterType != b2.filterType ||
                   b1.enabled != b2.enabled {
                    bandsMatch = false
                    break
                }
            }

            return nameMatch && preampMatch && limiterMatch
                && limiterThresholdMatch && bandCountMatch && bandsMatch
        }
    }

    // MARK: - Property 7: dB Display Formatting
    // **Validates: Requirements 1.3**

    func testProperty7_dbDisplayFormatting() {
        let label = "Feature: basic-eq-view, Property 7: dB display formatting"
        property(label) <- forAll(displayGainGen) { (value: Float) in
            let formatted = String(format: "%.1f", value)

            // Verify exactly one decimal place: should match pattern like "-12.0", "0.0", "5.3"
            let parts = formatted.split(separator: ".", maxSplits: 2)
            guard parts.count == 2 else { return false }
            return parts[1].count == 1
        }
    }

    // MARK: - Property 10: Change Detection Correctness
    // **Validates: Requirements 2.1, 3.1, 4.1**

    func testProperty10_changeDetectionCorrectness() {
        let label = "Feature: basic-eq-view, Property 10: Change detection correctness"

        // Reuse a single controller for all iterations
        let controller = EQController(testDeviceUID: "test-change-detect")

        // Test gain threshold detection
        let gainLabel = label + " (gain threshold)"
        property(gainLabel) <- forAll(eqGainGen, eqGainGen, eqGainGen,
                                      eqGainGen, eqGainGen, eqGainGen) {
            (bass1: Float, mids1: Float, treble1: Float,
             bass2: Float, mids2: Float, treble2: Float) in

            // Set state 1 and sync cache
            controller.bass = bass1
            controller.mids = mids1
            controller.treble = treble1
            controller.isEnabled = true
            controller.updateCache()

            // Set state 2 (cache still holds state 1)
            controller.bass = bass2
            controller.mids = mids2
            controller.treble = treble2

            let hasChange = controller.hasSignificantChange()

            let bassDiff = abs(bass2 - bass1) >= 0.01
            let midsDiff = abs(mids2 - mids1) >= 0.01
            let trebleDiff = abs(treble2 - treble1) >= 0.01
            let expectedChange = bassDiff || midsDiff || trebleDiff

            return hasChange == expectedChange
        }

        // Test bypass change detection
        let bypassLabel = label + " (bypass toggle)"
        property(bypassLabel) <- forAll(Bool.arbitrary, Bool.arbitrary) {
            (en1: Bool, en2: Bool) in

            controller.bass = 0.0
            controller.mids = 0.0
            controller.treble = 0.0
            controller.isEnabled = en1
            controller.updateCache()

            controller.isEnabled = en2

            let hasChange = controller.hasSignificantChange()
            let bypassDiff = (!en2) != (!en1)

            return hasChange == bypassDiff
        }
    }
}
