import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "HostLifecycle")

/// Samples a real mapping and reports level 6/7 transitions.
///
/// 在主队列采样和发布，与恢复、停止及设备状态修改串行。
/// 它不在实时音频回调中运行。
final class DriverConnectionMonitor {
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var tracker: DriverConnectionTracker = DriverConnectionTracker()
    private let lifecycleGate: HostLifecycleGate
    private var runGeneration: UInt64 = 0
    private var lifecycleToken: UInt64?
    private let sample: () -> DriverConnectionObservation?
    private let report: (SharedMemoryConnectionStatus, AudioPipelineStatus) -> Void

    init(
        interval: TimeInterval = SoundBridgeConfig.connectionPollInterval,
        stallThreshold: Int = 3,
        lifecycleGate: HostLifecycleGate,
        sample: @escaping () -> DriverConnectionObservation?,
        report: @escaping (SharedMemoryConnectionStatus, AudioPipelineStatus) -> Void
    ) {
        self.interval = max(interval, 0.1)
        self.tracker = DriverConnectionTracker(driverStallSamples: stallThreshold)
        self.lifecycleGate = lifecycleGate
        self.sample = sample
        self.report = report
    }

    /// start、stop 和采样必须与设备生命周期一样由主队列串行调用。
    func start() {
        guard timer == nil, let token = lifecycleGate.normalToken() else { return }
        runGeneration &+= 1
        let generation = runGeneration
        lifecycleToken = token
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in
            self?.tick(expectedGeneration: generation)
        }
        timer = source
        source.resume()
        logger.info("Driver connection monitor started (interval \(self.interval, format: .fixed(precision: 2))s)")
    }

    func stop() {
        runGeneration &+= 1
        lifecycleToken = nil
        timer?.cancel()
        timer = nil
    }

    /// 可由隔离测试同步驱动；生产计时器传入创建时的代际。
    func sampleNow() {
        tick(expectedGeneration: runGeneration)
    }

    private func tick(expectedGeneration: UInt64) {
        guard timer != nil, expectedGeneration == runGeneration,
              let token = lifecycleToken, lifecycleGate.permitsNormal(token),
              let observation = sample() else { return }
        guard timer != nil, expectedGeneration == runGeneration,
              lifecycleGate.permitsNormal(token) else { return }
        let status = tracker.observe(observation)
        report(status, tracker.audioPipeline)
    }
}

/// Owns the lifecycle snapshot and is the only writer of it.
///
/// 快照更新和发布按同一锁串行，避免旧快照晚于新快照写入状态文件。
final class HostLifecycleReporter {
    private var snapshot = HostLifecycleSnapshot()
    private let lock = NSRecursiveLock()
    private let publish: (HostLifecycleSnapshot) -> Void
    private let log: (String) -> Void
    private var emittedLogLines = 0

    /// How many log lines this reporter has emitted. A repeated poll with the
    /// same content must not move it; that is the property the logging tests pin.
    var logLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return emittedLogLines
    }

    /// - Parameter log: sink for the human-readable lines. Injectable so a test
    ///   can count them instead of reading the unified log.
    init(
        publish: @escaping (HostLifecycleSnapshot) -> Void,
        log: ((String) -> Void)? = nil
    ) {
        self.publish = publish
        self.log = log ?? { message in logger.info("\(message, privacy: .public)") }
    }

    func current() -> HostLifecycleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Merge a change and publish it.
    ///
    /// Every call refreshes `updatedAt` and writes the file, because that
    /// timestamp is the App's evidence that the Host is alive: skipping the write
    /// would make a running Host look stale. Logging, by contrast, is tied to
    /// *content* changes — `updatedAt` moves on every poll, and comparing whole
    /// snapshots made one second of polling look like a state transition and
    /// printed the same INFO line (and the same detail) once per second.
    func update(_ mutate: (inout HostLifecycleSnapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let before = snapshot
        mutate(&snapshot)
        snapshot.updatedAt = Date().timeIntervalSince1970
        let after = snapshot

        let contentChanged = !Self.hasSameContent(before, after)
        publish(after)

        guard contentChanged else { return }

        emittedLogLines += 1
        log(
            "Lifecycle: outcome=\(after.outcome.rawValue) driver=\(after.driverFile.rawValue)/\(after.driverCompatibility.rawValue) load=\(after.driverLoad.rawValue) hal=\(after.halDiscovery.rawValue) proxy=\(after.proxyDevice.rawValue) shm=\(after.sharedMemoryConnection.rawValue) audio=\(after.audioPipeline.rawValue)"
        )
        if let detail = after.detail {
            emittedLogLines += 1
            log("Lifecycle detail: \(detail)")
        }
    }

    /// Compare everything a reader can act on, ignoring the heartbeat timestamp.
    private static func hasSameContent(_ lhs: HostLifecycleSnapshot, _ rhs: HostLifecycleSnapshot) -> Bool {
        var left = lhs
        var right = rhs
        left.updatedAt = 0
        right.updatedAt = 0
        return left == right
    }
}
