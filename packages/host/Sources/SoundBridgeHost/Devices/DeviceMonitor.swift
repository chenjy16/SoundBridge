import Foundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "DeviceMonitor")

class DeviceMonitor {
    private let registry: DeviceRegistry
    private let proxyManager: ProxyDeviceManager
    private let memoryManager: SharedMemoryManager
    private let discovery: DeviceDiscovery
    private let audioEngine: AudioEngine
    private var lastHandledDeviceID: AudioDeviceID = 0
    private var lastHandledTime: Date = .distantPast
    private let callbackDebounce: TimeInterval = 0.3
    private var listenersRegistered = false
    private var devicesListenerRegistered = false
    private var defaultOutputListenerRegistered = false

    init(
        registry: DeviceRegistry,
        proxyManager: ProxyDeviceManager,
        memoryManager: SharedMemoryManager,
        discovery: DeviceDiscovery,
        audioEngine: AudioEngine
    ) {
        self.registry = registry
        self.proxyManager = proxyManager
        self.memoryManager = memoryManager
        self.discovery = discovery
        self.audioEngine = audioEngine
    }

    func registerListeners() {
        guard !listenersRegistered else { return }

        // SAFETY: self 是 main.swift 中的全局 let 变量，生命周期与进程一致。
        // passUnretained 安全，因为 self 不会在回调存活期间被释放。
        // 如果未来改为非全局实例，必须改用 passRetained + 配对 release。
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            deviceListChangedCallbackC,
            selfPtr
        )
        devicesListenerRegistered = (devicesStatus == noErr)
        if devicesStatus != noErr {
            logger.error("Failed to register devices listener (OSStatus: \(devicesStatus))")
        }

        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outputStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            defaultOutputChangedCallbackC,
            selfPtr
        )
        defaultOutputListenerRegistered = (outputStatus == noErr)
        if outputStatus != noErr {
            logger.error("Failed to register default output listener (OSStatus: \(outputStatus))")
        }

        listenersRegistered = devicesListenerRegistered && defaultOutputListenerRegistered
    }

    private func removeListeners() {
        guard devicesListenerRegistered || defaultOutputListenerRegistered else { return }
        listenersRegistered = false

        // SAFETY: self 是 main.swift 中的全局 let 变量，生命周期与进程一致。
        // passUnretained 安全，因为 self 不会在回调存活期间被释放。
        // 如果未来改为非全局实例，必须改用 passRetained + 配对 release。
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if devicesListenerRegistered {
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                deviceListChangedCallbackC,
                selfPtr
            )
            devicesListenerRegistered = false
        }

        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if defaultOutputListenerRegistered {
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                defaultOutputChangedCallbackC,
                selfPtr
            )
            defaultOutputListenerRegistered = false
        }
    }

    func reregisterListeners() {
        removeListeners()
        registerListeners()
        logger.info("Listeners re-registered after wake")
    }

    func resetDebounce() {
        lastHandledDeviceID = 0
        lastHandledTime = .distantPast
    }

    fileprivate func handleDeviceListChanged() {
        let oldDevices = registry.devices
        let newDevices = discovery.enumeratePhysicalDevices()

        let addedDevices = newDevices.filter { new in
            !oldDevices.contains { $0.uid == new.uid }
        }
        let removedDevices = oldDevices.filter { old in
            !newDevices.contains { $0.uid == old.uid }
        }

        // 1. Create shared memory for new devices
        for device in addedDevices {
            print("Device added: \(device.name) (\(discovery.transportTypeName(device.transportType)))")
            _ = memoryManager.createMemory(for: device.uid)
        }

        for device in removedDevices {
            print("Device removed: \(device.name) (\(discovery.transportTypeName(device.transportType)))")
        }

        // 2. Update registry (writes control file + sends Darwin notification)
        registry.update(newDevices)

        // 3. Delay shared memory removal for removed devices
        if !removedDevices.isEmpty {
            let removedUIDs = removedDevices.map { $0.uid }
            DispatchQueue.main.asyncAfter(deadline: .now() + SoundBridgeConfig.cleanupWaitTimeout) {
                [weak self] in
                guard let self else { return }
                for uid in removedUIDs {
                    self.memoryManager.removeMemory(for: uid)
                }
            }
        }

        // 4. Wait for proxy devices and auto-switch for new devices
        if !addedDevices.isEmpty {
            waitForProxyAndSwitch(addedDevices: addedDevices)
        }
        // NOTE: reloadDriver() removed — Darwin notifications replace manual reload
    }

    fileprivate func handleDefaultOutputChanged() {
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
            return
        }

        // Debounce: skip if same device within cooldown period
        let now = Date()
        if deviceID == lastHandledDeviceID && now.timeIntervalSince(lastHandledTime) < callbackDebounce {
            return
        }
        lastHandledDeviceID = deviceID
        lastHandledTime = now

        guard let name = getDeviceName(deviceID),
              let uid = getDeviceUID(deviceID) else {
            return
        }

        print("Default output changed: \(name)")

        if name.contains("SoundBridge") {
            proxyManager.handleProxySelection(uid, deviceID: deviceID)

            let targetID = proxyManager.activePhysicalDeviceID
            if targetID != 0 {
                do {
                    try audioEngine.switchDevice(targetID)
                } catch {
                    logger.error("Failed to switch audio engine device: \(error.localizedDescription)")
                }
            } else {
                logger.warning("No active physical device mapped for proxy \(uid)")
            }
        } else {
            proxyManager.handlePhysicalSelection(uid)

            if let physical = registry.find(uid: uid) {
                do {
                    try audioEngine.switchDevice(physical.id)
                } catch {
                    logger.error("Failed to switch audio engine device: \(error.localizedDescription)")
                }
            }
        }
    }

    private func waitForProxyAndSwitch(addedDevices: [PhysicalDevice]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let deadline = Date().addingTimeInterval(SoundBridgeConfig.deviceWaitTimeout)

            for device in addedDevices {
                var proxyID: AudioDeviceID? = nil

                while Date() < deadline {
                    proxyID = self.proxyManager.findProxyDevice(forPhysicalUID: device.uid)
                    if proxyID != nil { break }
                    Thread.sleep(forTimeInterval: 0.1)
                }

                if proxyID != nil {
                    DispatchQueue.main.async {
                        self.proxyManager.handlePhysicalSelection(device.uid)
                    }
                } else {
                    logger.warning("Proxy device not found for \(device.name) after \(SoundBridgeConfig.deviceWaitTimeout)s timeout")
                }
            }
        }
    }

    private func reloadDriver() {
        print("Driver reload required - restart coreaudiod with: sudo killall coreaudiod")
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
}

// File-level C callbacks — stable function pointers required for AudioObjectRemovePropertyListener.
// AudioObjectPropertyListenerProc requires non-optional UnsafePointer<AudioObjectPropertyAddress>.
private func deviceListChangedCallbackC(
    _ objectID: AudioObjectID,
    _ numAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    Unmanaged<DeviceMonitor>.fromOpaque(clientData).takeUnretainedValue()
        .handleDeviceListChanged()
    return noErr
}

private func defaultOutputChangedCallbackC(
    _ objectID: AudioObjectID,
    _ numAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    Unmanaged<DeviceMonitor>.fromOpaque(clientData).takeUnretainedValue()
        .handleDefaultOutputChanged()
    return noErr
}
