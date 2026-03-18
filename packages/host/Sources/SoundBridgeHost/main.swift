import AudioToolbox
import CSoundBridgeAudio
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "Main")

let deviceDiscovery = DeviceDiscovery()
let deviceRegistry = DeviceRegistry()
let memoryManager = SharedMemoryManager()
let volumePersistence = VolumePersistence()
let proxyManager = ProxyDeviceManager(registry: deviceRegistry, volumePersistence: volumePersistence)
let renderer = AudioRenderer(
    memoryManager: memoryManager,
    proxyManager: proxyManager
)
let audioEngine = AudioEngine(renderer: renderer, registry: deviceRegistry)
let deviceMonitor = DeviceMonitor(
    registry: deviceRegistry,
    proxyManager: proxyManager,
    memoryManager: memoryManager,
    discovery: deviceDiscovery,
    audioEngine: audioEngine
)
let sleepWakeMonitor = SleepWakeMonitor()

func main() {

    print("[Step 0] Setting up directories...")
    do {
        try PathManager.ensureDirectories()
        print("    ✓ Application Support: \(PathManager.appSupportDir.path)")
        print("    ✓ Logs: \(PathManager.logsDir.path)")
    } catch {
        logger.error("Failed to create directories: \(error.localizedDescription)")
        exit(1)
    }

    print("[Step 1] Discovering physical audio devices...")
    let devices = deviceDiscovery.enumeratePhysicalDevices()

    guard !devices.isEmpty else {
        logger.error("No physical output devices found")
        exit(1)
    }

    let validatedDevices = devices.filter { $0.validationPassed }
    logger.info("Found \(devices.count) physical output device(s) (\(validatedDevices.count) validated)")
    for device in devices {
        let status = device.validationPassed ? "✓" : "⚠"
        var line = "    \(status) \(device.name) (\(device.uid))"
        if let note = device.validationNote {
            line += " - \(note)"
        }
        print(line)
    }

    if validatedDevices.isEmpty {
        logger.warning("No validated devices found. Will attempt setup with available devices anyway.")
    }

    // Query device sample rate for HiFi/lossless audio support
    let preferredDevice = proxyManager.resolveCurrentOutputDevice(in: devices)
        ?? validatedDevices.first
        ?? devices.first!
    let deviceSampleRate = deviceDiscovery.getDeviceNominalSampleRate(preferredDevice.id)
    SoundBridgeConfig.activeSampleRate = deviceSampleRate
    print("[Step 1.5] HiFi mode: \(deviceSampleRate) Hz (from \(preferredDevice.name))")

    deviceRegistry.update(devices)

    print("[Step 2] Registering device change listeners...")
    deviceMonitor.registerListeners()

    print("[Step 3] Creating shared memory files...")
    memoryManager.createMemory(for: devices)

    print("[Step 4] Writing control file...")
    deviceRegistry.writeControlFile()
    print("    ✓ Control file: \(SoundBridgeConfig.controlFilePath)")

    print("[Step 5] Starting heartbeat monitor...")
    memoryManager.startHeartbeat()

    print("[Step 6] Waiting for driver to create proxy devices...")
    Thread.sleep(forTimeInterval: SoundBridgeConfig.deviceWaitTimeout)

    print("[Step 7] Auto-selecting proxy device...")
    proxyManager.autoSelectProxy()

    // Bounce device to recapture audio from apps that were already running
    if proxyManager.activeProxyDeviceID != 0 {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            proxyManager.bounceDevice()
        }
    }

    print("[Step 7.5] Registering sleep/wake handler...")
    sleepWakeMonitor.onSleep = {
        print("[SleepWake] System entering sleep, stopping AudioEngine...")
        audioEngine.stop()
        logger.info("AudioEngine stopped before sleep")
    }
    sleepWakeMonitor.onWake = {
        print("[SleepWake] Recovering after wake...")
        deviceMonitor.reregisterListeners()
        deviceMonitor.resetDebounce()
        proxyManager.reregisterVolumeForwarding()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            do {
                try audioEngine.setup(devices: deviceRegistry.devices,
                                      preferredDeviceID: proxyManager.activePhysicalDeviceID)
                try audioEngine.start()
                logger.info("AudioEngine restarted after wake")
            } catch {
                logger.error("AudioEngine restart failed: \(error.localizedDescription)")
            }
        }
    }
    sleepWakeMonitor.start()

    print("[Step 8] Setting up audio engine with device fallback...")

    // Get the user's preferred device from proxy manager (set during autoSelectProxy)
    let preferredDeviceID = proxyManager.activePhysicalDeviceID
    if preferredDeviceID != 0 {
        if let preferredDevice = devices.first(where: { $0.id == preferredDeviceID }) {
            print("    Preferred device: \(preferredDevice.name)")
        } else {
            print("    Preferred device ID \(preferredDeviceID) not in device list")
        }
    }

    do {
        try audioEngine.setup(devices: devices, preferredDeviceID: preferredDeviceID != 0 ? preferredDeviceID : nil)
        try audioEngine.start()
        logger.info("Audio engine started successfully")

        // Post-start volume sync: After IO starts, the driver maps shared memory.
        // Re-apply the current proxy volume so the driver writes it into shared memory.
        // Without this, shared memory retains its init default (0.35) instead of the
        // actual volume set during restoreVolumeState (before IO was running).
        if proxyManager.activeProxyDeviceID != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let physicalUID = proxyManager.activeProxyUID {
                    proxyManager.restoreVolumeState(
                        proxyDeviceID: proxyManager.activeProxyDeviceID,
                        physicalUID: physicalUID
                    )
                    logger.info("Volume re-synced to shared memory")
                }
            }
        }
    } catch let error as AudioEngineError {
        logger.error("Audio engine setup failed: \(error.description)")
        if case .allDevicesFailed = error {
            logger.error("All \(devices.count) device(s) failed to initialize.")
            logger.error("This may indicate no functional audio output devices are available.")
        }
        exit(1)
    } catch {
        logger.error("Audio engine setup failed: \(error.localizedDescription)")
        exit(1)
    }

    setupSignalHandlers()

    logger.info("Signal handlers installed")

    RunLoop.current.run()
}

func setupSignalHandlers() {
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        print("\n[Signal] Received SIGINT (Ctrl+C)")
        cleanup()
        exit(0)
    }
    sigintSource.resume()

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        print("\n[Signal] Received SIGTERM")
        cleanup()
        exit(0)
    }
    sigtermSource.resume()

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
}

func cleanup() {
    print("\n[Cleanup] Starting cleanup process...")

    sleepWakeMonitor.stop()
    memoryManager.stopHeartbeat()

    _ = proxyManager.restorePhysicalDevice()

    audioEngine.stop()

    print("[Cleanup] Removing control file...")
    unlink(SoundBridgeConfig.controlFilePath)

    Thread.sleep(forTimeInterval: SoundBridgeConfig.cleanupWaitTimeout)

    memoryManager.cleanup()

    restartCoreAudio()

    logger.info("Cleanup complete")
}

private func restartCoreAudio() {
    // Force HAL to drop any lingering virtual devices by restarting coreaudiod
    let task = Process()
    task.launchPath = "/usr/bin/killall"
    task.arguments = ["coreaudiod"]  // 默认发送 SIGTERM

    do {
        try task.run()
        task.waitUntilExit()
        logger.info("Restarted coreaudiod (status \(task.terminationStatus))")
    } catch {
        logger.error("Failed to restart coreaudiod: \(error.localizedDescription)")
    }
}

main()
