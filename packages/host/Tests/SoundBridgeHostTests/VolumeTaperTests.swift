import XCTest

@testable import SoundBridgeHost

/// Pins the Host side of the volume taper contract (Phase 2.1, decision D1).
///
/// Curve under test: `dB = 48 * sqrt(s) - 48`, `gain = pow(10, dB / 20)`.
/// The driver reaches the same curve through libASPL's `VolumeCurve` once
/// `MaxDecibelVolume - MinDecibelVolume == 48` (> 30 dB, so the Pow2 branch is
/// active). `testDriverQuantisationMirrorMatchesTaper` is the cross-end check:
/// it walks every raw step the driver can emit and asserts the Host curve
/// agrees with libASPL's `scalar = (raw / 48)^2`, `dB = -48 + raw`.
final class VolumeTaperTests: XCTestCase {

    // MARK: - Reference points

    /// The six scalars the Phase 2.1 spec pins, plus the silent boundary.
    private static let referencePoints: [(scalar: Float, decibels: Float)] = [
        (0.00, -48.0000),
        (1.00, 0.0000),
        (0.75, -6.4308),
        (0.50, -14.0589),
        (0.30, -21.7093),
        (0.10, -32.8211),
        (0.05, -37.2669),
    ]

    func testRangeConstantsAreFortyeightDB() {
        XCTAssertEqual(VolumeTaper.rangeDB, 48.0)
        XCTAssertEqual(VolumeTaper.rawSteps, 48)
        // The Pow2 transfer function only applies above 30 dB. If this ever
        // fails, libASPL has silently degraded to a linear curve and the Host
        // gains are wrong by up to ~29 dB.
        XCTAssertGreaterThan(VolumeTaper.rangeDB, 30.0)
    }

    func testDecibelsAtReferencePoints() {
        for point in Self.referencePoints {
            XCTAssertEqual(
                VolumeTaper.decibels(forScalar: point.scalar),
                point.decibels,
                accuracy: 0.001,
                "dB mismatch at scalar \(point.scalar)"
            )
        }
    }

    func testGainFollowsDecibelDefinition() {
        for point in Self.referencePoints {
            let dB = VolumeTaper.decibels(forScalar: point.scalar)
            let expected = powf(10.0, dB / 20.0)
            XCTAssertEqual(
                VolumeTaper.gain(forScalar: point.scalar),
                expected,
                accuracy: 1e-6,
                "gain mismatch at scalar \(point.scalar)"
            )
        }
    }

    func testUnityGainAtFullScaleAndSilenceAtZero() {
        XCTAssertEqual(VolumeTaper.gain(forScalar: 1.0), 1.0, accuracy: 1e-6)
        // 0 maps to the taper floor, not to a literal 0 gain: -48 dB is the
        // quietest step the driver's HAL control can express, so the two ends
        // agree. The renderer applies an explicit mute on top of this.
        XCTAssertEqual(VolumeTaper.gain(forScalar: 0.0), 0.0039811, accuracy: 1e-6)
    }

    func testDefaultScalarGain() {
        // 0.35 is the documented safe default; -19.60 dB is ~0.1047 gain.
        XCTAssertEqual(
            VolumeTaper.gain(forScalar: VolumeState.defaultScalar),
            0.1047,
            accuracy: 0.0005
        )
    }

    func testCurveIsMonotonic() {
        var previous = -Float.infinity
        for step in 0...100 {
            let scalar = Float(step) / 100.0
            let dB = VolumeTaper.decibels(forScalar: scalar)
            XCTAssertGreaterThan(dB, previous, "curve is not strictly increasing at \(scalar)")
            previous = dB
        }
    }

    // MARK: - Cross-end agreement with libASPL

    /// Driver side: `scalar = (raw / rawRange)^2`, `dB = MinDB + raw`.
    /// Host side: `dB = 48 * sqrt(scalar) - 48`.
    /// They must agree at every raw step the driver exposes.
    func testDriverQuantisationMirrorMatchesTaper() {
        for raw in 0...VolumeTaper.rawSteps {
            let driverScalar = VolumeTaper.scalar(forRawStep: raw)
            let driverDB = -48.0 + Float(raw)
            let hostDB = VolumeTaper.decibels(forScalar: driverScalar)
            XCTAssertEqual(
                hostDB,
                driverDB,
                accuracy: 0.0005,
                "Host/driver curve divergence at raw step \(raw)"
            )
        }
    }

    func testRawStepRoundTripsThroughScalar() {
        for raw in 0...VolumeTaper.rawSteps {
            let scalar = VolumeTaper.scalar(forRawStep: raw)
            XCTAssertEqual(
                VolumeTaper.rawStep(forScalar: scalar),
                raw,
                "raw step \(raw) does not survive a scalar round-trip"
            )
        }
    }

    func testRawStepQuantisationOfInteriorScalars() {
        // sqrt(0.5) * 48 = 33.94 -> 34; sqrt(0.75) * 48 = 41.57 -> 42.
        XCTAssertEqual(VolumeTaper.rawStep(forScalar: 0.5), 34)
        XCTAssertEqual(VolumeTaper.rawStep(forScalar: 0.75), 42)
        XCTAssertEqual(VolumeTaper.rawStep(forScalar: 0.0), 0)
        XCTAssertEqual(VolumeTaper.rawStep(forScalar: 1.0), 48)
    }

    // MARK: - Boundary and hostile inputs

    func testSanitizeClampsOutOfRangeValues() {
        XCTAssertEqual(VolumeTaper.sanitize(-0.5), 0.0)
        XCTAssertEqual(VolumeTaper.sanitize(-1e9), 0.0)
        XCTAssertEqual(VolumeTaper.sanitize(1.5), 1.0)
        XCTAssertEqual(VolumeTaper.sanitize(1e9), 1.0)
        XCTAssertEqual(VolumeTaper.sanitize(0.0), 0.0)
        XCTAssertEqual(VolumeTaper.sanitize(1.0), 1.0)
        XCTAssertEqual(VolumeTaper.sanitize(0.42), 0.42)
    }

    func testSanitizeCollapsesNaNAndInfinity() {
        // Non-finite input is treated as corruption, not as a request: +Inf
        // becomes the fallback, not 1.0. Clamping it up would let a corrupt
        // shared-memory read turn into full-scale output.
        XCTAssertEqual(VolumeTaper.sanitize(.nan), 0.0)
        XCTAssertEqual(VolumeTaper.sanitize(.nan, fallback: 0.5), 0.5)
        XCTAssertEqual(VolumeTaper.sanitize(.infinity), 0.0)
        XCTAssertEqual(VolumeTaper.sanitize(.infinity, fallback: 0.35), 0.35)
        XCTAssertEqual(VolumeTaper.sanitize(-.infinity), 0.0)
        XCTAssertEqual(VolumeTaper.sanitize(-.infinity, fallback: 0.35), 0.35)
        XCTAssertEqual(VolumeTaper.sanitize(.nan, fallback: .nan), 0.0, "a NaN fallback must not leak through")
        XCTAssertEqual(VolumeTaper.sanitize(.nan, fallback: 5.0), 1.0, "fallback is clamped too")
        XCTAssertEqual(VolumeTaper.sanitize(.nan, fallback: -5.0), 0.0, "fallback is clamped too")
    }

    /// A corrupt shared-memory read must never put NaN into the render path.
    func testHostileInputsAlwaysProduceFiniteGain() {
        let hostile: [Float] = [
            .nan, .infinity, -.infinity,
            -.greatestFiniteMagnitude, .greatestFiniteMagnitude,
            -1.0, -0.0001, 0.0, 1.0, 1.0001, 2.0
        ]
        for scalar in hostile {
            // The renderer sanitises with a 0.0 fallback, so corruption is
            // silence and never full scale.
            let gain = VolumeTaper.gain(forScalar: scalar)
            XCTAssertTrue(gain.isFinite, "gain not finite for input \(scalar)")
            XCTAssertGreaterThanOrEqual(gain, 0.0, "negative gain for input \(scalar)")
            XCTAssertLessThanOrEqual(gain, 1.0, "gain above unity for input \(scalar)")

            let dB = VolumeTaper.decibels(forScalar: scalar)
            XCTAssertTrue(dB.isFinite, "dB not finite for input \(scalar)")
            XCTAssertGreaterThanOrEqual(dB, -48.0 - 0.001)
            XCTAssertLessThanOrEqual(dB, 0.0 + 0.001)

            let raw = VolumeTaper.rawStep(forScalar: scalar)
            XCTAssertGreaterThanOrEqual(raw, 0)
            XCTAssertLessThanOrEqual(raw, VolumeTaper.rawSteps)
        }

        // Non-finite reads collapse to silence, never to unity gain.
        XCTAssertEqual(VolumeTaper.gain(forScalar: .infinity), VolumeTaper.gain(forScalar: 0.0), accuracy: 1e-9)
        XCTAssertEqual(VolumeTaper.gain(forScalar: .nan), VolumeTaper.gain(forScalar: 0.0), accuracy: 1e-9)
    }
}
