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
let lifecycleGate = HostLifecycleGate()
let proxyManager = ProxyDeviceManager(registry: deviceRegistry, volumePersistence: volumePersistence,
                                      lifecycleGate: lifecycleGate)
let volumeStateStore = VolumeStateStore()
let renderer = AudioRenderer(memoryManager: memoryManager)

// The render callback reads whatever mapping this slot publishes; it never
// looks at `proxyManager` itself. Routing changes therefore have to be pushed
// in, and this is the single place that does it.
proxyManager.onManagedProxyChanged = { uid in
    memoryManager.setPreferredRenderUID(uid)
}
let audioEngine = AudioEngine(renderer: renderer, registry: deviceRegistry)
let deviceMonitor = DeviceMonitor(
    registry: deviceRegistry,
    proxyManager: proxyManager,
    memoryManager: memoryManager,
    discovery: deviceDiscovery,
    audioEngine: audioEngine
)
let sleepWakeMonitor = SleepWakeMonitor(lifecycleGate: lifecycleGate)

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
/// 设备通知和恢复操作均在主队列串行；该标志合并已排队的重复尝试。
private var degradedRecoveryGate = DegradedRecoveryGate()
// P2 Batch 2 removed `degradedMaySelectDefault`. Recovery used it to decide
// whether it was allowed to make the proxy the default output again; recovery
// no longer writes the default output at all, so there is nothing to allow.

/// Single-flight guard for `.coreaudioRebuild` recovery.
///
/// Separate from `degradedRecoveryGate` because the two transitions are
/// different: degraded means the proxy never appeared, a rebuild means the
/// object graph that described it was replaced. Sharing one flag would let a
/// rebuild pass be mistaken for a degraded retry and skipped.
private var coreAudioRecoveryGate = CoreAudioRecoveryGate()

/// Teardown is requested by SIGINT and SIGTERM, so it has to be run-once and
/// stay ordered; see `ShutdownSequence` for why the order is the contract.
private var shutdownSequence = ShutdownSequence()

// Retain signal dispatch sources for the lifetime of the host process.
// Otherwise they are released after setupSignalHandlers() returns.
private var signalSources: [DispatchSourceSignal] = []
private var bounceNotificationToken: Int32?

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
        guard let sessionID = instanceLock.sessionID else {
            logger.error("Instance lock acquired without a session")
            cleanup()
            exit(1)
        }
        deviceRegistry.beginSession(sessionID)
        memoryManager.beginSession(sessionID)
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
    let initialEnumeration = deviceDiscovery.enumeratePhysicalDevicesWithStatus()
    let devices = initialEnumeration.devices

    if initialEnumeration.queryFailed {
        deviceMonitor.setHostState(.degraded)
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .degraded
            snapshot.halDiscovery = .notDiscovered
            snapshot.audioPipeline = .notStarted
            snapshot.detail = "initial HAL device-list query failed; waiting for a recheck"
        }
    } else if devices.isEmpty {
        logger.info("No physical output devices currently available; entering idle mode")
        deviceMonitor.setHostState(.idle)
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .noPhysicalDevices
            snapshot.audioPipeline = .notStarted
            snapshot.detail = "no physical output device; idle by design, not a failure"
        }
    }

    // 初始空设备与恢复后的空设备都使用同一条 degraded 恢复路径。
    deviceMonitor.onDegradedRecovery = { attemptDegradedRecovery() }
    deviceMonitor.onNoPhysicalDevices = {
        connectionMonitor?.stop()
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .noPhysicalDevices
            snapshot.audioPipeline = .notStarted
            snapshot.detail = "no physical output device; waiting for a device"
        }
    }
    deviceMonitor.onIdleDevicesAvailable = { allowRoutingChanges in
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .degraded
            snapshot.proxyDevice = .pending
            snapshot.audioPipeline = .notStarted
            snapshot.detail = "physical device appeared; waiting for its proxy"
        }
        if allowRoutingChanges { attemptDegradedRecovery() }
    }

    print("[Step 2] Registering device change listeners...")
    deviceMonitor.registerListeners()
    setupBounceNotifications()
    if initialEnumeration.queryFailed { deviceMonitor.scheduleInitialDeviceRecheck() }

    // A HAL rebuild invalidates the listeners registered above and every
    // AudioObjectID this process holds. DeviceMonitor decides when a device
    // notification means "rebuilt" rather than "plugged"; this is what it calls
    // when it does.
    deviceMonitor.onCoreAudioRestart = { reason in
        attemptCoreAudioRecovery(reason: reason)
    }

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

    print("[Step 3] Preparing shared memory and publishing the device list...")
    let preparationSession = instanceLock.sessionID
    let canPrepare = {
        lifecycleGate.permitsNormal() && instanceLock.isHeld && preparationSession != nil &&
            instanceLock.sessionID == preparationSession && !shutdownSequence.isComplete
    }
    // 启动与热插拔使用同一准备规则：所有映射可用后才发布控制文件。
    // 部分创建的映射保留供有界重查复用，不把未完成的快照交给 Driver。
    let prepared = DeviceMappingPreparation.publishIfReady(
        uids: devices.map { $0.uid },
        canProceed: canPrepare,
        hasMapping: { memoryManager.acquireMemory(for: $0) != nil },
        createMapping: { memoryManager.createMemory(for: $0, persistence: volumePersistence) != nil },
        publish: { deviceRegistry.update(devices) }
    )
    guard prepared else {
        guard canPrepare() else { return }
        enterDegraded(detail: "initial device mappings or control file could not be published; waiting for a recheck")
        deviceMonitor.scheduleInitialDeviceRecheck()
        RunLoop.current.run()
        cleanup()
        return
    }
    print("[Step 4] Control file: \(SoundBridgeConfig.controlFilePath)")

    print("[Step 5] Starting heartbeat monitor...")
    memoryManager.startHeartbeat()

    print("[Step 6] Waiting up to \(SoundBridgeConfig.proxyDiscoveryTimeout)s for the driver's proxy device...")

    // Phase 2.1.4: this used to be `Thread.sleep(2)`, which asserted nothing —
    // startup "succeeded" whether or not a proxy device ever appeared, and the
    // two seconds were spent even when the device was already there. Wait for the
    // actual HAL device instead, with a deadline.
    func waitForCurrentLifecycleToStop() {
        if !shutdownSequence.isComplete, instanceLock.isHeld { RunLoop.current.run() }
    }

    switch waitForProxyDevice(forUID: preferredDevice.uid) {
    case .ready:
        break
    case .timedOut(let seconds):
        enterDegraded(
            detail: "no proxy device for \(preferredDevice.name) after \(seconds)s; the driver is not loaded, or is not compatible with this build"
        )
        RunLoop.current.run()
        cleanup()
        return
    case .cancelled:
        // 泵送期间恢复可能已经接管启动；旧启动流程不能再次建立音频链路。
        waitForCurrentLifecycleToStop()
        if instanceLock.isHeld { cleanup() }
        return
    }

    guard let startupToken = lifecycleGate.normalToken(), let startupSession = instanceLock.sessionID else {
        waitForCurrentLifecycleToStop()
        if instanceLock.isHeld { cleanup() }
        return
    }
    let canStart = {
        lifecycleGate.permitsNormal(startupToken) && instanceLock.isHeld && instanceLock.sessionID == startupSession
    }
    print("[Step 7] Resolving the proxy route (the default output is not touched)...")
    let routing = proxyManager.resolveProxyRouting(forPhysicalUID: preferredDevice.uid)
    guard canStart() else {
        waitForCurrentLifecycleToStop()
        if instanceLock.isHeld { cleanup() }
        return
    }
    print("[Step 7] Proxy route: \(routing.diagnostic)")

    guard routing.isRoutable else {
        enterDegraded(detail: "the driver's proxy device for \(preferredDevice.name) is not available (\(routing.diagnostic))")
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

    print("[Step 8] Setting up audio engine with device fallback...")

    // The device this Host routes for, resolved above without reference to
    // which output the user has selected.
    let preferredDeviceID = proxyManager.activePhysicalDeviceID
    if preferredDeviceID != 0 {
        if let preferredDevice = devices.first(where: { $0.id == preferredDeviceID }) {
            print("    Preferred device: \(preferredDevice.name)")
        } else {
            print("    Preferred device ID \(preferredDeviceID) not in device list")
        }
    }

    do {
        let result = try GuardedEngineStart.run(
            canProceed: canStart,
            setup: {
                try audioEngine.setup(devices: devices, preferredDeviceID: preferredDeviceID != 0 ? preferredDeviceID : nil)
            },
            start: { try audioEngine.start() }
        )
        guard result == .started, canStart() else {
            waitForCurrentLifecycleToStop()
            if instanceLock.isHeld { cleanup() }
            return
        }

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
            snapshot.detail = "engine running; the driver attaches on its first IO, so waitingForDriver is expected until an app plays through the SoundBridge device; " + defaultOutputNote(routing)
        }
        startConnectionMonitor()

        // Post-start re-apply. The driver pushed the committed shared-memory
        // volume into its VolumeControl during OnStartIO (see
        // SyncVolumeStateWithSharedMemory), so this is a belt-and-braces
        // re-apply after the initial device bounce, not the initialisation
        // path. The override keeps a recovered shared-memory value from being
        // replaced by the persistence default.
        if proxyManager.activeProxyDeviceID != 0, let token = lifecycleGate.normalToken() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard lifecycleGate.permitsNormal(token) else { return }
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
        guard canStart() else {
            waitForCurrentLifecycleToStop()
            if instanceLock.isHeld { cleanup() }
            return
        }
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
        // P2 Batch 2 removed the default-output restore that used to precede
        // this. The Host never made the proxy the default output, so a failed
        // engine start no longer leaves the Mac pointing at a virtual device;
        // there is nothing to put back. Teardown still releases the lock, the
        // mappings and the control file.
        cleanup()
        exit(1)
    } catch {
        guard canStart() else {
            waitForCurrentLifecycleToStop()
            if instanceLock.isHeld { cleanup() }
            return
        }
        logger.error("Audio engine setup failed: \(error.localizedDescription)")
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .inactive
            snapshot.audioPipeline = .notStarted
            snapshot.detail = "audio engine setup failed: \(error.localizedDescription)"
        }
        // See the AudioEngineError branch: there is no default-output state to
        // put back, because the Host never took one.
        cleanup()
        exit(1)
    }

    RunLoop.current.run()

    // Every exit from `main()` now releases what startup acquired, not just the
    // signal paths. Without this, a run loop that returns — no HAL sources left
    // to wait on — ended the process with the flock held until the kernel
    // reclaimed it and the mapping unlinked by nobody.
    cleanup()
}

private func setupBounceNotifications() {
    var token: Int32 = 0
    let status = _notify_register_dispatch("com.soundbridge.bounce-request", &token, DispatchQueue.main) { _ in
        guard lifecycleGate.permitsNormal() else { return }
        logger.info("Received reconnect request from App")
        reconnectAudioPath()
    }
    if status == 0 {
        bounceNotificationToken = token
    } else {
        logger.error("Failed to register bounce notification listener (status: \(status))")
    }
}

/// Re-establish the Host's own audio path after the App's "Reconnect Audio".
///
/// It re-resolves the proxy the driver publishes and points the engine at the
/// physical device behind it. It deliberately does **not** bounce the default
/// output: a reconnect restores the Host↔driver↔proxy connection, and the
/// user's default output — wherever it is — stays put. The notification name is
/// unchanged because the App's button still posts it; only what the Host does
/// with it changed (P2 Batch 2).
private func reconnectAudioPath() {
    guard lifecycleGate.permitsNormal(), !proxyManager.isRecovering else { return }
    let devices = deviceRegistry.devices
    guard !devices.isEmpty else {
        logger.info("Reconnect requested with no physical devices; nothing to re-establish")
        return
    }

    let remap = proxyManager.remapAfterCoreAudioRebuild(in: devices)
    guard remap.proxyPresent else {
        logger.notice("Reconnect requested but the driver has not published a proxy again yet")
        return
    }

    do {
        try audioEngine.switchDevice(remap.physicalDeviceID)
    } catch {
        logger.error("Reconnect could not point the engine at the physical device: \(error.localizedDescription)")
    }
    proxyManager.refreshSystemDefaultOutput()
    print("[Reconnect] Audio path re-established; default output untouched")
}

func setupSleepWakeMonitoring() {
    print("[Startup] Registering sleep/wake handler...")

    sleepWakeMonitor.onSleep = {
        guard lifecycleGate.permitsNormal(), deviceMonitor.hostState == .active else {
            logger.info("Host is idle; no AudioEngine to stop before sleep")
            return
        }

        print("[SleepWake] System entering sleep, stopping AudioEngine...")
        audioEngine.stop()
        logger.info("AudioEngine stopped before sleep")
    }

    sleepWakeMonitor.onWake = {
        guard let token = lifecycleGate.normalToken(), let session = instanceLock.sessionID,
              instanceLock.isHeld else { return }
        print("[SleepWake] Recovering after wake...")
        let canWakeProceed = {
            lifecycleGate.permitsNormal(token) && instanceLock.isHeld && instanceLock.sessionID == session
        }

        deviceMonitor.reregisterListeners()
        guard canWakeProceed() else { return }
        deviceMonitor.resetDebounce()
        guard canWakeProceed() else { return }
        proxyManager.reregisterVolumeForwarding()
        guard canWakeProceed() else { return }

        guard deviceMonitor.hostState == .active else {
            logger.info("Host is idle after wake; skipping AudioEngine restart")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard canWakeProceed(), deviceMonitor.hostState == .active else { return }
            do {
                let result = try GuardedEngineStart.run(
                    canProceed: { canWakeProceed() && deviceMonitor.hostState == .active },
                    setup: {
                        try audioEngine.setup(
                            devices: deviceRegistry.devices,
                            preferredDeviceID: proxyManager.activePhysicalDeviceID
                        )
                    },
                    start: { try audioEngine.start() }
                )
                if result == .started { logger.info("AudioEngine restarted after wake") }
            } catch {
                guard canWakeProceed() else { return }
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
            lifecycleGate.stop()
            if let token = bounceNotificationToken {
                _ = _notify_cancel(token)
                bounceNotificationToken = nil
            }
            // Refuse new recovery first: a pass that rewrites the control file
            // or re-registers listeners while resources are being released is
            // how a teardown ends up racing itself.
            coreAudioRecoveryGate.terminate()
            deviceMonitor.setHostState(.stopping)
            lifecycleReporter.update { snapshot in
                snapshot.outcome = .stopping
                snapshot.detail = "shutdown started"
            }
            print("\n[Cleanup] Starting cleanup process...")

        case .stopConnectionMonitor:
            connectionMonitor?.stop()

        case .stopSleepWakeMonitor:
            sleepWakeMonitor.stop()

        case .removePropertyListeners:
            // One-way from here: nothing may re-arm them, so a HAL notification
            // cannot re-enter the device path while the rest is being released.
            deviceMonitor.stop()

        case .stopHeartbeat:
            memoryManager.stopHeartbeat()

        // P2 Batch 2 removed the shutdown restore step. It returned the
        // physical device as the default output on quit, which changed a
        // system-wide setting from a lifecycle event; the default output is
        // now left exactly where the user put it.

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

        case .publishStopped:
            // Written while the lock is still held, so the App can tell
            // "quitting" apart from "died": it resolves the lock first, and a
            // state written after the release would never be read.
            lifecycleReporter.update { snapshot in
                snapshot.outcome = .stopped
                snapshot.detail = "shutdown complete"
            }

        case .releaseInstanceLock:
            // 使排队的状态重试失效后再释放锁，防止旧 Session 晚发布。
            deviceRegistry.endSession()
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

// MARK: - Routing target

/// The device this Host should route for, chosen without consulting the system
/// default output.
///
/// `managedProxyUID` first: it survives a rebuild and remembers what the Host
/// was doing. Then whatever the user is listening to, then the first device.
private func routingTarget(in devices: [PhysicalDevice]) -> PhysicalDevice? {
    if let uid = proxyManager.managedProxyUID,
       let managed = devices.first(where: { $0.uid == uid }) {
        return managed
    }
    return proxyManager.resolveCurrentOutputDevice(in: devices) ?? devices.first
}

/// One clause for the lifecycle detail: where the audio is going, and the fact
/// that the Host is not the thing that decides it.
private func defaultOutputNote(_ routing: ProxyDeviceManager.ProxyRoutingOutcome) -> String {
    if routing.isDefaultOutput {
        return "the system default output is the SoundBridge device"
    }
    let current = deviceRegistry.systemDefaultOutputUID ?? "unset"
    return "the system default output is \(current) and was left alone"
}

// MARK: - Startup readiness

private enum ProxyReadiness {
    case ready
    case timedOut(seconds: Int)
    case cancelled
}

/// Poll for the driver's proxy device, with a hard deadline.
///
/// Sleeps by running the main run loop rather than `Thread.sleep`: the HAL
/// device-changed callbacks are delivered on the main queue, and a Host that
/// blocked the main thread here would not notice a device appearing until it
/// had stopped waiting for one.
private func waitForProxyDevice(forUID physicalUID: String) -> ProxyReadiness {
    guard let token = lifecycleGate.normalToken(), let session = instanceLock.sessionID else { return .cancelled }
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
        guard lifecycleGate.permitsNormal(token), instanceLock.isHeld, instanceLock.sessionID == session else {
            return .terminal("startup lifecycle changed")
        }
        let found = proxyManager.findProxyDevice(forPhysicalUID: physicalUID) != nil
        guard lifecycleGate.permitsNormal(token), instanceLock.isHeld, instanceLock.sessionID == session else {
            return .terminal("startup lifecycle changed")
        }
        return found ? .ready : .notYet("proxy device for \(physicalUID) absent from the HAL list (poll \(poll))")
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
        return .cancelled
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
        snapshot.outcome = .degraded
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
    guard let token = lifecycleGate.normalToken(), let session = instanceLock.sessionID, instanceLock.isHeld,
          degradedRecoveryGate.begin(isDegraded: deviceMonitor.hostState == .degraded) else { return }

    DispatchQueue.main.async {
        defer { degradedRecoveryGate.finish() }
        guard lifecycleGate.permitsNormal(token), deviceMonitor.hostState == .degraded,
              instanceLock.isHeld, instanceLock.sessionID == session else { return }
        let devices = deviceRegistry.devices
        guard !devices.isEmpty else {
            logger.warning("Degraded recovery: no physical devices left")
            return
        }

        // 恢复只重建映射与音频链路，不夺取用户当前的默认输出。
        let target = routingTarget(in: devices)
        guard let target else {
            logger.warning("Degraded recovery: no device to route for")
            return
        }
        let routing = proxyManager.resolveProxyRouting(forPhysicalUID: target.uid)
        guard routing.isRoutable else {
            logger.info("Degraded recovery: proxy still not available (\(routing.diagnostic, privacy: .public))")
            return
        }
        guard lifecycleGate.permitsNormal(token), deviceMonitor.hostState == .degraded,
              instanceLock.isHeld, instanceLock.sessionID == session else { return }
        adoptCommittedVolumeState()

        let canStart = {
            lifecycleGate.permitsNormal(token) && deviceMonitor.hostState == .degraded &&
                instanceLock.isHeld && instanceLock.sessionID == session
        }
        do {
            let result = try GuardedEngineStart.run(
                canProceed: canStart,
                setup: { try audioEngine.setup(devices: devices, preferredDeviceID: proxyManager.activePhysicalDeviceID) },
                start: { try audioEngine.start() }
            )
            guard result == .started, canStart() else { return }
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
            guard canStart() else { return }
            logger.error("Degraded recovery: audio engine failed: \(error.localizedDescription)")
            lifecycleReporter.update { snapshot in
                snapshot.outcome = .inactive
                snapshot.audioPipeline = .notStarted
                snapshot.detail = "proxy found but the audio engine failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - CoreAudio rebuild recovery

/// Start one bounded recovery episode for a rebuilt HAL object graph.
///
/// Runs on the main queue and pumps the run loop while it waits between
/// attempts, for the same reason `waitForProxyDevice` does: the HAL callbacks
/// that carry the new device list are delivered on the main queue, and a Host
/// blocked in `Thread.sleep` here would not see the device it is waiting for.
///
/// Duplicate triggers are no-ops: `coreAudioRecoveryGate` allows one episode at a
/// time and refuses new ones once shutdown has begun.
private func attemptCoreAudioRecovery(reason: String) {
    guard coreAudioRecoveryGate.begin() else { return }
    guard let session = instanceLock.sessionID, lifecycleGate.beginRecovery() else {
        coreAudioRecoveryGate.finish()
        return
    }

    // Report "recovering", not "ready" and not "stopped". The App has no third
    // channel for this, so the phase has to be a value of the existing outcome
    // field.
    connectionMonitor?.stop()
    deviceMonitor.beginRecoveryReconciliation()
    proxyManager.beginRecovery()
    audioEngine.stop()
    deviceMonitor.setHostState(.recovering)
    lifecycleReporter.update { snapshot in
        snapshot.outcome = .recovering
        snapshot.halDiscovery = .pending
        snapshot.proxyDevice = .pending
        snapshot.audioPipeline = .notStarted
        snapshot.detail = "CoreAudio rebuilt its device list: \(reason)"
    }
    logger.error("CoreAudio recovery started: \(reason, privacy: .public)")

    var reconciliationGeneration: UInt64 = 0
    let episode = CoreAudioRecoveryEpisode(
        backoff: RecoveryBackoff(),
        sleep: { interval in
            // `run(mode:before:)` returns immediately when the run loop has no
            // sources, which would turn the backoff into a spin and make four
            // attempts happen in a microsecond. One long-lived timer keeps each
            // slice honest, exactly as `waitForProxyDevice` does.
            let keepAlive = Timer(timeInterval: 3600, repeats: false) { _ in }
            RunLoop.current.add(keepAlive, forMode: .default)
            defer { keepAlive.invalidate() }
            let deadline = ProcessInfo.processInfo.systemUptime + interval
            while !coreAudioRecoveryGate.isTerminated, !shutdownSequence.isComplete {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(min(remaining, 0.1)))
            }
        },
        shouldContinue: {
            !coreAudioRecoveryGate.isTerminated && !shutdownSequence.isComplete &&
                instanceLock.isHeld && instanceLock.sessionID == session
        },
        commitAttempt: {
            deviceMonitor.finishRecoveryReconciliation(ifUnchanged: reconciliationGeneration)
        },
        discardAttempt: {
            audioEngine.stop()
        },
        attemptWithBudget: { attempt, canProceed in
            reconciliationGeneration = deviceMonitor.recoveryReconciliationSnapshot()
            let result = performCoreAudioRecoveryAttempt(attempt, canProceed: canProceed)
            guard canProceed() else { return .terminal(reason: "recovery cancelled or attempt deadline exceeded") }
            return result
        }
    )

    let outcome = episode.run()
    guard !coreAudioRecoveryGate.isTerminated, !shutdownSequence.isComplete,
          instanceLock.isHeld, instanceLock.sessionID == session else {
        coreAudioRecoveryGate.finish()
        return
    }
    if !outcome.isRecovered {
        audioEngine.stop()
        if case .waitingForDevice = outcome {
            // 已在预算检查后原子提交空设备快照。
        } else {
            deviceMonitor.abandonRecoveryReconciliation()
        }
    }
    finishCoreAudioRecovery(outcome)
    proxyManager.endRecovery()
    lifecycleGate.endRecovery()
    coreAudioRecoveryGate.finish()
    deviceMonitor.resetCoreAudioDetector()
    if outcome.isRecovered, lifecycleGate.permitsNormal() {
        // 恢复期间的音量通知被 Gate 拒绝；重新同步当前代理音量与静音。
        if let uid = proxyManager.managedProxyUID,
           proxyManager.currentDefaultOutputOwner() == .proxy(physicalUID: uid) {
            proxyManager.reregisterVolumeForwarding()
        }
        startConnectionMonitor()
    }
}

/// One attempt at putting the audio path back together.
///
/// The order matters and is the same on every attempt: drop every stale ID,
/// re-register the listeners that died with the old graph, enumerate afresh,
/// publish, then re-map by UID. Nothing from before the rebuild is reused.
private func performCoreAudioRecoveryAttempt(_ attempt: Int, canProceed: () -> Bool) -> RecoveryAttemptResult {
    guard canProceed() else {
        return .terminal(reason: "shutdown or recovery deadline reached")
    }

    // 1. Every AudioObjectID this process holds is stale. Dropping them first
    //    means no later step can use one by accident.
    proxyManager.invalidateDeviceReferences()
    guard canProceed() else { return .terminal(reason: "recovery cancelled") }

    // 2. The property listeners were registered against the old graph and are
    //    gone with it. Without them the Host would recover once and then go
    //    deaf, which is exactly the 1.2.0 symptom.
    deviceMonitor.reregisterListeners(reason: "CoreAudio rebuild")
    guard canProceed() else { return .terminal(reason: "recovery cancelled") }
    guard deviceMonitor.hasAllListeners else {
        return .retryable(reason: "HAL property listeners could not be re-registered")
    }

    // 3. Enumerate from scratch.
    let enumeration = deviceDiscovery.enumeratePhysicalDevicesWithStatus()
    guard canProceed() else { return .terminal(reason: "recovery cancelled") }
    guard !enumeration.queryFailed else {
        return .retryable(reason: "the HAL device list is still not queryable (attempt \(attempt))")
    }

    let devices = enumeration.devices
    // 先为新设备建立共享内存，再发布快照；清理旧映射时检查代际。
    guard deviceMonitor.publishRecoveryDevices(devices, canProceed: canProceed) else {
        return .retryable(reason: "could not prepare the current recovery device mappings")
    }
    guard canProceed() else { return .terminal(reason: "recovery cancelled") }
    guard !devices.isEmpty else {
        _ = proxyManager.refreshSystemDefaultOutput()
        return .waitingForDevice(reason: "no physical output device after the CoreAudio rebuild")
    }
    // 可能从尚未启动过心跳的 idle 状态进入恢复。
    guard canProceed() else { return .terminal(reason: "recovery cancelled") }
    memoryManager.startHeartbeat()

    // 5. Re-resolve the proxy by UID and restore its volume state. This does
    //    not touch the default output device.
    let remap = proxyManager.remapAfterCoreAudioRebuild(in: devices)
    guard canProceed() else { return .terminal(reason: "recovery cancelled") }
    guard remap.proxyPresent else {
        return .retryable(
            reason: "the driver has not published a proxy again yet (\(devices.count) physical device(s))"
        )
    }

    // 6. Bring the engine back on the physical device.
    do {
        adoptCommittedVolumeState()
        guard canProceed() else { return .terminal(reason: "recovery cancelled") }
        try audioEngine.setup(devices: devices, preferredDeviceID: remap.physicalDeviceID)
        guard canProceed() else { return .terminal(reason: "recovery cancelled") }
        try audioEngine.start()
        guard canProceed() else { return .terminal(reason: "recovery cancelled") }
    } catch {
        return .retryable(reason: "the audio engine could not start: \(error.localizedDescription)")
    }

    let detail = remap.defaultIsProxy
        ? "proxy re-established and still the default output"
        : "proxy re-established; the default output is \(remap.systemDefaultOutputUID ?? "unset") and was left alone"
    return .recovered(detail: detail)
}

/// Report what the episode achieved.
private func finishCoreAudioRecovery(_ outcome: CoreAudioRecoveryOutcome) {
    switch outcome {
    case .recovered:
        deviceMonitor.setHostState(.active)
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .ready
            snapshot.driverFile = .present
            snapshot.driverCompatibility = .compatible
            snapshot.driverLoad = .loaded
            snapshot.halDiscovery = .discovered
            snapshot.proxyDevice = .found
            snapshot.sharedMemoryConnection = .waitingForDriver
            snapshot.audioPipeline = .notStarted
            snapshot.detail = outcome.diagnostic
        }
        print("[Recovery] \(outcome.diagnostic)")
        logger.info("CoreAudio recovery complete: \(outcome.diagnostic, privacy: .public)")

    case .waitingForDevice:
        deviceMonitor.setHostState(.idle)
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .noPhysicalDevices
            snapshot.audioPipeline = .notStarted
            snapshot.detail = outcome.diagnostic
        }

    case .failed, .exhausted:
        deviceMonitor.setHostState(.degraded)
        lifecycleReporter.update { snapshot in
            snapshot.outcome = .degraded
            snapshot.halDiscovery = .notDiscovered
            snapshot.proxyDevice = .missing
            snapshot.audioPipeline = .notStarted
            snapshot.detail = outcome.diagnostic
        }
        // A proxy that appears later must still be able to take over without a
        // relaunch; that is the same late-driver path startup uses.
        deviceMonitor.onDegradedRecovery = {
            attemptDegradedRecovery()
        }
        logger.error("CoreAudio recovery did not restore the audio path: \(outcome.diagnostic, privacy: .public)")
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
        lifecycleGate: lifecycleGate,
        sample: {
            // Control-thread drain for what the render callback recorded. The
            // callback itself only adds to counters; this is where a refused
            // block, a missing mapping or a missed deadline becomes a log line.
            renderer.drainDiagnostics()
            renderer.drainTiming()
            guard let uid = proxyManager.activeProxyUID else { return nil }
            return memoryManager.connectionObservation(for: uid)
        },
        report: { status, pipeline in
            lifecycleReporter.update { snapshot in
                SharedMemoryReportPolicy.apply(
                    status,
                    pipeline: pipeline,
                    hostIsActive: deviceMonitor.hostState == .active,
                    to: &snapshot
                )
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
