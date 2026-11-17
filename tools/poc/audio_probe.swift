// SoundBridge 1.2.0 PoC — CoreAudio output-device volume capability probe.
//
// Read-only by default. Pass --write-test to additionally verify that the
// writable volume properties actually accept a value; the original value is
// always restored afterwards.
//
// Build/run:
//   swift tools/poc/audio_probe.swift
//   swift tools/poc/audio_probe.swift --write-test
//
// This tool never decides whether audio is *audible*; it only reports what the
// CoreAudio API exposes and accepts.

import Foundation
import CoreAudio

// MARK: - Property helpers

func hasProperty(_ id: AudioObjectID,
                 _ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope,
                 _ element: UInt32) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    return AudioObjectHasProperty(id, &address)
}

func isSettable(_ id: AudioObjectID,
                _ selector: AudioObjectPropertySelector,
                _ scope: AudioObjectPropertyScope,
                _ element: UInt32) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    guard AudioObjectHasProperty(id, &address) else { return false }
    var settable = DarwinBoolean(false)
    guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr else { return false }
    return settable.boolValue
}

func getUInt32(_ id: AudioObjectID,
               _ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
               _ element: UInt32 = kAudioObjectPropertyElementMain) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func getFloat32(_ id: AudioObjectID,
                _ selector: AudioObjectPropertySelector,
                _ scope: AudioObjectPropertyScope,
                _ element: UInt32) -> Float32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func setFloat32(_ id: AudioObjectID,
                _ selector: AudioObjectPropertySelector,
                _ scope: AudioObjectPropertyScope,
                _ element: UInt32,
                _ value: Float32) -> OSStatus {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    var mutable = value
    return AudioObjectSetPropertyData(id, &address, 0, nil,
                                      UInt32(MemoryLayout<Float32>.size), &mutable)
}

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

func outputChannelCount(_ id: AudioObjectID) -> Int {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
        return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
}

func transportName(_ type: UInt32) -> String {
    switch type {
    case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
    case kAudioDeviceTransportTypeAggregate: return "Aggregate"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    case kAudioDeviceTransportTypePCI: return "PCI"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeFireWire: return "FireWire"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "BluetoothLE"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    case kAudioDeviceTransportTypeAVB: return "AVB"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    default: return "Other(\(type))"
    }
}

// MARK: - Probe

let writeTest = CommandLine.arguments.contains("--write-test")

func probeDevice(_ deviceID: AudioObjectID, defaultOutput: AudioObjectID) {
    let name = getString(deviceID, kAudioObjectPropertyName) ?? "<unnamed>"
    let uid = getString(deviceID, kAudioDevicePropertyDeviceUID) ?? "<no-uid>"
    let manufacturer = getString(deviceID, kAudioObjectPropertyManufacturer) ?? "?"
    let transport = transportName(getUInt32(deviceID, kAudioDevicePropertyTransportType) ?? 0)
    let channels = outputChannelCount(deviceID)
    let sampleRate = getFloat32(deviceID, kAudioDevicePropertyNominalSampleRate,
                                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain)
    let isDefault = deviceID == defaultOutput

    print("")
    print("──────────────────────────────────────────────────────────────")
    print("Device:       \(name)\(isDefault ? "   [DEFAULT OUTPUT]" : "")")
    print("  UID:        \(uid)")
    print("  Transport:  \(transport)   Manufacturer: \(manufacturer)")
    print("  Channels:   \(channels)   SampleRate: \(sampleRate.map { String(format: "%.0f", $0) } ?? "?") Hz")
    print("  DeviceID:   \(deviceID)")

    // Volume / mute capability, master element first, then per-channel.
    var elements: [UInt32] = [kAudioObjectPropertyElementMain]
    if channels > 0 { elements.append(contentsOf: (1...channels).map { UInt32($0) }) }

    var anyReadable = false
    var anyWritable = false

    for element in elements {
        let elementName = element == kAudioObjectPropertyElementMain ? "master" : "ch\(element)"
        let readable = hasProperty(deviceID, kAudioDevicePropertyVolumeScalar,
                                   kAudioDevicePropertyScopeOutput, element)
        let writable = isSettable(deviceID, kAudioDevicePropertyVolumeScalar,
                                  kAudioDevicePropertyScopeOutput, element)
        if readable { anyReadable = true }
        if writable { anyWritable = true }

        guard readable else { continue }

        let value = getFloat32(deviceID, kAudioDevicePropertyVolumeScalar,
                               kAudioDevicePropertyScopeOutput, element)
        var line = String(format: "    volume[%@]: readable=Y writable=%@ value=%@",
                          elementName,
                          writable ? "Y" : "N",
                          value.map { String(format: "%.4f", $0) } ?? "?")

        if writeTest && writable, let original = value {
            // Write a probe value, read it back, then restore the original.
            let probeValue: Float32 = original > 0.5 ? 0.25 : 0.75
            let setStatus = setFloat32(deviceID, kAudioDevicePropertyVolumeScalar,
                                       kAudioDevicePropertyScopeOutput, element, probeValue)
            let readBack = getFloat32(deviceID, kAudioDevicePropertyVolumeScalar,
                                      kAudioDevicePropertyScopeOutput, element)
            _ = setFloat32(deviceID, kAudioDevicePropertyVolumeScalar,
                           kAudioDevicePropertyScopeOutput, element, original)
            let restored = getFloat32(deviceID, kAudioDevicePropertyVolumeScalar,
                                      kAudioDevicePropertyScopeOutput, element)

            line += String(format: " | write(%.2f)->status=%d readback=%@ restored=%@",
                           probeValue,
                           Int(setStatus),
                           readBack.map { String(format: "%.4f", $0) } ?? "?",
                           restored.map { String(format: "%.4f", $0) } ?? "?")
        }
        print(line)
    }

    let muteReadable = hasProperty(deviceID, kAudioDevicePropertyMute,
                                   kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
    let muteWritable = isSettable(deviceID, kAudioDevicePropertyMute,
                                  kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
    var muteValue: UInt32?
    if muteReadable {
        muteValue = getUInt32(deviceID, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
    }
    print("    mute:      readable=\(muteReadable ? "Y" : "N") writable=\(muteWritable ? "Y" : "N") value=\(muteValue.map(String.init) ?? "?")")

    print("  SUMMARY: volumeReadable=\(anyReadable) volumeWritable=\(anyWritable) → \(anyWritable ? "HARDWARE-capable" : "FIXED (software-only)")")
}

// MARK: - Main

var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
var dataSize: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress,
                                     0, nil, &dataSize) == noErr else {
    print("Failed to query device list")
    exit(1)
}

let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress,
                                 0, nil, &dataSize, &deviceIDs) == noErr else {
    print("Failed to read device list")
    exit(1)
}

let defaultOutput = getUInt32(AudioObjectID(kAudioObjectSystemObject),
                              kAudioHardwarePropertyDefaultOutputDevice) ?? 0

print("SoundBridge 1.2.0 PoC — CoreAudio output device probe")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Mode: \(writeTest ? "READ + WRITE TEST (original values are restored)" : "READ ONLY")")
print("Total devices: \(deviceCount)   Default output device ID: \(defaultOutput)")

for deviceID in deviceIDs {
    // Only report devices that actually expose output streams.
    var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                    mScope: kAudioDevicePropertyScopeOutput,
                                                    mElement: kAudioObjectPropertyElementMain)
    var streamsSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr,
          streamsSize > 0 else { continue }
    probeDevice(deviceID, defaultOutput: defaultOutput)
}

print("")
print("──────────────────────────────────────────────────────────────")
print("Note: 'volumeWritable=Y' means the API accepts writes.")
print("It does NOT prove the hardware audibly changes. Confirm by ear.")
