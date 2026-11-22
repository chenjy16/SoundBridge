import XCTest
@testable import SoundBridgeApp

/// The uninstaller's invariants, asserted on the source.
///
/// `tools/test_uninstall_lifecycle.sh` runs the script against disposable
/// sandboxes: removal, idempotence, refusal of anything that is not ours, Host
/// termination with a bounded wait and an escalation against the same pid, IPC
/// scope, failure reporting, and the things it must leave alone. These tests
/// cover the claims that are stronger as text than as a run: the script removes
/// the bundle the app's policy removes, its manifest is the same manifest, and
/// nothing it can execute signals a system daemon or deletes user data.
///
/// Evidence level: L1. Files are read. Nothing is installed, removed, or
/// signalled, and no HAL directory is touched.
final class UninstallLifecycleScriptTests: XCTestCase {

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoundBridgeAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SoundBridgeApp
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // apps
            .deletingLastPathComponent()   // repository root
    }

    private static func text(_ relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw XCTSkip("\(relativePath) is not next to the app sources")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Lines the shell would execute. The header documents `killall coreaudiod`
    /// on purpose; only an executable line is a claim about behaviour.
    private static func executableLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
    }

    private func script() throws -> String {
        try Self.text("tools/uninstall_driver.sh")
    }

    // MARK: - 1. It removes what the app's policy removes

    func testTheScriptRemovesTheBundlesThePolicyNames() throws {
        let text = try script()
        XCTAssertTrue(text.contains(DriverUninstallPolicy.driverPath),
                      "the script must remove the path the app's policy removes")
        XCTAssertTrue(text.contains(DriverUninstallPolicy.expectedBundleIdentifier),
                      "the script must identify the bundle before removing it")
        XCTAssertTrue(text.contains("/bin/rm -rf '$DRIVER_PATH'"),
                      "the one privileged command must keep the policy's shape")
        XCTAssertEqual(
            "/bin/rm -rf '$DRIVER_PATH'".replacingOccurrences(
                of: "$DRIVER_PATH",
                with: DriverUninstallPolicy.driverPath
            ),
            DriverUninstallPolicy.removalCommand,
            "the script's default and the app's command must expand to the same string"
        )
    }

    func testIdentificationHappensBeforeAnythingIsStoppedOrRemoved() throws {
        let text = try script()
        let identify = try XCTUnwrap(text.range(of: "phase 1: identify"))
        let stop = try XCTUnwrap(text.range(of: "phase 2: stop"))
        let ipc = try XCTUnwrap(text.range(of: "phase 3: release"))
        let remove = try XCTUnwrap(text.range(of: "phase 4: remove"))
        XCTAssertLessThan(identify.lowerBound, stop.lowerBound)
        XCTAssertLessThan(stop.lowerBound, ipc.lowerBound)
        XCTAssertLessThan(ipc.lowerBound, remove.lowerBound)
    }

    func testTheDryRunCannotReachTheRemoval() throws {
        let text = try script()
        let dryRun = try XCTUnwrap(text.range(of: "Dry run: nothing was changed"))
        let call = try XCTUnwrap(text.range(of: "remove_driver || true"))
        XCTAssertLessThan(dryRun.lowerBound, call.lowerBound,
                          "the dry-run branch must end before the removal call")
    }

    // MARK: - 2. It reports four separate states and never claims more

    func testTheReportKeepsTheFourStatesSeparate() throws {
        let text = try script()
        XCTAssertTrue(text.contains("1. driver files removed from disk"))
        XCTAssertTrue(text.contains("2. driver unloaded from coreaudiod"))
        XCTAssertTrue(text.contains("3. CoreAudio device disappeared"))
        XCTAssertTrue(text.contains("4. coreaudiod restarted"))
        XCTAssertTrue(text.contains("no — coreaudiod keeps its loaded copy"),
                      "state 2 must be reported as not done, not implied")
        XCTAssertTrue(text.contains("this script never signals it"),
                      "state 4 must say the daemon was not restarted")
    }

    // MARK: - 3. Nothing executable signals a daemon or asks for privileges

    func testNoExecutableLineSignalsADaemonOrUsesSudo() throws {
        let dangerous = ["killall", "launchctl", "kextload", "kextunload", "pkill", "sudo"]
        let offenders = Self.executableLines(try script()).filter { line in
            dangerous.contains { line.contains($0) }
        }
        // The one permitted mention is the advice printed to the user. Anything
        // else is a command that would run.
        let unadvised = offenders.filter { !$0.contains("run this by hand") }
        XCTAssertTrue(unadvised.isEmpty, "a daemon signal or sudo is executable: \(unadvised)")
        XCTAssertEqual(offenders.count, 1,
                       "the only mention may be the printed advice, found: \(offenders)")
        XCTAssertFalse(DriverUninstallPolicy.restartsCoreAudio)
    }

    // MARK: - 4. What it keeps, it keeps on purpose

    func testUserStateLogsAndPreferencesAreListedAsKept() throws {
        let text = try script()
        for path in ["Application Support/SoundBridge", "Library/Logs/SoundBridge"] {
            let manifestLine = text
                .components(separatedBy: .newlines)
                .first { $0.contains(path) && $0.contains("kept") }
            XCTAssertNotNil(manifestLine, "\(path) must be in the manifest as kept")
        }
        XCTAssertTrue(text.contains("~/Library/Preferences/com.soundbridge.menubar.plist"),
                      "the preferences file is named so it cannot be removed by accident")
    }

    func testTheReceiptAndTheAppBundleAreReportedNotRemoved() throws {
        let text = try script()
        let lines = Self.executableLines(text)
        XCTAssertFalse(lines.contains { $0.contains("pkgutil") && $0.contains("--forget") },
                       "the receipt is reported; forgetting it would not unload anything")
        XCTAssertFalse(lines.contains { $0.contains("/bin/rm") && $0.contains("APP_PATH") },
                       "the app bundle is never removed by this script")
        XCTAssertTrue(text.contains("RECEIPT_ID=\"com.soundbridge.menubar\""),
                      "the receipt id is the package id the release tooling builds")
    }

    func testTheScriptIsExecutableAndTheSuiteIsWiredIntoMake() throws {
        let url = Self.repositoryRoot.appendingPathComponent("tools/uninstall_driver.sh")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw XCTSkip("tools/uninstall_driver.sh is not next to the app sources")
        }
        XCTAssertNotEqual(permissions.intValue & 0o111, 0,
                          "the uninstaller must stay runnable")

        let makefile = try Self.text("Makefile")
        XCTAssertTrue(makefile.contains("tools/test_uninstall_lifecycle.sh"),
                      "make test-installer must run the uninstall lifecycle suite")
    }
}
