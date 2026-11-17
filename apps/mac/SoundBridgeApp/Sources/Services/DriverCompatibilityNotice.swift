import Foundation

/// The message shown when the installed driver cannot be used by this build.
///
/// Phase 2.1.4 forbids every upgrade *entry point*: no button, no menu item, no
/// launch window asking to update, no background download or replacement, no
/// administrator prompt the user did not ask for, no `killall coreaudiod` after a
/// version check. It equally forbids the opposite mistake — failing silently.
/// A user whose driver speaks another protocol gets no audio; if the app says
/// nothing, the only explanation available is "it is broken".
///
/// This type therefore produces **text only**. There is no install action, no
/// URLSession, and no privileged call anywhere on this path. The download
/// location is read from the app's own configuration (`SUFeedURL` in Info.plist),
/// which is the repository's real release configuration, rather than being typed
/// in from memory.
struct DriverCompatibilityNotice: Equatable {
    let title: String
    let lines: [String]

    /// Whether this status warrants an alert the user did not ask for.
    ///
    /// `.notInstalled` is excluded: that is the first-install flow, and onboarding
    /// already covers it with an install action. `.compatible` is healthy.
    /// `.newer` is excluded too, but for a different reason: nothing is wrong with
    /// the driver, so a launch alert would be encouraging the user to "fix" the
    /// only component that is up to date. `make(for:)` still describes that state
    /// — it is shown where the user is looking at the driver, not pushed at them.
    static func shouldPresent(for status: DriverVersionStatus) -> Bool {
        guard DriverUpgradePolicy.allowsCompatibilityNotice else { return false }

        switch status {
        case .outdated, .protocolIncompatible, .metadataUnreadable, .expectedVersionUnavailable:
            return true
        case .notInstalled, .compatible, .newer:
            return false
        }
    }

    /// Build the notice, or `nil` when there is nothing to report.
    ///
    /// `.newer` is described even though `shouldPresent(for:)` keeps it off the
    /// launch path. The mismatch is real — the app is the stale half — and the
    /// screen that reports the driver's state is the place to say so instead of
    /// showing the "an audio driver is required" copy, which reads as "there is
    /// no driver" and invites an install that would downgrade the one on disk.
    ///
    /// - Parameters:
    ///   - status: what the version gate found.
    ///   - appVersion: `CFBundleShortVersionString` of this app.
    ///   - releasePageURL: derived from `SUFeedURL` by `releasePageURL(feedURL:)`.
    ///     `nil` when the feed is not configured; the notice then tells the user
    ///     where to look without inventing a link.
    static func make(
        for status: DriverVersionStatus,
        appVersion: String,
        releasePageURL: URL?
    ) -> DriverCompatibilityNotice? {
        guard DriverUpgradePolicy.allowsCompatibilityNotice else { return nil }

        if case .newer(let installed, let supported) = status {
            return newerDriverNotice(
                installed: installed,
                supported: supported,
                appVersion: appVersion,
                releasePageURL: releasePageURL
            )
        }

        var lines: [String] = []
        lines.append("SoundBridge \(appVersion) cannot use the audio driver installed on this Mac.")

        switch status {
        case .outdated(let installed, let expected):
            lines.append("Installed driver: \(installed)")
            lines.append("This version needs: \(expected)")
        case .protocolIncompatible(let version, let installedProtocol, let expectedProtocol):
            lines.append("Installed driver: \(version)")
            lines.append("This version needs: \(VersionManager.bundledDriverVersion() ?? "bundled with this build")")
            lines.append(
                "Shared-memory protocol: installed \(DriverVersionGate.hex(installedProtocol)), "
                    + "this build expects \(DriverVersionGate.hex(expectedProtocol))"
            )
        case .metadataUnreadable(let reason):
            lines.append("Installed driver: version could not be read")
            lines.append("This version needs: \(VersionManager.bundledDriverVersion() ?? "bundled with this build")")
            lines.append("Reason: \(reason)")
        case .expectedVersionUnavailable:
            lines.append("Installed driver: cannot be compared")
            lines.append("This build could not read the driver version it ships, so no comparison was possible.")
        case .notInstalled, .compatible, .newer:
            return nil
        }

        if let releasePageURL {
            lines.append("To install a matching driver, download the full package from \(releasePageURL.absoluteString) and run its installer.")
        } else {
            lines.append("To install a matching driver, download the full package from the SoundBridge releases page and run its installer.")
        }

        // The promise 2.1.4 §2.3 makes, stated to the user rather than only kept
        // in code: nothing rewrites the system driver behind their back.
        lines.append("SoundBridge will not replace the system driver in the background.")

        return DriverCompatibilityNotice(
            title: "Audio driver is not compatible with this version",
            lines: lines
        )
    }

    /// The text for "the driver is newer than the app".
    ///
    /// Phase 3.2C. This state used to produce no notice at all, so onboarding fell
    /// through to "An audio driver is required to enable volume control. This
    /// requires an administrator password" — the first-install copy, shown to
    /// someone who has a driver that works, just not with this build. Its only
    /// implied action was the one thing that must not happen: replacing the newer
    /// driver with this build's older copy.
    ///
    /// Every clause below is load-bearing: which driver is installed, what this
    /// app supports, why they cannot work together, and that the fix is to update
    /// the app rather than to touch the driver.
    private static func newerDriverNotice(
        installed: String,
        supported: String,
        appVersion: String,
        releasePageURL: URL?
    ) -> DriverCompatibilityNotice {
        var lines: [String] = []
        lines.append(
            "The SoundBridge driver installed on this Mac (\(installed)) is newer than "
                + "the version SoundBridge \(appVersion) supports (\(supported))."
        )
        lines.append("Installed driver: \(installed)")
        lines.append("This version of SoundBridge supports: \(supported)")
        lines.append(
            "The app and the driver have to agree on both the bundle version and the "
                + "shared-memory protocol. A driver from a later release speaks a format "
                + "this build does not, so this build cannot use it."
        )

        if let releasePageURL {
            lines.append(
                "To recover, update SoundBridge to a version that supports driver \(installed): "
                    + "check for updates in the app, or download the latest version from "
                    + "\(releasePageURL.absoluteString)."
            )
        } else {
            lines.append(
                "To recover, update SoundBridge to a version that supports driver \(installed): "
                    + "check for updates in the app, or download the latest version from the "
                    + "SoundBridge releases page."
            )
        }
        lines.append(
            "Do not reinstall or downgrade the installed driver. The driver on this Mac "
                + "is the newer half, and replacing it with an older one is not a fix."
        )
        lines.append("SoundBridge will not replace the system driver in the background.")

        return DriverCompatibilityNotice(
            title: "App and Driver Versions Do Not Match",
            lines: lines
        )
    }

    /// The notice body as one paragraph, for places that want a single string.
    var message: String {
        return lines.joined(separator: "\n\n")
    }

    // MARK: - Configuration-derived download location

    /// Derive the repository's releases page from the update feed.
    ///
    /// `SUFeedURL` is
    /// `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`,
    /// so the first two path components are the repository. Deriving it from
    /// configuration means a fork or a rename changes the link in one place, and
    /// means this code cannot point at a repository that does not exist.
    ///
    /// Returns `nil` for anything that is not a GitHub release feed — there is no
    /// safe guess to make, and a wrong link is worse than a missing one.
    static func releasePageURL(feedURL: URL?) -> URL? {
        guard let feedURL,
              let host = feedURL.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }

        let components = feedURL.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }

        let owner = components[0]
        let repo = components[1]
        guard !owner.isEmpty, !repo.isEmpty else { return nil }

        var urlComponents = URLComponents()
        urlComponents.scheme = "https"
        urlComponents.host = "github.com"
        urlComponents.path = "/\(owner)/\(repo)/releases"
        return urlComponents.url
    }

    /// The same derivation against this app's bundle.
    static var configuredReleasePageURL: URL? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return releasePageURL(feedURL: url)
    }
}
