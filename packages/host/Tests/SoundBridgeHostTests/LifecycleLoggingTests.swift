import XCTest
import CSoundBridgeAudio
@testable import SoundBridgeHost

// MARK: - Lifecycle wording and log volume
//
// Gate 3 recorded `Lifecycle detail: driver detached from this mapping` once a
// second while `driver_connected` was 1 and audio was flowing. Two separate
// defects produced that: the tracker treated a *new* mapping's zeroed
// `driver_connected` as the departure of the driver it had watched on the
// previous mapping, and the reporter compared whole snapshots — so a moving
// `updatedAt` made every poll look like a transition.
//
// These tests pin the decided behaviour, not the implementation:
// - `.disconnected` (and its wording) requires a driver that attached to the
//   incarnation being watched and then left;
// - a retired or replaced mapping never produces that sentence;
// - an identical repeat poll publishes a fresh heartbeat but logs nothing.

final class LifecycleLoggingTests: XCTestCase {

    private func observation(
        connected: Bool,
        token: UUID?,
        heartbeat: UInt64 = 10,
        hostHeartbeat: UInt64 = 10,
        headerValid: Bool = true
    ) -> DriverConnectionObservation {
        DriverConnectionObservation(
            headerValid: headerValid,
            driverConnected: connected,
            driverHeartbeat: heartbeat,
            hostHeartbeat: hostHeartbeat,
            mappingToken: token
        )
    }

    private final class LogRecorder {
        private(set) var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
        var details: [String] { lines.filter { $0.hasPrefix("Lifecycle detail:") } }
    }

    // MARK: - 1. A connected driver is never described as detached

    func testConnectedDriverNeverProducesDetachedWording() {
        var tracker = DriverConnectionTracker()
        let status = tracker.observe(observation(connected: true, token: UUID()))

        XCTAssertEqual(status, .connected)
        let detail = SharedMemoryConnectionDetail.detail(for: status)
        XCTAssertEqual(detail, "driver attached to this mapping")
        XCTAssertFalse(detail?.contains("detached") ?? false)
    }

    // MARK: - 2. A new incarnation starts as "waiting", not "detached"

    func testNewIncarnationReportsWaitingForDriverNotDetached() {
        var tracker = DriverConnectionTracker()
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(tracker.observe(observation(connected: true, token: first)), .connected)

        // Fresh mapping: `driver_connected` is zero until the driver's first IO.
        let status = tracker.observe(observation(connected: false, token: second, heartbeat: 0))
        XCTAssertEqual(status, .waitingForDriver, "a mapping that never had a driver attached is not a detach")
        XCTAssertEqual(tracker.incarnationSwitches, 1)
        XCTAssertFalse(SharedMemoryConnectionDetail.detail(for: status)?.contains("detached") ?? false)
    }

    // MARK: - 3. A real detach on the same incarnation is still reported

    func testRealDetachOnTheSameIncarnationIsStillReported() {
        var tracker = DriverConnectionTracker()
        let token = UUID()

        XCTAssertEqual(tracker.observe(observation(connected: true, token: token)), .connected)

        let status = tracker.observe(observation(connected: false, token: token, hostHeartbeat: 11))
        XCTAssertEqual(status, .disconnected)
        XCTAssertEqual(SharedMemoryConnectionDetail.detail(for: status), "driver detached from this mapping")
    }

    // MARK: - 4. Retiring and replacing a mapping never looks like a detach

    func testRetiredAndReplacedMappingNeverProducesADetach() {
        var tracker = DriverConnectionTracker()
        let oldIncarnation = UUID()
        let newIncarnation = UUID()

        var statuses: [SharedMemoryConnectionStatus] = []

        // The old mapping had a driver attached ...
        statuses.append(tracker.observe(observation(connected: true, token: oldIncarnation)))

        // ... the file is retired: the monitor's `sample()` returns nil and it
        // reports nothing at all, which is how this step is expressed here.
        // (No observation is appended.)

        // A new mapping is published; the driver has not attached yet.
        statuses.append(tracker.observe(observation(connected: false, token: newIncarnation, heartbeat: 0, hostHeartbeat: 1)))

        // ... and the driver attaches to it on the next IO.
        statuses.append(tracker.observe(observation(connected: true, token: newIncarnation, heartbeat: 1, hostHeartbeat: 2)))

        XCTAssertEqual(statuses, [.connected, .waitingForDriver, .connected])
        XCTAssertFalse(statuses.contains(.disconnected), "retire + replace must not be reported as a driver detach")
    }

    // MARK: - 5. A stale "detached" line is replaced when a new mapping appears

    func testStaleDetachedDetailIsReplacedWhenANewIncarnationIsPublished() {
        var tracker = DriverConnectionTracker()
        let recorder = LogRecorder()
        let reporter = HostLifecycleReporter(publish: { _ in }, log: recorder.append)
        let oldIncarnation = UUID()
        let newIncarnation = UUID()

        func report(_ observation: DriverConnectionObservation) {
            let status = tracker.observe(observation)
            reporter.update { snapshot in
                SharedMemoryReportPolicy.apply(
                    status,
                    pipeline: tracker.audioPipeline,
                    hostIsActive: true,
                    to: &snapshot
                )
            }
        }

        report(observation(connected: true, token: oldIncarnation))
        report(observation(connected: false, token: oldIncarnation, hostHeartbeat: 11))
        XCTAssertEqual(reporter.current().detail, "driver detached from this mapping")

        // New mapping. The previous sentence must not survive it.
        report(observation(connected: false, token: newIncarnation, heartbeat: 0, hostHeartbeat: 1))
        XCTAssertEqual(reporter.current().detail, "waiting for the driver's first IO on this mapping")
        XCTAssertEqual(reporter.current().sharedMemoryConnection, .waitingForDriver)

        report(observation(connected: true, token: newIncarnation, heartbeat: 1, hostHeartbeat: 2))
        XCTAssertEqual(reporter.current().detail, "audio flowing through the driver")
        XCTAssertEqual(reporter.current().outcome, .ready)

        let detachedLines = recorder.details.filter { $0.hasSuffix("driver detached from this mapping") }
        XCTAssertEqual(detachedLines.count, 1, "the detached line is logged for the real detach only, not carried forward")
    }

    // MARK: - 6. Repeating the same poll logs once, but keeps the file fresh

    func testRepeatedIdenticalPollsLogOnceAndStillRefreshTheTimestamp() {
        let recorder = LogRecorder()
        var published: [HostLifecycleSnapshot] = []
        let reporter = HostLifecycleReporter(
            publish: { published.append($0) },
            log: recorder.append
        )

        for _ in 0..<5 {
            reporter.update { snapshot in
                SharedMemoryReportPolicy.apply(.connected, pipeline: .flowing, hostIsActive: true, to: &snapshot)
            }
        }

        // One transition = the state line plus the detail line.
        XCTAssertEqual(reporter.logLineCount, 2, "an unchanged poll must not log again")
        XCTAssertEqual(recorder.lines.count, 2)
        XCTAssertEqual(published.count, 5, "every poll refreshes updatedAt so the App can tell the Host is alive")

        let stamps = published.compactMap(\.updatedAt)
        XCTAssertEqual(stamps.count, 5)
        XCTAssertEqual(stamps, stamps.sorted(), "the refresh must not move backwards")
    }

    // MARK: - 7. Invalid or absent sample never becomes a detach

    func testInvalidHeaderIsReportedAsInvalidNotDetached() {
        var tracker = DriverConnectionTracker()
        let status = tracker.observe(observation(connected: false, token: UUID(), headerValid: false))

        XCTAssertEqual(status, .invalid)
        XCTAssertEqual(SharedMemoryConnectionDetail.detail(for: status), "shared memory header failed validation")
    }

    // MARK: - 8. Transition logging still distinguishes each level

    func testEachLevelKeepsItsOwnWording() {
        XCTAssertEqual(SharedMemoryConnectionDetail.detail(for: .waitingForDriver),
                       "waiting for the driver's first IO on this mapping")
        XCTAssertEqual(SharedMemoryConnectionDetail.detail(for: .disconnected),
                       "driver detached from this mapping")
        XCTAssertEqual(SharedMemoryConnectionDetail.detail(for: .driverNotResponding),
                       "driver attached but never produced a frame")
        XCTAssertEqual(SharedMemoryConnectionDetail.detail(for: .hostHeartbeatStalled),
                       "Host heartbeat timer stopped advancing")
        XCTAssertNil(SharedMemoryConnectionDetail.detail(for: .pending))
    }

    // MARK: - 9. The real manager supplies a token per incarnation

    /// The tests above build observations by hand, so they would still pass if
    /// `SharedMemoryManager` stopped carrying the token at all (verified: they
    /// did). This one goes through a real mapping on disk and the real
    /// `connectionObservation(for:)`, so the whole chain is covered:
    /// manager → observation → tracker → status.
    func testManagerObservationCarriesANewTokenForANewIncarnation() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lifecycle-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let uid = "conn-\(UUID().uuidString)"
        let manager = SharedMemoryManager(sessionID: nil) { deviceUID in
            "\(sandbox.path)/soundbridge-\(deviceUID)"
        }
        manager.beginSession(UUID())
        defer { manager.cleanup() }

        XCTAssertNotNil(manager.createMemory(for: uid, persistence: NullPersistence()))
        guard let firstMapping = manager.acquireMemory(for: uid),
              let firstSample = manager.connectionObservation(for: uid) else {
            return XCTFail("a published mapping must be observable")
        }

        var tracker = DriverConnectionTracker()
        XCTAssertEqual(tracker.observe(firstSample), .waitingForDriver)

        // Stand in for the driver's IO on this incarnation.
        setDriverConnected(firstMapping.memory, 1)
        rf_update_driver_heartbeat(firstMapping.memory)
        guard let attached = manager.connectionObservation(for: uid) else {
            return XCTFail("the mapping must still be observable after the attach")
        }
        XCTAssertEqual(attached.mappingToken, firstSample.mappingToken, "the same inode keeps the same token")
        XCTAssertEqual(tracker.observe(attached), .connected)

        // A real detach on the same incarnation is still identifiable.
        setDriverConnected(firstMapping.memory, 0)
        guard let detached = manager.connectionObservation(for: uid) else {
            return XCTFail("the mapping must still be observable after the detach")
        }
        XCTAssertEqual(tracker.observe(detached), .disconnected)

        // Replace the mapping: a new inode under the same path.
        manager.removeMemory(for: uid)
        XCTAssertNil(manager.connectionObservation(for: uid), "a retired mapping is not sampled at all")

        XCTAssertNotNil(manager.createMemory(for: uid, persistence: NullPersistence()))
        guard let fresh = manager.connectionObservation(for: uid) else {
            return XCTFail("the replacement mapping must be observable")
        }
        XCTAssertNotNil(fresh.mappingToken)
        XCTAssertNotEqual(fresh.mappingToken, firstSample.mappingToken,
                          "a re-created mapping is a different incarnation")
        XCTAssertEqual(tracker.observe(fresh), .waitingForDriver,
                       "a new mapping must not be reported as the old driver's detach")
    }

    // MARK: - Helpers

    /// `driver_connected` is a C11 atomic owned by the driver. The offset (120)
    /// is pinned by RFSharedAudio.h; the test writes it only to stand in for an
    /// IO callback that this process cannot run.
    private func setDriverConnected(_ memory: UnsafeMutablePointer<RFSharedAudio>, _ value: UInt32) {
        UnsafeMutableRawPointer(memory)
            .advanced(by: 120)
            .assumingMemoryBound(to: UInt32.self)
            .pointee = value
    }

    private final class NullPersistence: VolumeStatePersisting {
        func loadIfPresent(uid: String) -> DeviceVolumeState? { nil }
        func save(uid: String, volume: Float, muted: Bool) {}
    }
}
