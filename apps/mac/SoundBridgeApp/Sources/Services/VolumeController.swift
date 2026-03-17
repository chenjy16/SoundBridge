import Foundation
import CoreAudio
import Combine
import os.log

private let logger = Logger(subsystem: "com.soundbridge.app", category: "VolumeController")

/// Format an OSStatus as a FourCC string for readable CoreAudio error logging.
private func formatOSStatus(_ status: OSStatus) -> String {
    if status == noErr { return "noErr" }
    let chars: [Character] = [
        Character(UnicodeScalar(UInt8((status >> 24) & 0xFF))),
        Character(UnicodeScalar(UInt8((status >> 16) & 0xFF))),
        Character(UnicodeScalar(UInt8((status >> 8) & 0xFF))),
        Character(UnicodeScalar(UInt8(status & 0xFF)))
    ]
    let fourCC = String(chars)
    // If all printable ASCII, return as FourCC; otherwise return numeric
    if fourCC.allSatisfy({ $0.isASCII && !$0.isNewline }) {
        return "'\(fourCC)' (\(status))"
    }
    return "\(status)"
}

/// Represents an audio output device visible to the system.
struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let isFixedVolume: Bool

    static func == (lhs: OutputDevice, rhs: OutputDevice) -> Bool {
        lhs.uid == rhs.uid
    }
}

/// Bridges the menu bar UI with the Proxy Device's volume/mute properties
/// via CoreAudio HAL API. Zero file I/O for volume control.
class VolumeController: ObservableObject {
    static let shared = VolumeController()

    // MARK: - Published State

    @Published var activeDeviceName: String = ""
    @Published var activeDeviceUID: String = ""
    @Published var isFixedVolumeDevice: Bool = false
    @Published var currentVolume: Float = 0.35
    @Published var isMuted: Bool = false
    @Published var allDevices: [OutputDevice] = []

    // MARK: - Private

    private var proxyDeviceID: AudioObjectID = kAudioObjectUnknown

    // Block references for proper listener removal (P0 fix: prevents listener leak)
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    private var hardwareListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?

    // Addresses stored as instance vars so start/stop use the same pointer
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var hardwareDevicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {
        refreshDeviceList()
        findAndBindProxyDevice()
        startHardwareListener()
    }

    // MARK: - Device Discovery

    /// Enumerate all output devices (excluding SoundBridge proxies from the user-facing list,
    /// but including them internally for binding).
    func refreshDeviceList() {
        let deviceIDs = getAllOutputDeviceIDs()
        var devices: [OutputDevice] = []

        for deviceID in deviceIDs {
            guard let name = getDeviceName(deviceID),
                  let uid = getDeviceUID(deviceID) else { continue }

            // Skip SoundBridge proxy devices in the user-facing device list
            if name.contains("SoundBridge") { continue }

            let isFixed = !deviceHasVolumeControl(deviceID)
            devices.append(OutputDevice(id: deviceID, name: name, uid: uid, isFixedVolume: isFixed))
        }

        DispatchQueue.main.async { [weak self] in
            self?.allDevices = devices
        }
    }

    /// Find the active SoundBridge proxy device and bind volume listeners.
    func findAndBindProxyDevice() {
        stopListening()

        guard let defaultDeviceID = getDefaultOutputDevice() else { return }
        guard let name = getDeviceName(defaultDeviceID),
              let uid = getDeviceUID(defaultDeviceID) else { return }

        if name.contains("SoundBridge") {
            // Current default is a proxy device
            proxyDeviceID = defaultDeviceID

            // Extract physical device info from proxy UID
            let physicalUID = uid.components(separatedBy: "-soundbridge").first ?? uid
            let physicalName = name.replacingOccurrences(of: " via SoundBridge", with: "")

            DispatchQueue.main.async { [weak self] in
                self?.activeDeviceName = physicalName
                self?.activeDeviceUID = physicalUID
                self?.isFixedVolumeDevice = true
            }

            readCurrentVolume()
            readCurrentMute()
            startListening()
        } else {
            // Current default is a physical device (no proxy)
            proxyDeviceID = kAudioObjectUnknown
            let isFixed = !deviceHasVolumeControl(defaultDeviceID)

            DispatchQueue.main.async { [weak self] in
                self?.activeDeviceName = name
                self?.activeDeviceUID = uid
                self?.isFixedVolumeDevice = isFixed
            }
        }
    }

    // MARK: - Volume Control (Task 10.2)

    /// Set volume on the proxy device via CoreAudio API.
    /// UI → Driver → Shared Memory → Host (zero file I/O).
    func setVolume(_ value: Float) {
        guard proxyDeviceID != kAudioObjectUnknown else { return }
        let clamped = max(0.0, min(1.0, value))

        var volume = clamped
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            proxyDeviceID, &address, 0, nil,
            UInt32(MemoryLayout<Float>.size), &volume
        )

        if status == noErr {
            DispatchQueue.main.async { [weak self] in
                self?.currentVolume = clamped
            }
        } else {
            logger.error("setVolume failed: \(formatOSStatus(status))")
        }
    }

    /// Toggle mute on the proxy device.
    func setMute(_ muted: Bool) {
        guard proxyDeviceID != kAudioObjectUnknown else { return }

        var value: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            proxyDeviceID, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        )

        if status == noErr {
            DispatchQueue.main.async { [weak self] in
                self?.isMuted = muted
            }
        } else {
            logger.error("setMute failed: \(formatOSStatus(status))")
        }
    }

    // MARK: - Volume Listening (Task 10.3)

    /// Register AudioObjectPropertyListenerBlock for volume and mute changes
    /// on the proxy device. Keyboard volume key changes update the slider within 100ms.
    private func startListening() {
        guard proxyDeviceID != kAudioObjectUnknown else { return }

        // Volume listener
        let volBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.readCurrentVolume()
        }
        volumeListenerBlock = volBlock

        let volumeStatus = AudioObjectAddPropertyListenerBlock(
            proxyDeviceID, &volumeAddress, DispatchQueue.main, volBlock
        )
        if volumeStatus != noErr {
            logger.error("Failed to add volume listener: \(formatOSStatus(volumeStatus))")
            volumeListenerBlock = nil
        }

        // Mute listener
        let mtBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.readCurrentMute()
        }
        muteListenerBlock = mtBlock

        let muteStatus = AudioObjectAddPropertyListenerBlock(
            proxyDeviceID, &muteAddress, DispatchQueue.main, mtBlock
        )
        if muteStatus != noErr {
            logger.error("Failed to add mute listener: \(formatOSStatus(muteStatus))")
            muteListenerBlock = nil
        }
    }

    private func stopListening() {
        if let block = volumeListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                proxyDeviceID, &volumeAddress, DispatchQueue.main, block
            )
            if status != noErr {
                logger.warning("Failed to remove volume listener: \(formatOSStatus(status))")
            }
            volumeListenerBlock = nil
        }
        if let block = muteListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                proxyDeviceID, &muteAddress, DispatchQueue.main, block
            )
            if status != noErr {
                logger.warning("Failed to remove mute listener: \(formatOSStatus(status))")
            }
            muteListenerBlock = nil
        }
    }

    // MARK: - Hardware Device List Listener (P0 fix: hot-plug + startup race)

    /// Listen for system-wide device list changes (HDMI plug/unplug, Host creating proxy).
    /// Solves both the startup race condition and hot-plug detection.
    private func startHardwareListener() {
        let hwBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.refreshDeviceList()
            self.findAndBindProxyDevice()
        }
        hardwareListenerBlock = hwBlock

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &hardwareDevicesAddress,
            DispatchQueue.main,
            hwBlock
        )
        if status != noErr {
            logger.error("Failed to add hardware devices listener: \(formatOSStatus(status))")
            hardwareListenerBlock = nil
        }

        // 监听默认输出设备变化（用户在系统偏好设置切换设备）
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.findAndBindProxyDevice()
        }
        defaultOutputListenerBlock = defaultBlock

        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            defaultBlock
        )
        if defaultStatus != noErr {
            logger.error("Failed to add default output listener: \(formatOSStatus(defaultStatus))")
            defaultOutputListenerBlock = nil
        }
    }

    private func stopHardwareListener() {
        if let block = hardwareListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &hardwareDevicesAddress,
                DispatchQueue.main,
                block
            )
            if status != noErr {
                logger.warning("Failed to remove hardware devices listener: \(formatOSStatus(status))")
            }
            hardwareListenerBlock = nil
        }
        if let block = defaultOutputListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                DispatchQueue.main,
                block
            )
            if status != noErr {
                logger.warning("Failed to remove default output listener: \(formatOSStatus(status))")
            }
            defaultOutputListenerBlock = nil
        }
    }

    /// Full cleanup — call from applicationWillTerminate.
    func cleanup() {
        stopListening()
        stopHardwareListener()
    }

    /// Read current volume from the proxy device.
    private func readCurrentVolume() {
        guard proxyDeviceID != kAudioObjectUnknown else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var volume: Float = 0
        var dataSize = UInt32(MemoryLayout<Float>.size)

        let status = AudioObjectGetPropertyData(
            proxyDeviceID, &address, 0, nil, &dataSize, &volume
        )

        if status == noErr {
            DispatchQueue.main.async { [weak self] in
                self?.currentVolume = volume
            }
        } else {
            logger.error("readCurrentVolume failed: \(formatOSStatus(status))")
        }
    }

    /// Read current mute state from the proxy device.
    private func readCurrentMute() {
        guard proxyDeviceID != kAudioObjectUnknown else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            proxyDeviceID, &address, 0, nil, &dataSize, &muted
        )

        if status == noErr {
            DispatchQueue.main.async { [weak self] in
                self?.isMuted = muted != 0
            }
        } else {
            logger.error("readCurrentMute failed: \(formatOSStatus(status))")
        }
    }

    // MARK: - Device Switching (Task 10.5)

    /// Switch the system default output device via CoreAudio API.
    func switchDevice(to device: OutputDevice) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = device.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )

        if status != noErr {
            logger.error("switchDevice failed: \(formatOSStatus(status))")
        }
        // 切换默认输出设备会触发 kAudioHardwarePropertyDefaultOutputDevice 监听器，
        // 该监听器会自动调用 findAndBindProxyDevice() 更新 UI 状态。
    }

    // MARK: - CoreAudio Helpers

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceID
        ) == noErr else { return nil }

        return deviceID
    }

    private func getAllOutputDeviceIDs() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        // Filter to output devices only
        return deviceIDs.filter { deviceHasOutputStreams($0) }
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
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
            if status != noErr {
                logger.error("getDeviceName(\(deviceID)) failed: \(formatOSStatus(status))")
            }
            return nil
        }
        return cfName as String
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
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
            if status != noErr {
                logger.error("getDeviceUID(\(deviceID)) failed: \(formatOSStatus(status))")
            }
            return nil
        }
        return cfUID as String
    }

    private func deviceHasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    private func deviceHasVolumeControl(_ deviceID: AudioDeviceID) -> Bool {
        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &address) {
                return true
            }
        }
        return false
    }
}
