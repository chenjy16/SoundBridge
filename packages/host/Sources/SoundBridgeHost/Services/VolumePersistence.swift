import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "VolumePersistence")

/// Persisted volume state for a single physical device.
struct DeviceVolumeState: Codable {
    var volumeScalar: Float  // 0.0 - 1.0
    var isMuted: Bool
}

/// Persists per-device volume and mute state to disk.
///
/// Storage: `~/Library/Application Support/SoundBridge/volume-state.json`
/// - In-memory cache for fast reads
/// - 500ms debounce on writes to avoid excessive I/O during slider drag
/// - Atomic write (.tmp + rename) to prevent corruption
///
/// Conforms to `VolumeStatePersisting` so the volume state model can be
/// tested against an in-memory fake instead of this file.
class VolumePersistence: VolumeStatePersisting {
    /// Kept in sync with `VolumeState.defaultScalar` and the seed value used by
    /// `rf_shared_audio_init()`; all three must agree or the first launch
    /// publishes a value the other two do not expect.
    static let defaultVolume: Float = VolumeState.defaultScalar

    private let fileURL: URL
    private var cache: [String: DeviceVolumeState] = [:]
    private let queue = DispatchQueue(label: "com.soundbridge.volume-persistence")
    private var pendingWrite: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.5  // 500ms

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? PathManager.appSupportDir.appendingPathComponent("volume-state.json")
        loadFromDisk()
    }

    /// Save volume and mute state for a device UID.
    /// Writes are debounced (500ms) and performed atomically.
    func save(uid: String, volume: Float, muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cache[uid] = DeviceVolumeState(volumeScalar: volume, isMuted: muted)
            self.scheduleDebouncedWrite()
        }
    }

    /// Load volume state for a device UID.
    /// Returns cached value if available, otherwise defaults (volume=0.35, muted=false).
    func load(uid: String) -> DeviceVolumeState {
        return queue.sync {
            cache[uid] ?? DeviceVolumeState(volumeScalar: Self.defaultVolume, isMuted: false)
        }
    }

    /// Load volume state only if this device has actually been saved before.
    ///
    /// The difference from `load(uid:)` is load-bearing: `load` substitutes a
    /// default, which would mask a recoverable shared-memory state and
    /// silently reset the user's volume on a Host restart.
    func loadIfPresent(uid: String) -> DeviceVolumeState? {
        return queue.sync { cache[uid] }
    }

    // MARK: - Private

    private func scheduleDebouncedWrite() {
        // Cancel any pending write
        pendingWrite?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.writeToDisk()
        }
        pendingWrite = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func loadFromDisk() {
        queue.sync { [self] in
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
                logger.info("No existing state file, starting fresh")
                return
            }
            do {
                let data = try Data(contentsOf: self.fileURL)
                let decoded = try JSONDecoder().decode([String: DeviceVolumeState].self, from: data)
                self.cache = decoded
                logger.info("Loaded state for \(decoded.count) device(s)")
            } catch {
                logger.error("Failed to load state: \(error.localizedDescription)")
            }
        }
    }

    private func writeToDisk() {
        do {
            let data = try JSONEncoder().encode(cache)

            guard AtomicFileWriter.replace(at: fileURL.path, with: data) else {
                logger.error("Failed to atomically publish volume state")
                return
            }
            logger.info("Saved state for \(self.cache.count) device(s)")
        } catch {
            logger.error("Failed to save state: \(error.localizedDescription)")
        }
    }
}
