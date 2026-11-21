import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.soundbridge.app", category: "DefaultOutputSwitch")

/// What happened to an explicit request to change the system output.
///
/// The App needs this to be a value and not just a log line: P2 Batch 2 forbids
/// silent retries, so a failed switch has to reach the person who asked for it.
enum DefaultOutputSwitchResult: Equatable {
    case switched(deviceID: AudioDeviceID, throughProxy: Bool)
    case failed(deviceID: AudioDeviceID, status: OSStatus, message: String)

    var didSwitch: Bool {
        if case .switched = self { return true }
        return false
    }

    /// A sentence for the UI, or `nil` when the switch succeeded.
    var failureMessage: String? {
        if case .failed(_, _, let message) = self { return message }
        return nil
    }
}

/// The HAL write, behind a protocol so a test can count calls instead of moving
/// the developer's audio.
protocol DefaultOutputWriting {
    func writeDefaultOutput(_ deviceID: AudioDeviceID) -> OSStatus
}

struct CoreAudioDefaultOutputWriter: DefaultOutputWriting {
    func writeDefaultOutput(_ deviceID: AudioDeviceID) -> OSStatus {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var device = deviceID
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &device
        )
    }
}

/// The single place in SoundBridge that changes the macOS default output device.
///
/// Reached from the device list in the menu bar and from nowhere else — not from
/// launch, not from the host monitor, not from a device notification. Exactly one
/// write is attempted per call: a retry here is how an explicit action quietly
/// turns into an automatic one, which is the behaviour P2 Batch 2 removed.
///
/// Switching *to* the SoundBridge device prefers the driver's proxy for the
/// chosen physical output, so audio keeps flowing through the DSP pipeline. When
/// no proxy exists (the Host is not running) the physical device is the
/// fallback — the user asked to hear that device, and it is the only sound path
/// there is.
struct DefaultOutputSwitch {
    private let writer: DefaultOutputWriting

    init(writer: DefaultOutputWriting = CoreAudioDefaultOutputWriter()) {
        self.writer = writer
    }

    func switchToDevice(
        _ device: OutputDevice,
        proxyDeviceID: AudioDeviceID?
    ) -> DefaultOutputSwitchResult {
        let target = proxyDeviceID ?? device.id
        let status = writer.writeDefaultOutput(target)

        guard status == noErr else {
            logger.error(
                "Explicit switch to \(device.name) (ID: \(target)) failed: \(formatOSStatus(status))"
            )
            return .failed(
                deviceID: target,
                status: status,
                message: "Could not switch the system output to \(device.name) (\(formatOSStatus(status)))."
            )
        }

        if let proxyDeviceID {
            logger.info("Switched the system output to the SoundBridge proxy \(proxyDeviceID) for \(device.name)")
        } else {
            logger.info("Switched the system output to \(device.name) (ID: \(target))")
        }
        return .switched(deviceID: target, throughProxy: proxyDeviceID != nil)
    }
}
