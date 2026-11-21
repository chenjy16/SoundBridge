import XCTest
import Darwin
import CSoundBridgeAudio
@testable import SoundBridgeApp

// MARK: - Fixture
//
// P2 Batch 3's evidence has to be about *real* mappings: a fake manager that
// returns hand-written identities would prove nothing about `rename` publishing,
// inode changes or `munmap`. The fixture therefore builds the same file the Host
// builds — staging inode, `rf_shared_audio_init`, Host session, admission epoch,
// then `rename` onto the published path — in a throwaway directory.
//
// It keeps its own `mmap` of every incarnation it publishes, so a test can read
// what a *retired* mapping still contains after the path has moved on. That is
// how "the old mapping stopped receiving writes" is checked against mapped
// memory rather than against a counter the implementation itself reports.

/// One published incarnation, still mapped by the test.
struct FixtureIncarnation {
    let pointer: UnsafeMutablePointer<RFSharedAudio>
    let size: Int
    let identity: SharedMemoryIdentity
    let session: UUID
    let epoch: UInt64

    /// Read the EQ block through the C SeqLock reader, exactly like the Host.
    var eqSnapshot: RFEQSnapshot? {
        var snapshot = RFEQSnapshot()
        guard rf_load_eq_snapshot_safe(pointer, &snapshot) else { return nil }
        return snapshot
    }

    var bandGains: [Float] {
        guard let snapshot = eqSnapshot else { return [] }
        var copy = snapshot
        return withUnsafeBytes(of: &copy.bands) { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}

final class SharedMemoryFixture {
    let directory: URL
    let path: String
    private var live: [FixtureIncarnation] = []

    init(name: String = UUID().uuidString) {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("soundbridge-mapping-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("device-mapping").path
    }

    deinit {
        teardown()
    }

    func teardown() {
        for incarnation in live {
            munmap(incarnation.pointer, incarnation.size)
        }
        live = []
        try? FileManager.default.removeItem(at: directory)
    }

    /// Publish a new incarnation onto `path`, replacing whatever was there.
    ///
    /// Every knob exists to reproduce one failure the manager must reject:
    /// `initialise: false` (an uninitialised file), `markSession: false` (no
    /// Phase 6A session marker), `admit: false` (epoch stays 0).
    @discardableResult
    func publish(
        epoch: UInt64 = UInt64.random(in: 1...UInt64.max),
        session: UUID = UUID(),
        initialise: Bool = true,
        markSession: Bool = true,
        admit: Bool = true,
        durationMs: UInt32 = 100
    ) throws -> FixtureIncarnation {
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)")
        let fd = open(staging.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR, 0o666)
        guard fd >= 0 else {
            throw NSError(domain: "fixture", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "open staging failed: \(String(cString: strerror(errno)))"
            ])
        }

        let frames = rf_ring_capacity_frames_for(48000, durationMs)
        let size = Int(rf_shared_audio_size(frames, 2, rf_bytes_per_sample(RF_FORMAT_FLOAT32)))
        guard ftruncate(fd, off_t(size)) == 0 else {
            close(fd)
            throw NSError(domain: "fixture", code: Int(errno), userInfo: nil)
        }

        let raw = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard raw != MAP_FAILED, let raw else {
            close(fd)
            throw NSError(domain: "fixture", code: Int(errno), userInfo: nil)
        }
        let memory = raw.assumingMemoryBound(to: RFSharedAudio.self)

        if initialise {
            rf_shared_audio_init(memory, 48000, 2, RF_FORMAT_FLOAT32, durationMs)
        }
        if markSession {
            var uuid = session.uuid
            withUnsafeBytes(of: &uuid) { bytes in
                rf_set_host_session(memory, bytes.bindMemory(to: UInt8.self).baseAddress!)
            }
        }
        if admit {
            _ = rf_admission_open(memory, epoch)
        }

        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0, rename(staging.path, path) == 0 else {
            munmap(memory, size)
            close(fd)
            throw NSError(domain: "fixture", code: Int(errno), userInfo: nil)
        }
        close(fd)

        let identity = SharedMemoryIdentity(
            device: fileInfo.st_dev,
            inode: fileInfo.st_ino,
            epoch: epoch,
            hostSession: markSession ? session : nil
        )
        let incarnation = FixtureIncarnation(
            pointer: memory,
            size: size,
            identity: identity,
            session: session,
            epoch: epoch
        )
        live.append(incarnation)
        return incarnation
    }

    /// Replace `path` with a zero-filled file of a valid length — what a Host
    /// that died between `ftruncate` and `rf_shared_audio_init` would leave.
    func publishUninitialisedFile() throws {
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)")
        let size = Int(rf_shared_audio_size(rf_ring_capacity_frames_for(48000, 100), 2, 4))
        let fd = open(staging.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR, 0o666)
        guard fd >= 0 else { throw NSError(domain: "fixture", code: Int(errno), userInfo: nil) }
        guard ftruncate(fd, off_t(size)) == 0, rename(staging.path, path) == 0 else {
            close(fd)
            throw NSError(domain: "fixture", code: Int(errno), userInfo: nil)
        }
        close(fd)
    }

    func removePublishedFile() {
        unlink(path)
    }

    /// A snapshot whose `preamp` encodes the value under test, so a reader can
    /// tell *which* write landed in *which* incarnation.
    func snapshot(marker: Float, bypass: Bool = false) -> RFEQSnapshot {
        var snapshot = RFEQSnapshot()
        var gains = [Float](repeating: marker, count: 10)
        withUnsafeMutablePointer(to: &snapshot.bands) { pointer in
            pointer.withMemoryRebound(to: Float.self, capacity: 10) { floats in
                for index in 0..<10 { floats[index] = gains[index] }
            }
        }
        gains = []
        snapshot.preamp = marker
        snapshot.bypass = bypass
        return snapshot
    }
}

// MARK: - Attach pipeline

final class SharedMemoryMappingManagerTests: XCTestCase {

    private var fixture: SharedMemoryFixture!
    private var manager: SharedMemoryMappingManager!

    override func setUp() {
        super.setUp()
        fixture = SharedMemoryFixture(name: name)
        // The closure is the only path seam: no test may ever open a real
        // shared-memory file under /tmp.
        manager = SharedMemoryMappingManager(pathForUID: { [path = fixture.path] _ in path })
    }

    override func tearDown() {
        manager = nil
        fixture.teardown()
        fixture = nil
        super.tearDown()
    }

    // MARK: §7.1 basic

    func testFirstAttachSucceedsAndPublishesTheFileIdentity() throws {
        let published = try fixture.publish()

        let outcome = manager.attachSynchronously(uid: "dev-a")

        guard case .attached(let identity, let generation) = outcome else {
            return XCTFail("expected an attach, got \(outcome)")
        }
        XCTAssertEqual(identity, published.identity)
        XCTAssertEqual(generation, 1, "the first publication is generation 1")
        XCTAssertEqual(manager.currentIdentity, published.identity)
        XCTAssertTrue(manager.isAvailable)
    }

    func testMissingFileIsReportedAndLeavesTheWriterUnavailable() {
        let outcome = manager.attachSynchronously(uid: "dev-a")

        XCTAssertEqual(outcome, .fileMissing)
        XCTAssertNil(manager.currentIdentity)
        XCTAssertFalse(manager.isAvailable)
        XCTAssertEqual(manager.writeEQSnapshot(fixture.snapshot(marker: 1)), .unavailable)
    }

    func testOpenFailureIsReported() throws {
        // A directory cannot be opened read-write: deterministic EISDIR without
        // touching permissions or the real filesystem layout.
        let directoryPath = fixture.directory.path
        let outcome = SharedMemoryMappingManager(pathForUID: { _ in directoryPath })
            .attachSynchronously(uid: "dev-a")

        guard case .openFailed(let code) = outcome else {
            return XCTFail("expected openFailed, got \(outcome)")
        }
        XCTAssertEqual(code, EISDIR)
    }

    func testAFileSmallerThanTheHeaderIsRefused() throws {
        let fd = open(fixture.path, O_CREAT | O_RDWR, 0o666)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 16), 0)
        close(fd)

        let outcome = manager.attachSynchronously(uid: "dev-a")

        XCTAssertEqual(outcome, .fileTooSmall(16))
        XCTAssertFalse(manager.isAvailable)
    }

    func testAnUninitialisedFileIsRefused() throws {
        // Right length, zeroed header: `rf_validate_header` must reject it rather
        // than let the App write EQ into a mapping the Host never finished.
        try fixture.publishUninitialisedFile()

        let outcome = manager.attachSynchronously(uid: "dev-a")

        guard case .invalidHeader(let reason) = outcome else {
            return XCTFail("expected invalidHeader, got \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(manager.currentIdentity)
    }

    func testAMappingWithoutAHostSessionIsNotAnIncarnation() throws {
        try fixture.publish(markSession: false)

        let outcome = manager.attachSynchronously(uid: "dev-a")

        guard case .notAnIncarnation(let reason) = outcome else {
            return XCTFail("expected notAnIncarnation, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("session"), "got: \(reason)")
    }

    func testAMappingWithoutAnAdmissionEpochIsNotAnIncarnation() throws {
        // The Host writes the epoch immediately before publishing; zero means the
        // file was never published by this Host.
        try fixture.publish(admit: false)

        let outcome = manager.attachSynchronously(uid: "dev-a")

        guard case .notAnIncarnation(let reason) = outcome else {
            return XCTFail("expected notAnIncarnation, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("epoch"), "got: \(reason)")
    }

    // MARK: §7.1 replacement

    func testSamePathWithANewInodeIsRecognisedAsANewIncarnation() throws {
        let first = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)

        let second = try fixture.publish()

        XCTAssertNotEqual(first.identity.inode, second.identity.inode,
                          "the fixture must actually replace the inode")
        guard case .attached(let identity, let generation) = manager.attachSynchronously(uid: "dev-a") else {
            return XCTFail("expected the replacement to attach")
        }
        XCTAssertEqual(identity, second.identity)
        XCTAssertEqual(generation, 2)
    }

    func testTheSameIncarnationIsAdoptedWithoutChurn() throws {
        let published = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)
        let generationAfterFirst = manager.currentGeneration

        for _ in 0..<20 {
            let outcome = manager.attachSynchronously(uid: "dev-a")
            XCTAssertEqual(outcome, .alreadyCurrent(published.identity))
        }

        XCTAssertEqual(manager.currentGeneration, generationAfterFirst,
                       "repeated notifications must not republish the mapping")
    }

    func testRapidSuccessivePublicationsConvergeOnTheNewest() throws {
        _ = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)

        var newest: FixtureIncarnation?
        for _ in 0..<3 {
            newest = try fixture.publish()
        }

        guard case .attached(let identity, _) = manager.attachSynchronously(uid: "dev-a") else {
            return XCTFail("expected an attach")
        }
        XCTAssertEqual(identity, newest?.identity)
        XCTAssertEqual(manager.currentIdentity, newest?.identity)
    }

    func testAFailedReplacementLeavesTheWriterUnavailableRatherThanStale() throws {
        _ = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)

        // The Host died mid-publish: a new inode exists but is not valid.
        try fixture.publishUninitialisedFile()
        let outcome = manager.attachSynchronously(uid: "dev-a")

        guard case .invalidHeader = outcome else {
            return XCTFail("expected invalidHeader, got \(outcome)")
        }
        // §4.4: a new mapping that cannot be validated must not leave the old one
        // marked valid. The old inode is not what the path points at any more.
        XCTAssertNil(manager.currentIdentity, "the retired incarnation must not stay current")
        XCTAssertFalse(manager.isAvailable)
        XCTAssertEqual(manager.writeEQSnapshot(fixture.snapshot(marker: 9)), .unavailable)
    }

    func testTheWriterRecoversOnceAValidMappingIsPublished() throws {
        _ = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)
        try fixture.publishUninitialisedFile()
        _ = manager.attachSynchronously(uid: "dev-a")
        XCTAssertFalse(manager.isAvailable)

        let recovered = try fixture.publish()
        let outcome = manager.attachSynchronously(uid: "dev-a")

        guard case .attached(let identity, _) = outcome else {
            return XCTFail("expected recovery, got \(outcome)")
        }
        XCTAssertEqual(identity, recovered.identity)
        XCTAssertTrue(manager.isAvailable)
    }

    func testDisappearingFileRetiresTheActiveMapping() throws {
        _ = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)

        fixture.removePublishedFile()
        manager.revalidate()

        let deadline = Date().addingTimeInterval(2.0)
        while manager.isAvailable && Date() < deadline {
            usleep(5_000)
        }
        XCTAssertFalse(manager.isAvailable)
        XCTAssertNil(manager.currentIdentity)
    }

    func testRevalidateAttachesAMappingThatAppearedAfterTheAppStarted() throws {
        // §7.1 item 11/12: the App is running before the Host published anything.
        XCTAssertEqual(manager.attachSynchronously(uid: "dev-a"), .fileMissing)
        XCTAssertFalse(manager.isAvailable)

        let published = try fixture.publish()
        manager.revalidate()

        let deadline = Date().addingTimeInterval(2.0)
        while !manager.isAvailable && Date() < deadline {
            usleep(5_000)
        }
        XCTAssertEqual(manager.currentIdentity, published.identity)
    }

    func testRestartedHostWithANewSessionAndEpochIsANewIncarnation() throws {
        let firstSession = UUID()
        let first = try fixture.publish(epoch: 0x1111, session: firstSession)
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)

        let secondSession = UUID()
        let second = try fixture.publish(epoch: 0x2222, session: secondSession)

        guard case .attached(let identity, _) = manager.attachSynchronously(uid: "dev-a") else {
            return XCTFail("expected the restarted Host's mapping to attach")
        }
        XCTAssertNotEqual(identity.epoch, first.identity.epoch)
        XCTAssertNotEqual(identity.hostSession, first.identity.hostSession)
        XCTAssertEqual(identity.hostSession, secondSession)
        XCTAssertNotEqual(first.session, second.session)
        XCTAssertEqual(manager.currentIdentity, second.identity)
    }

    // MARK: §7.2 retired mappings

    func testRetiredMappingStopsReceivingWrites() throws {
        let first = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)

        XCTAssertEqual(manager.writeEQSnapshot(fixture.snapshot(marker: 11, bypass: false)), .written(generation: 1))
        XCTAssertEqual(first.eqSnapshot?.preamp, 11)

        let second = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)

        XCTAssertEqual(manager.writeEQSnapshot(fixture.snapshot(marker: 22, bypass: true)), .written(generation: 2))

        // The old inode is still mapped by the fixture, so this reads real memory
        // rather than trusting the manager's own bookkeeping.
        XCTAssertEqual(first.eqSnapshot?.preamp, 11,
                       "the retired incarnation must not receive the new write")
        XCTAssertEqual(first.eqSnapshot?.bypass, false)
        XCTAssertEqual(second.eqSnapshot?.preamp, 22)
        XCTAssertEqual(second.eqSnapshot?.bypass, true)
    }

    func testAnInFlightWriteKeepsTheOldMappingAliveUntilItFinishes() throws {
        _ = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)

        let replacementDone = DispatchSemaphore(value: 0)
        let writeReturned = DispatchSemaphore(value: 0)
        var observedBefore: Float?
        var observedAfter: Float?

        let writer = Thread {
            self.manager.write { memory in
                observedBefore = memory.pointee.eq_snapshot.preamp
                writeReturned.signal()
                // Wait until the other thread has published and retired this
                // mapping, then touch the memory again. A `munmap` that ignored
                // the lease would fault here instead of returning.
                _ = replacementDone.wait(timeout: .now() + 5)
                observedAfter = memory.pointee.eq_snapshot.preamp
            }
        }
        writer.start()
        XCTAssertEqual(writeReturned.wait(timeout: .now() + 5), .success)

        let second = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach,
                      "the replacement must be able to publish while a write is in flight")
        XCTAssertEqual(manager.currentIdentity, second.identity)

        replacementDone.signal()
        let deadline = Date().addingTimeInterval(5)
        while !writer.isFinished && Date() < deadline {
            usleep(5_000)
        }
        XCTAssertTrue(writer.isFinished, "the writer must not be blocked forever")
        XCTAssertEqual(observedBefore, observedAfter,
                       "a leased mapping stays readable for the whole body")
    }

    func testTheNewMappingIsTheOnlyOneWrittenAfterRetirement() throws {
        let first = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)
        let second = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(uid: "dev-a").didAttach)

        for marker in 1...10 {
            XCTAssertTrue(manager.writeEQSnapshot(fixture.snapshot(marker: Float(marker))).isWritten)
        }

        XCTAssertEqual(second.eqSnapshot?.preamp, 10)
        XCTAssertEqual(first.eqSnapshot?.preamp, 0,
                       "the retired incarnation saw none of the ten writes")
    }
}

// MARK: - Small helpers

extension SharedMemoryWriteResult {
    var isWritten: Bool {
        if case .written = self { return true }
        return false
    }
}
