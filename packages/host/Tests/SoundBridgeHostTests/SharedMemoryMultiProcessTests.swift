import XCTest
import Darwin
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - Same-UID multi-process behaviour
//
// `SharedMemoryRecoveryTests` runs eight *threads* against one manager. Threads
// share a mapping and a file descriptor table, so they cannot show what happens
// when two Host processes race: the kernel's `O_EXCL`, `unlink` on a mapped inode
// and `ftruncate` all behave differently across processes.
//
// These tests therefore spawn real child processes. Each child runs a small C
// program compiled at test time from the same `RFSharedAudio.h`, performs the
// same open/ftruncate/mmap/init/publish sequence as `SharedMemoryManager`, and
// then either exits normally or exits without cleaning up (a crash).
//
// Scope, stated plainly: the children are stand-ins for a second Host — they use
// the same syscall sequence and the same header, but they are not
// `SoundBridgeHost` itself. Everything runs in a per-test sandbox directory; no
// child can reach `/tmp/soundbridge-<uid>`.

final class SharedMemoryMultiProcessTests: XCTestCase {

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

    private struct HelperResult {
        let status: Int32
        let output: String
    }

    private static var helperBinary: String?
    private static var helperDirectory: URL?
    private static var compileFailure: String?

    private var sandbox: URL!
    private var testUID: String!

    // MARK: - Helper build (once per class)

    override class func setUp() {
        super.setUp()

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoundBridgeHostTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // host
            .deletingLastPathComponent()   // packages
            .deletingLastPathComponent()   // repository root
        let includeDir = repoRoot.appendingPathComponent("packages/shared/include").path

        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") else {
            compileFailure = "clang not found; skipping multi-process tests"
            return
        }
        guard FileManager.default.fileExists(atPath: "\(includeDir)/RFSharedAudio.h") else {
            compileFailure = "shared header not found at \(includeDir)"
            return
        }

        let workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeMPHarness-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            compileFailure = "could not create harness directory: \(error)"
            return
        }
        // Registered before compiling so a failed build still gets cleaned up.
        helperDirectory = workDir

        let sourceURL = workDir.appendingPathComponent("shm_child.c")
        let binaryURL = workDir.appendingPathComponent("shm_child")
        do {
            try Self.childSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            compileFailure = "could not write child source: \(error)"
            return
        }

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = ["-O1", "-std=c11", "-I", includeDir, sourceURL.path, "-o", binaryURL.path]
        let compileOutput = Pipe()
        compile.standardOutput = compileOutput
        compile.standardError = compileOutput
        do {
            try compile.run()
            compile.waitUntilExit()
        } catch {
            compileFailure = "could not run clang: \(error)"
            return
        }
        guard compile.terminationStatus == 0 else {
            let data = compileOutput.fileHandleForReading.readDataToEndOfFile()
            compileFailure = "child helper failed to compile: \(String(data: data, encoding: .utf8) ?? "")"
            return
        }

        helperDirectory = workDir
        helperBinary = binaryURL.path
    }

    override class func tearDown() {
        if let helperDirectory {
            try? FileManager.default.removeItem(at: helperDirectory)
        }
        helperDirectory = nil
        helperBinary = nil
        compileFailure = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        if let compileFailure = Self.compileFailure {
            throw XCTSkip(compileFailure)
        }
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeShmMPTests-\(UUID().uuidString)", isDirectory: true)
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
        return SharedMemoryManager(sessionID: UUID()) { uid in "\(root)/soundbridge-\(uid)" }
    }

    private func path(for uid: String) -> String {
        "\(sandbox.path)/soundbridge-\(uid)"
    }

    private var expectedFileSize: Int {
        // Batch 1: same single source of truth as the production SharedMemoryManager
        // — the power-of-two rounding, not the raw frame count.
        let frames = rf_ring_capacity_frames_for(
            SoundBridgeConfig.activeSampleRate,
            SoundBridgeConfig.defaultDurationMs
        )
        let bytesPerSample = rf_bytes_per_sample(SoundBridgeConfig.defaultFormat)
        return Int(rf_shared_audio_size(frames, SoundBridgeConfig.defaultChannels, bytesPerSample))
    }

    private func nowMilliseconds() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    }

    private func launchChild(
        mode: String,
        path: String,
        startMS: Int64 = 0,
        holdMS: Int = 0,
        commit: Bool = true
    ) throws -> (process: Process, pipe: Pipe) {
        guard let binary = Self.helperBinary else {
            throw XCTSkip("multi-process helper unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            mode,
            path,
            String(expectedFileSize),
            String(startMS),
            String(holdMS),
            commit ? "1" : "0",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return (process, pipe)
    }

    private func finish(_ launched: (process: Process, pipe: Pipe)) -> HelperResult {
        launched.process.waitUntilExit()
        let data = launched.pipe.fileHandleForReading.readDataToEndOfFile()
        return HelperResult(
            status: launched.process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private func entriesInSandbox() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
    }

    // MARK: - 1. Two (four) processes creating the same mapping

    /// All four children call `open(path, O_CREAT|O_EXCL|O_NOFOLLOW|O_RDWR)` at
    /// the same instant. Exactly one may win; the rest must be told the path is
    /// taken rather than opening someone else's file and truncating it.
    func testConcurrentCreateElectsExactlyOneOwner() throws {
        let target = path(for: testUID)
        let start = nowMilliseconds() + 900

        var launched: [(process: Process, pipe: Pipe)] = []
        for _ in 0..<4 {
            launched.append(try launchChild(mode: "create", path: target, startMS: start))
        }
        let results = launched.map { finish($0) }

        let winners = results.filter { $0.status == 0 }
        let rejected = results.filter { $0.status == 3 }
        XCTAssertEqual(winners.count, 1, "exactly one process may create the mapping, got \(results.map(\.status))")
        XCTAssertEqual(rejected.count, 3, "the losers must fail on O_EXCL/EACCES, got \(results.map(\.status))")

        // One path, not several competing files.
        XCTAssertEqual(try entriesInSandbox(), ["soundbridge-\(testUID!)"])

        let manager = makeManager()
        let fd = open(target, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let mapped = mmap(nil, MemoryLayout<RFSharedAudio>.size, PROT_READ, MAP_SHARED, fd, 0)
        XCTAssertNotEqual(mapped, MAP_FAILED)
        defer { munmap(mapped, MemoryLayout<RFSharedAudio>.size) }
        let mem = mapped!.assumingMemoryBound(to: RFSharedAudio.self)
        XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK, "the winner's file must satisfy the contract")
        var snapshot = RFVolumeStateSnapshot()
        XCTAssertTrue(rf_read_volume_state(mem, &snapshot))
        XCTAssertEqual(snapshot.scalar, 0.62, accuracy: 0.0001)
        XCTAssertNil(manager.getMemory(for: testUID), "no in-process mapping was created by the race")
    }

    // MARK: - 2. Many processes probing one mapping

    /// Concurrent readers must all reach the same verdict about an existing file.
    /// A probe that mutated what it read would show up here as disagreement.
    func testConcurrentProbesAgreeOnTheExistingMapping() throws {
        let manager = makeManager()
        XCTAssertEqual(manager.createMemory(for: testUID, persistence: FakePersistence()), .created)
        let target = path(for: testUID)
        let start = nowMilliseconds() + 700

        var launched: [(process: Process, pipe: Pipe)] = []
        for _ in 0..<4 {
            launched.append(try launchChild(mode: "probe", path: target, startMS: start))
        }
        let results = launched.map { finish($0) }

        for result in results {
            XCTAssertEqual(result.status, 0, "probe failed: \(result.output)")
            XCTAssertTrue(
                result.output.contains("size=\(expectedFileSize)"),
                "probe saw an unexpected size: \(result.output)"
            )
            XCTAssertTrue(
                result.output.contains("validate=0"),
                "probe rejected the header by a different rule: \(result.output)"
            )
        }
    }

    // MARK: - 3. A child that dies without cleaning up

    /// The child creates the mapping, commits a volume and exits without
    /// `unlink`. That is exactly what a crashed Host leaves behind, and the
    /// manager must adopt the committed value rather than treat the file as junk.
    func testStateFromAProcessThatDiedIsRecovered() throws {
        let target = path(for: testUID)
        let result = finish(try launchChild(mode: "create", path: target, commit: true))
        XCTAssertEqual(result.status, 0, "child create failed: \(result.output)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target), "the child's file must still be on disk")

        let manager = makeManager()
        let origin = manager.createMemory(for: testUID, persistence: FakePersistence())

        XCTAssertEqual(origin, .recoveredFromCrash)
        let mem = try XCTUnwrap(manager.getMemory(for: testUID))
        XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)
        var snapshot = RFVolumeStateSnapshot()
        XCTAssertTrue(rf_read_volume_state(mem, &snapshot))
        XCTAssertEqual(snapshot.scalar, 0.62, accuracy: 0.0001, "the dead process's committed volume must survive")
    }

    // MARK: - 4. Unlinking a file another process still has mapped

    /// The Host rebuilds its mapping while a second process is writing through an
    /// older one. POSIX keeps the old inode alive for the holder, so the writer
    /// must not fault; the rebuild must land in a new file with this process's
    /// volume. If either half of that is wrong, an upgrade or restart would
    /// corrupt audio the moment two Hosts overlap.
    func testUnlinkWhileAnotherProcessHoldsTheMappingIsSurvivable() throws {
        let target = path(for: testUID)

        // A crashed Host's leftovers are the realistic starting point.
        XCTAssertEqual(finish(try launchChild(mode: "create", path: target)).status, 0)

        let holder = try launchChild(mode: "hold", path: target, holdMS: 1_500)
        // Give the holder time to map and start writing.
        Thread.sleep(forTimeInterval: 0.4)

        let manager = makeManager()
        let origin = manager.createMemory(
            for: testUID,
            persistence: FakePersistence(seed: [testUID: DeviceVolumeState(volumeScalar: 0.5, isMuted: false)])
        )

        XCTAssertEqual(origin, .recoveredFromCrash, "the probe must see the holder's committed header first")
        let holderResult = finish(holder)
        XCTAssertEqual(holderResult.status, 0, "writing through an unlinked mapping must not fault: \(holderResult.output)")

        // The rebuild is a new file with this process's persisted volume, not the
        // dead one's.
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))
        let mem = try XCTUnwrap(manager.getMemory(for: testUID))
        XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)
        var snapshot = RFVolumeStateSnapshot()
        XCTAssertTrue(rf_read_volume_state(mem, &snapshot))
        XCTAssertEqual(snapshot.scalar, 0.5, accuracy: 0.0001, "persisted state wins over the stale mapping")
        XCTAssertEqual(try entriesInSandbox(), ["soundbridge-\(testUID!)"])
    }

    // MARK: - Child program

    /// Compiled at test time against the real `RFSharedAudio.h`. Modes:
    ///
    /// - `create`: `O_CREAT|O_EXCL|O_NOFOLLOW`, init, optional commit, exit 0.
    ///   Exit 3 when the path is already taken.
    /// - `probe`:  read-only map of the header, print size and validation result.
    /// - `hold`:   map an existing file and keep writing through it for `holdMS`.
    private static let childSource = """
    #include "RFSharedAudio.h"
    #include <errno.h>
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/mman.h>
    #include <sys/stat.h>
    #include <time.h>
    #include <unistd.h>

    static long long now_ms(void) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        return (long long)ts.tv_sec * 1000 + (long long)(ts.tv_nsec / 1000000);
    }

    static void wait_until(long long deadline_ms) {
        while (now_ms() < deadline_ms) {
            struct timespec req;
            req.tv_sec = 0;
            req.tv_nsec = 2 * 1000 * 1000;
            nanosleep(&req, NULL);
        }
    }

    static void sleep_ms(long long ms) {
        if (ms <= 0) return;
        struct timespec req;
        req.tv_sec = (time_t)(ms / 1000);
        req.tv_nsec = (long)((ms % 1000) * 1000000);
        nanosleep(&req, NULL);
    }

    int main(int argc, char **argv) {
        if (argc < 4) {
            fprintf(stderr, "usage: %s <mode> <path> <size> [start_ms] [hold_ms] [commit]\\n", argv[0]);
            return 64;
        }
        const char *mode = argv[1];
        const char *path = argv[2];
        long long size = atoll(argv[3]);
        long long start_ms = argc > 4 ? atoll(argv[4]) : 0;
        long long hold_ms = argc > 5 ? atoll(argv[5]) : 0;
        int commit = argc > 6 ? atoi(argv[6]) : 1;

        wait_until(start_ms);

        if (strcmp(mode, "create") == 0) {
            int fd = open(path, O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR, 0666);
            if (fd < 0) {
                printf("create-failed errno=%d\\n", errno);
                return 3;
            }
            fchmod(fd, 0666);
            if (ftruncate(fd, size) != 0) {
                printf("truncate-failed errno=%d\\n", errno);
                close(fd);
                return 4;
            }
            RFSharedAudio *mem = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (mem == MAP_FAILED) {
                printf("mmap-failed errno=%d\\n", errno);
                close(fd);
                return 5;
            }
            rf_shared_audio_init(mem, 48000, 2, RF_FORMAT_FLOAT32, 100);
            if (commit) {
                rf_publish_volume_state(mem, 0.62f, false, RF_VOLUME_MODE_SOFTWARE);
            }
            msync(mem, (size_t)size, MS_SYNC);
            sleep_ms(hold_ms);
            munmap(mem, (size_t)size);
            close(fd);
            printf("created\\n");
            return 0;
        }

        if (strcmp(mode, "probe") == 0) {
            int fd = open(path, O_RDONLY | O_NOFOLLOW);
            if (fd < 0) {
                printf("probe-open-failed errno=%d\\n", errno);
                return 6;
            }
            struct stat st;
            if (fstat(fd, &st) != 0) {
                printf("probe-stat-failed errno=%d\\n", errno);
                close(fd);
                return 6;
            }
            size_t header = sizeof(RFSharedAudio);
            RFSharedAudio *mem = mmap(NULL, header, PROT_READ, MAP_SHARED, fd, 0);
            if (mem == MAP_FAILED) {
                printf("probe-mmap-failed errno=%d\\n", errno);
                close(fd);
                return 6;
            }
            int verdict = (int)rf_validate_header(mem);
            printf("size=%lld validate=%d\\n", (long long)st.st_size, verdict);
            munmap(mem, header);
            close(fd);
            return verdict == RF_VALIDATE_OK ? 0 : 7;
        }

        if (strcmp(mode, "hold") == 0) {
            int fd = open(path, O_RDWR | O_NOFOLLOW);
            if (fd < 0) {
                printf("hold-open-failed errno=%d\\n", errno);
                return 8;
            }
            RFSharedAudio *mem = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (mem == MAP_FAILED) {
                printf("hold-mmap-failed errno=%d\\n", errno);
                close(fd);
                return 8;
            }
            rf_publish_volume_state(mem, 0.31f, false, RF_VOLUME_MODE_SOFTWARE);
            long long elapsed = 0;
            while (elapsed < hold_ms) {
                rf_store_volume_scalar(mem, 0.31f);
                msync(mem, sizeof(RFSharedAudio), MS_SYNC);
                sleep_ms(10);
                elapsed += 10;
            }
            munmap(mem, (size_t)size);
            close(fd);
            printf("held\\n");
            return 0;
        }

        fprintf(stderr, "unknown mode: %s\\n", mode);
        return 65;
    }
    """
}
