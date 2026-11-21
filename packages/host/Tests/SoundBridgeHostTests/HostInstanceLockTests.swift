import XCTest
import Darwin
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - Single-instance lock across real processes
//
// `HostInstanceLock` claims a property that threads cannot demonstrate: that a
// second *process* is refused, and that the first process's death — normal,
// `_exit`-without-cleanup, or SIGKILL — frees the lock without any of our code
// running. Both halves depend on kernel behaviour (flock ownership lives on the
// open file description, which fork/exec children do not share), so the holder
// in most of these tests is a real child process compiled at test time.
//
// Scope, stated plainly: the children are stand-ins that perform the same
// `open` + `flock(LOCK_EX|LOCK_NB)` sequence as `HostInstanceLock`, not the
// `SoundBridgeHost` binary itself. Launching the real binary here would create
// and unlink `/tmp/soundbridge-<uid>`, which this phase forbids. Every path is
// inside a per-test sandbox; no test opens `/tmp/soundbridge-*`.

final class HostInstanceLockTests: XCTestCase {

    private struct HelperResult {
        let status: Int32
        let output: String
        let reason: Process.TerminationReason
    }

    private static var helperBinary: String?
    private static var helperDirectory: URL?
    private static var helperFailure: String?

    private var sandbox: URL!
    private var lockPath: String!

    // MARK: - Helper build (once per class)

    override class func setUp() {
        super.setUp()

        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/clang") else {
            helperFailure = "clang not found; skipping single-instance lock tests"
            return
        }

        let workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeLockHarness-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            helperFailure = "could not create harness directory: \(error)"
            return
        }
        // Registered before compiling so a failed build is still cleaned up.
        helperDirectory = workDir

        let sourceURL = workDir.appendingPathComponent("lock_child.c")
        let binaryURL = workDir.appendingPathComponent("lock_child")
        do {
            try Self.childSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            helperFailure = "could not write child source: \(error)"
            return
        }

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = ["-O1", "-std=c11", sourceURL.path, "-o", binaryURL.path]
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
            helperFailure = "lock helper failed to compile: \(String(data: data, encoding: .utf8) ?? "")"
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
            .appendingPathComponent("SoundBridgeLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        lockPath = "\(sandbox.path)/soundbridge-host-test.lock"
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        lockPath = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func launchChild(
        mode: String,
        path: String,
        holdMS: Int = 0,
        startMS: Int64 = 0
    ) throws -> Process {
        guard let binary = Self.helperBinary else {
            throw XCTSkip("lock helper unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [mode, path, String(holdMS), String(startMS)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func finish(_ process: Process) -> HelperResult {
        process.waitUntilExit()
        let pipe = process.standardOutput as? Pipe
        let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        return HelperResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? "",
            reason: process.terminationReason
        )
    }

    /// Waits for `predicate` without a fixed sleep longer than needed.
    ///
    /// The children start in microseconds, but "started" and "holds the lock" are
    /// not the same instant. Polling the same probe the App uses is the honest
    /// way to wait for the second.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return predicate()
    }

    private var entriesInSandbox: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: sandbox.path))?.sorted() ?? []
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

    /// Writes a *valid* shared-memory file without keeping a live mapping, so a
    /// refusal test can prove the file survived byte-for-byte.
    @discardableResult
    private func writeValidMapping(at path: String, volume: Float) throws -> Int {
        let fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0o666)
        XCTAssertGreaterThanOrEqual(fd, 0, "could not create the fixture mapping")
        XCTAssertEqual(ftruncate(fd, Int64(expectedFileSize)), 0)

        let mapped = mmap(nil, expectedFileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        XCTAssertNotEqual(mapped, MAP_FAILED, "could not map the fixture")
        let mem = mapped!.assumingMemoryBound(to: RFSharedAudio.self)
        rf_shared_audio_init(
            mem,
            SoundBridgeConfig.activeSampleRate,
            SoundBridgeConfig.defaultChannels,
            SoundBridgeConfig.defaultFormat,
            SoundBridgeConfig.defaultDurationMs
        )
        rf_publish_volume_state(mem, volume, false, 0)
        msync(mem, expectedFileSize, MS_SYNC)
        munmap(mem, expectedFileSize)
        close(fd)
        return expectedFileSize
    }

    // MARK: - 会话标识与锁的生命周期

    func testSessionIsStableWhileHeldAndChangesAfterReacquisition() throws {
        let first = HostInstanceLock(path: lockPath)
        let second = HostInstanceLock(path: lockPath)
        XCTAssertNil(first.sessionID)
        XCTAssertEqual(first.acquire(), .acquired)
        let original = try XCTUnwrap(first.sessionID)
        XCTAssertEqual(first.acquire(), .acquired)
        XCTAssertEqual(first.sessionID, original)
        XCTAssertTrue(try String(contentsOfFile: lockPath, encoding: .utf8)
            .contains("session=\(original.uuidString)"))

        guard case .heldByAnotherInstance = second.acquire() else {
            return XCTFail("持锁期间不能创建第二个会话")
        }
        XCTAssertNil(second.sessionID)
        first.release()
        XCTAssertNil(first.sessionID)

        XCTAssertEqual(second.acquire(), .acquired)
        let next = try XCTUnwrap(second.sessionID)
        XCTAssertNotEqual(next, original)
        second.release()
        XCTAssertNil(second.sessionID)
    }

    func testGlobalLockSerializesDistinctUserLockPaths() throws {
        let shared = "\(sandbox.path)/global.lock"
        let first = HostInstanceLock(path: "\(sandbox.path)/user-a.lock", globalPath: shared)
        let secondPath = "\(sandbox.path)/user-b.lock"
        let second = HostInstanceLock(path: secondPath, globalPath: shared)
        XCTAssertEqual(first.acquire(), .acquired)
        guard case .heldByAnotherInstance = second.acquire() else {
            return XCTFail("共用 IPC 路径的两个 Host 不能同时启动")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondPath))
        XCTAssertNil(second.sessionID)
        first.release()
        XCTAssertEqual(second.acquire(), .acquired)
        second.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared))
    }

    func testGlobalLockIsReleasedIfUserLockAcquisitionFails() throws {
        let shared = "\(sandbox.path)/global.lock"
        let invalid = "\(sandbox.path)/missing/user.lock"
        let failed = HostInstanceLock(path: invalid, globalPath: shared)
        guard case .failed = failed.acquire() else { return XCTFail("每用户锁应当失败") }
        let next = HostInstanceLock(path: lockPath, globalPath: shared)
        XCTAssertEqual(next.acquire(), .acquired)
        next.release()
    }

    func testGlobalLockRejectsSymlink() throws {
        let target = "\(sandbox.path)/target"
        let shared = "\(sandbox.path)/global.lock"
        try Data("untouched".utf8).write(to: URL(fileURLWithPath: target))
        XCTAssertEqual(symlink(target, shared), 0)
        let contender = HostInstanceLock(path: lockPath, globalPath: shared)
        guard case .failed = contender.acquire() else { return XCTFail("不能跟随全局锁符号链接") }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)), Data("untouched".utf8))
    }

    func testGlobalLockConflictsWithSeparateProcess() throws {
        let shared = "\(sandbox.path)/global.lock"
        let child = try launchChild(mode: "hold", path: shared, holdMS: 1200)
        XCTAssertTrue(waitUntil { HostInstanceLock.isHeld(path: shared) })
        let contender = HostInstanceLock(path: lockPath, globalPath: shared)
        guard case .heldByAnotherInstance = contender.acquire() else {
            _ = finish(child)
            return XCTFail("跨进程全局锁冲突未被拒绝")
        }
        XCTAssertEqual(finish(child).status, 0)
        XCTAssertEqual(contender.acquire(), .acquired)
        contender.release()
    }

    // MARK: - 1. The first process acquires

    func testFirstProcessAcquiresTheLock() throws {
        let result = finish(try launchChild(mode: "hold", path: lockPath, holdMS: 50))

        XCTAssertEqual(result.status, 0, "the first process must acquire the lock: \(result.output)")
        XCTAssertTrue(result.output.contains("acquired"), "expected an acquisition report, got: \(result.output)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockPath),
            "the lock file must exist after acquisition"
        )
    }

    // MARK: - 2. A second process is refused

    /// The holder is a real child; the contender is this process. If the lock
    /// were advisory-by-existence, or if `acquire` returned `.acquired` on
    /// `EWOULDBLOCK`, this is where it would show.
    func testSecondProcessIsRefusedWhileTheFirstHolds() throws {
        let holder = try launchChild(mode: "hold", path: lockPath, holdMS: 2_500)
        XCTAssertTrue(
            waitUntil { HostInstanceLock.isHeld(path: self.lockPath) },
            "the child never appeared to hold the lock"
        )

        // In-process contender: a separate open file description, exactly like a
        // second Host process.
        let contender = HostInstanceLock(path: lockPath)
        let result = contender.acquire()

        switch result {
        case .heldByAnotherInstance(let owner):
            let record = try XCTUnwrap(owner, "the owner record must explain who holds the lock")
            XCTAssertTrue(record.contains("pid="), "owner record should name the pid, got: \(record)")
        case .acquired:
            XCTFail("a second instance acquired a held lock")
        case .failed(let reason):
            XCTFail("contention must not be reported as a failure: \(reason)")
        }
        XCTAssertFalse(contender.isHeld, "a refused instance must not think it holds the lock")

        // And a real child contender must exit with the dedicated status rather
        // than treating contention as a generic failure.
        let second = finish(try launchChild(mode: "hold", path: lockPath, holdMS: 50))
        XCTAssertEqual(second.status, HostExitCode.instanceConflict, "second process output: \(second.output)")
        XCTAssertTrue(second.output.contains("held"), "expected a contention report, got: \(second.output)")

        // A non-owning probe agrees, and does not disturb the holder.
        XCTAssertTrue(HostInstanceLock.isHeld(path: lockPath))

        XCTAssertEqual(finish(holder).status, 0, "the holder must be unaffected by the contenders")
        XCTAssertFalse(HostInstanceLock.isHeld(path: lockPath), "the lock must be free once the holder exits")
    }

    // MARK: - 3. Different users do not contend

    /// UID isolation is a property of the path, so it is tested as one: the
    /// derived paths must differ, must embed the UID, and must never coincide
    /// with the shared-memory path (which carries no `.lock` and is the thing we
    /// must not touch). Two locks on distinct per-UID paths must both succeed.
    func testDifferentUIDsUseDistinctPathsAndBothAcquire() throws {
        let firstPath = HostInstanceLock.defaultPath(uid: 501)
        let secondPath = HostInstanceLock.defaultPath(uid: 502)

        XCTAssertNotEqual(firstPath, secondPath, "the lock path must be UID-scoped")
        XCTAssertTrue(firstPath.contains("501"))
        XCTAssertTrue(secondPath.contains("502"))
        XCTAssertTrue(firstPath.hasSuffix(HostInstanceLock.lockSuffix))

        // Regression guard for the expensive mistake: locking the shared-memory
        // file itself would mean "one Host per device", not "one Host per user".
        XCTAssertNotEqual(
            firstPath,
            PathManager.sharedMemoryPath(uid: "501"),
            "the instance lock must not be the shared-memory path"
        )

        // Two per-UID sandbox paths standing in for two users.
        let userA = "\(sandbox.path)/user-a.lock"
        let userB = "\(sandbox.path)/user-b.lock"

        let holder = try launchChild(mode: "hold", path: userA, holdMS: 1_200)
        XCTAssertTrue(waitUntil { HostInstanceLock.isHeld(path: userA) })

        let other = HostInstanceLock(path: userB)
        XCTAssertEqual(other.acquire(), .acquired, "a different user's lock must be available")
        other.release()

        XCTAssertEqual(finish(holder).status, 0)
    }

    // MARK: - 4. Re-acquisition after a normal exit

    func testLockIsAcquirableAfterNormalExit() throws {
        let first = finish(try launchChild(mode: "hold", path: lockPath, holdMS: 50))
        XCTAssertEqual(first.status, 0, "holder output: \(first.output)")
        XCTAssertTrue(first.output.contains("released"), "a normal exit must release before closing")

        let next = HostInstanceLock(path: lockPath)
        XCTAssertEqual(next.acquire(), .acquired, "a clean restart must be able to take the lock")
        next.release()
    }

    // MARK: - 5. Re-acquisition after an exit that skipped cleanup

    /// `_exit()` runs no cleanup code at all — no `LOCK_UN`, no `close`. The lock
    /// must still be free, because it belongs to the process, not to our code.
    func testLockIsAcquirableAfterExitWithoutCleanup() throws {
        let result = finish(try launchChild(mode: "hold-no-cleanup", path: lockPath, holdMS: 50))
        XCTAssertEqual(result.status, 0, "child output: \(result.output)")
        XCTAssertTrue(result.output.contains("acquired"))

        XCTAssertFalse(HostInstanceLock.isHeld(path: lockPath), "no process holds the lock now")

        let next = HostInstanceLock(path: lockPath)
        XCTAssertEqual(next.acquire(), .acquired)
        next.release()
    }

    // MARK: - 6. SIGKILL from outside

    /// The strongest form of "crash": the process is killed by a signal it cannot
    /// handle, so nothing in the program runs. If the lock were released by a
    /// deinit or a handler, this test would hang the next Host forever.
    func testSIGKILLReleasesTheLock() throws {
        let victim = try launchChild(mode: "hold", path: lockPath, holdMS: 10_000)
        XCTAssertTrue(
            waitUntil { HostInstanceLock.isHeld(path: self.lockPath) },
            "the victim never acquired the lock"
        )

        XCTAssertEqual(kill(victim.processIdentifier, SIGKILL), 0, "could not signal the test child")

        let result = finish(victim)
        XCTAssertEqual(result.reason, .uncaughtSignal, "expected an uncaught-signal death")
        XCTAssertEqual(result.status, SIGKILL)

        XCTAssertFalse(HostInstanceLock.isHeld(path: lockPath), "SIGKILL must free the lock with no cleanup code")

        let next = HostInstanceLock(path: lockPath)
        XCTAssertEqual(next.acquire(), .acquired, "the host must be restartable after a SIGKILL")
        next.release()
    }

    // MARK: - 7. A refused instance creates no shared memory

    /// Mirrors `main()`'s ordering: gate first, shared memory only after the gate
    /// says proceed. The refused path must leave the directory exactly as it was.
    func testRefusedInstanceCreatesNoSharedMemory() throws {
        let deviceUID = "test-\(UUID().uuidString)"
        let manager = SharedMemoryManager { uid in "\(self.sandbox.path)/soundbridge-\(uid)" }

        let holder = try launchChild(mode: "hold", path: lockPath, holdMS: 1_500)
        XCTAssertTrue(waitUntil { HostInstanceLock.isHeld(path: self.lockPath) })
        let before = entriesInSandbox

        let gate = HostStartupGate(lock: HostInstanceLock(path: lockPath))
        let decision = gate.evaluate()
        var createdOrigin: SharedMemoryOrigin?
        if case .proceed = decision {
            createdOrigin = manager.createMemory(for: deviceUID, persistence: EmptyPersistence())
            XCTFail("the gate let a second instance through")
        }

        XCTAssertNil(createdOrigin, "a refused instance must not create a mapping")
        XCTAssertNil(manager.getMemory(for: deviceUID), "no in-process mapping may exist after a refusal")
        XCTAssertEqual(entriesInSandbox, before, "a refused instance must not create any file")

        XCTAssertEqual(finish(holder).status, 0)
    }

    // MARK: - 8. A refused instance deletes no existing shared memory

    /// The expensive failure: a second Host deciding the existing file is "stale"
    /// and unlinking it, which silently detaches the driver from a working Host.
    func testRefusedInstanceDeletesNoExistingSharedMemory() throws {
        let deviceUID = "test-\(UUID().uuidString)"
        let mappingPath = "\(sandbox.path)/soundbridge-\(deviceUID)"
        try writeValidMapping(at: mappingPath, volume: 0.61)

        var before = stat()
        XCTAssertEqual(lstat(mappingPath, &before), 0)
        XCTAssertEqual(Int(before.st_size), expectedFileSize)

        let holder = try launchChild(mode: "hold", path: lockPath, holdMS: 1_500)
        XCTAssertTrue(waitUntil { HostInstanceLock.isHeld(path: self.lockPath) })

        let gate = HostStartupGate(lock: HostInstanceLock(path: lockPath))
        switch gate.evaluate() {
        case .proceed:
            XCTFail("the gate let a second instance through")
        case .refuseInstanceConflict, .refuseLockFailure:
            break
        }

        var after = stat()
        XCTAssertEqual(lstat(mappingPath, &after), 0, "the existing mapping must survive a refusal")
        XCTAssertEqual(Int(after.st_size), expectedFileSize, "the mapping must not be resized")
        XCTAssertEqual(after.st_ino, before.st_ino, "the mapping must not be replaced by a new inode")

        // And it must still be a valid, committed mapping.
        let fd = open(mappingPath, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let mapped = mmap(nil, MemoryLayout<RFSharedAudio>.size, PROT_READ, MAP_SHARED, fd, 0)
        XCTAssertNotEqual(mapped, MAP_FAILED)
        defer { munmap(mapped, MemoryLayout<RFSharedAudio>.size) }
        let mem = mapped!.assumingMemoryBound(to: RFSharedAudio.self)
        XCTAssertEqual(rf_validate_header(mem), RF_VALIDATE_OK)
        var snapshot = RFVolumeStateSnapshot()
        XCTAssertTrue(rf_read_volume_state(mem, &snapshot))
        XCTAssertEqual(snapshot.scalar, 0.61, accuracy: 0.0001, "the committed volume must be untouched")

        XCTAssertEqual(finish(holder).status, 0)
    }

    // MARK: - 9. N processes racing for one lock

    /// Eight children call `flock(LOCK_EX|LOCK_NB)` at the same instant. Exactly
    /// one may win. Anything else means the guard is a check-then-act, which is
    /// what `pgrep` was.
    func testConcurrentProcessesElectExactlyOneOwner() throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let start = now + 800

        var children: [Process] = []
        for _ in 0..<8 {
            children.append(try launchChild(mode: "hold", path: lockPath, holdMS: 900, startMS: start))
        }
        let results = children.map { finish($0) }

        let winners = results.filter { $0.status == 0 }
        let refused = results.filter { $0.status == HostExitCode.instanceConflict }
        XCTAssertEqual(
            winners.count,
            1,
            "exactly one process may hold the lock, got statuses \(results.map(\.status))"
        )
        XCTAssertEqual(refused.count, 7, "the losers must report contention, got \(results.map(\.status))")

        XCTAssertFalse(HostInstanceLock.isHeld(path: lockPath), "the race must not leave the lock held")

        let next = HostInstanceLock(path: lockPath)
        XCTAssertEqual(next.acquire(), .acquired, "the lock must be usable after the race")
        next.release()
    }

    // MARK: - 10. A leftover lock file does not block startup

    /// The file is never unlinked, so it survives reboots and crashes by design.
    /// If its mere existence were the lock, that design would be a startup bug.
    func testLeftoverLockFileDoesNotBlockStartup() throws {
        // Case A: an empty leftover file.
        FileManager.default.createFile(atPath: lockPath, contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath))
        XCTAssertFalse(HostInstanceLock.isHeld(path: lockPath), "an unheld flock is not a held lock")

        let first = HostInstanceLock(path: lockPath)
        XCTAssertEqual(first.acquire(), .acquired, "a leftover file must not block startup")
        first.release()

        // Case B: a leftover file full of stale owner text — what a SIGKILLed
        // Host leaves behind. Truncating it is not required for acquisition.
        try "pid=99999 uid=501 since=yesterday\n".write(toFile: lockPath, atomically: true, encoding: .utf8)
        let second = HostInstanceLock(path: lockPath)
        XCTAssertEqual(second.acquire(), .acquired, "stale owner text must not block startup")
        XCTAssertTrue(HostInstanceLock.isHeld(path: lockPath), "the new owner must be visible to a probe")
        second.release()

        // Case C: a fresh process still gets the lock afterwards.
        XCTAssertEqual(finish(try launchChild(mode: "hold", path: lockPath, holdMS: 50)).status, 0)
    }

    // MARK: - Child program

    /// Modes:
    ///
    /// - `hold`: acquire, hold, release, exit 0. Exit 3 on contention.
    /// - `hold-no-cleanup`: acquire, hold, `_exit(0)` — no `LOCK_UN`, no `close`.
    /// - `hold-sigkill`: acquire, hold, then SIGKILL itself.
    /// - `probe`: try to acquire and report without keeping it (`probe-free`
    ///   exit 0, `probe-held` exit 3, `probe-absent` exit 2).
    private static let childSource = """
    #include <errno.h>
    #include <fcntl.h>
    #include <signal.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/file.h>
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
        if (argc < 3) {
            fprintf(stderr, "usage: %s <mode> <path> [hold_ms] [start_ms]\\n", argv[0]);
            return 64;
        }
        const char *mode = argv[1];
        const char *path = argv[2];
        long long hold_ms = argc > 3 ? atoll(argv[3]) : 0;
        long long start_ms = argc > 4 ? atoll(argv[4]) : 0;

        if (strcmp(mode, "probe") == 0) {
            int pfd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
            if (pfd < 0) {
                printf("probe-absent errno=%d\\n", errno);
                return 2;
            }
            if (flock(pfd, LOCK_EX | LOCK_NB) != 0) {
                printf("probe-held errno=%d\\n", errno);
                close(pfd);
                return 3;
            }
            flock(pfd, LOCK_UN);
            close(pfd);
            printf("probe-free\\n");
            return 0;
        }

        /* Same flags as HostInstanceLock: no O_EXCL, an existing file is normal. */
        int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0644);
        if (fd < 0) {
            printf("open-failed errno=%d (%s)\\n", errno, strerror(errno));
            return 4;
        }

        wait_until(start_ms);

        if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
            printf("held errno=%d\\n", errno);
            close(fd);
            return 3;
        }

        printf("acquired pid=%d\\n", (int)getpid());
        fflush(stdout);

        /* Same owner record HostInstanceLock writes, so the diagnostic path is
           exercised across a real process boundary. */
        {
            char record[160];
            int len = snprintf(record, sizeof record, "pid=%d uid=%d since=child\\n",
                               (int)getpid(), (int)getuid());
            if (len > 0) {
                ftruncate(fd, 0);
                pwrite(fd, record, (size_t)len, 0);
            }
        }

        sleep_ms(hold_ms);

        if (strcmp(mode, "hold-no-cleanup") == 0) {
            _exit(0);
        }
        if (strcmp(mode, "hold-sigkill") == 0) {
            kill(getpid(), SIGKILL);
            sleep_ms(1000);
            return 70;
        }

        flock(fd, LOCK_UN);
        close(fd);
        printf("released\\n");
        return 0;
    }
    """
}

// MARK: - Test doubles

/// A persistence stub that never has anything. Declared here rather than shared
/// so this file cannot be broken by changes to another suite's fixture.
private final class EmptyPersistence: VolumeStatePersisting {
    func loadIfPresent(uid: String) -> DeviceVolumeState? { nil }
    func save(uid: String, volume: Float, muted: Bool) {}
}
