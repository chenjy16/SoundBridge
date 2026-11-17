// SoundBridge 1.2.0 Phase 2.0 — read-only HARDWARE-mode feasibility probe.
//
// Question: can the host drive a physical device's volume by writing
// kAudioLevelControlPropertyDecibelValue directly, instead of translating
// scalar values across two different curves?
//
// This probe never writes audio properties. It only queries
// HasProperty / IsPropertySettable / DecibelRange, so it is safe to run
// while audio is playing.
//
// Build: swiftc -O tools/poc/decibel_write_probe.swift -o /tmp/decibel_write_probe

import CoreAudio
import Foundation

func addr(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = addr(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(object, &a, 0, nil, &size, ptr)
    }
    guard status == noErr, let cf = value?.takeUnretainedValue() else { return nil }
    return cf as String
}

func hasProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var a = addr(selector)
    return AudioObjectHasProperty(object, &a)
}

func isSettable(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
    var a = addr(selector)
    guard AudioObjectHasProperty(object, &a) else { return false }
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(object, &a, &settable) == noErr else { return false }
    return settable.boolValue
}

func readFloat(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float32? {
    var a = addr(selector)
    guard AudioObjectHasProperty(object, &a) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func readRange(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioValueRange? {
    var a = addr(selector)
    guard AudioObjectHasProperty(object, &a) else { return nil }
    var value = AudioValueRange()
    var size = UInt32(MemoryLayout<AudioValueRange>.size)
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func ownedLevelControls(_ deviceID: AudioObjectID) -> [AudioObjectID] {
    var a = addr(kAudioObjectPropertyOwnedObjects)
    var qualifier: AudioClassID = kAudioLevelControlClassID
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &a, UInt32(MemoryLayout<AudioClassID>.size),
                                         &qualifier, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(deviceID, &a, UInt32(MemoryLayout<AudioClassID>.size),
                                     &qualifier, &size, &ids) == noErr else { return [] }
    return ids
}

func readScope(_ control: AudioObjectID) -> UInt32? {
    // kAudioLevelControlPropertyScope is not exported to Swift by name.
    let selector: AudioObjectPropertySelector = 0x73636F70 // 'scop'
    var a = addr(selector)
    guard AudioObjectHasProperty(control, &a) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(control, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func readElement(_ control: AudioObjectID) -> UInt32? {
    let selector: AudioObjectPropertySelector = 0x656C656D // 'elem'
    var a = addr(selector)
    guard AudioObjectHasProperty(control, &a) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(control, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

var devicesAddress = addr(kAudioHardwarePropertyDevices)
var dataSize: UInt32 = 0
guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress,
                                     0, nil, &dataSize) == noErr else { exit(1) }
var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress,
                                 0, nil, &dataSize, &deviceIDs) == noErr else { exit(1) }

print("SoundBridge 1.2.0 Phase 2.0 — dB-write feasibility probe (READ ONLY)")
print("")
print("")

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

var printedAny = false

for deviceID in deviceIDs {
    let name = getString(deviceID, kAudioObjectPropertyName) ?? "<unnamed>"
    let controls = ownedLevelControls(deviceID)
    guard !controls.isEmpty else { continue }

    print("[(deviceID)] \(name) — \(controls.count) level control(s)")
    printedAny = true

    for control in controls {
        let scopeRaw = readScope(control)
        let scopeText: String
        if let s = scopeRaw {
            if s == kAudioObjectPropertyScopeOutput { scopeText = "outp" }
            else if s == kAudioObjectPropertyScopeInput { scopeText = "inpt" }
            else if s == kAudioObjectPropertyScopeGlobal { scopeText = "glob" }
            else { scopeText = String(format: "0x%08X", s) }
        } else {
            scopeText = "?"
        }

        let element = readElement(control).map { String(format: "0x%02X", $0) } ?? "??"
        let range = readRange(control, kAudioLevelControlPropertyDecibelRange)
        let rangeText = range.map { String(format: "%.1f…%.1f dB", $0.mMinimum, $0.mMaximum) } ?? "<no db range>"
        let dbValue = readFloat(control, kAudioLevelControlPropertyDecibelValue)
        let dbText = dbValue.map { String(format: "%.2f dB", $0) } ?? "<none>"
        let scalar = readFloat(control, kAudioLevelControlPropertyScalarValue)
        let scalarText = scalar.map { String(format: "%.4f", $0) } ?? "<none>"
        let dbSettable = isSettable(control, kAudioLevelControlPropertyDecibelValue)
        let scaleSettable = isSettable(control, kAudioLevelControlPropertyScalarValue)

        print("    ctl=\(control) scope=\(scopeText) elem=\(element)")
        print("      dB range   : \(rangeText)")
        print("      dB value   : \(dbText)   settable=\(dbSettable)")
        print("      scalar     : \(scalarText)   settable=\(scaleSettable)")
    }
    print("")
}

if !printedAny { print("(no level controls found)") }

print("")
print("Legend:")
print("  dB-value settable = kAudioLevelControlPropertyDecibelValue can be written.")
print("  When yes, HARDWARE mode can write dB directly and skip curve translation.")
