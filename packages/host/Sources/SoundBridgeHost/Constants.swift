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
