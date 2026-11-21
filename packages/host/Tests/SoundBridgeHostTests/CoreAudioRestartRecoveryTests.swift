import XCTest
import CoreAudio
@testable import SoundBridgeHost

// MARK: - CoreAudio rebuild: detection, retry, single-flight
//
// Phase 6A. The failure these tests model:
//
//   `killall coreaudiod` → every AudioObjectID the Host held names nothing →
//   the driver's proxy for the still-plugged monitor is deactivated → the Host
//   keeps publishing a device list built from a HAL it can no longer query →
//   nothing re-publishes the proxy, so the SoundBridge devices stay gone until
//   the App is relaunched.
//
// Three questions, answered without a running `coreaudiod`:
//
//   1. Can "the HAL rebuilt its object graph" be told apart from "a monitor was
//      unplugged"? (`CoreAudioRestartDetector`)
//   2. Is recovery bounded, spaced out, and idempotent? (`RecoveryBackoff`,
//      `CoreAudioRecoveryEpisode`)
//   3. Can two rebuild notifications start two recovery passes, and can one
//      begin after shutdown? (`CoreAudioRecoveryGate`)
//
// What is *not* covered here: a real HAL rebuild. That needs `sudo killall
// coreaudiod`, which Phase 6A's constraints forbid. The HAL calls themselves
// live in `main.swift` and are audited statically; the report marks them as
// unverified on hardware rather than claiming otherwise.

final class CoreAudioRestartRecoveryTests: XCTestCase {

    // MARK: - Fixtures

    /// A proxy that vanished while its physical device is still enumerated: the
    /// signature of a rebuild, and the shape of the 1.2.0 field failure.
    private func rebuildObservation(
        physicalUID: String = "AppleUSBAudioEngine:LG:HDR:1",
        physicalStillPresent: Bool = true,
        proxyPresent: Bool = false,
        deviceCount: Int = 2
    ) -> CoreAudioObservation {
        CoreAudioObservation(
            physicalDeviceCount: deviceCount,
            routing: ExpectedRouting(
                physicalUID: physicalUID,
                physicalStillPresent: physicalStillPresent,
                proxyPresent: proxyPresent
            )
        )
    }

    // MARK: - 1. Nothing unusual is not a rebuild

    func testAHealthyObservationIsSilent() {
        var detector = CoreAudioRestartDetector()
        let signal = detector.observe(rebuildObservation(proxyPresent: true))
        XCTAssertEqual(signal, .none, "a present proxy is the healthy case; it must not start recovery")
        XCTAssertEqual(detector.consecutiveSuspects, 0)
    }

    func testOrdinaryPlugEventIsNotARebuild() {
        // Two devices became three. No routing was involved, so nothing that is
        // enumerated can be "missing".
        var detector = CoreAudioRestartDetector()
        XCTAssertEqual(detector.observe(CoreAudioObservation(physicalDeviceCount: 2)), .none)
        XCTAssertEqual(detector.observe(CoreAudioObservation(physicalDeviceCount: 3)), .none)
    }

    func testUnpluggingTheMonitoredDeviceIsNotARebuild() {
        // The user unplugged the monitor. The physical device is gone too, so
        // this is the ordinary removal path, not a HAL rebuild. Treating it as a
        // rebuild would restart the audio engine every time a cable moved.
        var detector = CoreAudioRestartDetector()
        for _ in 0..<5 {
            let signal = detector.observe(
                rebuildObservation(physicalStillPresent: false, deviceCount: 1)
            )
            XCTAssertEqual(signal, .none)
        }
    }

    // MARK: - 2. A rebuild is suspected, then confirmed

    func testProxyVanishingIsSuspectedOnTheFirstSampleAndConfirmedOnTheSecond() {
        var detector = CoreAudioRestartDetector()

        guard case .suspected = detector.observe(rebuildObservation()) else {
            return XCTFail("one sample cannot distinguish a rebuild from a single unplug")
        }
        guard case .confirmed = detector.observe(rebuildObservation()) else {
            return XCTFail("two consecutive samples are enough evidence")
        }
    }

    func testARebuildThatTurnsOutToBeATransientBlipResetsTheCounter() {
        // One notification where the proxy is missing, then one where it is
        // back. Nothing was rebuilt; the next real suspect starts at 1 again.
        var detector = CoreAudioRestartDetector()
        guard case .suspected = detector.observe(rebuildObservation()) else {
            return XCTFail("expected a suspect sample")
        }
        XCTAssertEqual(detector.observe(rebuildObservation(proxyPresent: true)), .none)
        XCTAssertEqual(detector.consecutiveSuspects, 0)

        guard case .suspected = detector.observe(rebuildObservation()) else {
            return XCTFail("the counter must start over, not resume")
        }
    }

    func testGenericHALQueryFailureIsNotAnEmptySnapshotOrConfirmedRebuild() {
        var detector = CoreAudioRestartDetector()
        _ = detector.observe(CoreAudioObservation(physicalDeviceCount: 2))
        for _ in 0..<3 {
            guard case .suspected = detector.observe(
                CoreAudioObservation(deviceListQueryFailed: true, deviceListQueryStatus: -50, physicalDeviceCount: 0)
            ) else { return XCTFail("generic errors cannot prove a rebuild") }
            XCTAssertEqual(detector.lastDeviceCount, 2)
        }
        guard case .suspected = detector.observe(CoreAudioObservation(physicalDeviceCount: 0)) else {
            return XCTFail("a later valid empty list must still be compared with the last valid snapshot")
        }
        XCTAssertEqual(detector.observe(CoreAudioObservation(physicalDeviceCount: 0)), .none)
    }

    func testInvalidHALSystemObjectThenEmptyListConfirmsRebuild() {
        var detector = CoreAudioRestartDetector()
        _ = detector.observe(CoreAudioObservation(physicalDeviceCount: 1))
        guard case .suspected = detector.observe(CoreAudioObservation(
            deviceListQueryFailed: true, deviceListQueryStatus: kAudioHardwareBadObjectError, physicalDeviceCount: 0
        )) else { return XCTFail("one invalid system-object result needs confirmation") }
        guard case .confirmed = detector.observe(CoreAudioObservation(physicalDeviceCount: 0)) else {
            return XCTFail("empty list with invalid system-object evidence must not be a dead end")
        }
    }

    func testRepeatedInvalidHALSystemObjectConfirmsButHealthySampleClearsEvidence() {
        let invalid = CoreAudioObservation(deviceListQueryFailed: true,
                                           deviceListQueryStatus: kAudioHardwareBadObjectError,
                                           physicalDeviceCount: 0)
        var detector = CoreAudioRestartDetector()
        guard case .suspected = detector.observe(invalid) else { return XCTFail("expected suspicion") }
        guard case .confirmed = detector.observe(invalid) else { return XCTFail("expected confirmation") }
        detector.reset()
        guard case .suspected = detector.observe(invalid) else { return XCTFail("expected suspicion") }
        XCTAssertEqual(detector.observe(CoreAudioObservation(physicalDeviceCount: 1)), .none)
        guard case .suspected = detector.observe(CoreAudioObservation(physicalDeviceCount: 0)) else {
            return XCTFail("a healthy sample clears the old invalid-object evidence")
        }
        XCTAssertEqual(detector.observe(CoreAudioObservation(physicalDeviceCount: 0)), .none)
    }

    func testDifferentProxySuspicionsDoNotCombine() {
        var detector = CoreAudioRestartDetector()
        guard case .suspected = detector.observe(rebuildObservation(physicalUID: "A")) else {
            return XCTFail("expected first suspicion")
        }
        guard case .suspected = detector.observe(rebuildObservation(physicalUID: "B")) else {
            return XCTFail("different proxy losses are not consecutive evidence for the same route")
        }
        guard case .confirmed = detector.observe(rebuildObservation(physicalUID: "B")) else {
            return XCTFail("repeated missing proxy should confirm")
        }
    }

    func testEnumerationRetainsFailureStatus() {
        let result = PhysicalDeviceEnumeration.failedQuery(-50)
        XCTAssertTrue(result.queryFailed)
        XCTAssertEqual(result.queryStatus, -50)
        XCTAssertTrue(result.devices.isEmpty)
    }

    func testDeviceListGoingToOneDeviceIsANormalUnplugNotARebuild() {
        var detector = CoreAudioRestartDetector()
        _ = detector.observe(CoreAudioObservation(physicalDeviceCount: 2))
        XCTAssertEqual(detector.observe(CoreAudioObservation(physicalDeviceCount: 1)), .none)
    }

    func testDeviceListGoingToZeroWithoutOtherEvidenceIsNotConfirmed() {
        // "Zero devices" is what unplugging the last monitor looks like. It is
        // recorded as suspicious once — that is the only hint available — but
        // the ordinary idle path removes the proxies anyway, so escalating to a
        // full recovery would restart the engine for nothing.
        var detector = CoreAudioRestartDetector()
        _ = detector.observe(CoreAudioObservation(physicalDeviceCount: 2))
        guard case .suspected = detector.observe(CoreAudioObservation(physicalDeviceCount: 0)) else {
            return XCTFail("an abrupt drop to zero is worth a look")
        }
        XCTAssertEqual(detector.observe(CoreAudioObservation(physicalDeviceCount: 0)), .none)
        XCTAssertEqual(detector.observe(CoreAudioObservation(physicalDeviceCount: 0)), .none)
    }

    func testResetForgetsTheSampleHistory() {
        var detector = CoreAudioRestartDetector()
        _ = detector.observe(rebuildObservation())
        detector.reset()
        XCTAssertEqual(detector.consecutiveSuspects, 0)
        XCTAssertNil(detector.lastDeviceCount)

        guard case .suspected = detector.observe(rebuildObservation()) else {
            return XCTFail("after a reset the next episode counts from zero")
        }
    }

    func testConfirmAfterIsConfigurableAndNeverBelowOne() {
        var impatient = CoreAudioRestartDetector(confirmAfter: 1)
        guard case .confirmed = impatient.observe(rebuildObservation()) else {
            return XCTFail("confirmAfter 1 confirms on the first sample")
        }

        var clamped = CoreAudioRestartDetector(confirmAfter: 0)
        XCTAssertEqual(clamped.confirmAfter, 1)
        guard case .confirmed = clamped.observe(rebuildObservation()) else {
            return XCTFail("a zero threshold must not mean 'never confirm'")
        }
    }

    // MARK: - 3. Retry schedule

    func testBackoffConsumesEverySlotOnceAndThenStops() {
        var backoff = RecoveryBackoff(delays: [0, 1.0, 2.0, 4.0])

        XCTAssertEqual(backoff.nextDelay(), 0, "the first attempt runs immediately: the usual cause is already fixed")
        XCTAssertEqual(backoff.nextDelay(), 1.0)
        XCTAssertEqual(backoff.nextDelay(), 2.0)
        XCTAssertEqual(backoff.nextDelay(), 4.0)
        XCTAssertNil(backoff.nextDelay(), "a bounded schedule must end")
        XCTAssertEqual(backoff.attemptsMade, 4)
        XCTAssertEqual(backoff.plannedAttempts, 4)
    }

    func testBackoffNeverProducesATightLoop() {
        // Every slot after the first is spaced out; a 100ms poll loop here would
        // rewrite the control file ten times a second.
        var backoff = RecoveryBackoff()
        var delays: [TimeInterval] = []
        while let delay = backoff.nextDelay() {
            delays.append(delay)
        }
        XCTAssertEqual(delays.first, 0)
        XCTAssertTrue(delays.dropFirst().allSatisfy { $0 > 0 })
        XCTAssertLessThanOrEqual(delays.count, 5, "recovery must not be open-ended")
    }

    func testBackoffResetMakesTheScheduleReusable() {
        var backoff = RecoveryBackoff(delays: [0, 1.0])
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        XCTAssertNil(backoff.nextDelay())

        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 0)
    }

    // MARK: - 4. One episode

    func testRecoverySucceedsOnTheFirstAttemptWithoutSleeping() {
        var slept: [TimeInterval] = []
        let episode = CoreAudioRecoveryEpisode(
            sleep: { slept.append($0) },
            attempt: { _ in .recovered(detail: "proxy re-published") }
        )

        let outcome = episode.run()

        XCTAssertEqual(outcome, .recovered(attempts: 1, detail: "proxy re-published"))
        XCTAssertTrue(outcome.isRecovered)
        XCTAssertTrue(slept.isEmpty, "the first attempt must not wait")
    }

    func testRetryableFailuresAreRetriedUntilTheySucceed() {
        var attempts: [Int] = []
        var slept: [TimeInterval] = []
        let episode = CoreAudioRecoveryEpisode(
            sleep: { slept.append($0) },
            attempt: { n in
                attempts.append(n)
                return n < 3 ? .retryable(reason: "HAL not up yet") : .recovered(detail: "ok")
            }
        )

        let outcome = episode.run()

        XCTAssertEqual(attempts, [1, 2, 3], "attempts are 1-based and strictly sequential")
        XCTAssertEqual(slept, [1.0, 2.0], "no sleep before the first attempt, then the schedule")
        XCTAssertEqual(outcome, .recovered(attempts: 3, detail: "ok"))
    }

    func testATerminalResultStopsTheLoopImmediately() {
        var calls = 0
        let episode = CoreAudioRecoveryEpisode(
            sleep: { _ in },
            attempt: { _ in
                calls += 1
                return .terminal(reason: "the driver is not installed")
            }
        )

        let outcome = episode.run()

        XCTAssertEqual(calls, 1, "a terminal failure is not retried")
        XCTAssertEqual(outcome, .failed(attempts: 1, reason: "the driver is not installed"))
        XCTAssertFalse(outcome.isRecovered)
    }

    func testAnEpisodeThatNeverSucceedsIsReportedAsExhausted() {
        var calls = 0
        let episode = CoreAudioRecoveryEpisode(
            backoff: RecoveryBackoff(delays: [0, 0.01, 0.01]),
            sleep: { _ in },
            attempt: { _ in
                calls += 1
                return .retryable(reason: "proxy still missing")
            }
        )

        let outcome = episode.run()

        XCTAssertEqual(calls, 3, "exactly the planned number of attempts")
        XCTAssertEqual(outcome, .exhausted(attempts: 3, lastReason: "proxy still missing"))
        XCTAssertTrue(outcome.diagnostic.contains("proxy still missing"),
                      "the last reason must reach the lifecycle detail, not just the log")
    }

    func testRecoveryCancellationDuringBackoffPreventsAnotherAttempt() {
        var running = true
        var calls = 0
        let episode = CoreAudioRecoveryEpisode(
            sleep: { _ in running = false },
            shouldContinue: { running },
            attempt: { _ in calls += 1; return .retryable(reason: "not ready") }
        )
        XCTAssertEqual(episode.run(), .failed(attempts: 1, reason: "recovery cancelled"))
        XCTAssertEqual(calls, 1)
    }

    func testAttemptBudgetPreventsLaterStepsAfterBlockingCallReturns() {
        var time: TimeInterval = 0
        var sideEffects: [String] = []
        let episode = CoreAudioRecoveryEpisode(
            backoff: RecoveryBackoff(delays: [0]),
            sleep: { _ in }, now: { time }, episodeTimeout: 20, attemptTimeout: 5,
            attemptWithBudget: { _, canProceed in
                sideEffects.append("enumerate")
                time = 6 // 模拟无法中断的同步 HAL 调用返回。
                if canProceed() { sideEffects.append("publish ready") }
                return .recovered(detail: "late")
            }
        )
        XCTAssertEqual(episode.run(), .exhausted(attempts: 1, lastReason: "attempt deadline exceeded"))
        XCTAssertEqual(sideEffects, ["enumerate"])
    }

    func testTimedOutStartedEngineIsStoppedBeforeBackoffAndRetry() {
        var time: TimeInterval = 0
        var running = false
        var events: [String] = []
        let episode = CoreAudioRecoveryEpisode(
            backoff: RecoveryBackoff(delays: [0, 1]),
            sleep: { delay in
                XCTAssertFalse(running, "超时的引擎不能在退避期间继续运行")
                events.append("sleep")
                time += delay
            },
            now: { time }, episodeTimeout: 20, attemptTimeout: 5,
            discardAttempt: { running = false; events.append("stop") },
            attemptWithBudget: { attempt, canProceed in
                XCTAssertFalse(running)
                running = true
                events.append("start\(attempt)")
                if attempt == 1 {
                    time += 6
                    XCTAssertFalse(canProceed())
                    return .terminal(reason: "late start")
                }
                return .recovered(detail: "ready")
            }
        )
        XCTAssertEqual(episode.run(), .recovered(attempts: 2, detail: "ready"))
        XCTAssertEqual(events, ["start1", "stop", "sleep", "start2"])
        XCTAssertTrue(running, "已提交的引擎应继续运行")
    }

    func testFailedOrUncommittedAttemptsDiscardEngine() {
        for result in [
            RecoveryAttemptResult.retryable(reason: "start failed"), .terminal(reason: "failed"), .recovered(detail: "dirty")
        ] {
            var running = false
            var stops = 0
            let episode = CoreAudioRecoveryEpisode(
                backoff: RecoveryBackoff(delays: [0]), sleep: { _ in },
                commitAttempt: { false },
                discardAttempt: { running = false; stops += 1 },
                attempt: { _ in running = true; return result }
            )
            _ = episode.run()
            XCTAssertFalse(running, "\(result)")
            XCTAssertEqual(stops, 1, "\(result)")
        }
    }

    func testEpisodeDeadlineDiscardsEngineButShutdownOwnsCancellationCleanup() {
        var time: TimeInterval = 0
        var running = false
        var stops = 0
        let timedOut = CoreAudioRecoveryEpisode(
            backoff: RecoveryBackoff(delays: [0]), sleep: { _ in }, now: { time },
            episodeTimeout: 5, attemptTimeout: 5,
            discardAttempt: { running = false; stops += 1 },
            attempt: { _ in running = true; time = 6; return .recovered(detail: "late") }
        )
        XCTAssertEqual(timedOut.run(), .exhausted(attempts: 1, lastReason: "episode deadline exceeded"))
        XCTAssertFalse(running)
        XCTAssertEqual(stops, 1)

        var alive = true
        let cancelled = CoreAudioRecoveryEpisode(
            shouldContinue: { alive }, discardAttempt: { stops += 1 },
            attempt: { _ in alive = false; running = false; return .recovered(detail: "late") }
        )
        XCTAssertEqual(cancelled.run(), .failed(attempts: 1, reason: "recovery cancelled"))
        XCTAssertFalse(running, "模拟 Shutdown 已回收引擎")
        XCTAssertEqual(stops, 1, "Shutdown 后不能再由 Recovery 操作引擎")
    }

    func testWakeEngineRestartStopsBeforeStartWhenSetupInvalidatesLifecycle() throws {
        for stop in [false, true] {
            let gate = HostLifecycleGate()
            let token = try XCTUnwrap(gate.normalToken())
            var events: [String] = []
            let result = try GuardedEngineStart.run(
                canProceed: { gate.permitsNormal(token) },
                setup: {
                    events.append("setup")
                    if stop { gate.stop() } else { XCTAssertTrue(gate.beginRecovery()) }
                },
                start: { events.append("start") }
            )
            XCTAssertEqual(result, .cancelled)
            XCTAssertEqual(events, ["setup"])
        }
    }

    func testWakeEngineRestartRejectsStaleTokenAndChecksAfterStart() throws {
        let gate = HostLifecycleGate()
        let token = try XCTUnwrap(gate.normalToken())
        var events: [String] = []
        let result = try GuardedEngineStart.run(
            canProceed: { gate.permitsNormal(token) },
            setup: { events.append("setup") },
            start: { events.append("start"); gate.stop() }
        )
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(events, ["setup", "start"])
        let stale = try GuardedEngineStart.run(
            canProceed: { gate.permitsNormal(token) },
            setup: { events.append("stale setup") },
            start: { events.append("stale start") }
        )
        XCTAssertEqual(stale, .cancelled)
        XCTAssertEqual(events, ["setup", "start"])
    }

    func testWakeEngineRestartRunsBothStepsWhenLifecycleIsStable() throws {
        var events: [String] = []
        let result = try GuardedEngineStart.run(
            canProceed: { true }, setup: { events.append("setup") }, start: { events.append("start") }
        )
        XCTAssertEqual(result, .started)
        XCTAssertEqual(events, ["setup", "start"])
    }

    func testGuardedEngineStartDiscardsErrorsFromInvalidatedLifecycle() throws {
        enum FixtureError: Error { case failed }
        for failDuringStart in [false, true] {
            let gate = HostLifecycleGate()
            let token = try XCTUnwrap(gate.normalToken())
            var started = false
            let result = try GuardedEngineStart.run(
                canProceed: { gate.permitsNormal(token) },
                setup: {
                    if !failDuringStart { gate.stop(); throw FixtureError.failed }
                },
                start: {
                    started = true
                    gate.stop()
                    throw FixtureError.failed
                }
            )
            XCTAssertEqual(result, .cancelled)
            XCTAssertEqual(started, failDuringStart)
        }
    }

    func testGuardedEngineStartPropagatesErrorsForCurrentLifecycle() {
        enum FixtureError: Error { case failed }
        for failDuringStart in [false, true] {
            var started = false
            XCTAssertThrowsError(try GuardedEngineStart.run(
                canProceed: { true },
                setup: { if !failDuringStart { throw FixtureError.failed } },
                start: { started = true; throw FixtureError.failed }
            ))
            XCTAssertEqual(started, failDuringStart)
        }
    }

    func testGuardedEngineStartDoesNotStartAfterSessionLoss() throws {
        var sessionIsCurrent = true
        var started = false
        let result = try GuardedEngineStart.run(
            canProceed: { sessionIsCurrent },
            setup: { sessionIsCurrent = false },
            start: { started = true }
        )
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(started)
    }

    func testHotplugPublishesOnlyAfterMissingMappingsArePrepared() {
        var mappings: Set<String> = ["existing"]
        var attempts: [String] = []
        var snapshots: [[String]] = []
        var failSecond = true
        let devices = ["existing", "new-a", "new-b"]
        func reconcile() -> Bool {
            DeviceMappingPreparation.publishIfReady(
                uids: devices, canProceed: { true }, hasMapping: { mappings.contains($0) },
                createMapping: { uid in
                    attempts.append(uid)
                    if uid == "new-b", failSecond { return false }
                    mappings.insert(uid)
                    return true
                },
                publish: { snapshots.append(devices); return true }
            )
        }

        XCTAssertFalse(reconcile())
        XCTAssertEqual(attempts, ["new-a", "new-b"])
        XCTAssertTrue(snapshots.isEmpty, "映射未全部建立时不得发布设备快照")
        failSecond = false
        XCTAssertTrue(reconcile())
        XCTAssertEqual(attempts, ["new-a", "new-b", "new-b"], "重试复用此前已建立的映射")
        XCTAssertEqual(snapshots, [devices])
    }

    func testHotplugReusesMappingDuringRapidReappearance() {
        var creates = 0
        var published = false
        XCTAssertTrue(DeviceMappingPreparation.publishIfReady(
            uids: ["reappeared"], canProceed: { true }, hasMapping: { $0 == "reappeared" },
            createMapping: { _ in creates += 1; return true }, publish: { published = true; return true }
        ))
        XCTAssertEqual(creates, 0)
        XCTAssertTrue(published)
    }

    func testHotplugReportsControlPublicationFailure() {
        var calls = 0
        XCTAssertFalse(DeviceMappingPreparation.publishIfReady(
            uids: ["prepared"], canProceed: { true }, hasMapping: { _ in true },
            createMapping: { _ in XCTFail("已有映射不应重新创建"); return false },
            publish: { calls += 1; return false }
        ))
        XCTAssertEqual(calls, 1)
    }

    func testHotplugCannotPublishAfterLifecycleChangesDuringPreparation() throws {
        let gate = HostLifecycleGate()
        let token = try XCTUnwrap(gate.normalToken())
        var created: [String] = []
        var published = false
        XCTAssertFalse(DeviceMappingPreparation.publishIfReady(
            uids: ["a", "b"], canProceed: { gate.permitsNormal(token) }, hasMapping: { _ in false },
            createMapping: { uid in created.append(uid); gate.stop(); return true },
            publish: { published = true; return true }
        ))
        XCTAssertEqual(created, ["a"])
        XCTAssertFalse(published)
    }

    func testEpisodeDeadlineIncludesAttemptsAndBackoff() {
        var time: TimeInterval = 0
        var calls = 0
        let episode = CoreAudioRecoveryEpisode(
            sleep: { time += $0 }, now: { time }, episodeTimeout: 2, attemptTimeout: 2,
            attempt: { _ in calls += 1; time += 0.5; return .retryable(reason: "waiting") }
        )
        XCTAssertEqual(episode.run(), .exhausted(attempts: 2, lastReason: "episode deadline exceeded"))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(time, 2)
    }

    func testNoPhysicalDeviceWaitsInsteadOfTerminatingHost() {
        let episode = CoreAudioRecoveryEpisode(
            attempt: { _ in .waitingForDevice(reason: "no device") }
        )
        XCTAssertEqual(episode.run(), .waitingForDevice(attempts: 1, reason: "no device"))
    }

    func testRecoveryEventsForceAnotherSnapshotBeforeFinishing() {
        let gate = HostLifecycleGate()
        XCTAssertTrue(gate.beginRecovery())
        let first = gate.recoverySnapshot()
        XCTAssertNil(gate.captureEventToken()) // 拔出设备。
        XCTAssertNil(gate.captureEventToken()) // 新设备及默认输出变化。
        XCTAssertFalse(gate.finishRecovery(ifUnchanged: first))
        let second = gate.recoverySnapshot()
        XCTAssertNil(gate.captureEventToken()) // 收敛期间又收到通知。
        XCTAssertFalse(gate.finishRecovery(ifUnchanged: second))
        XCTAssertTrue(gate.finishRecovery(ifUnchanged: gate.recoverySnapshot()))
        XCTAssertNotNil(gate.captureEventToken(), "提交后的事件必须走普通事件路径")
        XCTAssertFalse(gate.finishRecovery(ifUnchanged: gate.recoverySnapshot()))
    }

    func testShutdownCancelsPendingRecoveryReconciliation() {
        let gate = HostLifecycleGate()
        XCTAssertTrue(gate.beginRecovery())
        let generation = gate.recoverySnapshot()
        gate.stop()
        XCTAssertFalse(gate.finishRecovery(ifUnchanged: generation))
        XCTAssertNil(gate.captureEventToken())
    }

    func testRecoveryEpisodeReconcilesChangedDeviceAndDefaultBeforeCommit() {
        let gate = HostLifecycleGate()
        XCTAssertTrue(gate.beginRecovery())
        var device = "A"
        var defaultOutput = "proxy-A"
        var observed: [(String, String)] = []
        var generation: UInt64 = 0
        let episode = CoreAudioRecoveryEpisode(
            backoff: RecoveryBackoff(delays: [0, 0]), sleep: { _ in },
            commitAttempt: { gate.finishRecovery(ifUnchanged: generation) },
            attempt: { attempt in
                generation = gate.recoverySnapshot()
                observed.append((device, defaultOutput))
                if attempt == 1 {
                    device = "B"
                    defaultOutput = "speaker"
                    _ = gate.captureEventToken()
                    _ = gate.captureEventToken()
                }
                return .recovered(detail: "ready")
            }
        )
        XCTAssertEqual(episode.run(), .recovered(attempts: 2, detail: "ready"))
        XCTAssertEqual(observed.map { $0.0 }, ["A", "B"])
        XCTAssertEqual(observed.map { $0.1 }, ["proxy-A", "speaker"])
        XCTAssertNotNil(gate.normalToken())
    }

    func testExpiredAttemptCannotCommitReconciliation() {
        let gate = HostLifecycleGate()
        XCTAssertTrue(gate.beginRecovery())
        var clock: TimeInterval = 0
        var commits = 0
        let episode = CoreAudioRecoveryEpisode(
            backoff: RecoveryBackoff(delays: [0]), sleep: { _ in }, now: { clock },
            episodeTimeout: 20, attemptTimeout: 5,
            commitAttempt: { commits += 1; return gate.finishRecovery(ifUnchanged: gate.recoverySnapshot()) },
            attempt: { _ in clock = 6; return .recovered(detail: "late") }
        )
        XCTAssertEqual(episode.run(), .exhausted(attempts: 1, lastReason: "attempt deadline exceeded"))
        XCTAssertEqual(commits, 0)
        XCTAssertNil(gate.normalToken())
    }

    func testLifecycleGateInvalidatesQueuedWakeBounceAndVolumeAfterRecovery() throws {
        let gate = HostLifecycleGate()
        let queuedToken = try XCTUnwrap(gate.normalToken())
        var operations: [String] = []
        let queued = { if gate.permitsNormal(queuedToken) { operations.append("device operation") } }
        XCTAssertTrue(gate.beginRecovery())
        queued()
        gate.endRecovery()
        queued()
        XCTAssertTrue(operations.isEmpty)
        let newToken = try XCTUnwrap(gate.normalToken())
        XCTAssertTrue(gate.permitsNormal(newToken))
        XCTAssertNotEqual(queuedToken, newToken)
    }

    func testLifecycleGateStoppingIsFinalEvenIfRecoveryFinishes() throws {
        let gate = HostLifecycleGate()
        let token = try XCTUnwrap(gate.normalToken())
        XCTAssertTrue(gate.beginRecovery())
        gate.stop()
        gate.endRecovery()
        XCTAssertFalse(gate.permitsNormal(token))
        XCTAssertNil(gate.normalToken())
        XCTAssertFalse(gate.beginRecovery())
    }

    func testConnectionSampleCannotPublishAcrossRecoveryAndMustRestart() {
        let gate = HostLifecycleGate()
        var enterRecovery = true
        var reports: [SharedMemoryConnectionStatus] = []
        let monitor = DriverConnectionMonitor(
            interval: 60, lifecycleGate: gate,
            sample: {
                if enterRecovery { _ = gate.beginRecovery() }
                return DriverConnectionObservation(headerValid: true, driverConnected: true,
                                                   driverHeartbeat: 1, hostHeartbeat: 1)
            },
            report: { status, _ in reports.append(status) }
        )
        monitor.start()
        monitor.sampleNow()
        XCTAssertTrue(reports.isEmpty)
        gate.endRecovery()
        enterRecovery = false
        monitor.sampleNow()
        XCTAssertTrue(reports.isEmpty, "旧采样代际不能在恢复结束后复活")
        monitor.stop()
        monitor.start()
        monitor.sampleNow()
        XCTAssertEqual(reports, [.connected])
        monitor.stop()
    }

    func testConnectionSampleCannotPublishAfterStoppingDuringSampling() {
        let gate = HostLifecycleGate()
        var reports: [SharedMemoryConnectionStatus] = []
        let monitor = DriverConnectionMonitor(
            interval: 60, lifecycleGate: gate,
            sample: {
                gate.stop()
                return DriverConnectionObservation(headerValid: true, driverConnected: true,
                                                   driverHeartbeat: 1, hostHeartbeat: 1)
            },
            report: { status, _ in reports.append(status) }
        )
        monitor.start()
        monitor.sampleNow()
        monitor.stop()
        XCTAssertTrue(reports.isEmpty)
        monitor.start()
        monitor.sampleNow()
        XCTAssertTrue(reports.isEmpty, "停止后的监控不能重新启动")
    }

    func testLifecycleReporterSerializesSnapshotPublication() {
        let firstPublishing = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        var published: [HostStartupOutcome] = []
        let reporter = HostLifecycleReporter { snapshot in
            if snapshot.outcome == .ready {
                firstPublishing.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
            published.append(snapshot.outcome)
        }
        finished.enter()
        DispatchQueue.global().async {
            reporter.update { $0.outcome = .ready }
            finished.leave()
        }
        XCTAssertEqual(firstPublishing.wait(timeout: .now() + 2), .success)
        finished.enter()
        DispatchQueue.global().async {
            secondStarted.signal()
            reporter.update { $0.outcome = .stopped }
            secondFinished.signal()
            finished.leave()
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(published, [.ready, .stopped])
        XCTAssertEqual(reporter.current().outcome, .stopped)
    }

    func testRepeatedTriggersDoNotStartASecondPass() {
        // What the main queue actually sees during a coreaudiod restart: several
        // device notifications before the first probe lands back on main.
        var gate = CoreAudioRecoveryGate()
        var started = 0

        for _ in 0..<32 where gate.begin() {
            started += 1
        }

        XCTAssertEqual(started, 1, "a notification storm must not fan out into parallel recoveries")
        XCTAssertEqual(gate.episodes, 1)
        XCTAssertTrue(gate.isRecovering)
    }

    func testGateReopensAfterTheEpisodeFinishes() {
        var gate = CoreAudioRecoveryGate()
        XCTAssertTrue(gate.begin())
        gate.finish()

        XCTAssertFalse(gate.isRecovering)
        XCTAssertTrue(gate.begin(), "a second rebuild later in the same process must be recoverable")
        XCTAssertEqual(gate.episodes, 2)
    }

    func testAGateThatWasTerminatedRefusesToStartAndStaysRefused() {
        // Recovery rewrites the control file and re-registers listeners. A Host
        // that is already tearing down must not do either.
        var gate = CoreAudioRecoveryGate()
        gate.terminate()

        XCTAssertFalse(gate.begin())
        XCTAssertEqual(gate.episodes, 0)
        XCTAssertTrue(gate.isTerminated)

        gate.terminate()
        XCTAssertFalse(gate.begin(), "terminate is idempotent and final")
    }

    func testTerminatingMidEpisodeReleasesTheGuardWithoutRestarting() {
        var gate = CoreAudioRecoveryGate()
        XCTAssertTrue(gate.begin())
        gate.terminate()
        gate.finish()

        XCTAssertFalse(gate.isRecovering)
        XCTAssertFalse(gate.begin())
    }
}

// 仅运行普通设备列表处理路径：不注册 HAL listener、不解析代理、不修改默认输出。
// 所有 IPC 和映射都位于独立目录，设备枚举由 Fake 提供。
final class DeviceMonitorMappingTests: XCTestCase {
    private final class FakeDiscovery: DeviceDiscovery {
        var devices: [PhysicalDevice] = []
        var enumerations = 0

        override func enumeratePhysicalDevicesWithStatus() -> PhysicalDeviceEnumeration {
            enumerations += 1
            return PhysicalDeviceEnumeration(devices: devices, queryFailed: false, totalAudioDeviceCount: devices.count)
        }
    }

    private final class MappingPaths {
        let root: URL
        var failUID: String?

        init(root: URL) { self.root = root }
        func path(_ uid: String) -> String {
            let directory = uid == failUID ? root.appendingPathComponent("missing") : root
            return directory.appendingPathComponent("mapping-\(uid)").path
        }
    }

    private var sandbox: URL!
    private var paths: MappingPaths!
    private var discovery: FakeDiscovery!
    private var registry: DeviceRegistry!
    private var memory: SharedMemoryManager!
    private var monitor: DeviceMonitor!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        paths = MappingPaths(root: sandbox)
        let session = UUID()
        registry = DeviceRegistry(
            controlFilePath: sandbox.appendingPathComponent("control").path,
            deviceStateURL: sandbox.appendingPathComponent("state.json"), notify: { _ in }
        )
        registry.beginSession(session)
        let fixturePaths = paths!
        memory = SharedMemoryManager(sessionID: session, pathForUID: { fixturePaths.path($0) })
        let persistence = VolumePersistence(fileURL: sandbox.appendingPathComponent("volume.json"))
        let proxy = ProxyDeviceManager(registry: registry, volumePersistence: persistence)
        // P2 Batch 4: the render path no longer asks the proxy manager for the
        // active UID; the routing decision is pushed into the mapping manager.
        proxy.onManagedProxyChanged = { [weak self] uid in self?.memory?.setPreferredRenderUID(uid) }
        let renderer = AudioRenderer(memoryManager: memory)
        let engine = AudioEngine(renderer: renderer, registry: registry)
        discovery = FakeDiscovery()
        monitor = DeviceMonitor(registry: registry, proxyManager: proxy, memoryManager: memory,
                                discovery: discovery, audioEngine: engine)
    }

    override func tearDownWithError() throws {
        monitor?.stop()
        memory?.cleanup()
        monitor = nil
        memory = nil
        try FileManager.default.removeItem(at: sandbox)
        sandbox = nil
        try super.tearDownWithError()
    }

    private func device(_ uid: String, id: AudioDeviceID) -> PhysicalDevice {
        PhysicalDevice(id: id, name: uid, uid: uid, manufacturer: "Fake", transportType: 0,
                       isOutput: true, validationPassed: true, validationNote: nil, isFixedVolume: true)
    }

    private func waitForMainQueue(_ delay: TimeInterval) {
        let completed = expectation(description: "等待主队列上的有界重查")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { completed.fulfill() }
        wait(for: [completed], timeout: delay + 2)
    }

    func testMappingFailureKeepsPublishedSnapshotThenRecheckPublishesPreparedDevices() throws {
        let old = device("old", id: 1)
        let addedA = device("new-a", id: 2)
        let addedB = device("new-b", id: 3)
        discovery.devices = [old]
        monitor.handleDeviceListChanged(allowRoutingChanges: false)
        let control = sandbox.appendingPathComponent("control")
        let state = sandbox.appendingPathComponent("state.json")
        let oldControl = try Data(contentsOf: control)
        let oldState = try Data(contentsOf: state)

        paths.failUID = addedB.uid
        discovery.devices = [old, addedA, addedB]
        monitor.handleDeviceListChanged(allowRoutingChanges: false)
        XCTAssertEqual(registry.devices.map(\.uid), [old.uid])
        XCTAssertEqual(try Data(contentsOf: control), oldControl)
        XCTAssertEqual(try Data(contentsOf: state), oldState)
        let retainedGeneration = try XCTUnwrap(memory.acquireMemory(for: addedA.uid)?.generation)
        XCTAssertNil(memory.acquireMemory(for: addedB.uid))

        paths.failUID = nil
        waitForMainQueue(SoundBridgeConfig.coreAudioRebuildRecheckDelay + 0.3)
        XCTAssertEqual(discovery.enumerations, 3)
        XCTAssertEqual(registry.devices.map(\.uid), [old.uid, addedA.uid, addedB.uid])
        XCTAssertEqual(memory.acquireMemory(for: addedA.uid)?.generation, retainedGeneration)
        XCTAssertNotNil(memory.acquireMemory(for: addedB.uid))
        let payload = try JSONDecoder().decode(HostDeviceStatePayload.self, from: Data(contentsOf: state))
        XCTAssertEqual(payload.devices.map(\.uid), [old.uid, addedA.uid, addedB.uid])
    }

    func testRejectedControlSnapshotRetainsRegistryAndRecheckPublishesValidSnapshot() throws {
        let old = device("old", id: 1)
        let added = device("new", id: 2)
        let invalid = PhysicalDevice(id: added.id, name: "bad|name", uid: added.uid,
                                     manufacturer: "Fake", transportType: 0, isOutput: true,
                                     validationPassed: true, validationNote: nil, isFixedVolume: true)
        discovery.devices = [old]
        monitor.handleDeviceListChanged(allowRoutingChanges: false)
        let control = sandbox.appendingPathComponent("control")
        let state = sandbox.appendingPathComponent("state.json")
        let oldControl = try Data(contentsOf: control)
        let oldState = try Data(contentsOf: state)

        discovery.devices = [old, invalid]
        monitor.handleDeviceListChanged(allowRoutingChanges: false)
        XCTAssertEqual(registry.devices.map(\.uid), [old.uid])
        XCTAssertEqual(try Data(contentsOf: control), oldControl)
        XCTAssertEqual(try Data(contentsOf: state), oldState)
        let generation = try XCTUnwrap(memory.acquireMemory(for: added.uid)?.generation)

        discovery.devices = [old, added]
        waitForMainQueue(SoundBridgeConfig.coreAudioRebuildRecheckDelay + 0.3)
        XCTAssertEqual(discovery.enumerations, 3)
        XCTAssertEqual(registry.devices.map(\.uid), [old.uid, added.uid])
        XCTAssertEqual(memory.acquireMemory(for: added.uid)?.generation, generation)
        let payload = try JSONDecoder().decode(HostDeviceStatePayload.self, from: Data(contentsOf: state))
        XCTAssertEqual(payload.devices.map(\.uid), [old.uid, added.uid])
    }

    func testPersistentMappingFailureHasOnlyOneRecheckUntilAnotherEvent() {
        let added = device("new", id: 1)
        paths.failUID = added.uid
        discovery.devices = [added]
        monitor.handleDeviceListChanged(allowRoutingChanges: false)
        waitForMainQueue(SoundBridgeConfig.coreAudioRebuildRecheckDelay * 2 + 0.3)
        XCTAssertEqual(discovery.enumerations, 2)
        XCTAssertTrue(registry.devices.isEmpty)

        paths.failUID = nil
        monitor.handleDeviceListChanged(allowRoutingChanges: false)
        XCTAssertEqual(discovery.enumerations, 3)
        XCTAssertEqual(registry.devices.map(\.uid), [added.uid])
        XCTAssertNotNil(memory.acquireMemory(for: added.uid))
    }

    func testStoppingCancelsMappingFailureRecheck() {
        let added = device("new", id: 1)
        paths.failUID = added.uid
        discovery.devices = [added]
        monitor.handleDeviceListChanged(allowRoutingChanges: false)
        monitor.stop()
        paths.failUID = nil
        waitForMainQueue(SoundBridgeConfig.coreAudioRebuildRecheckDelay + 0.3)
        XCTAssertEqual(discovery.enumerations, 1)
        XCTAssertTrue(registry.devices.isEmpty)
        XCTAssertNil(memory.acquireMemory(for: added.uid))
    }
}
