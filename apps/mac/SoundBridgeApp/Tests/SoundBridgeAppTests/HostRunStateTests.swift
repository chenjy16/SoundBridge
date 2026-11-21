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

    // MARK: - Phase 6A: the Host can be busy, not broken

    func testRecoveringIsShownButIsNotAProblem() {
        // The complaint this answers: during a coreaudiod restart the panel said
        // "Audio host is not running" while the Host was alive and working on it.
        let state = HostRunState.resolve(report: report(outcome: "recovering"), hostRunning: true)
        XCTAssertEqual(state, .recovering)
        XCTAssertFalse(state.isProblem, "a Host that is visibly working is not a fault")
        XCTAssertTrue(state.isTransitional, "but it must still be shown, or the panel looks frozen")
        XCTAssertNotEqual(state.shortMessage, HostRunState.notRunning.shortMessage)
    }

    func testDegradedIsAProblemTheHostSurvived() {
        let state = HostRunState.resolve(report: report(outcome: "degraded"), hostRunning: true)
        XCTAssertEqual(state, .degraded)
        XCTAssertTrue(state.isProblem, "recovery finished without an audio path; the user has to know")
        XCTAssertFalse(state.isTransitional)
    }

    func testStoppingIsTransientAndStoppedIsQuiet() {
        let stopping = HostRunState.resolve(report: report(outcome: "stopping"), hostRunning: true)
        XCTAssertEqual(stopping, .stopping)
        XCTAssertTrue(stopping.isTransitional)
        XCTAssertFalse(stopping.isProblem)

        // `stopped` is written while the lock is still held, so it resolves as a
        // real state rather than falling through to `unknown`.
        let stopped = HostRunState.resolve(report: report(outcome: "stopped"), hostRunning: true)
        XCTAssertEqual(stopped, .stopped)
        XCTAssertFalse(stopped.isTransitional)
        XCTAssertFalse(stopped.isProblem)
    }

    func testAGoneHostStillOutranksAStoppingReport() {
        // The lock remains the authority: a `stopping` file left behind by a Host
        // that then died must not keep the panel saying "stopping" forever.
        let state = HostRunState.resolve(report: report(outcome: "stopping"), hostRunning: false)
        XCTAssertEqual(state, .notRunning)
    }

    func testRecoveringThenReadyIsAFileThatCanBeReadInEitherOrder() {
        // The two frames the App can land on during a recovery. Both must be
        // renderable; neither may need the other to have been seen first.
        let recovering = HostRunState.resolve(report: report(outcome: "recovering"), hostRunning: true)
        let ready = HostRunState.resolve(
            report: report(outcome: "ready", connection: "connected", audio: "flowing"),
            hostRunning: true
        )
        XCTAssertEqual(recovering, .recovering)
        XCTAssertEqual(ready, .ready(flowing: true))
        XCTAssertTrue(recovering.isTransitional)
        XCTAssertFalse(ready.isTransitional, "a ready Host hides the status line again")
    }

    // MARK: - Every state is renderable

    func testEveryStateHasAShortMessage() {
        let states: [HostRunState] = [
            .notRunning, .starting, .ready(flowing: true), .ready(flowing: false),
            .waitingForDriver, .recovering, .degraded, .stopping, .stopped,
            .proxyUnavailable, .sharedMemoryInvalid,
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
        XCTAssertTrue(HostRunState.degraded.isProblem)

        XCTAssertFalse(HostRunState.starting.isProblem)
        XCTAssertFalse(HostRunState.ready(flowing: true).isProblem)
        XCTAssertFalse(HostRunState.ready(flowing: false).isProblem)
        XCTAssertFalse(HostRunState.waitingForDriver.isProblem)
        XCTAssertFalse(HostRunState.recovering.isProblem)
        XCTAssertFalse(HostRunState.stopping.isProblem)
        XCTAssertFalse(HostRunState.stopped.isProblem)
        XCTAssertFalse(HostRunState.noOutputDevices.isProblem)
        XCTAssertFalse(HostRunState.inactive.isProblem)
        XCTAssertFalse(HostRunState.unknown.isProblem)
    }

    func testTransitionalStatesAreExactlyTheOnesInFlight() {
        // `isTransitional` drives `showsStatusLine`, so a wrong answer here means
        // either a silent panel during a restart or a permanent status row on a
        // healthy machine.
        let transitional: [HostRunState] = [.starting, .recovering, .stopping]
        for state in transitional {
            XCTAssertTrue(state.isTransitional, "\(state) is in flight")
        }

        let quiet: [HostRunState] = [
            .notRunning, .ready(flowing: true), .ready(flowing: false), .waitingForDriver,
            .degraded, .stopped, .proxyUnavailable, .sharedMemoryInvalid,
            .driverNotResponding, .noOutputDevices, .instanceConflict, .inactive, .unknown
        ]
        for state in quiet {
            XCTAssertFalse(state.isTransitional, "\(state) is not in flight")
        }
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

    func testDeviceStateFromAPhase6AHostCarriesBothUIDs() throws {
        // Two facts that used to share one key. The App still reads the old one
        // on an old Host, and prefers the explicit one on a new Host.
        let json = """
        {
            "devices": [{"name": "ULTRAGEAR+", "uid": "hdmi-uid", "isFixedVolume": true}],
            "activeDeviceUID": "BuiltInSpeakerDevice",
            "managedProxyUID": "hdmi-uid",
            "systemDefaultOutputUID": "BuiltInSpeakerDevice"
        }
        """
        let state = try JSONDecoder().decode(IPCDeviceState.self, from: Data(json.utf8))

        XCTAssertEqual(state.managedProxyUID, "hdmi-uid", "the Host still manages the HDMI proxy")
        XCTAssertEqual(state.systemDefaultOutputUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(state.effectiveDefaultOutputUID, "BuiltInSpeakerDevice")
    }

    func testAnOlderPayloadStillResolvesTheDefaultOutput() throws {
        let json = """
        {"devices": [], "activeDeviceUID": "abc"}
        """
        let state = try JSONDecoder().decode(IPCDeviceState.self, from: Data(json.utf8))

        XCTAssertNil(state.systemDefaultOutputUID)
        XCTAssertEqual(state.effectiveDefaultOutputUID, "abc", "no Phase 6A keys, so fall back")
    }

    // MARK: - Session、Revision 与原子替换的隔离测试

    private func temporaryStateURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SoundBridgeIPCTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("device-state.json")
    }

    private func writeState(_ url: URL, session: UUID?, revision: UInt64?, outcome: String) throws {
        var json: [String: Any] = ["devices": [], "lifecycle": ["outcome": outcome]]
        if let session { json["sessionID"] = session.uuidString; json["protocolVersion"] = 1 }
        if let revision { json["revision"] = revision }
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
    }

    func testIPCRejectsOlderRevisionAndPreviousSession() throws {
        let url = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = UUID(), second = UUID()
        var lock: HostInstanceProbe.State = .held(session: first)
        let controller = IPCController(fileURL: url, lockState: { lock })
        try writeState(url, session: first, revision: 4, outcome: "ready")
        XCTAssertEqual(controller.readDeviceState()?.revision, 4)
        try writeState(url, session: first, revision: 4, outcome: "recovering")
        XCTAssertNil(controller.readDeviceState())
        try writeState(url, session: first, revision: 3, outcome: "recovering")
        XCTAssertNil(controller.readDeviceState())
        XCTAssertEqual(controller.latestState?.revision, 4)
        lock = .held(session: second)
        XCTAssertNil(controller.readDeviceState())
        XCTAssertNil(controller.latestState)
        try writeState(url, session: second, revision: 1, outcome: "starting")
        XCTAssertEqual(controller.readDeviceState()?.sessionID, second.uuidString)
        try writeState(url, session: first, revision: 5, outcome: "ready")
        XCTAssertNil(controller.readDeviceState())
        XCTAssertEqual(controller.latestState?.sessionID, second.uuidString)
        lock = .notRunning
        XCTAssertNil(controller.readDeviceState())
        XCTAssertNil(controller.latestState)
    }

    func testIPCLegacyStateRequiresLegacyLockAndRejectsPartialNewFormat() throws {
        let url = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = IPCController(fileURL: url, lockState: { .held(session: nil) })
        try writeState(url, session: nil, revision: nil, outcome: "ready")
        XCTAssertEqual(controller.readDeviceState()?.lifecycle?.outcome, "ready")
        try writeState(url, session: nil, revision: 1, outcome: "starting")
        XCTAssertNil(controller.readDeviceState())
    }

    func testIPCDropsReadIfLockChangesDuringFileRead() throws {
        let url = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = UUID(), second = UUID()
        try writeState(url, session: first, revision: 1, outcome: "ready")
        var reads = 0
        let controller = IPCController(fileURL: url, lockState: {
            reads += 1
            return .held(session: reads == 1 ? first : second)
        })
        XCTAssertNil(controller.readDeviceState())
        XCTAssertNil(controller.latestState)
    }

    func testIPCWatcherConvergesAfterConsecutiveAtomicRenames() throws {
        let url = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = UUID()
        try writeState(url, session: session, revision: 1, outcome: "starting")
        let controller = IPCController(fileURL: url, lockState: { .held(session: session) })
        let converged = expectation(description: "最新 Revision 被读取")
        controller.onDeviceStateChanged = { state in
            if state.revision == 3 { converged.fulfill() }
        }
        controller.startMonitoring()
        defer { controller.stopMonitoring() }
        try writeState(url, session: session, revision: 2, outcome: "recovering")
        try writeState(url, session: session, revision: 3, outcome: "ready")
        waitForExpectations(timeout: 3)
        XCTAssertEqual(controller.latestState?.revision, 3)
    }

    func testIPCWatcherRearmsWhenFileChangesBeforeRegistration() throws {
        let url = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = UUID()
        try writeState(url, session: session, revision: 1, outcome: "starting")
        let rearmed = expectation(description: "注册时发现旧 inode 并重新打开")
        let converged = expectation(description: "重挂后继续收到新的替换")
        var opens = 0
        let controller = IPCController(fileURL: url, lockState: { .held(session: session) }, watcherOpened: {
            opens += 1
            if opens == 1 {
                do { try self.writeState(url, session: session, revision: 2, outcome: "recovering") }
                catch { XCTFail("无法创建替换文件：\(error)") }
            } else if opens == 2 {
                rearmed.fulfill()
            }
        })
        controller.onDeviceStateChanged = { state in
            if state.revision == 3 { converged.fulfill() }
        }
        controller.startMonitoring()
        defer { controller.stopMonitoring() }
        wait(for: [rearmed], timeout: 3)
        XCTAssertEqual(controller.latestState?.revision, 2)
        try writeState(url, session: session, revision: 3, outcome: "ready")
        wait(for: [converged], timeout: 3)
        XCTAssertEqual(controller.latestState?.revision, 3)
    }

    func testIPCWatcherRateLimitsRepeatedRegistrationRacesAndConverges() throws {
        let url = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = UUID()
        try writeState(url, session: session, revision: 1, outcome: "starting")
        let firstDelay = expectation(description: "限速窗口")
        let thirdOpen = expectation(description: "两次替换后重新监听")
        let latest = expectation(description: "监听稳定后继续接收更新")
        var opens = 0
        let controller = IPCController(fileURL: url, lockState: { .held(session: session) }, watcherOpened: {
            opens += 1
            if opens <= 2 {
                do { try self.writeState(url, session: session, revision: UInt64(opens + 1), outcome: "recovering") }
                catch { XCTFail("无法创建替换文件：\(error)") }
            } else if opens == 3 {
                thirdOpen.fulfill()
            }
        })
        controller.onDeviceStateChanged = { if $0.revision == 4 { latest.fulfill() } }
        controller.startMonitoring()
        defer { controller.stopMonitoring() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { firstDelay.fulfill() }
        wait(for: [firstDelay], timeout: 2)
        XCTAssertEqual(opens, 1, "持续替换不能导致立即重复重挂")
        XCTAssertEqual(controller.latestState?.revision, 2)
        wait(for: [thirdOpen], timeout: 4)
        XCTAssertEqual(controller.latestState?.revision, 3)
        try writeState(url, session: session, revision: 4, outcome: "ready")
        wait(for: [latest], timeout: 3)
    }

    func testIPCWatcherStopCancelsPendingRetry() throws {
        let url = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = UUID()
        try writeState(url, session: session, revision: 1, outcome: "starting")
        let registration = expectation(description: "注册处理")
        let afterRetry = expectation(description: "原重试时间已过")
        var opens = 0
        let controller = IPCController(fileURL: url, lockState: { .held(session: session) }, watcherOpened: {
            opens += 1
            if opens == 1 {
                do { try self.writeState(url, session: session, revision: 2, outcome: "ready") }
                catch { XCTFail("无法创建替换文件：\(error)") }
            }
        })
        controller.startMonitoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { registration.fulfill() }
        wait(for: [registration], timeout: 2)
        controller.stopMonitoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { afterRetry.fulfill() }
        wait(for: [afterRetry], timeout: 2)
        XCTAssertEqual(opens, 1, "停止后不得重新打开监听")
    }

    func testIPCFallbackRefreshConvergesWithoutNotifications() throws {
        let url = try temporaryStateURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = UUID()
        try writeState(url, session: session, revision: 1, outcome: "starting")
        let controller = IPCController(fileURL: url, lockState: { .held(session: session) })
        var revisions: [UInt64] = []
        controller.onDeviceStateChanged = { if let revision = $0.revision { revisions.append(revision) } }
        controller.refreshAndNotify()
        try writeState(url, session: session, revision: 2, outcome: "ready")
        controller.refreshAndNotify()
        XCTAssertEqual(revisions, [1, 2])
        XCTAssertEqual(controller.latestState?.revision, 2)
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
