import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "DegradedRecovery")

/// Single-flight guard for the degraded → active transition.
///
/// The failure this exists to prevent is not hypothetical. `DeviceMonitor`
/// delivers `kAudioHardwarePropertyDevices` changes on the main queue and the
/// recovery it triggers immediately hops to a background queue to probe
/// CoreAudio. Between the hop and the result landing back on the main queue,
/// `DeviceMonitor.hostState` is still `.degraded`, so a second notification
/// passes the same `guard hostState == .degraded` and starts a second recovery.
/// Two recoveries mean two `AudioEngine.setup()` calls, and `setup()` creates a
/// new `AudioComponentInstance` before the first one is disposed — the first
/// unit is then both leaked and still running its render callback into the
/// same shared memory.
///
/// The gate is a value type with an injected clock-free API so the host tests
/// can drive it without CoreAudio or a device list.
struct DegradedRecoveryGate {
    private(set) var isRecovering = false
    private(set) var attempts = 0

    /// Ask for permission to run one recovery pass.
    ///
    /// - Parameter isDegraded: the caller's current lifecycle state. Passed in
    ///   rather than read from a captured object so the rule "recovery only
    ///   starts while degraded" is testable on its own.
    /// - Returns: `true` at most once per `.degraded` episode.
    mutating func begin(isDegraded: Bool) -> Bool {
        guard isDegraded else { return false }
        guard !isRecovering else {
            logger.info("Degraded recovery already in flight; ignoring duplicate device notification")
            return false
        }
        isRecovering = true
        attempts += 1
        return true
    }

    /// Release the guard. Must be called on every exit path from a pass,
    /// including the failing ones, or the Host stays degraded with recovery
    /// permanently disabled.
    mutating func finish() {
        isRecovering = false
    }
}
