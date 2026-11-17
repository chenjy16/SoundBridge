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

class SharedMemoryManager {
    /// Resolves the shared-memory file path for a device UID.
    ///
    /// Production uses `/tmp/soundbridge-<uid>` via `PathManager`. Tests inject a
    /// throwaway directory so a fixture can never create, truncate or unlink a
    /// real file. The closure is the only seam; every path lookup below goes
    /// through it.
    private let pathForUID: (String) -> String

    init(pathForUID: @escaping (String) -> String = { PathManager.sharedMemoryPath(uid: $0) }) {
        self.pathForUID = pathForUID
    }

    private var deviceMemory: [String: UnsafeMutablePointer<RFSharedAudio>] = [:]
    /// How each mapping came to exist, for diagnostics and tests.
    private(set) var origins: [String: SharedMemoryOrigin] = [:]
    private var heartbeatTimer: DispatchSourceTimer?
    private var lock = os_unfair_lock()

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

        let shmPath = pathForUID(uid)
        print("[SoundBridgeHost] File: \(shmPath)")

        // Probe before destroying: this is the only chance to learn what the
        // previous process committed.
        let probe = probeExisting(path: shmPath)
        let origin = probe.origin

        // Always start from a clean inode. Attaching to the old one would leave
        // the driver holding a mapping whose length may differ from this
        // build's, and a stale mapping is worse than a lost default.
        unlink(shmPath)

        // O_EXCL is the load-bearing flag here. The path was just unlinked, so a
        // file still present at this instant was created by someone else between
        // the unlink and this open; failing is the correct outcome, because
        // opening it would mean truncating a file this process does not own.
        // O_NOFOLLOW keeps the create from resolving through a symlink planted in
        // /tmp — O_EXCL already rejects symlinks, but the intent should be
        // readable without knowing that corner of POSIX.
        let fd = open(shmPath, O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR, 0o666)
        guard fd >= 0 else {
            let code = errno
            if code == EEXIST || code == ELOOP {
                logger.error("Refusing to occupy \(shmPath, privacy: .public): another process created it first")
            } else {
                logger.error("Failed to create file: \(String(cString: strerror(code)))")
            }
            return nil
        }

        fchmod(fd, 0o666)

        let sampleRate = SoundBridgeConfig.activeSampleRate
        let frames = rf_frames_for_duration(
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
            close(fd)
            return nil
        }

        let mem = mmap(nil, shmSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        close(fd)

        guard mem != MAP_FAILED else {
            logger.error("mmap failed: \(String(cString: strerror(errno)))")
            return nil
        }

        let sharedMem = mem!.assumingMemoryBound(to: RFSharedAudio.self)

        rf_shared_audio_init(
            sharedMem,
            sampleRate,
            SoundBridgeConfig.defaultChannels,
            SoundBridgeConfig.defaultFormat,
            SoundBridgeConfig.defaultDurationMs
        )

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

        os_unfair_lock_lock(&lock)
        deviceMemory[uid] = sharedMem
        origins[uid] = origin
        os_unfair_lock_unlock(&lock)

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
        guard let mem = getMemory(for: uid) else {
            logger.error("Cannot publish volume state for \(uid): no mapping")
            return false
        }
        rf_publish_volume_state(mem, scalar, muted, mode.protocolValue)
        logger.debug("Published volume state for \(uid): scalar=\(scalar) muted=\(muted) mode=\(mode.rawValue)")
        return true
    }

    /// Read back the committed volume state for `uid`.
    /// Returns `nil` when the block has never been committed.
    func readVolumeState(for uid: String) -> RFVolumeStateSnapshotLike? {
        guard let mem = getMemory(for: uid) else { return nil }
        var snapshot = RFVolumeStateSnapshot()
        guard rf_read_volume_state(mem, &snapshot) else { return nil }
        return RFVolumeStateSnapshotLike(
            scalar: snapshot.scalar,
            muted: snapshot.muted != 0,
            mode: snapshot.mode,
            initialized: true
        )
    }

    func removeMemory(for uid: String) {
        os_unfair_lock_lock(&lock)
        let sharedMem = deviceMemory[uid]
        if sharedMem != nil {
            deviceMemory.removeValue(forKey: uid)
            origins.removeValue(forKey: uid)
        }
        os_unfair_lock_unlock(&lock)

        guard let sharedMem = sharedMem else { return }

        let shmSize = rf_shared_audio_size(
            sharedMem.pointee.ring_capacity_frames,
            sharedMem.pointee.channels,
            sharedMem.pointee.bytes_per_sample
        )

        munmap(sharedMem, shmSize)

        let shmPath = pathForUID(uid)
        unlink(shmPath)
    }

    /// Snapshot the connection fields of one mapping.
    ///
    /// All four reads are C11 atomic loads (see the accessors in
    /// `RFSharedAudio.h`), so a torn value is not possible across processes. The
    /// sample is still a snapshot in time: the fields are not updated together,
    /// which is why the tracker compares successive samples instead of trusting
    /// one.
    func connectionObservation(for uid: String) -> DriverConnectionObservation? {
        guard let mem = getMemory(for: uid) else { return nil }

        return DriverConnectionObservation(
            headerValid: rf_validate_header(mem) == RF_VALIDATE_OK,
            driverConnected: rf_get_driver_connected(mem) != 0,
            driverHeartbeat: rf_get_driver_heartbeat(mem),
            hostHeartbeat: rf_get_host_heartbeat(mem)
        )
    }

    func getMemory(for uid: String) -> UnsafeMutablePointer<RFSharedAudio>? {
        os_unfair_lock_lock(&lock)
        let mem = deviceMemory[uid]
        os_unfair_lock_unlock(&lock)
        return mem
    }

    func getFirstMemory() -> UnsafeMutablePointer<RFSharedAudio>? {
        os_unfair_lock_lock(&lock)
        let mem = deviceMemory.values.first
        os_unfair_lock_unlock(&lock)
        return mem
    }

    func startHeartbeat() {
        // Idempotent: `DeviceMonitor` calls this again on every idle → active
        // transition, and the previous timer was simply overwritten — one leaked
        // live source per cycle, each still writing `host_heartbeat`. Cancelling
        // first makes "exactly one heartbeat timer" true by construction.
        stopHeartbeat()

        heartbeatTimer = DispatchSource.makeTimerSource(queue: .global())
        heartbeatTimer?.schedule(
            deadline: .now(),
            repeating: SoundBridgeConfig.heartbeatInterval
        )

        heartbeatTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            os_unfair_lock_lock(&self.lock)
            let mems = Array(self.deviceMemory)
            os_unfair_lock_unlock(&self.lock)
            for (_, mem) in mems {
                rf_update_host_heartbeat(mem)
            }

            // Telemetry: log underrun/overrun deltas every 5 seconds (non-RT safe)
            self.telemetryCounter += 1
            if self.telemetryCounter % 5 == 0 {
                for (uid, mem) in mems {
                    let underruns = rf_get_underrun_count(mem)
                    let overruns = rf_get_overrun_count(mem)
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
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    func cleanup() {
        print("[Cleanup] Unmapping shared memory...")
        os_unfair_lock_lock(&lock)
        let entries = deviceMemory
        deviceMemory.removeAll()
        origins.removeAll()
        os_unfair_lock_unlock(&lock)

        for (uid, mem) in entries {
            let size = rf_shared_audio_size(
                mem.pointee.ring_capacity_frames,
                mem.pointee.channels,
                mem.pointee.bytes_per_sample
            )
            munmap(mem, size)
            unlink(pathForUID(uid))
        }
    }

    // MARK: - Private

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
