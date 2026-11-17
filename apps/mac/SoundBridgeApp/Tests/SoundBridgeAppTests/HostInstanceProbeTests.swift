import XCTest
import Darwin
@testable import SoundBridgeApp

// `flock(2)` is not nameable from Swift: the symbol collides with `struct flock`.
// Bound the same way the production code binds it.
@_silgen_name("flock")
private func _lockFileDescriptor(_ fd: Int32, _ operation: Int32) -> Int32

// MARK: - Instance probe
//
// The app decides "does a Host already own this user's audio?" by trying the
// same exclusive lock the Host holds. This replaced `pgrep -f SoundBridgeHost`,
// which matched look-alikes and had no atom. Two properties matter and are
// tested here: the path is the Host's path, and probing never creates, mutates,
// or keeps the file.

final class HostInstanceProbeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Take the lock the way the Host does, and hand back the fd that holds it.
    private func acquireLikeAHost(path: String) throws -> Int32 {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw XCTSkip("could not open \(path): \(String(cString: strerror(errno)))")
        }
        guard _lockFileDescriptor(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw XCTSkip("could not take the lock on \(path)")
        }
        return fd
    }

    // MARK: - Path contract

    func testDefaultPathMatchesTheHostPath() {
        // Pinned literally because this is the contract between two binaries.
        // `RF_INSTANCE_LOCK_PATH_PREFIX`/`SUFFIX` in RFSharedAudio.h is the single
        // definition; the Host's `HostInstanceLock.defaultPath` and this probe
        // both build the name from it.
        XCTAssertEqual(
            HostInstanceProbe.lockPath(uid: 501),
            "/tmp/soundbridge-host-501.lock"
        )
        XCTAssertEqual(HostInstanceProbe.lockSuffix, ".lock")
    }

    func testDefaultPathUsesTheRealUIDByDefault() {
        XCTAssertEqual(
            HostInstanceProbe.lockPath(),
            "/tmp/soundbridge-host-\(getuid()).lock"
        )
    }

    func testDifferentUsersGetDifferentPaths() {
        // UID isolation: one user's Host must not block another's, and `/tmp` is
        // shared, so the name has to carry the UID.
        XCTAssertNotEqual(HostInstanceProbe.lockPath(uid: 501), HostInstanceProbe.lockPath(uid: 502))
    }

    // MARK: - Probe semantics

    func testProbeReportsARunningHostWhileTheLockIsHeld() throws {
        let path = root.appendingPathComponent("held.lock").path
        let fd = try acquireLikeAHost(path: path)
        defer { close(fd) }

        XCTAssertTrue(HostInstanceProbe.isHostRunning(path: path))
    }

    func testProbeReportsNoHostOnceTheLockIsReleased() throws {
        let path = root.appendingPathComponent("released.lock").path
        let fd = try acquireLikeAHost(path: path)

        XCTAssertTrue(HostInstanceProbe.isHostRunning(path: path))

        _ = _lockFileDescriptor(fd, LOCK_UN)
        close(fd)

        XCTAssertFalse(HostInstanceProbe.isHostRunning(path: path))
    }

    func testProbeDoesNotCreateTheLockFile() {
        // Creating it would be harmless in itself, but it is the same class of
        // mistake as `rm`-ing one: the probe must be a pure read of the state.
        let path = root.appendingPathComponent("absent.lock").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        XCTAssertFalse(HostInstanceProbe.isHostRunning(path: path))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path),
            "probing an absent lock must not create it"
        )
    }

    func testProbeLeavesTheLockFreeForTheHost() {
        // If the probe kept the lock even briefly, a Host starting right after
        // the probe would conclude another instance exists and exit 3.
        let path = root.appendingPathComponent("free.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return XCTFail("could not create \(path)") }
        defer { close(fd) }

        XCTAssertFalse(HostInstanceProbe.isHostRunning(path: path))

        XCTAssertEqual(
            _lockFileDescriptor(fd, LOCK_EX | LOCK_NB), 0,
            "the probe left the lock held"
        )
        _ = _lockFileDescriptor(fd, LOCK_UN)
    }

    func testProbeDoesNotBlock() throws {
        // LOCK_NB is the whole reason a probe is safe on the main thread: a
        // blocking flock would freeze the app for as long as the Host lives.
        let path = root.appendingPathComponent("blocking.lock").path
        let fd = try acquireLikeAHost(path: path)
        defer { close(fd) }

        let start = Date()
        XCTAssertTrue(HostInstanceProbe.isHostRunning(path: path))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    // MARK: - Owner record

    func testOwnerDescriptionReturnsTheFirstLine() throws {
        let path = root.appendingPathComponent("owner.lock").path
        try "pid=4242 uid=501 since=2026-01-01T00:00:00Z\n".write(
            to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(
            HostInstanceProbe.ownerDescription(path: path),
            "pid=4242 uid=501 since=2026-01-01T00:00:00Z"
        )
    }

    func testOwnerDescriptionIsNilForEmptyOrMissingFiles() throws {
        let empty = root.appendingPathComponent("empty.lock").path
        try Data().write(to: URL(fileURLWithPath: empty))
        XCTAssertNil(HostInstanceProbe.ownerDescription(path: empty))

        let missing = root.appendingPathComponent("missing.lock").path
        XCTAssertNil(HostInstanceProbe.ownerDescription(path: missing))
    }
}
