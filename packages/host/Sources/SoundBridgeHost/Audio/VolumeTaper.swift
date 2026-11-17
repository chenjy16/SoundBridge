import Foundation

/// The single Swift-side definition of the SoundBridge volume taper.
///
/// Both ends of the shared-memory boundary must agree on this curve:
///
///     dB   = 48 * sqrt(scalar) - 48
///     gain = pow(10, dB / 20)
///
/// The driver produces the same curve implicitly rather than explicitly.
/// libASPL's `VolumeCurve` applies its Pow2 transfer function only when the dB
/// range exceeds 30 dB (`packages/driver/vendor/libASPL/src/VolumeCurve.cpp`,
/// `ConvertRawToScalar` / `ConvertScalarToRaw`). With the parameters the driver
/// now advertises — `MinRawVolume = 0`, `MaxRawVolume = 48`,
/// `MinDecibelVolume = -48`, `MaxDecibelVolume = 0` — that works out to:
///
///     scalar = (raw / 48)^2          dB = -48 + raw
///     => dB = 48 * sqrt(scalar) - 48
///
/// which is the same function this file implements. `VolumeTaperTests` pins
/// the numeric agreement across every raw step the driver can produce.
///
/// TRAP: the equivalence above exists only while the dB range stays above
/// 30 dB. Shrinking it makes libASPL silently fall back to a linear curve
/// while this file keeps the square root, and the two sides drift apart by up
/// to ~29 dB. `RFSharedAudio.h` and `Plugin.cpp` each carry a `static_assert`
/// for the range; do not weaken either of them.
enum VolumeTaper {
    /// Full-scale attenuation of the taper, in dB below unity.
    static let rangeDB: Float = 48.0

    /// Number of discrete steps the driver exposes as its raw volume range.
    static let rawSteps: Int = 48

    // MARK: - Host side

    /// Map a normalised scalar onto the taper's dB value.
    ///
    /// `0` maps to `-rangeDB`, `1` maps to `0 dB`. NaN and infinities collapse
    /// through `sanitize(_:fallback:)` before any maths happens, so a corrupt
    /// shared-memory read can never reach the render gain stage as NaN.
    static func decibels(forScalar scalar: Float) -> Float {
        rangeDB * sqrtf(sanitize(scalar)) - rangeDB
    }

    /// Linear amplitude for a scalar: `1.0` at full volume, `0.0` at zero.
    static func gain(forScalar scalar: Float) -> Float {
        powf(10.0, decibels(forScalar: scalar) / 20.0)
    }

    // MARK: - Driver mirror

    /// Reproduce libASPL's `ConvertRawToScalar` for a raw step (`0...48`).
    ///
    /// Only used by tests and diagnostics: it exists so the Host side of the
    /// contract can be checked against the driver's arithmetic without linking
    /// libASPL into the Swift package.
    static func scalar(forRawStep raw: Int) -> Float {
        let clamped = min(max(raw, 0), rawSteps)
        let linear = Float(clamped) / Float(rawSteps)
        return linear * linear
    }

    /// Reproduce libASPL's raw quantisation of a scalar:
    /// `ConvertScalarToRaw` does `round(sqrt(s) * rawRange)`.
    static func rawStep(forScalar scalar: Float) -> Int {
        let scaled = sqrtf(sanitize(scalar)) * Float(rawSteps)
        let rounded = Int(scaled.rounded())
        return min(max(rounded, 0), rawSteps)
    }

    // MARK: - Input hygiene

    /// Clamp and de-NaN a scalar before it reaches a gain multiply.
    ///
    /// Same rule as `rf_sanitize_volume_scalar()` in `RFSharedAudio.h`:
    ///   - finite values are clamped to `[0, 1]`,
    ///   - non-finite values (NaN, ±Inf) collapse to `fallback`, because +Inf
    ///     is a corrupt read, not a request for full scale,
    ///   - a non-finite `fallback` collapses to `0.0`, so NaN cannot leak
    ///     through the fallback path.
    ///
    /// Anything that survives this is safe to feed into `sqrtf` and `powf` on
    /// the realtime thread.
    static func sanitize(_ scalar: Float, fallback: Float = 0.0) -> Float {
        let safeFallback: Float
        if fallback.isFinite {
            safeFallback = min(max(fallback, 0.0), 1.0)
        } else {
            safeFallback = 0.0
        }

        guard scalar.isFinite else { return safeFallback }
        return min(max(scalar, 0.0), 1.0)
    }
}
