import Foundation
import Combine
import Darwin
import os.log
import CSoundBridgeAudio

private let logger = Logger(subsystem: "com.soundbridge.app", category: "EQController")

// MARK: - Local Preset Config Types (Phase 1)

/// Filter type matching SoundBridgeFilterType values.
enum EQFilterType: Int {
    case peak = 0
    case lowShelf = 1
    case highShelf = 2
}

/// Per-band configuration mirroring SoundBridgeBand.
struct EQBandConfig {
    let frequencyHz: Float
    var gainDb: Float
    let qFactor: Float
    let filterType: EQFilterType
    var enabled: Bool
}

/// Full preset configuration mirroring SoundBridgePreset.
struct EQPresetConfig {
    let name: String
    var bands: [EQBandConfig]
    var preampDb: Float
    let limiterEnabled: Bool
    let limiterThresholdDb: Float
}

// MARK: - Band Mapping Constants

/// Weighted mapping table for the three-band EQ.
/// Concentrated weights — push perceptible frequency bands harder.
private let bassBands: [(index: Int, weight: Float, freq: Float, type: EQFilterType)] = [
    (0, 0.5, 32,  .lowShelf),
    (1, 1.0, 64,  .lowShelf),
    (2, 1.5, 125, .lowShelf),
]

private let midsBands: [(index: Int, weight: Float, freq: Float, type: EQFilterType)] = [
    (4, 0.6, 500,  .peak),
    (5, 1.2, 1000, .peak),
]

private let trebleBands: [(index: Int, weight: Float, freq: Float, type: EQFilterType)] = [
    (8, 0.4, 8000,  .highShelf),
    (9, 1.3, 16000, .highShelf),
]

/// Bands that are unused and always disabled with 0.0 gain.
private let unusedBandIndices: Set<Int> = [3, 6, 7]


// MARK: - EQ Persistence Keys

/// Per-device UserDefaults key generation for EQ state persistence.
enum EQDefaultsKey {
    static func bass(for deviceUID: String) -> String { "eq_\(deviceUID)_bass_db" }
    static func mids(for deviceUID: String) -> String { "eq_\(deviceUID)_mids_db" }
    static func treble(for deviceUID: String) -> String { "eq_\(deviceUID)_treble_db" }
    static func isEnabled(for deviceUID: String) -> String { "eq_\(deviceUID)_enabled" }
}

// MARK: - EQController

/// EQ business-logic controller for a single device.
/// Manages three-band EQ state, weighted band mapping, throttled updates, and persistence.
class EQController: ObservableObject {

    let deviceUID: String

    /// Shared memory pointer — nil when device not connected.
    private var sharedMemory: UnsafeMutablePointer<RFSharedAudio>?
    private var shmSize: Int = 0

    // MARK: - Published State (UI 60Hz responsive)

    @Published var bass: Float = 0.0 {
        didSet {
            let clamped = EQController.clampGain(bass)
            if bass != clamped { bass = clamped }
        }
    }
    @Published var mids: Float = 0.0 {
        didSet {
            let clamped = EQController.clampGain(mids)
            if mids != clamped { mids = clamped }
        }
    }
    @Published var treble: Float = 0.0 {
        didSet {
            let clamped = EQController.clampGain(treble)
            if treble != clamped { treble = clamped }
        }
    }
    @Published var isEnabled: Bool = true

    // MARK: - Change Detection Cache

    private var lastBass: Float = 0.0
    private var lastMids: Float = 0.0
    private var lastTreble: Float = 0.0
    private var lastBypass: Bool = false

    // MARK: - Combine Pipeline

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(deviceUID: String, sharedMemory: UnsafeMutablePointer<RFSharedAudio>? = nil) {
        self.deviceUID = deviceUID
        self.sharedMemory = sharedMemory
        setupThrottledPipeline()
        loadFromUserDefaults()
    }

    /// Lightweight initializer for testing — skips Combine pipeline and UserDefaults loading.
    /// Use only in unit/property tests where Combine infrastructure is not needed.
    init(testDeviceUID: String) {
        self.deviceUID = testDeviceUID
        self.sharedMemory = nil
    }

    // MARK: - Gain Clamping (Sub-task 1.4)

    /// Clamp a gain value to the valid range [-12.0, 12.0].
    static func clampGain(_ value: Float) -> Float {
        min(max(value, -12.0), 12.0)
    }

    // MARK: - Band Mapping (Sub-task 1.2)

    /// Pure function: compute 10-band gain array from three-band slider values.
    /// Bands 3, 6, 7 are always 0.0.
    static func computeBandGains(bass: Float, mids: Float, treble: Float) -> [Float] {
        var gains = [Float](repeating: 0.0, count: 10)

        for band in bassBands {
            gains[band.index] = bass * band.weight
        }
        for band in midsBands {
            gains[band.index] = mids * band.weight
        }
        for band in trebleBands {
            gains[band.index] = treble * band.weight
        }
        // bands 3, 6, 7 remain 0.0

        return gains
    }

    // MARK: - Auto Gain Compensation (Sub-task 1.3)

    /// Pure function: compute preamp compensation.
    /// Disabled for now — let the DSP limiter handle clipping protection.
    /// This makes EQ changes much more perceptible.
    static func computeAutoGainCompensation(bass: Float, mids: Float, treble: Float) -> Float {
        return 0.0
    }

    // MARK: - Reset (Sub-task 1.5)

    /// Reset all EQ gains to flat (0.0 dB). isEnabled is preserved.
    func reset() {
        bass = 0.0
        mids = 0.0
        treble = 0.0
    }

    // MARK: - Build Initial Preset (Sub-task 1.6)

    /// Build a 10-band preset with correct filter types, frequencies, and enabled states.
    /// Returns a local `EQPresetConfig` (mapped to `SoundBridgePreset` in Phase 2).
    func buildInitialPreset() -> EQPresetConfig {
        // Q values tuned per filter type for perceptible effect:
        // Shelf filters: Q=0.7 for wide, smooth slope
        // Peak filters: Q=1.2 for focused but audible boost/cut
        let shelfQ: Float = 0.7
        let peakQ: Float = 1.2

        // Build a lookup from band index → config for active bands
        var bandMap: [Int: (freq: Float, type: EQFilterType, q: Float)] = [:]
        for b in bassBands   { bandMap[b.index] = (b.freq, b.type, shelfQ) }
        for b in midsBands   { bandMap[b.index] = (b.freq, b.type, peakQ) }
        for b in trebleBands { bandMap[b.index] = (b.freq, b.type, shelfQ) }

        // Default frequencies for unused bands (from the 10-band EQ standard layout)
        let defaultFreqs: [Int: Float] = [3: 250, 6: 2000, 7: 4000]

        let gains = EQController.computeBandGains(bass: bass, mids: mids, treble: treble)

        var bands: [EQBandConfig] = []
        for i in 0..<10 {
            if let active = bandMap[i] {
                bands.append(EQBandConfig(
                    frequencyHz: active.freq,
                    gainDb: gains[i],
                    qFactor: active.q,
                    filterType: active.type,
                    enabled: true
                ))
            } else {
                // Unused band (3, 6, 7)
                bands.append(EQBandConfig(
                    frequencyHz: defaultFreqs[i] ?? 0,
                    gainDb: 0.0,
                    qFactor: 1.0,
                    filterType: .peak,
                    enabled: false
                ))
            }
        }

        let preamp = EQController.computeAutoGainCompensation(bass: bass, mids: mids, treble: treble)

        return EQPresetConfig(
            name: "Basic EQ",
            bands: bands,
            preampDb: preamp,
            limiterEnabled: false,
            limiterThresholdDb: 0.0
        )
    }

    // MARK: - Change Detection (Sub-task 1.7)

    /// Returns true if the current state differs from the cached state by ≥ 0.01 dB
    /// on any slider, or if the bypass state changed.
    func hasSignificantChange() -> Bool {
        let bypass = !isEnabled
        if abs(bass - lastBass) >= 0.01 { return true }
        if abs(mids - lastMids) >= 0.01 { return true }
        if abs(treble - lastTreble) >= 0.01 { return true }
        if bypass != lastBypass { return true }
        return false
    }

    /// Update the change-detection cache to the current state.
    func updateCache() {
        lastBass = bass
        lastMids = mids
        lastTreble = treble
        lastBypass = !isEnabled
    }

    // MARK: - Combine Throttle Pipeline (Sub-task 1.8)

    /// Set up a 30 Hz throttled pipeline that reacts to slider changes.
    private func setupThrottledPipeline() {
        $bass.combineLatest($mids, $treble, $isEnabled)
            .throttle(for: .milliseconds(33), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] bass, mids, treble, isEnabled in
                guard let self else { return }

                let bypass = !isEnabled

                // Change detection — skip if nothing meaningful changed
                if abs(bass - self.lastBass) < 0.01 &&
                   abs(mids - self.lastMids) < 0.01 &&
                   abs(treble - self.lastTreble) < 0.01 &&
                   bypass == self.lastBypass {
                    return
                }

                let bandGains = EQController.computeBandGains(bass: bass, mids: mids, treble: treble)
                let preamp = EQController.computeAutoGainCompensation(bass: bass, mids: mids, treble: treble)

                logger.debug("EQ update: bass=\(bass, privacy: .public) mids=\(mids, privacy: .public) treble=\(treble, privacy: .public) preamp=\(preamp, privacy: .public) bypass=\(bypass, privacy: .public)")

                // Write EQ state to shared memory
                self.writeToSharedMemory(bandGains: bandGains, preamp: preamp, bypass: bypass)

                // Update cache after successful processing
                self.lastBass = bass
                self.lastMids = mids
                self.lastTreble = treble
                self.lastBypass = bypass

                // Persist EQ state to UserDefaults
                self.saveToUserDefaults()
            }
            .store(in: &cancellables)
    }

    // MARK: - EQ Persistence (Sub-task 2.2, 2.3)

    /// Save current EQ state to UserDefaults using per-device keys.
    func saveToUserDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(bass, forKey: EQDefaultsKey.bass(for: deviceUID))
        defaults.set(mids, forKey: EQDefaultsKey.mids(for: deviceUID))
        defaults.set(treble, forKey: EQDefaultsKey.treble(for: deviceUID))
        defaults.set(isEnabled, forKey: EQDefaultsKey.isEnabled(for: deviceUID))
    }

    /// Restore EQ state from UserDefaults. Defaults to (0.0, 0.0, 0.0, true) if not found.
    func loadFromUserDefaults() {
        let defaults = UserDefaults.standard

        // Use object(forKey:) to distinguish "missing" from "stored 0.0",
        // since float(forKey:) returns 0.0 for missing keys.
        if let bassValue = defaults.object(forKey: EQDefaultsKey.bass(for: deviceUID)) as? Float {
            bass = bassValue
        } else {
            bass = 0.0
        }

        if let midsValue = defaults.object(forKey: EQDefaultsKey.mids(for: deviceUID)) as? Float {
            mids = midsValue
        } else {
            mids = 0.0
        }

        if let trebleValue = defaults.object(forKey: EQDefaultsKey.treble(for: deviceUID)) as? Float {
            treble = trebleValue
        } else {
            treble = 0.0
        }

        if defaults.object(forKey: EQDefaultsKey.isEnabled(for: deviceUID)) != nil {
            isEnabled = defaults.bool(forKey: EQDefaultsKey.isEnabled(for: deviceUID))
        } else {
            isEnabled = true
        }

        // Sync cache so the throttled pipeline doesn't immediately re-trigger
        updateCache()
    }

    // MARK: - Shared Memory Attachment

    /// Attach to the Host's shared memory file for a given device UID.
    /// The Host creates `/tmp/soundbridge-{sanitized_uid}` via mmap.
    /// The App opens the same file read-write to write EQ snapshots.
    func attachSharedMemory(for deviceUID: String) {
        // Detach previous mapping if any
        detachSharedMemory()

        let safeUID = deviceUID
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let shmPath = "/tmp/soundbridge-\(safeUID)"

        guard FileManager.default.fileExists(atPath: shmPath) else {
            logger.warning("Shared memory file not found: \(shmPath, privacy: .public)")
            return
        }

        let fd = open(shmPath, O_RDWR)
        guard fd >= 0 else {
            logger.error("Failed to open shared memory: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        // Get file size to determine mmap length
        var stat = stat()
        guard fstat(fd, &stat) == 0 else {
            logger.error("fstat failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return
        }

        let fileSize = Int(stat.st_size)
        guard fileSize >= MemoryLayout<RFSharedAudio>.size else {
            logger.error("Shared memory file too small: \(fileSize) bytes")
            close(fd)
            return
        }

        let mem = mmap(nil, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        close(fd)

        guard mem != MAP_FAILED, let validMem = mem else {
            logger.error("mmap failed: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        sharedMemory = validMem.assumingMemoryBound(to: RFSharedAudio.self)
        shmSize = fileSize
        logger.info("EQ attached to shared memory: \(shmPath, privacy: .public) (\(fileSize) bytes)")

        // Immediately flush current EQ state to shared memory
        flushToSharedMemory()
    }

    /// Detach from shared memory (unmap).
    func detachSharedMemory() {
        guard let mem = sharedMemory else { return }
        if shmSize > 0 {
            munmap(mem, shmSize)
        }
        sharedMemory = nil
        shmSize = 0
    }

    // MARK: - Shared Memory Write (Phase 2)

    /// Write current EQ state to shared memory via RFEQSnapshot.
    private func writeToSharedMemory(bandGains: [Float], preamp: Float, bypass: Bool) {
        guard let mem = sharedMemory else { return }

        var snapshot = RFEQSnapshot()
        withUnsafeMutablePointer(to: &snapshot.bands) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 10) { floatPtr in
                for i in 0..<min(bandGains.count, 10) {
                    floatPtr[i] = bandGains[i]
                }
            }
        }
        snapshot.preamp = preamp
        snapshot.bypass = bypass

        rf_store_eq_snapshot(mem, &snapshot)
    }

    // MARK: - Flush to Shared Memory (Sub-task 1.9)

    /// Immediately sync current state to shared memory, bypassing throttle and change detection.
    /// Phase 1: no-op. Phase 2: will compute and write via SeqLock.
    func flushToSharedMemory() {
        let bandGains = EQController.computeBandGains(bass: bass, mids: mids, treble: treble)
        let preamp = EQController.computeAutoGainCompensation(bass: bass, mids: mids, treble: treble)
        let bypass = !isEnabled

        logger.debug("EQ flush: bass=\(self.bass, privacy: .public) mids=\(self.mids, privacy: .public) treble=\(self.treble, privacy: .public) preamp=\(preamp, privacy: .public) bypass=\(bypass, privacy: .public)")

        // Write immediately to shared memory, bypassing throttle
        writeToSharedMemory(bandGains: bandGains, preamp: preamp, bypass: bypass)

        // Force-update cache so the throttled pipeline doesn't re-send
        updateCache()
    }
}
