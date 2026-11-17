import XCTest
@testable import SoundBridgeApp

// MARK: - Old-driver recovery matrix (Phase 2.1.5-A4)
//
// The question this file answers, row by row: a user who is on some installed
// driver state — one version, another protocol, an unreadable bundle — what does
// this build do, and can they actually get to a matching driver?
//
// The matrix is deliberately about *reachability*, not only about classification.
// A row that the gate classifies correctly but no shipped path can act on is a
// user with no recovery, so each row also asserts which of the two paths exists:
//
//   in-app:  `DriverInstaller.installDriver(intent:)` — capability present,
//            entry point disabled (`DriverUpgradePolicy.allowsUserFacingPrompt`
//            and `allowsAutomaticInstall` are both false). Reachable today only
//            from onboarding's first-install button.
//   package: the installer produced by tools/build_installer_pkg.sh — app and
//            driver in one artifact, preinstall replaces the bundle.
//
// Nothing here installs anything. Evidence level: L2 (pure gate evaluation).

final class DriverRecoveryMatrixTests: XCTestCase {

    private struct Row {
        let name: String
        let plist: [String: Any]?
        let bundleExists: Bool
        let expectedVersion: String
        let status: DriverVersionStatus
        let intent: DriverInstallIntent?
        /// Does recovery require replacing the bundle on disk?
        let replaceOnDisk: Bool
        /// Is the user shown an in-app explanation (no install action)?
        let notice: Bool
    }

    private let protocolVersion = DriverVersionGate.expectedProtocolVersion
    private let olderProtocol: UInt32 = 0x0001_0100

    /// Seven states, in the order a support conversation would meet them.
    private func rows() -> [Row] {
        [
            Row(
                name: "no driver installed",
                plist: nil,
                bundleExists: false,
                expectedVersion: "1.2.0",
                status: .notInstalled,
                intent: .firstInstall,
                replaceOnDisk: false,      // nothing to replace; onboarding installs
                notice: false              // onboarding is the explanation
            ),
            Row(
                name: "1.1.x driver, same protocol, no protocol key",
                // Pre-1.2.0 builds did not write SBAudioProtocolVersion at all,
                // which is why its absence is not an error.
                plist: ["CFBundleIdentifier": "com.soundbridge.driver",
                        "CFBundleShortVersionString": "1.1.1"],
                bundleExists: true,
                expectedVersion: "1.2.0",
                status: .outdated(installed: "1.1.1", expected: "1.2.0"),
                intent: .explicitUpgrade(from: "1.1.1", to: "1.2.0"),
                replaceOnDisk: true,
                notice: true
            ),
            Row(
                name: "same version, older protocol",
                plist: ["CFBundleIdentifier": "com.soundbridge.driver",
                        "CFBundleShortVersionString": "1.2.0",
                        DriverVersionGate.protocolVersionKey: Int(olderProtocol)],
                bundleExists: true,
                expectedVersion: "1.2.0",
                status: .protocolIncompatible(
                    installedVersion: "1.2.0",
                    installedProtocol: olderProtocol,
                    expectedProtocol: 0x0002_0100
                ),
                intent: .explicitUpgrade(from: "1.2.0", to: "this build"),
                replaceOnDisk: true,
                notice: true
            ),
            Row(
                name: "bundle present but metadata unreadable",
                plist: nil,
                bundleExists: true,
                expectedVersion: "1.2.0",
                status: .metadataUnreadable(
                    reason: "Info.plist is missing or is not a property list dictionary"
                ),
                intent: .explicitUpgrade(from: "unreadable", to: "this build"),
                replaceOnDisk: true,
                notice: true
            ),
            Row(
                name: "installed driver is newer",
                plist: ["CFBundleIdentifier": "com.soundbridge.driver",
                        "CFBundleShortVersionString": "1.3.0",
                        DriverVersionGate.protocolVersionKey: 0x0002_0100],
                bundleExists: true,
                expectedVersion: "1.2.0",
                status: .newer(installed: "1.3.0", expected: "1.2.0"),
                intent: nil,               // replacing it would be a silent downgrade
                replaceOnDisk: false,
                notice: false
            ),
            Row(
                name: "compatible",
                plist: ["CFBundleIdentifier": "com.soundbridge.driver",
                        "CFBundleShortVersionString": "1.2.0",
                        DriverVersionGate.protocolVersionKey: 0x0002_0100],
                bundleExists: true,
                expectedVersion: "1.2.0",
                status: .compatible(version: "1.2.0"),
                intent: nil,
                replaceOnDisk: false,
                notice: false
            ),
            Row(
                name: "this build cannot name its own driver version",
                plist: ["CFBundleIdentifier": "com.soundbridge.driver",
                        "CFBundleShortVersionString": "1.2.0"],
                bundleExists: true,
                expectedVersion: "",
                status: .expectedVersionUnavailable,
                intent: .explicitUpgrade(from: "unknown", to: "unknown"),
                // A packaging defect, not a user-side state: another package built
                // from the same broken tree would install the same broken bundle.
                replaceOnDisk: false,
                notice: true
            ),
        ]
    }

    // MARK: - The matrix

    func testSevenRowRecoveryMatrix() {
        let rows = rows()
        XCTAssertEqual(rows.count, 7, "the matrix is fixed at seven rows")

        for row in rows {
            let status = DriverVersionGate.evaluate(
                plist: row.plist,
                bundleExists: row.bundleExists,
                expectedVersion: row.expectedVersion,
                expectedProtocol: protocolVersion
            )

            XCTAssertEqual(status, row.status, "[\(row.name)] gate classification")
            XCTAssertEqual(status.installIntent, row.intent, "[\(row.name)] install intent")

            // A status that claims an intent must also permit it, or the row is a
            // dead end: classified but not actionable.
            if let intent = row.intent {
                XCTAssertTrue(
                    intent.permits(status),
                    "[\(row.name)] \(intent.summary) must be permitted against \(status.summary)"
                )
            }

            XCTAssertEqual(
                DriverCompatibilityNotice.shouldPresent(for: status),
                row.notice,
                "[\(row.name)] user-visible explanation"
            )
        }
    }

    func testEveryActionableRowIsUnreachableInApp() {
        // The recovery capability exists; the entry point does not. That is the
        // product decision, and it means the package is the only path a user has.
        XCTAssertFalse(DriverUpgradePolicy.allowsUserFacingPrompt)
        XCTAssertFalse(DriverUpgradePolicy.allowsAutomaticInstall)

        for row in rows() where row.intent != nil && !row.intent!.isFirstInstall {
            // No shipped surface can produce this intent from a launch, a
            // reconnect or a Host restart: the only call sites are onboarding's
            // first-install button and the unwired update window
            // (DriverInstallBoundaryTests asserts both).
            if case .expectedVersionUnavailable = row.status {
                // The one row the gate would permit an install for and that a
                // replacement cannot fix: the defect is in this build, so another
                // package built from the same tree ships the same unreadable
                // bundle. Recorded rather than hidden, because "the gate allows
                // it" must not be read as "the user can recover".
                XCTAssertFalse(
                    row.replaceOnDisk,
                    "[\(row.name)] a packaging defect is not something the user replaces"
                )
            } else {
                XCTAssertTrue(
                    row.replaceOnDisk,
                    "[\(row.name)] an upgrade row must describe a driver that has to be replaced"
                )
            }
        }
    }

    func testNewerAndCompatibleRowsNeverAskForAReplacement() {
        for row in rows() where row.status.isCompatible || isNewer(row.status) {
            XCTAssertNil(row.intent, "[\(row.name)] nothing to install")
            XCTAssertFalse(row.replaceOnDisk, "[\(row.name)] must not be replaced")
            XCTAssertFalse(DriverCompatibilityNotice.shouldPresent(for: row.status))
        }
    }

    // MARK: - Protocol drift is a version-independent failure

    func testProtocolMismatchOutranksVersionComparison() {
        // Same version string, one protocol bit different: the version dance would
        // say "compatible" and ship an ABI mismatch.
        let status = DriverVersionGate.evaluate(
            plist: ["CFBundleShortVersionString": "1.2.0",
                    DriverVersionGate.protocolVersionKey: Int(olderProtocol)],
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: DriverVersionGate.expectedProtocolVersion
        )

        guard case .protocolIncompatible = status else {
            return XCTFail("expected protocolIncompatible, got \(status)")
        }
    }

    func testProtocolKeyInAnUnparseableFormIsUnreadableNotIncompatible() {
        // Guessing "incompatible" would hide a corrupt bundle behind a version
        // message the user cannot act on.
        for raw in ["2.1", "v2", "0xZZ", ""] as [Any] {
            let status = DriverVersionGate.evaluate(
                plist: ["CFBundleShortVersionString": "1.2.0",
                        DriverVersionGate.protocolVersionKey: raw],
                bundleExists: true,
                expectedVersion: "1.2.0",
                expectedProtocol: DriverVersionGate.expectedProtocolVersion
            )

            guard case .metadataUnreadable = status else {
                return XCTFail("\(raw): expected metadataUnreadable, got \(status)")
            }
        }
    }

    func testProtocolKeyWrittenAsAHexStringIsStillRead() {
        // Info.plist may hold the value as a string — hand-edited, or written by a
        // tool that stringifies numbers. `protocolValue` accepts both decimal and
        // `0x`-prefixed hex, so a correct protocol in string form is not
        // misreported as a corrupt bundle.
        let status = DriverVersionGate.evaluate(
            plist: ["CFBundleShortVersionString": "1.2.0",
                    DriverVersionGate.protocolVersionKey: "0x00020100"],
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: 0x0002_0100
        )

        XCTAssertEqual(status, .compatible(version: "1.2.0"))
    }

    private func isNewer(_ status: DriverVersionStatus) -> Bool {
        if case .newer = status { return true }
        return false
    }
}
