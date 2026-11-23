// SoundBridge — set (or read) the macOS default output device by UID.
//
// This is the operator's routing action for the hardware validation run. It is
// deliberately separate from sb-hw-validate, which must never change routing:
// the observer staying read-only is what makes its evidence trustworthy.
//
//   swiftc -O -swift-version 5 -o build/hwvalidate/sb-set-default-output \
//       tools/hardware-validation/sb-set-default-output.swift
//
//   build/hwvalidate/sb-set-default-output --verify
//   build/hwvalidate/sb-set-default-output --uid <UID>
//
// It writes exactly one property: kAudioHardwarePropertyDefaultOutputDevice on
// the system object. It does not touch per-device volume, mute, stream format,
// aggregate membership, or the alert-sound device.

import Foundation
import CoreAudio

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

func allDeviceIDs() -> [AudioDeviceID] {
    var a = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func uid(of device: AudioDeviceID) -> String? {
    var a = address(kAudioDevicePropertyDeviceUID)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>? = nil
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, $0)
    }
    guard status == noErr, let unmanaged = value else { return nil }
    return unmanaged.takeRetainedValue() as String
}

func name(of device: AudioDeviceID) -> String? {
    var a = address(kAudioObjectPropertyName)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>? = nil
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(device, &a, 0, nil, &size, $0)
    }
    guard status == noErr, let unmanaged = value else { return nil }
    return unmanaged.takeRetainedValue() as String
}

/// An output device is one that has at least one output stream.
func outputChannelCount(of device: AudioDeviceID) -> Int {
    var a = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, buffer) == noErr else { return 0 }
    let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func defaultOutputDevice() -> AudioDeviceID? {
    var a = address(kAudioHardwarePropertyDefaultOutputDevice)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var device = AudioDeviceID(0)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr,
          device != kAudioObjectUnknown else { return nil }
    return device
}

func describe(_ device: AudioDeviceID?) -> String {
    guard let device else { return "<none>" }
    let u = uid(of: device) ?? "<no-uid>"
    let n = name(of: device) ?? "<no-name>"
    return "\(n) [\(u)] deviceID=\(device) outChannels=\(outputChannelCount(of: device))"
}

// MARK: - main

let argv = Array(CommandLine.arguments.dropFirst())
var wantedUID: String? = nil
var verifyOnly = false
var index = 0
while index < argv.count {
    switch argv[index] {
    case "--verify":
        verifyOnly = true
        index += 1
    case "--uid":
        guard index + 1 < argv.count else { fail("--uid needs a value") }
        wantedUID = argv[index + 1]
        index += 2
    case "--help", "-h":
        print("usage: sb-set-default-output --uid <UID> | --verify")
        exit(0)
    default:
        fail("unknown argument: \(argv[index])")
    }
}

print("before: \(describe(defaultOutputDevice()))")

if verifyOnly || wantedUID == nil {
    if !verifyOnly {
        FileHandle.standardError.write(Data("nothing to do: pass --uid <UID>\n".utf8))
        exit(2)
    }
    exit(0)
}

guard let target = allDeviceIDs().first(where: { uid(of: $0) == wantedUID }) else {
    fail("no audio device currently has UID \(wantedUID!); refusing to guess", code: 3)
}
guard outputChannelCount(of: target) > 0 else {
    fail("device \(wantedUID!) has no output streams", code: 4)
}
if let current = defaultOutputDevice(), uid(of: current) == wantedUID {
    print("already the default output; nothing written")
    print("after:  \(describe(defaultOutputDevice()))")
    exit(0)
}

var a = address(kAudioHardwarePropertyDefaultOutputDevice)
var device = target
let status = AudioObjectSetPropertyData(
    AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
    UInt32(MemoryLayout<AudioDeviceID>.size), &device)
guard status == noErr else {
    fail("AudioObjectSetPropertyData(default output) failed with OSStatus \(status)", code: 5)
}

// Read it back rather than trusting the write: the property can be reverted by
// another client immediately after this process exits.
usleep(300_000)
let after = defaultOutputDevice()
print("after:  \(describe(after))")
guard let afterUID = after.flatMap(uid) else {
    fail("default output became unreadable after the write", code: 6)
}
guard afterUID == wantedUID else {
    fail("default output is \(afterUID), not \(wantedUID!); the change did not stick", code: 7)
}
print("ok: default output is now \(wantedUID!)")
