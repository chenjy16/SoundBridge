import XCTest
import Darwin
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - Heartbeat fields across a real process boundary
//
// `DriverLifecycleTests` proves the state machine. It cannot prove the fields it
// reads are the ones another process writes: a wrong offset, a non-atomic read,
// or a 32-bit truncation of a 64-bit counter would pass every in-process test and
// still misreport a real driver.
//
// So the writer here is a real child process running the same inline helpers the
// driver compiles (`rf_update_driver_heartbeat`, `rf_update_host_heartbeat`),
// against a mapping this process created. Both sides are on the same file.
//
// Timing note: assertions are about *sample order*, not wall-clock ages. The
// tracker counts consecutive unchanged samples, so a killed writer is detected by
// taking more samples — no sleeping for a threshold.

final class DriverHeartbeatCrossProcessTests: XCTestCase {

    private static var helperBinary: String?
    private static var helperDirectory: URL?
    private static var helperFailure: String?

    private var sandbox: URL!
    private var deviceUID: String!
    private var manager: SharedMemoryManager!
    private var mappingPath: String!

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
            helperFailure = "clang not found; skipping cross-process heartbeat tests"
            return
        }
        guard FileManager.default.fileExists(atPath: "\(includeDir)/RFSharedAudio.h") else {
            helperFailure = "shared header not found at \(includeDir)"
            return
        }

        let workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeHbHarness-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            helperFailure = "could not create harness directory: \(error)"
            return
        }
        helperDirectory = workDir

        let sourceURL = workDir.appendingPathComponent("heartbeat_child.c")
        let binaryURL = workDir.appendingPathComponent("heartbeat_child")
        do {
            try Self.childSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            helperFailure = "could not write child source: \(error)"
            return
        }

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = ["-O1", "-std=c11", "-I", includeDir, sourceURL.path, "-o", binaryURL.path]
        let output = Pipe()
        compile.standardOutput = output
        compile.standardError = output
        do {
            try compile.run()
            compile.waitUntilExit()
        } catch {
            helperFailure = "could not run clang: \(error)"
            return
        }
        guard compile.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            helperFailure = "heartbeat helper failed to compile: \(String(data: data, encoding: .utf8) ?? "")"
            return
        }

        helperBinary = binaryURL.path
    }

    override class func tearDown() {
        if let helperDirectory {
            try? FileManager.default.removeItem(at: helperDirectory)
        }
        helperDirectory = nil
        helperBinary = nil
        helperFailure = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        if let helperFailure = Self.helperFailure {
            throw XCTSkip(helperFailure)
        }
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeHbTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        deviceUID = "test-\(UUID().uuidString)"
        mappingPath = "\(sandbox.path)/soundbridge-\(deviceUID!)"
        let root = sandbox.path
        manager = SharedMemoryManager(sessionID: UUID()) { uid in "\(root)/soundbridge-\(uid)" }
        XCTAssertEqual(manager.createMemory(for: deviceUID, persistence: NoPersistence()), .created)
        XCTAssertNotNil(manager.getMemory(for: deviceUID))
    }

    override func tearDownWithError() throws {
        manager?.cleanup()
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        manager = nil
        mappingPath = nil
        deviceUID = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private final class NoPersistence: VolumeStatePersisting {
        func loadIfPresent(uid: String) -> DeviceVolumeState? { nil }
        func save(uid: String, volume: Float, muted: Bool) {}
    }

    private func launchChild(_ arguments: [String]) throws -> (process: Process, pipe: Pipe) {
        guard let binary = Self.helperBinary else {
            throw XCTSkip("heartbeat helper unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        return (process, pipe)
    }

    private func finish(_ launched: (process: Process, pipe: Pipe)) -> (status: Int32, output: String) {
        launched.process.waitUntilExit()
        let data = launched.pipe.fileHandleForReading.readDataToEndOfFile()
        return (launched.process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func observe() -> DriverConnectionObservation {
        guard let observation = manager.connectionObservation(for: deviceUID) else {
            XCTFail("the mapping disappeared")
            return DriverConnectionObservation(
                headerValid: false, driverConnected: false, driverHeartbeat: 0, hostHeartbeat: 0
            )
        }
        return observation
    }

    /// Stands in for `SharedMemoryManager.startHeartbeat`'s timer between samples.
    ///
    /// Without this the Host's own counter is frozen, and the tracker rightly
    /// reports `hostHeartbeatStalled` — which would hide the driver behaviour
    /// under test. A real Host advances this once a second for its whole life.
    private func advanceHostHeartbeat() {
        guard let memory = manager.getMemory(for: deviceUID) else {
            return XCTFail("the mapping disappeared")
        }
        rf_update_host_heartbeat(memory)
    }

    /// Waits until the child has attached, using the same field the Host uses.
    @discardableResult
    private func waitForDriver(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if observe().driverConnected { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return observe().driverConnected
    }

    // MARK: - 1. What another process writes is what this process reads

    /// The child calls `rf_update_driver_heartbeat()` in a loop, exactly as the
    /// driver does from `OnWriteMixedOutput`. If the Host read a different offset,
    /// a stale page, or a non-atomic copy, the connection would never leave
    /// `waitingForDriver`.
    func testDriverAttachmentAndFramesAreVisibleToTheHost() throws {
        let child = try launchChild(["hold", mappingPath, "20", "3000"])

        XCTAssertTrue(waitForDriver(), "the child's driver_connected write was not visible")
        XCTAssertGreaterThan(observe().driverHeartbeat, 0, "the child's heartbeat write was not visible")

        var tracker = DriverConnectionTracker()
        XCTAssertEqual(tracker.observe(observe()), .connected)

        // Give the child time to advance the counter, then take a second sample.
        Thread.sleep(forTimeInterval: 0.15)
        advanceHostHeartbeat()
        XCTAssertEqual(tracker.observe(observe()), .connected)
        XCTAssertEqual(tracker.audioPipeline, .flowing, "frames produced by another process must read as flowing")
        XCTAssertTrue(tracker.isAudioFlowing)

        XCTAssertEqual(kill(child.process.processIdentifier, SIGKILL), 0)
        _ = finish(child)
    }

    // MARK: - 2. A writer that stops is a pause, not a detach

    /// The child is killed without clearing `driver_connected` — which is exactly
    /// what a crash looks like. Level 6 must keep reporting the attachment the
    /// header still claims; only level 7 may report that frames stopped.
    func testKilledWriterStallsThePipelineWithoutDetaching() throws {
        let child = try launchChild(["hold", mappingPath, "20", "3000"])
        XCTAssertTrue(waitForDriver())

        var tracker = DriverConnectionTracker(driverStallSamples: 3)
        XCTAssertEqual(tracker.observe(observe()), .connected)
        Thread.sleep(forTimeInterval: 0.1)
        advanceHostHeartbeat()
        XCTAssertEqual(tracker.observe(observe()), .connected)
        XCTAssertEqual(tracker.audioPipeline, .flowing)

        XCTAssertEqual(kill(child.process.processIdentifier, SIGKILL), 0)
        _ = finish(child)

        // The counter is frozen now; more samples are the evidence. The Host's
        // own heartbeat keeps advancing, as it would in a live process.
        var status = SharedMemoryConnectionStatus.pending
        for _ in 0..<3 {
            advanceHostHeartbeat()
            status = tracker.observe(observe())
        }

        XCTAssertEqual(status, .connected, "a silent writer has not detached")
        XCTAssertEqual(tracker.audioPipeline, .stalled, "level 7 must record that frames stopped")
    }

    // MARK: - 3. A real detach is visible as a detach

    /// The driver's `Disconnect()` stores 0 into `driver_connected` before it
    /// unmaps. Same write, same field, from the other process.
    func testDriverDetachFromAnotherProcessIsVisible() throws {
        let child = try launchChild(["emit-detach", mappingPath, "20", "5"])
        let result = finish(child)
        XCTAssertEqual(result.status, 0, "child output: \(result.output)")

        let observation = observe()
        XCTAssertTrue(observation.headerValid)
        XCTAssertFalse(observation.driverConnected, "the child's detach was not visible")

        var tracker = DriverConnectionTracker()
        XCTAssertEqual(tracker.observe(observe()), .waitingForDriver, "nothing attached during this process's life")
    }

    // MARK: - 4. The counter is 64-bit and is read from the right place

    /// The child seeds the counter near the top of the 64-bit range before
    /// incrementing. A read of the wrong width, or of a neighbouring field, shows
    /// up as a value outside `[seed, seed + writes]` or a changed upper word.
    func testSixtyFourBitCounterIsReadWhole() throws {
        let seed: UInt64 = 0xFFFF_FFF0_0000_0000
        let writes = 64
        let child = try launchChild(["set-high", mappingPath, String(writes), String(seed)])
        let result = finish(child)
        XCTAssertEqual(result.status, 0, "child output: \(result.output)")

        let observation = observe()
        XCTAssertEqual(observation.driverConnected, true)
        XCTAssertGreaterThanOrEqual(observation.driverHeartbeat, seed, "the high word was lost")
        XCTAssertLessThanOrEqual(observation.driverHeartbeat, seed + UInt64(writes) + 1, "more writes than were made")
        XCTAssertEqual(
            observation.driverHeartbeat >> 32,
            seed >> 32,
            "the upper 32 bits changed, so the read is not a whole 64-bit load"
        )
    }

    // MARK: - 5. The Host's heartbeat is visible to the driver process

    /// The other direction. If the driver could not see `host_heartbeat`, its
    /// `CheckHealth()` would eventually declare a healthy Host dead.
    func testHostHeartbeatIsVisibleToTheDriverProcess() throws {
        let memory = try XCTUnwrap(manager.getMemory(for: deviceUID))

        // Exactly what the Host's timer does, three times.
        for _ in 0..<3 {
            rf_update_host_heartbeat(memory)
        }

        let child = try launchChild(["read-host", mappingPath])
        let result = finish(child)
        XCTAssertEqual(result.status, 0, "child output: \(result.output)")
        XCTAssertTrue(
            result.output.contains("host_hb=3"),
            "the child must read back the three heartbeats this process wrote, got: \(result.output)"
        )
        XCTAssertTrue(result.output.contains("host_conn=1"), "host_connected must be visible: \(result.output)")
    }

    // MARK: - Child program

    /// Modes:
    ///
    /// - `hold <path> <interval_ms> <duration_ms>`: loop `rf_update_driver_heartbeat`
    ///   until killed or done, leaving `driver_connected` set.
    /// - `emit-detach <path> <interval_ms> <count>`: write, then store 0 into
    ///   `driver_connected` — the driver's `Disconnect()`.
    /// - `set-high <path> <count> <seed>`: seed the 64-bit counter, then increment.
    /// - `read-host <path>`: print the Host's heartbeat and connection flag.
    private static let childSource = """
    #include "RFSharedAudio.h"
    #include <fcntl.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/mman.h>
    #include <sys/stat.h>
    #include <time.h>
    #include <unistd.h>

    static RFSharedAudio *map_mapping(const char *path, size_t *out_size) {
        int fd = open(path, O_RDWR);
        if (fd < 0) return NULL;
        struct stat st;
        if (fstat(fd, &st) != 0 || (size_t)st.st_size < sizeof(RFSharedAudio)) {
            close(fd);
            return NULL;
        }
        void *mem = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (mem == MAP_FAILED) return NULL;
        *out_size = (size_t)st.st_size;
        return (RFSharedAudio *)mem;
    }

    static void sleep_ms(long long ms) {
        if (ms <= 0) return;
        struct timespec req;
        req.tv_sec = (time_t)(ms / 1000);
        req.tv_nsec = (long)((ms % 1000) * 1000000);
        nanosleep(&req, NULL);
    }

    int main(int argc, char **argv) {
        if (argc < 3) {
            fprintf(stderr, "usage: %s <mode> <path> [...]\\n", argv[0]);
            return 64;
        }
        const char *mode = argv[1];
        const char *path = argv[2];

        if (strcmp(mode, "read-host") == 0) {
            size_t size = 0;
            RFSharedAudio *mem = map_mapping(path, &size);
            if (!mem) { printf("map-failed\\n"); return 5; }
            uint32_t host_conn = atomic_load(&mem->host_connected);
            uint64_t host_hb = rf_get_host_heartbeat(mem);
            printf("host_conn=%u host_hb=%llu\\n", host_conn, (unsigned long long)host_hb);
            munmap(mem, size);
            return 0;
        }

        size_t size = 0;
        RFSharedAudio *mem = map_mapping(path, &size);
        if (!mem) { printf("map-failed\\n"); return 5; }

        if (strcmp(mode, "set-high") == 0) {
            long long count = argc > 3 ? atoll(argv[3]) : 1;
            unsigned long long seed = argc > 4 ? strtoull(argv[4], NULL, 10) : 0;
            atomic_store(&mem->driver_connected, 1);
            atomic_store(&mem->driver_heartbeat, seed);
            for (long long i = 0; i < count; i++) {
                rf_update_driver_heartbeat(mem);
            }
            printf("final=%llu\\n", (unsigned long long)atomic_load(&mem->driver_heartbeat));
            munmap(mem, size);
            return 0;
        }

        if (strcmp(mode, "emit-detach") == 0) {
            long long interval = argc > 3 ? atoll(argv[3]) : 10;
            long long count = argc > 4 ? atoll(argv[4]) : 1;
            for (long long i = 0; i < count; i++) {
                rf_update_driver_heartbeat(mem);
                sleep_ms(interval);
            }
            /* What Plugin::Disconnect() does, in the same order. */
            atomic_store(&mem->driver_connected, 0);
            printf("detached\\n");
            munmap(mem, size);
            return 0;
        }

        if (strcmp(mode, "hold") == 0) {
            long long interval = argc > 3 ? atoll(argv[3]) : 20;
            long long duration = argc > 4 ? atoll(argv[4]) : 2000;
            long long elapsed = 0;
            while (elapsed < duration) {
                rf_update_driver_heartbeat(mem);
                sleep_ms(interval);
                elapsed += interval;
            }
            printf("done=%lld\\n", elapsed);
            munmap(mem, size);
            return 0;
        }

        fprintf(stderr, "unknown mode: %s\\n", mode);
        munmap(mem, size);
        return 65;
    }
    """
}
