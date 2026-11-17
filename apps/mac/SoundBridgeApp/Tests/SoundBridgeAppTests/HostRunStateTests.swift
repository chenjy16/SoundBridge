import XCTest
@testable import SoundBridgeApp

// MARK: - Host run state
//
// The app used to answer "is the host healthy?" from what it last read out of
// `device-state.json`. That file outlives the process: a killed Host leaves
// `outcome: "ready"` behind, and the popover kept claiming everything was fine.
// The rule these tests pin is that the instance lock outranks the file, and that
// a running Host which never found its proxy device is a *reported* state rather
// than silence.

final class HostRunStateTests: XCTestCase {

    // MARK: - Fixtures

    private func report(
        outcome: String?,
        connection: String? = nil,
        audio: String? = nil,
        detail: String? = nil
    ) -> HostLifecycleReport {
        HostLifecycleReport(
            outcome: outcome,
            driverFile: "installed",
            driverCompatibility: "compatible",
            driverLoad: "loaded",
            halDiscovery: "visible",
            proxyDevice: "created",
            sharedMemoryConnection: connection,
            audioPipeline: audio,
            detail: detail,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    // MARK: - The lock outranks the file

    func testNoLockMeansNotRunningEvenWithAReadyReport() {
        // This is the killed-Host bug in one assertion.
        let stale = report(outcome: "ready", connection: "connected", audio: "flowing")
        XCTAssertEqual(HostRunState.resolve(report: stale, hostRunning: false), .notRunning)
    }

    func testNoLockAndNoReportMeansNotRunning() {
        XCTAssertEqual(HostRunState.resolve(report: nil, hostRunning: false), .notRunning)
    }

    func testLockWithoutAReportMeansStarting() {
        // A Host that just took the lock has not written anything yet. Calling
        // that "not running" would make the app launch a second one.
        XCTAssertEqual(HostRunState.resolve(report: nil, hostRunning: true), .starting)
    }

    func testStartingOutcomeIsStarting() {
        XCTAssertEqual(HostRunState.resolve(report: report(outcome: "starting"), hostRunning: true), .starting)
    }

    // MARK: - The seven levels mapped to sentences

    func testReadyAndConnectedAndFlowingIsReady() {
        let state = HostRunState.resolve(
            report: report(outcome: "ready", connection: "connected", audio: "flowing"),
            hostRunning: true
        )
        XCTAssertEqual(state, .ready(flowing: true))
    }

    func testReadyButSilentIsRoutedNotFaulted() {
        // Nothing playing is the normal case on a quiet machine. Reporting it as
        // a fault was the false alarm Phase 2.1.4 had to remove.
        let state = HostRunState.resolve(
            report: report(outcome: "ready", connection: "connected", audio: "stalled"),
            hostRunning: true
        )
        XCTAssertEqual(state, .ready(flowing: false))
        XCTAssertFalse(state.isProblem)
    }

    func testReadyWithNoDriverAttachedIsWaitingForDriver() {
        let state = HostRunState.resolve(
            report: report(outcome: "ready", connection: "waitingForDriver"),
            hostRunning: true
        )
        XCTAssertEqual(state, .waitingForDriver)
        XCTAssertFalse(state.isProblem, "a driver that has not attached yet is not an error")
    }

    func testProxyTimeoutIsProxyUnavailable() {
        for outcome in ["proxyTimeout", "deviceNotFound"] {
            XCTAssertEqual(
                HostRunState.resolve(report: report(outcome: outcome), hostRunning: true),
                .proxyUnavailable,
                "outcome \(outcome)"
            )
        }
    }

    func testInstanceConflictIsItsOwnState() {
        let state = HostRunState.resolve(report: report(outcome: "instanceConflict"), hostRunning: true)
        XCTAssertEqual(state, .instanceConflict)
        XCTAssertTrue(state.isProblem)
    }

    func testNoPhysicalDevicesIsIdleNotBroken() {
        let state = HostRunState.resolve(report: report(outcome: "noPhysicalDevices"), hostRunning: true)
        XCTAssertEqual(state, .noOutputDevices)
        XCTAssertFalse(state.isProblem)
    }

    func testSharedMemoryInvalidIsAProblem() {
        let state = HostRunState.resolve(report: report(outcome: "sharedMemoryInvalid"), hostRunning: true)
        XCTAssertEqual(state, .sharedMemoryInvalid)
        XCTAssertTrue(state.isProblem)
    }

    func testDriverNotRespondingIsAProblem() {
        let state = HostRunState.resolve(report: report(outcome: "driverNotResponding"), hostRunning: true)
        XCTAssertEqual(state, .driverNotResponding)
        XCTAssertTrue(state.isProblem)
    }

    func testInactiveWithAConnectedMappingIsActuallyReady() {
        // A degraded Host that recovered keeps writing `ready`; a snapshot that
        // still says `inactive` but reports a live connection is the recovery in
        // progress, and the connection is the newer fact.
        let state = HostRunState.resolve(
            report: report(outcome: "inactive", connection: "connected", audio: "flowing"),
            hostRunning: true
        )
        XCTAssertEqual(state, .ready(flowing: true))
    }

    func testInactiveWaitingForDriverStaysWaiting() {
        let state = HostRunState.resolve(
            report: report(outcome: "inactive", connection: "waitingForDriver"),
            hostRunning: true
        )
        XCTAssertEqual(state, .waitingForDriver)
    }

    func testInactiveOtherwiseIsInactive() {
        let state = HostRunState.resolve(report: report(outcome: "inactive", connection: "pending"), hostRunning: true)
        XCTAssertEqual(state, .inactive)
        XCTAssertFalse(state.isProblem)
    }

    func testOutcomeFromANewerHostIsUnknownNotBroken() {
        let state = HostRunState.resolve(report: report(outcome: "quarantined"), hostRunning: true)
        XCTAssertEqual(state, .unknown)
    }

    // MARK: - Every state is renderable

    func testEveryStateHasAShortMessage() {
        let states: [HostRunState] = [
            .notRunning, .starting, .ready(flowing: true), .ready(flowing: false),
            .waitingForDriver, .proxyUnavailable, .sharedMemoryInvalid,
            .driverNotResponding, .noOutputDevices, .instanceConflict, .inactive, .unknown
        ]
        for state in states {
            XCTAssertFalse(state.shortMessage.isEmpty, "no message for \(state)")
        }
    }

    func testOnlyTheStatesAUserMustActOnAreProblems() {
        XCTAssertTrue(HostRunState.notRunning.isProblem)
        XCTAssertTrue(HostRunState.proxyUnavailable.isProblem)
        XCTAssertTrue(HostRunState.sharedMemoryInvalid.isProblem)
        XCTAssertTrue(HostRunState.driverNotResponding.isProblem)
        XCTAssertTrue(HostRunState.instanceConflict.isProblem)

        XCTAssertFalse(HostRunState.starting.isProblem)
        XCTAssertFalse(HostRunState.ready(flowing: true).isProblem)
        XCTAssertFalse(HostRunState.ready(flowing: false).isProblem)
        XCTAssertFalse(HostRunState.waitingForDriver.isProblem)
        XCTAssertFalse(HostRunState.noOutputDevices.isProblem)
        XCTAssertFalse(HostRunState.inactive.isProblem)
        XCTAssertFalse(HostRunState.unknown.isProblem)
    }

    // MARK: - Decoding across versions

    func testLifecycleObjectDecodesWithUnknownFieldsPresent() throws {
        // A newer Host may add a level. Decoding must not fail because of it,
        // otherwise one added field would blank the whole panel.
        let json = """
        {
            "outcome": "ready",
            "driverFile": "installed",
            "driverCompatibility": "compatible",
            "driverLoad": "loaded",
            "halDiscovery": "visible",
            "proxyDevice": "created",
            "sharedMemoryConnection": "connected",
            "audioPipeline": "flowing",
            "driverTelemetry": "something-new",
            "detail": null,
            "updatedAt": 1700000000
        }
        """
        let report = try JSONDecoder().decode(HostLifecycleReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.outcome, "ready")
        XCTAssertTrue(report.isAudioFlowing)
    }

    func testDeviceStateFromAnOlderHostHasNoLifecycle() throws {
        // Pre-1.2.0 Hosts write devices only. The app must still parse them and
        // fall back to the lock for the host question.
        let json = """
        {"devices": [{"name": "Speakers", "uid": "abc", "isFixedVolume": true}], "activeDeviceUID": "abc"}
        """
        let state = try JSONDecoder().decode(IPCDeviceState.self, from: Data(json.utf8))
        XCTAssertNil(state.lifecycle)
        XCTAssertEqual(state.devices.count, 1)
        XCTAssertEqual(HostRunState.resolve(report: state.lifecycle, hostRunning: true), .starting)
    }

    func testReportAgeIsMeasuredFromUpdatedAt() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        var report = report(outcome: "ready", connection: "connected", audio: "flowing")
        report.updatedAt = 1_700_000_000

        XCTAssertEqual(report.age(now: now), 100)
        report.updatedAt = nil
        XCTAssertNil(report.age(now: now), "an undated report has no age; it must not look fresh")
    }
}
