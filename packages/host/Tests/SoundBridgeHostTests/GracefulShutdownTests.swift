import XCTest
@testable import SoundBridgeHost

// MARK: - Quitting predictably
//
// Phase 6A, Bug #6. In the 1.2.0 field run the App sent SIGTERM and waited
// 0.15 s; the Host needs about 1.2 s for its ordered teardown, so the App always
// escalated to SIGKILL. SIGKILL skips state saving, listener removal, unmapping
// the shared memory and releasing the instance lock — which is why a killed Host
// left a `device-state.json` claiming `ready` behind it, and why the next launch
// could not tell "quitting" from "died".
//
// The fix has two halves. The App's side (a 2.5 s window and a logged
// escalation) is covered by inspection — it lives in `SoundBridgeApp.swift` and
// cannot be exercised without an app launch. The Host's side is the ordering
// modelled here:
//
//   `markStopping` first, so the App stops trusting a half-torn-down Host, and
//   `publishStopped` while the lock is still held, so a final state exists at
//   all. Both are claims about declaration order, so they are asserted against
//   the enum that *is* the execution list.

final class GracefulShutdownTests: XCTestCase {

    // MARK: - What the App needs to be able to read

    func testPublishStoppedRunsBeforeTheLockIsReleased() {
        // `HostRunState.resolve` reads the lock first and the file second. Writing
        // "stopped" after the release would mean nobody could ever read it: the
        // lock would already say "no Host".
        var sequence = ShutdownSequence()
        var order: [ShutdownSequence.Step] = []
        sequence.run { order.append($0) }

        let publish = order.firstIndex(of: .publishStopped) ?? -1
        let release = order.firstIndex(of: .releaseInstanceLock) ?? -1

        XCTAssertGreaterThanOrEqual(publish, 0, "a shutdown that never says it stopped is indistinguishable from a crash")
        XCTAssertLessThan(publish, release)
        XCTAssertEqual(order.last, .releaseInstanceLock)
    }

    func testStoppingIsAnnouncedBeforeAnyResourceIsReleased() {
        var sequence = ShutdownSequence()
        var order: [ShutdownSequence.Step] = []
        sequence.run { order.append($0) }

        XCTAssertEqual(order.first, .markStopping,
                       "the App must stop treating the Host as active before the resources behind that claim go away")
        let stopping = order.firstIndex(of: .markStopping) ?? -1
        let firstResource = order.firstIndex(of: .stopConnectionMonitor) ?? -1
        XCTAssertLessThan(stopping, firstResource)
    }

    func testListenersAreRemovedBeforeAnythingElseTouchesTheHAL() {
        // A notification delivered mid-teardown must find no listener to run: the
        // device path writes the control file, and that file must not be
        // re-published by a Host on its way out.
        var sequence = ShutdownSequence()
        var order: [ShutdownSequence.Step] = []
        sequence.run { order.append($0) }

        let remove = order.firstIndex(of: .removePropertyListeners) ?? -1
        let publish = order.firstIndex(of: .publishStopped) ?? -1

        XCTAssertGreaterThanOrEqual(remove, 0, "the shutdown must drop the HAL listeners it installed")
        XCTAssertLessThan(remove, publish)
    }

    func testTheQuitPathHasNoDefaultOutputStep() {
        // P2 Batch 2: a quit is not a licence to change the user's default
        // output. The step that put the physical device back is gone, and this
        // pins its absence to the same declaration order the rest of the file
        // asserts against.
        var sequence = ShutdownSequence()
        var order: [ShutdownSequence.Step] = []
        sequence.run { order.append($0) }

        XCTAssertFalse(order.contains { $0.rawValue.contains("restore") })
        XCTAssertFalse(order.contains { $0.rawValue.localizedCaseInsensitiveContains("default") })
    }

    // MARK: - Idempotency under repeated signals
    func testRepeatedTerminationYieldsExactlyOnePublishAndOneRelease() {
        // Two SIGTERM handlers are installed on the main queue. A third signal
        // arriving while the first pass is on the stack must not start a second.
        var sequence = ShutdownSequence()
        var published = 0
        var released = 0

        for _ in 0..<5 {
            sequence.run { step in
                if step == .publishStopped { published += 1 }
                if step == .releaseInstanceLock { released += 1 }
            }
        }

        XCTAssertEqual(published, 1, "one 'stopped' per process, not one per signal")
        XCTAssertEqual(released, 1)
    }

    func testAnIncompleteSequenceNeverClaimsToBeComplete() {
        // `main` uses `isComplete` to refuse a recovery attempt mid-teardown. If
        // it flipped true before the steps ran, a rebuild notification arriving
        // late would re-publish the control file into a Host that is leaving.
        var sequence = ShutdownSequence()
        XCTAssertFalse(sequence.isComplete)
        XCTAssertTrue(sequence.executed.isEmpty)

        sequence.run { _ in }
        XCTAssertTrue(sequence.isComplete)
        XCTAssertTrue(sequence.ranEveryStepOnce)
    }

    // MARK: - The wait has to fit in the App's window

    func testTheTeardownWaitFitsInsideTheAppsTerminationWindow() {
        // The App waits 2.5 s before escalating to SIGKILL. The teardown waits
        // once for the driver to detach; everything else is synchronous work.
        // Leaving headroom here is what keeps a normal quit from being a kill.
        XCTAssertLessThanOrEqual(
            SoundBridgeConfig.cleanupWaitTimeout, 1.5,
            "a teardown wait close to the App's 2.5s window would make SIGKILL the normal path again"
        )
        XCTAssertGreaterThan(
            SoundBridgeConfig.cleanupWaitTimeout, 0,
            "the driver reads the control file without a lock; zero wait would unmap underneath it"
        )
    }

    func testCoreAudioIsNotRestartedOnTheQuitPath() {
        // Unchanged by this phase, restated because a shutdown rewrite is exactly
        // where an automatic `coreaudiod` restart would creep back in — it takes
        // every other app's audio down with it.
        XCTAssertFalse(SoundBridgeConfig.restartsCoreAudioOnExit)
    }
}
