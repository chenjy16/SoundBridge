import XCTest
import Darwin
import CSoundBridgeAudio
@testable import SoundBridgeApp

// MARK: - P2 Batch 4 §5.2/§5.3: who actually runs `munmap`
//
// Batch 3 proved *when* a mapping may be released (retired, no leases, once).
// It left the thread ambiguous: `releaseLease` runs on whichever thread finished
// writing, and EQ writes come from the main queue, so the last `munmap` could
// land on the UI thread. Batch 4 routes every published-mapping `munmap` through
// `performUnmap`, which runs it on `attachQueue`.
//
// These tests read `unmapRecords` — the ledger the unmap work itself writes,
// capturing the pthread that executed the call. They assert the executor, not
// the presence of a `DispatchQueue.async` in the source.

final class SharedMemoryMappingUnmapThreadTests: XCTestCase {

    private var fixture: SharedMemoryFixture!
    private var manager: SharedMemoryMappingManager!

    override func setUp() {
        super.setUp()
        fixture = SharedMemoryFixture(name: name)
        manager = SharedMemoryMappingManager(pathForUID: { [path = fixture.path] _ in path })
    }

    override func tearDown() {
        manager = nil
        fixture.teardown()
        fixture = nil
        super.tearDown()
    }

    // MARK: Helpers

    @discardableResult
    private func attachCurrent() -> SharedMemoryAttachOutcome {
        manager.attachSynchronously(path: fixture.path)
    }

    private func recordsEventually(_ expected: Int, timeout: TimeInterval = 2.0) -> [SharedMemoryMappingUnmapRecord] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let records = manager.unmapRecords
            if records.count >= expected { return records }
            usleep(2_000)
        }
        return manager.unmapRecords
    }

    private var currentThread: UInt64 { SharedMemoryMappingUnmapRecord.currentThreadIdentifier() }

    // MARK: 1. Writer-side release

    func testLastLeaseReleaseUnmapsOnTheAttachQueueNotTheWriter() throws {
        let first = try fixture.publish()
        XCTAssertTrue(attachCurrent().isCurrent)

        let leaseHeld = DispatchSemaphore(value: 0)
        let releaseBody = DispatchSemaphore(value: 0)
        let writerAlive = DispatchSemaphore(value: 0)
        let writerExit = DispatchSemaphore(value: 0)
        let writerThread = LockedValue<UInt64>(0)

        DispatchQueue.global().async {
            writerThread.value = SharedMemoryMappingUnmapRecord.currentThreadIdentifier()
            self.manager.write { _ in
                leaseHeld.signal()
                releaseBody.wait()
            }
            // Park rather than return: if this thread stayed alive while the
            // unmap ran, its pthread cannot be the executor, so the identity
            // assertion below is about the executor and not about pool reuse.
            writerAlive.signal()
            writerExit.wait()
        }
        leaseHeld.wait()

        // A new incarnation retires the one the writer is inside.
        _ = try fixture.publish()
        XCTAssertTrue(attachCurrent().didAttach)
        XCTAssertTrue(
            manager.unmapRecords.isEmpty,
            "a mapping with a live lease must not be unmapped, even when it is retired"
        )

        releaseBody.signal()
        XCTAssertEqual(writerAlive.wait(timeout: .now() + 5), .success)

        let records = recordsEventually(1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].inode, first.identity.inode)
        XCTAssertFalse(records[0].inline, "the release had to be handed to the attach queue")
        XCTAssertNotEqual(records[0].executor, writerThread.value,
                          "the writer thread must not execute munmap")
        XCTAssertGreaterThan(records[0].generation, 0, "the record carries the incarnation it released")

        writerExit.signal()
    }

    // MARK: 2. Attach-side retirement

    func testRetirementFromTheAttachQueueUnmapsWithoutQueueingBehindItself() throws {
        let first = try fixture.publish()
        XCTAssertTrue(attachCurrent().isCurrent)

        _ = try fixture.publish()
        let caller = currentThread
        XCTAssertTrue(attachCurrent().didAttach)

        let records = recordsEventually(1)
        XCTAssertEqual(records.count, 1)
        // `attachSynchronously` enters the queue with `sync`, so libdispatch runs
        // the block on this thread; `inline` records that the work found itself
        // already on the queue instead of posting another task. That is the
        // control-thread path (attach, publish, retire, stop), not the audio path.
        XCTAssertTrue(records[0].inline, "attach already runs on the queue and must not queue behind itself")
        XCTAssertEqual(records[0].executor, caller)
        XCTAssertEqual(records[0].inode, first.identity.inode)
    }

    // MARK: 3. Exactly once, with valid metadata

    func testEachIncarnationIsUnmappedExactlyOnce() throws {
        var inodes: [ino_t] = []
        for _ in 0..<4 {
            let incarnation = try fixture.publish()
            inodes.append(incarnation.identity.inode)
            XCTAssertTrue(attachCurrent().isCurrent)
        }

        // Re-adopting the current incarnation and revalidating must not release
        // anything: only the three replaced incarnations are eligible.
        XCTAssertFalse(attachCurrent().didAttach)
        manager.revalidate()

        let records = recordsEventually(3)
        let released = records.map(\.inode)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(Set(released).count, 3, "an incarnation was unmapped twice")
        XCTAssertEqual(Set(released), Set(inodes.dropLast()))
        XCTAssertTrue(records.allSatisfy { $0.generation > 0 })
    }

    // MARK: 4. Leases still gate the release

    func testReleaseHappensOnlyAfterTheLastConcurrentLease() throws {
        let first = try fixture.publish()
        XCTAssertTrue(attachCurrent().isCurrent)

        let leases = 4
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writersReleased = DispatchGroup()

        for _ in 0..<leases {
            DispatchQueue.global().async(group: writersReleased) {
                self.manager.write { _ in
                    held.signal()
                    release.wait()
                }
            }
        }
        for _ in 0..<leases {
            XCTAssertEqual(held.wait(timeout: .now() + 5), .success)
        }

        _ = try fixture.publish()
        XCTAssertTrue(attachCurrent().didAttach)
        XCTAssertTrue(manager.unmapRecords.isEmpty)

        // Three of four leases go away; the mapping must stay.
        for _ in 0..<(leases - 1) { release.signal() }
        usleep(100_000)
        XCTAssertTrue(manager.unmapRecords.isEmpty,
                      "releasing all but one lease must not unmap")

        release.signal()
        XCTAssertEqual(writersReleased.wait(timeout: .now() + 5), .success)

        let records = recordsEventually(1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].inode, first.identity.inode)
    }

    // MARK: 5. Shutdown drains

    func testStopDrainsEveryQueuedUnmapBeforeReturning() throws {
        let first = try fixture.publish()
        XCTAssertTrue(attachCurrent().isCurrent)

        let leaseHeld = DispatchSemaphore(value: 0)
        let releaseBody = DispatchSemaphore(value: 0)
        let writerDone = expectation(description: "writer finished")
        DispatchQueue.global().async {
            self.manager.write { _ in
                leaseHeld.signal()
                releaseBody.wait()
            }
            writerDone.fulfill()
        }
        leaseHeld.wait()

        let second = try fixture.publish()
        XCTAssertTrue(attachCurrent().didAttach)

        releaseBody.signal()
        wait(for: [writerDone], timeout: 5)

        // The release only enqueued the old incarnation's unmap; `stop` is the
        // drain point that makes "the App is terminating" mean the bytes are
        // already gone. It also retires the active incarnation (the second one).
        manager.stop()

        let records = manager.unmapRecords
        XCTAssertEqual(records.count, 2, "stop must not return with an unmap still queued")
        XCTAssertEqual(Set(records.map(\.inode)), Set([first.identity.inode, second.identity.inode]))
        XCTAssertTrue(records.contains { $0.inode == first.identity.inode && !$0.inline },
                      "the writer-released incarnation must have been drained by stop")
    }

    // MARK: 6. The writer path stays off the queue

    func testWriterPathNeverWaitsForAPendingUnmap() throws {
        // A queued unmap must not serialise EQ writes behind it. The writer only
        // takes `lock` for bookkeeping and (for EQ) `eqCommitLock`; neither is
        // held across the queue, and `performUnmap` is asynchronous off-queue.
        var incarnation = try fixture.publish()
        XCTAssertTrue(attachCurrent().isCurrent)

        for _ in 0..<8 {
            incarnation = try fixture.publish()
            XCTAssertTrue(attachCurrent().didAttach)
        }

        var snapshot = RFEQSnapshot()
        snapshot.preamp = 1.5
        let started = Date()
        for _ in 0..<50 {
            guard case .written = manager.writeEQSnapshot(snapshot) else {
                return XCTFail("the active incarnation must accept EQ writes")
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5, "EQ writes must not queue behind mapping releases")

        // And the pending releases still complete on their own.
        XCTAssertEqual(recordsEventually(8).count, 8)
        XCTAssertEqual(manager.currentIdentity?.inode, incarnation.identity.inode)
    }

    // MARK: 7. Writes follow the active incarnation, never the retired one

    func testWritingAfterRetirementTargetsTheNewIncarnationAndQueuesNoSecondUnmap() throws {
        let first = try fixture.publish()
        XCTAssertTrue(attachCurrent().isCurrent)

        let second = try fixture.publish()
        XCTAssertTrue(attachCurrent().didAttach)
        XCTAssertEqual(recordsEventually(1).count, 1)

        // Twenty writes against the still-open writer: all of them land in the
        // new incarnation, and none can re-enter the one that was released.
        for _ in 0..<20 {
            guard case .written(let generation) = manager.write({ _ in }) else {
                return XCTFail("the active incarnation must accept writes")
            }
            XCTAssertEqual(generation, 2)
        }
        usleep(50_000)
        XCTAssertEqual(manager.unmapRecords.count, 1, "the retired incarnation must not be unmapped again")
        XCTAssertEqual(manager.unmapRecords[0].inode, first.identity.inode)
        XCTAssertEqual(manager.currentIdentity?.inode, second.identity.inode)
    }

    // MARK: 8. P3 Batch 1.5: the record carries the cost of the call itself

    func testUnmapRecordReportsHowLongTheCallTook() throws {
        let first = try fixture.publish()
        XCTAssertTrue(attachCurrent().isCurrent)

        _ = try fixture.publish()
        XCTAssertTrue(attachCurrent().didAttach)

        let records = recordsEventually(1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].inode, first.identity.inode)
        XCTAssertLessThan(
            records[0].durationMicroseconds, 50_000,
            "a single page-table teardown takes microseconds, not milliseconds"
        )
    }
}

/// Minimal thread-safe box for a value the writer thread publishes to the test.
private final class LockedValue<Value> {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
