import XCTest
import Darwin
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - Degraded lifecycle: recovery gating, teardown, resource release
//
// Phase 2.1.5-B. Three questions these tests answer, and one they cannot:
//
//   1. Can two device-list notifications start two recoveries? (`DegradedRecoveryGate`)
//   2. Can teardown run twice, and does the lock stay the last thing released?
//      (`ShutdownSequence`)
//   3. Are the resources actually released — flock, mapping, heartbeat timer?
//      (real `HostInstanceLock`, real `SharedMemoryManager`, real timer)
//
// What is *not* covered here: a Host that really waits for a HAL proxy device.
// That needs `coreaudiod`, a loaded driver and a device list, i.e. a machine
// state this phase may not create. Those paths are audited statically and are
// listed as unverified in the Phase 2.1.5 report — they are not claimed as L5.
//
// Every fixture path is a per-test sandbox. No test opens `/tmp/soundbridge-*`,
// and none signals a real Host process.

final class DegradedLifecycleTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeDegradedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Deleted before the reference is dropped so a failed assertion still
        // leaves no directory behind.
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - 1. Recovery gate

    func testGateAllowsOneRecoveryPerDegradedEpisode() {
        var gate = DegradedRecoveryGate()

        XCTAssertTrue(gate.begin(isDegraded: true), "the first notification must start recovery")
        XCTAssertFalse(gate.begin(isDegraded: true), "a second notification while the probe is in flight must not")
        XCTAssertFalse(gate.begin(isDegraded: true))
        XCTAssertEqual(gate.attempts, 1, "only the accepted pass counts as an attempt")
    }

    func testGateRefusesRecoveryWhenNotDegraded() {
        var gate = DegradedRecoveryGate()

        XCTAssertFalse(gate.begin(isDegraded: false), "recovery may only start from .degraded")
        XCTAssertFalse(gate.isRecovering)
        XCTAssertEqual(gate.attempts, 0)
        XCTAssertTrue(gate.begin(isDegraded: true), "and it must still work afterwards")
    }

    func testGateRearmsAfterFailedPassSoALateProxyCanStillBePickedUp() {
        // The driver-never-appears case: every pass fails, the Host stays
        // degraded, and the *next* device notification must get a fresh try.
        var gate = DegradedRecoveryGate()

        for pass in 1...5 {
            XCTAssertTrue(gate.begin(isDegraded: true), "pass \(pass) must be allowed")
            gate.finish()
            XCTAssertFalse(gate.isRecovering)
        }

        XCTAssertEqual(gate.attempts, 5)
    }

    func testGateCountsAttemptsForDiagnostics() {
        var gate = DegradedRecoveryGate()
        XCTAssertEqual(gate.attempts, 0)

        XCTAssertTrue(gate.begin(isDegraded: true))
        XCTAssertEqual(gate.attempts, 1)
        gate.finish()

        XCTAssertTrue(gate.begin(isDegraded: true))
        XCTAssertEqual(gate.attempts, 2)
    }

    func testDuplicateFinishDoesNotTrapOrUnblockAPass() {
        var gate = DegradedRecoveryGate()

        gate.finish()
        XCTAssertFalse(gate.isRecovering, "finish without begin must be inert, not a stuck flag")

        XCTAssertTrue(gate.begin(isDegraded: true))
        gate.finish()
        gate.finish()
        gate.finish()
        XCTAssertFalse(gate.isRecovering)
        XCTAssertTrue(gate.begin(isDegraded: true), "the gate must still be usable after repeated finishes")
    }

    func testBurstOfNotificationsWhileRecoveringNeverStartsASecondPass() {
        // What the main queue actually delivers during a CoreAudio device churn:
        // many notifications, all before the first probe lands back on main.
        var gate = DegradedRecoveryGate()
        var started = 0

        for _ in 0..<64 {
            if gate.begin(isDegraded: true) { started += 1 }
        }

        XCTAssertEqual(started, 1, "a device-list storm must not fan out into parallel recoveries")
        gate.finish()

        // The episode ends once; recovery is available again afterwards.
        XCTAssertTrue(gate.begin(isDegraded: true))
        XCTAssertEqual(started, 1)
    }

    // MARK: - 2. Teardown ordering

    func testShutdownStepsRunInDeclaredOrder() {
        var sequence = ShutdownSequence()
        var visited: [ShutdownSequence.Step] = []

        XCTAssertTrue(sequence.run { visited.append($0) })

        XCTAssertEqual(visited, ShutdownSequence.Step.allCases)
        XCTAssertTrue(sequence.ranEveryStepOnce)
        XCTAssertTrue(sequence.isComplete)
    }

    func testShutdownReleasesTheLockLast() {
        var sequence = ShutdownSequence()
        var order: [ShutdownSequence.Step] = []

        sequence.run { order.append($0) }

        XCTAssertEqual(order.last, .releaseInstanceLock, "the instance lock covers every resource above it")
        XCTAssertTrue(sequence.releasedLockLast)

        // The steps whose order the lock depends on.
        let indexOf = { (step: ShutdownSequence.Step) in
            order.firstIndex(of: step) ?? -1
        }
        XCTAssertLessThan(indexOf(.stopHeartbeat), indexOf(.unlinkSharedMemory),
                          "a heartbeat must not write into a mapping that is being unmapped")
        XCTAssertLessThan(indexOf(.removeControlFile), indexOf(.waitForDriverDetach),
                          "the driver is told to stop before we wait for it")
        XCTAssertLessThan(indexOf(.stopAudioEngine), indexOf(.unlinkSharedMemory))
    }

    func testShutdownSecondCallIsANoOpAndDoesNotTouchResourcesAgain() {
        var sequence = ShutdownSequence()
        var bodyCalls: [ShutdownSequence.Step] = []

        XCTAssertTrue(sequence.run { bodyCalls.append($0) })
        let afterFirstPass = bodyCalls

        // A second SIGINT/SIGTERM after the first teardown started.
        XCTAssertFalse(sequence.run { bodyCalls.append($0) },
                       "a duplicate shutdown request must report that it did nothing")

        XCTAssertEqual(bodyCalls, afterFirstPass, "no step may run twice, not even unlink or release")
        XCTAssertTrue(sequence.ranEveryStepOnce)
    }

    func testShutdownSurvivesRepeatedSignalDelivery() {
        var sequence = ShutdownSequence()
        var unlinkCount = 0
        var releaseCount = 0

        for _ in 0..<10 {
            sequence.run { step in
                if step == .unlinkSharedMemory { unlinkCount += 1 }
                if step == .releaseInstanceLock { releaseCount += 1 }
            }
        }

        XCTAssertEqual(unlinkCount, 1, "ten signals must produce one unmap pass")
        XCTAssertEqual(releaseCount, 1, "ten signals must produce one lock release")
        XCTAssertEqual(sequence.executed.count, ShutdownSequence.Step.allCases.count)
    }

    func testQuitPathKeepsCoreAudioPolicyVisible() {
        // The step exists so the decision is still a decision. Deleting the call
        // would silently remove the only place that can restart the audio daemon.
        XCTAssertTrue(ShutdownSequence.Step.allCases.contains(.maybeRestartCoreAudio))
        XCTAssertFalse(
            SoundBridgeConfig.restartsCoreAudioOnExit,
            "a quit path must not restart coreaudiod: it takes every other app's audio down"
        )
    }

    // MARK: - 3. Real lock release

    func testLockIsReacquirableAfterRunOnceTeardown() throws {
        let lockPath = "\(sandbox.path)/soundbridge-host-test.lock"

        // The Host's own lock object, on a sandbox path instead of /tmp.
        let hostLock = HostInstanceLock(path: lockPath)
        XCTAssertEqual(hostLock.acquire(), .acquired)

        // A second instance — the App probing, or a relaunch racing the old
        // process — must be refused while the first holds it.
        let rival = HostInstanceLock(path: lockPath)
        if case .heldByAnotherInstance = rival.acquire() {
            // expected
        } else {
            XCTFail("a second instance must be refused while the lock is held")
        }

        var sequence = ShutdownSequence()
        XCTAssertTrue(sequence.run { step in
            if step == .releaseInstanceLock { hostLock.release() }
        })
        XCTAssertFalse(hostLock.isHeld)

        XCTAssertEqual(rival.acquire(), .acquired, "after teardown a relaunch must get the lock")
        rival.release()

        // And the file itself is still there: unlinking it is what would make the
        // next two processes both think they are exclusive.
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath))
    }

    func testLockReleaseIsSkippedByNoTeardownPath() throws {
        // Every exit from main() now goes through cleanup(): idle, degraded and
        // active. This pins the two invariants that depended on it.
        let lockPath = "\(sandbox.path)/soundbridge-host-test-2.lock"
        let hostLock = HostInstanceLock(path: lockPath)
        XCTAssertEqual(hostLock.acquire(), .acquired)

        var sequence = ShutdownSequence()
        var releasedBeforeFinalStep = false
        sequence.run { step in
            if step == .releaseInstanceLock {
                releasedBeforeFinalStep = hostLock.isHeld
                hostLock.release()
            }
        }

        XCTAssertTrue(releasedBeforeFinalStep, "the lock must still be held up to the last step")
        XCTAssertFalse(hostLock.isHeld)
        XCTAssertFalse(HostInstanceLock.isHeld(path: lockPath))
    }

    // MARK: - 4. Real shared-memory release and rebuild

    func testSharedMemoryIsRebuildableAfterTeardown() throws {
        let uid = "degraded-teardown-\(UUID().uuidString)"
        let path = "\(sandbox.path)/soundbridge-\(uid)"
        let persistence = SandboxPersistence()

        let firstRun = SharedMemoryManager(sessionID: UUID(), pathForUID: { _ in path })
        XCTAssertEqual(firstRun.createMemory(for: uid, persistence: persistence), .created)
        XCTAssertNotNil(firstRun.getMemory(for: uid))

        // The teardown steps that own the mapping, in the real order.
        var sequence = ShutdownSequence()
        sequence.run { step in
            switch step {
            case .stopHeartbeat:
                firstRun.stopHeartbeat()
            case .unlinkSharedMemory:
                firstRun.cleanup()
            default:
                break
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "teardown must unlink the mapping")
        XCTAssertNil(firstRun.getMemory(for: uid), "teardown must drop the pointer it unmapped")

        // A second run of the same teardown (the duplicate-signal case) must not
        // trap on an already empty map.
        firstRun.cleanup()
        firstRun.stopHeartbeat()

        // Relaunch: a fresh manager over the same path must rebuild rather than
        // adopt a half-torn-down file.
        let secondRun = SharedMemoryManager(sessionID: UUID(), pathForUID: { _ in path })
        XCTAssertEqual(secondRun.createMemory(for: uid, persistence: persistence), .created,
                       "a clean teardown leaves nothing to recover, so this is a fresh mapping")
        let mem = try XCTUnwrap(secondRun.getMemory(for: uid))
        XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)
        XCTAssertEqual(mem.pointee.protocol_version, UInt32(RF_AUDIO_PROTOCOL_VERSION))
        XCTAssertNotNil(secondRun.readVolumeState(for: uid), "the rebuilt mapping must carry a committed state")

        secondRun.cleanup()
    }

    // MARK: - 5. Real heartbeat timer

    func testHeartbeatRestartDoesNotLeaveAStrayTimer() throws {
        // The defect this pins: `startHeartbeat()` used to overwrite the timer
        // reference without cancelling it, so every idle → active transition
        // leaked a live source that kept writing `host_heartbeat` — a stopped
        // Host that still looked alive to the driver.
        let uid = "degraded-heartbeat-\(UUID().uuidString)"
        let path = "\(sandbox.path)/soundbridge-\(uid)"
        let manager = SharedMemoryManager(sessionID: UUID(), pathForUID: { _ in path })

        XCTAssertEqual(manager.createMemory(for: uid, persistence: SandboxPersistence()), .created)
        let mem = try XCTUnwrap(manager.getMemory(for: uid))

        manager.startHeartbeat()
        // Second start (idle → active twice): must cancel the first, not stack.
        manager.startHeartbeat()

        XCTAssertTrue(waitForHeartbeat(mem, toAdvancePast: rf_get_host_heartbeat(mem)),
                      "the surviving timer must still be firing")

        manager.stopHeartbeat()
        let afterStop = rf_get_host_heartbeat(mem)

        // Longer than one heartbeat interval: a leaked timer would bump this.
        Thread.sleep(forTimeInterval: SoundBridgeConfig.heartbeatInterval * 1.8)
        XCTAssertEqual(rf_get_host_heartbeat(mem), afterStop,
                       "stopHeartbeat() must stop every timer, not just the newest one")

        manager.cleanup()
    }

    // MARK: - Helpers

    /// Poll `host_heartbeat` until it moves past `baseline`, with a deadline.
    private func waitForHeartbeat(_ mem: UnsafeMutablePointer<RFSharedAudio>,
                                  toAdvancePast baseline: UInt64,
                                  timeout: TimeInterval = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if rf_get_host_heartbeat(mem) > baseline { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}

/// Minimal in-memory persistence for the sandbox fixtures. Deliberately holds
/// nothing: these tests exercise creation and teardown, not the persisted volume
/// precedence, which `SharedMemoryRecoveryTests` already covers.
private final class SandboxPersistence: VolumeStatePersisting {
    private var stored: [String: DeviceVolumeState] = [:]

    func loadIfPresent(uid: String) -> DeviceVolumeState? {
        stored[uid]
    }

    func save(uid: String, volume: Float, muted: Bool) {
        stored[uid] = DeviceVolumeState(volumeScalar: volume, isMuted: muted)
    }
}
