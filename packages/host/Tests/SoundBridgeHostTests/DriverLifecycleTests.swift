import XCTest
@testable import SoundBridgeHost

// MARK: - Lifecycle state machine
//
// Two things are being pinned here, and neither can be shown by running the Host:
//
// 1. `ReadinessWaiter` replaced `Thread.sleep(deviceWaitTimeout)`. The old code
//    reported success no matter what appeared; the replacement must be bounded,
//    must not spin, and must stop early when more waiting cannot help.
// 2. The seven lifecycle levels must stay distinguishable. The failure mode this
//    suite guards against is one level standing in for another — a file on disk
//    reported as "driver loaded", a quiet system reported as a dead driver.
//
// The clock is injected so the timeout path is exercised in microseconds and the
// assertions are deterministic instead of "hopefully long enough".

final class DriverLifecycleTests: XCTestCase {

    /// A clock that only moves when `sleep` is called, so a supposedly
    /// non-blocking wait cannot accidentally pass by really sleeping.
    private final class FakeClock {
        private var current: Date
        private(set) var sleeps: [TimeInterval] = []

        init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
            self.current = start
        }

        var now: Date { current }

        func sleep(_ interval: TimeInterval) {
            sleeps.append(interval)
            current = current.addingTimeInterval(interval)
        }

        func makeWaiter(timeout: TimeInterval, pollInterval: TimeInterval) -> ReadinessWaiter {
            return ReadinessWaiter(
                timeout: timeout,
                pollInterval: pollInterval,
                now: { self.current },
                sleep: { self.sleep($0) }
            )
        }
    }

    // MARK: - 1. An already-satisfied condition costs one probe and no sleep

    func testWaiterReturnsImmediatelyWhenTheConditionAlreadyHolds() {
        let clock = FakeClock()
        var probes = 0

        let outcome = clock.makeWaiter(timeout: 5, pollInterval: 0.25).waitFor { _ in
            probes += 1
            return .ready
        }

        XCTAssertEqual(outcome, .ready(polls: 1))
        XCTAssertEqual(probes, 1, "a satisfied condition must not be polled twice")
        XCTAssertTrue(clock.sleeps.isEmpty, "a satisfied condition must not sleep at all")
    }

    // MARK: - 2. A proxy device that appears late is waited for, not assumed

    func testWaiterPollsUntilALateDeviceAppears() {
        let clock = FakeClock()

        let outcome = clock.makeWaiter(timeout: 2, pollInterval: 0.25).waitFor { poll in
            // Appears on the third probe: the case the fixed two-second sleep was
            // pretending to handle.
            return poll < 3 ? .notYet("no proxy yet") : .ready
        }

        XCTAssertEqual(outcome, .ready(polls: 3))
        XCTAssertEqual(clock.sleeps, [0.25, 0.25], "waits must happen between polls, not before the first")
    }

    // MARK: - 3. A device that never appears times out with the reason quoted

    /// 0.25 s polls over a 2 s budget: the deadline is reached on probe 9. If the
    /// loop ignored the deadline this test would hang instead of failing, which is
    /// exactly the difference between the old sleep and this one.
    func testWaiterTimesOutAndQuotesTheLastReason() {
        let clock = FakeClock()

        let outcome = clock.makeWaiter(timeout: 2, pollInterval: 0.25).waitFor { _ in
            .notYet("proxy device not in the HAL device list")
        }

        guard case .timedOut(let polls, let reason) = outcome else {
            return XCTFail("expected a timeout, got \(outcome)")
        }
        XCTAssertEqual(polls, 9, "one probe per quarter second over a two second budget")
        XCTAssertEqual(clock.sleeps.count, 8, "the last poll must not sleep past the deadline")
        XCTAssertEqual(reason, "proxy device not in the HAL device list")
    }

    // MARK: - 4. Terminal conditions stop the wait instead of burning the budget

    /// An incompatible header will not fix itself in two seconds. Waiting for the
    /// full timeout would misreport it as a timeout.
    func testWaiterStopsImmediatelyOnATerminalSignal() {
        let clock = FakeClock()
        var probes = 0

        let outcome = clock.makeWaiter(timeout: 5, pollInterval: 0.25).waitFor { _ in
            probes += 1
            return .terminal("shared memory header failed validation")
        }

        XCTAssertEqual(outcome, .terminal(reason: "shared memory header failed validation", polls: 1))
        XCTAssertEqual(probes, 1)
        XCTAssertTrue(clock.sleeps.isEmpty, "a terminal signal must not wait")
    }

    // MARK: - 5. Every sleep is positive and never overshoots the deadline

    /// Two properties in one test because they fail together: a zero-length sleep
    /// is a busy loop, and an unclamped one lets startup overshoot its own budget.
    func testWaiterNeverSpinsAndClampsTheFinalSleep() {
        let clock = FakeClock()

        _ = clock.makeWaiter(timeout: 1, pollInterval: 0.4).waitFor { _ in
            .notYet("still waiting")
        }

        XCTAssertFalse(clock.sleeps.isEmpty)
        XCTAssertTrue(clock.sleeps.allSatisfy { $0 > 0 }, "a zero sleep is a busy loop: \(clock.sleeps)")
        XCTAssertTrue(
            clock.sleeps.allSatisfy { $0 <= 0.4 + 1e-9 },
            "no sleep may exceed the poll interval: \(clock.sleeps)"
        )
        XCTAssertLessThan(clock.sleeps.last!, 0.4, "the final sleep must be clamped to the remaining budget")
        XCTAssertGreaterThanOrEqual(clock.now, Date(timeIntervalSince1970: 1_000_001))

        // A zero poll interval must be floored, not honoured.
        let floored = ReadinessWaiter(timeout: 1, pollInterval: 0)
        XCTAssertEqual(floored.pollInterval, 0.001)
    }

    // MARK: - 6. The heartbeat watch needs consecutive evidence

    /// The first sample is a baseline. Treating it as liveness is how a frozen
    /// counter passes as healthy.
    func testHeartbeatWatchRequiresConsecutiveUnchangedSamples() {
        var watch = DriverHeartbeatWatch(stallThreshold: 3)

        XCTAssertFalse(watch.observe(0), "the first sample is a baseline, not liveness")
        XCTAssertFalse(watch.isStalled)

        XCTAssertFalse(watch.observe(0))
        XCTAssertFalse(watch.observe(0))
        XCTAssertFalse(watch.isStalled, "two unchanged samples are within tolerance")

        XCTAssertFalse(watch.observe(0))
        XCTAssertTrue(watch.isStalled, "three unchanged samples must be reported as stalled")

        XCTAssertTrue(watch.observe(41), "an advancing counter is proof of liveness")
        XCTAssertFalse(watch.isStalled, "progress must clear the stall")
        XCTAssertEqual(watch.unchangedSamples, 0)
    }

    func testHeartbeatWatchFloorsTheThresholdToAvoidInstantStalls() {
        let watch = DriverHeartbeatWatch(stallThreshold: 0)
        XCTAssertEqual(watch.stallThreshold, 1, "a zero threshold would need no evidence at all")
    }

    // MARK: - 7. A quiet system is waiting, not broken

    /// The driver sets `driver_connected` from its IO callback, so on a machine
    /// nobody is playing through it stays 0 forever. Reporting that as a fault
    /// would tell every idle user their driver is broken.
    func testQuietSystemIsWaitingForTheDriverNotFaulted() {
        var tracker = DriverConnectionTracker()
        var status = SharedMemoryConnectionStatus.pending

        for sample in 0..<5 {
            status = tracker.observe(
                DriverConnectionObservation(
                    headerValid: true,
                    driverConnected: false,
                    driverHeartbeat: 0,
                    hostHeartbeat: UInt64(sample)
                )
            )
        }

        XCTAssertEqual(status, .waitingForDriver)
        XCTAssertFalse(tracker.hasEverConnected, "the driver never attached, so nothing may be claimed")
        XCTAssertEqual(tracker.audioPipeline, .pending)
        XCTAssertFalse(tracker.isAudioFlowing, "no heartbeat means no evidence of audio")
    }

    // MARK: - 8. A driver that attached and left is not "waiting"

    func testDriverThatDetachesIsReportedAsDisconnected() {
        var tracker = DriverConnectionTracker()

        XCTAssertEqual(
            tracker.observe(
                DriverConnectionObservation(
                    headerValid: true, driverConnected: true, driverHeartbeat: 7, hostHeartbeat: 1
                )
            ),
            .connected
        )
        XCTAssertTrue(tracker.hasEverConnected)

        let after = tracker.observe(
            DriverConnectionObservation(
                headerValid: true, driverConnected: false, driverHeartbeat: 7, hostHeartbeat: 2
            )
        )
        XCTAssertEqual(after, .disconnected, "a driver that was here and left must not look like it never arrived")
    }

    // MARK: - 9. Attached and then quiet is idle; attached and never producing is not

    /// Playback stopping stops `DoIOOperation`, so the frame counter freezes on an
    /// idle machine. Reporting that as "driver not responding" would flag a fault
    /// every time a user pauses music. Level 6 stays `.connected`; level 7 is
    /// allowed to say `.stalled`.
    func testAttachedDeviceThatPlayedThenWentQuietIsIdleNotFaulted() {
        var tracker = DriverConnectionTracker(driverStallSamples: 3)
        var status = SharedMemoryConnectionStatus.pending

        // Same heartbeat every time; our own heartbeat keeps advancing so the
        // stall is attributed to the driver's frame production, not to us.
        for sample in 0..<4 {
            status = tracker.observe(
                DriverConnectionObservation(
                    headerValid: true,
                    driverConnected: true,
                    driverHeartbeat: 12,
                    hostHeartbeat: UInt64(sample)
                )
            )
        }

        XCTAssertEqual(status, .connected, "a paused device is still attached")
        XCTAssertEqual(tracker.audioPipeline, .stalled, "level 7 is what records the pause")
        XCTAssertFalse(tracker.isAudioFlowing)
        XCTAssertTrue(tracker.hasHeardDriverHeartbeat)
    }

    /// The narrow case that is actually wrong: the driver validated the mapping
    /// and never produced a frame, for the full threshold.
    func testAttachedDriverThatNeverProducedAFrameIsNotResponding() {
        var tracker = DriverConnectionTracker(driverStallSamples: 3)
        var status = SharedMemoryConnectionStatus.pending

        for sample in 0..<4 {
            status = tracker.observe(
                DriverConnectionObservation(
                    headerValid: true,
                    driverConnected: true,
                    driverHeartbeat: 0,
                    hostHeartbeat: UInt64(sample)
                )
            )
        }

        XCTAssertEqual(status, .driverNotResponding)
        XCTAssertEqual(tracker.audioPipeline, .notStarted)
        XCTAssertFalse(tracker.isAudioFlowing)
    }

    // MARK: - 10. An invalid mapping is its own status

    /// A header that fails validation must never be reported as a driver state;
    /// the fix is on our side, not the driver's.
    func testInvalidHeaderIsReportedSeparatelyFromAnyDriverState() {
        var tracker = DriverConnectionTracker()

        let status = tracker.observe(
            DriverConnectionObservation(
                headerValid: false, driverConnected: true, driverHeartbeat: 99, hostHeartbeat: 1
            )
        )

        XCTAssertEqual(status, .invalid)
        XCTAssertFalse(tracker.hasEverConnected, "a mapping we cannot trust must not update driver state")
        XCTAssertFalse(tracker.isAudioFlowing)
    }

    // MARK: - 11. A stalled Host heartbeat blames the Host

    /// Our writer stopping is our bug. Reporting it as a driver problem would send
    /// the user to reinstall a driver that is fine.
    ///
    /// Uses the default host threshold (5 samples), which is deliberately looser
    /// than the driver's: the Host's heartbeat timer and this monitor run at the
    /// same one-second cadence and can alias, so a repeated sample is normal.
    func testStalledHostHeartbeatIsBlamedOnTheHost() {
        var tracker = DriverConnectionTracker(driverStallSamples: 3)
        var status = SharedMemoryConnectionStatus.pending

        // Baseline plus more than five unchanged samples while the driver keeps
        // producing frames.
        for sample in 0..<8 {
            status = tracker.observe(
                DriverConnectionObservation(
                    headerValid: true,
                    driverConnected: true,
                    driverHeartbeat: UInt64(sample + 1),
                    hostHeartbeat: 55
                )
            )
        }

        XCTAssertEqual(status, .hostHeartbeatStalled)
    }

    // MARK: - 12. The snapshot survives the file it travels through

    /// The App reads `device-state.json`, which an older build may also read. The
    /// encoded shape is therefore a contract: string-valued levels, numeric time,
    /// and unknown keys ignored rather than fatal.
    func testLifecycleSnapshotRoundTripsAndToleratesUnknownFields() throws {
        var snapshot = HostLifecycleSnapshot()
        snapshot.outcome = .proxyTimeout
        snapshot.driverFile = .present
        snapshot.driverCompatibility = .compatible
        snapshot.driverLoad = .loaded
        snapshot.halDiscovery = .discovered
        snapshot.proxyDevice = .missing
        snapshot.sharedMemoryConnection = .waitingForDriver
        snapshot.audioPipeline = .notStarted
        snapshot.detail = "no proxy device for Built-in Output after 5.0s"
        snapshot.updatedAt = 1_700_000_000.5

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HostLifecycleSnapshot.self, from: encoded)
        XCTAssertEqual(decoded, snapshot)

        // A future Host adding a level must not break this build's decoding.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["someFutureLevel"] = "whatever"
        let tolerant = try JSONDecoder().decode(
            HostLifecycleSnapshot.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(tolerant.outcome, .proxyTimeout)

        // Raw values are what the App switches on, so they are part of the
        // contract rather than an implementation detail.
        XCTAssertEqual(HostStartupOutcome.ready.rawValue, "ready")
        XCTAssertEqual(HostStartupOutcome.instanceConflict.rawValue, "instanceConflict")
        XCTAssertEqual(SharedMemoryConnectionStatus.waitingForDriver.rawValue, "waitingForDriver")
        XCTAssertEqual(HostLifecycleSnapshot().outcome, .starting, "nothing is claimed before startup decides")

        // `stamped` is how every publisher records when it decided.
        let stamped = snapshot.stamped("later")
        XCTAssertEqual(stamped.detail, "later")
        XCTAssertNotEqual(stamped.updatedAt, snapshot.updatedAt)
    }
}
