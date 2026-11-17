import AudioToolbox
import CSoundBridgeAudio
import CoreAudio
import Darwin
import Foundation
import os.log

// Darwin notify API — not always visible during x86_64 cross-compilation.
@_silgen_name("notify_register_dispatch")
private func _notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ out_token: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping @convention(block) (Int32) -> Void
) -> UInt32

@_silgen_name("notify_cancel")
private func _notify_cancel(_ token: Int32) -> UInt32

private let logger = Logger(subsystem: "com.soundbridge.host", category: "Main")

let deviceDiscovery = DeviceDiscovery()
let deviceRegistry = DeviceRegistry()
let memoryManager = SharedMemoryManager()
let volumePersistence = VolumePersistence()
let proxyManager = ProxyDeviceManager(registry: deviceRegistry, volumePersistence: volumePersistence)
let volumeStateStore = VolumeStateStore()
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

/// Process-wide single-instance lock. Acquired at the top of `main()` and held
/// until the process ends; see `HostInstanceLock` for why this is a `flock` and
/// not a `pgrep`.
let instanceLock = HostInstanceLock()

/// Publishes the lifecycle snapshot into `device-state.json`, which is how the
/// App tells "Host is up" apart from "Host is up and audio works".
let lifecycleReporter = HostLifecycleReporter { snapshot in
    deviceRegistry.lifecycle = snapshot
    deviceRegistry.writeDeviceStateFile()
}

var connectionMonitor: DriverConnectionMonitor?

/// Single-flight guard for `.degraded` → `.active`.
///
/// Device-list notifications are delivered on the main queue, but the recovery
/// they trigger immediately hops to a background queue to probe CoreAudio. Two
/// notifications inside that window both observe `.degraded` and both call
/// `audioEngine.setup()`, which allocates a new audio unit before disposing the
/// previous one. Mutated on the main queue only.
private var degradedRecoveryGate = DegradedRecoveryGate()

/// Teardown is requested by SIGINT and SIGTERM, so it has to be run-once and
/// stay ordered; see `ShutdownSequence` for why the order is the contract.
private var shutdownSequence = ShutdownSequence()

// Retain signal dispatch sources for the lifetime of the host process.
// Otherwise they are released after setupSignalHandlers() returns.
private var signalSources: [DispatchSourceSignal] = []

func main() {

    // Prevent macOS App Nap from throttling this process.
    // Without this, the system may suspend timers and background work
    // after prolonged playback, causing heartbeat timeouts and audio dropout.
    let _ = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "SoundBridge realtime audio processing"
    )

    // Step -1: single instance, before anything else.
    //
    // Everything below touches state another Host would share: the control file,
    // `/tmp/soundbridge-<uid>` and the driver's mapping of it. A second Host that
    // got past a `pgrep` check would unlink the first one's mappings and leave a
    // ghost consumer behind, so the lock is the first thing that happens and a
    // refusal exits before any of it — no unlink, no create, no cleanup.
    switch HostStartupGate(lock: instanceLock).evaluate() {
    case .proceed:
        print("[Step -1] Single instance: \(instanceLock.path)")
    case .refuseInstanceConflict(let owner):
        let who = owner ?? "another process"
        print("[Startup] Refusing to start: \(instanceLock.path) is held by \(who)")
        logger.error("Refusing to start: instance lock held by \(who, privacy: .public)")
        exit(HostExitCode.instanceConflict)
    case .refuseLockFailure(let reason):
        print("[Startup] Refusing to start: cannot acquire instance lock (\(reason))")
        logger.error("Refusing to start: lock failure \(reason, privacy: .public)")
        exit(HostExitCode.instanceLockFailure)
    }

    print("[Step 0] Setting up directories...")
    do {
        try PathManager.ensureDirectories()
        print("    ✓ Application Support: \(PathManager.appSupportDir.path)")
        print("    ✓ Logs: \(PathManager.logsDir.path)")
    } catch {
        logger.error("Failed to create directories: \(error.localizedDescription)")
        // The instance lock is already held at this point; release it explicitly
        // instead of relying on the kernel to reclaim the descriptor on exit.
        cleanup()
        exit(1)
    }

    lifecycleReporter.update { snapshot in
        snapshot.outcome = .starting
        snapshot.detail = "startup began"
    }

    setupSignalHandlers()
    logger.info("Signal handlers installed")

    setupSleepWakeMonitoring()

    print("[Step 1] Discovering physical audio devices...")
    let devices = deviceDiscovery.enumeratePhysicalDevices()

    if devices.isEmpty {
        logger.info("No physical output devices currently available; entering idle mode")
        deviceMonitor.setHostState(.idle)
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .noPhysicalDevices
            snapshot.audioPipeline = .notStarted
            snapshot.detail = "no physical output device; idle by design, not a failure"
        }
    }

    print("[Step 2] Registering device change listeners...")
    deviceMonitor.registerListeners()

    if devices.isEmpty {
        // The run loop is what keeps an idle Host alive. If it ever returns — no
        // HAL sources left to wait on — the process must still release the lock
        // and unlink the shared memory, instead of falling out of `main()` with
        // both still held.
        RunLoop.current.run()
        cleanup()
        return
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

    print("[Step 3] Creating shared memory files...")
    // createMemory() resolves the starting volume for each device in the
    // documented order (persisted > recovered-from-crash > safe default) and
    // commits it, so the driver sees state_initialized == 1 on first OnStartIO.
    memoryManager.createMemory(for: devices, persistence: volumePersistence)

    // `createMemory` logs per device; a caller cannot tell "one failure among
    // several" from "nothing was created" without looking. With no mapping there
    // is no audio path at all, so stop instead of continuing into a fake startup.
    let mappedDevices = devices.filter { memoryManager.getMemory(for: $0.uid) != nil }
    guard !mappedDevices.isEmpty else {
        print("[Step 3] FATAL: no shared memory mapping exists for any device")
        logger.error("Shared memory creation failed for all \(devices.count) device(s); refusing to start")
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .sharedMemoryInvalid
            snapshot.sharedMemoryConnection = .invalid
            snapshot.audioPipeline = .notStarted
            snapshot.detail = "createMemory() produced no mapping for any physical device"
        }
        // Nothing was routed yet, so there is no default device to restore, but
        // a partial mapping can exist and must not outlive the process.
        cleanup()
        exit(1)
    }

    print("[Step 4] Writing control file...")
    deviceRegistry.writeControlFile()
    print("    ✓ Control file: \(SoundBridgeConfig.controlFilePath)")

    print("[Step 5] Starting heartbeat monitor...")
    memoryManager.startHeartbeat()

    print("[Step 6] Waiting up to \(SoundBridgeConfig.proxyDiscoveryTimeout)s for the driver's proxy device...")

    // Phase 2.1.4: this used to be `Thread.sleep(2)`, which asserted nothing —
    // startup "succeeded" whether or not a proxy device ever appeared, and the
    // two seconds were spent even when the device was already there. Wait for the
    // actual HAL device instead, with a deadline.
    if case .timedOut(let seconds) = waitForProxyDevice(forUID: preferredDevice.uid) {
        enterDegraded(
            detail: "no proxy device for \(preferredDevice.name) after \(seconds)s; the driver is not loaded, or is not compatible with this build"
        )
        // Degraded is not a terminal state: the run loop keeps the Host alive so
        // a late driver can attach. When it does return, the teardown still has
        // to happen.
        RunLoop.current.run()
        cleanup()
        return
    }

    print("[Step 7] Auto-selecting proxy device...")
    let selection = proxyManager.autoSelectProxy()
    print("[Step 7] Proxy selection: \(selection.diagnostic)")

    guard selection.isRouted else {
        enterDegraded(detail: "proxy device exists but could not be selected (\(selection.diagnostic))")
        RunLoop.current.run()
        cleanup()
        return
    }

    // Step 7.5: adopt the committed state as the Host's runtime authority.
    //
    // createMemory() already committed a state per device, so this does not
    // write shared memory again — it records the active device's authoritative
    // scalar/gain pair for the render path and for Phase 2.2 routing.
    adoptCommittedVolumeState()

    // Bounce device to recapture audio from apps that were already running
    if proxyManager.activeProxyDeviceID != 0 {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            proxyManager.bounceDevice()
        }
    }

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

        deviceMonitor.setHostState(.active)
        logger.info("Audio engine started successfully")

        lifecycleReporter.update { snapshot in
            snapshot.outcome = .ready
            snapshot.driverFile = .present
            snapshot.driverCompatibility = .compatible
            snapshot.driverLoad = .loaded
            snapshot.halDiscovery = .discovered
            snapshot.proxyDevice = .found
            snapshot.sharedMemoryConnection = .waitingForDriver
            snapshot.audioPipeline = .notStarted
            snapshot.detail = "engine running; the driver attaches on its first IO, so waitingForDriver is expected until an app plays through the SoundBridge device"
        }
        startConnectionMonitor()

        // Post-start re-apply. The driver pushed the committed shared-memory
        // volume into its VolumeControl during OnStartIO (see
        // SyncVolumeStateWithSharedMemory), so this is a belt-and-braces
        // re-apply after the initial device bounce, not the initialisation
        // path. The override keeps a recovered shared-memory value from being
        // replaced by the persistence default.
        if proxyManager.activeProxyDeviceID != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let physicalUID = proxyManager.activeProxyUID {
                    let committed = memoryManager.readVolumeState(for: physicalUID).map {
                        DeviceVolumeState(volumeScalar: $0.scalar, isMuted: $0.muted)
                    }
                    proxyManager.restoreVolumeState(
                        proxyDeviceID: proxyManager.activeProxyDeviceID,
                        physicalUID: physicalUID,
                        override: committed
                    )
                    logger.info("Volume state re-applied to proxy after IO start")
                }
            }
        }
    } catch let error as AudioEngineError {
        logger.error("Audio engine setup failed: \(error.description)")
        if case .allDevicesFailed = error {
            logger.error("All \(devices.count) device(s) failed to initialize.")
            logger.error("This may indicate no functional audio output devices are available.")
        }
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .inactive
            snapshot.audioPipeline = .notStarted
            snapshot.detail = "audio engine setup failed: \(error.description)"
        }
        // `autoSelectProxy()` above already switched the system default output to
        // the proxy device. Exiting without teardown would leave the Mac pointed
        // at a virtual device whose Host is gone — silent audio with no obvious
        // cause. `cleanup()` restores the physical device before releasing.
        cleanup()
        exit(1)
    } catch {
        logger.error("Audio engine setup failed: \(error.localizedDescription)")
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .inactive
            snapshot.audioPipeline = .notStarted
            snapshot.detail = "audio engine setup failed: \(error.localizedDescription)"
        }
        // See the AudioEngineError branch: the default output is on the proxy by
        // now, so teardown is what keeps the failure from silencing the machine.
        cleanup()
        exit(1)
    }

    // Listen for bounce requests from App via Darwin notification
    var bounceToken: Int32 = 0
    let bounceStatus = _notify_register_dispatch(
        "com.soundbridge.bounce-request",
        &bounceToken,
        DispatchQueue.global(qos: .userInitiated)
    ) { _ in
        logger.info("Received bounce request from App")
        proxyManager.bounceDevice()
    }
    if bounceStatus != 0 {
        logger.error("Failed to register bounce notification listener (status: \(bounceStatus))")
    }

    RunLoop.current.run()

    // Every exit from `main()` now releases what startup acquired, not just the
    // signal paths. Without this, a run loop that returns — no HAL sources left
    // to wait on — ended the process with the flock held until the kernel
    // reclaimed it and the mapping unlinked by nobody.
    cleanup()
}

func setupSleepWakeMonitoring() {
    print("[Startup] Registering sleep/wake handler...")

    sleepWakeMonitor.onSleep = {
        guard deviceMonitor.hostState == .active else {
            logger.info("Host is idle; no AudioEngine to stop before sleep")
            return
        }

        print("[SleepWake] System entering sleep, stopping AudioEngine...")
        audioEngine.stop()
        logger.info("AudioEngine stopped before sleep")
    }

    sleepWakeMonitor.onWake = {
        print("[SleepWake] Recovering after wake...")

        deviceMonitor.reregisterListeners()
        deviceMonitor.resetDebounce()
        proxyManager.reregisterVolumeForwarding()

        guard deviceMonitor.hostState == .active else {
            logger.info("Host is idle after wake; skipping AudioEngine restart")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            do {
                try audioEngine.setup(
                    devices: deviceRegistry.devices,
                    preferredDeviceID: proxyManager.activePhysicalDeviceID
                )
                try audioEngine.start()
                logger.info("AudioEngine restarted after wake")
            } catch {
                logger.error(
                    "AudioEngine restart failed: \(error.localizedDescription)"
                )
            }
        }
    }

    sleepWakeMonitor.start()
}

func setupSignalHandlers() {
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        print("\n[Signal] Received SIGINT (Ctrl+C)")
        cleanup()
        exit(0)
    }
    sigintSource.resume()
    signalSources.append(sigintSource)

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        print("\n[Signal] Received SIGTERM")
        cleanup()
        exit(0)
    }
    sigtermSource.resume()
    signalSources.append(sigtermSource)

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
}

func cleanup() {
    // Run-once and strictly ordered. Reached from SIGINT and SIGTERM, and now
    // also from the three run-loop exits in `main()`, so a duplicate request is
    // a real possibility rather than a theoretical one.
    let performedTeardown = shutdownSequence.run { step in
        switch step {
        case .markStopping:
            deviceMonitor.setHostState(.stopping)
            print("\n[Cleanup] Starting cleanup process...")

        case .stopConnectionMonitor:
            connectionMonitor?.stop()

        case .stopSleepWakeMonitor:
            sleepWakeMonitor.stop()

        case .stopHeartbeat:
            memoryManager.stopHeartbeat()

        case .restorePhysicalDevice:
            _ = proxyManager.restorePhysicalDevice()

        case .stopAudioEngine:
            audioEngine.stop()

        case .removeControlFile:
            print("[Cleanup] Removing control file...")
            unlink(SoundBridgeConfig.controlFilePath)

        case .waitForDriverDetach:
            Thread.sleep(forTimeInterval: SoundBridgeConfig.cleanupWaitTimeout)

        case .unlinkSharedMemory:
            memoryManager.cleanup()

        case .maybeRestartCoreAudio:
            // Phase 2.1.4 §2.3: restarting the system audio daemon is not
            // something a quit path may do on its own initiative — it takes
            // every other application's audio down with it, and the driver no
            // longer needs it to notice a removed Host. Kept behind a constant
            // so the decision stays visible instead of being deleted and
            // quietly reintroduced.
            if SoundBridgeConfig.restartsCoreAudioOnExit {
                restartCoreAudio()
            } else {
                print("[Cleanup] coreaudiod left running (policy: no automatic audio-daemon restart)")
                logger.info("Skipping coreaudiod restart (restartsCoreAudioOnExit == false)")
            }

        case .releaseInstanceLock:
            // Released last: the lock covers every resource touched above. The
            // file stays on disk; only the flock is dropped.
            instanceLock.release()
        }
    }

    guard performedTeardown else {
        print("[Cleanup] Teardown already in progress or complete; duplicate request ignored")
        return
    }

    logger.info("Cleanup complete")
}

// MARK: - Startup readiness

private enum ProxyReadiness {
    case ready
    case timedOut(seconds: Int)
}

/// Poll for the driver's proxy device, with a hard deadline.
///
/// Sleeps by running the main run loop rather than `Thread.sleep`: the HAL
/// device-changed callbacks are delivered on the main queue, and a Host that
/// blocked the main thread here would not notice a device appearing until it
/// had stopped waiting for one.
private func waitForProxyDevice(forUID physicalUID: String) -> ProxyReadiness {
    // `run(mode:before:)` returns immediately when the run loop has no sources,
    // which would turn the poll interval into a spin. One long-lived timer keeps
    // each call blocked for the requested slice.
    let keepAlive = Timer(timeInterval: 3600, repeats: false) { _ in }
    RunLoop.current.add(keepAlive, forMode: .default)
    defer { keepAlive.invalidate() }

    let waiter = ReadinessWaiter(
        timeout: SoundBridgeConfig.proxyDiscoveryTimeout,
        pollInterval: SoundBridgeConfig.proxyPollInterval,
        sleep: { interval in
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(interval))
        }
    )

    let outcome = waiter.waitFor { poll in
        if proxyManager.findProxyDevice(forPhysicalUID: physicalUID) != nil {
            return .ready
        }
        return .notYet("proxy device for \(physicalUID) absent from the HAL list (poll \(poll))")
    }

    switch outcome {
    case .ready(let polls):
        print("    ✓ Proxy device found after \(polls) poll(s)")
        return .ready
    case .timedOut(let polls, let reason):
        logger.error("Proxy device did not appear: \(reason, privacy: .public) after \(polls) poll(s)")
        return .timedOut(seconds: Int(SoundBridgeConfig.proxyDiscoveryTimeout.rounded()))
    case .terminal(let reason, _):
        logger.error("Proxy wait aborted: \(reason, privacy: .public)")
        return .timedOut(seconds: Int(SoundBridgeConfig.proxyDiscoveryTimeout.rounded()))
    }
}

/// Enter the degraded state: alive, diagnosable, and explicitly not in the audio
/// path.
///
/// Shared memory stays up on purpose — the driver may still attach later, and
/// `onDegradedRecovery` retries when the device list changes. The control file
/// stays too: it is what the driver reads to build the proxy in the first place,
/// so removing it here would guarantee the situation never recovers.
private func enterDegraded(detail: String) {
    deviceMonitor.setHostState(.degraded)
    lifecycleReporter.update { snapshot in
        snapshot.outcome = .proxyTimeout
        snapshot.halDiscovery = .notDiscovered
        snapshot.proxyDevice = .missing
        snapshot.audioPipeline = .notStarted
        snapshot.detail = detail
    }

    // A proxy that appears later must be able to take over without a relaunch.
    deviceMonitor.onDegradedRecovery = {
        attemptDegradedRecovery()
    }

    print("[Startup] DEGRADED: \(detail)")
    logger.error(
        "Host is running without an audio path: \(detail, privacy: .public). Shared memory and heartbeat are kept so a late driver can attach; coreaudiod is left untouched."
    )
}

/// Retry the routing step after a device-list change while degraded.
private func attemptDegradedRecovery() {
    // One pass per degraded episode. Two notifications arriving while the first
    // probe is still on a background queue used to start two recoveries, and the
    // second `audioEngine.setup()` would replace `outputUnit` without disposing
    // it — two live units rendering into one shared-memory ring.
    guard degradedRecoveryGate.begin(isDegraded: deviceMonitor.hostState == .degraded) else { return }

    DispatchQueue.global(qos: .userInitiated).async {
        let selection = proxyManager.autoSelectProxy()
        guard selection.isRouted else {
            logger.info("Degraded recovery: proxy still not selectable (\(selection.diagnostic, privacy: .public))")
            // Released on the main queue like every other gate mutation.
            DispatchQueue.main.async { degradedRecoveryGate.finish() }
            return
        }

        DispatchQueue.main.async {
            defer { degradedRecoveryGate.finish() }

            // The probe ran off the main queue, so re-check: another path may
            // have left `.degraded` while it was in flight.
            guard deviceMonitor.hostState == .degraded else {
                logger.info(
                    "Degraded recovery: state became \(deviceMonitor.hostState.rawValue, privacy: .public) while probing; abandoning this pass"
                )
                return
            }

            let devices = deviceRegistry.devices
            guard !devices.isEmpty else {
                logger.warning("Degraded recovery: no physical devices left")
                return
            }

            adoptCommittedVolumeState()

            do {
                try audioEngine.setup(
                    devices: devices,
                    preferredDeviceID: proxyManager.activePhysicalDeviceID
                )
                try audioEngine.start()
                deviceMonitor.setHostState(.active)
                lifecycleReporter.update { snapshot in
                    snapshot.outcome = .ready
                    snapshot.driverFile = .present
                    snapshot.driverCompatibility = .compatible
                    snapshot.driverLoad = .loaded
                    snapshot.halDiscovery = .discovered
                    snapshot.proxyDevice = .found
                    snapshot.sharedMemoryConnection = .waitingForDriver
                    snapshot.detail = "recovered after the proxy device appeared late"
                }
                startConnectionMonitor()
                logger.info("Degraded recovery: audio engine started")
            } catch {
                logger.error("Degraded recovery: audio engine failed: \(error.localizedDescription)")
                lifecycleReporter.update { snapshot in
                    snapshot.outcome = .inactive
                    snapshot.audioPipeline = .notStarted
                    snapshot.detail = "proxy found but the audio engine failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Adopt the committed volume state as the Host's runtime authority.
///
/// Shared with the startup path and with degraded recovery so both sides of a
/// late start agree on which scalar the render path is using.
private func adoptCommittedVolumeState() {
    guard let activeUID = proxyManager.activeProxyUID,
          let committed = memoryManager.readVolumeState(for: activeUID) else {
        logger.warning("No committed volume state available after proxy selection")
        return
    }

    let state = volumeStateStore.initialize(
        scalar: committed.scalar,
        muted: committed.muted,
        mode: VolumeMode(protocolValue: committed.mode)
    )
    print("[Volume] Adopted: scalar=\(String(format: "%.3f", state.requestedScalar)) muted=\(state.isMuted) gain=\(String(format: "%.4f", state.appliedGain)) revision=\(state.revision)")
    logger.info("Adopted volume state for \(activeUID): scalar=\(state.requestedScalar) muted=\(state.isMuted) mode=\(state.mode.rawValue)")
}

/// Sample `driver_connected` and the heartbeats until the process exits.
///
/// This is reporting, not a startup gate: the driver only sets
/// `driver_connected` from its IO callback, so it stays 0 until something plays
/// through the proxy device. Waiting for it before starting the engine would
/// deadlock a quiet system.
func startConnectionMonitor() {
    connectionMonitor?.stop()

    let monitor = DriverConnectionMonitor(
        sample: {
            guard let uid = proxyManager.activeProxyUID else { return nil }
            return memoryManager.connectionObservation(for: uid)
        },
        report: { status, pipeline in
            lifecycleReporter.update { snapshot in
                snapshot.sharedMemoryConnection = status
                snapshot.audioPipeline = pipeline

                switch status {
                case .connected:
                    snapshot.driverLoad = .loaded
                    snapshot.halDiscovery = .discovered
                    snapshot.proxyDevice = .found
                case .driverNotResponding:
                    // Attached but never produced a frame — the narrow case that
                    // really is wrong. A device that played and went quiet stays
                    // `.connected` with `pipeline == .stalled`, because a pause
                    // is not a fault.
                    snapshot.outcome = .driverNotResponding
                    snapshot.detail = "driver attached but never produced a frame"
                case .disconnected:
                    snapshot.detail = "driver detached from this mapping"
                case .hostHeartbeatStalled:
                    snapshot.detail = "Host heartbeat timer stopped advancing"
                case .invalid:
                    snapshot.detail = "shared memory header failed validation"
                case .pending, .waitingForDriver:
                    break
                }

                if status == .connected, deviceMonitor.hostState == .active {
                    snapshot.outcome = .ready
                    if snapshot.detail?.isEmpty != false {
                        snapshot.detail = pipeline == .flowing
                            ? "audio flowing through the driver"
                            : "routed through the proxy device; no frames yet"
                    }
                }
            }
        }
    )

    monitor.start()
    connectionMonitor = monitor
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
