import XCTest
import Darwin
import CSoundBridgeAudio
@testable import SoundBridgeApp

// MARK: - Shared helpers
//
// P2 Batch 3 §7.3 / §7.4. `SharedMemoryMappingManagerTests` proves the pipeline
// one step at a time; this file proves it while other threads are using it, and
// that the EQ writer keeps working across an outage.
//
// Both files use `SharedMemoryFixture`, which builds the Host's real
// staging → init → session → admission → rename sequence inside a throwaway
// directory and never touches `/tmp/soundbridge-*`.

/// Spin the main run loop until `condition` holds or the deadline passes.
///
/// Needed because `mappingPublished` is delivered on the main queue: a test that
/// blocked the main thread with `sleep` would deadlock the very hand-off it is
/// waiting for. Returns the final state of the condition, so the caller asserts
/// rather than assuming success.
@discardableResult
private func waitUntil(
    _ timeout: TimeInterval = 5,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

private func bands(
    of snapshot: RFEQSnapshot?
) -> [Float] {
    guard var copy = snapshot else { return [] }
    return withUnsafeBytes(of: &copy.bands) { Array($0.bindMemory(to: Float.self)) }
}

// MARK: - §7.3 Concurrency

final class SharedMemoryMappingConcurrencyTests: XCTestCase {

    private var fixture: SharedMemoryFixture!
    private var manager: SharedMemoryMappingManager!

    override func setUp() {
        super.setUp()
        fixture = SharedMemoryFixture(name: "concurrency-\(name)")
        manager = SharedMemoryMappingManager(pathForUID: { [path = fixture.path] _ in path })
    }

    override func tearDown() {
        manager = nil
        fixture.teardown()
        fixture = nil
        super.tearDown()
    }

    private func attach() -> SharedMemoryAttachOutcome {
        manager.attachSynchronously(uid: "dev-a")
    }

    // MARK: Writes racing a replacement

    func testConcurrentWritersAndReplacementsNeverFaultOrStrandAWriter() throws {
        let first = try fixture.publish()
        XCTAssertTrue(attach().didAttach)

        let manager = self.manager!
        let snapshot = fixture.snapshot(marker: 1)
        var published: [FixtureIncarnation] = [first]

        let group = DispatchGroup()
        for _ in 0..<6 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for _ in 0..<150 { _ = manager.writeEQSnapshot(snapshot) }
            }
        }
        // Ten replacements, each a new inode, published while the writers run.
        // `published` is only mutated here; it is read after `wait`.
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            for _ in 0..<10 {
                if let incarnation = try? self.fixture.publish() {
                    published.append(incarnation)
                }
                _ = manager.attachSynchronously(uid: "dev-a")
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 60), .success,
                       "no writer may block forever while mappings are replaced")
        XCTAssertTrue(attach().isCurrent)
        XCTAssertEqual(manager.currentIdentity, published.last?.identity)

        // Whatever the writers did before retirement, the retired inode must be
        // frozen from here on and the new one must take the write.
        let frozen = first.eqSnapshot?.preamp
        XCTAssertTrue(manager.writeEQSnapshot(fixture.snapshot(marker: 99)).isWritten)
        XCTAssertEqual(published.last?.eqSnapshot?.preamp, 99)
        XCTAssertEqual(first.eqSnapshot?.preamp, frozen,
                       "a retired mapping must not receive writes after the swap")
    }

    func testInFlightWriterSurvivesRepeatedReplacements() throws {
        _ = try fixture.publish()
        XCTAssertTrue(attach().didAttach)

        let manager = self.manager!
        let replica: SharedMemoryFixture = fixture
        let writerDone = DispatchSemaphore(value: 0)
        var bodiesRun = 0
        var writesReported = 0

        // The body reads the mapping on every iteration, so a `munmap` that
        // ignored the lease faults here instead of quietly passing a counter.
        let writer = Thread {
            for _ in 0..<200 {
                let result = manager.write { memory in
                    _ = memory.pointee.eq_snapshot.preamp
                    bodiesRun += 1
                    usleep(200)
                }
                if case .written = result { writesReported += 1 }
            }
            writerDone.signal()
        }
        writer.start()

        var newest: FixtureIncarnation?
        for _ in 0..<15 {
            newest = try replica.publish()
            _ = manager.attachSynchronously(uid: "dev-a")
        }

        XCTAssertEqual(writerDone.wait(timeout: .now() + 30), .success,
                       "the in-flight writer must finish")
        // A write either ran inside a lease and reported `.written`, or never
        // ran at all. There is no third outcome — and 15 replacements make both
        // happen.
        XCTAssertEqual(bodiesRun, writesReported,
                       "the body must run exactly when a write is reported as written")
        XCTAssertGreaterThan(writesReported, 0)
        XCTAssertEqual(manager.currentIdentity, newest?.identity)
    }

    // MARK: Writes racing retirement

    func testRetirementDuringConcurrentWritesLeavesTheWriterUnavailable() throws {
        _ = try fixture.publish()
        XCTAssertTrue(attach().didAttach)

        let manager = self.manager!
        let snapshot = fixture.snapshot(marker: 3)
        let group = DispatchGroup()
        for _ in 0..<5 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for _ in 0..<120 { _ = manager.writeEQSnapshot(snapshot) }
            }
        }

        fixture.removePublishedFile()
        manager.revalidate()

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        // Drain the attach queue: retirement is asynchronous by design.
        _ = manager.attachSynchronously(uid: "dev-a")

        XCTAssertFalse(manager.isAvailable)
        XCTAssertNil(manager.currentIdentity)
        XCTAssertEqual(manager.writeEQSnapshot(snapshot), .unavailable)
    }

    func testAFailedReplacementUnderLoadStopsAllFurtherWrites() throws {
        let valid = try fixture.publish()
        XCTAssertTrue(attach().didAttach)

        let manager = self.manager!
        let snapshot = fixture.snapshot(marker: 4)
        let group = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for _ in 0..<100 { _ = manager.writeEQSnapshot(snapshot) }
            }
        }

        try fixture.publishUninitialisedFile()
        guard case .invalidHeader = attach() else {
            return XCTFail("a half-published inode must be refused")
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        // §2.2 / §4.4: after the failed replacement there is no valid mapping,
        // and the one we held must not keep accepting writes.
        XCTAssertFalse(manager.isAvailable)
        let frozen = valid.eqSnapshot?.preamp
        for _ in 0..<50 {
            XCTAssertEqual(manager.writeEQSnapshot(snapshot), .unavailable)
        }
        XCTAssertEqual(valid.eqSnapshot?.preamp, frozen)
    }

    // MARK: Notifications

    func testConcurrentAttachRequestsForTheSameIncarnationPublishOnce() throws {
        let published = try fixture.publish()

        let manager = self.manager!
        let lock = NSLock()
        var outcomes: [SharedMemoryAttachOutcome] = []

        let group = DispatchGroup()
        for _ in 0..<12 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let outcome = manager.attachSynchronously(uid: "dev-a")
                lock.lock()
                outcomes.append(outcome)
                lock.unlock()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(outcomes.count, 12)
        XCTAssertEqual(outcomes.filter(\.didAttach).count, 1,
                       "twelve notifications for one inode must publish one mapping")
        XCTAssertEqual(outcomes.filter {
            if case .alreadyCurrent = $0 { return true }
            return false
        }.count, 11)
        XCTAssertEqual(manager.currentGeneration, 1)
        XCTAssertEqual(manager.currentIdentity, published.identity)
    }

    func testRepeatedNotificationsAreIdempotent() throws {
        let published = try fixture.publish()
        XCTAssertTrue(attach().didAttach)
        let generation = manager.currentGeneration

        for _ in 0..<100 {
            manager.requestAttach(for: "dev-a")
            manager.revalidate()
        }
        // `attachSynchronously` is the barrier: it cannot run before every
        // queued request has been drained.
        _ = attach()

        XCTAssertEqual(manager.currentGeneration, generation,
                       "repeated notifications must not republish the mapping")
        XCTAssertEqual(manager.currentIdentity, published.identity)
        XCTAssertEqual(manager.writeEQSnapshot(fixture.snapshot(marker: 5)),
                       .written(generation: generation))
    }

    func testRapidPublicationsConvergeToTheNewestUnderConcurrentAttaches() throws {
        _ = try fixture.publish()
        XCTAssertTrue(attach().didAttach)

        var newest: FixtureIncarnation?
        for _ in 0..<8 {
            newest = try fixture.publish()
        }

        let manager = self.manager!
        let group = DispatchGroup()
        for _ in 0..<12 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                _ = manager.attachSynchronously(uid: "dev-a")
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        _ = attach()

        XCTAssertEqual(manager.currentIdentity, newest?.identity,
                       "eight publications followed by twelve attaches must land on the last one")
        XCTAssertEqual(manager.currentGeneration, 2,
                       "only one of the twelve attaches had anything to publish")
    }

    // MARK: Host restart

    func testHostRestartUnderLoadMovesEQAgressivelyToTheNewSession() throws {
        let firstSession = UUID()
        let first = try fixture.publish(epoch: 0xA1, session: firstSession)
        XCTAssertTrue(attach().didAttach)

        let manager = self.manager!
        let snapshot = fixture.snapshot(marker: 6)
        let group = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                for _ in 0..<100 { _ = manager.writeEQSnapshot(snapshot) }
            }
        }

        let secondSession = UUID()
        let second = try fixture.publish(epoch: 0xB2, session: secondSession)
        _ = attach()
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        _ = attach()

        XCTAssertEqual(manager.currentIdentity?.hostSession, secondSession)
        XCTAssertNotEqual(manager.currentIdentity?.epoch, first.identity.epoch)
        XCTAssertEqual(manager.currentIdentity, second.identity)

        XCTAssertTrue(manager.writeEQSnapshot(fixture.snapshot(marker: 77)).isWritten)
        XCTAssertEqual(second.eqSnapshot?.preamp, 77)
        XCTAssertNotEqual(first.eqSnapshot?.preamp, 77,
                          "the previous session's inode must not receive the write")
    }

    // MARK: Lock hygiene

    func testTheWriterPathTakesNoFileSystemOrAttachWork() throws {
        _ = try fixture.publish()
        XCTAssertTrue(attach().didAttach)

        // 2 000 writes with no mapping change: if the writer path opened, stat'ed
        // or mapped anything, this would be orders of magnitude slower and the
        // deadline would catch it. Timing is a coarse gate on purpose — the
        // structural gate is the source scan in the ownership tests.
        let started = Date()
        for _ in 0..<2_000 {
            XCTAssertTrue(manager.writeEQSnapshot(fixture.snapshot(marker: 1)).isWritten)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "the write path must not perform I/O or wait on a lock it cannot get")
    }
}

// MARK: - §7.4 Recovery through the EQ writer

final class EQControllerMappingRecoveryTests: XCTestCase {

    private var fixture: SharedMemoryFixture!
    private var manager: SharedMemoryMappingManager!
    private var controller: EQController!
    private let deviceUID = "recovery-device-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = SharedMemoryFixture(name: "recovery-\(name)")
        manager = SharedMemoryMappingManager(pathForUID: { [path = fixture.path] _ in path })
        clearDefaults()
        controller = EQController(deviceUID: deviceUID, mapping: manager)
        controller.bass = 0
        controller.mids = 0
        controller.treble = 0
        controller.isEnabled = true
    }

    override func tearDown() {
        clearDefaults()
        controller = nil
        manager = nil
        fixture.teardown()
        fixture = nil
        super.tearDown()
    }

    private func clearDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: EQDefaultsKey.state(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.bass(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.mids(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.treble(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.isEnabled(for: deviceUID))
    }

    private func expectedBands(bass: Float, mids: Float, treble: Float) -> [Float] {
        EQController.computeBandGains(bass: bass, mids: mids, treble: treble)
    }

    /// §7.4 items 1 and 4: no mapping must not crash, and the user's values must
    /// survive both in memory and in UserDefaults (the pending state).
    func testEQSurvivesAnUnavailableMappingAndKeepsThePendingValues() throws {
        XCTAssertFalse(controller.isMappingAvailable)

        controller.bass = 6
        controller.mids = -3
        controller.treble = 4.5

        // The direct flush runs with no mapping at all: it must report nothing
        // and change nothing.
        controller.flushToSharedMemory()

        // A later edit is the normal user path. With no mapping the write is
        // skipped, so UserDefaults is the only copy that survives a restart —
        // the throttled pipeline must still get there.
        controller.bass = 3.25
        XCTAssertTrue(waitUntil(2) {
            (UserDefaults.standard.dictionary(forKey: EQDefaultsKey.state(for: self.deviceUID))?["bass"] as? Float) == 3.25
        }, "the throttled pipeline must persist the pending value without a mapping")

        XCTAssertEqual(controller.bass, 3.25)
        XCTAssertEqual(controller.mids, -3)
        XCTAssertEqual(controller.treble, 4.5)
        XCTAssertFalse(controller.isMappingAvailable)
    }

    /// §7.4 item 2 and 3: the first mapping to appear receives the pending state.
    func testPendingEQLandsInTheMappingThatAppearsLater() throws {
        controller.bass = 7.5
        controller.mids = -2
        controller.treble = 1.25

        let published = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: deviceUID).didAttach)

        let expected = expectedBands(bass: 7.5, mids: -2, treble: 1.25)
        XCTAssertTrue(waitUntil {
            bands(of: published.eqSnapshot) == expected
        }, "the pending EQ state must be written once a mapping is published; got \(bands(of: published.eqSnapshot))")
        XCTAssertEqual(published.eqSnapshot?.bypass, false)
    }

    /// §7.4 item 2: a Host restart is a new incarnation, and the EQ follows.
    func testEQIsReappliedAfterTheHostRepublishes() throws {
        let first = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: deviceUID).didAttach)

        controller.bass = 5
        controller.mids = 0
        controller.treble = -4
        controller.flushToSharedMemory()
        let firstExpected = expectedBands(bass: 5, mids: 0, treble: -4)
        XCTAssertTrue(waitUntil { bands(of: first.eqSnapshot) == firstExpected })

        let second = try fixture.publish()
        XCTAssertNotEqual(second.identity.inode, first.identity.inode)
        XCTAssertTrue(manager.attachSynchronously(uid: deviceUID).didAttach)

        XCTAssertTrue(waitUntil {
            bands(of: second.eqSnapshot) == firstExpected
        }, "a new incarnation must receive the current EQ state without user action")

        // The next change must go to the new inode only.
        controller.mids = 3
        controller.flushToSharedMemory()
        let secondExpected = expectedBands(bass: 5, mids: 3, treble: -4)
        XCTAssertTrue(waitUntil { bands(of: second.eqSnapshot) == secondExpected })
        XCTAssertNotEqual(bands(of: first.eqSnapshot), secondExpected)
    }

    /// §7.4 item 4 / §5.3: re-applying EQ must not touch fields the Host owns.
    func testAnEQWriteLeavesHostOwnedFieldsUntouched() throws {
        let published = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: deviceUID).didAttach)

        // The Host seeded the volume block and the admission epoch before it
        // renamed the file into place; the App must leave both alone.
        rf_publish_volume_state(published.pointer, 0.42, true, RF_VOLUME_MODE_SOFTWARE)
        let epochBefore = rf_admission_epoch(published.pointer)
        let sessionBefore = SharedMemoryMappingManager.hostSession(of: published.pointer)

        controller.bass = 8
        controller.mids = 1
        controller.treble = -2
        controller.flushToSharedMemory()

        var volume = RFVolumeStateSnapshot()
        XCTAssertTrue(rf_read_volume_state(published.pointer, &volume))
        XCTAssertEqual(volume.scalar, 0.42, accuracy: 1e-6)
        XCTAssertEqual(volume.muted, 1)
        XCTAssertEqual(volume.mode, RF_VOLUME_MODE_SOFTWARE)
        XCTAssertEqual(rf_admission_epoch(published.pointer), epochBefore)
        XCTAssertEqual(SharedMemoryMappingManager.hostSession(of: published.pointer), sessionBefore)
        XCTAssertEqual(published.pointer.pointee.sample_rate, 48000)
        XCTAssertEqual(bands(of: published.eqSnapshot), expectedBands(bass: 8, mids: 1, treble: -2))
    }

    /// §7.4: the mapping goes away, EQ changes happen with nothing to write to,
    /// and a returning mapping picks them up.
    func testEQRecoversAfterTheMappingDisappearsAndReturns() throws {
        let first = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: deviceUID).didAttach)
        controller.bass = 2
        controller.flushToSharedMemory()
        XCTAssertTrue(waitUntil { bands(of: first.eqSnapshot) == expectedBands(bass: 2, mids: 0, treble: 0) })

        fixture.removePublishedFile()
        manager.revalidate()
        XCTAssertTrue(waitUntil { !self.manager.isAvailable },
                      "a vanished file must retire the active mapping")

        // Changing EQ with no mapping is a normal user action, not an error path.
        controller.bass = -5
        controller.treble = 6
        controller.flushToSharedMemory()
        XCTAssertEqual(controller.bass, -5)
        XCTAssertEqual(controller.treble, 6)

        let second = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: deviceUID).didAttach)

        let expected = expectedBands(bass: -5, mids: 0, treble: 6)
        XCTAssertTrue(waitUntil {
            bands(of: second.eqSnapshot) == expected
        }, "EQ changed during the outage must be applied to the returning mapping")
    }
}

// MARK: - §6.1 / §12 H source gate
//
// "Mapping discovery must not depend on a View's lifecycle" and "no object but
// the manager may own an mmap" are structural claims. They are checked against
// the sources rather than against a type the tests happen to reach, the same way
// `AppDefaultOutputSourceTests` checks that only one switch writes the default.

final class SharedMemoryMappingOwnershipSourceTests: XCTestCase {

    private var appSources: URL {
        URL(fileURLWithPath: #filePath)          // Tests/SoundBridgeAppTests/<file>
            .deletingLastPathComponent()          // Tests/SoundBridgeAppTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // apps/mac/SoundBridgeApp
            .appendingPathComponent("Sources")
    }

    private func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        XCTAssertFalse(files.isEmpty, "no App sources found at \(appSources.path)")
        return files
    }

    /// Drop comment-only lines so prose that names `munmap` or a raw pointer does
    /// not read as a use of it.
    private func code(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
                    && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    private func source(_ fileName: String) throws -> String {
        let url = appSources
            .appendingPathComponent("Services")
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            return code(try String(contentsOf: url, encoding: .utf8))
        }
        let appURL = appSources
            .appendingPathComponent("App")
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: appURL.path) {
            return code(try String(contentsOf: appURL, encoding: .utf8))
        }
        let viewURL = appSources
            .appendingPathComponent("Views")
            .appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: viewURL.path) {
            return code(try String(contentsOf: viewURL, encoding: .utf8))
        }
        XCTFail("\(fileName) not found under \(appSources.path)")
        return ""
    }

    func testOnlyTheMappingManagerMapsSharedMemory() throws {
        let allowed = "SharedMemoryMappingManager.swift"
        var offenders: [String] = []

        for file in try swiftFiles() {
            let text = code(try String(contentsOf: file, encoding: .utf8))
            if text.contains("mmap(") || text.contains("munmap(") {
                if file.lastPathComponent != allowed {
                    offenders.append(file.lastPathComponent)
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "only \(allowed) may map or unmap shared memory; found in \(offenders.joined(separator: ", "))"
        )
    }

    func testEQControllerHoldsNoMappingLifetime() throws {
        let text = try source("EQController.swift")

        XCTAssertFalse(text.contains("mmap("), "EQController must not map shared memory")
        XCTAssertFalse(text.contains("munmap("), "EQController must not unmap shared memory")
        XCTAssertFalse(text.contains("UnsafeMutablePointer<RFSharedAudio>"),
                       "EQController must not cache a mapping pointer")
        XCTAssertFalse(text.contains("shmSize"), "EQController must not track a mapping size")
        XCTAssertTrue(text.contains("mapping?.requestAttach"),
                      "EQController must ask the manager for the mapping")
    }

    func testTheMappingIsOwnedByTheApplicationNotByAView() throws {
        let app = try source("SoundBridgeApp.swift")
        XCTAssertTrue(app.contains("SharedMemoryMappingManager.shared.start()"),
                      "the App must start the mapping owner at launch")
        XCTAssertTrue(app.contains("SharedMemoryMappingManager.shared.stop()"),
                      "the App must release the mapping on terminate")
        XCTAssertTrue(app.contains("deviceUIDProvider"),
                      "the App must tell the manager which device's mapping is wanted")

        for file in try swiftFiles() where file.path.contains("/Views/") {
            let text = code(try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(text.contains("mmap("), "\(file.lastPathComponent) must not map")
            XCTAssertFalse(text.contains("munmap("), "\(file.lastPathComponent) must not unmap")
            XCTAssertFalse(text.contains("UnsafeMutablePointer<RFSharedAudio>"),
                           "\(file.lastPathComponent) must not hold a mapping pointer")
        }
    }

    func testNotificationsReReadTheIdentityInsteadOfBeingTrusted() throws {
        let app = try source("SoundBridgeApp.swift")
        XCTAssertTrue(app.contains("SharedMemoryMappingManager.shared.revalidate()"),
                      "an IPC notification is a hint; the identity must be re-read")
    }
}
