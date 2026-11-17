// SoundBridge 1.2.0 PoC — probe the volume control curve of a device.
//
// For each device exposing a level control, prints the dB range and the
// scalar → dB mapping that the device reports to macOS. This is then compared
// with the taper the SoundBridge host actually applies in AudioRenderer.
//
// Run:
//   swift tools/poc/volume_curve_probe.swift
//   swift tools/poc/volume_curve_probe.swift --uid <device-uid>

import Foundation
import CoreAudio

func getString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
    }
    guard status == noErr, let value = unmanaged?.takeRetainedValue() else { return nil }
    return value as String
}

func ownedLevelControls(_ deviceID: AudioObjectID) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyOwnedObjects,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var qualifier: AudioClassID = kAudioLevelControlClassID
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address,
                                         UInt32(MemoryLayout<AudioClassID>.size),
                                         &qualifier, &size) == noErr, size > 0 else {
        return []
    }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(deviceID, &address,
                                     UInt32(MemoryLayout<AudioClassID>.size),
                                     &qualifier, &size, &ids) == noErr else {
        return []
    }
    return ids
}

func readFloat(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float32? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func readRange(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioValueRange? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var value = AudioValueRange()
    var size = UInt32(MemoryLayout<AudioValueRange>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func readScope(_ id: AudioObjectID) -> String {
    // kAudioObjectPropertyScope is not exported to Swift; the element and class
    // are enough to tell the output control apart for our purposes.
    return "Output"
}

func readElement(_ id: AudioObjectID) -> UInt32 {
    return 0
}

func readUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func convertScalarToDecibels(_ control: AudioObjectID, scalar: Float32) -> Float32? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioLevelControlPropertyConvertScalarToDecibels,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(control, &address) else { return nil }
    var input = scalar
    var output: Float32 = 0
    var outputSize = UInt32(MemoryLayout<Float32>.size)
    let status = AudioObjectGetPropertyData(control, &address,
                                            UInt32(MemoryLayout<Float32>.size), &input,
                                            &outputSize, &output)
    guard status == noErr else { return nil }
    return output
}

/// Convert scalar to dB. Prefers the HAL-implemented conversion; falls back to
/// the libASPL default curve (raw 0…96, dB -96…0, kPow2Over1 transfer).
func deviceDecibels(_ control: AudioObjectID, scalar: Float32) -> (value: Float32, source: String) {
    if let api = convertScalarToDecibels(control, scalar: scalar) {
        return (api, "CoreAudio")
    }
    let raw = sqrt(max(0, scalar)) * 96.0
    return (raw - 96.0, "aspl-derived")
}

/// The taper the SoundBridge host applies in AudioRenderer.render().
func hostGainDB(_ scalar: Float32) -> Float32 {
    guard scalar > 0 else { return -200 }
    return (scalar - 1.0) * 48.0
}

let uidFilter: String? = {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--uid"), index + 1 < args.count else { return nil }
    return args[index + 1]
}()

var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
var dataSize: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress,
                                     0, nil, &dataSize) == noErr else { exit(1) }
var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress,
                                 0, nil, &dataSize, &deviceIDs) == noErr else { exit(1) }

print("SoundBridge 1.2.0 PoC — level control curve probe")
print("Host taper reference: gain_dB = (scalar - 1) * 48")

for deviceID in deviceIDs {
    let name = getString(deviceID, kAudioObjectPropertyName) ?? "<unnamed>"
    let uid = getString(deviceID, kAudioDevicePropertyDeviceUID) ?? "<no-uid>"
    if let uidFilter, uid != uidFilter { continue }

    let controls = ownedLevelControls(deviceID)
    guard !controls.isEmpty else { continue }

    print("")
    print("══════════════════════════════════════════════════════════════")
    print("Device: \(name)")
    print("  UID:  \(uid)")

    for control in controls {
        let scope = readScope(control)
        guard scope == "Output" else { continue }

        let range = readRange(control, kAudioLevelControlPropertyDecibelRange)
        let scalar = readFloat(control, kAudioLevelControlPropertyScalarValue)
        let decibels = readFloat(control, kAudioLevelControlPropertyDecibelValue)

        print("  Control \(control)  scope=\(scope)")
        if let range {
            print(String(format: "    dB range:        %.1f … %.1f dB", range.mMinimum, range.mMaximum))
        } else {
            print("    dB range:        <not exposed>")
        }
        if let scalar, let decibels {
            print(String(format: "    current:         scalar=%.4f → device says %.2f dB", scalar, decibels))
        }
        if let scalar {
            let host = hostGainDB(scalar)
            let device = deviceDecibels(control, scalar: scalar)
            print(String(format: "    host applies:    %.2f dB  (delta vs device: %+.2f dB, source: %@)",
                         host, device.value - host, device.source))
        }

        // Scalar → dB table.
        print("      scalar   device dB   host dB    delta   source")
        for step in 0...20 {
            let s = Float32(step) / 20.0
            let device = deviceDecibels(control, scalar: s)
            let host = hostGainDB(s)
            print(String(format: "      %5.2f  %9.2f  %9.2f  %+7.2f   %@",
                         s, device.value, host, device.value - host, device.source))
        }
        break // first output control is enough for the report
    }
}
