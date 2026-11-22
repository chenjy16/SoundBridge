import CoreAudio

/// The HAL surface the Host uses for a device's own volume and mute.
///
/// Same reason `DefaultOutputHAL` exists: `ProxyDeviceManager` used to make
/// these four calls inline, so nothing could observe what a volume
/// notification actually did without a live device. Moving them behind a
/// protocol lets `ProxyVolumeCommitTests` drive the production commit path
/// against a recording device.
///
/// Semantics are the 1.2.0 semantics, unchanged:
///   - reads try the main element first and fall back to channel 1,
///   - writes try the main element, then channels 1 and 2,
///   - "no such property" is `nil`/`false`, never a throw.
protocol DeviceVolumeHAL: AnyObject {
    /// The device's output volume scalar, or `nil` when CoreAudio will not answer.
    func volume(_ deviceID: AudioDeviceID) -> Float32?
    /// The device's output mute flag, or `nil` when CoreAudio will not answer.
    func muted(_ deviceID: AudioDeviceID) -> Bool?
    /// Apply `volume` to the device. `true` when at least one element accepted it.
    func setVolume(_ deviceID: AudioDeviceID, volume: Float32) -> Bool
    /// Apply `muted` to the device. `true` when the main element accepted it.
    func setMuted(_ deviceID: AudioDeviceID, muted: Bool) -> Bool
}

/// The real CoreAudio implementation.
final class CoreAudioDeviceVolumeHAL: DeviceVolumeHAL {

    func volume(_ deviceID: AudioDeviceID) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Try getting master volume
        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0
            var dataSize = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &volume
            )
            if status == noErr {
                return volume
            }
        }

        // Try getting channel 1 volume (left channel)
        address.mElement = 1
        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0
            var dataSize = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &volume
            )
            if status == noErr {
                return volume
            }
        }

        return nil
    }

    func muted(_ deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &muted) == noErr else {
            return nil
        }
        return muted != 0
    }

    func setVolume(_ deviceID: AudioDeviceID, volume: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Try setting master volume
        if AudioObjectHasProperty(deviceID, &address) {
            var vol = volume
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &vol
            )
            if status == noErr {
                return true
            }
        }

        // Try setting per-channel volume (channel 1 and 2) if master failed
        var channelSet = false
        for channel: UInt32 in 1...2 {
            address.mElement = channel
            if AudioObjectHasProperty(deviceID, &address) {
                var vol = volume
                let status = AudioObjectSetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float32>.size),
                    &vol
                )
                if status == noErr {
                    channelSet = true
                }
            }
        }

        return channelSet
    }

    func setMuted(_ deviceID: AudioDeviceID, muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }
}
