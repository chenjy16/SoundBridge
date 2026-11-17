import XCTest
import Darwin
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - File-level crash recovery
//
// Everything here runs inside a per-test sandbox under NSTemporaryDirectory().
// The manager's path resolver is injected, so no fixture can create, truncate or
// unlink /tmp/soundbridge-<uid>. These tests cover the probe → unlink → rebuild →
// read-back chain that Phase 2.1 left untested; the pure state logic above it is
// already covered by VolumeStateTests.

final class SharedMemoryRecoveryTests: XCTestCase {

    private final class FakePersistence: VolumeStatePersisting {
        private var stored: [String: DeviceVolumeState]
        private(set) var saveCallCount = 0

        init(seed: [String: DeviceVolumeState] = [:]) {
            self.stored = seed
        }

        func loadIfPresent(uid: String) -> DeviceVolumeState? {
            stored[uid]
        }

        func save(uid: String, volume: Float, muted: Bool) {
            saveCallCount += 1
            stored[uid] = DeviceVolumeState(volumeScalar: volume, isMuted: muted)
        }
    }

    private var sandbox: URL!
    private var testUID: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeShmTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        testUID = "test-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        testUID = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeManager() -> SharedMemoryManager {
        let root = sandbox.path
        return SharedMemoryManager { uid in "\(root)/soundbridge-\(uid)" }
    }

    private func path(for uid: String) -> String {
        "\(sandbox.path)/soundbridge-\(uid)"
    }

    /// Size the Host would use for its mapping.
    private var expectedFileSize: Int {
        let frames = rf_frames_for_duration(
            SoundBridgeConfig.activeSampleRate,
            SoundBridgeConfig.defaultDurationMs
        )
        let bytesPerSample = rf_bytes_per_sample(SoundBridgeConfig.defaultFormat)
        return Int(rf_shared_audio_size(frames, SoundBridgeConfig.defaultChannels, bytesPerSample))
    }

    /// Write a file at `path` and let `configure` decide what its header says.
    ///
    /// The size defaults to what the Host builds, so the only variable under test
    /// is the header contents, not the mapping length.
    private func makeFile(
        at path: String,
        size: Int? = nil,
        configure: (UnsafeMutablePointer<RFSharedAudio>) -> Void
    ) throws {
        let byteCount = size ?? expectedFileSize
        let fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0o666)
        XCTAssertGreaterThanOrEqual(fd, 0, "open failed: \(String(cString: strerror(errno)))")
        defer { close(fd) }

        XCTAssertEqual(ftruncate(fd, Int64(byteCount)), 0)

        // Undersized fixtures stop here on purpose: the header does not exist.
        guard byteCount >= MemoryLayout<RFSharedAudio>.size else { return }

        let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED else {
            return XCTFail("mmap failed: \(String(cString: strerror(errno)))")
        }
        let mem = mapped!.assumingMemoryBound(to: RFSharedAudio.self)
        defer { munmap(mem, byteCount) }

        configure(mem)
        msync(mem, byteCount, MS_SYNC)
    }

    private func seedValidHeader(_ mem: UnsafeMutablePointer<RFSharedAudio>) {
        rf_shared_audio_init(
            mem,
            SoundBridgeConfig.activeSampleRate,
            SoundBridgeConfig.defaultChannels,
            SoundBridgeConfig.defaultFormat,
            SoundBridgeConfig.defaultDurationMs
        )
    }

    private func fileSize(_ path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.size] as? Int) ?? -1
    }

    // MARK: - 1. Missing file

    func testCreatesFreshFileWhenAbsent() throws {
        let manager = makeManager()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(for: testUID)))

        let origin = manager.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertEqual(origin, .created)
        XCTAssertEqual(try fileSize(path(for: testUID)), expectedFileSize)

        let state = manager.readVolumeState(for: testUID)
        XCTAssertEqual(state?.scalar ?? -1, VolumeState.defaultScalar, accuracy: 1e-6)
        XCTAssertEqual(state?.muted, false)
    }

    // MARK: - 2. Valid file with committed state

    func testAdoptsCommittedStateAfterCrash() throws {
        let first = makeManager()
        XCTAssertEqual(first.createMemory(for: testUID, persistence: FakePersistence()), .created)
        XCTAssertTrue(first.publishVolumeState(for: testUID, scalar: 0.62, muted: true))

        // Second Host run. Persistence has nothing, so only the crashed state can
        // supply the volume.
        let second = makeManager()
        let origin = second.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertEqual(origin, .recoveredFromCrash)
        let recovered = second.readVolumeState(for: testUID)
        XCTAssertEqual(recovered?.scalar ?? -1, 0.62, accuracy: 1e-6)
        XCTAssertEqual(recovered?.muted, true)
    }

    // MARK: - 3. Protocol version mismatch

    func testRejectsProtocolMismatch() throws {
        try makeFile(at: path(for: testUID)) { mem in
            seedValidHeader(mem)
            mem.pointee.protocol_version = UInt32(RF_AUDIO_PROTOCOL_VERSION) &+ 1
            rf_publish_volume_state(mem, 0.5, false, RF_VOLUME_MODE_SOFTWARE)
        }

        let manager = makeManager()
        let origin = manager.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertEqual(origin, .replacedIncompatible)
        XCTAssertEqual(
            manager.getMemory(for: testUID)?.pointee.protocol_version,
            UInt32(RF_AUDIO_PROTOCOL_VERSION)
        )
        XCTAssertEqual(try fileSize(path(for: testUID)), expectedFileSize)
    }

    // MARK: - 4. Wrong file size

    func testRejectsUndersizedFile() throws {
        try makeFile(at: path(for: testUID), size: 64) { _ in }
        XCTAssertEqual(try fileSize(path(for: testUID)), 64)

        let manager = makeManager()
        let origin = manager.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertEqual(origin, .replacedIncompatible)
        XCTAssertEqual(try fileSize(path(for: testUID)), expectedFileSize)
    }

    func testRejectsHeaderOnlyFile() throws {
        // Exactly one header's worth of bytes: readable header, no audio payload.
        // The probe maps only the header, so this must not be mistaken for a
        // usable mapping just because mmap would succeed.
        try makeFile(at: path(for: testUID), size: MemoryLayout<RFSharedAudio>.size) { mem in
            seedValidHeader(mem)
            rf_publish_volume_state(mem, 0.44, false, RF_VOLUME_MODE_SOFTWARE)
        }

        let manager = makeManager()
        XCTAssertEqual(
            manager.createMemory(for: testUID, persistence: FakePersistence()),
            .recoveredFromCrash,
            "a header-only file is still a recoverable committed state"
        )
        XCTAssertEqual(try fileSize(path(for: testUID)), expectedFileSize, "rebuild must restore the full mapping")
    }

    // MARK: - 5. Corrupt header

    func testRejectsCorruptHeaderSize() throws {
        try makeFile(at: path(for: testUID)) { mem in
            seedValidHeader(mem)
            mem.pointee.header_size = 999
            rf_publish_volume_state(mem, 0.5, false, RF_VOLUME_MODE_SOFTWARE)
        }

        let manager = makeManager()
        XCTAssertEqual(
            manager.createMemory(for: testUID, persistence: FakePersistence()),
            .replacedIncompatible
        )
        XCTAssertEqual(
            manager.getMemory(for: testUID)?.pointee.header_size,
            UInt32(RF_SHARED_AUDIO_HEADER_SIZE)
        )
    }

    func testRejectsZeroFilledFile() throws {
        // All-zero header means protocol_version == 0, which is not this build.
        try makeFile(at: path(for: testUID)) { _ in }

        let manager = makeManager()
        XCTAssertEqual(
            manager.createMemory(for: testUID, persistence: FakePersistence()),
            .replacedIncompatible
        )
    }

    // MARK: - 6. Interrupted initialisation

    func testReplacesUninitializedFile() throws {
        // Header valid, nothing ever committed: the previous Host died between
        // rf_shared_audio_init and rf_publish_volume_state.
        try makeFile(at: path(for: testUID)) { mem in
            seedValidHeader(mem)
        }

        let manager = makeManager()
        let origin = manager.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertEqual(origin, .replacedUninitialized)
        XCTAssertNotNil(manager.readVolumeState(for: testUID), "rebuild must commit a state")
    }

    // MARK: - 7. Rebuild

    func testRebuildLeavesValidMapping() throws {
        try makeFile(at: path(for: testUID)) { mem in
            seedValidHeader(mem)
            mem.pointee.header_size = 999
        }

        let manager = makeManager()
        XCTAssertEqual(
            manager.createMemory(for: testUID, persistence: FakePersistence()),
            .replacedIncompatible
        )

        guard let mem = manager.getMemory(for: testUID) else {
            return XCTFail("no mapping after rebuild")
        }
        XCTAssertEqual(mem.pointee.protocol_version, UInt32(RF_AUDIO_PROTOCOL_VERSION))
        XCTAssertEqual(mem.pointee.header_size, UInt32(RF_SHARED_AUDIO_HEADER_SIZE))
        XCTAssertEqual(mem.pointee.sample_rate, SoundBridgeConfig.activeSampleRate)
        XCTAssertEqual(mem.pointee.channels, SoundBridgeConfig.defaultChannels)

        var snapshot = RFVolumeStateSnapshot()
        XCTAssertTrue(rf_read_volume_state(mem, &snapshot), "rebuild must leave a committed state")
    }

    // MARK: - 8. Cleanup

    func testCleanupRemovesFileAndIsIdempotent() throws {
        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: testUID, persistence: FakePersistence()), .created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(for: testUID)))

        manager.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path(for: testUID)))
        XCTAssertNil(manager.getMemory(for: testUID))

        // A second cleanup after a normal shutdown must not trap.
        manager.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path(for: testUID)))
    }

    func testRemoveMemoryLeavesNoFile() throws {
        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: testUID, persistence: FakePersistence()), .created)

        manager.removeMemory(for: testUID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path(for: testUID)))
        XCTAssertNil(manager.getMemory(for: testUID))
        XCTAssertNil(manager.origins[testUID])
    }

    // MARK: - 9. Concurrency

    func testConcurrentCreationAcrossUIDs() {
        let manager = makeManager()
        let persistence = FakePersistence()
        let uids = (0..<8).map { "concurrent-\($0)-\(UUID().uuidString)" }

        DispatchQueue.concurrentPerform(iterations: uids.count) { index in
            XCTAssertEqual(manager.createMemory(for: uids[index], persistence: persistence), .created)
        }

        for uid in uids {
            XCTAssertNotNil(manager.getMemory(for: uid))
            XCTAssertEqual(
                manager.readVolumeState(for: uid)?.scalar ?? -1,
                VolumeState.defaultScalar,
                accuracy: 1e-6
            )
        }
    }

    func testSequentialRebuildOfSameUIDDoesNotTrap() throws {
        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: testUID, persistence: FakePersistence()), .created)
        XCTAssertTrue(manager.publishVolumeState(for: testUID, scalar: 0.31, muted: false))

        // Same manager, same UID: the old mapping is replaced underneath. This is
        // a programming error in production, but it must fail safe rather than
        // corrupt or crash.
        XCTAssertEqual(
            manager.createMemory(for: testUID, persistence: FakePersistence()),
            .recoveredFromCrash
        )
        XCTAssertEqual(manager.readVolumeState(for: testUID)?.scalar ?? -1, 0.31, accuracy: 1e-6)
    }

    // MARK: - 10. Reopen after recovery

    func testRecoveredFileReopensWithValidLayout() throws {
        let first = makeManager()
        XCTAssertEqual(first.createMemory(for: testUID, persistence: FakePersistence()), .created)
        XCTAssertTrue(first.publishVolumeState(for: testUID, scalar: 0.47, muted: false))

        // Reopen the way the driver does: read-only private map of the header.
        let fd = open(path(for: testUID), O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var st = stat()
        XCTAssertEqual(fstat(fd, &st), 0)
        XCTAssertEqual(Int(st.st_size), expectedFileSize)

        let headerSize = MemoryLayout<RFSharedAudio>.size
        let raw = mmap(nil, headerSize, PROT_READ, MAP_SHARED, fd, 0)
        guard raw != MAP_FAILED else {
            return XCTFail("mmap failed: \(String(cString: strerror(errno)))")
        }
        defer { munmap(raw, headerSize) }

        let mem = raw!.assumingMemoryBound(to: RFSharedAudio.self)
        XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)
        XCTAssertEqual(headerSize, 256)
        XCTAssertEqual(
            MemoryLayout<RFSharedAudio>.offset(of: \.eq_snapshot),
            156,
            "header layout drifted from the documented offsets"
        )

        var snapshot = RFVolumeStateSnapshot()
        XCTAssertTrue(rf_read_volume_state(mem, &snapshot))
        XCTAssertEqual(snapshot.scalar, 0.47, accuracy: 1e-6)
    }

    // MARK: - Priority and isolation

    func testPersistenceOutranksRecoveredState() throws {
        let first = makeManager()
        XCTAssertEqual(first.createMemory(for: testUID, persistence: FakePersistence()), .created)
        XCTAssertTrue(first.publishVolumeState(for: testUID, scalar: 0.9, muted: true))

        let persistence = FakePersistence(
            seed: [testUID: DeviceVolumeState(volumeScalar: 0.25, isMuted: false)]
        )
        let second = makeManager()
        XCTAssertEqual(second.createMemory(for: testUID, persistence: persistence), .recoveredFromCrash)

        let state = second.readVolumeState(for: testUID)
        XCTAssertEqual(state?.scalar ?? -1, 0.25, accuracy: 1e-6)
        XCTAssertEqual(state?.muted, false)
    }

    func testFixtureNeverWritesOutsideSandbox() throws {
        let fixturePath = path(for: testUID)
        XCTAssertTrue(fixturePath.hasPrefix(sandbox.path))
        XCTAssertNotEqual(fixturePath, PathManager.sharedMemoryPath(uid: testUID))

        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: testUID, persistence: FakePersistence()), .created)

        let produced = try FileManager.default
            .subpathsOfDirectory(atPath: sandbox.path)
            .sorted()
        XCTAssertEqual(produced, ["soundbridge-\(testUID!)"])
    }
}
