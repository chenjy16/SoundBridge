import Foundation
import CSoundBridgeAudio

struct SoundBridgeConfig {
    /// 采样率的线程安全访问
    private static var _activeSampleRate: UInt32 = 48000
    private static var sampleRateLock = os_unfair_lock()

    static var activeSampleRate: UInt32 {
        get {
            os_unfair_lock_lock(&sampleRateLock)
            defer { os_unfair_lock_unlock(&sampleRateLock) }
            return _activeSampleRate
        }
        set {
            os_unfair_lock_lock(&sampleRateLock)
            _activeSampleRate = newValue
            os_unfair_lock_unlock(&sampleRateLock)
        }
    }
    /// Fallback sample rate if device query fails
    static let defaultSampleRate: UInt32 = 48000
    static let defaultChannels: UInt32 = 2
    static let defaultFormat = RF_FORMAT_FLOAT32
    static let defaultDurationMs: UInt32 = 100

    // MARK: - Render callback capacity (P2 Batch 4)

    /// The highest sample rate `AudioEngine` will bind to.
    ///
    /// `AudioEngine.getDeviceNominalSampleRate` snaps the device to a rate from
    /// a fixed list; 192 kHz is its top. Capacity is calculated at this rate so
    /// a device switch never finds the pre-allocated render buffer too small.
    static let maxSupportedSampleRate: UInt32 = 192_000

    /// Largest block the real-time callback accepts, in frames.
    ///
    /// Derived from the frozen `rf_ring_capacity_frames_for` the Host already
    /// uses to size the shared-memory ring, at the highest supported rate. That
    /// makes it the same 100 ms of audio the producer can queue: a callback
    /// cannot legitimately be asked for more than the ring can hold, and any
    /// larger request is refused instead of overflowing the buffer.
    static var maxCallbackFrames: Int {
        Int(rf_ring_capacity_frames_for(maxSupportedSampleRate, defaultDurationMs))
    }

    /// Channel ceiling for the render path.
    ///
    /// The shared-memory header documents `channels` as 1-8, so 8 is the ABI's
    /// limit rather than an estimate.
    static let maxCallbackChannels = 8

    /// Total span of the software volume taper, in decibels below unity.
    ///
    /// Single source of truth is `VolumeTaper.rangeDB`; this is only an alias
    /// for code that already reads the config object. The curve itself is
    /// `dB = 48 * sqrt(scalar) - 48`, matching the driver's 48 dB Pow2
    /// `aspl::VolumeControlParameters`. Applying a *linear* mapping to this
    /// range (as was done before Phase 2.1) put the Host up to ~29 dB away
    /// from what the proxy device reported.
    static var volumeRangeDB: Float { VolumeTaper.rangeDB }

    static var controlFilePath: String {
        return PathManager.controlFilePath
    }

    static let heartbeatInterval: TimeInterval = 1.0
    static let wakeRecoveryDelay: TimeInterval = 1.5
    static let wakeRetryMaxAttempts = 4
    static let wakeRetryDelays: [TimeInterval] = [0, 2.0, 4.0, 8.0]

    static let deviceWaitTimeout: TimeInterval = 2.0
    static let cleanupWaitTimeout: TimeInterval = 1.2
    static let physicalDeviceSwitchDelay: TimeInterval = 0.5

    // MARK: - Startup readiness

    /// How long startup waits for the driver's proxy device to show up in the
    /// HAL device list.
    ///
    /// This replaces a fixed two-second sleep that asserted nothing. Five seconds
    /// covers a cold `coreaudiod` load after a reboot with room to spare, and it
    /// is a ceiling rather than a cost: the wait ends the moment the device
    /// appears.
    static let proxyDiscoveryTimeout: TimeInterval = 5.0

    /// Poll interval while waiting for the proxy device. Short enough that a
    /// device appearing at 4.9s is still picked up promptly, long enough that
    /// the CoreAudio queries do not dominate startup.
    static let proxyPollInterval: TimeInterval = 0.1

    /// How often the connection monitor samples `driver_connected` and the
    /// heartbeats once the audio engine is running.
    static let connectionPollInterval: TimeInterval = 1.0

    // MARK: - CoreAudio rebuild

    /// Delay before the single confirmation probe that follows a suspect
    /// rebuild sample.
    ///
    /// The detector confirms on two consecutive samples, and normally the
    /// second one arrives as the next device notification. A HAL that rebuilds
    /// without sending one would leave the Host stuck on a single suspect
    /// sample — the 1.2.0 symptom — so one probe is scheduled. 1.5 s is long
    /// enough for `coreaudiod` to finish re-enumerating and short enough that a
    /// genuine rebuild is still recovered while the user is looking at it.
    static let coreAudioRebuildRecheckDelay: TimeInterval = 1.5

    // MARK: - Exit policy

    /// Whether the Host may restart `coreaudiod` when it exits.
    ///
    /// Off, and that is a product decision rather than an oversight: the driver
    /// no longer needs a coreaudiod restart to notice a removed Host (it watches
    /// the mapping), and killing the system audio daemon on every Host quit
    /// takes every other application's audio down with it. Phase 2.1.4 forbids
    /// an automatic restart, so this stays `false` until a release deliberately
    /// changes the policy.
    static let restartsCoreAudioOnExit = false
}
