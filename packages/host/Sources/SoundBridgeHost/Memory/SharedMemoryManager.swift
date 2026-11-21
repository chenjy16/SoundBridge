import Foundation
import Darwin
import CSoundBridgeAudio
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "SharedMemoryManager")

/// What `createMemory(for:)` found at the target path before it wrote anything.
///
/// Phase 2.1 requires the Host to tell these four situations apart instead of
/// blindly `unlink()`-ing whatever is there. The distinction is what lets a
/// crashed Host's committed volume survive a restart.
enum SharedMemoryOrigin: String {
    /// No file existed. A fresh mapping was created with seed defaults.
    case created

    /// A previous Host process left a *committed* state behind — it crashed or
    /// was killed instead of running `cleanup()`. The volume, mute and mode
    /// were carried over into the new mapping.
    case recoveredFromCrash

    /// A file existed with a valid header but no committed state. Replaced;
    /// there was nothing worth keeping.
    case replacedUninitialized

    /// A file existed but its protocol version, header size or length did not
    /// match this build. Replaced so we never read an unknown layout.
    case replacedIncompatible
}

/// 映射的租约；持有者完成访问后才解除映射。
final class SharedMemoryMapping {
    let memory: UnsafeMutablePointer<RFSharedAudio>
    let size: Int
    let device: dev_t
    let inode: ino_t
    let generation = UUID()

    init(memory: UnsafeMutablePointer<RFSharedAudio>, size: Int, device: dev_t, inode: ino_t) {
        self.memory = memory
        self.size = size
        self.device = device
        self.inode = inode
    }

    deinit {
        munmap(memory, size)
    }
}

class SharedMemoryManager {
    /// Resolves the shared-memory file path for a device UID.
    ///
    /// Production uses `/tmp/soundbridge-<uid>` via `PathManager`. Tests inject a
    /// throwaway directory so a fixture can never create, truncate or unlink a
    /// real file. The closure is the only seam; every path lookup below goes
    /// through it.
    private let pathForUID: (String) -> String

    init(
        sessionID: UUID? = nil,
        pathForUID: @escaping (String) -> String = { PathManager.sharedMemoryPath(uid: $0) }
    ) {
        self.sessionID = sessionID
        self.pathForUID = pathForUID
        self.renderGate = rf_rt_gate_create()
        self.renderPublishLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.renderPublishLock.initialize(to: os_unfair_lock())
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        // Nothing is published by now: `cleanup()` retired the render path, and
        // the retired mappings are released as properties.
        if let renderGate {
            rf_rt_gate_destroy(renderGate)
        }
        renderPublishLock.deinitialize(count: 1)
        renderPublishLock.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private var sessionID: UUID?

    /// 生产环境在取得实例锁之后、创建任何映射之前绑定会话。
    func beginSession(_ id: UUID) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        precondition(sessionID == nil && deviceMemory.isEmpty, "不能替换共享内存会话")
        sessionID = id
    }

    private var deviceMemory: [String: SharedMemoryMapping] = [:]
    /// How each mapping came to exist, for diagnostics and tests.
    private(set) var origins: [String: SharedMemoryOrigin] = [:]

    // MARK: - Render path (P2 Batch 4)

    /// What the audio callback reads: a pointer in a C11-atomic gate.
    ///
    /// P2 Batch 4 moved the callback off `acquireMemory(for:)` — a dictionary
    /// lookup under `lock`, a `String` read of `proxyManager.activeProxyUID`,
    /// and an ARC retain/release pair whose last release ran `munmap` on the
    /// real-time thread. What it left behind was an `os_unfair_lock` taken twice
    /// per block. That removed the work, not the wait: the holder can be a
    /// preempted control thread, and "the critical section is three
    /// instructions" bounds the holder's work, not the waiter's latency.
    ///
    /// P3 Batch 1.5 replaces it with `rf_rt_gate_*`: the callback performs one
    /// lock-free increment, one load, one lock-free decrement, and waits for
    /// nobody. Publication is still deferred while a callback is inside — the
    /// mapping lifecycle depends on that — but only the control thread spins.
    private let renderGate: OpaquePointer?

    /// Serialises control-thread publishers. The callback never takes it.
    ///
    /// Heap-allocated on purpose: `os_unfair_lock_lock(&someStoredProperty)`
    /// opens an exclusive (inout) access to the property *before* the lock is
    /// acquired, so two control threads doing it at once is a Swift exclusivity
    /// violation even though the lock itself serialises the critical sections.
    /// TSan reports that as a Swift access race; a pointer has no access
    /// markers to race on.
    private let renderPublishLock: UnsafeMutablePointer<os_unfair_lock>

    /// Held strongly while published: the mmap must outlive every reader, and
    /// an object reference is the least error-prone way to say that.
    private var renderMapping: SharedMemoryMapping?

    /// Mappings the gate can no longer hand out but a callback may still be
    /// using: the release is deferred until the gate reports no lease, which is
    /// what keeps `munmap` off the audio thread.
    private var retiredRenderMappings: [SharedMemoryMapping] = []

    /// How many `retireRenderPath` waits expired before the callback left.
    /// A non-zero value is the only runtime evidence that a render callback
    /// outlived the shutdown budget.
    private var renderRetireTimeouts: UInt64 = 0

    /// A publication that could not be applied because a callback was inside
    /// the old mapping. Retried by the heartbeat, never by the callback.
    private var renderPendingMapping: SharedMemoryMapping?
    private var renderPendingIsSet = false
    /// Which device's mapping should be published. Set by the owner of the
    /// routing decision, so the callback never has to ask.
    private var preferredRenderUID: String?
    private var heartbeatTimer: DispatchSourceTimer?
    private let heartbeatQueue = DispatchQueue(label: "com.soundbridge.host.heartbeat")
    private let heartbeatLock = NSLock()
    // 文件发布、删除与 cleanup 必须串行；音频回调不获取此锁。
    private let mutationLock = NSLock()
    private var isClosed = false
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // Telemetry: track last-seen underrun/overrun counts for delta logging
    private var lastUnderrunCounts: [String: UInt64] = [:]
    private var lastOverrunCounts: [String: UInt64] = [:]
    private var telemetryCounter: Int = 0

    func createMemory(for devices: [PhysicalDevice], persistence: VolumeStatePersisting) {
        logger.info("Creating shared memory for \(devices.count) devices")

        for device in devices {
            switch createMemory(for: device.uid, persistence: persistence) {
            case .some(.created):
                logger.info("Shared memory created for \(device.name)")
            case .some(.recoveredFromCrash):
                logger.warning("Shared memory for \(device.name) recovered committed volume state from a previous run")
            case .some(.replacedUninitialized):
                logger.info("Shared memory for \(device.name) was uninitialized; replaced")
            case .some(.replacedIncompatible):
                logger.warning("Shared memory for \(device.name) was incompatible; replaced")
            case .none:
                logger.error("Failed to create shared memory for \(device.name)")
            }
        }

        logger.info("Shared memory creation complete")
    }

    /// Create (or re-adopt) the mapping for `uid` and publish an initial
    /// volume state resolved from persistence and, failing that, from whatever
    /// a crashed Host left behind.
    ///
    /// Returns the origin, or `nil` if the mapping could not be created.
    @discardableResult
    func createMemory(for uid: String, persistence: VolumeStatePersisting) -> SharedMemoryOrigin? {
        print("[SoundBridgeHost] Creating shared memory for: \(uid)")

        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard !isClosed else {
            logger.warning("Cannot create shared memory after cleanup")
            return nil
        }
        os_unfair_lock_lock(lock)
        let session = sessionID
        os_unfair_lock_unlock(lock)
        guard let session else {
            logger.error("Cannot create shared memory without an active session")
            return nil
        }

        let shmPath = pathForUID(uid)
        print("[SoundBridgeHost] File: \(shmPath)")

        // Probe before destroying: this is the only chance to learn what the
        // previous process committed.
        let probe = probeExisting(path: shmPath)
        let origin = probe.origin

        // 在独立 inode 上完成初始化后才替换公开路径，读者不会看到半初始化的头。
        // 这不构成跨用户互斥，也不能使 Driver 已有的旧映射自动切换。
        let stagingPath = shmPath + ".tmp." + UUID().uuidString
        let fd = open(stagingPath, O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_RDWR, 0o666)
        guard fd >= 0 else {
            logger.error("Failed to create staging file: \(String(cString: strerror(errno)))")
            return nil
        }
        defer {
            close(fd)
            unlink(stagingPath)
        }
        guard fchmod(fd, 0o666) == 0 else {
            logger.error("Failed to set shared memory permissions: \(String(cString: strerror(errno)))")
            return nil
        }

        let sampleRate = SoundBridgeConfig.activeSampleRate
        // Ring capacity is rounded UP to a power of two (Batch 1 contract) so
        // the slot mask is exact. This must stay the SAME single source of
        // truth that rf_shared_audio_init uses internally — sizing the file
        // with the raw frame count would truncate the payload that init
        // writes a rounded-up capacity for.
        let frames = rf_ring_capacity_frames_for(
            sampleRate,
            SoundBridgeConfig.defaultDurationMs
        )
        let bytesPerSample = rf_bytes_per_sample(SoundBridgeConfig.defaultFormat)
        let shmSize = rf_shared_audio_size(
            frames,
            SoundBridgeConfig.defaultChannels,
            bytesPerSample
        )

        print("[SoundBridgeHost] Size: \(shmSize) bytes (\(frames) frames @ \(sampleRate)Hz)")

        guard ftruncate(fd, Int64(shmSize)) == 0 else {
            logger.error("Failed to set size: \(String(cString: strerror(errno)))")
            return nil
        }

        let mem = mmap(nil, shmSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mem != MAP_FAILED, let mem else {
            logger.error("mmap failed: \(String(cString: strerror(errno)))")
            return nil
        }
        var published = false
        defer {
            if !published { munmap(mem, shmSize) }
        }

        let sharedMem = mem.assumingMemoryBound(to: RFSharedAudio.self)

        rf_shared_audio_init(
            sharedMem,
            sampleRate,
            SoundBridgeConfig.defaultChannels,
            SoundBridgeConfig.defaultFormat,
            SoundBridgeConfig.defaultDurationMs
        )

        var uuid = session.uuid
        withUnsafeBytes(of: &uuid) { bytes in
            rf_set_host_session(sharedMem, bytes.bindMemory(to: UInt8.self).baseAddress!)
        }

        // Resolve in the documented priority order and commit once, so the
        // driver sees `state_initialized == 1` the first time OnStartIO runs.
        let resolution = VolumeStateResolver.resolve(
            persisted: persistence.loadIfPresent(uid: uid),
            recovered: probe.recovered
        )
        rf_publish_volume_state(
            sharedMem,
            resolution.scalar,
            resolution.muted,
            resolution.mode.protocolValue
        )

        // One-shot prefill (Batch 1): half a ring of silence BEFORE the
        // mapping is published. This realizes the frozen lifecycle
        // `Create -> Initialize -> Prefill -> Publish -> Producer Admission`:
        // the consumer never races the producer on cold start, the driver
        // never re-fills an ACTIVE mapping, and Stop -> Start does not touch
        // W/R. The staging inode is still private here, so no reader can
        // observe the ring mid-prefill.
        //
        // Batch 2 narrowed the entry point: this uses the pre-publish helper,
        // which refuses to write once admission is OPEN or an owner exists.
        // Re-running the prefill on a live mapping is therefore impossible,
        // not merely discouraged.
        let prefillFrames = sharedMem.pointee.ring_capacity_frames / 2
        if prefillFrames > 0 {
            let prefillSilence = [Float](
                repeating: 0.0, count: Int(prefillFrames) * Int(sharedMem.pointee.channels))
            var prefillDropped: UInt32 = 0
            let prefillWritten = rf_ring_prefill_before_publish(
                sharedMem, prefillSilence, prefillFrames, &prefillDropped)
            print("[SoundBridgeHost] Prefill: \(prefillWritten)/\(prefillFrames) frames (dropped \(prefillDropped))")
            guard prefillWritten == prefillFrames else {
                logger.error("Pre-publish prefill was refused (wrote \(prefillWritten) of \(prefillFrames))")
                return nil
            }
        }

        // Admission gateway (Batch 2): publish the mapping incarnation and
        // OPEN it before the rename below makes the file reachable. Order is
        // Create -> Initialize -> Prefill -> Open -> Publish -> driver claim.
        // The Host is the only writer of admission_state and admission_epoch;
        // the driver can claim the single owner slot but can never open it.
        let admissionEpoch = UInt64.random(in: 1...UInt64.max)
        let admissionResult = rf_admission_open(sharedMem, admissionEpoch)
        guard admissionResult == RF_ADMISSION_OK else {
            logger.error(
                "Failed to open admission: \(String(cString: rf_admission_result_string(admissionResult)))")
            return nil
        }

        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0, rename(stagingPath, shmPath) == 0 else {
            logger.error("Failed to publish shared memory: \(String(cString: strerror(errno)))")
            return nil
        }
        published = true
        let mapping = SharedMemoryMapping(
            memory: sharedMem, size: shmSize, device: fileInfo.st_dev, inode: fileInfo.st_ino
        )
        os_unfair_lock_lock(lock)
        let previous = deviceMemory.updateValue(mapping, forKey: uid)
        origins[uid] = origin
        os_unfair_lock_unlock(lock)
        // 最后一个租约可能仍在回调中，不能在这里直接 munmap。
        withExtendedLifetime(previous) {}
        // The new mapping becomes the render path's candidate; if a callback is
        // still inside the previous one, the swap is deferred to the heartbeat.
        refreshRenderMemory()

        logger.info(
            "Shared memory ready for \(uid) [origin=\(origin.rawValue, privacy: .public), volume=\(String(format: "%.3f", resolution.scalar), privacy: .public), muted=\(resolution.muted)]"
        )
        print("[SoundBridgeHost]   Protocol: 0x\(String(RF_AUDIO_PROTOCOL_VERSION, radix: 16)) (header \(RF_SHARED_AUDIO_HEADER_SIZE) bytes)")
        print("[SoundBridgeHost]   Volume source: \(resolution.source.rawValue) -> scalar \(String(format: "%.3f", resolution.scalar))")
        print("[SoundBridgeHost]   Format: \(sampleRate)Hz, \(SoundBridgeConfig.defaultChannels)ch, float32")
        print("[SoundBridgeHost]   Buffer: \(SoundBridgeConfig.defaultDurationMs)ms (\(frames) frames)")

        return origin
    }

    /// Publish a volume state into the mapping for `uid`.
    ///
    /// This is the Host's authoritative write path: it bumps
    /// `state_revision` and latches `state_initialized` inside the header.
    @discardableResult
    func publishVolumeState(
        for uid: String,
        scalar: Float,
        muted: Bool,
        mode: VolumeMode = .software
    ) -> Bool {
        guard let mapping = acquireMemory(for: uid) else {
            logger.error("Cannot publish volume state for \(uid): no mapping")
            return false
        }
        defer { withExtendedLifetime(mapping) {} }
        rf_publish_volume_state(mapping.memory, scalar, muted, mode.protocolValue)
        logger.debug("Published volume state for \(uid): scalar=\(scalar) muted=\(muted) mode=\(mode.rawValue)")
        return true
    }

    /// Read back the committed volume state for `uid`.
    /// Returns `nil` when the block has never been committed.
    func readVolumeState(for uid: String) -> RFVolumeStateSnapshotLike? {
        guard let mapping = acquireMemory(for: uid) else { return nil }
        defer { withExtendedLifetime(mapping) {} }
        var snapshot = RFVolumeStateSnapshot()
        guard rf_read_volume_state(mapping.memory, &snapshot) else { return nil }
        return RFVolumeStateSnapshotLike(
            scalar: snapshot.scalar,
            muted: snapshot.muted != 0,
            mode: snapshot.mode,
            initialized: true
        )
    }

    /// 延迟删除可附带创建时的代际，避免删除同 UID 的新映射。
    func removeMemory(for uid: String, ifGeneration expected: UUID? = nil) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        os_unfair_lock_lock(lock)
        let candidate = deviceMemory[uid]
        let mapping = candidate.flatMap { expected == nil || $0.generation == expected ? $0 : nil }
        if mapping != nil {
            deviceMemory.removeValue(forKey: uid)
            origins.removeValue(forKey: uid)
        }
        os_unfair_lock_unlock(lock)
        guard let mapping else { return }
        // Take it off the render path *before* the local reference goes away:
        // the slot keeps its own reference until the last callback leaves, so
        // the bytes stay mapped for as long as a reader can still see them.
        refreshRenderMemory()
        revokeAdmission(mapping)
        unlinkIfStillOwned(path: pathForUID(uid), mapping: mapping)
        withExtendedLifetime(mapping) {}
    }

    // MARK: - Render path

    /// The mapping the render callback should read, recomputed from the
    /// preferred UID and, failing that, from whatever mapping exists.
    ///
    /// Control threads only — it takes `lock` and `renderPublishLock`, neither
    /// of which the callback ever touches.
    func refreshRenderMemory() {
        os_unfair_lock_lock(lock)
        let preferred = preferredRenderUID
        let candidate = preferred.flatMap { deviceMemory[$0] } ?? deviceMemory.values.first
        os_unfair_lock_unlock(lock)
        publishRenderMapping(candidate)
    }

    /// Tells the manager which device the Host is routing through.
    ///
    /// `nil` means "no preference": the render path falls back to the single
    /// mapping, exactly as it did when the callback consulted
    /// `proxyManager.activeProxyUID`.
    func setPreferredRenderUID(_ uid: String?) {
        os_unfair_lock_lock(lock)
        preferredRenderUID = uid
        os_unfair_lock_unlock(lock)
        refreshRenderMemory()
    }

    /// The RT entry point.
    ///
    /// One lock-free increment and one load. It never allocates, never logs,
    /// never reads a `String`, never releases a mapping, and never waits on a
    /// control thread: the pointer stays valid until the matching
    /// `exitRenderMemory()`, because publication refuses to swap while a lease
    /// is held.
    func enterRenderMemory() -> UnsafeMutablePointer<RFSharedAudio>? {
        guard let pointer = rf_rt_gate_enter(renderGate) else { return nil }
        return pointer.assumingMemoryBound(to: RFSharedAudio.self)
    }

    /// Balances `enterRenderMemory()`. Must only be called when that returned a
    /// non-nil pointer; an unbalanced call would keep a publication deferred.
    func exitRenderMemory() {
        rf_rt_gate_exit(renderGate)
    }

    /// Applies a publication that was deferred, once the render path is idle.
    /// Called from the heartbeat and from `removeMemory`/`cleanup`.
    func drainDeferredRenderPublication() {
        os_unfair_lock_lock(renderPublishLock)
        let pending = renderPendingIsSet
        let replacement = renderPendingMapping
        os_unfair_lock_unlock(renderPublishLock)

        guard pending else {
            reclaimRenderMappingsIfIdle()
            return
        }
        publishRenderMapping(replacement)
    }

    /// Releases retired mappings whose leases are gone. Control thread only.
    func reclaimRenderMappingsIfIdle() {
        os_unfair_lock_lock(renderPublishLock)
        defer { os_unfair_lock_unlock(renderPublishLock) }
        reclaimRetiredRenderMappingsLocked()
    }

    /// Diagnostics for tests: what the render path currently holds.
    struct RenderPathSnapshot {
        var publishedPointer: UnsafeMutablePointer<RFSharedAudio>?
        var inFlight: Int
        var hasDeferredPublication: Bool
        var holdsMapping: Bool
        var retireTimeouts: UInt64
    }

    var renderPathSnapshot: RenderPathSnapshot {
        os_unfair_lock_lock(renderPublishLock)
        defer { os_unfair_lock_unlock(renderPublishLock) }
        let published = rf_rt_gate_current(renderGate)
        return RenderPathSnapshot(
            publishedPointer: published?.assumingMemoryBound(to: RFSharedAudio.self),
            inFlight: Int(rf_rt_gate_in_flight(renderGate)),
            hasDeferredPublication: renderPendingIsSet || !retiredRenderMappings.isEmpty,
            holdsMapping: renderMapping != nil,
            retireTimeouts: renderRetireTimeouts
        )
    }

    /// Control thread only. Swaps the published mapping, or parks it when a
    /// callback is still inside the current one.
    ///
    /// Returns `false` when the swap was deferred; the caller must not drop its
    /// own reference expecting the memory to be released — the slot still holds
    /// it, and `drainDeferredRenderPublication()` will publish it later.
    @discardableResult
    private func publishRenderMapping(_ mapping: SharedMemoryMapping?) -> Bool {
        os_unfair_lock_lock(renderPublishLock)
        defer { os_unfair_lock_unlock(renderPublishLock) }

        if mapping === renderMapping, !renderPendingIsSet {
            reclaimRetiredRenderMappingsLocked()
            return true
        }

        // The gate swaps only with no lease outstanding. Once the swap happens
        // it is never rolled back: a reader that slipped into the window may
        // already hold the previous pointer, and putting it back could not
        // retract it. The previous mapping is therefore retired here and freed
        // only when the gate reports no lease left. That is the same contract
        // the lock used to provide, minus the waiter.
        let rawMapping = mapping.map { UnsafeMutableRawPointer($0.memory) }
        if rf_rt_gate_try_publish(renderGate, rawMapping) != 0 {
            let previous = renderMapping
            renderMapping = mapping
            renderPendingMapping = nil
            renderPendingIsSet = false
            if let previous, previous !== mapping {
                retiredRenderMappings.append(previous)
            }
            reclaimRetiredRenderMappingsLocked()
            return true
        }

        renderPendingMapping = mapping
        renderPendingIsSet = true
        // Control thread only, and rare (a device switch that landed while a
        // callback was inside). Logged so a deferred swap can be matched against
        // the heartbeat's drain instead of guessed at.
        logger.notice("Deferred render publication: a callback is inside the current mapping")
        return false
    }

    /// Drops retired mappings the gate can no longer hand out.
    ///
    /// Must be called with `renderPublishLock` held. The release itself runs
    /// here, on a control thread, which is exactly why the gate refuses to swap
    /// while a lease is held: `munmap` may not run on the audio thread.
    private func reclaimRetiredRenderMappingsLocked() {
        guard !retiredRenderMappings.isEmpty else { return }
        guard rf_rt_gate_in_flight(renderGate) == 0 else { return }
        let releasing = retiredRenderMappings
        retiredRenderMappings.removeAll(keepingCapacity: true)
        withExtendedLifetime(releasing) {}
    }

    /// Stops the render path and waits (bounded) for callbacks to leave.
    ///
    /// Shutdown only: a control thread spinning here is allowed, a callback
    /// waiting would not be.
    private func retireRenderPath(timeout: TimeInterval) {
        publishRenderMapping(nil)
        let drained = waitForRenderPathIdle(timeout: timeout)

        os_unfair_lock_lock(renderPublishLock)
        // Shutdown only: stop handing out the pointer even when a callback is
        // still inside, then release it below. `renderRetireTimeouts` records
        // that the documented last resort was used.
        rf_rt_gate_force_publish(renderGate, nil)
        let lastMapping = renderMapping
        renderMapping = nil
        renderPendingMapping = nil
        renderPendingIsSet = false
        let retired = retiredRenderMappings
        retiredRenderMappings.removeAll(keepingCapacity: false)
        if !drained { renderRetireTimeouts &+= 1 }
        os_unfair_lock_unlock(renderPublishLock)

        if !drained {
            logger.error(
                "Render path did not drain within \(timeout)s; releasing the mapping anyway (shutdown)"
            )
        }
        // Released outside the lock: `munmap` runs here, on this control thread.
        withExtendedLifetime((lastMapping, retired)) {}
    }

    /// Wait, bounded, for every callback to leave the render path.
    ///
    /// Control thread only. A callback is never allowed to wait; a control
    /// thread waiting is the whole point of this function. Returns `false` when
    /// the deadline passed with a callback still inside, which is a fact worth
    /// counting rather than a condition to hide.
    func waitForRenderPathIdle(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if rf_rt_gate_in_flight(renderGate) == 0 { return true }
            if Date() >= deadline { return false }
            usleep(200)
        }
    }

    /// Snapshot the connection fields of one mapping.
    ///
    /// All four reads are C11 atomic loads (see the accessors in
    /// `RFSharedAudio.h`), so a torn value is not possible across processes. The
    /// sample is still a snapshot in time: the fields are not updated together,
    /// which is why the tracker compares successive samples instead of trusting
    /// one.
    func connectionObservation(for uid: String) -> DriverConnectionObservation? {
        guard let mapping = acquireMemory(for: uid) else { return nil }
        defer { withExtendedLifetime(mapping) {} }
        let mem = mapping.memory
        return DriverConnectionObservation(
            headerValid: rf_validate_header(mem) == RF_VALIDATE_OK,
            driverConnected: rf_get_driver_connected(mem) != 0,
            driverHeartbeat: rf_get_driver_heartbeat(mem),
            hostHeartbeat: rf_get_host_heartbeat(mem),
            // A re-created mapping is a different incarnation even though the
            // path is the same. The monitor needs to know that, because a fresh
            // mapping's zeroed `driver_connected` means "not attached yet".
            mappingToken: mapping.generation
        )
    }

    func acquireMemory(for uid: String) -> SharedMemoryMapping? {
        os_unfair_lock_lock(lock)
        let mapping = deviceMemory[uid]
        os_unfair_lock_unlock(lock)
        return mapping
    }

    func acquireFirstMemory() -> SharedMemoryMapping? {
        os_unfair_lock_lock(lock)
        let mapping = deviceMemory.values.first
        os_unfair_lock_unlock(lock)
        return mapping
    }

    /// 仅用于同步测试与存在性检查；跨调用持有指针必须使用租约。
    func getMemory(for uid: String) -> UnsafeMutablePointer<RFSharedAudio>? {
        acquireMemory(for: uid)?.memory
    }

    func startHeartbeat() {
        // Idempotent: `DeviceMonitor` calls this again on every idle → active
        // transition, and the previous timer was simply overwritten — one leaked
        // live source per cycle, each still writing `host_heartbeat`. Cancelling
        // first makes "exactly one heartbeat timer" true by construction.
        heartbeatLock.lock()
        defer { heartbeatLock.unlock() }
        heartbeatTimer?.cancel()
        heartbeatTimer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        heartbeatTimer?.schedule(
            deadline: .now(),
            repeating: SoundBridgeConfig.heartbeatInterval
        )

        heartbeatTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            // A publication the render path could not take earlier (a callback
            // was inside the previous mapping) is applied from here, never from
            // the callback.
            self.drainDeferredRenderPublication()
            os_unfair_lock_lock(self.lock)
            let mems = Array(self.deviceMemory)
            os_unfair_lock_unlock(self.lock)
            for (_, mapping) in mems {
                rf_update_host_heartbeat(mapping.memory)
                withExtendedLifetime(mapping) {}
            }

            // Telemetry: log underrun/overrun deltas every 5 seconds (non-RT safe)
            self.telemetryCounter += 1
            if self.telemetryCounter % 5 == 0 {
                // P3 Batch 1.5: the render path's own state had no runtime
                // outlet before this line. `renderPathSnapshot` was reachable
                // from tests only, so "a publication is stuck behind a
                // callback" was unobservable in a real run.
                let path = self.renderPathSnapshot
                logger.notice(
                    "Render path: inFlight=\(path.inFlight) deferred=\(path.hasDeferredPublication) holdsMapping=\(path.holdsMapping) retireTimeouts=\(path.retireTimeouts)"
                )
                for (uid, mapping) in mems {
                    let underruns = rf_get_underrun_count(mapping.memory)
                    let overruns = rf_get_overrun_count(mapping.memory)
                    withExtendedLifetime(mapping) {}
                    let lastU = self.lastUnderrunCounts[uid] ?? 0
                    let lastO = self.lastOverrunCounts[uid] ?? 0
                    if underruns > lastU {
                        logger.warning("⚠️ Buffer underrun: +\(underruns - lastU) (total: \(underruns)) [\(uid)]")
                    }
                    if overruns > lastO {
                        logger.warning("⚠️ Buffer overrun: +\(overruns - lastO) (total: \(overruns)) [\(uid)]")
                    }
                    self.lastUnderrunCounts[uid] = underruns
                    self.lastOverrunCounts[uid] = overruns
                }
            }
        }

        heartbeatTimer?.resume()
        logger.info("Started heartbeat - updating every second")
    }

    func stopHeartbeat() {
        heartbeatLock.lock()
        defer { heartbeatLock.unlock() }
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    func cleanup() {
        print("[Cleanup] Unmapping shared memory...")
        mutationLock.lock()
        defer { mutationLock.unlock() }
        isClosed = true
        // Detach the render path first and give an in-flight callback the time
        // to leave. Only then can `entries` be the last reference to any
        // mapping, which is what keeps munmap off the audio thread at exit.
        retireRenderPath(timeout: SoundBridgeConfig.cleanupWaitTimeout)
        os_unfair_lock_lock(lock)
        let entries = deviceMemory
        deviceMemory.removeAll()
        origins.removeAll()
        os_unfair_lock_unlock(lock)

        for (uid, mapping) in entries {
            revokeAdmission(mapping)
            unlinkIfStillOwned(path: pathForUID(uid), mapping: mapping)
        }
        withExtendedLifetime(entries) {}
    }

    // MARK: - Private

    /// Revoke producer admission on a mapping this Host is abandoning.
    ///
    /// CLOSING stops every future producer write immediately. It is NOT a
    /// drain proof: a callback already past the gate may still be running, and
    /// that is exactly why the mapping is not reused — the file is unlinked
    /// and the lease is dropped, so the old bytes are never handed to a new
    /// incarnation. `finalize_close()` deliberately stays uncalled here; the
    /// state it would confirm belongs to the drain/retirement batch.
    private func revokeAdmission(_ mapping: SharedMemoryMapping) {
        let result = rf_admission_begin_close(mapping.memory)
        if result != RF_ADMISSION_OK {
            logger.error(
                "Failed to revoke admission: \(String(cString: rf_admission_result_string(result)))")
        }
    }

    /// inode 检查避免顺序执行的旧实例清理删除新文件；检查与 unlink
    /// 之间不是原子操作，调用方仍须依靠实例锁排除其他合法写者。
    private func unlinkIfStillOwned(path: String, mapping: SharedMemoryMapping) {
        var current = stat()
        guard lstat(path, &current) == 0,
              current.st_dev == mapping.device, current.st_ino == mapping.inode else { return }
        if unlink(path) != 0 && errno != ENOENT {
            logger.error("Failed to unlink shared memory: \(String(cString: strerror(errno)))")
        }
    }

    /// Read-only probe of an existing shared-memory file.
    ///
    /// Maps just the fixed header (never the audio payload) so a corrupt or
    /// gigantic file cannot hurt us, and classifies what it finds.
    private func probeExisting(path: String) -> (
        origin: SharedMemoryOrigin,
        recovered: RFVolumeStateSnapshotLike?
    ) {
        // Read-only, and never through a symlink: a planted link should be
        // classified as unusable rather than followed.
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            // ENOENT is the normal first-run case. Anything else means something
            // is there but we cannot read it (permissions, a symlink, a
            // directory); classify it as unusable instead of absent so the log
            // says why it was replaced.
            let code = errno
            if code == ENOENT {
                return (.created, nil)
            }
            logger.warning("Could not open existing shared memory (\(String(cString: strerror(code)))); replacing")
            return (.replacedIncompatible, nil)
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { return (.created, nil) }

        let headerSize = MemoryLayout<RFSharedAudio>.size
        guard Int(st.st_size) >= headerSize else {
            logger.warning("Existing shared memory too small (\(st.st_size) < \(headerSize)); replacing")
            return (.replacedIncompatible, nil)
        }

        let raw = mmap(nil, headerSize, PROT_READ, MAP_SHARED, fd, 0)
        guard raw != MAP_FAILED, let base = raw else {
            logger.warning("Could not map existing shared memory read-only; replacing")
            return (.replacedIncompatible, nil)
        }
        defer { munmap(base, headerSize) }

        let mem = base.assumingMemoryBound(to: RFSharedAudio.self)

        guard mem.pointee.protocol_version == UInt32(RF_AUDIO_PROTOCOL_VERSION) else {
            logger.warning(
                "Existing shared memory protocol 0x\(String(mem.pointee.protocol_version, radix: 16)) != 0x\(String(RF_AUDIO_PROTOCOL_VERSION, radix: 16)); replacing"
            )
            return (.replacedIncompatible, nil)
        }

        guard mem.pointee.header_size == UInt32(RF_SHARED_AUDIO_HEADER_SIZE) else {
            logger.warning(
                "Existing shared memory header_size \(mem.pointee.header_size) != \(RF_SHARED_AUDIO_HEADER_SIZE); replacing"
            )
            return (.replacedIncompatible, nil)
        }

        var snapshot = RFVolumeStateSnapshot()
        guard rf_read_volume_state(mem, &snapshot) else {
            // Valid layout, but nothing was ever committed.
            return (.replacedUninitialized, nil)
        }

        return (
            .recoveredFromCrash,
            RFVolumeStateSnapshotLike(
                scalar: snapshot.scalar,
                muted: snapshot.muted != 0,
                mode: snapshot.mode,
                initialized: true
            )
        )
    }
}
