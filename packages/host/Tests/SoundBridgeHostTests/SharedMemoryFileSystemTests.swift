import XCTest
import Darwin
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - Filesystem failures around shared-memory creation
//
// The recovery tests cover what a *file* can be. These cover what the *path* can
// be: a read-only directory, a directory, a symlink, garbage, and something far
// too large. Every case must end in one of two ways — a clean refusal
// (`createMemory` returns nil, nothing is deleted) or a replace (the path is a
// fresh, valid mapping). What must never happen is a crash, a followed symlink,
// or a deleted file the process did not create.
//
// All fixtures live under a per-test sandbox. `/tmp/soundbridge-<uid>` is never
// opened: the manager's path resolver is injected.

final class SharedMemoryFileSystemTests: XCTestCase {

    private final class FakePersistence: VolumeStatePersisting {
        private var stored: [String: DeviceVolumeState]

        init(seed: [String: DeviceVolumeState] = [:]) {
            self.stored = seed
        }

        func loadIfPresent(uid: String) -> DeviceVolumeState? {
            stored[uid]
        }

        func save(uid: String, volume: Float, muted: Bool) {
            stored[uid] = DeviceVolumeState(volumeScalar: volume, isMuted: muted)
        }
    }

    private var sandbox: URL!
    private var testUID: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeShmFSTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        testUID = "test-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        // A test may have left a directory at mode 0500; restore before cleanup.
        let root = sandbox.path
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: root) {
            for entry in entries {
                chmod("\(root)/\(entry)", 0o700)
            }
        }
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        testUID = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeManager(root: String? = nil) -> SharedMemoryManager {
        let base = root ?? sandbox.path
        return SharedMemoryManager { uid in "\(base)/soundbridge-\(uid)" }
    }

    private func path(for uid: String) -> String {
        "\(sandbox.path)/soundbridge-\(uid)"
    }

    private var expectedFileSize: Int {
        let frames = rf_frames_for_duration(
            SoundBridgeConfig.activeSampleRate,
            SoundBridgeConfig.defaultDurationMs
        )
        let bytesPerSample = rf_bytes_per_sample(SoundBridgeConfig.defaultFormat)
        return Int(rf_shared_audio_size(frames, SoundBridgeConfig.defaultChannels, bytesPerSample))
    }

    private func seedValidCommittedState(
        _ mem: UnsafeMutablePointer<RFSharedAudio>,
        volume: Float = 0.42
    ) {
        rf_shared_audio_init(
            mem,
            SoundBridgeConfig.activeSampleRate,
            SoundBridgeConfig.defaultChannels,
            SoundBridgeConfig.defaultFormat,
            SoundBridgeConfig.defaultDurationMs
        )
        rf_publish_volume_state(mem, volume, false, 0)
    }

    private func fileSize(_ path: String) -> Int {
        var st = stat()
        guard lstat(path, &st) == 0 else { return -1 }
        return Int(st.st_size)
    }

    private func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    private func isSymlink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - 1. Read-only directory

    /// The directory the file would be created in is unwritable. Creation must
    /// fail without touching anything — a half-processed `unlink` + failed `open`
    /// is how a working file gets destroyed by a process that cannot replace it.
    func testReadOnlyDirectoryRefusesCreation() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores directory permissions; this case cannot be exercised as root")

        let readOnlyDir = sandbox.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(readOnlyDir.path, 0o500), 0, "could not make the directory read-only")
        defer { chmod(readOnlyDir.path, 0o700) }

        let manager = makeManager(root: readOnlyDir.path)
        let origin = manager.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertNil(origin, "creation in a read-only directory must fail, not pretend to succeed")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "\(readOnlyDir.path)/soundbridge-\(testUID!)"),
            "a refused creation must not leave a file behind"
        )
        XCTAssertTrue(
            manager.getMemory(for: testUID) == nil,
            "a failed creation must not publish a mapping"
        )
    }

    // MARK: - 2. A directory where the file should be

    /// Something that is not a file occupies the path. `unlink` cannot remove a
    /// directory, and `O_EXCL` then refuses the create — the process must report
    /// failure and leave the directory alone rather than doing something clever.
    func testDirectoryAtPathIsRefusedWithoutDeletingIt() throws {
        let target = path(for: testUID)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try "keep me".write(toFile: "\(target)/sentinel", atomically: true, encoding: .utf8)

        let manager = makeManager()
        let origin = manager.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertNil(origin, "a directory at the mapping path must be a hard failure")
        var st = stat()
        XCTAssertEqual(lstat(target, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFDIR, "the directory must survive the attempt")
        XCTAssertEqual(
            try String(contentsOfFile: "\(target)/sentinel", encoding: .utf8),
            "keep me",
            "nothing inside the directory may be touched"
        )
    }

    // MARK: - 3. Symlink at the path

    /// A symlink planted at the mapping path must never be followed: following it
    /// would hand a different process a writable view of whatever it points at.
    /// The link itself is classified as unusable and replaced by a real file, and
    /// its target is left byte-for-byte intact.
    func testSymlinkIsReplacedWithoutFollowingIt() throws {
        let targetPath = "\(sandbox.path)/planted-target"
        let linkPath = path(for: testUID)

        // A perfectly valid mapping at the target: if the link were followed, the
        // manager would happily adopt it.
        let fd = open(targetPath, O_CREAT | O_RDWR | O_TRUNC, 0o666)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, Int64(expectedFileSize)), 0)
        let mapped = mmap(nil, expectedFileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        XCTAssertNotEqual(mapped, MAP_FAILED)
        let targetMem = mapped!.assumingMemoryBound(to: RFSharedAudio.self)
        seedValidCommittedState(targetMem, volume: 0.93)
        msync(targetMem, expectedFileSize, MS_SYNC)
        munmap(targetMem, expectedFileSize)
        close(fd)

        XCTAssertEqual(symlink(targetPath, linkPath), 0, "could not plant the symlink")
        XCTAssertTrue(isSymlink(linkPath), "precondition: the path is a symlink")

        let manager = makeManager()
        let origin = manager.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertEqual(origin, .replacedIncompatible, "a symlink must be treated as an unusable mapping")
        XCTAssertTrue(isRegularFile(linkPath), "the symlink must be replaced by a real file")
        XCTAssertFalse(isSymlink(linkPath))
        XCTAssertEqual(fileSize(linkPath), expectedFileSize)

        // The target is a different file and must be untouched — neither deleted,
        // nor resized, nor overwritten with our seed volume.
        XCTAssertEqual(fileSize(targetPath), expectedFileSize, "the symlink target must not be resized")
        let verifyFD = open(targetPath, O_RDONLY)
        XCTAssertGreaterThanOrEqual(verifyFD, 0)
        defer { close(verifyFD) }
        let verifyMap = mmap(nil, expectedFileSize, PROT_READ, MAP_SHARED, verifyFD, 0)
        XCTAssertNotEqual(verifyMap, MAP_FAILED)
        defer { munmap(verifyMap, expectedFileSize) }
        let verifyMem = verifyMap!.assumingMemoryBound(to: RFSharedAudio.self)
        var snapshot = RFVolumeStateSnapshot()
        XCTAssertTrue(rf_read_volume_state(verifyMem, &snapshot), "the target must still hold its committed state")
        XCTAssertEqual(snapshot.scalar, 0.93, accuracy: 0.0001, "the target's volume must not be overwritten")
    }

    // MARK: - 4. Existing file with garbage

    /// A file of a plausible size whose header is nonsense: no protocol version,
    /// no header size, no state. Replaced, and the replacement must validate.
    func testGarbageFileIsReplacedWithValidHeader() throws {
        let target = path(for: testUID)
        let garbage = Data(repeating: 0x5A, count: 4096)
        try garbage.write(to: URL(fileURLWithPath: target))
        XCTAssertEqual(fileSize(target), 4096, "precondition: garbage file written")

        let manager = makeManager()
        let origin = manager.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertEqual(origin, .replacedIncompatible)
        XCTAssertEqual(fileSize(target), expectedFileSize, "the file must be rebuilt at the Host's size")

        let mem = try XCTUnwrap(manager.getMemory(for: testUID))
        XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK, "the rebuilt mapping must satisfy the shared contract")
    }

    // MARK: - 5. Oversized file

    /// A committed mapping that is far larger than this build needs. The volume is
    /// worth keeping, the length is not: the file is rebuilt at the Host's size and
    /// the committed value survives.
    func testOversizedFileIsTruncatedToHostSizeAndKeepsCommittedVolume() throws {
        let target = path(for: testUID)
        let oversized = expectedFileSize * 2

        let fd = open(target, O_CREAT | O_RDWR | O_TRUNC, 0o666)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, Int64(oversized)), 0)
        let mapped = mmap(nil, oversized, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        XCTAssertNotEqual(mapped, MAP_FAILED)
        let mem = mapped!.assumingMemoryBound(to: RFSharedAudio.self)
        seedValidCommittedState(mem, volume: 0.77)
        msync(mem, oversized, MS_SYNC)
        munmap(mem, oversized)
        close(fd)

        let manager = makeManager()
        let origin = manager.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertEqual(origin, .recoveredFromCrash, "a valid committed header is worth keeping")
        XCTAssertEqual(fileSize(target), expectedFileSize, "the stale length must not survive")

        let rebuilt = try XCTUnwrap(manager.getMemory(for: testUID))
        XCTAssertEqual(rf_validate_header(rebuilt), RF_VALIDATE_OK)
        var snapshot = RFVolumeStateSnapshot()
        XCTAssertTrue(rf_read_volume_state(rebuilt, &snapshot))
        XCTAssertEqual(snapshot.scalar, 0.77, accuracy: 0.0001, "the committed volume must survive the resize")
    }

    // MARK: - 6. Permissions the driver depends on

    /// The driver runs inside coreaudiod as a different user and maps this file
    /// read-write. A "hardening" pass that tightened the mode to 0600 would break
    /// audio with no error in the Host at all — the file would simply be
    /// unopenable from the other process. Pinned here so that change has to be
    /// deliberate.
    func testMappingIsWritableByTheDriverProcess() throws {
        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: testUID, persistence: FakePersistence()), .created)

        var st = stat()
        let target = path(for: testUID)
        XCTAssertEqual(lstat(target, &st), 0)

        let mode = st.st_mode & 0o777
        XCTAssertEqual(mode & 0o004, 0o004, "the driver (different uid) must be able to read the mapping")
        XCTAssertEqual(mode & 0o002, 0o002, "the driver must be able to write read_index and heartbeat")
    }
}
