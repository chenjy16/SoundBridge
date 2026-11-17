import XCTest
@testable import SoundBridgeHost

// MARK: - Startup failure paths must tear down (Phase 2.1.5-B4)
//
// `main()` can end in three different ways that all call `exit()`:
//
//   * the single-instance gate refuses to start,
//   * startup hits a condition it cannot continue from,
//   * SIGINT / SIGTERM.
//
// The first one is the odd one out. At that point the process owns nothing —
// the shared memory it would unlink belongs to the Host that is already running,
// and unlinking it would sabotage a healthy instance. Every other exit owns
// resources: a mapping (possibly partial), a heartbeat timer, a claimed instance
// lock, and — after `autoSelectProxy()` — the **system default output device**.
//
// That last one is not theoretical. `autoSelectProxy()` switches the default
// output to the proxy device before the audio engine is set up, so an
// `exit(1)` that skips teardown leaves the Mac pointing at a virtual device whose
// Host has just died: the user loses all audio and nothing in the app explains
// why. This test is the reason that cannot be reintroduced silently.
//
// Source-level by necessity: these are process-exit paths, and running them
// would mean actually killing a Host. Evidence level: L1 (structural).

final class StartupFailureCleanupTests: XCTestCase {

    /// Distance, in lines, within which a `cleanup()` call is considered to be
    /// part of the same exit path. Wide enough for a short comment, narrow
    /// enough that an unrelated `cleanup()` elsewhere in `main()` cannot satisfy
    /// the assertion.
    private let window = 8

    private func mainSourceLines() throws -> [String] {
        // packages/host/Tests/SoundBridgeHostTests/<this file>
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoundBridgeHostTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // packages/host
        let main = packageRoot.appendingPathComponent("Sources/SoundBridgeHost/main.swift")
        let text = try String(contentsOf: main, encoding: .utf8)
        return text.components(separatedBy: .newlines)
    }

    private func preceding(_ lines: [String], upTo index: Int) -> [String] {
        let start = max(0, index - window)
        return Array(lines[start..<index])
    }

    func testEveryFatalExitRunsCleanupFirst() throws {
        let lines = try mainSourceLines()

        var checked = 0
        for (index, line) in lines.enumerated() where line.contains("exit(") {
            // The single-instance refusals deliberately do NOT clean up.
            guard !line.contains("HostExitCode.") else { continue }

            checked += 1
            let context = preceding(lines, upTo: index)
            XCTAssertTrue(
                context.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("cleanup()") }),
                "exit at line \(index + 1) must run cleanup() first: \(line.trimmingCharacters(in: .whitespaces))"
            )
        }

        XCTAssertGreaterThanOrEqual(checked, 5, "expected the fatal, degraded and signal exit paths to be found")
    }

    func testInstanceLockRefusalsDoNotTearDownAnotherHost() throws {
        let lines = try mainSourceLines()

        var checked = 0
        for (index, line) in lines.enumerated() where line.contains("HostExitCode.") {
            checked += 1
            let context = preceding(lines, upTo: index)
            XCTAssertFalse(
                context.contains(where: { $0.contains("cleanup()") }),
                "the refusal at line \(index + 1) must not touch resources it does not own"
            )
        }

        XCTAssertEqual(checked, 2, "both single-instance refusals are expected to be present")
    }

    /// The failure branch that used to silence the machine: routing has already
    /// happened when the engine fails, so the restore step is mandatory.
    func testEngineFailureExitIsReachableOnlyAfterRouting() throws {
        let lines = try mainSourceLines()
        let source = lines.joined(separator: "\n")

        let route = try XCTUnwrap(source.range(of: "let selection = proxyManager.autoSelectProxy()"))
        let engine = try XCTUnwrap(source.range(of: "try audioEngine.setup(devices: devices, preferredDeviceID:"))
        XCTAssertLessThan(
            source.distance(from: route.lowerBound, to: engine.lowerBound), 2_000,
            "the engine setup is expected to follow routing in main(); if this moved, re-check that teardown still restores the device"
        )
    }
}
