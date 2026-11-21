import XCTest
import Foundation
@testable import SoundBridgeApp

// MARK: - Driver install and uninstall boundaries (P4 Batch 1A)
//
// Two claims about this build are claims about the source, not about a runtime
// mode, so they are asserted against the source:
//
//   1. the app does not install the driver — the release's `.pkg` is the only
//      thing that writes to /Library/Audio/Plug-Ins/HAL;
//   2. the app's uninstall is the same policy as tools/uninstall_driver.sh —
//      identify the bundle, remove one constant path, never restart coreaudiod.
//
// Every place that can reach a privileged command is enumerated, and anything
// new fails the test instead of shipping quietly.
//
// Evidence level: L1/L2. These tests read files and check policy constants. They
// deliberately do not launch the App, and nothing here installs, uninstalls or
// touches the HAL directory.

final class DriverInstallBoundaryTests: XCTestCase {

    private struct SourceFile {
        let relativePath: String
        /// Source lines with comment-only lines blanked out, so a doc comment that
        /// names a function is not mistaken for a call site. Line numbers survive.
        let code: [String]

        func occurrences(of needle: String) -> [String] {
            code.filter { $0.contains(needle) }
        }

        func contains(_ needle: String) -> Bool {
            !occurrences(of: needle).isEmpty
        }
    }

    private static var cachedSources: [SourceFile]?

    private var sources: [SourceFile] {
        get throws {
            if let cached = Self.cachedSources { return cached }
            let loaded = try Self.loadSources()
            Self.cachedSources = loaded
            return loaded
        }
    }

    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoundBridgeAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SoundBridgeApp
    }

    /// `Sources/` next to this test bundle's package root, derived from the test
    /// file's own path so the test works from any working directory.
    private static func loadSources() throws -> [SourceFile] {
        let sourcesRoot = appRoot.appendingPathComponent("Sources", isDirectory: true)

        guard let walker = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        ) else {
            throw XCTSkip("could not enumerate \(sourcesRoot.path)")
        }

        var files: [SourceFile] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text
                .components(separatedBy: .newlines)
                .map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("//") ? "" : line
                }
            let relative = url.path.replacingOccurrences(of: appRoot.path + "/", with: "")
            files.append(SourceFile(relativePath: relative, code: code))
        }

        XCTAssertFalse(files.isEmpty, "source scan found no files; the path derivation is wrong")
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// Files whose non-comment source contains `needle`, with the matching lines.
    private func filesContaining(_ needle: String) throws -> [(path: String, lines: [String])] {
        try sources.compactMap { file in
            let hits = file.occurrences(of: needle)
            return hits.isEmpty ? nil : (file.relativePath, hits)
        }
    }

    private func source(_ suffix: String) throws -> SourceFile {
        try XCTUnwrap(sources.first { $0.relativePath.hasSuffix(suffix) },
                      "no source file ends in \(suffix)")
    }

    // MARK: - 1. The app does not install the driver

    func testNoSourceCanInstallTheDriver() throws {
        // The installer transaction is the package's. Any of these in the app
        // would be a second implementation of it.
        for needle in [".installDriver(", "installDriverWithPrivileges", "DriverInstallState", "cp -R"] {
            let hits = try filesContaining(needle)
            XCTAssertTrue(hits.isEmpty,
                          "\(needle) is back in the app: \(hits.map(\.path))")
        }
    }

    func testOnboardingPointsAtTheInstallerPackage() throws {
        let onboarding = try source("OnboardingView.swift")

        XCTAssertTrue(onboarding.contains("DriverInstallGuide.action("),
                      "onboarding must ask the guide where the package is")
        XCTAssertTrue(onboarding.contains("Open Installer Package"),
                      "the only way to install is opening the package")
        XCTAssertFalse(onboarding.contains("NSAppleScript"),
                       "an admin script here would be the second install transaction again")
        XCTAssertFalse(onboarding.contains("killall"),
                       "onboarding must not restart any daemon")
    }

    func testOnboardingCompletionIsDecidedByTheVersionGate() throws {
        let onboarding = try source("OnboardingView.swift")

        // Success is read, never assumed: the page shows completion only for a
        // driver the gate calls compatible, and re-reads when it becomes active
        // again (which is what "returned from Installer" looks like).
        XCTAssertTrue(onboarding.contains("status?.isCompatible == true"),
                      "completion must hang off the gate, not off a click")
        XCTAssertTrue(onboarding.contains("isInstalledAndUsable"),
                      "the page must render from the gate's answer")
        XCTAssertTrue(onboarding.contains("didBecomeActiveNotification"),
                      "the page must re-check after Installer closes")
        XCTAssertTrue(onboarding.contains("installer.currentInstallStatus()"),
                      "the gate is the only input to the page's state")
    }

    // MARK: - 2. No in-app upgrade surface remains

    func testNothingOffersAnInAppUpgrade() throws {
        for needle in ["showDriverUpdatePrompt", "performDriverUpdate", "DriverUpdateWindow"] {
            let hits = try filesContaining(needle)
            XCTAssertTrue(hits.isEmpty,
                          "\(needle) still exists: \(hits.map(\.path))")
        }
    }

    // MARK: - 3. Privileged operations are enumerated

    func testExactlyOnePrivilegedCommandExists() throws {
        let hits = try filesContaining("with administrator privileges")

        XCTAssertEqual(hits.map(\.path).sorted(), ["Sources/Services/DriverUninstaller.swift"],
                       "a second privileged command needs its own review, not a passing test")
        XCTAssertEqual(hits.first?.lines.count, 1,
                       "the uninstaller should hold a single admin prompt")
    }

    func testTheAppNeverRestartsCoreAudio() throws {
        // The daemon is not the app's to restart: the loaded copy survives until
        // the next login, and cutting audio for every process is the user's
        // decision. `tools/uninstall_driver.sh` prints the same advice.
        let hits = try filesContaining("killall")
        XCTAssertTrue(hits.isEmpty, "killall is back in the app: \(hits.map(\.path))")
        XCTAssertFalse(DriverUninstallPolicy.restartsCoreAudio)
    }

    func testTheUninstallerOnlyRunsThePolicyCommand() throws {
        let uninstaller = try source("DriverUninstaller.swift")
        XCTAssertTrue(uninstaller.contains("DriverUninstallPolicy.removalCommand"),
                      "the privileged string must come from the policy, not be retyped")
        XCTAssertFalse(uninstaller.contains("/tmp/"),
                       "the uninstaller must not touch /tmp at all")
        XCTAssertFalse(uninstaller.contains("*"),
                       "no wildcard belongs in a removal command")

        let menuBar = try source("MenuBarView.swift")
        XCTAssertTrue(menuBar.contains("DriverUninstallPolicy.decide("),
                      "the app must decide with the shared policy")
        XCTAssertTrue(menuBar.contains("prepareForUninstall {"),
                      "the Host must be stopped before the driver is removed")
        XCTAssertFalse(menuBar.contains("FileManager.default.removeItem"),
                       "nothing outside the driver path may be deleted by a view")
    }

    // MARK: - 4. The app's policy is the script's policy

    func testUninstallPolicyRefusesWhatIsNotOurs() {
        typealias Identity = DriverUninstallPolicy.Identity

        XCTAssertEqual(
            DriverUninstallPolicy.decide(Identity(isPresent: true, isSymlink: true,
                                                  isDirectory: true,
                                                  bundleIdentifier: DriverBundleLocation.bundleIdentifier)),
            .refuse("the HAL path is a symlink, not a bundle"),
            "a symlink is never a bundle, even when it declares the right id"
        )
        XCTAssertEqual(
            DriverUninstallPolicy.decide(Identity(isPresent: false, isSymlink: false,
                                                  isDirectory: false, bundleIdentifier: nil)),
            .nothingToRemove
        )
        XCTAssertEqual(
            DriverUninstallPolicy.decide(Identity(isPresent: true, isSymlink: false,
                                                  isDirectory: false, bundleIdentifier: nil)),
            .refuse("the HAL path is a file, not a bundle")
        )
        XCTAssertEqual(
            DriverUninstallPolicy.decide(Identity(isPresent: true, isSymlink: false,
                                                  isDirectory: true, bundleIdentifier: nil)),
            .refuse("the bundle has no readable Info.plist")
        )
        XCTAssertEqual(
            DriverUninstallPolicy.decide(Identity(isPresent: true, isSymlink: false,
                                                  isDirectory: true, bundleIdentifier: "com.example.other")),
            .refuse("the HAL path declares 'com.example.other', not com.soundbridge.driver"),
            "another vendor's HAL bundle must be left alone"
        )
        XCTAssertEqual(
            DriverUninstallPolicy.decide(Identity(isPresent: true, isSymlink: false,
                                                  isDirectory: true,
                                                  bundleIdentifier: DriverBundleLocation.bundleIdentifier)),
            .remove
        )
    }

    func testUninstallPolicyMatchesTheScript() throws {
        let script = Self.appRoot
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // apps
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("tools/uninstall_driver.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("tools/uninstall_driver.sh is not next to the app sources")
        }
        let text = try String(contentsOf: script, encoding: .utf8)

        XCTAssertTrue(text.contains(DriverUninstallPolicy.driverPath),
                      "the script and the app must name the same driver path")
        XCTAssertTrue(text.contains(DriverUninstallPolicy.expectedBundleIdentifier),
                      "the script and the app must check the same bundle identifier")

        // The script parameterises the path (it has a dry-run seam); the app
        // hard-codes it. What must be identical is the command those two
        // produce, so the shape is compared with the path substituted.
        let shape = "/bin/rm -rf '$DRIVER_PATH'"
        XCTAssertTrue(text.contains(shape),
                      "the script must remove with the same command shape the policy uses")
        XCTAssertEqual(
            shape.replacingOccurrences(of: "$DRIVER_PATH", with: DriverUninstallPolicy.driverPath),
            DriverUninstallPolicy.removalCommand,
            "the script's default and the app's command must expand to the same string"
        )
    }

    // MARK: - 5. Policy is still the source of truth

    func testShippingPolicyRemainsReportOnly() {
        XCTAssertFalse(DriverUpgradePolicy.allowsUserFacingPrompt,
                       "an upgrade prompt is an entry point; this build ships none")
        XCTAssertFalse(DriverUpgradePolicy.allowsAutomaticInstall,
                       "an install needs an explicit user action")
        XCTAssertTrue(DriverUpgradePolicy.allowsCompatibilityNotice,
                      "an unusable driver must still be explained, without an install action")
    }

    func testInstallerStillRefusesIntentsThatDoNotMatch() {
        // The gate is what a future surface would have to go through. If this
        // loosens, the boundary above stops meaning anything.
        XCTAssertFalse(DriverInstallIntent.firstInstall.permits(.outdated(installed: "1.1.3", expected: "1.2.0")))
        XCTAssertFalse(DriverInstallIntent.firstInstall.permits(.compatible(version: "1.2.0")))
        XCTAssertFalse(
            DriverInstallIntent.explicitUpgrade(from: "1.1.3", to: "1.2.0")
                .permits(.newer(installed: "1.3.0", expected: "1.2.0"))
        )
    }

    func testFirstInstallRefusesANewerDriver() {
        // Phase 3.2C. `.newer` means the driver on disk is ahead of this build.
        // A first install must not overwrite it, so the last line of defence has
        // to refuse it even if some future surface asks for one.
        XCTAssertFalse(
            DriverInstallIntent.firstInstall.permits(.newer(installed: "1.1.2", expected: "1.1.1"))
        )
        XCTAssertNil(
            DriverVersionStatus.newer(installed: "1.1.2", expected: "1.1.1").installIntent,
            "nothing is installed for a newer driver"
        )
    }
}
