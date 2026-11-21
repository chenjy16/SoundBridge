import XCTest
import Darwin
@testable import SoundBridgeApp

// MARK: - The menu item's path into HostSupervisor.restart()
//
// `HostSupervisorTests` already pins what a restart does. What it cannot answer is
// whether the menu item reaches it: `restartHost()` had no caller in the product,
// so every one of those tests proved a path the user could not walk.
//
// These tests walk it. The gate under test is the same instance the popover uses
// (`AppDelegate.requestHostRestart()` builds one exactly like this), the forward
// closure is the App's `restartHost()`, and the Host is still `/bin/sleep` — a
// HAL driver is never started, `coreaudiod` is never touched, no audio is played.

final class HostRestartEntryTests: XCTestCase {

    private var launcher: StubHostLauncher!
    private var supervisor: HostSupervisor!
    private var uninstalling = false
    private var terminating = false
    /// Counts calls to the action the menu item forwards to
    /// (`AppDelegate.restartHost()` in production).
    private var forwarded = 0

    override func setUp() {
        super.setUp()
        launcher = StubHostLauncher()
        uninstalling = false
        terminating = false
        forwarded = 0

        var configuration = HostSupervisor.Configuration()
        configuration.launchTimeout = 0.4
        configuration.gracefulExitTimeout = 0.4
        configuration.killGraceTimeout = 0.2
        configuration.maxConsecutiveFailures = 3
        configuration.initialBackoff = 0.05
        configuration.maximumBackoff = 0.1
        configuration.makeProcess = { [weak launcher = self.launcher] in launcher?.makeProcess() }
        configuration.isHostRunning = { [weak launcher = self.launcher] in launcher?.isHostRunning() ?? false }
        supervisor = HostSupervisor(configuration: configuration)
    }

    override func tearDown() {
        supervisor?.shutdown(intent: .appTermination, waitTimeout: 3)
        launcher?.terminateAll()
        supervisor = nil
        launcher = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private var entry: HostRestartEntry {
        HostRestartEntry(
            supervisor: supervisor,
            isUninstalling: { [weak self] in self?.uninstalling ?? true },
            isTerminating: { [weak self] in self?.terminating ?? true }
        )
    }

    /// What the popover does: gate → `restartHost()`.
    @discardableResult
    private func click() -> HostRestartOutcome {
        entry.request {
            forwarded += 1
            supervisor.restart()
        }
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

    // MARK: - 1. The item calls the App's restart entry

    func testTheMenuItemForwardsToTheAppsRestartEntry() {
        supervisor.start()
        waitForRunning(launches: 1)

        let outcome = click()

        XCTAssertEqual(outcome, .requested)
        XCTAssertEqual(forwarded, 1, "the item must call restartHost() exactly once")
    }

    // MARK: - 2. The request reaches HostSupervisor.restart()

    func testTheForwardedRequestReplacesTheHostThroughTheSupervisor() {
        supervisor.start()
        waitForRunning(launches: 1)
        let firstPID = launcher.processes[0].processIdentifier
        let appPID = getpid()

        XCTAssertEqual(click(), .requested)
        waitForRunning(launches: 2)

        XCTAssertEqual(forwarded, 1)
        XCTAssertNotEqual(launcher.processes[1].processIdentifier, firstPID, "a new Host, not the same one")
        XCTAssertEqual(getpid(), appPID, "the App is never restarted by the item")
    }

    // MARK: - 3. Rapid clicks cannot become two Hosts

    func testFiveRapidClicksStillProduceOneReplacementHost() {
        supervisor.start()
        waitForRunning(launches: 1)

        for _ in 0..<5 { click() }
        waitForRunning(launches: 2)
        _ = spin(timeout: 0.6) { false }

        XCTAssertEqual(forwarded, 5, "every click is forwarded; the supervisor is what coalesces")
        XCTAssertEqual(launcher.launches, 2, "one replacement, not five")
        XCTAssertEqual(launcher.peakConcurrency, 1)
    }

    // MARK: - 4. Refusal while the App is shutting down

    func testATerminatingAppRefusesAndNeverForwards() {
        supervisor.start()
        waitForRunning(launches: 1)

        terminating = true
        let outcome = click()

        XCTAssertEqual(outcome, .refusedShuttingDown)
        XCTAssertEqual(forwarded, 0, "a refused click must not reach restartHost()")
        XCTAssertEqual(launcher.launches, 1)
    }

    func testAShutDownSupervisorRefusesAndNeverForwards() {
        supervisor.start()
        waitForRunning(launches: 1)
        supervisor.shutdown(intent: .appTermination, waitTimeout: 3)

        // The App's own flag has not been set yet; the supervisor's has.
        let outcome = click()

        XCTAssertEqual(outcome, .refusedShuttingDown)
        XCTAssertEqual(forwarded, 0)
        XCTAssertEqual(launcher.launches, 1)
    }

    // MARK: - 5. Refusal during uninstall

    func testUninstallRefusesEvenWhileTheSupervisorCouldStillRestart() {
        supervisor.start()
        waitForRunning(launches: 1)

        uninstalling = true
        let outcome = click()

        XCTAssertEqual(outcome, .refusedUninstalling)
        XCTAssertEqual(forwarded, 0)
        XCTAssertEqual(launcher.launches, 1)
        XCTAssertFalse(supervisor.isShutDown, "the refusal is the App's, not the supervisor's")
    }

    // MARK: - 6. A failed replacement does not take the App with it

    func testAFailedReplacementEndsInDegradedAndTheAppSurvives() {
        supervisor.start()
        waitForRunning(launches: 1)
        let appPID = getpid()

        launcher.setScript(.exits(status: 3))
        XCTAssertEqual(click(), .requested)
        waitForDegraded()

        XCTAssertTrue(supervisor.isDegraded)
        XCTAssertEqual(forwarded, 1)
        XCTAssertEqual(getpid(), appPID, "nothing on this path may terminate the App")
        XCTAssertFalse(supervisor.isShutDown, "degraded keeps ownership; only shutdown gives it up")
    }

    // MARK: - 7. degraded is a state the item can leave

    func testTheMenuItemLeavesDegradedWithAFreshBudget() {
        launcher.setScript(.exits(status: 3))
        supervisor.start()
        waitForDegraded()
        XCTAssertEqual(launcher.launches, 3)

        launcher.setScript(.longRunning)
        XCTAssertEqual(click(), .requested)
        waitForRunning(launches: 4)

        XCTAssertEqual(launcher.launches, 4, "an explicit click gets a fresh budget, not the spent one")
    }

    // MARK: - 8. The old Host is gone before the new one starts

    func testTheReplacementStartsOnlyAfterTheOldHostExited() {
        supervisor.start()
        waitForRunning(launches: 1)
        let oldProcess = launcher.processes[0]

        XCTAssertEqual(click(), .requested)
        waitForRunning(launches: 2)

        XCTAssertFalse(oldProcess.isRunning, "the old Host is reaped before the relaunch")
        XCTAssertFalse(launcher.everStartedOverALiveHost)
        XCTAssertEqual(launcher.peakConcurrency, 1, "never two producers for one mapping")
    }
}
