import XCTest
import Darwin
@testable import SoundBridgeApp

// MARK: - A Host that is a process and nothing else
//
// Gate 3 needed a Host-only restart and a crash recovery path, but neither can be
// exercised against the real `SoundBridgeHost`: it would register a HAL plugin's
// client, create a mapping and touch CoreAudio. The supervisor therefore takes
// its `Process` factory and its instance-lock probe as inputs, and these tests
// give it `/bin/sleep` and `/bin/sh`.
//
// What stays real: the `Process` object, SIGTERM delivery, exit status, the
// termination handler's thread, and the instance lock as a predicate. What never
// happens: a HAL driver is started, `coreaudiod` is touched, or audio is played.
//
// The stub Host "holds the instance lock" exactly when one of its processes is
// alive, which is what the real lock means (a `flock` held for the Host's life).

/// A stub Host: a `Process` that never becomes a real one.
///
/// Not `private`: `HostRestartEntryTests` drives the same supervisor through the
/// menu item's gate, and a second copy of this fixture would be a second set of
/// assumptions about what "the Host holds the lock" means.
final class StubHostLauncher {

    enum LockBehaviour {
        /// A launched process takes the lock while it runs — the real Host.
        case acquiresOnLaunch
        /// The process stays alive but never locks: a Host that booted wrong.
        case neverAcquires
        /// Somebody else already holds the lock: another App's Host.
        case alwaysHeld
    }

    enum Script {
        case longRunning
        case exits(status: Int32)
    }

    private let lock = NSLock()
    private var owned: [Process] = []
    private var launchCount = 0
    private var concurrencyPeak = 0
    private var startedOverALiveHost = false
    private var lockBehaviour: LockBehaviour = .acquiresOnLaunch
    private var script: Script = .longRunning

    func setLockBehaviour(_ behaviour: LockBehaviour) {
        lock.lock()
        lockBehaviour = behaviour
        lock.unlock()
    }

    func setScript(_ newScript: Script) {
        lock.lock()
        script = newScript
        lock.unlock()
    }

    var launches: Int {
        lock.lock()
        defer { lock.unlock() }
        return launchCount
    }

    var processes: [Process] {
        lock.lock()
        defer { lock.unlock() }
        return owned
    }

    /// Highest number of stub Hosts alive at once. Must never exceed 1: two Hosts
    /// would mean two producers for one mapping.
    var peakConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return concurrencyPeak
    }

    /// `true` if a launch was ever started before the previous process was gone.
    var everStartedOverALiveHost: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startedOverALiveHost
    }

    func makeProcess() -> Process? {
        lock.lock()
        let liveNow = owned.filter { $0.isRunning }.count
        concurrencyPeak = max(concurrencyPeak, liveNow + 1)
        if liveNow > 0 { startedOverALiveHost = true }
        launchCount += 1
        let chosen = script
        lock.unlock()

        let process = Process()
        switch chosen {
        case .longRunning:
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
        case .exits(let status):
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit \(status)"]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        lock.lock()
        owned.append(process)
        lock.unlock()
        return process
    }

    func isHostRunning() -> Bool {
        lock.lock()
        let behaviour = lockBehaviour
        let live = owned.contains { $0.isRunning }
        lock.unlock()

        switch behaviour {
        case .alwaysHeld: return true
        case .neverAcquires: return false
        case .acquiresOnLaunch: return live
        }
    }

    /// Kill anything the supervisor lost track of (a test that replays a
    /// termination event deliberately desynchronises the two).
    func terminateAll() {
        for process in processes where process.isRunning {
            process.terminate()
        }
    }
}

// MARK: - Host supervisor

final class HostSupervisorTests: XCTestCase {

    private var launcher: StubHostLauncher!
    private var supervisor: HostSupervisor!

    override func setUp() {
        super.setUp()
        launcher = StubHostLauncher()
        supervisor = makeSupervisor()
    }

    override func tearDown() {
        // The stub Host is `/bin/sleep`; leaving it behind would outlive the test.
        supervisor?.shutdown(intent: .appTermination, waitTimeout: 3)
        launcher?.terminateAll()
        supervisor = nil
        launcher = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeSupervisor(
        configure: (inout HostSupervisor.Configuration) -> Void = { _ in }
    ) -> HostSupervisor {
        var configuration = HostSupervisor.Configuration()
        // Short enough for a test, long enough that a scheduling hiccup does not
        // turn into a spurious "launch timed out".
        configuration.launchTimeout = 0.4
        configuration.gracefulExitTimeout = 0.4
        configuration.killGraceTimeout = 0.2
        configuration.maxConsecutiveFailures = 3
        configuration.initialBackoff = 0.05
        configuration.maximumBackoff = 0.1
        configuration.makeProcess = { [weak launcher = self.launcher] in launcher?.makeProcess() }
        configuration.isHostRunning = { [weak launcher = self.launcher] in launcher?.isHostRunning() ?? false }
        configure(&configuration)
        return HostSupervisor(configuration: configuration)
    }

    @discardableResult
    private func spin(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func waitForRunning(launches: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let launched = launches
        let ok = spin {
            guard case .running = self.supervisor.currentState else { return false }
            if let launched { return self.launcher.launches == launched }
            return true
        }
        XCTAssertTrue(ok, "expected running, state was \(supervisor.currentState)", file: file, line: line)
    }

    private func waitForDegraded(file: StaticString = #filePath, line: UInt = #line) {
        let ok = spin {
            if case .degraded = self.supervisor.currentState { return true }
            return false
        }
        XCTAssertTrue(ok, "expected degraded, state was \(supervisor.currentState)", file: file, line: line)
    }

    // MARK: - 1. A normal launch owns exactly one Host

    func testStartingTheHostCreatesOneProcess() {
        supervisor.start()

        waitForRunning(launches: 1)
        XCTAssertEqual(launcher.launches, 1)
        XCTAssertEqual(supervisor.ownedProcessIdentifier, launcher.processes[0].processIdentifier)
        XCTAssertEqual(launcher.peakConcurrency, 1)
    }

    func testStartingTwiceDoesNotCreateASecondHost() {
        supervisor.start()
        waitForRunning()
        supervisor.start()
        supervisor.start()

        _ = spin(timeout: 0.5) { false }

        XCTAssertEqual(launcher.launches, 1, "start() must be idempotent while a Host is owned")
        XCTAssertEqual(launcher.peakConcurrency, 1)
    }

    // MARK: - 2. Host-only restart

    func testHostOnlyRestartReplacesTheProcessAndKeepsTheAppAlive() {
        supervisor.start()
        waitForRunning(launches: 1)
        let appPID = getpid()
        let firstHostPID = launcher.processes[0].processIdentifier

        supervisor.restart()
        waitForRunning(launches: 2)

        let secondHostPID = launcher.processes[1].processIdentifier
        XCTAssertEqual(getpid(), appPID, "the App is not restarted by a Host restart")
        XCTAssertNotEqual(secondHostPID, firstHostPID, "the Host PID must change")
        XCTAssertEqual(launcher.peakConcurrency, 1, "the new Host may only start after the old one exited")
        XCTAssertFalse(launcher.everStartedOverALiveHost)
        XCTAssertFalse(launcher.processes[0].isRunning)
    }

    func testRepeatedRestartRequestsAreSingleFlight() {
        supervisor.start()
        waitForRunning(launches: 1)

        supervisor.restart()
        supervisor.restart()
        supervisor.restart()

        waitForRunning(launches: 2)
        _ = spin(timeout: 0.6) { false }

        XCTAssertEqual(launcher.launches, 2, "three requests must not become three Hosts")
        XCTAssertEqual(launcher.peakConcurrency, 1)
    }

    func testRestartFromDegradedGetsAFreshBudget() {
        launcher.setScript(.exits(status: 3))
        supervisor.start()
        waitForDegraded()
        XCTAssertEqual(launcher.launches, 3)

        launcher.setScript(.longRunning)
        supervisor.restart()
        waitForRunning(launches: 4)

        XCTAssertEqual(launcher.launches, 4)
    }

    // MARK: - 3. Unexpected exit

    func testAnUnexpectedHostExitIsRecoveredWithoutRestartingTheApp() {
        supervisor.start()
        waitForRunning(launches: 1)
        let appPID = getpid()
        let firstHostPID = launcher.processes[0].processIdentifier

        // SIGTERM with no stop intent recorded: indistinguishable from a crash
        // as far as the supervisor is concerned, and exactly what a killed Host
        // looks like from here.
        launcher.processes[0].terminate()
        waitForRunning(launches: 2)

        XCTAssertEqual(getpid(), appPID)
        XCTAssertNotEqual(launcher.processes[1].processIdentifier, firstHostPID)
        XCTAssertEqual(launcher.peakConcurrency, 1)
    }

    func testACrashLoopIsBoundedAndEndsInDegraded() {
        launcher.setScript(.exits(status: 3))
        supervisor.start()

        waitForDegraded()
        XCTAssertEqual(launcher.launches, 3, "three attempts, then stop")

        guard case .degraded(let failure, let attempts) = supervisor.currentState else {
            return XCTFail("expected degraded, state was \(supervisor.currentState)")
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(failure, .exited(status: 3))
    }

    func testADegradedSupervisorStopsRetryingOnItsOwn() {
        launcher.setScript(.exits(status: 3))
        supervisor.start()
        waitForDegraded()
        let attempts = launcher.launches

        _ = spin(timeout: 0.8) { false }

        XCTAssertEqual(launcher.launches, attempts, "degraded is a resting state, not a slower retry loop")
    }

    func testAHostThatNeverTakesTheLockIsTreatedAsAFailedLaunch() {
        launcher.setLockBehaviour(.neverAcquires)
        supervisor.start()

        waitForDegraded()

        guard case .degraded(let failure, _) = supervisor.currentState else {
            return XCTFail("expected degraded, state was \(supervisor.currentState)")
        }
        XCTAssertEqual(failure, .launchTimedOut)
        XCTAssertEqual(launcher.launches, 3)
        XCTAssertTrue(launcher.processes.allSatisfy { !$0.isRunning },
                      "a process that never locked must not be left running")
    }

    // MARK: - 4. App termination

    func testAppTerminationStopsTheHostAndNeverRelaunchesIt() {
        supervisor.start()
        waitForRunning(launches: 1)

        supervisor.shutdown(intent: .appTermination, waitTimeout: 5)

        XCTAssertEqual(supervisor.currentState, .idle)
        XCTAssertEqual(launcher.launches, 1)
        XCTAssertTrue(launcher.processes.allSatisfy { !$0.isRunning })

        supervisor.start()
        _ = spin(timeout: 0.8) { false }
        XCTAssertEqual(launcher.launches, 1, "a shut-down supervisor must not start a Host")
    }

    func testShutdownCancelsARestartThatIsAlreadyInFlight() {
        supervisor.start()
        waitForRunning(launches: 1)

        supervisor.restart()
        supervisor.shutdown(intent: .appTermination, waitTimeout: 5)
        let launchesAtShutdown = launcher.launches

        _ = spin(timeout: 0.8) { false }

        XCTAssertEqual(supervisor.currentState, .idle)
        XCTAssertTrue(launcher.processes.allSatisfy { !$0.isRunning },
                      "no Host may survive the App")
        XCTAssertEqual(launcher.launches, launchesAtShutdown,
                       "nothing may relaunch after shutdown, even from an in-flight restart")
        XCTAssertEqual(launcher.peakConcurrency, 1)
    }

    func testRestartAfterShutdownIsIgnored() {
        supervisor.start()
        waitForRunning(launches: 1)
        supervisor.shutdown(intent: .appTermination, waitTimeout: 5)

        supervisor.restart()
        _ = spin(timeout: 0.6) { false }

        XCTAssertEqual(launcher.launches, 1)
        XCTAssertEqual(supervisor.currentState, .idle)
    }

    // MARK: - 5. Ownership boundaries

    func testAHostOwnedByAnotherProcessIsNeverTakenOver() {
        launcher.setLockBehaviour(.alwaysHeld)
        supervisor.start()

        XCTAssertTrue(spin(timeout: 1) {
            if case .notOwned = self.supervisor.currentState { return true }
            return false
        }, "state was \(supervisor.currentState)")
        XCTAssertEqual(launcher.launches, 0, "starting a second Host would give the mapping two producers")

        supervisor.restart()
        _ = spin(timeout: 0.5) { false }
        XCTAssertEqual(launcher.launches, 0)
    }

    func testALateTerminationEventFromAReplacedProcessIsIgnored() {
        supervisor.start()
        waitForRunning(launches: 1)
        let staleToken = supervisor.currentLaunchToken

        supervisor.restart()
        waitForRunning(launches: 2)
        let stateBefore = supervisor.currentState

        // The old Host's exit arriving late — after its replacement is running.
        supervisor.handleTermination(token: staleToken, status: 0, reason: .exit)
        _ = spin(timeout: 0.4) { false }

        XCTAssertEqual(supervisor.currentState, stateBefore)
        XCTAssertEqual(launcher.launches, 2, "a late event must not start a third Host")
    }

    func testADuplicateTerminationEventDoesNotStartASecondHost() {
        supervisor.start()
        waitForRunning(launches: 1)
        let token = supervisor.currentLaunchToken

        // Replay the event twice while the stub Host is still alive. The first
        // one clears the supervisor's record of the process; the relaunch it
        // schedules must then refuse, because the lock is still held.
        supervisor.handleTermination(token: token, status: 0, reason: .exit)
        supervisor.handleTermination(token: token, status: 0, reason: .exit)

        XCTAssertTrue(spin(timeout: 1.5) {
            if case .notOwned = self.supervisor.currentState { return true }
            return false
        }, "state was \(supervisor.currentState)")
        XCTAssertEqual(launcher.launches, 1, "two producers for one mapping is the failure this refuses")
        XCTAssertEqual(launcher.peakConcurrency, 1)
    }

    // MARK: - 6. A restart, a retired mapping and a writer that follows it

    /// The composition the App actually runs: `HostSupervisor` replaces the
    /// process, the old mapping is retired, the new Host publishes a new inode on
    /// the same path, and the App-owned EQ writer re-applies the persisted values
    /// into it. Nothing here is a mock — the mapping is a real file and the EQ
    /// block is read with the Host's own SeqLock reader.
    func testAHostRestartRetiresTheOldMappingAndTheWriterFollowsTheNewOne() throws {
        let fixture = SharedMemoryFixture(name: "host-restart-\(UUID().uuidString)")
        let uid = "host-restart-\(UUID().uuidString)"
        let manager = SharedMemoryMappingManager(pathForUID: { _ in fixture.path })
        // `revalidate()` resolves the device through this closure; without it the
        // path is never re-checked and a retired mapping would never be noticed.
        manager.deviceUIDProvider = { uid }
        let defaults = UserDefaults.standard
        defaults.set(3 as Float, forKey: EQDefaultsKey.bass(for: uid))
        defaults.set(-2 as Float, forKey: EQDefaultsKey.mids(for: uid))
        defaults.set(1 as Float, forKey: EQDefaultsKey.treble(for: uid))
        defaults.set(true, forKey: EQDefaultsKey.isEnabled(for: uid))
        defer {
            manager.stop()
            fixture.teardown()
            for key in [EQDefaultsKey.state(for: uid),
                        EQDefaultsKey.bass(for: uid), EQDefaultsKey.mids(for: uid),
                        EQDefaultsKey.treble(for: uid), EQDefaultsKey.isEnabled(for: uid)] {
                defaults.removeObject(forKey: key)
            }
        }

        let writer = EQService(deviceUID: uid, mapping: manager)
        let first = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(path: fixture.path).didAttach)
        XCTAssertTrue(spin { writer.controller.isAppliedToCurrentMapping })
        XCTAssertEqual(first.bandGains, EQController.computeBandGains(bass: 3, mids: -2, treble: 1))

        supervisor.start()
        waitForRunning(launches: 1)

        supervisor.restart()
        waitForRunning(launches: 2)

        // The Host that went away retired its mapping.
        fixture.removePublishedFile()
        manager.revalidate()
        XCTAssertTrue(spin { !manager.isAvailable }, "the old mapping must be retired")
        XCTAssertTrue(spin { !writer.controller.isAppliedToCurrentMapping },
                      "the writer must withdraw its claim on the retired incarnation")

        // The replacement publishes a different inode on the same path.
        let second = try fixture.publish()
        manager.revalidate()

        XCTAssertTrue(spin { writer.controller.lastAppliedGeneration == manager.currentGeneration })
        XCTAssertNotEqual(second.identity.inode, first.identity.inode, "a new incarnation, not a reused inode")
        XCTAssertEqual(second.bandGains, EQController.computeBandGains(bass: 3, mids: -2, treble: 1),
                       "the new mapping is restored from the persisted EQ without restarting the App")
        XCTAssertGreaterThan(second.eqSequence, 0)
    }
}
