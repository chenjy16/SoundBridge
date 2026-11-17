import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "HostLifecycle")

/// Samples a real mapping and reports level 6/7 transitions.
///
/// Runs on its own queue at the heartbeat interval. It never runs in the audio
/// callback: `SharedMemoryManager.getMemory` takes an `os_unfair_lock`, which is
/// forbidden on a real-time thread, and reading a heartbeat is not worth
/// blocking a render cycle for.
final class DriverConnectionMonitor {
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.soundbridge.host.connection", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tracker: DriverConnectionTracker = DriverConnectionTracker()
    private let sample: () -> DriverConnectionObservation?
    private let report: (SharedMemoryConnectionStatus, AudioPipelineStatus) -> Void

    init(
        interval: TimeInterval = SoundBridgeConfig.connectionPollInterval,
        stallThreshold: Int = 3,
        sample: @escaping () -> DriverConnectionObservation?,
        report: @escaping (SharedMemoryConnectionStatus, AudioPipelineStatus) -> Void
    ) {
        self.interval = max(interval, 0.1)
        self.tracker = DriverConnectionTracker(driverStallSamples: stallThreshold)
        self.sample = sample
        self.report = report
    }

    func start() {
        guard timer == nil else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        timer = source
        logger.info("Driver connection monitor started (interval \(self.interval, format: .fixed(precision: 2))s)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let observation = sample() else { return }
        let status = tracker.observe(observation)
        report(status, tracker.audioPipeline)
    }
}

/// Owns the lifecycle snapshot and is the only writer of it.
///
/// Thread-safety matters here: `main` sets levels from the startup path while
/// the connection monitor updates level 6/7 from its own queue. One lock, one
/// snapshot, one publisher — so the App never reads a half-updated object.
final class HostLifecycleReporter {
    private var snapshot = HostLifecycleSnapshot()
    private var lock = os_unfair_lock()
    private var lastPublished: HostLifecycleSnapshot?
    private let publish: (HostLifecycleSnapshot) -> Void

    init(publish: @escaping (HostLifecycleSnapshot) -> Void) {
        self.publish = publish
    }

    func current() -> HostLifecycleSnapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return snapshot
    }

    /// Merge a change and publish it if anything moved.
    ///
    /// Publishing only on change keeps the App's file watcher from waking up on
    /// every identical poll.
    func update(_ mutate: (inout HostLifecycleSnapshot) -> Void) {
        os_unfair_lock_lock(&lock)
        let before = snapshot
        mutate(&snapshot)
        snapshot.updatedAt = Date().timeIntervalSince1970
        let after = snapshot
        os_unfair_lock_unlock(&lock)

        guard after != before, after != lastPublished else { return }
        lastPublished = after
        publish(after)
        logger.info(
            "Lifecycle: outcome=\(after.outcome.rawValue, privacy: .public) driver=\(after.driverFile.rawValue, privacy: .public)/\(after.driverCompatibility.rawValue, privacy: .public) load=\(after.driverLoad.rawValue, privacy: .public) hal=\(after.halDiscovery.rawValue, privacy: .public) proxy=\(after.proxyDevice.rawValue, privacy: .public) shm=\(after.sharedMemoryConnection.rawValue, privacy: .public) audio=\(after.audioPipeline.rawValue, privacy: .public)"
        )
        if let detail = after.detail {
            logger.info("Lifecycle detail: \(detail, privacy: .public)")
        }
    }
}
