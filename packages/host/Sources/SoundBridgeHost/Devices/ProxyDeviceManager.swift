import Foundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "ProxyDeviceManager")

class ProxyDeviceManager {
    private let registry: DeviceRegistry
    let lifecycleGate: HostLifecycleGate
    /// Every CoreAudio question about the default output goes through this.
    ///
    /// The Host only reads through it. P2 Batch 2 removed every write — no
    /// startup, reconnect, recovery, device callback or shutdown path calls
    /// `setDefaultOutput(_:)` — and `DefaultOutputGovernanceTests` installs a
    /// recorder here so a regression that puts one back fails a test instead of
    /// silently moving a user's audio.
    private let hal: DefaultOutputHAL
    /// Every read and write of a device's own volume/mute goes through this.
    ///
    /// Held to the same rule as `hal`: it is the only seam that touches those
    /// properties, so `ProxyVolumeCommitTests` can drive the commit path
    /// without the machine's audio hardware.
    private let volumeHAL: DeviceVolumeHAL
    /// Whether a CoreAudio rebuild is being recovered.
    ///
    /// DeviceMonitor must not act on default-output notifications while the
    /// object graph is being rebuilt: the notifications are about devices that
    /// are being replaced, and reacting to them would start a second recovery.
    private(set) var isRecovering = false
    private var monitoredProxyDeviceID: AudioDeviceID?
    private var monitoredVolumeElements: [UInt32] = []
    private var monitoredMuteRegistered = false
    // 与 Recovery、Shutdown 和路由操作串行，避免后台音量写入越过停止边界。
    private let volumeForwardQueue = DispatchQueue.main
    private let volumeForwardEpsilon: Float32 = 0.001
    private var lastForwardedProxyVolume: Float32?
    /// The last state this Host successfully pushed into shared memory.
    ///
    /// Only successful commits are recorded, so a mapping that was missing (or
    /// refused the write) is retried on the next notification instead of being
    /// remembered as done. Cleared whenever the monitored device changes.
    private var lastCommittedProxyState: ProxyVolumeCommit?
    let volumePersistence: VolumePersistence

    /// The physical device whose proxy this Host is routing through.
    ///
    /// Phase 6A split this from the system default output. The two disagree
    /// exactly when the user is listening somewhere else, and conflating them
    /// is what made a reconnect drag the output back to a proxy the user had
    /// already left. `didSet` therefore publishes `managedProxyUID`, not
    /// `activeDeviceUID`.
    var managedProxyUID: String? {
        didSet {
            guard managedProxyUID != oldValue else { return }
            registry.managedProxyUID = managedProxyUID
            registry.writeDeviceStateFile()
            // The render callback must not read this property: it is a String,
            // so every read would be an ARC retain/release pair on the audio
            // thread. Publishing the new UID here keeps that work on whichever
            // control thread changed the routing.
            onManagedProxyChanged?(managedProxyUID)
        }
    }

    /// Called on the thread that changes the routing, once per change.
    ///
    /// `main.swift` points this at `SharedMemoryManager.setPreferredRenderUID`,
    /// which republishes the mapping the render callback reads.
    var onManagedProxyChanged: ((String?) -> Void)?

    /// Called once per accepted volume/mute change, so the state can be
    /// committed to shared memory.
    ///
    /// `main.swift` points this at `SharedMemoryManager.publishVolumeState`,
    /// which bumps `state_revision` and latches `state_initialized`. The return
    /// value is whether the mapping accepted the write; `false` means the
    /// change is not yet committed and must be retried on the next change.
    ///
    /// Deliberately separate from `onManagedProxyChanged`: routing answers
    /// "which mapping does the render path read", this answers "what does the
    /// mapping say the volume is".
    var onProxyVolumeStateCommitted: ((String, Float, Bool) -> Bool)?

    /// Pre-Phase-6A name for `managedProxyUID`.
    ///
    /// Kept as an alias rather than renamed at every call site: the render path
    /// and the response builders read the same fact, and two names for one
    /// stored property is a rename, not a second state source.
    var activeProxyUID: String? {
        get { managedProxyUID }
        set { managedProxyUID = newValue }
    }

    var activePhysicalDeviceID: AudioDeviceID = 0
    var activeProxyDeviceID: AudioDeviceID = 0

    init(registry: DeviceRegistry, volumePersistence: VolumePersistence = VolumePersistence(),
         lifecycleGate: HostLifecycleGate = HostLifecycleGate(),
         hal: DefaultOutputHAL = CoreAudioDefaultOutputHAL(),
         volumeHAL: DeviceVolumeHAL = CoreAudioDeviceVolumeHAL()) {
        self.registry = registry
        self.volumePersistence = volumePersistence
        self.lifecycleGate = lifecycleGate
        self.hal = hal
        self.volumeHAL = volumeHAL
    }

    deinit {
        stopVolumeForwarding()
    }

    // MARK: - Ownership of the default output

    /// Classify what the system default output currently is.
    ///
    /// Reads CoreAudio every time rather than trusting a cached value: the
    /// whole point is to answer "where is the audio going right now", and a
    /// cache is what produced the wrong answer in 1.2.0.
    func currentDefaultOutputOwner() -> DefaultOutputOwner {
        guard let deviceID = hal.defaultOutputDevice() else { return .unknown }
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else { return .none }
        let uid = hal.deviceUID(deviceID)
        let managed = Set(registry.devices.map { $0.uid })
        return DefaultOutputPolicy.owner(uid: uid, managedPhysicalUIDs: managed)
    }

    /// The UID of the system default output, or `nil` when the query failed.
    func currentDefaultOutputUID() -> String? {
        guard let deviceID = hal.defaultOutputDevice() else { return nil }
        return hal.deviceUID(deviceID)
    }

    /// One sample of "where is the audio going", including the device the HAL
    /// reports so callers can debounce on it.
    ///
    /// `nil` only when the HAL refuses the query; a device whose UID cannot be
    /// read comes back with `uid == nil`, which is a different fact. DeviceMonitor
    /// treats the first as rebuild evidence and the second as nothing to act on,
    /// and it reads through this seam for the same reason it writes through it:
    /// one place answers every default-output question.
    struct CurrentDefaultOutput: Equatable {
        var deviceID: AudioDeviceID
        var uid: String?
    }

    func currentDefaultOutput() -> CurrentDefaultOutput? {
        guard let deviceID = hal.defaultOutputDevice() else { return nil }
        return CurrentDefaultOutput(deviceID: deviceID, uid: hal.deviceUID(deviceID))
    }

    /// Publish what CoreAudio says the default output is.
    ///
    /// Called on every default-output notification and after every recovery
    /// pass, so `device-state.json` cannot drift from the system's answer.
    @discardableResult
    func refreshSystemDefaultOutput() -> String? {
        let uid = currentDefaultOutputUID()
        if registry.systemDefaultOutputUID != uid {
            registry.systemDefaultOutputUID = uid
            registry.writeDeviceStateFile()
        }
        return uid
    }

    // MARK: - CoreAudio rebuild

    /// Forget every AudioObjectID this manager holds.
    ///
    /// A `coreaudiod` restart invalidates all of them; keeping one and calling
    /// a setter with it produces `kAudioHardwareBadObjectError` (560947818 on
    /// the machine this was found on) and, worse, made the Host believe it was
    /// still routed through a device that no longer existed.
    func invalidateDeviceReferences() {
        stopVolumeForwarding()
        activeProxyDeviceID = 0
        activePhysicalDeviceID = 0
        lastForwardedProxyVolume = nil
    }

    /// What a rebuild left to re-establish, without changing the user's output.
    struct RemapResult: Equatable {
        var managedPhysicalUID: String?
        var proxyDeviceID: AudioDeviceID
        var physicalDeviceID: AudioDeviceID
        var proxyPresent: Bool
        var systemDefaultOutputUID: String?
        /// The default output is the proxy this Host just re-mapped.
        var defaultIsProxy: Bool
    }

    /// Re-resolve every held ID after CoreAudio rebuilt its object graph.
    ///
    /// Deliberately does **not** touch the default output: a recovery
    /// restores objects, listeners and volume state, and a reconnect restores
    /// connections — neither is a request to re-assert ownership of the default
    /// output. If the system is back on the proxy, it stays there; if the user
    /// is listening somewhere else, that choice survives.
    @discardableResult
    func remapAfterCoreAudioRebuild(in devices: [PhysicalDevice]) -> RemapResult {
        invalidateDeviceReferences()

        let defaultUID = currentDefaultOutputUID()
        registry.systemDefaultOutputUID = defaultUID

        let owner = DefaultOutputPolicy.owner(
            uid: defaultUID,
            managedPhysicalUIDs: Set(devices.map { $0.uid })
        )

        // 仅选择内部路由目标；旧设备消失后可映射新设备，但不更改默认输出。
        let candidateUID = DefaultOutputPolicy.recoveryTarget(
            current: owner, previousUID: managedProxyUID, availableUIDs: devices.map { $0.uid }
        )

        guard let physicalUID = candidateUID,
              let physical = devices.first(where: { $0.uid == physicalUID }),
              let proxyID = findProxyDevice(forPhysicalUID: physicalUID) else {
            // Nothing to route through yet. The driver may still be creating
            // the proxy; the caller retries.
            registry.writeDeviceStateFile()
            return RemapResult(
                managedPhysicalUID: nil,
                proxyDeviceID: 0,
                physicalDeviceID: 0,
                proxyPresent: false,
                systemDefaultOutputUID: defaultUID,
                defaultIsProxy: false
            )
        }

        managedProxyUID = physicalUID
        activePhysicalDeviceID = physical.id
        activeProxyDeviceID = proxyID
        startVolumeForwarding(proxyDeviceID: proxyID)
        restoreVolumeState(proxyDeviceID: proxyID, physicalUID: physicalUID)
        registry.writeDeviceStateFile()

        let defaultIsProxy = owner.isProxy(of: physicalUID)
        logger.notice(
            "Remapped after rebuild: physical=\(physicalUID, privacy: .public) proxy=\(proxyID) defaultIsProxy=\(defaultIsProxy, privacy: .public)"
        )
        return RemapResult(
            managedPhysicalUID: physicalUID,
            proxyDeviceID: proxyID,
            physicalDeviceID: physical.id,
            proxyPresent: true,
            systemDefaultOutputUID: defaultUID,
            defaultIsProxy: defaultIsProxy
        )
    }

    /// Mark a recovery as in flight so notification handling stands down.
    func beginRecovery() {
        isRecovering = true
    }

    /// Release the recovery latch. Must run on every exit path.
    func endRecovery() {
        isRecovering = false
    }

    func findProxyDevice(forPhysicalUID physicalUID: String) -> AudioDeviceID? {
        hal.deviceID(forUID: physicalUID + "-soundbridge")
    }

    // P2 Batch 2 removed `setDefaultOutputDevice`, `bounceDevice`,
    // `setDefaultOnly` and `setDefaultAndSystemDevice` from this class. A bounce
    // changed the system default output twice, on a lifecycle event, and the
    // App's "Reconnect Audio" button was reaching it — the exact behaviour this
    // batch exists to end. A reconnect now re-establishes the Host's own route
    // (`remapAfterCoreAudioRebuild`) and leaves the default output where the
    // user put it. `DefaultOutputGovernanceTests` drives startup, reconnect,
    // recovery, device callbacks and shutdown through this class and asserts no
    // write was requested.

    /// What `resolveProxyRouting(forPhysicalUID:)` achieved.
    ///
    /// It used to return `Void` while logging failures at warning level, which is
    /// how startup reported success with no audio path: every early return was
    /// indistinguishable from the successful path. P2 Batch 2 replaced the old
    /// `switch`/`alreadyOnProxy` pair with one `routed` case carrying the fact
    /// that mattered: whether macOS is *also* sending audio through the proxy.
    enum ProxyRoutingOutcome: Equatable {
        /// The driver's proxy for `physicalUID` is now the Host's route.
        /// `defaultOutputIsProxy` says whether macOS is sending audio to it too;
        /// `false` is a supported state, not a failure.
        case routed(proxyDeviceID: AudioDeviceID, defaultOutputIsProxy: Bool)
        /// The lifecycle forbids work right now: stopping, or a recovery pass.
        case lifecycleBlocked
        /// `physicalUID` is not a device this Host has a mapping for.
        case notManagedDevice
        /// The driver has not published a proxy device for this device yet.
        case proxyDeviceMissing

        /// Whether the Host has an audio path to configure.
        var isRoutable: Bool {
            if case .routed = self { return true }
            return false
        }

        /// Whether macOS is currently sending audio through that proxy.
        var isDefaultOutput: Bool {
            if case .routed(_, let isDefault) = self { return isDefault }
            return false
        }

        /// One line for logs and for the lifecycle snapshot's `detail`.
        var diagnostic: String {
            switch self {
            case .routed(let id, let isDefault):
                return isDefault
                    ? "routed through proxy \(id), which is also the system default output"
                    : "routed through proxy \(id); the system default output is elsewhere and was left alone"
            case .lifecycleBlocked:
                return "the lifecycle does not permit routing right now"
            case .notManagedDevice:
                return "the target is not a device this Host manages"
            case .proxyDeviceMissing:
                return "the driver's proxy device is not in the HAL device list"
            }
        }
    }

    /// Resolve the Host's proxy route for `physicalUID`.
    ///
    /// This is the startup / recovery entry point, and it deliberately takes the
    /// device it should route *for* instead of asking which device is the system
    /// default: the default output is not this Host's to choose. It reads the
    /// default output only to report where the audio is actually going.
    ///
    /// Nothing in here writes the default output. The one caller that used to
    /// (the old `autoSelectProxy`) was removed in P2 Batch 2.
    @discardableResult
    func resolveProxyRouting(forPhysicalUID physicalUID: String) -> ProxyRoutingOutcome {
        guard lifecycleGate.permitsNormal(), !isRecovering else { return .lifecycleBlocked }
        guard let physicalDevice = registry.find(uid: physicalUID) else {
            logger.info("Routing target \(physicalUID, privacy: .public) is not a device this Host manages")
            return .notManagedDevice
        }
        guard let proxyID = findProxyDevice(forPhysicalUID: physicalUID) else {
            logger.warning("No proxy device for \(physicalUID, privacy: .public) yet")
            return .proxyDeviceMissing
        }

        activeProxyUID = physicalUID
        activePhysicalDeviceID = physicalDevice.id
        activeProxyDeviceID = proxyID
        startVolumeForwarding(proxyDeviceID: proxyID)
        enqueueProxyVolumeForward(force: true)
        restoreVolumeState(proxyDeviceID: proxyID, physicalUID: physicalUID)

        refreshSystemDefaultOutput()
        let isDefault = currentDefaultOutputOwner().isProxy(of: physicalUID)
        print("[Route] \(physicalDevice.name) via proxy \(proxyID); default output left untouched")
        logger.notice(
            "Proxy route resolved: physical=\(physicalUID, privacy: .public) proxy=\(proxyID) defaultOutputIsProxy=\(isDefault, privacy: .public)"
        )
        return .routed(proxyDeviceID: proxyID, defaultOutputIsProxy: isDefault)
    }

    /// Resolve the current output device to a physical device, if possible.
    /// If current output is a proxy, this also updates activeProxy* state.
    ///
    /// Read-only. It answers "where is the audio going", which is how startup
    /// picks the device to route for; it does not make that device the default.
    func resolveCurrentOutputDevice(in devices: [PhysicalDevice]) -> PhysicalDevice? {
        guard let currentDeviceID = hal.defaultOutputDevice(),
              let uid = hal.deviceUID(currentDeviceID),
              let name = hal.deviceName(currentDeviceID) else {
            return nil
        }

        if name.contains("SoundBridge") {
            if let physicalUID = uid.components(separatedBy: "-soundbridge").first,
               let physicalDevice = devices.first(where: { $0.uid == physicalUID }) {
                activeProxyUID = physicalUID
                activePhysicalDeviceID = physicalDevice.id
                activeProxyDeviceID = currentDeviceID
                return physicalDevice
            }
            return nil
        }

        return devices.first(where: { $0.uid == uid })
    }

    /// Adopt the routing state for a proxy the user just made the default output.
    ///
    /// Reached from `DeviceMonitor` when the default output *becomes* a proxy this
    /// Host publishes — in practice, the user picking SoundBridge in the App or
    /// in System Settings. It never writes: the change already happened, and
    /// this only brings the Host's own view of it up to date so volume can be
    /// forwarded.
    func handleProxySelection(_ proxyUID: String, deviceID: AudioDeviceID) {
        guard lifecycleGate.permitsNormal(), !isRecovering else { return }
        if let physicalUID = proxyUID.components(separatedBy: "-soundbridge").first,
           let physicalDevice = registry.find(uid: physicalUID) {
            print("Routing to: \(physicalDevice.name)")

            activeProxyUID = physicalUID
            activePhysicalDeviceID = physicalDevice.id
            activeProxyDeviceID = deviceID
            startVolumeForwarding(proxyDeviceID: deviceID)
            enqueueProxyVolumeForward(force: true)
            restoreVolumeState(proxyDeviceID: deviceID, physicalUID: physicalUID)
        } else {
            // The selected proxy has no physical mapping (stale/unplugged). Tear down forwarding state.
            stopVolumeForwarding()
            activeProxyUID = nil
            activePhysicalDeviceID = 0
            activeProxyDeviceID = 0
        }
    }

    /// Note that a physical device is currently the default output.
    ///
    /// This used to switch the default output back to the proxy for any device
    /// the Host manages. That is exactly what P2 Batch 2 removed: the user chose
    /// the physical output, and the Host's job is to stop assuming the audio is
    /// coming through the proxy — not to undo the choice. Picking the proxy again
    /// reaches `handleProxySelection`, which restores the forwarding state.
    ///
    /// `managedProxyUID` deliberately survives both branches: it says what this
    /// Host manages, not where the audio is going right now.
    func notePhysicalSelection(_ physicalUID: String) {
        guard lifecycleGate.permitsNormal(), !isRecovering else { return }

        if let physicalDevice = registry.find(uid: physicalUID) {
            logger.info(
                "Default output is the physical device \(physicalUID, privacy: .public) (\(physicalDevice.name, privacy: .public)); leaving the user's choice alone"
            )
        } else {
            logger.info(
                "Default output \(physicalUID, privacy: .public) is not a device this Host manages; nothing to route"
            )
        }

        // Forwarding is already gated on the proxy being the default output
        // (`mayForwardToPhysical`); dropping the listeners here also releases
        // the HAL resources for a device that is no longer in the audio path.
        stopVolumeForwarding()
        activeProxyDeviceID = 0
        activePhysicalDeviceID = 0
    }

    // P2 Batch 2 removed `restorePhysicalDevice()`. It put the physical device
    // back as the default output while the Host was shutting down — a lifecycle
    // event changing the user's default output, which is now forbidden.

    // The property getters that used to live here now belong to
    // `CoreAudioDefaultOutputHAL`, so that a test can answer them instead of
    // asking the machine.

    // The device volume/mute getters and setters that used to live here now
    // belong to `CoreAudioDeviceVolumeHAL`, so that a test can answer them
    // instead of asking the machine. Their probing order is unchanged.

    private func startVolumeForwarding(proxyDeviceID: AudioDeviceID) {
        if monitoredProxyDeviceID == proxyDeviceID {
            return
        }

        stopVolumeForwarding()
        monitoredProxyDeviceID = proxyDeviceID
        monitoredVolumeElements.removeAll(keepingCapacity: true)
        clearVolumeCaches()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // SAFETY: self 是 main.swift 中的全局 let 变量，生命周期与进程一致。
        // passUnretained 安全，因为 self 不会在回调存活期间被释放。
        // 如果未来改为非全局实例，必须改用 passRetained + 配对 release。
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Prefer a single master listener to avoid duplicate callback bursts.
        if AudioObjectHasProperty(proxyDeviceID, &address) {
            let status = AudioObjectAddPropertyListener(proxyDeviceID, &address, proxyVolumeChangedCallback, selfPtr)
            if status == noErr {
                monitoredVolumeElements.append(kAudioObjectPropertyElementMain)
            } else {
                logger.error("Failed to add master listener (OSStatus: \(status))")
            }
        }

        // Fallback to channel listeners only when master is unavailable.
        if monitoredVolumeElements.isEmpty {
            for channel: UInt32 in 1...2 {
                address.mElement = channel
                guard AudioObjectHasProperty(proxyDeviceID, &address) else { continue }
                let status = AudioObjectAddPropertyListener(proxyDeviceID, &address, proxyVolumeChangedCallback, selfPtr)
                if status == noErr {
                    monitoredVolumeElements.append(channel)
                } else {
                    logger.error("Failed to add listener for channel \(channel) (OSStatus: \(status))")
                }
            }
        }

        if monitoredVolumeElements.isEmpty {
            monitoredProxyDeviceID = nil
            logger.warning("No volume listener registered for proxy device \(proxyDeviceID)")
            return
        }

        // Register mute listener (mute key, distinct from volume scalar)
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(proxyDeviceID, &muteAddress) {
            let status = AudioObjectAddPropertyListener(proxyDeviceID, &muteAddress, proxyMuteChangedCallback, selfPtr)
            if status == noErr {
                monitoredMuteRegistered = true
            } else {
                logger.error("Failed to add mute listener (OSStatus: \(status))")
            }
        }
    }

    private func stopVolumeForwarding() {
        guard let proxyDeviceID = monitoredProxyDeviceID else { return }
        defer {
            monitoredProxyDeviceID = nil
            monitoredVolumeElements.removeAll(keepingCapacity: false)
            monitoredMuteRegistered = false
            clearVolumeCaches()
        }

        // SAFETY: self 是 main.swift 中的全局 let 变量，生命周期与进程一致。
        // passUnretained 安全，因为 self 不会在回调存活期间被释放。
        // 如果未来改为非全局实例，必须改用 passRetained + 配对 release。
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        for element in monitoredVolumeElements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            let status = AudioObjectRemovePropertyListener(proxyDeviceID, &address, proxyVolumeChangedCallback, selfPtr)
            if status != noErr {
                logger.error("Failed to remove listener for element \(element) (OSStatus: \(status))")
            }
        }

        if monitoredMuteRegistered {
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectRemovePropertyListener(proxyDeviceID, &muteAddress, proxyMuteChangedCallback, selfPtr)
            if status != noErr {
                logger.error("Failed to remove mute listener (OSStatus: \(status))")
            }
        }
    }

    fileprivate func handleProxyVolumeChanged(from objectID: AudioObjectID) {
        guard lifecycleGate.permitsNormal(), monitoredProxyDeviceID == objectID, activeProxyDeviceID == objectID else {
            return
        }

        // Commit before forwarding: forwarding is gated on the proxy being the
        // default output, committing never is.
        commitObservedProxyVolumeState()
        enqueueProxyVolumeForward()
    }

    fileprivate func handleProxyMuteChanged(from objectID: AudioObjectID) {
        guard let token = lifecycleGate.normalToken(), monitoredProxyDeviceID == objectID, activeProxyDeviceID == objectID else {
            return
        }

        commitObservedProxyVolumeState()
        enqueueProxyMuteForward(token: token)
    }

    // MARK: - Committing the state (P1-1)

    /// One volume/mute value this Host pushed into shared memory.
    private struct ProxyVolumeCommit: Equatable {
        var uid: String
        var scalar: Float
        var muted: Bool
    }

    /// How many times a commit re-reads the control before giving up on
    /// convergence. Two extra passes cover "the user moved the slider while the
    /// first value was being published"; a third would only be spin.
    private static let commitConvergencePasses = 3

    /// Commit the proxy's current volume and mute for the active route.
    ///
    /// Internal rather than private because the notification handlers are the
    /// only production callers but the work behind them does not need a live
    /// CoreAudio device: `ProxyVolumeCommitTests` calls this directly. It runs
    /// on the caller's thread, which for both callers is the main thread — the
    /// same queue `lastCommittedProxyState` is confined to.
    func commitObservedProxyVolumeState() {
        commitProxyVolumeState(
            proxyDeviceID: activeProxyDeviceID,
            physicalDeviceID: activePhysicalDeviceID
        )
    }

    /// Publish the proxy's current volume and mute into shared memory and onto
    /// disk, then forward them to the physical device.
    ///
    /// Committing and forwarding are deliberately separate steps:
    ///
    ///   - *Forwarding* the value to the physical device is only correct while
    ///     the proxy is the macOS default output, which is why
    ///     `forwardProxyVolumeToPhysical` is gated on
    ///     `DefaultOutputPolicy.mayForwardVolume`.
    ///   - *Committing* the value is always correct. The driver installs the
    ///     shared-memory mapping into `SoundBridgeVolumeControl` only from
    ///     `OnStartIO`, so a change made while nothing is playing reaches the
    ///     HAL control and stops there. The next `OnStartIO` handshake then
    ///     adopts the committed state and pushes it back into the control —
    ///     discarding the user's choice. That is exactly the 1.2.0 observation
    ///     "reapplying the setting during playback makes it take effect".
    private func commitProxyVolumeState(proxyDeviceID: AudioDeviceID, physicalDeviceID: AudioDeviceID,
                                        attempt: Int = 0) {
        guard lifecycleGate.permitsNormal(),
              proxyDeviceID == activeProxyDeviceID,
              physicalDeviceID == activePhysicalDeviceID,
              let uid = activeProxyUID,
              let scalar = volumeHAL.volume(proxyDeviceID) else { return }

        let muted = volumeHAL.muted(proxyDeviceID) ?? false

        guard !isAlreadyCommitted(uid: uid, scalar: scalar, muted: muted) else { return }

        // Persist first: the disk entry is what `VolumeStateResolver` prefers on
        // the next Host start, so it must not depend on the mapping existing.
        volumePersistence.save(uid: uid, volume: scalar, muted: muted)

        guard let accepted = onProxyVolumeStateCommitted?(uid, scalar, muted), accepted else {
            // Nothing recorded, so the next notification retries instead of
            // treating an uncommitted value as done.
            logger.error(
                "Volume state for \(uid, privacy: .public) could not be published to shared memory; the next change will retry"
            )
            return
        }
        lastCommittedProxyState = ProxyVolumeCommit(uid: uid, scalar: scalar, muted: muted)

        // Converge: a second change that landed while the first was being
        // published must not be left behind only in the control, because the
        // next handshake makes shared memory the authority.
        guard attempt + 1 < Self.commitConvergencePasses,
              let recheck = volumeHAL.volume(proxyDeviceID), recheck != scalar else { return }
        commitProxyVolumeState(
            proxyDeviceID: proxyDeviceID,
            physicalDeviceID: physicalDeviceID,
            attempt: attempt + 1
        )
    }

    private func isAlreadyCommitted(uid: String, scalar: Float, muted: Bool) -> Bool {
        guard let last = lastCommittedProxyState else { return false }
        return last.uid == uid && last.scalar == scalar && last.muted == muted
    }

    /// Forget the "already handled" memories when the monitored device changes.
    ///
    /// Both fields are read on `volumeForwardQueue`, so the reset hops onto that
    /// queue instead of writing across queues — the same ordering the previous
    /// inline `volumeForwardQueue.async` had.
    private func clearVolumeCaches() {
        volumeForwardQueue.async { [weak self] in
            self?.lastForwardedProxyVolume = nil
            self?.lastCommittedProxyState = nil
        }
    }

    private func mayForwardToPhysical(proxyDeviceID: AudioDeviceID, physicalDeviceID: AudioDeviceID) -> Bool {
        guard lifecycleGate.permitsNormal(), proxyDeviceID == activeProxyDeviceID,
              physicalDeviceID == activePhysicalDeviceID, let uid = activeProxyUID else { return false }
        return DefaultOutputPolicy.mayForwardVolume(current: currentDefaultOutputOwner(), physicalUID: uid)
    }

    private func forwardProxyMuteToPhysical(proxyDeviceID: AudioDeviceID, physicalDeviceID: AudioDeviceID) {
        guard mayForwardToPhysical(proxyDeviceID: proxyDeviceID, physicalDeviceID: physicalDeviceID),
              let muted = volumeHAL.muted(proxyDeviceID),
              mayForwardToPhysical(proxyDeviceID: proxyDeviceID, physicalDeviceID: physicalDeviceID) else { return }
        _ = volumeHAL.setMuted(physicalDeviceID, muted: muted)

        // Persist mute state for the physical device
        if let physicalUID = activeProxyUID {
            let volume = volumeHAL.volume(proxyDeviceID) ?? VolumePersistence.defaultVolume
            volumePersistence.save(uid: physicalUID, volume: volume, muted: muted)
        }
    }

    /// Restore persisted volume and mute state to a proxy device via HAL API.
    /// Called when a device connects or a proxy is selected.
    ///
    /// `override` lets the caller supply an already-committed state (for
    /// example one recovered from shared memory) instead of falling back to
    /// the persisted default. Without it a device that has no saved entry
    /// would be forced back to 0.35 and could clobber a recovered value.
    func restoreVolumeState(
        proxyDeviceID: AudioDeviceID,
        physicalUID: String,
        override: DeviceVolumeState? = nil
    ) {
        let state = override ?? volumePersistence.load(uid: physicalUID)
        let restored = volumeHAL.setVolume(proxyDeviceID, volume: state.volumeScalar)
        let muteRestored = volumeHAL.setMuted(proxyDeviceID, muted: state.isMuted)
        logger.info("Restored volume state for \(physicalUID): volume=\(String(format: "%.0f%%", state.volumeScalar * 100)), muted=\(state.isMuted) (vol:\(restored), mute:\(muteRestored))")
    }

    /// Re-register the proxy volume listener after sleep/wake.
    ///
    /// coreaudiod silently drops all AudioObjectAddPropertyListener registrations
    /// when it restarts (which happens on sleep/wake). Calling startVolumeForwarding
    /// directly would no-op if the proxy device ID is unchanged (the common case),
    /// so we force teardown first to clear monitoredProxyDeviceID and bypass that guard.
    ///
    /// Because coreaudiod may not be ready immediately after wake, this method retries
    /// registration with increasing delays if the initial attempt fails.
    func reregisterVolumeForwarding(attempt: Int = 1) {
        guard let token = lifecycleGate.normalToken() else { return }
        // stopVolumeForwarding clears monitoredProxyDeviceID, so the same-ID
        // early-return guard in startVolumeForwarding will not block re-registration.
        stopVolumeForwarding()

        guard activeProxyDeviceID != 0 else {
            print("[VolumeForward] No active proxy — skipping re-registration")
            return
        }

        startVolumeForwarding(proxyDeviceID: activeProxyDeviceID)

        if monitoredVolumeElements.isEmpty {
            if attempt < SoundBridgeConfig.wakeRetryMaxAttempts {
                let delay = SoundBridgeConfig.wakeRetryDelays[attempt]
                print("[VolumeForward] Listener registration failed (attempt \(attempt)/\(SoundBridgeConfig.wakeRetryMaxAttempts)) — retrying in \(delay)s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.lifecycleGate.permitsNormal(token) else { return }
                    self.reregisterVolumeForwarding(attempt: attempt + 1)
                }
            } else {
                logger.error("Listener registration failed after \(SoundBridgeConfig.wakeRetryMaxAttempts) attempts")
            }
            return
        }

        enqueueProxyVolumeForward(force: true)
        enqueueProxyMuteForward(token: token)

        if attempt > 1 {
            logger.info("Volume and mute listeners re-registered after wake (attempt \(attempt))")
        } else {
            logger.info("Volume and mute listeners re-registered after wake")
        }
    }

    /// One volume notification's work: forward the state to the physical device.
    ///
    /// Forwarding only — the commit happened in `handleProxyVolumeChanged`. This
    /// is also the entry point routing changes and wake recovery use, and those
    /// must not publish: `restoreVolumeState` writes the persisted value into
    /// the control, and the mapping may legitimately hold a newer recovered
    /// state that the driver's next `OnStartIO` handshake is about to apply.
    private func enqueueProxyVolumeForward(force: Bool = false) {
        guard let token = lifecycleGate.normalToken() else { return }
        let proxyDeviceID = activeProxyDeviceID
        let physicalDeviceID = activePhysicalDeviceID
        guard proxyDeviceID != 0, physicalDeviceID != 0 else {
            return
        }

        volumeForwardQueue.async { [weak self] in
            guard let self, self.lifecycleGate.permitsNormal(token) else { return }
            self.forwardProxyVolumeToPhysical(
                proxyDeviceID: proxyDeviceID,
                physicalDeviceID: physicalDeviceID,
                force: force
            )
        }
    }

    /// One mute notification's work: forward the mute flag to the physical device.
    private func enqueueProxyMuteForward(token: UInt64) {
        let proxyDeviceID = activeProxyDeviceID
        let physicalDeviceID = activePhysicalDeviceID
        guard proxyDeviceID != 0, physicalDeviceID != 0 else { return }

        volumeForwardQueue.async { [weak self] in
            guard let self, self.lifecycleGate.permitsNormal(token) else { return }
            self.forwardProxyMuteToPhysical(
                proxyDeviceID: proxyDeviceID,
                physicalDeviceID: physicalDeviceID
            )
        }
    }

    private func forwardProxyVolumeToPhysical(
        proxyDeviceID: AudioDeviceID,
        physicalDeviceID: AudioDeviceID,
        force: Bool = false
    ) {
        guard mayForwardToPhysical(proxyDeviceID: proxyDeviceID, physicalDeviceID: physicalDeviceID),
              let proxyVolume = volumeHAL.volume(proxyDeviceID) else { return }

        if !force, let lastForwardedProxyVolume, abs(proxyVolume - lastForwardedProxyVolume) < volumeForwardEpsilon {
            return
        }
        guard mayForwardToPhysical(proxyDeviceID: proxyDeviceID, physicalDeviceID: physicalDeviceID) else { return }

        lastForwardedProxyVolume = proxyVolume
        _ = volumeHAL.setVolume(physicalDeviceID, volume: proxyVolume)

        // Persist volume state for the physical device
        if let physicalUID = activeProxyUID {
            let muted = volumeHAL.muted(proxyDeviceID) ?? false
            volumePersistence.save(uid: physicalUID, volume: proxyVolume, muted: muted)
        }
    }
}

private func proxyVolumeChangedCallback(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let manager = Unmanaged<ProxyDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
    guard let token = manager.lifecycleGate.normalToken() else { return noErr }
    DispatchQueue.main.async {
        guard manager.lifecycleGate.permitsNormal(token) else { return }
        manager.handleProxyVolumeChanged(from: objectID)
    }
    return noErr
}

private func proxyMuteChangedCallback(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let manager = Unmanaged<ProxyDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
    guard let token = manager.lifecycleGate.normalToken() else { return noErr }
    DispatchQueue.main.async {
        guard manager.lifecycleGate.permitsNormal(token) else { return }
        manager.handleProxyMuteChanged(from: objectID)
    }
    return noErr
}
