import XCTest
import Darwin
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - L3: admission gateway across real processes
//
// `AdmissionGatewayTests` runs threads inside one process. Threads share a
// mapping and the same `mmap`, so they cannot show what happens when two
// *processes* claim the same owner slot: the atomics live in shared memory and
// only a second address space proves the CAS is visible on both sides.
//
// Every test here spawns real child processes running a C program compiled at
// test time from the same `RFSharedAudio.h`. Scope, stated plainly: this is
// "the L3 cross-process behaviour observed on this machine", not a proof about
// every macOS build, CPU or future kernel.

final class AdmissionCrossProcessTests: XCTestCase {

    private struct HelperResult {
        let status: Int32
        let output: String
    }

    private static var helperBinary: String?
    private static var helperDirectory: URL?
    private static var compileFailure: String?

    private var sandbox: URL!
    private var mappings: [(raw: UnsafeMutableRawPointer, size: Int)] = []
    private var lastPath: String!

    private let sampleRate: UInt32 = 48000
    private let channels: UInt32 = 2
    private let durationMs: UInt32 = 100
    private let epochA: UInt64 = 0x0BAD_C0DE_0000_0001
    private let epochB: UInt64 = 0x0BAD_C0DE_0000_0002
    private let tokenA: UInt64 = 0x0000_01F5_0000_1001
    private let tokenB: UInt64 = 0x0000_01F5_0000_1003

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
            compileFailure = "clang not found; skipping cross-process admission tests"
            return
        }
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeAdmissionL3-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            compileFailure = "could not create harness directory: \(error)"
            return
        }
        helperDirectory = workDir

        let sourceURL = workDir.appendingPathComponent("admission_child.c")
        let binaryURL = workDir.appendingPathComponent("admission_child")
        do {
            try Self.childSource.write(to: sourceURL, atomically: true, encoding: .utf8)
        } catch {
            compileFailure = "could not write child source: \(error)"
            return
        }

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = ["-O1", "-std=c11", "-Wall", "-I", includeDir,
                             sourceURL.path, "-o", binaryURL.path]
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
            .appendingPathComponent("SoundBridgeAdmissionL3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for mapping in mappings {
            munmap(mapping.raw, mapping.size)
        }
        mappings.removeAll()
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        lastPath = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private var fileSize: Int {
        let frames = rf_ring_capacity_frames_for(sampleRate, durationMs)
        return Int(rf_shared_audio_size(frames, channels, 4))
    }

    /// Creates, sizes and maps a real shared-memory file, then runs `init` —
    /// exactly the sequence `SharedMemoryManager.createMemory` performs, minus
    /// the rename (the file is already at its final path in the sandbox).
    @discardableResult
    private func createMapping(openEpoch: UInt64? = nil,
                              initialize: Bool = true) throws -> UnsafeMutablePointer<RFSharedAudio> {
        let path = "\(sandbox.path)/sb-\(UUID().uuidString).shm"
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw XCTSkip("open failed: \(String(cString: strerror(errno)))")
        }
        XCTAssertEqual(ftruncate(fd, off_t(fileSize)), 0)
        let raw = mmap(nil, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        close(fd)
        guard raw != MAP_FAILED else {
            throw XCTSkip("mmap failed: \(String(cString: strerror(errno)))")
        }
        mappings.append((raw!, fileSize))
        lastPath = path
        let mem = raw!.assumingMemoryBound(to: RFSharedAudio.self)
        if initialize {
            rf_shared_audio_init(mem, sampleRate, channels, RF_FORMAT_FLOAT32, durationMs)
        }
        if let epoch = openEpoch {
            XCTAssertEqual(rf_admission_open(mem, epoch), RF_ADMISSION_OK)
        }
        return mem
    }

    private func launch(_ arguments: [String]) throws -> (process: Process, pipe: Pipe) {
        guard let binary = Self.helperBinary else {
            throw XCTSkip("cross-process helper unavailable")
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

    private func finish(_ launched: (process: Process, pipe: Pipe)) throws -> HelperResult {
        launched.process.waitUntilExit()
        let data = launched.pipe.fileHandleForReading.readDataToEndOfFile()
        return HelperResult(status: launched.process.terminationStatus,
                            output: String(data: data, encoding: .utf8) ?? "")
    }

    private func run(_ arguments: [String]) throws -> HelperResult {
        try finish(try launch(arguments))
    }

    // MARK: - 1. Two independent processes racing for one owner slot

    func testEightProcessesRaceToClaimAndExactlyOneWins() throws {
        let mem = try createMapping(openEpoch: epochA)
        let goFile = "\(sandbox.path)/go"

        var launched: [(process: Process, pipe: Pipe)] = []
        var tokens: [UInt64] = []
        for i in 0..<8 {
            let token = tokenA + UInt64(i) * 2
            tokens.append(token)
            launched.append(try launch(["claim", lastPath, String(token, radix: 16), goFile]))
        }
        XCTAssertEqual(FileManager.default.createFile(atPath: goFile, contents: Data()), true)

        let results = launched.map { try! finish($0) }
        let winners = results.filter { $0.status == 0 }
        XCTAssertEqual(winners.count, 1, "exactly one process may own the mapping, got \(results.map(\.status))")
        XCTAssertTrue(winners.first!.output.contains("claim=1"))

        let owner = rf_producer_owner_token(mem)
        XCTAssertTrue(tokens.contains(owner), "the surviving owner must be one of the contenders")
        XCTAssertEqual(rf_admission_state(mem), RF_ADMISSION_OPEN)
        XCTAssertEqual(rf_admission_epoch(mem), epochA)
        XCTAssertEqual(rf_admission_claim_seq(mem), 1, "one successful claim, seen from the parent too")
    }

    // MARK: - 2. Owner dies without releasing

    func testOwnerThatDiesWithoutReleasingBlocksTakeover() throws {
        let mem = try createMapping(openEpoch: epochA)

        let crashed = try run(["claim_hold", lastPath, String(tokenA, radix: 16), "150"])
        XCTAssertEqual(crashed.status, 0, "owner should claim before dying: \(crashed.output)")
        XCTAssertEqual(rf_producer_owner_token(mem), tokenA, "the crashed owner's record is preserved")

        let successor = try run(["claim", lastPath, String(tokenB, radix: 16)])
        XCTAssertEqual(successor.status, 1, "no automatic takeover: the old callback cannot be proven gone")
        XCTAssertTrue(successor.output.contains("claim=0"))
        XCTAssertEqual(rf_producer_owner_token(mem), tokenA, "the stale owner is not replaced")

        // And the stale owner cannot write into a closed mapping either.
        XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
        let stale = try run(["write", lastPath, String(tokenA, radix: 16),
                             String(epochA, radix: 16), "8"])
        XCTAssertTrue(stale.output.contains("written=0"), "closing admission stops the stale producer: \(stale.output)")
        XCTAssertEqual(rf_ring_write_index(mem), 0)
    }

    // MARK: - 3. Clean release

    func testCleanReleaseLetsTheNextProcessClaim() throws {
        let mem = try createMapping(openEpoch: epochA)

        let first = try run(["claim_release", lastPath, String(tokenA, radix: 16)])
        XCTAssertEqual(first.status, 0, "\(first.output)")
        XCTAssertTrue(first.output.contains("claim=1"))
        XCTAssertTrue(first.output.contains("release=1"))
        XCTAssertEqual(rf_producer_owner_token(mem), 0, "a clean release empties the slot for the next owner")

        let second = try run(["claim", lastPath, String(tokenB, radix: 16)])
        XCTAssertEqual(second.status, 0, "\(second.output)")
        XCTAssertEqual(rf_producer_owner_token(mem), tokenB)
        XCTAssertEqual(rf_admission_claim_seq(mem), 2)
    }

    // MARK: - 4. State visibility across the process boundary

    func testAdmissionStateIsVisibleAcrossProcesses() throws {
        let mem = try createMapping(openEpoch: epochA)

        var report = try run(["report", lastPath])
        XCTAssertEqual(report.status, 0, "\(report.output)")
        XCTAssertTrue(report.output.contains("validate=0"), "\(report.output)")
        XCTAssertTrue(report.output.contains("state=\(RF_ADMISSION_OPEN)"), "\(report.output)")
        XCTAssertTrue(report.output.contains("epoch=\(String(epochA, radix: 16))"), "\(report.output)")

        XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)

        report = try run(["report", lastPath])
        XCTAssertTrue(report.output.contains("state=\(RF_ADMISSION_CLOSING)"),
                      "the child must observe the parent's CLOSING immediately: \(report.output)")

        let refused = try run(["claim", lastPath, String(tokenA, radix: 16)])
        XCTAssertEqual(refused.status, 1, "a CLOSING mapping admits no producer: \(refused.output)")

        XCTAssertEqual(rf_admission_finalize_close(mem), RF_ADMISSION_OK)
        report = try run(["report", lastPath])
        XCTAssertTrue(report.output.contains("state=\(RF_ADMISSION_CLOSED)"), "\(report.output)")
    }

    // MARK: - 5. Writes are refused across the boundary, ring untouched

    func testClosedMappingRefusesWritesFromAnotherProcess() throws {
        let mem = try createMapping(openEpoch: epochA)
        XCTAssertEqual(try run(["claim", lastPath, String(tokenA, radix: 16)]).status, 0)

        // Open + owned: the child's frames land.
        var result = try run(["write", lastPath, String(tokenA, radix: 16),
                              String(epochA, radix: 16), "32"])
        XCTAssertTrue(result.output.contains("written=32"), "\(result.output)")

        XCTAssertEqual(rf_admission_begin_close(mem), RF_ADMISSION_OK)
        let wBefore = rf_ring_write_index(mem)

        result = try run(["write", lastPath, String(tokenA, radix: 16),
                          String(epochA, radix: 16), "32"])
        XCTAssertTrue(result.output.contains("written=0"), "CLOSING must refuse the write: \(result.output)")
        XCTAssertTrue(result.output.contains("dropped=32"), "\(result.output)")
        XCTAssertEqual(rf_ring_write_index(mem), wBefore, "a refused write never advances W")
        XCTAssertEqual(rf_ring_read_index(mem), 0, "and never touches R")
    }

    // MARK: - 6. Epoch binds the owner to its incarnation

    func testEpochMismatchBlocksWritesAcrossProcesses() throws {
        let mem = try createMapping(openEpoch: epochA)
        XCTAssertEqual(try run(["claim", lastPath, String(tokenA, radix: 16)]).status, 0)

        var result = try run(["write", lastPath, String(tokenA, radix: 16),
                              String(epochB, radix: 16), "16"])
        XCTAssertTrue(result.output.contains("written=0"),
                      "a token claimed under another incarnation must not write: \(result.output)")
        XCTAssertEqual(rf_ring_write_index(mem), 0)

        result = try run(["write", lastPath, String(tokenA, radix: 16),
                          String(epochA, radix: 16), "16"])
        XCTAssertTrue(result.output.contains("written=16"), "\(result.output)")
    }

    // MARK: - 7. Fail-closed on partial / foreign headers

    func testUninitializedHeaderIsRefusedByAnotherProcess() throws {
        // Sized but never initialized: the protocol fields are still zero.
        try createMapping(initialize: false)
        let result = try run(["report", lastPath])
        XCTAssertEqual(result.status, 0, "\(result.output)")
        XCTAssertTrue(result.output.contains("validate=\(RF_VALIDATE_PROTOCOL_VERSION.rawValue)"),
                      "an uninitialized header must be refused, not half-trusted: \(result.output)")
        XCTAssertTrue(result.output.contains("state=0"), "and it reads as CLOSED, never OPEN: \(result.output)")
    }

    func testPartiallyInitializedAdmissionIsRefused() throws {
        let mem = try createMapping(openEpoch: epochA)
        // A writer that stopped half-way leaves an undefined state value.
        UnsafeMutableRawPointer(mem).storeBytes(of: UInt32(99), toByteOffset: 256, as: UInt32.self)

        let result = try run(["report", lastPath])
        XCTAssertTrue(result.output.contains("validate=\(RF_VALIDATE_ADMISSION.rawValue)"),
                      "unknown admission state must fail closed: \(result.output)")

        let claim = try run(["claim", lastPath, String(tokenA, radix: 16)])
        XCTAssertEqual(claim.status, 3, "and no producer may claim it: \(claim.output)")
    }

    func testVersionMismatchIsRefusedByAnotherProcess() throws {
        let mem = try createMapping(openEpoch: epochA)
        mem.pointee.protocol_version = 0x0002_0100  // Batch 1 layout

        let result = try run(["report", lastPath])
        XCTAssertTrue(result.output.contains("validate=\(RF_VALIDATE_PROTOCOL_VERSION.rawValue)"),
                      "old protocol must never be mistaken for the new one: \(result.output)")

        let claim = try run(["claim", lastPath, String(tokenA, radix: 16)])
        XCTAssertEqual(claim.status, 3, "a version-mismatched mapping is never claimed: \(claim.output)")
        XCTAssertEqual(rf_producer_owner_token(mem), 0)
    }

    // MARK: - 8. Environment record (printed into the test log)

    func testRecordEnvironmentForThisRun() {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        print("[L3] macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) \(arch), "
              + "processes per race=8, protocol=0x\(String(RF_AUDIO_PROTOCOL_VERSION, radix: 16)), "
              + "header=\(RF_SHARED_AUDIO_HEADER_SIZE) bytes")
        XCTAssertEqual(RF_SHARED_AUDIO_HEADER_SIZE, 320)
    }

    // MARK: - C helper

    private static let childSource = #"""
    #include <fcntl.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/mman.h>
    #include <sys/stat.h>
    #include <unistd.h>

    #include "RFSharedAudio.h"

    static RFSharedAudio *map_file(const char *path, struct stat *st) {
        int fd = open(path, O_RDWR);
        if (fd < 0) { perror("open"); return NULL; }
        if (fstat(fd, st) != 0) { perror("fstat"); close(fd); return NULL; }
        RFSharedAudio *mem = mmap(NULL, (size_t)st->st_size,
                                  PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (mem == MAP_FAILED) { perror("mmap"); return NULL; }
        return mem;
    }

    int main(int argc, char **argv) {
        if (argc < 3) return 2;
        const char *mode = argv[1];
        const char *path = argv[2];
        struct stat st;
        RFSharedAudio *mem = map_file(path, &st);
        if (mem == NULL) return 3;

        if (strcmp(mode, "report") == 0) {
            printf("state=%u epoch=%llx owner=%llx seq=%llu validate=%d\n",
                   rf_admission_state(mem),
                   (unsigned long long)rf_admission_epoch(mem),
                   (unsigned long long)rf_producer_owner_token(mem),
                   (unsigned long long)rf_admission_claim_seq(mem),
                   (int)rf_validate_header(mem));
            return 0;
        }

        if (strcmp(mode, "claim") == 0 || strcmp(mode, "claim_hold") == 0) {
            if (argc < 4) return 4;
            /* Mirror the driver: ValidateConnection runs before the admission
               claim, so a foreign or half-initialized header is never claimed. */
            const int valid = (int)rf_validate_header(mem);
            if (valid != 0) {
                printf("validate=%d refused\n", valid);
                return 3;
            }
            const uint64_t token = strtoull(argv[3], NULL, 16);
            /* Optional start barrier: spin until the parent creates the go file,
               so every contender reaches the claim within microseconds. */
            if (argc > (strcmp(mode, "claim") == 0 ? 4 : 5)) {
                const char *go = argv[argc - 1];
                while (access(go, F_OK) != 0) usleep(200);
            }
            const int ok = rf_producer_claim(mem, token);
            printf("claim=%d state=%u owner=%llx epoch=%llx\n", ok,
                   rf_admission_state(mem),
                   (unsigned long long)rf_producer_owner_token(mem),
                   (unsigned long long)rf_admission_epoch(mem));
            fflush(stdout);
            if (strcmp(mode, "claim_hold") == 0) {
                const int hold_ms = (argc > 4) ? atoi(argv[4]) : 0;
                if (hold_ms > 0) usleep((useconds_t)hold_ms * 1000);
                /* Exit WITHOUT releasing: this is the crashed-owner shape. */
            }
            return ok ? 0 : 1;
        }

        if (strcmp(mode, "claim_release") == 0) {
            if (argc < 4) return 4;
            const uint64_t token = strtoull(argv[3], NULL, 16);
            const int claimed = rf_producer_claim(mem, token);
            const int released = claimed ? rf_producer_release(mem, token) : 0;
            printf("claim=%d release=%d owner=%llx\n", claimed, released,
                   (unsigned long long)rf_producer_owner_token(mem));
            return claimed ? 0 : 1;
        }

        if (strcmp(mode, "write") == 0) {
            if (argc < 6) return 4;
            const uint64_t token = strtoull(argv[3], NULL, 16);
            const uint64_t epoch = strtoull(argv[4], NULL, 16);
            const uint32_t frames = (uint32_t)atoi(argv[5]);
            const uint32_t channels = mem->channels;
            float *buf = (float *)calloc((size_t)frames * channels, sizeof(float));
            if (buf == NULL) return 5;
            for (uint32_t i = 0; i < frames * channels; ++i) buf[i] = 1.0f;
            uint32_t dropped = 0;
            const uint32_t written = rf_ring_write(mem, buf, frames, token, epoch, &dropped);
            printf("written=%u dropped=%u w=%llu r=%llu\n", written, dropped,
                   (unsigned long long)rf_ring_write_index(mem),
                   (unsigned long long)rf_ring_read_index(mem));
            free(buf);
            return written == frames ? 0 : 1;
        }

        fprintf(stderr, "unknown mode %s\n", mode);
        return 6;
    }
    """#
}
