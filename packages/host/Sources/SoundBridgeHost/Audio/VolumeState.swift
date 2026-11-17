import Foundation

// MARK: - State value

/// Immutable snapshot of the Host's authoritative volume state for one device.
///
/// The four quantities Phase 2.0 identified as "the volume state" are kept
/// strictly separate here, because collapsing them is what produced the double
/// attenuation bug:
///
///   - `requestedScalar` — what the user asked for, in the taper's normalised
///     scalar space. This is the only value that gets persisted.
///   - `appliedGain` — the linear amplitude the renderer actually multiplies
///     samples by. Derived from `requestedScalar` through `VolumeTaper`, never
///     set independently.
///   - `isMuted` — orthogonal to the scalar. Muting at 0.5 must leave 0.5
///     behind so unmuting restores it.
///   - `mode` — routing decision. Phase 2.1 only ever produces `.software`.
///
/// `revision` and `initialized` describe the *publication* of the state, not
/// the state itself: `initialized == false` means "these are seed defaults and
/// nothing has ever committed them".
struct VolumeState: Equatable {
    var requestedScalar: Float
    var appliedGain: Float
    var isMuted: Bool
    var mode: VolumeMode
    var revision: UInt64
    var initialized: Bool

    /// Safe default used when neither persistence nor runtime state has an
    /// opinion. Mirrors `VolumePersistence.defaultVolume` and the
    /// `rf_shared_audio_init()` seed so all three agree.
    static let defaultScalar: Float = 0.35

    /// Seed state: correct numbers, but explicitly not committed.
    static let seed = VolumeState(
        requestedScalar: defaultScalar,
        appliedGain: VolumeTaper.gain(forScalar: defaultScalar),
        isMuted: false,
        mode: .software,
        revision: 0,
        initialized: false
    )

    /// Build a committed state from a user-facing scalar.
    ///
    /// `appliedGain` is always recomputed here so the two can never drift.
    static func committed(
        scalar: Float,
        muted: Bool,
        mode: VolumeMode,
        revision: UInt64
    ) -> VolumeState {
        let safeScalar = VolumeTaper.sanitize(scalar, fallback: defaultScalar)
        return VolumeState(
            requestedScalar: safeScalar,
            appliedGain: VolumeTaper.gain(forScalar: safeScalar),
            isMuted: muted,
            mode: mode,
            revision: revision,
            initialized: true
        )
    }
}

// MARK: - Persistence seam

/// Minimal persistence seam.
///
/// `VolumePersistence` conforms as-is; tests use an in-memory fake so the
/// state model can be exercised without touching the user's library folder.
/// Deliberately not a heavyweight protocol: Phase 2.1 only needs "read what
/// the user last chose" and "remember what they chose now".
protocol VolumeStatePersisting: AnyObject {
    /// Persisted value for `uid`, or `nil` if this device has never been seen.
    /// Returning `nil` rather than a default matters: a default would mask a
    /// recoverable shared-memory state and silently reset the volume.
    func loadIfPresent(uid: String) -> DeviceVolumeState?

    func save(uid: String, volume: Float, muted: Bool)
}

// MARK: - Initialisation priority

/// Resolves what the Host should start with, in one documented order.
///
/// Priority, highest first:
///   1. the user's persisted setting for this device,
///   2. a shared-memory state that the previous Host process committed
///      (i.e. it crashed rather than cleaned up),
///   3. the safe default.
///
/// Expressed as a pure function so the ordering is testable and cannot be
/// re-derived incorrectly at a call site.
enum VolumeStateResolver {
    enum Source: String {
        case persisted
        case recovered
        case safeDefault
    }

    struct Resolution: Equatable {
        let scalar: Float
        let muted: Bool
        let mode: VolumeMode
        let source: Source
    }

    static func resolve(
        persisted: DeviceVolumeState?,
        recovered: RFVolumeStateSnapshotLike?
    ) -> Resolution {
        if let persisted {
            return Resolution(
                scalar: VolumeTaper.sanitize(
                    persisted.volumeScalar,
                    fallback: VolumeState.defaultScalar
                ),
                muted: persisted.isMuted,
                mode: .software,
                source: .persisted
            )
        }

        if let recovered, recovered.initialized {
            return Resolution(
                scalar: VolumeTaper.sanitize(
                    recovered.scalar,
                    fallback: VolumeState.defaultScalar
                ),
                muted: recovered.muted,
                mode: VolumeMode(protocolValue: recovered.mode),
                source: .recovered
            )
        }

        return Resolution(
            scalar: VolumeState.defaultScalar,
            muted: false,
            mode: .software,
            source: .safeDefault
        )
    }
}

/// Type-erased view of `RFVolumeStateSnapshot` so the resolver stays free of
/// the C module and can be unit-tested without a mapped file.
struct RFVolumeStateSnapshotLike: Equatable {
    let scalar: Float
    let muted: Bool
    let mode: UInt32
    let initialized: Bool
}

// MARK: - Runtime owner

/// Owns the Host runtime volume state and the revision counter mirrored into
/// shared memory.
///
/// Phase 2.1 scope: one store for the active device. Per-device routing, the
/// HARDWARE path and the capability model arrive in Phase 2.2; this type is
/// deliberately small so that change stays reviewable.
///
/// Revision rules:
///   - only `commit(...)` and `initialize(...)` move the counter,
///   - it moves strictly forward by exactly 1 per commit,
///   - re-committing an identical scalar+mute is a no-op and does NOT bump it,
///     so a 60 Hz volume-slider drag does not inflate the counter.
final class VolumeStateStore {
    private let lock = NSLock()
    private var current: VolumeState = .seed

    var snapshot: VolumeState {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Adopt the resolved starting state for a device.
    ///
    /// Always publishes a fresh revision: whatever the store held before is
    /// stale the moment a different device becomes active, even when the
    /// scalar happens to match.
    @discardableResult
    func initialize(scalar: Float, muted: Bool, mode: VolumeMode = .software) -> VolumeState {
        lock.lock()
        defer { lock.unlock() }
        current = VolumeState.committed(
            scalar: scalar,
            muted: muted,
            mode: mode,
            revision: current.revision &+ 1
        )
        return current
    }

    /// Commit a user-facing change.
    ///
    /// Returns the resulting state; `revision` moves forward only when the
    /// scalar or the mute flag actually changed.
    @discardableResult
    func commit(scalar: Float, muted: Bool, mode: VolumeMode? = nil) -> VolumeState {
        lock.lock()
        defer { lock.unlock() }

        let safeScalar = VolumeTaper.sanitize(
            scalar,
            fallback: current.requestedScalar
        )
        let nextMode = mode ?? current.mode

        if current.initialized,
           current.requestedScalar == safeScalar,
           current.isMuted == muted,
           current.mode == nextMode {
            return current
        }

        current = VolumeState.committed(
            scalar: safeScalar,
            muted: muted,
            mode: nextMode,
            revision: current.revision &+ 1
        )
        return current
    }

    /// Adopt a state that was read back from shared memory, but only when the
    /// store has nothing better. Used to keep a recovered state from being
    /// overwritten by seed defaults.
    @discardableResult
    func adoptIfUninitialized(_ state: VolumeState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !current.initialized else { return false }
        current = state
        return true
    }
}
