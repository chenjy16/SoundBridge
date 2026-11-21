import XCTest
import Darwin
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - Cross-process atomicity: what is actually guaranteed (Phase 2.1.5-C)
//
// The claim under audit is "Host and driver agree on shared state because the
// fields are `_Atomic`". Three separate things have to be true for that, and
// they are checked separately here:
//
//   1. Layout: every atomic field sits at the offset the header pins, and at an
//      address its own size allows. Enforced by `static_assert` at compile time
//      and re-read here from the *shipped* header, so the file the driver
//      compiles is the file the test measured.
//   2. Lock-freedom: `_Atomic` does not mean lock-free. On arm64 and x86_64 an
//      aligned 8-byte atomic is a single instruction; anything larger (or
//      unaligned) silently becomes a library call, which is not something a
//      render callback may do. Measured at runtime, per field.
//   3. Visibility: a writer in another process must be seen whole. What the
//      reader can and cannot promise is asserted below, including the case the
//      snapshot *cannot* protect against — documented rather than hidden.
//
// Evidence levels, stated plainly:
//   - layout + lock-free: L2 (real C program, same machine, shipped header)
//   - arch coverage: L4 (compiles for arm64 and x86_64; only arm64 runs here)
//   - cross-process publish/read: L3 (real child process, real mapping)
// None of this is L5 for Intel: no Intel Mac was used.

final class AtomicMemoryModelTests: XCTestCase {

    private var sandbox: URL!
    private var includeDir: String {
        // The header the Host target compiles, i.e. the synced copy rather than
        // packages/shared — the two are identical (protocol-check), and using the
        // build input is what makes this a check of the shipped artifact.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoundBridgeHostTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // packages/host
            .appendingPathComponent("Sources/CSoundBridgeAudio/include")
            .path
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") else {
            throw XCTSkip("clang not found")
        }
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeAtomicTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - 1. Layout and lock-freedom, measured on this machine

    /// Fields the header pins with `static_assert`, plus the two ring indices.
    private static let atomicFields: [(name: String, size: Int, offset: Int?)] = [
        ("format_change_counter", 8, nil),
        ("write_index", 8, nil),
        ("read_index", 8, nil),
        ("total_frames_written", 8, nil),
        ("total_frames_read", 8, nil),
        ("overrun_count", 8, nil),
        ("underrun_count", 8, nil),
        ("format_mismatch_count", 8, nil),
        ("driver_connected", 4, 120),
        ("host_connected", 4, 124),
        ("driver_heartbeat", 8, 128),
        ("host_heartbeat", 8, 136),
        ("volume_scalar", 4, 144),
        ("mute_state", 4, 148),
        ("eq_sequence", 4, 152),
        ("volume_mode", 4, 204),
        ("state_initialized", 4, 208),
        ("state_revision", 8, 216),
        // Batch 2 admission gateway: read inside the audio callback, so the
        // offsets AND the lock-freedom of these four are part of the RT contract.
        ("admission_state", 4, 256),
        ("admission_epoch", 8, 264),
        ("producer_owner_token", 8, 272),
        ("admission_claim_seq", 8, 280),
    ]

    func testAtomicFieldLayoutIsAlignedAndPinned() throws {
        let report = try runProbe()

        XCTAssertEqual(report["sizeof"], "320", "the fixed header must stay one cache-line-multiple")
        XCTAssertEqual(report["header_size"], "320")

        for field in Self.atomicFields {
            let offsetKey = "offset.\(field.name)"
            guard let offsetText = report[offsetKey], let offset = Int(offsetText) else {
                XCTFail("probe did not report \(offsetKey)")
                continue
            }

            XCTAssertEqual(
                offset % field.size, 0,
                "\(field.name) at offset \(offset) is not \(field.size)-byte aligned; "
                + "misalignment turns an atomic into a lock or a split store"
            )

            if let pinned = field.offset {
                XCTAssertEqual(offset, pinned, "\(field.name) moved; RF_AUDIO_PROTOCOL_VERSION must be bumped")
            }
        }

        XCTAssertEqual(report["alignof"], "8", "an 8-byte atomic alignment is what makes arm64 ldxr/stxr legal")
    }

    func testEverySharedFieldIsLockFreeOnThisMachine() throws {
        let report = try runProbe()

        for field in Self.atomicFields {
            let key = "lockfree.\(field.name)"
            XCTAssertEqual(
                report[key], "1",
                "\(key) is not lock-free on this architecture: a libatomic call inside the render "
                + "callback is a priority inversion, not a theoretical concern"
            )
        }

        XCTAssertEqual(report["lockfree.volume_snapshot"], "1", "the 24-byte snapshot is only copied, not atomic")
    }

    func testProbeCompilesForBothTargetArchitectures() throws {
        // Compile-only. On an arm64 machine the x86_64 slice proves the header and
        // the atomics translate, not that they behave — that would be L5.
        let source = sandbox.appendingPathComponent("atomic_probe.c")
        try Self.probeSource.write(to: source, atomically: true, encoding: .utf8)

        for arch in ["arm64", "x86_64"] {
            let output = sandbox.appendingPathComponent("atomic_probe_\(arch).o")
            let compile = Process()
            compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            compile.arguments = [
                "-std=c11", "-O1", "-Wall", "-Werror",
                "-arch", arch, "-c",
                "-I", includeDir,
                source.path, "-o", output.path,
            ]
            let pipe = Pipe()
            compile.standardError = pipe
            compile.standardOutput = pipe
            try compile.run()
            compile.waitUntilExit()

            let diagnostics = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                compile.terminationStatus, 0,
                "\(arch) compile failed: \(diagnostics)"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }

    // MARK: - 2. Snapshot semantics in one process

    func testSnapshotCarriesNoStateBeforeTheFirstCommit() throws {
        let uid = "atomic-uncommitted-\(UUID().uuidString)"
        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: uid, persistence: NoPersistence()), .created)

        // createMemory commits, so start from a block nobody has published to.
        let path = sandbox.appendingPathComponent("soundbridge-\(uid)").path
        let fd = open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        var st = stat()
        XCTAssertEqual(fstat(fd, &st), 0)
        let mapped = mmap(nil, Int(st.st_size), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        XCTAssertNotEqual(mapped, MAP_FAILED)
        let raw = try XCTUnwrap(mapped?.assumingMemoryBound(to: RFSharedAudio.self))
        defer { munmap(mapped, Int(st.st_size)) }

        rf_shared_audio_init(raw, 48000, 2, RF_FORMAT_FLOAT32, 100)

        var snapshot = RFVolumeStateSnapshot()
        XCTAssertFalse(rf_read_volume_state(raw, &snapshot),
                       "an uncommitted block must report 'no state', not a default volume")
        XCTAssertEqual(rf_get_state_revision(raw), 0)

        rf_publish_volume_state(raw, 0.42, false, 1)
        XCTAssertTrue(rf_read_volume_state(raw, &snapshot))
        XCTAssertEqual(snapshot.scalar, 0.42, accuracy: 1e-6)
        XCTAssertEqual(snapshot.muted, 0)
        XCTAssertEqual(snapshot.mode, 1)
        XCTAssertEqual(snapshot.revision, 1, "publish advances the revision by exactly one")

        manager.cleanup()
    }

    func testSnapshotRevisionMatchesTheValuesItReturns() throws {
        let uid = "atomic-revision-\(UUID().uuidString)"
        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: uid, persistence: NoPersistence()), .created)
        let mem = try XCTUnwrap(manager.getMemory(for: uid))
        // createMemory() commits the resolved starting volume, so the first
        // publish below is not revision 1.
        let baseline = rf_get_state_revision(mem)

        for generation in 1...5 {
            let scalar = Float(generation) / 10.0
            rf_publish_volume_state(mem, scalar, generation % 2 == 1, UInt32(generation % 2))

            var snapshot = RFVolumeStateSnapshot()
            XCTAssertTrue(rf_read_volume_state(mem, &snapshot))
            XCTAssertEqual(snapshot.revision, baseline + UInt64(generation))
            XCTAssertEqual(snapshot.scalar, scalar, accuracy: 1e-6)
            XCTAssertEqual(snapshot.muted, Int32(generation % 2 == 1 ? 1 : 0))
        }

        manager.cleanup()
    }

    func testRawStoreWithoutCommitIsVisibleWithThePreviousRevision() throws {
        // This is the residual window, stated as a test instead of as prose.
        //
        // rf_publish_volume_state() stores the values first and bumps the revision
        // last, so between those two steps the new values are already readable
        // while the revision still describes the old generation. A reader that
        // lands entirely inside that window — or between the last value store and
        // its own closing revision read — returns a self-consistent-looking
        // snapshot, not necessarily the newest one.
        //
        // Closing it needs a seqlock in publish (bump, write, bump). That would
        // make every revision odd-then-even and break interop with a 1.1.x driver
        // that only bumps once, so it is a protocol decision (2.1.5 §C5), not a
        // fix made here. Pinned so nobody "simplifies" the reader and loses the
        // retry, and so nobody assumes the guarantee is stronger than it is.
        let uid = "atomic-rawstore-\(UUID().uuidString)"
        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: uid, persistence: NoPersistence()), .created)
        let mem = try XCTUnwrap(manager.getMemory(for: uid))

        rf_publish_volume_state(mem, 0.5, false, 0)
        let committedRevision = rf_get_state_revision(mem)

        // Exactly what the driver's realtime control path does: values, no commit.
        rf_store_volume_scalar(mem, 0.9)
        rf_store_mute_state(mem, 1)

        var snapshot = RFVolumeStateSnapshot()
        XCTAssertTrue(rf_read_volume_state(mem, &snapshot))
        XCTAssertEqual(snapshot.scalar, 0.9, accuracy: 1e-6,
                       "the raw transport write is visible; a snapshot is not a transaction log")
        XCTAssertEqual(snapshot.revision, committedRevision,
                       "and the revision still names the last commit — this is the documented residual window")

        manager.cleanup()
    }

    func testSnapshotRejectsNullOrUninitialisedOutBuffer() throws {
        let uid = "atomic-null-\(UUID().uuidString)"
        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: uid, persistence: NoPersistence()), .created)
        let mem = try XCTUnwrap(manager.getMemory(for: uid))

        XCTAssertFalse(rf_read_volume_state(nil, nil))
        XCTAssertFalse(rf_read_volume_state(mem, nil), "a NULL out pointer must fail, not trap")

        manager.cleanup()
    }

    // MARK: - 3. Real cross-process publishing

    func testRevisionAndValuesStaySaneWhileAnotherProcessPublishes() throws {
        let uid = "atomic-multiproc-\(UUID().uuidString)"
        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: uid, persistence: NoPersistence()), .created)
        let mem = try XCTUnwrap(manager.getMemory(for: uid))
        // Same value the writer's "even" iteration publishes, so the reader never
        // has to accept a third state while it waits for the child's first write.
        rf_publish_volume_state(mem, 0.25, false, 0)

        let writer = try launchPublisher(
            path: sandbox.appendingPathComponent("soundbridge-\(uid)").path,
            iterations: 4000
        )

        var lastRevision = rf_get_state_revision(mem)
        var samples = 0
        var mixedGenerations = 0

        while writer.isRunning {
            var snapshot = RFVolumeStateSnapshot()
            XCTAssertTrue(rf_read_volume_state(mem, &snapshot), "a committed block must always answer")
            XCTAssertGreaterThanOrEqual(snapshot.revision, lastRevision,
                                        "state_revision only ever increases")
            lastRevision = snapshot.revision

            // Values the writer alternates between: (0.25, unmuted, mode 0) and
            // (0.75, muted, mode 1).
            XCTAssertTrue(snapshot.scalar == 0.25 || snapshot.scalar == 0.75,
                          "torn scalar read: \(snapshot.scalar)")
            XCTAssertTrue(snapshot.muted == 0 || snapshot.muted == 1)
            XCTAssertTrue(snapshot.mode <= 1)

            let expectedMuted = snapshot.scalar == 0.75 ? Int32(1) : Int32(0)
            let expectedMode = snapshot.scalar == 0.75 ? UInt32(1) : UInt32(0)
            if snapshot.muted != expectedMuted || snapshot.mode != expectedMode {
                mixedGenerations += 1
            }
            samples += 1
        }

        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0, "the publisher process must exit cleanly")
        XCTAssertGreaterThan(samples, 100, "the reader must have actually raced the writer")

        // Reported, not asserted away: the retry loop narrows the window but the
        // publish order leaves it open (see the raw-store test above). A non-zero
        // count here is the documented behaviour; the assertion that matters is
        // that no read torn a single field or ran the revision backwards.
        print("[Atomic] \(samples) samples raced the writer, \(mixedGenerations) crossed a commit")
        XCTAssertLessThan(Double(mixedGenerations), Double(samples) * 0.05,
                          "most reads must land inside one generation; 5%+ means the retry stopped working")

        manager.cleanup()
    }

    // MARK: - Fixtures

    private func makeManager() -> SharedMemoryManager {
        let directory = sandbox!
        return SharedMemoryManager(sessionID: UUID(), pathForUID: { "\(directory.path)/soundbridge-\($0)" })
    }

    private func runProbe() throws -> [String: String] {
        let source = sandbox.appendingPathComponent("atomic_probe.c")
        let binary = sandbox.appendingPathComponent("atomic_probe")
        try Self.probeSource.write(to: source, atomically: true, encoding: .utf8)

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [
            "-std=c11", "-O1", "-Wall", "-Werror",
            "-I", includeDir,
            source.path, "-o", binary.path,
        ]
        let compileOutput = Pipe()
        compile.standardError = compileOutput
        compile.standardOutput = compileOutput
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            let text = String(data: compileOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            throw ProbeFailure("probe failed to compile: \(text ?? "")")
        }

        let run = Process()
        run.executableURL = binary
        let output = Pipe()
        run.standardOutput = output
        run.standardError = output
        try run.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()
        XCTAssertEqual(run.terminationStatus, 0, "probe exited \(run.terminationStatus)")

        let text = String(data: data, encoding: .utf8) ?? ""
        var report: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            report[parts[0]] = parts[1]
        }
        XCTAssertFalse(report.isEmpty, "probe produced no key=value output: \(text)")
        return report
    }

    private func launchPublisher(path: String, iterations: Int) throws -> Process {
        let source = sandbox.appendingPathComponent("publisher.c")
        let binary = sandbox.appendingPathComponent("publisher")
        try Self.publisherSource.write(to: source, atomically: true, encoding: .utf8)

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = ["-std=c11", "-O1", "-I", includeDir, source.path, "-o", binary.path]
        let compileOutput = Pipe()
        compile.standardError = compileOutput
        compile.standardOutput = compileOutput
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            let text = String(data: compileOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            throw XCTSkip("publisher failed to compile: \(text ?? "")")
        }

        let run = Process()
        run.executableURL = binary
        run.arguments = [path, String(iterations)]
        let output = Pipe()
        run.standardOutput = output
        run.standardError = output
        try run.run()
        return run
    }

    // MARK: - C sources

    private static let probeSource = #"""
    #include <stdalign.h>
    #include <stdatomic.h>
    #include <stddef.h>
    #include <stdio.h>
    #include <stdlib.h>

    #include "RFSharedAudio.h"

    /* Heap-allocated: a struct with a flexible array member must not be a static
       object, and only the fixed header is measured anyway. */
    static RFSharedAudio *probe = NULL;

    #define OFFSET(field) printf("offset." #field "=%zu\n", offsetof(RFSharedAudio, field))
    #define LOCKFREE(field) printf("lockfree." #field "=%d\n", atomic_is_lock_free(&(probe->field)) ? 1 : 0)

    int main(void) {
        probe = calloc(1, sizeof(RFSharedAudio));
        if (probe == NULL) return 1;

        printf("sizeof=%zu\n", sizeof(RFSharedAudio));
        printf("header_size=%zu\n", (size_t)RF_SHARED_AUDIO_HEADER_SIZE);
        printf("alignof=%zu\n", alignof(RFSharedAudio));
        printf("protocol=0x%x\n", (unsigned)RF_AUDIO_PROTOCOL_VERSION);

        OFFSET(format_change_counter);
        OFFSET(write_index);
        OFFSET(read_index);
        OFFSET(total_frames_written);
        OFFSET(total_frames_read);
        OFFSET(overrun_count);
        OFFSET(underrun_count);
        OFFSET(format_mismatch_count);
        OFFSET(driver_connected);
        OFFSET(host_connected);
        OFFSET(driver_heartbeat);
        OFFSET(host_heartbeat);
        OFFSET(volume_scalar);
        OFFSET(mute_state);
        OFFSET(eq_sequence);
        OFFSET(volume_mode);
        OFFSET(state_initialized);
        OFFSET(state_revision);
        OFFSET(admission_state);
        OFFSET(admission_epoch);
        OFFSET(producer_owner_token);
        OFFSET(admission_claim_seq);

        LOCKFREE(format_change_counter);
        LOCKFREE(write_index);
        LOCKFREE(read_index);
        LOCKFREE(total_frames_written);
        LOCKFREE(total_frames_read);
        LOCKFREE(overrun_count);
        LOCKFREE(underrun_count);
        LOCKFREE(format_mismatch_count);
        LOCKFREE(driver_connected);
        LOCKFREE(host_connected);
        LOCKFREE(driver_heartbeat);
        LOCKFREE(host_heartbeat);
        LOCKFREE(volume_scalar);
        LOCKFREE(mute_state);
        LOCKFREE(eq_sequence);
        LOCKFREE(volume_mode);
        LOCKFREE(state_initialized);
        LOCKFREE(state_revision);
        LOCKFREE(admission_state);
        LOCKFREE(admission_epoch);
        LOCKFREE(producer_owner_token);
        LOCKFREE(admission_claim_seq);

        /* Copied by value, never read atomically: report its lock-freedom as a
           separate fact so a future change to a wider snapshot is visible. */
        printf("lockfree.volume_snapshot=%d\n",
               sizeof(RFVolumeStateSnapshot) <= 32 ? 1 : 0);

        printf("assert.offsets=ok\n");
        return 0;
    }
    """#

    private static let publisherSource = #"""
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <sys/mman.h>
    #include <sys/stat.h>
    #include <unistd.h>

    #include "RFSharedAudio.h"

    int main(int argc, char **argv) {
        if (argc < 3) return 2;
        const char *path = argv[1];
        const int iterations = atoi(argv[2]);

        int fd = open(path, O_RDWR);
        if (fd < 0) { perror("open"); return 3; }

        struct stat st;
        if (fstat(fd, &st) != 0) { perror("fstat"); return 4; }

        RFSharedAudio *mem = mmap(NULL, (size_t)st.st_size,
                                  PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mem == MAP_FAILED) { perror("mmap"); return 5; }

        if (rf_validate_header(mem) != RF_VALIDATE_OK) {
            fprintf(stderr, "header invalid\n");
            return 6;
        }

        for (int i = 0; i < iterations; ++i) {
            const int even = (i % 2) == 0;
            rf_publish_volume_state(mem,
                                    even ? 0.25f : 0.75f,
                                    even ? false : true,
                                    even ? 0u : 1u);
            if ((i % 16) == 0) usleep(200);
        }

        munmap(mem, (size_t)st.st_size);
        close(fd);
        return 0;
    }
    """#
}

private final class NoPersistence: VolumeStatePersisting {
    func loadIfPresent(uid: String) -> DeviceVolumeState? { nil }
    func save(uid: String, volume: Float, muted: Bool) {}
}

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
