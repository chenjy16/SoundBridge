import Foundation
import CSoundBridgeAudio

/// What this build can say about the HAL driver that is currently installed.
///
/// The gate exists so `DriverInstaller` never has to guess from file existence
/// alone. Every case below is a decision, not an observation: `requiresInstallation`
/// is what the installer acts on, and nothing installs without passing through here.
enum DriverVersionStatus: Equatable {
    /// No bundle at the install path.
    case notInstalled
    /// Installed bundle matches this build's version and, when both sides declare
    /// one, its shared-memory protocol version.
    case compatible(version: String)
    /// Installed bundle is older than the one shipped inside the app.
    case outdated(installed: String, expected: String)
    /// Installed bundle is newer than the one shipped inside the app. Replacing it
    /// would be a silent downgrade, so it is left alone.
    case newer(installed: String, expected: String)
    /// The bundle is there but its `Info.plist` cannot tell us what it is.
    case metadataUnreadable(reason: String)
    /// `Info.plist` declares a shared-memory protocol version that differs from
    /// the one this build was compiled against.
    case protocolIncompatible(installedVersion: String, installedProtocol: UInt32, expectedProtocol: UInt32)
    /// The app's own bundled driver version could not be read, so nothing can be
    /// compared. Treated as "install anyway" — the copy step will fail loudly if
    /// the bundle is genuinely absent.
    case expectedVersionUnavailable

    /// What kind of installation would be appropriate, if any.
    ///
    /// This used to be a single `requiresInstallation: Bool` that was true for
    /// `.notInstalled` *and* for every incompatible state, which made "a driver is
    /// installed but speaks another protocol" and "there is no driver" the same
    /// decision. The two are not the same: the first is a compatibility problem
    /// the user resolves with a full package, the second is the first-install
    /// flow. Callers now have to name which one they are doing.
    var installIntent: DriverInstallIntent? {
        switch self {
        case .notInstalled:
            return .firstInstall
        case .outdated(let installed, let expected):
            return .explicitUpgrade(from: installed, to: expected)
        case .protocolIncompatible(let version, _, _):
            return .explicitUpgrade(from: version, to: bundledVersionLabel)
        case .metadataUnreadable:
            return .explicitUpgrade(from: "unreadable", to: bundledVersionLabel)
        case .expectedVersionUnavailable:
            return .explicitUpgrade(from: "unknown", to: "unknown")
        case .compatible, .newer:
            // Nothing to install. `.newer` in particular must never be replaced.
            return nil
        }
    }

    /// Only used to describe an upgrade in one line.
    private var bundledVersionLabel: String {
        if case .outdated(_, let expected) = self { return expected }
        return "this build"
    }

    /// Whether the installed driver can be used by this build as-is.
    var isCompatible: Bool {
        if case .compatible = self {
            return true
        }
        return false
    }

    /// Single-line explanation for logs. Never used for control flow.
    var summary: String {
        switch self {
        case .notInstalled:
            return "not installed"
        case .compatible(let version):
            return "compatible (version \(version))"
        case .outdated(let installed, let expected):
            return "outdated (installed \(installed), expected \(expected))"
        case .newer(let installed, let expected):
            return "newer than this build (installed \(installed), app ships \(expected))"
        case .metadataUnreadable(let reason):
            return "metadata unreadable (\(reason))"
        case .protocolIncompatible(let version, let installedProtocol, let expectedProtocol):
            return "protocol mismatch (version \(version): installed \(DriverVersionGate.hex(installedProtocol)), expected \(DriverVersionGate.hex(expectedProtocol)))"
        case .expectedVersionUnavailable:
            return "bundled driver version unavailable"
        }
    }

    /// Label shown in the update prompt as the "current" side.
    var installedVersionLabel: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .compatible(let version):
            return version
        case .outdated(let installed, _):
            return installed
        case .newer(let installed, _):
            return installed
        case .metadataUnreadable:
            return "Unreadable"
        case .protocolIncompatible(let version, let installedProtocol, _):
            return "\(version) (\(DriverVersionGate.hex(installedProtocol)))"
        case .expectedVersionUnavailable:
            return "Unknown"
        }
    }
}

/// What the caller is asking an install to do.
///
/// The distinction is load-bearing, not cosmetic: an automatic path cannot
/// accidentally ask for `.explicitUpgrade` because no automatic path has a user
/// action to attribute it to, and a first install must never overwrite a bundle
/// that is already there.
///
/// P4 Batch 1A: the app no longer installs the driver — the release's `.pkg`
/// owns that — so nothing in `Sources/` constructs these cases any more. The type
/// stays because the gate (`permits`) is still the rule any future install flow
/// would have to satisfy, and the tests still hold it to that rule.
enum DriverInstallIntent: Equatable {
    /// Nothing is installed at the HAL path: the state onboarding guides the
    /// user out of with the installer package.
    case firstInstall
    /// Replacing an existing bundle: outdated, unreadable metadata, a different
    /// protocol, or an unknown expected version. No surface offers it; kept so
    /// the rule stays testable and a future release can wire it to an explicit
    /// user action.
    case explicitUpgrade(from: String, to: String)

    var isFirstInstall: Bool {
        if case .firstInstall = self { return true }
        return false
    }

    /// Whether this intent is allowed to act on `status`.
    ///
    /// The two rejections that matter: a first install must not overwrite an
    /// existing bundle, and an upgrade must not run against a compatible or newer
    /// driver (`newer` would be a silent downgrade, `compatible` a pointless
    /// privileged copy).
    func permits(_ status: DriverVersionStatus) -> Bool {
        switch (self, status) {
        case (.firstInstall, .notInstalled):
            return true
        case (.explicitUpgrade, .notInstalled):
            // Harmless: nothing to replace, the copy step is the same. Allowed so
            // an upgrade flow does not fail if the bundle vanished in between.
            return true
        case (.explicitUpgrade, .outdated), (.explicitUpgrade, .protocolIncompatible),
             (.explicitUpgrade, .metadataUnreadable), (.explicitUpgrade, .expectedVersionUnavailable):
            return true
        default:
            return false
        }
    }

    var summary: String {
        switch self {
        case .firstInstall:
            return "first install"
        case .explicitUpgrade(let from, let to):
            return "explicit upgrade \(from) -> \(to)"
        }
    }
}

/// What this build is allowed to do about the installed driver.
///
/// Phase 2.1.3 drew a line the code has to keep visible: an upgrade prompt is a
/// user-facing entry point and this build ships none. Four questions that are
/// easy to collapse into one are kept apart on purpose — whether the driver is
/// compatible, whether upgrading would help, whether this build may upgrade, and
/// whether the user is shown an entry point.
///
/// These are constants rather than dead flags so that turning them on is a
/// deliberate, reviewable release decision instead of a code cleanup.
enum DriverUpgradePolicy {
    /// Whether a launch-time mismatch may be turned into a window or alert.
    ///
    /// An upgrade *prompt* is an entry point: it asks the user to let the app
    /// replace the driver. Off.
    static let allowsUserFacingPrompt = false

    /// Whether installation may run without an explicit user action.
    static let allowsAutomaticInstall = false

    /// Whether a compatibility *error* may be explained to the user.
    ///
    /// On, and deliberately not the same thing as a prompt. A driver that speaks
    /// another protocol leaves the app silent and the user without audio; saying
    /// so — with no button that installs anything — is required by 2.1.4 §2.4.
    /// Nothing on this path copies files, restarts `coreaudiod`, or offers an
    /// in-app upgrade.
    static let allowsCompatibilityNotice = true
}

/// Reads the installed driver bundle and decides what to do about it.
///
/// Evaluation is split into a pure function over already-parsed `Info.plist`
/// contents (`evaluate(plist:...)`) and a thin file-reading wrapper
/// (`evaluate(bundleURL:...)`). Tests drive the pure half with dictionaries and
/// the file half with throwaway bundles in a temporary directory; neither
/// touches `/Library/Audio/Plug-Ins/HAL`.
enum DriverVersionGate {

    /// `Info.plist` key carrying the shared-memory protocol version the driver
    /// was compiled against. Written by `tools/update_versions.sh` from
    /// `packages/shared/include/RFSharedAudio.h`.
    ///
    /// Drivers built before 1.2.0 have no such key, which is why its absence is
    /// not treated as an error: version comparison still covers them.
    static let protocolVersionKey = "SBAudioProtocolVersion"

    /// The shared-memory protocol version this build speaks. Sourced from the
    /// shared header so it cannot drift from the code that uses it.
    static var expectedProtocolVersion: UInt32 {
        UInt32(truncatingIfNeeded: RF_AUDIO_PROTOCOL_VERSION)
    }

    // MARK: - Evaluation

    /// Decide what an installed bundle means, given its parsed metadata.
    ///
    /// - Parameters:
    ///   - plist: Parsed `Contents/Info.plist`, or `nil` when the file is absent
    ///     or unparseable.
    ///   - bundleExists: Whether `.driver` directory exists at the install path.
    ///   - expectedVersion: `CFBundleShortVersionString` of the bundled driver.
    ///   - expectedProtocol: Protocol version this build speaks.
    static func evaluate(
        plist: [String: Any]?,
        bundleExists: Bool,
        expectedVersion: String,
        expectedProtocol: UInt32
    ) -> DriverVersionStatus {
        guard bundleExists else {
            return .notInstalled
        }

        let expected = expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else {
            return .expectedVersionUnavailable
        }

        guard let plist else {
            return .metadataUnreadable(reason: "Info.plist is missing or is not a property list dictionary")
        }

        let installedVersion = (plist["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !installedVersion.isEmpty else {
            return .metadataUnreadable(reason: "CFBundleShortVersionString is missing or empty")
        }

        // Protocol compatibility outranks the version dance: a newer-looking build
        // that speaks a different protocol is still unusable.
        if let declared = plist[protocolVersionKey] {
            guard let installedProtocol = protocolValue(declared) else {
                return .metadataUnreadable(reason: "\(protocolVersionKey) is present but not a non-negative integer")
            }
            if installedProtocol != expectedProtocol {
                return .protocolIncompatible(
                    installedVersion: installedVersion,
                    installedProtocol: installedProtocol,
                    expectedProtocol: expectedProtocol
                )
            }
        }

        switch compare(installedVersion, expected) {
        case ..<0:
            return .outdated(installed: installedVersion, expected: expected)
        case 1...:
            return .newer(installed: installedVersion, expected: expected)
        default:
            return .compatible(version: installedVersion)
        }
    }

    /// Read a `.driver` bundle from disk and evaluate it.
    static func evaluate(
        bundleURL: URL,
        expectedVersion: String,
        expectedProtocol: UInt32
    ) -> DriverVersionStatus {
        let manager = FileManager.default
        let bundleExists = manager.fileExists(atPath: bundleURL.path)

        var plist: [String: Any]?
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        if let data = manager.contents(atPath: plistURL.path) {
            plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [String: Any]
        }

        return evaluate(
            plist: plist,
            bundleExists: bundleExists,
            expectedVersion: expectedVersion,
            expectedProtocol: expectedProtocol
        )
    }

    // MARK: - Version comparison

    /// Numeric component-wise comparison. Returns `-1`, `0` or `1`.
    ///
    /// Missing components count as zero, so `1.2` and `1.2.0` compare equal, and
    /// comparison is numeric rather than lexicographic, so `1.10` sorts above
    /// `1.9`. A pre-release suffix after `-` is ignored.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = numericComponents(lhs)
        let right = numericComponents(rhs)

        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r {
                return l < r ? -1 : 1
            }
        }
        return 0
    }

    private static func numericComponents(_ version: String) -> [Int] {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? trimmed

        return core.split(separator: ".").map { component in
            if let value = Int(component) {
                return value
            }
            let digits = component.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
    }

    // MARK: - Helpers

    /// Format a protocol version for logs and UI, e.g. `0x00020100`.
    static func hex(_ value: UInt32) -> String {
        String(format: "0x%08X", value)
    }

    private static func protocolValue(_ raw: Any) -> UInt32? {
        if let value = raw as? Int {
            return UInt32(exactly: value)
        }
        if let value = raw as? NSNumber {
            return UInt32(exactly: value.int64Value)
        }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let decimal = UInt32(trimmed) {
                return decimal
            }
            if trimmed.lowercased().hasPrefix("0x") {
                return UInt32(trimmed.dropFirst(2), radix: 16)
            }
        }
        return nil
    }
}
