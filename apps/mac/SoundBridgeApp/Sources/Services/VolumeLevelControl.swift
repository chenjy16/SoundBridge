import CoreAudio

/// The outcome of one volume or mute write.
///
/// P1-1 requires an explicit result: `VolumeController.setVolume`/`setMute` used
/// to return `Void` and published the requested value to the UI on the strength
/// of the HAL status code alone. A control that accepts the request and then
/// ignores it therefore looked successful in the menu bar while the audio device
/// was somewhere else.
enum ControlCommitResult<Value: Equatable>: Equatable {
    /// The device is in the requested state. The associated value is what was
    /// actually applied.
    case committed(Value)
    /// CoreAudio refused the write on every element that was tried.
    case rejected(OSStatus)
    /// The write returned success but the device does not report the requested
    /// value (or will not report anything). The requested value is NOT in
    /// effect, so the UI must not show it.
    case notVerified(requested: Value, actual: Value?)
    /// There is no target device to write to.
    case unavailable
}

typealias VolumeCommitResult = ControlCommitResult<Float>
typealias MuteCommitResult = ControlCommitResult<Bool>

/// Reads and writes a device's own volume and mute properties.
///
/// The seam exists for the same reason as `DefaultOutputWriting`: the decision
/// ("did this write actually land?") is worth testing, and testing it must not
/// depend on the developer's audio hardware.
protocol VolumeLevelWriting: AnyObject {
    func writeScalar(_ value: Float, to deviceID: AudioObjectID, element: UInt32) -> OSStatus
    func readScalar(from deviceID: AudioObjectID, element: UInt32) -> Float?
    func writeMute(_ muted: Bool, to deviceID: AudioObjectID, element: UInt32) -> OSStatus
    func readMute(from deviceID: AudioObjectID, element: UInt32) -> Bool?
}

/// One write plus, for the SoundBridge proxy, a read-back of what the device
/// reports.
///
/// The read-back is deliberately limited to the proxy. Its taper is known
/// exactly — 48 raw steps with `scalar = (raw / 48)^2`, because the driver sets
/// `MaxRawVolume = 48` over a 48 dB range and libASPL applies its Pow2 transfer
/// function — so "one step off" can be told apart from "the write was dropped".
/// A third-party device may quantise far more coarsely than that, and refusing
/// its valid changes would be a regression, so for a physical device the HAL
/// status remains the answer.
struct VolumeLevelCommit {
    enum Target: Equatable {
        case proxy(AudioObjectID)
        case physical(AudioObjectID)
        case none
    }

    /// The elements the app has always tried, in the order it tried them: the
    /// master control first, then the two channels.
    static let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]

    /// The driver's raw volume resolution (`RF_VOLUME_RAW_MAX`).
    static let taperSteps: Float = 48

    let level: VolumeLevelWriting

    func setVolume(_ value: Float, target: Target) -> VolumeCommitResult {
        guard let deviceID = Self.deviceID(of: target) else { return .unavailable }

        let clamped = min(max(value, 0), 1)
        var appliedElements: [UInt32] = []
        var lastFailure: OSStatus = noErr

        for element in Self.elements {
            let status = level.writeScalar(clamped, to: deviceID, element: element)
            if status == noErr {
                appliedElements.append(element)
                if element == kAudioObjectPropertyElementMain { break }
            } else {
                lastFailure = status
            }
        }

        guard let firstElement = appliedElements.first else { return .rejected(lastFailure) }

        if case .proxy = target {
            guard let actual = level.readScalar(from: deviceID, element: firstElement) else {
                return .notVerified(requested: clamped, actual: nil)
            }
            guard Self.isWithinOneRawStep(clamped, actual) else {
                return .notVerified(requested: clamped, actual: actual)
            }
            return .committed(actual)
        }

        return .committed(clamped)
    }

    func setMute(_ muted: Bool, target: Target) -> MuteCommitResult {
        guard let deviceID = Self.deviceID(of: target) else { return .unavailable }

        var appliedElements: [UInt32] = []
        var lastFailure: OSStatus = noErr

        for element in Self.elements {
            let status = level.writeMute(muted, to: deviceID, element: element)
            if status == noErr {
                appliedElements.append(element)
                if element == kAudioObjectPropertyElementMain { break }
            } else {
                lastFailure = status
            }
        }

        guard let firstElement = appliedElements.first else { return .rejected(lastFailure) }

        if case .proxy = target {
            guard let actual = level.readMute(from: deviceID, element: firstElement) else {
                return .notVerified(requested: muted, actual: nil)
            }
            guard actual == muted else {
                return .notVerified(requested: muted, actual: actual)
            }
        }

        return .committed(muted)
    }

    /// `sqrt(scalar)` is linear in the driver's raw volume, so one raw step is
    /// `1 / 48` in that space. A read-back inside that band is the setter's
    /// quantisation (`roundf` in libASPL's `ConvertScalarToRaw`), not a failure.
    static func isWithinOneRawStep(_ requested: Float, _ actual: Float) -> Bool {
        let requestedRoot = sqrt(min(max(requested, 0), 1))
        let actualRoot = sqrt(min(max(actual, 0), 1))
        return abs(requestedRoot - actualRoot) <= (1.0 / taperSteps) + 1e-4
    }

    private static func deviceID(of target: Target) -> AudioObjectID? {
        switch target {
        case .proxy(let deviceID), .physical(let deviceID):
            return deviceID == kAudioObjectUnknown ? nil : deviceID
        case .none:
            return nil
        }
    }
}

/// The real CoreAudio implementation. The calls are the ones `VolumeController`
/// used to make inline, with the same element probing and the same OSStatus
/// reporting.
final class CoreAudioVolumeLevelWriting: VolumeLevelWriting {

    func writeScalar(_ value: Float, to deviceID: AudioObjectID, element: UInt32) -> OSStatus {
        var volume = value
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<Float>.size), &volume
        )
    }

    func readScalar(from deviceID: AudioObjectID, element: UInt32) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var volume: Float = 0
        var dataSize = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &volume) == noErr else {
            return nil
        }
        return volume
    }

    func writeMute(_ muted: Bool, to deviceID: AudioObjectID, element: UInt32) -> OSStatus {
        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        )
    }

    func readMute(from deviceID: AudioObjectID, element: UInt32) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &muted) == noErr else {
            return nil
        }
        return muted != 0
    }
}
