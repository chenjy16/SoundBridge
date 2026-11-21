import XCTest
import Darwin
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - Mapping incarnation identity
//
// Batch 3 needs one Host-side property to be true by construction, because the
// driver's stale-claim recovery depends on it:
//
//   every published mapping is a NEW inode carrying a NEW admission epoch.
//
// If the Host ever re-adopted an existing file, a driver that crashed while
// holding the producer slot would keep that slot forever on the next launch.
// These tests pin the property and the liveness argument built on it. They do
// not exercise the driver, CoreAudio, or any HAL callback.

final class MappingIncarnationTests: XCTestCase {

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
    private var uid: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeIncarnationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        uid = "inc-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        uid = nil
        try super.tearDownWithError()
    }

    private func path(for uid: String) -> String {
        "\(sandbox.path)/soundbridge-\(uid)"
    }

    private func makeManager() -> SharedMemoryManager {
        let base = sandbox.path
        let manager = SharedMemoryManager(sessionID: nil) { uid in "\(base)/soundbridge-\(uid)" }
        manager.beginSession(UUID())
        return manager
    }

    @discardableResult
    private func publish(_ manager: SharedMemoryManager) -> SharedMemoryOrigin? {
        manager.createMemory(for: uid, persistence: FakePersistence())
    }

    private func inode(at path: String) -> ino_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_ino
    }

    // MARK: - New incarnation on every publish

    func testEveryPublishIsANewInodeWithANewEpoch() {
        let manager = makeManager()
        XCTAssertNotNil(publish(manager))
        guard let first = manager.acquireMemory(for: uid) else {
            return XCTFail("no first mapping published")
        }
        let firstEpoch = rf_admission_epoch(first.memory)
        XCTAssertNotEqual(firstEpoch, 0, "a published mapping always carries an epoch")
        XCTAssertEqual(rf_admission_state(first.memory), RF_ADMISSION_OPEN)

        XCTAssertNotNil(publish(manager))
        guard let second = manager.acquireMemory(for: uid) else {
            return XCTFail("no second mapping published")
        }
        let secondEpoch = rf_admission_epoch(second.memory)
        XCTAssertNotEqual(secondEpoch, 0)
        XCTAssertNotEqual(first.inode, second.inode, "a new incarnation is a new inode")
        XCTAssertNotEqual(first.memory, second.memory, "a new incarnation is a new mapping")
        XCTAssertNotEqual(firstEpoch, secondEpoch, "a new incarnation carries a new epoch")

        // The published path now belongs to the second incarnation and to
        // nothing else.
        XCTAssertEqual(inode(at: path(for: uid)), second.inode)
        XCTAssertNotEqual(inode(at: path(for: uid)), first.inode)

        withExtendedLifetime((first, second)) {}
    }

    // MARK: - Stale claim cannot block recovery (P0-C liveness)

    func testStaleClaimOnARetiredIncarnationCannotBlockTheNextOne() {
        let manager = makeManager()
        XCTAssertNotNil(publish(manager))
        guard let stale = manager.acquireMemory(for: uid) else {
            return XCTFail("no mapping published")
        }

        // A driver that dies between claim and release leaves exactly this
        // state: the slot is owned and the mapping is still OPEN.
        let token: UInt64 = 0xC0FFEE0123456789
        XCTAssertTrue(rf_producer_claim(stale.memory, token), "the crashed driver took the slot")
        XCTAssertEqual(rf_producer_owner_token(stale.memory), token)
        let staleEpoch = rf_admission_epoch(stale.memory)

        // Recovery is a new incarnation, never a re-adoption of the old file.
        XCTAssertNotNil(publish(manager))
        guard let fresh = manager.acquireMemory(for: uid) else {
            return XCTFail("no replacement mapping published")
        }
        XCTAssertNotEqual(fresh.inode, stale.inode)
        XCTAssertNotEqual(rf_admission_epoch(fresh.memory), staleEpoch)

        // Liveness: the new mapping starts unowned, so the same token (or any
        // token) can claim it. The stale owner cannot reach across incarnations.
        XCTAssertEqual(rf_producer_owner_token(fresh.memory), 0,
                       "a new incarnation starts with an empty producer slot")
        XCTAssertTrue(rf_producer_claim(fresh.memory, token),
                      "a stale claim on the retired incarnation must not block recovery")

        // And the retired incarnation is untouched: nothing revived it.
        XCTAssertEqual(rf_producer_owner_token(stale.memory), token)
        XCTAssertNotEqual(rf_admission_state(stale.memory), RF_ADMISSION_CLOSED,
                          "the retired mapping is abandoned, not silently reused")

        withExtendedLifetime((stale, fresh)) {}
    }

    // MARK: - Revocation is not a drain, and the lease keeps the page alive

    func testRemoveMemoryLeavesNoFileButKeepsTheHoldersLeaseValid() {
        let manager = makeManager()
        XCTAssertNotNil(publish(manager))
        guard let lease = manager.acquireMemory(for: uid) else {
            return XCTFail("no mapping published")
        }
        let pointer = lease.memory
        let size = lease.size
        XCTAssertTrue(rf_validate_header(pointer) == RF_VALIDATE_OK)
        XCTAssertEqual(rf_admission_state(pointer), RF_ADMISSION_OPEN)

        manager.removeMemory(for: uid)

        XCTAssertNil(manager.acquireMemory(for: uid), "the manager published nothing after removal")
        XCTAssertNil(inode(at: path(for: uid)), "the file was unlinked")

        // Revocation closes admission immediately...
        XCTAssertNotEqual(rf_admission_state(pointer), RF_ADMISSION_OPEN,
                          "admission is revoked before the mapping is abandoned")

        // ...but it is not a munmap: the lease holder still has a valid page, so
        // a driver callback that is already inside cannot fault on it.
        XCTAssertTrue(rf_validate_header(pointer) == RF_VALIDATE_OK,
                      "the retired mapping stays readable for its lease holder")
        XCTAssertEqual(Int(pointer.pointee.sample_rate), Int(SoundBridgeConfig.activeSampleRate))
        XCTAssertGreaterThan(pointer.pointee.ring_capacity_frames, 0)
        XCTAssertGreaterThan(size, MemoryLayout<RFSharedAudio>.size)

        withExtendedLifetime(lease) {}
    }

    // MARK: - Cleanup path

    func testCleanupAbandonsEveryIncarnationWithoutReusingThem() {
        let manager = makeManager()
        XCTAssertNotNil(publish(manager))
        guard let lease = manager.acquireMemory(for: uid) else {
            return XCTFail("no mapping published")
        }
        let pointer = lease.memory

        manager.cleanup()

        XCTAssertNil(manager.acquireMemory(for: uid))
        XCTAssertNil(inode(at: path(for: uid)), "cleanup unlinks the owned file")
        XCTAssertTrue(rf_validate_header(pointer) == RF_VALIDATE_OK,
                      "cleanup does not munmap under a lease holder")
        XCTAssertNotEqual(rf_admission_state(pointer), RF_ADMISSION_OPEN)

        // A closed manager refuses to publish again rather than resurrecting a
        // retired incarnation.
        XCTAssertNil(publish(manager), "a closed manager cannot publish")

        withExtendedLifetime(lease) {}
    }

    // MARK: - Incarnations never alias

    func testThreePublishesYieldThreeDistinctIncarnations() {
        let manager = makeManager()
        var inodes = Set<ino_t>()
        var epochs = Set<UInt64>()
        var leases: [SharedMemoryMapping] = []

        for _ in 0..<3 {
            XCTAssertNotNil(publish(manager))
            guard let lease = manager.acquireMemory(for: uid) else {
                return XCTFail("no mapping published")
            }
            leases.append(lease)
            inodes.insert(lease.inode)
            let epoch = rf_admission_epoch(lease.memory)
            XCTAssertNotEqual(epoch, 0)
            epochs.insert(epoch)
        }

        XCTAssertEqual(inodes.count, 3, "three publishes, three inodes")
        XCTAssertEqual(epochs.count, 3, "three publishes, three epochs")

        withExtendedLifetime(leases) {}
    }
}
