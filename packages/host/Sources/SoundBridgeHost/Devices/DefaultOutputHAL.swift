import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "DefaultOutputHAL")

/// The HAL surface the Host uses around the system default output.
///
/// P2 Batch 2 deleted every automatic write: startup, reconnect, recovery,
/// device callbacks and shutdown no longer ask CoreAudio to change the default
/// output device. `setDefaultOutput(_:)` stays on this protocol because the HAL
/// has the operation, not because the Host uses it — no file in this module
/// calls it.
///
/// Keeping it is what makes the invariant testable instead of merely asserted:
/// the lifecycle tests install `RecordingDefaultOutputHAL`, drive the real
/// `ProxyDeviceManager` / `DeviceMonitor` / `ShutdownSequence`, and fail if a
/// future change routes any of those paths through a write. The recording is
/// only meaningful while the seam is the same one production uses, which is why
/// `ProxyDeviceManager` reads and finds devices exclusively through it.
protocol DefaultOutputHAL: AnyObject {
    /// The system default output device, or `nil` when the query failed.
    func defaultOutputDevice() -> AudioDeviceID?
    /// The device's UID, or `nil` when CoreAudio will not answer.
    func deviceUID(_ deviceID: AudioDeviceID) -> String?
    /// The device's display name, or `nil` when CoreAudio will not answer.
    func deviceName(_ deviceID: AudioDeviceID) -> String?
    /// The live AudioObjectID for `uid`, re-resolved from the HAL device list.
    func deviceID(forUID uid: String) -> AudioDeviceID?

    /// Change the system default output device.
    ///
    /// Reserved for an explicit user action. Nothing in `SoundBridgeHost` calls
    /// this: the App owns the one user-facing switch (`VolumeController` →
    /// `DefaultOutputSwitch`). See `DefaultOutputGovernanceTests`.
    @discardableResult
    func setDefaultOutput(_ deviceID: AudioDeviceID) -> Bool
}

/// The real CoreAudio implementation.
///
/// These five calls are the ones `ProxyDeviceManager` used to make inline. They
/// are unchanged, including the `Unmanaged<CFString>` handling the property
/// getters need.
final class CoreAudioDefaultOutputHAL: DefaultOutputHAL {

    func defaultOutputDevice() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr else {
            return nil
        }

        return deviceID
    }

    func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfUID = uid?.takeUnretainedValue() else {
            return nil
        }
        return cfUID as String
    }

    func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfName = name?.takeUnretainedValue() else {
            return nil
        }
        return cfName as String
    }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        for deviceID in deviceIDs where self.deviceUID(deviceID) == uid {
            return deviceID
        }
        return nil
    }

    func setDefaultOutput(_ deviceID: AudioDeviceID) -> Bool {
        logger.error(
            "setDefaultOutput(\(deviceID)) was called from the Host; only an explicit user action may change the default output"
        )

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var newDeviceID = deviceID
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &newDeviceID
        ) == noErr
    }
}
