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
         hal: DefaultOutputHAL = CoreAudioDefaultOutputHAL()) {
        self.registry = registry
        self.volumePersistence = volumePersistence
        self.lifecycleGate = lifecycleGate
        self.hal = hal
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

    private func getDeviceVolume(_ deviceID: AudioDeviceID) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Try getting master volume
        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0
            var dataSize = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &volume
            )
            if status == noErr {
                return volume
            }
        }

        // Try getting channel 1 volume (left channel)
        address.mElement = 1
        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0
            var dataSize = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &volume
            )
            if status == noErr {
                return volume
            }
        }

        return nil
    }

    private func setDeviceVolume(_ deviceID: AudioDeviceID, volume: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Try setting master volume
        if AudioObjectHasProperty(deviceID, &address) {
            var vol = volume
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &vol
            )
            if status == noErr {
                return true
            }
        }

        // Try setting per-channel volume (channel 1 and 2) if master failed
        var channelSet = false
        for channel: UInt32 in 1...2 {
            address.mElement = channel
            if AudioObjectHasProperty(deviceID, &address) {
                var vol = volume
                let status = AudioObjectSetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float32>.size),
                    &vol
                )
                if status == noErr {
                    channelSet = true
                }
            }
        }

        return channelSet
    }

    private func startVolumeForwarding(proxyDeviceID: AudioDeviceID) {
        if monitoredProxyDeviceID == proxyDeviceID {
            return
        }

        stopVolumeForwarding()
        monitoredProxyDeviceID = proxyDeviceID
        monitoredVolumeElements.removeAll(keepingCapacity: true)
        volumeForwardQueue.async { [weak self] in
            self?.lastForwardedProxyVolume = nil
        }

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
            volumeForwardQueue.async { [weak self] in
                self?.lastForwardedProxyVolume = nil
            }
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

        enqueueProxyVolumeForward()
    }

    fileprivate func handleProxyMuteChanged(from objectID: AudioObjectID) {
        guard let token = lifecycleGate.normalToken(), monitoredProxyDeviceID == objectID, activeProxyDeviceID == objectID else {
            return
        }

        let proxyDeviceID = activeProxyDeviceID
        let physicalDeviceID = activePhysicalDeviceID
        guard proxyDeviceID != 0, physicalDeviceID != 0 else { return }

        volumeForwardQueue.async { [weak self] in
            guard let self, self.lifecycleGate.permitsNormal(token) else { return }
            self.forwardProxyMuteToPhysical(proxyDeviceID: proxyDeviceID, physicalDeviceID: physicalDeviceID)
        }
    }

    private func mayForwardToPhysical(proxyDeviceID: AudioDeviceID, physicalDeviceID: AudioDeviceID) -> Bool {
        guard lifecycleGate.permitsNormal(), proxyDeviceID == activeProxyDeviceID,
              physicalDeviceID == activePhysicalDeviceID, let uid = activeProxyUID else { return false }
        return DefaultOutputPolicy.mayForwardVolume(current: currentDefaultOutputOwner(), physicalUID: uid)
    }

    private func forwardProxyMuteToPhysical(proxyDeviceID: AudioDeviceID, physicalDeviceID: AudioDeviceID) {
        guard mayForwardToPhysical(proxyDeviceID: proxyDeviceID, physicalDeviceID: physicalDeviceID),
              let muted = getDeviceMute(proxyDeviceID),
              mayForwardToPhysical(proxyDeviceID: proxyDeviceID, physicalDeviceID: physicalDeviceID) else { return }
        _ = setDeviceMute(physicalDeviceID, muted: muted)

        // Persist mute state for the physical device
        if let physicalUID = activeProxyUID {
            let volume = getDeviceVolume(proxyDeviceID) ?? VolumePersistence.defaultVolume
            volumePersistence.save(uid: physicalUID, volume: volume, muted: muted)
        }
    }

    private func getDeviceMute(_ deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &muted) == noErr else { return nil }
        return muted != 0
    }

    private func setDeviceMute(_ deviceID: AudioDeviceID, muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
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
        let restored = setDeviceVolume(proxyDeviceID, volume: state.volumeScalar)
        let muteRestored = setDeviceMute(proxyDeviceID, muted: state.isMuted)
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

        let proxyID = activeProxyDeviceID
        let physicalID = activePhysicalDeviceID
        volumeForwardQueue.async { [weak self] in
            guard let self, self.lifecycleGate.permitsNormal(token) else { return }
            self.forwardProxyMuteToPhysical(proxyDeviceID: proxyID, physicalDeviceID: physicalID)
        }

        if attempt > 1 {
            logger.info("Volume and mute listeners re-registered after wake (attempt \(attempt))")
        } else {
            logger.info("Volume and mute listeners re-registered after wake")
        }
    }

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

    private func forwardProxyVolumeToPhysical(
        proxyDeviceID: AudioDeviceID,
        physicalDeviceID: AudioDeviceID,
        force: Bool = false
    ) {
        guard mayForwardToPhysical(proxyDeviceID: proxyDeviceID, physicalDeviceID: physicalDeviceID),
              let proxyVolume = getDeviceVolume(proxyDeviceID) else { return }

        if !force, let lastForwardedProxyVolume, abs(proxyVolume - lastForwardedProxyVolume) < volumeForwardEpsilon {
            return
        }
        guard mayForwardToPhysical(proxyDeviceID: proxyDeviceID, physicalDeviceID: physicalDeviceID) else { return }

        lastForwardedProxyVolume = proxyVolume
        _ = setDeviceVolume(physicalDeviceID, volume: proxyVolume)

        // Persist volume state for the physical device
        if let physicalUID = activeProxyUID {
            let muted = getDeviceMute(proxyDeviceID) ?? false
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
