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

/// Per-device UserDefaults keys for EQ state persistence.
enum EQDefaultsKey {
    /// All four values under one key, written with one `set` call.
    ///
    /// P1-2: they used to be four independent keys, so a crash between two of
    /// them could leave the gains of one drag next to the bypass flag of
    /// another. One dictionary value is replaced as a unit by `cfprefsd`, which
    /// makes the group atomic.
    static func state(for deviceUID: String) -> String { "eq_\(deviceUID)_state" }

    // The 1.2.0 layout. Read once when the new key is absent so an upgrade does
    // not silently flatten a device's EQ; never written again.
    static func bass(for deviceUID: String) -> String { "eq_\(deviceUID)_bass_db" }
    static func mids(for deviceUID: String) -> String { "eq_\(deviceUID)_mids_db" }
    static func treble(for deviceUID: String) -> String { "eq_\(deviceUID)_treble_db" }
    static func isEnabled(for deviceUID: String) -> String { "eq_\(deviceUID)_enabled" }
}

// MARK: - Persisted State

/// One device's EQ, as it is stored.
struct EQPersistedState: Equatable {
    var bass: Float
    var mids: Float
    var treble: Float
    var isEnabled: Bool

    /// Flat and enabled: what a device that has never been adjusted has.
    static let flat = EQPersistedState(bass: 0, mids: 0, treble: 0, isEnabled: true)

    /// The single value `UserDefaults` holds. Every field is a property-list
    /// type, so the whole state round-trips as one object.
    var dictionary: [String: Any] {
        ["bass": bass, "mids": mids, "treble": treble, "enabled": isEnabled]
    }

    /// Decode field by field, so one unusable field cannot throw away the rest.
    ///
    /// A gain that is not a number or not finite falls back to the flat default
    /// for that field only; a finite gain outside `[-12, 12]` is clamped rather
    /// than discarded, because it is a real value that travelled badly. A
    /// bypass flag that is not a boolean falls back to enabled, which is the
    /// state where the user can see and correct it.
    static func decode(_ raw: [String: Any]) -> EQPersistedState {
        var state = EQPersistedState.flat
        if let bass = gain(raw["bass"]) { state.bass = bass }
        if let mids = gain(raw["mids"]) { state.mids = mids }
        if let treble = gain(raw["treble"]) { state.treble = treble }
        if let enabled = flag(raw["enabled"]) { state.isEnabled = enabled }
        return state
    }

    private static func gain(_ value: Any?) -> Float? {
        // A boolean is an `NSNumber` too and would read as 1.0, so the CF type
        // has to be checked rather than the Swift cast alone.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let gain = number.floatValue
        guard gain.isFinite else { return nil }
        return EQController.clampGain(gain)
    }

    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

// MARK: - EQController

/// EQ business-logic controller for a single device.
/// Manages three-band EQ state, weighted band mapping, throttled updates, and persistence.
class EQController: ObservableObject {

    let deviceUID: String

    /// The App's single shared-memory mapping, owned by
    /// `SharedMemoryMappingManager` rather than by this controller.
    ///
    /// P2 Batch 3: the controller used to hold a raw pointer and a size and to
    /// `munmap` them itself. That is exactly what let it keep writing into an
    /// inode the Host had already replaced. `nil` in the lightweight test
    /// initialiser, where property tests exercise band mapping and persistence,
    /// not I/O.
    private let mapping: SharedMemoryMappingManager?
    private var mappingCancellables = Set<AnyCancellable>()

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

    // MARK: - Recovery State

    /// The incarnation these slider values were last written into.
    ///
    /// `SharedMemoryMappingManager` numbers publications monotonically, so this
    /// is also the de-duplication key: a repeated notification for a mapping
    /// that already holds these values is a no-op instead of another write.
    private var appliedGeneration: UInt64 = 0

    /// The generation the last successful write reached, or `nil` after the
    /// mapping was retired. Exposed for tests and diagnostics.
    private(set) var lastAppliedGeneration: UInt64?

    /// Whether the values on screen are known to be inside the live mapping.
    /// `false` means "persisted but not applied" — the UI must not claim more.
    @Published private(set) var isAppliedToCurrentMapping = false

    // MARK: - Combine Pipeline

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(deviceUID: String, mapping: SharedMemoryMappingManager? = .shared) {
        self.deviceUID = deviceUID
        self.mapping = mapping
        setupThrottledPipeline()
        loadFromUserDefaults()
        observeMapping()
    }

    /// Lightweight initializer for testing — skips the Combine pipeline, the
    /// UserDefaults load and the mapping subscription.
    /// Use only in unit/property tests where none of that infrastructure is needed.
    init(testDeviceUID: String) {
        self.deviceUID = testDeviceUID
        self.mapping = nil
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
        // A button press, not a drag: persist now rather than at the next
        // throttled delivery, so quitting straight afterwards cannot undo it.
        saveToUserDefaults()
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

                // Change detection decides whether the *write* is worth doing.
                let changed = abs(bass - self.lastBass) >= 0.01 ||
                              abs(mids - self.lastMids) >= 0.01 ||
                              abs(treble - self.lastTreble) >= 0.01 ||
                              bypass != self.lastBypass

                if changed {
                    let bandGains = EQController.computeBandGains(bass: bass, mids: mids, treble: treble)
                    let preamp = EQController.computeAutoGainCompensation(bass: bass, mids: mids, treble: treble)

                    logger.debug("EQ update: bass=\(bass, privacy: .public) mids=\(mids, privacy: .public) treble=\(treble, privacy: .public) preamp=\(preamp, privacy: .public) bypass=\(bypass, privacy: .public)")

                    // Write EQ state to shared memory
                    let result = self.writeToSharedMemory(bandGains: bandGains, preamp: preamp, bypass: bypass)

                    // Only a landed write makes the cache current. A skipped write
                    // leaves the difference visible, so the values are re-sent when
                    // a mapping appears instead of being treated as delivered.
                    if case .written(let generation) = result {
                        self.lastBass = bass
                        self.lastMids = mids
                        self.lastTreble = treble
                        self.lastBypass = bypass
                        self.appliedGeneration = generation
                        self.lastAppliedGeneration = generation
                        self.isAppliedToCurrentMapping = true
                    } else {
                        self.isAppliedToCurrentMapping = false
                    }
                }

                // Persist on every delivery, changed or not.
                //
                // P1-2: this used to sit behind the early `return` above, and
                // `flushToSharedMemory()` — which runs on every slider release —
                // advanced the cache without going through this sink. Releasing
                // the slider therefore made the pending delivery look like
                // "nothing changed", and the final position of the drag was
                // never saved. Saving unconditionally cannot over-save: this
                // pipeline only emits when one of the four values changed.
                self.saveToUserDefaults()
            }
            .store(in: &cancellables)
    }

    // MARK: - EQ Persistence (Sub-task 2.2, 2.3)

    /// The current state, in the shape it is stored.
    var persistedState: EQPersistedState {
        EQPersistedState(bass: bass, mids: mids, treble: treble, isEnabled: isEnabled)
    }

    /// Save current EQ state to UserDefaults using a per-device key.
    ///
    /// One `set` of one dictionary, so the four values are replaced together.
    func saveToUserDefaults() {
        UserDefaults.standard.set(
            persistedState.dictionary,
            forKey: EQDefaultsKey.state(for: deviceUID)
        )
    }

    /// Restore EQ state from UserDefaults. Defaults to (0.0, 0.0, 0.0, true) if not found.
    ///
    /// P1-2: the stored value is validated field by field (`EQPersistedState.decode`),
    /// so corrupt data degrades one field at a time instead of flattening the
    /// whole EQ, and a non-finite gain cannot reach the sliders or the DSP block
    /// — `clampGain` cannot repair `NaN`, because every comparison with it is
    /// false, so the sliders would keep it and `computeBandGains` would publish it.
    func loadFromUserDefaults() {
        let defaults = UserDefaults.standard

        if let stored = defaults.dictionary(forKey: EQDefaultsKey.state(for: deviceUID)) {
            apply(EQPersistedState.decode(stored))
        } else if let legacy = legacyState(in: defaults) {
            // The 1.2.0 keys. Adopt them and rewrite in the current shape once,
            // so the next launch takes the fast path.
            apply(legacy)
            saveToUserDefaults()
        } else {
            apply(.flat)
        }

        // Sync cache so the throttled pipeline doesn't immediately re-trigger
        updateCache()
    }

    private func apply(_ state: EQPersistedState) {
        bass = state.bass
        mids = state.mids
        treble = state.treble
        isEnabled = state.isEnabled
    }

    /// Read the four-key 1.2.0 layout. `nil` when none of the keys is present,
    /// which is a fresh install rather than an upgrade.
    private func legacyState(in defaults: UserDefaults) -> EQPersistedState? {
        let legacy = [
            "bass": EQDefaultsKey.bass(for: deviceUID),
            "mids": EQDefaultsKey.mids(for: deviceUID),
            "treble": EQDefaultsKey.treble(for: deviceUID),
            "enabled": EQDefaultsKey.isEnabled(for: deviceUID),
        ]
        var raw: [String: Any] = [:]
        for (field, key) in legacy {
            if let value = defaults.object(forKey: key) { raw[field] = value }
        }
        guard !raw.isEmpty else { return nil }
        return EQPersistedState.decode(raw)
    }

    // MARK: - Shared Memory Attachment

    /// Point the App's mapping at the Host's file for `deviceUID`.
    ///
    /// P2 Batch 3: this no longer opens, maps or unmaps anything here. It asks
    /// `SharedMemoryMappingManager` for the current incarnation, which validates
    /// the identity before publishing and only re-attaches when the inode
    /// actually changed. Repeating it for the same incarnation is a cheap no-op,
    /// which is why the existing call site in the menu bar is harmless.
    func attachSharedMemory(for deviceUID: String) {
        mapping?.requestAttach(for: deviceUID)
    }

    /// Re-apply the user's EQ state whenever a new incarnation becomes current.
    ///
    /// The EQ block belongs to the App — `rf_store_eq_snapshot` has no other
    /// caller, and the Host only reads it — so a mapping the Host just created
    /// starts flat and the current slider values have to be written back. This is
    /// also the pending-state mechanism: values set while no mapping existed live
    /// in the published properties and in UserDefaults, and they land here.
    private func observeMapping() {
        guard let mapping else { return }
        mapping.mappingPublished
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, generation in
                self?.applyIfNeeded(generation: generation)
            }
            .store(in: &mappingCancellables)

        mapping.mappingUnavailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                // The Host retired the file or went away. Nothing holds these
                // values any more, and the UI must stop claiming that it does.
                self.lastAppliedGeneration = nil
                self.isAppliedToCurrentMapping = false
            }
            .store(in: &mappingCancellables)

        // `mappingPublished` is a PassthroughSubject: a publication that happened
        // before this subscription is not replayed, and that is the normal case at
        // launch — `SharedMemoryMappingManager.start()` attaches from the App
        // delegate before the menu bar view creates this controller. Ask the
        // manager for the incarnation it holds right now instead of assuming the
        // notification will arrive. `applyIfNeeded` de-duplicates, so this costs a
        // write only when the mapping genuinely does not have these values yet.
        if mapping.isAvailable {
            applyIfNeeded(generation: mapping.currentGeneration)
        }
    }

    /// Publish the current slider values into `generation` unless they are already there.
    ///
    /// Runs for the incarnation present at construction and for every later
    /// incarnation change, so a Host restart (new inode, new epoch, new
    /// generation) re-applies the persisted EQ without restarting the App.
    private func applyIfNeeded(generation: UInt64) {
        guard generation > 0, generation != appliedGeneration else { return }

        switch flushToSharedMemory() {
        case .written(let written):
            appliedGeneration = written
            lastAppliedGeneration = written
            isAppliedToCurrentMapping = true
        case .unavailable:
            // Retired between the notification and the write. The next
            // publication retries; nothing is reported as applied.
            isAppliedToCurrentMapping = false
        }
    }

    /// Whether EQ writes actually reach a live mapping right now.
    var isMappingAvailable: Bool { mapping?.isAvailable ?? false }

    // MARK: - Shared Memory Write (Phase 2)

    /// Build a snapshot from the three-band state and hand it to the manager.
    @discardableResult
    private func writeToSharedMemory(bandGains: [Float], preamp: Float, bypass: Bool) -> SharedMemoryWriteResult {
        guard let mapping else { return .unavailable }

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

        let result = mapping.writeEQSnapshot(snapshot)
        if case .unavailable = result {
            // Not something the user can act on: the Host is not running. The
            // values stay in `bass` / `mids` / `treble` and in UserDefaults, and
            // `observeMapping()` writes them once a mapping exists.
            logger.notice("EQ write skipped: no active mapping")
        }
        return result
    }

    // MARK: - Flush to Shared Memory (Sub-task 1.9)

    /// Immediately sync current state to shared memory, bypassing throttle and change detection.
    ///
    /// Returns the write result so callers can tell "applied to this incarnation"
    /// from "no mapping yet". The cache is only advanced on a landed write, which
    /// keeps a skipped attempt visible as a difference to be re-sent later.
    ///
    /// P1-2: this also persists. It runs on every slider release, and it is the
    /// point that used to move the cache past the throttled sink — the sink then
    /// saw no change and never saved, so the position the user released the
    /// slider at was the one value that could not survive a restart.
    @discardableResult
    func flushToSharedMemory() -> SharedMemoryWriteResult {
        let bandGains = EQController.computeBandGains(bass: bass, mids: mids, treble: treble)
        let preamp = EQController.computeAutoGainCompensation(bass: bass, mids: mids, treble: treble)
        let bypass = !isEnabled

        logger.debug("EQ flush: bass=\(self.bass, privacy: .public) mids=\(self.mids, privacy: .public) treble=\(self.treble, privacy: .public) preamp=\(preamp, privacy: .public) bypass=\(bypass, privacy: .public)")

        // Write immediately to shared memory, bypassing throttle
        let result = writeToSharedMemory(bandGains: bandGains, preamp: preamp, bypass: bypass)

        // Persist regardless of the write: the user's values are the truth the
        // next incarnation is restored from, and they must not depend on a
        // mapping happening to exist.
        saveToUserDefaults()

        // Force-update cache only when the write really landed, so the throttled
        // pipeline does not re-send values that are already inside the mapping
        // and does not mark a skipped attempt as delivered.
        if case .written = result {
            updateCache()
        }
        return result
    }
}
