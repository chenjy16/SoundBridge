import Foundation
import Darwin
import os.log

private let supervisorLog = Logger(subsystem: "com.soundbridge.app", category: "HostSupervisor")

// MARK: - Vocabulary

/// Why the App is asking the Host it owns to stop.
///
/// The three cases are deliberately *not* one "stop" flag: what has to happen
/// after the process exits is different in each, and the Gate 3 defect was a
/// single `terminationHandler` that treated all of them as "quit the App".
enum HostStopIntent: Equatable, CustomStringConvertible {
    /// The user quit the App. Nothing may be restarted; the supervisor stops.
    case appTermination
    /// The uninstall path already killed the Host and removed the driver. Also
    /// final: relaunching a Host with no driver would be a recovery storm.
    case uninstall
    /// Host-only restart. The App keeps running and a new Host takes over.
    case restart

    /// `true` when the intent ends the App's ownership of the Host.
    var endsOwnership: Bool { self != .restart }

    var description: String {
        switch self {
        case .appTermination: return "app termination"
        case .uninstall: return "uninstall"
        case .restart: return "host-only restart"
        }
    }
}

/// Why the supervisor stopped trying.
enum HostSupervisorFailure: Equatable, CustomStringConvertible {
    /// No `SoundBridgeHost` executable was found or it could not be turned into
    /// a `Process`. Retrying cannot fix a missing binary.
    case executableMissing
    /// `Process.run()` threw.
    case launchFailed(String)
    /// The process was alive past `launchTimeout` but never took the instance
    /// lock, so it was not a working Host.
    case launchTimedOut
    /// The Host exited on its own, repeatedly.
    case exited(status: Int32)

    var description: String {
        switch self {
        case .executableMissing: return "the Host executable could not be found"
        case .launchFailed(let message): return "launch failed: \(message)"
        case .launchTimedOut: return "the Host did not take the instance lock in time"
        case .exited(let status): return "the Host exited on its own (status \(status))"
        }
    }
}

/// What the supervisor is doing with the Host it owns.
///
/// ```
///                 start()                     lock acquired
///   idle ─────────────────► launching(attempt) ──────────────► running(pid)
///    ▲  ◄────── launch failed / exited ──┐                        │
///    │                                   │                        │ restart()
///    │            backoff, bounded retries│                        ▼
///    │                                   │                    stopping(.restart)
///    │                                   │                        │ exited
///    │                                   └────────────────────────┘
///    │                                            (relaunch)
///    ├──────────── exited with no restart ───────────────────────┘
///    │
///  degraded(failure, attempts)   ← maxConsecutiveFailures reached
///  notOwned                      ← another process holds the instance lock
/// ```
enum HostSupervisorState: Equatable, CustomStringConvertible {
    /// Nothing is owned. Either not started yet, or the last Host is gone.
    case idle
    case launching(attempt: Int)
    case running(pid: Int32)
    case stopping(HostStopIntent)
    /// Stopped trying. The App keeps running and says so; it does not quit.
    case degraded(failure: HostSupervisorFailure, attempts: Int)
    /// The instance lock is held by a Host this App did not start. Starting a
    /// second one would mean two producers for one mapping, so we stay out.
    case notOwned

    var description: String {
        switch self {
        case .idle: return "idle"
        case .launching(let attempt): return "launching(attempt: \(attempt))"
        case .running(let pid): return "running(pid: \(pid))"
        case .stopping(let intent): return "stopping(\(intent))"
        case .degraded(let failure, let attempts): return "degraded(\(failure), after \(attempts))"
        case .notOwned: return "notOwned"
        }
    }
}

// MARK: - Locator

/// Finds the `SoundBridgeHost` executable this bundle ships.
///
/// Moved out of `AppDelegate` unchanged in substance: the production bundle is
/// searched first, and the development tree only under `#if DEBUG`. Kept separate
/// so the supervisor can be given a different `Process` factory in tests without
/// anyone having to stand up a real Host.
enum HostExecutableLocator {

    /// Paths to try, in priority order.
    static func candidates(fileManager: FileManager = .default) -> [String] {
        var paths: [String] = []

        // PRIORITY 1: auxiliary executable in the .app bundle (production)
        if let helperURL = Bundle.main.url(forAuxiliaryExecutable: "SoundBridgeHost") {
            paths.append(helperURL.path)
        }

        // PRIORITY 2: embedded binary next to the App's own executable
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent().path {
            paths.append("\(executableDirectory)/SoundBridgeHost")
        }

        // PRIORITY 3: Contents/Helpers/
        paths.append("\(Bundle.main.bundlePath)/Contents/Helpers/SoundBridgeHost")

        #if DEBUG
        var basePaths: [String] = []
        let appPath = Bundle.main.bundlePath
        if appPath.contains("/SoundBridgeApp/") {
            let appURL = URL(fileURLWithPath: appPath)
            basePaths.append(
                appURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .path
            )
        }
        basePaths.append(fileManager.currentDirectoryPath)
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            basePaths.append("\(home)/soundbridge")
        }

        for base in basePaths {
            if let arch = architectureDirectoryName() {
                paths.append("\(base)/packages/host/.build/\(arch)/release/SoundBridgeHost")
            }
            paths.append("\(base)/packages/host/.build/release/SoundBridgeHost")
            if let arch = architectureDirectoryName() {
                paths.append("\(base)/packages/host/.build/\(arch)/debug/SoundBridgeHost")
            }
            paths.append("\(base)/packages/host/.build/debug/SoundBridgeHost")
        }

        if let home = ProcessInfo.processInfo.environment["HOME"] {
            if let arch = architectureDirectoryName() {
                paths.append("\(home)/soundbridge/packages/host/.build/\(arch)/release/SoundBridgeHost")
            }
            paths.append("\(home)/soundbridge/packages/host/.build/release/SoundBridgeHost")
        }

        if let root = ProcessInfo.processInfo.environment["SOUNDBRIDGE_ROOT"] {
            if let arch = architectureDirectoryName() {
                paths.append("\(root)/packages/host/.build/\(arch)/release/SoundBridgeHost")
            }
            paths.append("\(root)/packages/host/.build/release/SoundBridgeHost")
        }
        #endif

        return paths
    }

    static func locate(fileManager: FileManager = .default) -> URL? {
        let all = candidates(fileManager: fileManager)
        guard let hit = all.first(where: { fileManager.fileExists(atPath: $0) }) else {
            supervisorLog.error("Could not find SoundBridgeHost. Searched: \(all.joined(separator: ", "), privacy: .public)")
            return nil
        }
        return URL(fileURLWithPath: hit)
    }

    /// Production factory. Standard output and error are captured into a pipe so
    /// a Host that fails to start leaves evidence instead of silence.
    static func makeProcess() -> Process? {
        guard let url = locate() else { return nil }
        let process = Process()
        process.executableURL = url
        process.arguments = []
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        return process
    }

    /// SwiftPM's architecture directory name (`arm64-apple-macosx`, …).
    static func architectureDirectoryName() -> String? {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let arch = String(cString: machine)

        if arch.contains("arm64") {
            return "arm64-apple-macosx"
        } else if arch.contains("x86_64") {
            return "x86_64-apple-macosx"
        }
        return nil
    }
}

// MARK: - Supervisor

/// Single owner of the Host process this App starts.
///
/// Gate 3's second defect was here: `AppDelegate`'s `terminationHandler` called
/// `NSApp.terminate(nil)` whenever the Host exited for any reason other than an
/// uninstall, so the App could never survive a Host crash, and there was no way
/// to restart the Host without restarting the App.
///
/// This type answers the three questions that were missing:
///
/// 1. *Who owns the Host?* Exactly one `Process`, `nil` once it has been reaped.
/// 2. *Was the exit expected?* `stopIntent` is set before a stop, so a crash and
///    an intentional stop cannot be confused.
/// 3. *May another Host start?* Only when no process is owned and the instance
///    lock is free — never twice, never while the old one is alive.
///
/// Concurrency: every state change happens on `queue`, a serial queue. The
/// `Process.terminationHandler` (arbitrary thread) and the public API only
/// enqueue. Nothing here runs on the realtime audio path, and nothing here waits
/// on the main thread; `shutdown(waitTimeout:)` is the single exception and is
/// only used while the App is already terminating.
final class HostSupervisor {

    struct Configuration {
        /// How long a started process has to take the instance lock before it is
        /// treated as a failed launch.
        var launchTimeout: TimeInterval = 6.0
        /// SIGTERM → SIGKILL grace. The Host's ordered teardown needs ~1.2s.
        var gracefulExitTimeout: TimeInterval = 2.5
        /// How long to wait for a SIGKILL to be reflected in `Process.isRunning`.
        var killGraceTimeout: TimeInterval = 1.0
        /// Stop trying after this many consecutive failed starts.
        var maxConsecutiveFailures: Int = 3
        var initialBackoff: TimeInterval = 0.5
        var maximumBackoff: TimeInterval = 8.0
        /// Injectable so tests never touch the real executable or the real lock.
        var makeProcess: () -> Process? = { HostExecutableLocator.makeProcess() }
        var isHostRunning: () -> Bool = { HostInstanceProbe.isHostRunning() }
    }

    /// Called on the main queue after every state change. Used for logging and
    /// for telling the menu bar the Host is degraded; it must stay cheap.
    var onStateChange: ((HostSupervisorState) -> Void)?

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.soundbridge.app.host-supervisor", qos: .utility)

    // MARK: Queue-confined state

    private var state: HostSupervisorState = .idle
    private var process: Process?
    /// Incremented for every launch. A termination event carries the value it was
    /// created with, so an event from a process this supervisor already replaced
    /// cannot act on the new one.
    private var launchToken: UInt64 = 0
    private var isShutdown = false
    private var consecutiveFailures = 0
    private var lastFailure: HostSupervisorFailure?
    /// Set when the watchdog declared the current launch dead. The exit it
    /// provokes is still counted once, in `handleTerminationOnQueue`.
    private var timedOutLaunch = false
    private var stopIntent: HostStopIntent?
    private var watchdog: DispatchWorkItem?
    private var killEscalation: DispatchWorkItem?
    private var relaunch: DispatchWorkItem?
    private var shutdownWaiters: [() -> Void] = []

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    deinit {
        watchdog?.cancel()
        killEscalation?.cancel()
        relaunch?.cancel()
    }

    // MARK: - Public API

    /// Start a Host unless one is already owned or another process holds the
    /// instance lock. Safe to call more than once; only the first one launches.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else {
                supervisorLog.info("start() ignored: the supervisor is shut down")
                return
            }
            switch self.state {
            case .idle, .degraded:
                // An explicit start is a fresh budget: a user or a diagnostic
                // asked for a Host, which is different from a crash loop.
                self.consecutiveFailures = 0
                self.lastFailure = nil
                self.launch(attempt: 0)
            case .launching, .running, .stopping, .notOwned:
                supervisorLog.info("start() ignored in state \(self.state.description, privacy: .public)")
            }
        }
    }

    /// Replace the Host this App owns. The App keeps running, keeps its PID, and
    /// keeps its mapping manager (which observes the new publication).
    ///
    /// Single-flight: a request that arrives while a launch, a stop, or a
    /// relaunch is already in progress is folded into that operation instead of
    /// queueing a second one.
    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isShutdown else {
                supervisorLog.info("restart() ignored: the supervisor is shut down")
                return
            }
            switch self.state {
            case .running, .launching:
                self.consecutiveFailures = 0
                self.lastFailure = nil
                self.stopOwnedProcess(intent: .restart)
            case .stopping:
                // Already on the way out, and `.restart` already implies a
                // relaunch once the process is reaped. A second request adds
                // nothing; that is the single-flight guarantee.
                supervisorLog.info("restart() coalesced into the in-flight stop")
            case .idle, .degraded:
                self.consecutiveFailures = 0
                self.lastFailure = nil
                self.launch(attempt: 0)
            case .notOwned:
                supervisorLog.info("restart() ignored: the Host is owned by another process")
            }
        }
    }

    /// Stop the Host this App owns and give up ownership.
    ///
    /// - Parameters:
    ///   - intent: `.appTermination` or `.uninstall` for good; nothing relaunches.
    ///   - waitTimeout: only used when the App is already terminating and the
    ///     process must not outlive it. Never pass this from the UI.
    func shutdown(intent: HostStopIntent, waitTimeout: TimeInterval? = nil, completion: (() -> Void)? = nil) {
        let semaphore = waitTimeout == nil ? nil : DispatchSemaphore(value: 0)

        queue.async { [weak self] in
            guard let self else {
                semaphore?.signal()
                completion?()
                return
            }
            self.isShutdown = true
            self.relaunch?.cancel()
            self.relaunch = nil
            self.shutdownWaiters.append {
                semaphore?.signal()
                completion?()
            }

            switch self.state {
            case .launching, .running, .stopping:
                self.stopOwnedProcess(intent: intent)
            default:
                self.stopIntent = nil
                self.transition(to: .idle)
                self.flushShutdownWaiters()
            }
        }

        if let waitTimeout, let semaphore {
            _ = semaphore.wait(timeout: .now() + waitTimeout)
        }
    }

    // MARK: - Observation

    var currentState: HostSupervisorState {
        queue.sync { state }
    }

    /// PID of the Host this App is currently supervising, if any.
    var ownedProcessIdentifier: Int32? {
        queue.sync { process?.processIdentifier }
    }

    /// Whether the supervisor gave up. The App renders this as `degraded`
    /// instead of exiting; nothing here decides to quit.
    var isDegraded: Bool {
        if case .degraded = queue.sync(execute: { state }) { return true }
        return false
    }

    /// Whether ownership has been given up for good (`shutdown` was called).
    ///
    /// `restart()` already ignores a request from this state; exposing it lets the
    /// menu item answer "nothing will happen, and here is why" instead of looking
    /// like a click that was swallowed. Read-only and non-blocking: it takes the
    /// same serial queue every other state read takes.
    var isShutDown: Bool {
        queue.sync { isShutdown }
    }

    /// The launch generation in flight. Exposed so tests can replay a late
    /// termination event and prove it is ignored.
    var currentLaunchToken: UInt64 {
        queue.sync { launchToken }
    }

    // MARK: - Termination (internal for tests)

    /// Reap a process. Called from `Process.terminationHandler` on whatever
    /// thread the process monitor uses, and directly by tests to replay a late
    /// or duplicated event.
    func handleTermination(token: UInt64, status: Int32, reason: Process.TerminationReason) {
        queue.async { [weak self] in
            self?.handleTerminationOnQueue(token: token, status: status, reason: reason)
        }
    }

    private func handleTerminationOnQueue(token: UInt64, status: Int32, reason: Process.TerminationReason) {
        guard token == launchToken else {
            // A process this supervisor already replaced. Acting on it would
            // either relaunch over a healthy Host or clear the new one's state.
            supervisorLog.info("Ignoring a late termination event for launch #\(token) (current #\(self.launchToken))")
            return
        }
        guard let process else {
            // Second callback for the same launch. The first one already
            // reaped it; there is nothing left to clean up.
            supervisorLog.info("Ignoring a duplicate termination event for launch #\(token)")
            return
        }

        self.process = nil
        watchdog?.cancel()
        watchdog = nil
        killEscalation?.cancel()
        killEscalation = nil

        let pid = process.processIdentifier
        let intent = stopIntent
        stopIntent = nil
        supervisorLog.info(
            "Host pid \(pid) exited (status \(status), reason \(reason.rawValue)) intent=\(intent?.description ?? "none", privacy: .public)"
        )

        switch intent {
        case .appTermination, .uninstall:
            transition(to: .idle)
            flushShutdownWaiters()

        case .restart:
            transition(to: .idle)
            // The old process is reaped *before* this call, so `launch()` sees a
            // free instance lock and cannot start a second Host alongside it.
            launch(attempt: 0)

        case .none:
            if isShutdown {
                transition(to: .idle)
                flushShutdownWaiters()
                return
            }
            if configuration.isHostRunning() {
                // Something else took the lock between the exit and now. Do not
                // compete for producer rights.
                transition(to: .notOwned)
                return
            }
            consecutiveFailures += 1
            lastFailure = timedOutLaunch ? .launchTimedOut : .exited(status: status)
            transition(to: .idle)
            scheduleRelaunch()
        }
    }

    // MARK: - Launch

    private func launch(attempt: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isShutdown else { return }
        guard process == nil else {
            let pid = process.map { "\($0.processIdentifier)" } ?? "unknown"
            supervisorLog.error("Refusing a second launch while pid \(pid) is owned")
            return
        }
        if configuration.isHostRunning() {
            // The lock is the truth: an old Host that has not exited, or one
            // owned by another App instance. Starting now would give the mapping
            // two producers.
            supervisorLog.notice("Not launching: the instance lock is held")
            transition(to: .notOwned)
            return
        }
        guard let newProcess = configuration.makeProcess() else {
            lastFailure = .executableMissing
            consecutiveFailures = configuration.maxConsecutiveFailures
            transition(to: .degraded(failure: .executableMissing, attempts: consecutiveFailures))
            return
        }

        launchToken &+= 1
        let token = launchToken
        timedOutLaunch = false
        newProcess.terminationHandler = { [weak self] exited in
            self?.handleTermination(
                token: token,
                status: exited.terminationStatus,
                reason: exited.terminationReason
            )
        }

        transition(to: .launching(attempt: attempt))
        do {
            try newProcess.run()
        } catch {
            consecutiveFailures += 1
            lastFailure = .launchFailed(error.localizedDescription)
            supervisorLog.error("Host launch threw: \(error.localizedDescription, privacy: .public)")
            scheduleRelaunch()
            return
        }

        process = newProcess
        supervisorLog.info("Launched Host pid \(newProcess.processIdentifier) (launch #\(token))")
        scheduleWatchdog(token: token)
    }

    private func scheduleWatchdog(token: UInt64) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, token == self.launchToken, let process = self.process else { return }
            guard process.isRunning else { return } // the termination handler owns this case
            self.watchdog = nil
            guard self.configuration.isHostRunning() else {
                // Alive but without the lock: it is not serving this user, and
                // leaving it running would block the next attempt forever.
                supervisorLog.error("Host pid \(process.processIdentifier) never took the instance lock")
                self.timedOutLaunch = true
                self.stopIntent = nil
                process.terminate()
                return
            }
            self.consecutiveFailures = 0
            self.lastFailure = nil
            self.transition(to: .running(pid: process.processIdentifier))
        }
        watchdog = work
        queue.asyncAfter(deadline: .now() + configuration.launchTimeout, execute: work)
    }

    // MARK: - Stop

    private func stopOwnedProcess(intent: HostStopIntent) {
        dispatchPrecondition(condition: .onQueue(queue))

        guard let process else {
            // Nothing owned. A restart still needs a Host; a final intent just
            // finishes whatever is waiting on it.
            if intent.endsOwnership {
                transition(to: .idle)
                flushShutdownWaiters()
            } else {
                launch(attempt: 0)
            }
            return
        }

        // Record the intent before looking at the process: the exit may already
        // have happened, and the handler must see the reason that is current —
        // otherwise a shutdown arriving after a restart is read as "relaunch".
        stopIntent = intent

        if !process.isRunning {
            // Exited but not yet reaped by the monitor: treat it as reaped now so
            // the intent is honoured immediately instead of waiting.
            handleTerminationOnQueue(token: launchToken, status: process.terminationStatus, reason: .exit)
            return
        }

        transition(to: .stopping(intent))
        process.terminate() // SIGTERM: the Host runs its ordered shutdown
        scheduleKillEscalation(token: launchToken, pid: process.processIdentifier)
    }

    private func scheduleKillEscalation(token: UInt64, pid: Int32) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, token == self.launchToken, let process = self.process, process.isRunning else { return }
            self.killEscalation = nil
            supervisorLog.error(
                "Host pid \(pid) still running after \(self.configuration.gracefulExitTimeout)s; sending SIGKILL"
            )
            if kill(pid, SIGKILL) != 0 {
                supervisorLog.error("SIGKILL to pid \(pid) failed (errno \(errno))")
            }
        }
        killEscalation = work
        queue.asyncAfter(deadline: .now() + configuration.gracefulExitTimeout, execute: work)
    }

    // MARK: - Retry

    private func scheduleRelaunch() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isShutdown else {
            flushShutdownWaiters()
            return
        }

        guard consecutiveFailures < configuration.maxConsecutiveFailures else {
            let failure = lastFailure ?? .exited(status: 0)
            supervisorLog.error(
                "Giving up after \(self.consecutiveFailures) failed starts: \(failure.description, privacy: .public)"
            )
            transition(to: .degraded(failure: failure, attempts: consecutiveFailures))
            return
        }

        let exponent = Double(max(consecutiveFailures - 1, 0))
        let delay = min(configuration.initialBackoff * pow(2, exponent), configuration.maximumBackoff)
        let attempt = consecutiveFailures
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isShutdown else { return }
            self.relaunch = nil
            self.launch(attempt: attempt)
        }
        relaunch = work
        supervisorLog.notice("Relaunching the Host in \(delay, format: .fixed(precision: 2))s (attempt \(attempt + 1))")
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Plumbing

    private func transition(to newState: HostSupervisorState) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard newState != state else { return }
        state = newState
        supervisorLog.info("Host supervisor state: \(newState.description, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(newState)
        }
    }

    private func flushShutdownWaiters() {
        dispatchPrecondition(condition: .onQueue(queue))
        let waiters = shutdownWaiters
        shutdownWaiters = []
        for waiter in waiters { waiter() }
    }
}
