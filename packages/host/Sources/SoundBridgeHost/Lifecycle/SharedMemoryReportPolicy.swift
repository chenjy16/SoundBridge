import Foundation

// MARK: - One connection report

/// Everything one `DriverConnectionMonitor` report changes in the snapshot.
///
/// Lifted out of `main.swift` so the wording rules are testable without a Host
/// process: the bug this replaces was a *text* decision — a freshly published
/// mapping, which legitimately starts with `driver_connected == 0`, was described
/// with the previous incarnation's "driver detached" sentence, and the sentence
/// then survived every later poll because nothing overwrote it.
enum SharedMemoryReportPolicy {

    /// Merge `status` / `pipeline` into `snapshot`.
    ///
    /// Returns `false` when the report repeats the state already recorded. The
    /// caller uses that to leave the rest of the snapshot untouched: an
    /// identical poll must not look like a transition, because the reporter logs
    /// transitions and would otherwise print the same line once a second.
    @discardableResult
    static func apply(
        _ status: SharedMemoryConnectionStatus,
        pipeline: AudioPipelineStatus,
        hostIsActive: Bool,
        to snapshot: inout HostLifecycleSnapshot
    ) -> Bool {
        let changed = snapshot.sharedMemoryConnection != status
            || snapshot.audioPipeline != pipeline
        snapshot.sharedMemoryConnection = status
        snapshot.audioPipeline = pipeline

        guard changed else { return false }

        switch status {
        case .connected:
            snapshot.driverLoad = .loaded
            snapshot.halDiscovery = .discovered
            snapshot.proxyDevice = .found
        case .driverNotResponding:
            // Attached but never produced a frame — the narrow case that really
            // is wrong. A device that played and went quiet stays `.connected`
            // with `pipeline == .stalled`, because a pause is not a fault.
            snapshot.outcome = .driverNotResponding
        default:
            break
        }

        // The wording is derived from the status alone, so a new mapping or a
        // retired file cannot leave the previous incarnation's "detached" line
        // behind. `.disconnected` is the only status the tracker reports after a
        // driver actually attached to this incarnation and left.
        if let detail = SharedMemoryConnectionDetail.detail(for: status) {
            snapshot.detail = detail
        }

        if status == .connected, hostIsActive {
            snapshot.outcome = .ready
            snapshot.detail = pipeline == .flowing
                ? "audio flowing through the driver"
                : "routed through the proxy device; no frames yet"
        }
        return true
    }
}
