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
// resources: a mapping (possibly partial), a heartbeat timer and a claimed
// instance lock.
//
// P2 Batch 2 removed the fourth one. The old `autoSelectProxy()` made the proxy
// device the system default output *before* the audio engine was set up, so an
// `exit(1)` that skipped teardown left the Mac pointing at a virtual device
// whose Host had just died — the user lost all audio and nothing in the app
// explained why. Routing no longer writes the default output at all, so there is
// nothing to restore and no state to leak on a failed start. These tests keep
// both facts: the teardown is still mandatory, and startup no longer changes a
// system-wide setting it would have to put back.
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

    /// Routing still precedes the engine setup, and — since P2 Batch 2 — it no
    /// longer changes the default output, so the engine-failure exit has nothing
    /// to restore.
    func testEngineFailureExitIsReachableOnlyAfterRouting() throws {
        let lines = try mainSourceLines()
        let source = lines.joined(separator: "\n")

        let route = try XCTUnwrap(source.range(of: "proxyManager.resolveProxyRouting(forPhysicalUID:"))
        let engine = try XCTUnwrap(source.range(of: "try audioEngine.setup(devices: devices, preferredDeviceID:"))
        XCTAssertLessThan(
            source.distance(from: route.lowerBound, to: engine.lowerBound), 2_000,
            "the engine setup is expected to follow routing in main(); if this moved, re-check the degraded path"
        )
    }

    /// The failure branch that used to put the default output back.
    ///
    /// It cannot come back by accident: `autoSelectProxy` is gone, and the only
    /// default-output write in the Host is the unreferenced HAL member.
    func testFailedStartupHasNoDefaultOutputToRestore() throws {
        let source = try mainSourceLines().joined(separator: "\n")

        XCTAssertFalse(source.contains("autoSelectProxy("),
                       "startup must not select the proxy as the default output")
        XCTAssertFalse(source.contains("setDefaultOutput("),
                       "main.swift must not write the default output, on a failure path or any other")
        XCTAssertTrue(source.contains("Host never made the proxy the default output"),
                      "the failure branches are expected to say why there is nothing to restore")
    }
}
