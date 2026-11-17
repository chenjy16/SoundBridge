import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "DriverLifecycle")

// MARK: - The seven levels

/// Level 1: a bundle is on disk at the HAL plug-ins path.
///
/// The Host only reports what it can see from inside the process; the App owns
/// the version comparison, because only the App knows which driver it ships.
enum DriverFileStatus: String, Codable {
    case unknown
    case present
    case missing
}

/// Level 2: the installed bundle speaks this build's protocol.
enum DriverCompatibilityStatus: String, Codable {
    case unknown
    case compatible
    case incompatible
    case unreadable
}

/// Level 3: `coreaudiod` loaded the bundle.
///
/// There is no API that answers this directly. The honest evidence is the
/// driver's own shared-memory attachment (level 6) or the appearance of its
/// proxy device (level 4); a file on disk proves neither.
enum DriverLoadStatus: String, Codable {
    case unknown
    case notLoaded
    case loaded
}

/// Level 4a: CoreAudio enumerated the virtual proxy device.
enum HALDiscoveryStatus: String, Codable {
    case pending
    case discovered
    case notDiscovered
}

/// Level 4b/5: the Host matched that proxy device to a physical output.
enum ProxyDeviceStatus: String, Codable {
    case pending
    case found
    case missing
}

/// Level 6: the driver attached to the mapping this Host created.
///
/// `waitingForDriver` is the normal state on a quiet system: the driver sets
/// `driver_connected` from its IO callback, so it stays 0 until something
/// actually plays through the SoundBridge device. Treating that as a fault was
/// how the previous fixed two-second sleep became "looks fine" without meaning
/// anything. Only `disconnected` and `driverNotResponding` describe a driver
/// that was there and stopped.
enum SharedMemoryConnectionStatus: String, Codable {
    case pending
    case waitingForDriver
    case connected
    case disconnected
    case driverNotResponding
    case hostHeartbeatStalled
    case invalid
}

/// Level 7: audio frames actually moved through the ring.
enum AudioPipelineStatus: String, Codable {
    case pending
    case flowing
    case notStarted
    case stalled
}

/// The single answer the App consumes. One value, so "started" and "working"
/// can never be two different files saying two different things.
enum HostStartupOutcome: String, Codable {
    /// Initialisation in progress; no claim yet.
    case starting
    /// Proxy device found, engine running.
    case ready
    /// Another Host owns this UID's lock. Nothing was touched.
    case instanceConflict
    /// No proxy device appeared before the deadline.
    case proxyTimeout
    /// Our own mapping failed validation (header or protocol).
    case sharedMemoryInvalid
    /// Driver attached but stopped producing.
    case driverNotResponding
    /// No physical output device; Host is idle by design.
    case noPhysicalDevices
    /// Running, but not in the audio path (recovered into idle/degraded).
    case inactive
}

/// Everything the Host knows about its own lifecycle, published as one object.
///
/// Deliberately flat and string-valued: it crosses a JSON file to an older App
/// build that must be able to ignore fields it does not know about.
struct HostLifecycleSnapshot: Codable, Equatable {
    var outcome: HostStartupOutcome = .starting
    var driverFile: DriverFileStatus = .unknown
    var driverCompatibility: DriverCompatibilityStatus = .unknown
    var driverLoad: DriverLoadStatus = .unknown
    var halDiscovery: HALDiscoveryStatus = .pending
    var proxyDevice: ProxyDeviceStatus = .pending
    var sharedMemoryConnection: SharedMemoryConnectionStatus = .pending
    var audioPipeline: AudioPipelineStatus = .pending
    /// Free-form explanation for logs and for the App's message body.
    var detail: String?

    /// Seconds since the epoch. A number rather than a formatted date so the
    /// App and the Host cannot disagree about a `DateFormatter`.
    var updatedAt: TimeInterval = Date().timeIntervalSince1970

    func stamped(_ detail: String? = nil) -> HostLifecycleSnapshot {
        var copy = self
        copy.detail = detail ?? self.detail
        copy.updatedAt = Date().timeIntervalSince1970
        return copy
    }
}

// MARK: - Bounded readiness waiting

/// Result of one probe, from the waiter's point of view.
enum ReadinessSignal: Equatable {
    case ready
    /// Keep polling; the reason is what the timeout message will quote.
    case notYet(String)
    /// Stop now: more waiting cannot help (invalid mapping, no devices, ...).
    case terminal(String)
}

enum ReadinessOutcome: Equatable {
    case ready(polls: Int)
    case timedOut(polls: Int, lastReason: String)
    case terminal(reason: String, polls: Int)
}

/// Poll-until-ready with a hard deadline.
///
/// Replaces `Thread.sleep(deviceWaitTimeout)`, which asserted nothing: it
/// succeeded whether or not a proxy device ever appeared. Three properties are
/// the reason this is a type instead of a loop in `main`:
///
/// - every wait is bounded, so startup cannot hang;
/// - the probe is polled at a fixed interval instead of spinning;
/// - `now` and `sleep` are injected, so tests exercise the timeout path in
///   microseconds instead of sleeping for real.
struct ReadinessWaiter {
    let timeout: TimeInterval
    let pollInterval: TimeInterval
    var now: () -> Date
    var sleep: (TimeInterval) -> Void

    init(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.timeout = max(timeout, 0)
        // A zero interval would turn the deadline check into a busy loop.
        self.pollInterval = max(pollInterval, 0.001)
        self.now = now
        self.sleep = sleep
    }

    /// Poll `probe` until it says ready, refuses, or the deadline passes.
    ///
    /// The probe runs at least once, so an already-satisfied condition costs
    /// exactly one CoreAudio query and no sleep.
    func waitFor(_ probe: (Int) -> ReadinessSignal) -> ReadinessOutcome {
        let deadline = now().addingTimeInterval(timeout)
        var polls = 0

        while true {
            polls += 1
            switch probe(polls) {
            case .ready:
                return .ready(polls: polls)
            case .terminal(let reason):
                return .terminal(reason: reason, polls: polls)
            case .notYet(let reason):
                let remaining = deadline.timeIntervalSince(now())
                if remaining <= 0 {
                    return .timedOut(polls: polls, lastReason: reason)
                }
                sleep(min(pollInterval, remaining))
            }
        }
    }
}

// MARK: - Heartbeat liveness

/// Detects a driver that is attached but no longer producing.
///
/// `rf_update_driver_heartbeat` runs inside the driver's IO callback, so an
/// advancing counter is the only field in the header that proves audio is being
/// produced rather than merely promised. A single sample cannot tell "idle" from
/// "stuck", which is why the watch counts consecutive non-advancing samples
/// before calling it stalled.
struct DriverHeartbeatWatch: Equatable {
    /// How many consecutive unchanged samples count as stalled. Three samples at
    /// the Host's one-second poll is long enough that a normal scheduling hiccup
    /// does not trip it.
    let stallThreshold: Int
    private(set) var lastHeartbeat: UInt64?
    private(set) var unchangedSamples = 0

    init(stallThreshold: Int = 3) {
        self.stallThreshold = max(1, stallThreshold)
    }

    /// Record a sample. Returns `true` when the counter moved.
    ///
    /// `!=` rather than `>`: the counter is an `atomic_fetch_add` on a `uint64_t`,
    /// so it cannot realistically wrap, but liveness is "the writer ran", not
    /// "the number grew". Comparing for inequality keeps a re-initialised
    /// mapping (counter back to 0) from being read as a stall.
    @discardableResult
    mutating func observe(_ value: UInt64) -> Bool {
        defer { lastHeartbeat = value }

        guard let previous = lastHeartbeat else {
            // First sample is a baseline, not evidence of liveness.
            return false
        }
        if value != previous {
            unchangedSamples = 0
            return true
        }
        unchangedSamples += 1
        return false
    }

    var isStalled: Bool {
        return unchangedSamples >= stallThreshold
    }
}

/// One read of the connection fields in the shared header.
struct DriverConnectionObservation: Equatable {
    var headerValid: Bool
    var driverConnected: Bool
    var driverHeartbeat: UInt64
    var hostHeartbeat: UInt64
}

/// Turns a stream of observations into the level-6/7 status.
///
/// The two levels are deliberately not derived from one field:
///
/// - level 6 is `driver_connected`, which the driver sets when it attaches and
///   clears when it unloads. It says nothing about frames;
/// - level 7 is the heartbeat counter, which only advances while the driver's IO
///   callback runs. It says nothing about attachment.
///
/// The trap this avoids: `DoIOOperation` stops being called when playback stops,
/// so the heartbeat freezes on an idle machine. Reading a frozen heartbeat as
/// "driver not responding" would report a fault every time a user pauses music.
/// `driverNotResponding` is therefore reserved for the narrow case that is
/// actually wrong — the driver attached and then never produced a single frame.
struct DriverConnectionTracker {
    private(set) var hasEverConnected = false
    /// Set the first time the driver's counter is observed above zero. That is
    /// the only evidence in the header that frames were actually produced.
    private(set) var hasHeardDriverHeartbeat = false
    private var heartbeatWatch = DriverHeartbeatWatch()
    private var hostHeartbeatWatch = DriverHeartbeatWatch(stallThreshold: 5)

    /// Two thresholds, not one, because the two counters have different cadences.
    ///
    /// - `driverStallSamples` (3): the driver writes from its IO callback, which
    ///   runs at the buffer cadence, so three one-second samples without a change
    ///   is already a long gap.
    /// - `hostStallSamples` (5): our own timer writes once a second and the
    ///   monitor is *also* driven once a second, so the two can alias. A single
    ///   repeated sample is normal scheduling, not a fault; five gives the same
    ///   margin the driver gives us (it tolerates 15s of silence before it
    ///   considers the Host gone).
    init(driverStallSamples: Int = 3, hostStallSamples: Int = 5) {
        self.heartbeatWatch = DriverHeartbeatWatch(stallThreshold: driverStallSamples)
        self.hostHeartbeatWatch = DriverHeartbeatWatch(stallThreshold: hostStallSamples)
    }

    mutating func observe(_ observation: DriverConnectionObservation) -> SharedMemoryConnectionStatus {
        guard observation.headerValid else {
            return .invalid
        }

        // Our own timer stopping is a Host fault, not a driver fault, and the
        // read path would quietly starve. Surface it before blaming the driver.
        hostHeartbeatWatch.observe(observation.hostHeartbeat)
        if hostHeartbeatWatch.isStalled, hasEverConnected {
            return .hostHeartbeatStalled
        }

        guard observation.driverConnected else {
            return hasEverConnected ? .disconnected : .waitingForDriver
        }

        hasEverConnected = true
        if observation.driverHeartbeat > 0 {
            hasHeardDriverHeartbeat = true
        }
        heartbeatWatch.observe(observation.driverHeartbeat)

        // Attached, and still nothing produced after the full threshold. A device
        // that produced frames once and then went quiet is idle, not broken, so
        // it stays `.connected` and only level 7 moves to `.stalled`.
        if !hasHeardDriverHeartbeat, heartbeatWatch.isStalled {
            return .driverNotResponding
        }
        return .connected
    }

    /// Level 7: what the frame counter proves right now.
    var audioPipeline: AudioPipelineStatus {
        guard hasEverConnected else { return .pending }
        guard hasHeardDriverHeartbeat else { return .notStarted }
        return heartbeatWatch.isStalled ? .stalled : .flowing
    }

    /// Level 7, as a yes/no. Flowing means "advanced within the stall threshold",
    /// not "advanced at some point since startup".
    var isAudioFlowing: Bool {
        return audioPipeline == .flowing
    }
}
