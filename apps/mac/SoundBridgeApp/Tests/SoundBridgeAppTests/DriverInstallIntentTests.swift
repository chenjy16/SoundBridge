import XCTest
@testable import SoundBridgeApp

// MARK: - Install intent
//
// `DriverVersionStatus.requiresInstallation` used to answer "should something be
// installed?" with a single boolean that was true for `.notInstalled` *and* for
// every incompatible state. A launch check could therefore not tell a first
// install from an upgrade, and the app's only automatic path could reach the
// privileged copy step with no user action behind it.
//
// These tests pin the split: an intent must be named, and the installer refuses
// the pairings that would silently downgrade, overwrite, or reinstall.

final class DriverInstallIntentTests: XCTestCase {

    private let compatible = DriverVersionStatus.compatible(version: "1.2.0")
    private let newer = DriverVersionStatus.newer(installed: "1.3.0", expected: "1.2.0")
    private let outdated = DriverVersionStatus.outdated(installed: "1.1.3", expected: "1.2.0")
    private let unreadable = DriverVersionStatus.metadataUnreadable(reason: "x")
    // MARK: - Fixtures

    // The mismatch fixture uses one ABI generation behind whatever this build
    // speaks, written as a delta so a protocol bump cannot leave a stale literal.
    private let mismatched = DriverVersionStatus.protocolIncompatible(
        installedVersion: "1.2.0",
        installedProtocol: DriverVersionGate.expectedProtocolVersion - 0x100,
        expectedProtocol: DriverVersionGate.expectedProtocolVersion
    )
    private let unknownExpected = DriverVersionStatus.expectedVersionUnavailable

    private var allStatuses: [DriverVersionStatus] {
        [.notInstalled, compatible, outdated, newer, unreadable, mismatched, unknownExpected]
    }

    // MARK: - First install

    func testFirstInstallIsAllowedOnlyWhenNothingIsInstalled() {
        XCTAssertTrue(DriverInstallIntent.firstInstall.permits(.notInstalled))

        // The load-bearing rejection. Everything else at the HAL path means a
        // bundle exists, and a first install must not quietly replace it.
        for status in [compatible, outdated, newer, unreadable, mismatched, unknownExpected] {
            XCTAssertFalse(
                DriverInstallIntent.firstInstall.permits(status),
                "a first install must not run against \(status)"
            )
        }
    }

    func testFirstInstallIsIdentifiable() {
        XCTAssertTrue(DriverInstallIntent.firstInstall.isFirstInstall)
        XCTAssertFalse(DriverInstallIntent.explicitUpgrade(from: "1.1.3", to: "1.2.0").isFirstInstall)
    }

    // MARK: - Upgrade

    func testUpgradeIsAllowedAgainstEveryStateThatNeedsOne() {
        let upgrade = DriverInstallIntent.explicitUpgrade(from: "1.1.3", to: "1.2.0")
        for status in [outdated, unreadable, mismatched, unknownExpected] {
            XCTAssertTrue(upgrade.permits(status), "an explicit upgrade should be allowed against \(status)")
        }
    }

    func testUpgradeIsRefusedAgainstACompatibleOrNewerDriver() {
        let upgrade = DriverInstallIntent.explicitUpgrade(from: "1.1.3", to: "1.2.0")

        XCTAssertFalse(upgrade.permits(compatible), "nothing to do; a privileged copy would be pointless")
        XCTAssertFalse(upgrade.permits(newer), "replacing a newer driver is a silent downgrade")
    }

    func testUpgradeIsAllowedWhenTheBundleVanishedInBetween() {
        // Allowed on purpose: nothing is being replaced, and failing here would
        // strand a user mid-flow on a race they cannot see.
        let upgrade = DriverInstallIntent.explicitUpgrade(from: "1.1.3", to: "1.2.0")
        XCTAssertTrue(upgrade.permits(.notInstalled))
    }

    // MARK: - Cross-checks

    func testEveryStatusThatYieldsAnIntentAcceptsIt() {
        // The status and the intent are derived in two places; if they ever
        // disagree, the installer throws at the last moment instead of the UI
        // never offering the action. This catches that.
        for status in allStatuses {
            guard let intent = status.installIntent else { continue }
            XCTAssertTrue(
                intent.permits(status),
                "status \(status) produced \(intent.summary) which refuses itself"
            )
        }
    }

    func testHealthyStatusesYieldNoIntent() {
        XCTAssertNil(compatible.installIntent)
        XCTAssertNil(newer.installIntent)
    }

    func testSummariesAreRenderable() {
        XCTAssertFalse(DriverInstallIntent.firstInstall.summary.isEmpty)
        XCTAssertEqual(
            DriverInstallIntent.explicitUpgrade(from: "1.1.3", to: "1.2.0").summary,
            "explicit upgrade 1.1.3 -> 1.2.0"
        )
    }

    // MARK: - Policy

    func testCompatibilityNoticeIsTheOnlyThingTurnedOn() {
        // Phase 2.1.4 keeps the capability, removes the entry point, and requires
        // that an unusable driver is still explained. Those are three different
        // switches; collapsing them is what the phase exists to prevent.
        XCTAssertFalse(DriverUpgradePolicy.allowsUserFacingPrompt)
        XCTAssertFalse(DriverUpgradePolicy.allowsAutomaticInstall)
        XCTAssertTrue(DriverUpgradePolicy.allowsCompatibilityNotice)
    }
}
