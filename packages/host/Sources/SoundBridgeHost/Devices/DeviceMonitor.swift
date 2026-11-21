import Foundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "DeviceMonitor")

enum HostState: String {
    case starting
    case idle
    case active
    /// Running, but deliberately not in the audio path.
    ///
    /// Phase 2.1.4: when the driver's proxy device never appears, the Host stays
    /// alive for diagnostics and keeps its shared memory so a late driver can
    /// attach, but it must not pretend to be `active`. This is the state that
    /// makes the difference visible to the App.
    case degraded
    /// CoreAudio replaced its object graph and the Host is rebuilding the path.
    /// Distinct from `degraded`: recovery is in progress rather than refused.
    case recovering
    case stopping
}

/// 仅在所有设备映射准备好且生命周期仍有效时发布设备快照。
enum DeviceMappingPreparation {
    static func publishIfReady(
        uids: [String],
        canProceed: () -> Bool,
        hasMapping: (String) -> Bool,
        createMapping: (String) -> Bool,
        publish: () -> Bool
    ) -> Bool {
        for uid in uids {
            guard canProceed() else { return false }
            if !hasMapping(uid), !createMapping(uid) { return false }
        }
        guard canProceed() else { return false }
        return publish()
    }
}

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
    /// Set by `stop()`. Shutdown is one-way: nothing after it may re-arm the HAL
    /// listeners.
    private var hasStopped = false
    /// The one pending confirmation probe for a suspect rebuild sample.
    private var pendingRebuildRecheck: DispatchWorkItem?
    private(set) var hostState: HostState = .starting
    var hasAllListeners: Bool { listenersRegistered }
    /// Decides whether a device-list change means "CoreAudio was rebuilt" or
    /// "a monitor was plugged in". Only the former starts a recovery.
    private var coreAudioDetector = CoreAudioRestartDetector()

    /// Called from a device-list change while the Host sits in `.degraded`, so a
    /// proxy device that shows up late (coreaudiod finishing its scan, driver
    /// installed after the Host started) can still be picked up instead of
    /// leaving the Host wedged until the next launch.
    var onDegradedRecovery: (() -> Void)?
    /// 空设备状态与恢复入口由主生命周期协调器发布。
    var onNoPhysicalDevices: (() -> Void)?
    var onIdleDevicesAvailable: ((_ allowRoutingChanges: Bool) -> Void)?

    /// Called when the HAL object graph looks rebuilt. The reason is passed
    /// through so the recovery can log what it reacted to instead of "something
    /// changed".
    var onCoreAudioRestart: ((String) -> Void)?

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

    func setHostState(_ newState: HostState) {
        guard hostState != newState else { return }

        print("[HostState] \(hostState.rawValue) -> \(newState.rawValue)")
        hostState = newState
    }

    func registerListeners() {
        guard !listenersRegistered else { return }
        // Shutdown removed them on purpose. Re-registering after that would put a
        // listener on an object graph the process is about to leave.
        guard !hasStopped else { return }

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
            let status = AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                deviceListChangedCallbackC,
                selfPtr
            )
            devicesListenerRegistered = false
            logRemovalStatus(status, name: "devices")
        }

        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if defaultOutputListenerRegistered {
            let status = AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                defaultOutputChangedCallbackC,
                selfPtr
            )
            defaultOutputListenerRegistered = false
            logRemovalStatus(status, name: "default-output")
        }
    }

    /// Report a listener removal without treating a rebuilt graph as an error.
    ///
    /// After `coreaudiod` restarts, the objects the listeners were attached to no
    /// longer exist and removal returns `kAudioHardwareBadObjectError`
    /// (560947818). That is the expected answer in a recovery, not a fault — the
    /// listener is gone either way — so it is logged at notice level with the
    /// status kept in the message rather than being silently discarded.
    private func logRemovalStatus(_ status: OSStatus, name: String) {
        if status == noErr { return }
        if status == kAudioHardwareBadObjectError {
            logger.notice(
                "Removing the \(name, privacy: .public) listener reported kAudioHardwareBadObjectError (OSStatus \(status)); the object it was attached to no longer exists"
            )
        } else {
            logger.error(
                "Failed to remove the \(name, privacy: .public) listener (OSStatus \(status))"
            )
        }
    }

    /// Remove the HAL listeners and refuse to install them again.
    ///
    /// The last teardown step that touches CoreAudio: once this has run, the
    /// process no longer reacts to anything the HAL says, so the steps after it
    /// cannot be interleaved with a device notification.
    func stop() {
        hasStopped = true
        cancelRebuildRecheck()
        removeListeners()
        logger.info("HAL property listeners removed (shutdown)")
    }

    /// Drop and re-install every HAL property listener.
    ///
    /// Needed whenever the objects the listeners were registered against stop
    /// existing: a wake from sleep, and a `coreaudiod` rebuild. The `reason`
    /// reaches the log so the two are distinguishable there — the recovery path
    /// and the wake path look identical from inside this method.
    func reregisterListeners(reason: String = "wake") {
        guard !hasStopped else { return }
        removeListeners()
        registerListeners()
        logger.info("Listeners re-registered (\(reason, privacy: .public))")
    }

    /// Drop the detector's sample history.
    ///
    /// Called after a recovery pass so the next episode counts from zero instead
    /// of inheriting samples taken against a graph that no longer exists.
    func resetCoreAudioDetector() {
        coreAudioDetector.reset()
        cancelRebuildRecheck()
    }

    func resetDebounce() {
        lastHandledDeviceID = 0
        lastHandledTime = .distantPast
    }

    /// 初次查询失败后执行一次有界重查，不把失败发布成空列表。
    func scheduleInitialDeviceRecheck() {
        scheduleRebuildRecheck(allowRoutingChanges: true)
    }

    func beginRecoveryReconciliation() {
        cancelRebuildRecheck()
    }

    func recoveryReconciliationSnapshot() -> UInt64 { proxyManager.lifecycleGate.recoverySnapshot() }

    func finishRecoveryReconciliation(ifUnchanged generation: UInt64) -> Bool {
        proxyManager.lifecycleGate.finishRecovery(ifUnchanged: generation)
    }

    func abandonRecoveryReconciliation() {
        guard !hasStopped else { return }
        // 失败或重试耗尽后仍重新读取设备与默认输出，不把恢复期间事件丢掉。
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasStopped, !self.proxyManager.isRecovering else { return }
            self.handleDeviceListChanged(allowRoutingChanges: false)
            // 失败后的收敛只观察默认输出，不把它当作新的用户选择。
            _ = self.proxyManager.refreshSystemDefaultOutput()
        }
    }

    /// P2 Batch 2 made these three entry points internal instead of fileprivate
    /// so `DefaultOutputGovernanceTests` can deliver the same notifications the
    /// HAL callbacks deliver. The callbacks stay the only production caller.
    func captureDeviceEventToken() -> UInt64? { proxyManager.lifecycleGate.captureEventToken() }

    /// 先准备新映射再发布设备集合；移除延迟到 Driver 有机会看到更新之后。
    func publishRecoveryDevices(_ devices: [PhysicalDevice], canProceed: () -> Bool) -> Bool {
        guard !hasStopped, canProceed() else { return false }
        let newUIDs = Set(devices.map { $0.uid })
        let removed = registry.devices.filter { !newUIDs.contains($0.uid) }.compactMap { device in
            memoryManager.acquireMemory(for: device.uid).map { (device.uid, $0.generation) }
        }
        for device in devices where memoryManager.acquireMemory(for: device.uid) == nil {
            guard canProceed(), memoryManager.createMemory(for: device.uid, persistence: proxyManager.volumePersistence) != nil else {
                return false
            }
        }
        guard canProceed(), !hasStopped, registry.update(devices) else { return false }
        if !removed.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + SoundBridgeConfig.cleanupWaitTimeout) { [weak self] in
                guard let self, !self.hasStopped else { return }
                for (uid, generation) in removed where self.registry.find(uid: uid) == nil {
                    self.memoryManager.removeMemory(for: uid, ifGeneration: generation)
                }
            }
        }
        return true
    }

    func handleDeviceListChanged(allowRoutingChanges: Bool = true, isRebuildProbe: Bool = false) {
        guard !hasStopped else { return }
        // The recovery pass enumerates, publishes and re-maps as one unit. A
        // notification delivered while it is running (the run loop is pumped
        // between attempts, so this is reachable) describes a graph that is
        // being replaced; letting the ordinary bookkeeping below act on it would
        // publish a transient list and create shared memory for devices that are
        // about to change UID.
        guard !proxyManager.isRecovering else {
            proxyManager.lifecycleGate.recordRecoveryEvent()
            logger.info("Device list changed during a CoreAudio recovery; reconciliation is pending")
            return
        }
        guard let token = proxyManager.lifecycleGate.normalToken() else { return }
        let canProceed = { !self.hasStopped && self.proxyManager.lifecycleGate.permitsNormal(token) }

        let oldDevices = registry.devices
        let enumeration = discovery.enumeratePhysicalDevicesWithStatus()
        guard canProceed() else { return }

        // Decide first whether this is a rebuild. Running the ordinary plug /
        // unplug bookkeeping against a graph that is being replaced writes a
        // device list the driver acts on, and is how a transient empty answer
        // used to remove every proxy.
        if let reason = observeHAL(enumeration, scheduleProbe: !isRebuildProbe,
                                   allowRoutingChangesForProbe: allowRoutingChanges) {
            confirmCoreAudioRestart(reason: reason, enumeration: enumeration)
            return
        }
        // 失败不是空列表；保留现有 Registry 和映射，等待有界探针或下一次事件。
        guard canProceed(), !enumeration.queryFailed else { return }

        let newDevices = enumeration.devices

        let addedDevices = newDevices.filter { new in
            !oldDevices.contains { $0.uid == new.uid }
        }
        let removedDevices = oldDevices.filter { old in
            !newDevices.contains { $0.uid == old.uid }
        }

        let startingFromIdle = hostState == .idle && !newDevices.isEmpty
        let enteringIdle = (hostState == .active || hostState == .degraded) && newDevices.isEmpty

        if startingFromIdle {
            let preferredDevice =
                proxyManager.resolveCurrentOutputDevice(in: newDevices)
                ?? newDevices.first!

            let sampleRate = discovery.getDeviceNominalSampleRate(preferredDevice.id)
            SoundBridgeConfig.activeSampleRate = sampleRate

            print(
                "[DeviceMonitor] Leaving idle mode: \(sampleRate) Hz " +
                "(from \(preferredDevice.name))"
            )
        }

        // 映射可能在上次发布失败时已部分创建，也可能因快速重插仍在延迟清理期。
        // 保留有效映射，补齐缺失映射后才发布；失败时保留旧快照并安排一次重查。
        let published = DeviceMappingPreparation.publishIfReady(
            uids: newDevices.map { $0.uid },
            canProceed: canProceed,
            hasMapping: { self.memoryManager.acquireMemory(for: $0) != nil },
            createMapping: {
                self.memoryManager.createMemory(for: $0, persistence: self.proxyManager.volumePersistence) != nil
            },
            publish: { self.registry.update(newDevices) }
        )
        guard published else {
            if canProceed(), !isRebuildProbe {
                logger.error("Device preparation or control publication failed; retaining the previous registry and scheduling one recheck")
                scheduleRebuildRecheck(allowRoutingChanges: allowRoutingChanges)
            }
            return
        }

        for device in addedDevices {
            print("Device added: \(device.name) (\(discovery.transportTypeName(device.transportType)))")
        }
        for device in removedDevices {
            print("Device removed: \(device.name) (\(discovery.transportTypeName(device.transportType)))")
        }

        // A new device may be the proxy we were waiting for when startup gave up.
        // Runs before the idle/active bookkeeping below so recovery is a single
        // path, not a special case bolted onto each branch.
        if hostState == .degraded && oldDevices.isEmpty && !newDevices.isEmpty {
            memoryManager.startHeartbeat()
        }
        if allowRoutingChanges && hostState == .degraded {
            logger.info("Device list changed while degraded; re-checking for the proxy device")
            onDegradedRecovery?()
        }

        if enteringIdle {
            print("[DeviceMonitor] No output devices remain; entering idle mode")

            audioEngine.stop()
            memoryManager.stopHeartbeat()
            setHostState(.idle)
            onNoPhysicalDevices?()
        }

        if startingFromIdle {
            // 物理设备出现不代表 Driver 已发布代理；先保持 degraded，
            // 由同一条代理恢复路径建立完整音频链路并发布 ready。
            memoryManager.startHeartbeat()
            setHostState(.degraded)
            onIdleDevicesAvailable?(allowRoutingChanges)
        }

        // 3. Delay shared memory removal for removed devices
        if !removedDevices.isEmpty {
            let removedMappings = removedDevices.compactMap { device in
                memoryManager.acquireMemory(for: device.uid).map { (device.uid, $0.generation) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + SoundBridgeConfig.cleanupWaitTimeout) {
                [weak self] in
                guard let self, !self.hasStopped else { return }
                for (uid, generation) in removedMappings where self.registry.find(uid: uid) == nil {
                    self.memoryManager.removeMemory(for: uid, ifGeneration: generation)
                }
            }
        }

        // NOTE: reloadDriver() removed — Darwin notifications replace manual reload
        // P2 Batch 2 removed the "wait for the proxy, then switch the default
        // output to it" step. A device appearing — a re-plugged HDMI or
        // DisplayPort monitor, a returning USB interface — is not a request to
        // make its proxy the default output. `audioEngine` keeps rendering on
        // the device the user chose.
    }

    func handleDefaultOutputChanged() {
        guard !hasStopped else { return }
        if proxyManager.isRecovering {
            proxyManager.lifecycleGate.recordRecoveryEvent()
            return
        }
        guard proxyManager.lifecycleGate.permitsNormal() else { return }
        // Skip during a CoreAudio rebuild: the notifications that arrive while
        // the object graph is being put back describe devices that are about to
        // be replaced, and acting on them starts a second recovery.
        guard !proxyManager.isRecovering else { return }

        // Read the answer through the same seam every other default-output
        // question goes through. A `nil` here means the query failed; a sample
        // with `uid == nil` means the device answered but has no UID.
        guard let sample = proxyManager.currentDefaultOutput() else {
            // A failed default-output read is the same evidence as a failed
            // device-list query: the system object is unreachable while the HAL
            // is being replaced. Ask the device list, which carries the answer.
            let enumeration = discovery.enumeratePhysicalDevicesWithStatus()
            if let reason = observeHAL(enumeration) {
                confirmCoreAudioRestart(reason: reason, enumeration: enumeration)
            }
            return
        }
        guard let uid = sample.uid else { return }
        let deviceID = sample.deviceID

        // Record what the system says, every time, before any routing decision.
        // `device-state.json`'s default-output field is this value and nothing
        // else, so it cannot drift from CoreAudio's answer.
        recordSystemDefaultOutput(uid)

        // Debounce: skip if same device within cooldown period
        let now = Date()
        if deviceID == lastHandledDeviceID && now.timeIntervalSince(lastHandledTime) < callbackDebounce {
            return
        }
        lastHandledDeviceID = deviceID
        lastHandledTime = now

        print("Default output changed: \(uid)")

        if uid.hasSuffix("-soundbridge") {
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
            // A physical device is the default output. That is the user's
            // choice; the Host follows it instead of undoing it.
            proxyManager.notePhysicalSelection(uid)

            if let physical = registry.find(uid: uid) {
                do {
                    try audioEngine.switchDevice(physical.id)
                } catch {
                    logger.error("Failed to switch audio engine device: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - CoreAudio rebuild detection

    /// Feed one HAL observation to the detector.
    ///
    /// - Returns: the reason, when a rebuild is confirmed. `nil` for an ordinary
    ///   plug or unplug, and for a suspicion that still needs another sample.
    private func observeHAL(_ enumeration: PhysicalDeviceEnumeration, scheduleProbe: Bool = true,
                            allowRoutingChangesForProbe: Bool = true) -> String? {
        let routing: ExpectedRouting?
        if !enumeration.queryFailed, let physicalUID = proxyManager.managedProxyUID {
            routing = ExpectedRouting(
                physicalUID: physicalUID,
                physicalStillPresent: enumeration.devices.contains { $0.uid == physicalUID },
                proxyPresent: proxyManager.findProxyDevice(forPhysicalUID: physicalUID) != nil
            )
        } else {
            // Not routing: a missing proxy says nothing about CoreAudio.
            routing = nil
        }

        let observation = CoreAudioObservation(
            deviceListQueryFailed: enumeration.queryFailed,
            deviceListQueryStatus: enumeration.queryStatus,
            physicalDeviceCount: enumeration.devices.count,
            routing: routing
        )

        switch coreAudioDetector.observe(observation) {
        case .none:
            cancelRebuildRecheck()
            return nil
        case .suspected:
            if scheduleProbe { scheduleRebuildRecheck(allowRoutingChanges: allowRoutingChangesForProbe) }
            return nil
        case .confirmed(let reason):
            cancelRebuildRecheck()
            return reason
        }
    }

    /// Take the second sample the two-sample rule needs.
    ///
    /// The rule is deliberately conservative, and it assumes a second device
    /// notification will arrive. Usually one does — deactivating the proxies is
    /// itself a device-list change — but a HAL that rebuilds quietly can leave
    /// the Host holding a single suspect sample forever, which is the very
    /// symptom this phase must not reproduce. So exactly one bounded re-check is
    /// scheduled per suspect sample. It is not a poll loop: it runs once, it
    /// feeds the same detector, and a cleared condition resets the counter.
    private func scheduleRebuildRecheck(allowRoutingChanges: Bool) {
        pendingRebuildRecheck?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasStopped, !self.proxyManager.isRecovering else { return }
            self.pendingRebuildRecheck = nil
            // 若首次查询失败，重查成功后还须执行普通设备收敛；不可反复安排探针。
            self.handleDeviceListChanged(allowRoutingChanges: allowRoutingChanges, isRebuildProbe: true)
        }
        pendingRebuildRecheck = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SoundBridgeConfig.coreAudioRebuildRecheckDelay,
            execute: work
        )
    }

    private func cancelRebuildRecheck() {
        pendingRebuildRecheck?.cancel()
        pendingRebuildRecheck = nil
    }

    /// Hand a confirmed rebuild to whoever owns the recovery flow.
    ///
    /// The registry is deliberately not rewritten here. A device list read while
    /// the HAL is being replaced is not the machine's answer, and the driver
    /// acts on whatever this Host publishes — so publishing it is exactly the
    /// step that used to remove every proxy. Recovery enumerates again once the
    /// graph is usable, and publishes then.
    private func confirmCoreAudioRestart(reason: String, enumeration: PhysicalDeviceEnumeration?) {
        let count = enumeration.map { String($0.devices.count) } ?? "unknown"
        logger.error(
            "HAL object graph looks rebuilt (\(reason, privacy: .public), physicalDevices=\(count, privacy: .public))"
        )

        guard let handler = onCoreAudioRestart else {
            logger.warning("No CoreAudio restart handler installed; the rebuild will not be recovered")
            return
        }
        handler(reason)
    }

    /// Publish what CoreAudio says the default output is, once.
    ///
    /// The registry holds the value; this only avoids rewriting the file while
    /// the answer has not moved.
    private func recordSystemDefaultOutput(_ uid: String) {
        guard registry.systemDefaultOutputUID != uid else { return }
        registry.systemDefaultOutputUID = uid
        registry.writeDeviceStateFile()
        logger.info("System default output is now \(uid, privacy: .public)")
    }

    func deliverDeviceNotification(token: UInt64?) {
        guard !hasStopped else { return }
        if let token {
            guard proxyManager.lifecycleGate.permitsNormal(token) else { return }
            handleDeviceListChanged()
        } else if proxyManager.isRecovering {
            // 事件已在 HAL 回调投递前记录。
            return
        } else if proxyManager.lifecycleGate.permitsNormal() {
            handleDeviceListChanged(allowRoutingChanges: false)
        }
    }

    func deliverDefaultOutputNotification(token: UInt64?) {
        guard !hasStopped else { return }
        if let token {
            guard proxyManager.lifecycleGate.permitsNormal(token) else { return }
            handleDefaultOutputChanged()
        } else if proxyManager.isRecovering {
            // 事件已在 HAL 回调投递前记录。
            return
        } else if proxyManager.lifecycleGate.permitsNormal() {
            // 恢复期间的事件只重新读取，不将用户选择转换为自动切换。
            _ = proxyManager.refreshSystemDefaultOutput()
        }
    }

    // Phase 2.1.4 removed `reloadDriver()`: it printed "restart coreaudiod with:
    // sudo killall coreaudiod" and was never called. The Darwin notifications the
    // class already subscribes to are what make a reload unnecessary, so the only
    // thing the function could still do was tell a future reader that restarting
    // the system audio daemon is part of this path. It is not.

    // P2 Batch 2 removed `getDeviceName(_:)` and `getDeviceUID(_:)`. They were
    // private duplicates of the two HAL reads `DefaultOutputHAL` already answers,
    // and having DeviceMonitor ask the HAL directly kept the default-output
    // notification path outside the seam `DefaultOutputGovernanceTests` drives.
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

    let monitor = Unmanaged<DeviceMonitor>
        .fromOpaque(clientData)
        .takeUnretainedValue()

    let token = monitor.captureDeviceEventToken()
    DispatchQueue.main.async {
        monitor.deliverDeviceNotification(token: token)
    }

    return noErr
}

private func defaultOutputChangedCallbackC(
    _ objectID: AudioObjectID,
    _ numAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }

    let monitor = Unmanaged<DeviceMonitor>
        .fromOpaque(clientData)
        .takeUnretainedValue()

    let token = monitor.captureDeviceEventToken()
    DispatchQueue.main.async {
        monitor.deliverDefaultOutputNotification(token: token)
    }

    return noErr
}
