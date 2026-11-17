import XCTest
@testable import SoundBridgeApp

// MARK: - Driver install gate
//
// These tests never touch /Library/Audio/Plug-Ins/HAL and never invoke the
// privileged copy step. The pure `evaluate(plist:...)` half is driven with
// dictionaries; the file half is driven with throwaway bundles under
// NSTemporaryDirectory().

final class DriverVersionGateTests: XCTestCase {

    private let protocolVersion = DriverVersionGate.expectedProtocolVersion

    // MARK: - Fixtures

    private func makeBundleRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeDriverGate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func withTemporaryBundle(_ body: (URL) throws -> Void) throws {
        let root = try makeBundleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("SoundBridgeDriver.driver", isDirectory: true))
    }

    private func writeInfoPlist(_ contents: [String: Any], to bundle: URL) throws {
        let contentsDir = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: contents,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsDir.appendingPathComponent("Info.plist"))
    }

    private func plist(version: String?, protocolVersion: Any? = nil) -> [String: Any] {
        var contents: [String: Any] = ["CFBundleIdentifier": "com.soundbridge.driver"]
        if let version {
            contents["CFBundleShortVersionString"] = version
        }
        if let protocolVersion {
            contents[DriverVersionGate.protocolVersionKey] = protocolVersion
        }
        return contents
    }

    // MARK: - Pure evaluation: presence and versions

    func testNotInstalledWhenBundleIsAbsent() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.2.0"),
            bundleExists: false,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        XCTAssertEqual(status, .notInstalled)
        XCTAssertEqual(status.installIntent, .firstInstall)
        XCTAssertFalse(status.isCompatible)
    }

    func testCompatibleWhenVersionsMatch() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.2.0"),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        XCTAssertEqual(status, .compatible(version: "1.2.0"))
        XCTAssertNil(status.installIntent)
        XCTAssertTrue(status.isCompatible)
    }

    func testOutdatedWhenInstalledIsOlder() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.1.3"),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        XCTAssertEqual(status, .outdated(installed: "1.1.3", expected: "1.2.0"))
        XCTAssertEqual(status.installIntent, .explicitUpgrade(from: "1.1.3", to: "1.2.0"))
        XCTAssertFalse(status.isCompatible)
    }

    func testNewerWhenInstalledIsNewer() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.3.0"),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        XCTAssertEqual(status, .newer(installed: "1.3.0", expected: "1.2.0"))
        XCTAssertNil(status.installIntent, "a downgrade must never be offered, automatic or not")
        XCTAssertFalse(status.isCompatible)
    }

    // MARK: - Pure evaluation: metadata damage

    func testMetadataUnreadableWhenPlistIsMissing() {
        let status = DriverVersionGate.evaluate(
            plist: nil,
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        XCTAssertEqual(status.installIntent, .explicitUpgrade(from: "unreadable", to: "this build"))
        guard case .metadataUnreadable = status else {
            return XCTFail("expected .metadataUnreadable, got \(status)")
        }
    }

    func testMetadataUnreadableWhenVersionKeyIsMissing() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: nil),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        guard case .metadataUnreadable(let reason) = status else {
            return XCTFail("expected .metadataUnreadable, got \(status)")
        }
        XCTAssertTrue(reason.contains("CFBundleShortVersionString"))
    }

    func testMetadataUnreadableWhenVersionKeyIsEmpty() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "   "),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        guard case .metadataUnreadable = status else {
            return XCTFail("expected .metadataUnreadable, got \(status)")
        }
    }

    func testMetadataUnreadableWhenProtocolKeyIsNotAnInteger() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.2.0", protocolVersion: "not-a-number"),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        guard case .metadataUnreadable(let reason) = status else {
            return XCTFail("expected .metadataUnreadable, got \(status)")
        }
        XCTAssertTrue(reason.contains(DriverVersionGate.protocolVersionKey))
    }

    // MARK: - Pure evaluation: protocol compatibility

    func testProtocolMismatchIsReportedWithBothValues() {
        let stale: UInt32 = 0x00010400
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.2.0", protocolVersion: Int(stale)),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        XCTAssertEqual(
            status,
            .protocolIncompatible(
                installedVersion: "1.2.0",
                installedProtocol: stale,
                expectedProtocol: protocolVersion
            )
        )
        XCTAssertEqual(status.installIntent, .explicitUpgrade(from: "1.2.0", to: "this build"))
    }

    func testProtocolMismatchOutranksVersionComparison() {
        // Same version string, different protocol: the layout is what matters,
        // so this must not be reported as compatible.
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.2.0", protocolVersion: Int(protocolVersion &+ 1)),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        guard case .protocolIncompatible = status else {
            return XCTFail("expected .protocolIncompatible, got \(status)")
        }
    }

    func testProtocolMismatchOutranksNewerVersion() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "9.9.9", protocolVersion: Int(protocolVersion &+ 1)),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        guard case .protocolIncompatible = status else {
            return XCTFail("expected .protocolIncompatible, got \(status)")
        }
    }

    func testLegacyDriverWithoutProtocolKeyFallsBackToVersionComparison() {
        // Drivers built before 1.2.0 have no protocol key at all. They must not be
        // declared unreadable just for that — version comparison still applies.
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.1.3"),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        XCTAssertEqual(status, .outdated(installed: "1.1.3", expected: "1.2.0"))
    }

    func testMatchingProtocolKeyIsAccepted() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.2.0", protocolVersion: Int(protocolVersion)),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        XCTAssertEqual(status, .compatible(version: "1.2.0"))
    }

    func testProtocolKeyDeclaredAsHexStringIsAccepted() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.2.0", protocolVersion: DriverVersionGate.hex(protocolVersion)),
            bundleExists: true,
            expectedVersion: "1.2.0",
            expectedProtocol: protocolVersion
        )
        XCTAssertEqual(status, .compatible(version: "1.2.0"))
    }

    // MARK: - Expected version

    func testExpectedVersionUnavailableWhenBundledVersionIsBlank() {
        let status = DriverVersionGate.evaluate(
            plist: plist(version: "1.2.0"),
            bundleExists: true,
            expectedVersion: "  ",
            expectedProtocol: protocolVersion
        )
        XCTAssertEqual(status, .expectedVersionUnavailable)
        XCTAssertEqual(status.installIntent, .explicitUpgrade(from: "unknown", to: "unknown"))
    }

    // MARK: - Version comparison

    func testVersionComparisonIsNumericNotLexicographic() {
        XCTAssertEqual(DriverVersionGate.compare("1.10", "1.9"), 1)
        XCTAssertEqual(DriverVersionGate.compare("1.9", "1.10"), -1)
        XCTAssertEqual(DriverVersionGate.compare("2.0", "10.0"), -1)
    }

    func testVersionComparisonPadsMissingComponents() {
        XCTAssertEqual(DriverVersionGate.compare("1.2", "1.2.0"), 0)
        XCTAssertEqual(DriverVersionGate.compare("1.2.0", "1.2"), 0)
        XCTAssertEqual(DriverVersionGate.compare("1", "1.0.0"), 0)
        XCTAssertEqual(DriverVersionGate.compare("1.2.1", "1.2"), 1)
    }

    func testVersionComparisonIgnoresPrereleaseSuffix() {
        XCTAssertEqual(DriverVersionGate.compare("1.2.0-beta", "1.2.0"), 0)
        XCTAssertEqual(DriverVersionGate.compare("1.2.0-beta", "1.2.1"), -1)
    }

    func testVersionManagerDelegatesToGate() {
        XCTAssertTrue(VersionManager.isVersionOlder("1.1.3", than: "1.2.0"))
        XCTAssertFalse(VersionManager.isVersionOlder("1.2.0", than: "1.2.0"))
        XCTAssertTrue(VersionManager.areVersionsEqual("1.2", "1.2.0"))
        XCTAssertFalse(VersionManager.areVersionsEqual("1.2", "1.3"))
    }

    // MARK: - Gate mapping

    /// The split that replaced `requiresInstallation`.
    ///
    /// The old boolean said "install something" for both "nothing is here" and
    /// "something incompatible is here", which is why a launch check could not
    /// tell a first install from an upgrade it was not allowed to perform. The
    /// matrix below is that distinction made explicit.
    func testInstallIntentMapping() {
        let cases: [(DriverVersionStatus, DriverInstallIntent?)] = [
            (.notInstalled, .firstInstall),
            (.compatible(version: "1.2.0"), nil),
            (.outdated(installed: "1.1.3", expected: "1.2.0"), .explicitUpgrade(from: "1.1.3", to: "1.2.0")),
            (.newer(installed: "1.3.0", expected: "1.2.0"), nil),
            (.metadataUnreadable(reason: "x"), .explicitUpgrade(from: "unreadable", to: "this build")),
            (
                .protocolIncompatible(installedVersion: "1.2.0", installedProtocol: 1, expectedProtocol: 2),
                .explicitUpgrade(from: "1.2.0", to: "this build")
            ),
            (.expectedVersionUnavailable, .explicitUpgrade(from: "unknown", to: "unknown"))
        ]
        for (status, expected) in cases {
            XCTAssertEqual(status.installIntent, expected, "installIntent for \(status)")
        }
    }

    func testIsCompatibleOnlyTrueForCompatible() {
        XCTAssertTrue(DriverVersionStatus.compatible(version: "1.2.0").isCompatible)
        XCTAssertFalse(DriverVersionStatus.notInstalled.isCompatible)
        XCTAssertFalse(DriverVersionStatus.outdated(installed: "1.1.3", expected: "1.2.0").isCompatible)
        XCTAssertFalse(DriverVersionStatus.newer(installed: "1.3.0", expected: "1.2.0").isCompatible)
        XCTAssertFalse(DriverVersionStatus.metadataUnreadable(reason: "x").isCompatible)
        XCTAssertFalse(
            DriverVersionStatus
                .protocolIncompatible(installedVersion: "1.2.0", installedProtocol: 1, expectedProtocol: 2)
                .isCompatible
        )
        XCTAssertFalse(DriverVersionStatus.expectedVersionUnavailable.isCompatible)
    }

    func testStatusLabelsAreAlwaysRenderable() {
        let cases: [DriverVersionStatus] = [
            .notInstalled,
            .compatible(version: "1.2.0"),
            .outdated(installed: "1.1.3", expected: "1.2.0"),
            .newer(installed: "1.3.0", expected: "1.2.0"),
            .metadataUnreadable(reason: "x"),
            .protocolIncompatible(installedVersion: "1.2.0", installedProtocol: 1, expectedProtocol: 2),
            .expectedVersionUnavailable
        ]
        for status in cases {
            XCTAssertFalse(status.installedVersionLabel.isEmpty, "label for \(status)")
            XCTAssertFalse(status.summary.isEmpty, "summary for \(status)")
        }
    }

    // MARK: - File-level evaluation

    func testFileEvaluationOnAbsentBundle() throws {
        try withTemporaryBundle { bundle in
            let status = DriverVersionGate.evaluate(
                bundleURL: bundle,
                expectedVersion: "1.2.0",
                expectedProtocol: protocolVersion
            )
            XCTAssertEqual(status, .notInstalled)
        }
    }

    func testFileEvaluationReadsRealBundle() throws {
        try withTemporaryBundle { bundle in
            try writeInfoPlist(plist(version: "1.2.0", protocolVersion: Int(protocolVersion)), to: bundle)
            let status = DriverVersionGate.evaluate(
                bundleURL: bundle,
                expectedVersion: "1.2.0",
                expectedProtocol: protocolVersion
            )
            XCTAssertEqual(status, .compatible(version: "1.2.0"))
        }
    }

    func testFileEvaluationWhenInfoPlistIsMissing() throws {
        try withTemporaryBundle { bundle in
            try FileManager.default.createDirectory(
                at: bundle.appendingPathComponent("Contents", isDirectory: true),
                withIntermediateDirectories: true
            )
            let status = DriverVersionGate.evaluate(
                bundleURL: bundle,
                expectedVersion: "1.2.0",
                expectedProtocol: protocolVersion
            )
            guard case .metadataUnreadable = status else {
                return XCTFail("expected .metadataUnreadable, got \(status)")
            }
        }
    }

    func testFileEvaluationWhenInfoPlistIsCorrupt() throws {
        try withTemporaryBundle { bundle in
            let contentsDir = bundle.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
            try Data("this is not a property list".utf8)
                .write(to: contentsDir.appendingPathComponent("Info.plist"))

            let status = DriverVersionGate.evaluate(
                bundleURL: bundle,
                expectedVersion: "1.2.0",
                expectedProtocol: protocolVersion
            )
            guard case .metadataUnreadable = status else {
                return XCTFail("expected .metadataUnreadable, got \(status)")
            }
        }
    }

    func testFileEvaluationDetectsProtocolMismatch() throws {
        try withTemporaryBundle { bundle in
            let stale: UInt32 = 0x00010400
            try writeInfoPlist(plist(version: "1.2.0", protocolVersion: Int(stale)), to: bundle)
            let status = DriverVersionGate.evaluate(
                bundleURL: bundle,
                expectedVersion: "1.2.0",
                expectedProtocol: protocolVersion
            )
            XCTAssertEqual(
                status,
                .protocolIncompatible(
                    installedVersion: "1.2.0",
                    installedProtocol: stale,
                    expectedProtocol: protocolVersion
                )
            )
        }
    }

    func testFileEvaluationLeavesNoArtifacts() throws {
        // The fixture helper deletes its root; this asserts the shape of the tree
        // it builds so a future refactor cannot start writing outside it.
        let root = try makeBundleRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = root.appendingPathComponent("SoundBridgeDriver.driver", isDirectory: true)
        try writeInfoPlist(plist(version: "1.2.0"), to: bundle)

        let created = try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .sorted()
        XCTAssertEqual(
            created,
            ["SoundBridgeDriver.driver", "SoundBridgeDriver.driver/Contents", "SoundBridgeDriver.driver/Contents/Info.plist"]
        )
    }

    // MARK: - Upgrade policy

    func testUpgradePolicyKeepsUserFacingUpgradeOff() {
        // Phase 2.1.3 ships the capability, not the entry point. Turning either of
        // these on is a product decision and must show up as a test change.
        XCTAssertFalse(DriverUpgradePolicy.allowsUserFacingPrompt)
        XCTAssertFalse(DriverUpgradePolicy.allowsAutomaticInstall)
    }

    // MARK: - Consistency guard

    func testExpectedProtocolVersionMatchesSharedHeader() {
        // If this fires, RFSharedAudio.h was bumped without updating the shared
        // memory layout expectations that the app was built against.
        XCTAssertEqual(
            DriverVersionGate.expectedProtocolVersion,
            0x0002_0100,
            "driver gate protocol version drifted from RFSharedAudio.h"
        )
    }
}
