import Foundation

// MARK: - What the Host says about itself

/// Mirror of the `lifecycle` object the Host writes into `device-state.json`.
///
/// Every field is optional and string-valued on purpose. This is a file two
/// independently-versioned processes share: an older Host omits the whole object,
/// a newer one may add levels this build has never heard of, and neither may make
/// the other fail to decode. The Host's raw values are the contract; switching on
/// the strings here (rather than inventing an enum that throws on the unknown) is
/// what keeps an unknown future level readable as `.unknown`.
struct HostLifecycleReport: Codable, Equatable {
    var outcome: String?
    var driverFile: String?
    var driverCompatibility: String?
    var driverLoad: String?
    var halDiscovery: String?
    var proxyDevice: String?
    var sharedMemoryConnection: String?
    var audioPipeline: String?
    var detail: String?
    var updatedAt: TimeInterval?

    /// `true` when the Host reported audio actually moving through the ring.
    var isAudioFlowing: Bool {
        return audioPipeline == "flowing"
    }

    /// Age of this report. Stale reports are how a dead Host keeps looking alive,
    /// so the app checks this rather than trusting the last file it saw.
    func age(now: Date = Date()) -> TimeInterval? {
        guard let updatedAt else { return nil }
        return now.timeIntervalSince1970 - updatedAt
    }
}

// MARK: - What the app tells the user

/// One value the menu bar and any alert can switch on.
///
/// The states are deliberately more numerous than "running / not running". A Host
/// that is running but never found its proxy device looks identical to a healthy
/// one from the outside — that was the original complaint: silence with no
/// explanation. Each case below is a different sentence the user can act on.
enum HostRunState: Equatable {
    /// No process holds the instance lock.
    case notRunning
    /// The Host is up and still deciding.
    case starting
    /// Routed through the proxy device. `flowing` distinguishes "playing" from
    /// "routed but nothing has produced a frame yet", which is normal on a quiet
    /// system and must not be shown as a fault.
    case ready(flowing: Bool)
    /// Host running, mapping valid, driver has never attached. Normal until
    /// something plays through the SoundBridge device.
    case waitingForDriver
    /// No proxy device appeared, or the default output is not one this Host
    /// manages. Audio goes wherever it went before.
    case proxyUnavailable
    /// Our own mapping failed validation — an internal inconsistency.
    case sharedMemoryInvalid
    /// Attached but produced nothing, or our own heartbeat stopped.
    case driverNotResponding
    /// No physical output device to bridge. Idle by design.
    case noOutputDevices
    /// Another Host owned the lock; this one refused to start and touched nothing.
    case instanceConflict
    /// Up, but not in the audio path.
    case inactive
    /// A report this build does not understand.
    case unknown

    /// Derive the user-visible state from the two things the app actually knows:
    /// whether the lock is held, and what the Host last wrote.
    ///
    /// The lock outranks the file. A Host that was killed leaves `device-state.json`
    /// behind saying `ready`; reporting that as running is how the app used to lie
    /// about a dead process.
    static func resolve(report: HostLifecycleReport?, hostRunning: Bool) -> HostRunState {
        guard hostRunning else { return .notRunning }
        guard let report else { return .starting }

        switch report.outcome {
        case "instanceConflict":
            return .instanceConflict
        case "noPhysicalDevices":
            return .noOutputDevices
        case "sharedMemoryInvalid":
            return .sharedMemoryInvalid
        case "driverNotResponding":
            return .driverNotResponding
        case "proxyTimeout", "deviceNotFound":
            return .proxyUnavailable
        case "inactive":
            // A degraded Host that later recovered keeps writing `ready`; only an
            // unrecovered one stays here.
            if report.sharedMemoryConnection == "connected" {
                return .ready(flowing: report.isAudioFlowing)
            }
            return report.sharedMemoryConnection == "waitingForDriver" ? .waitingForDriver : .inactive
        case "ready":
            if report.sharedMemoryConnection == "waitingForDriver" {
                return .waitingForDriver
            }
            return .ready(flowing: report.isAudioFlowing)
        case "starting", .none:
            return .starting
        default:
            return .unknown
        }
    }

    /// One line for the menu bar. Short on purpose: this is not the place for a
    /// paragraph, and every longer explanation belongs in the compatibility
    /// notice, which carries the versions and the download location.
    var shortMessage: String {
        switch self {
        case .notRunning:
            return "Audio host is not running"
        case .starting:
            return "Starting audio host…"
        case .ready(let flowing):
            return flowing ? "Connected" : "Routed — no audio playing"
        case .waitingForDriver:
            return "Waiting for audio driver"
        case .proxyUnavailable:
            return "SoundBridge device is not available"
        case .sharedMemoryInvalid:
            return "Audio engine could not initialise"
        case .driverNotResponding:
            return "Audio driver stopped responding"
        case .noOutputDevices:
            return "No output device"
        case .instanceConflict:
            return "Another SoundBridge host is already running"
        case .inactive:
            return "Audio host is idle"
        case .unknown:
            return "Audio host state is unknown"
        }
    }

    /// Whether this is something the user should be told about unprompted.
    ///
    /// `waitingForDriver` is excluded: it is the normal state on a machine where
    /// nothing plays through SoundBridge, and an alert for it would be noise.
    var isProblem: Bool {
        switch self {
        case .notRunning, .proxyUnavailable, .sharedMemoryInvalid, .driverNotResponding, .instanceConflict:
            return true
        case .starting, .ready, .waitingForDriver, .noOutputDevices, .inactive, .unknown:
            return false
        }
    }
}
