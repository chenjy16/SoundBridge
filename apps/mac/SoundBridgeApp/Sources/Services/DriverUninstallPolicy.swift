import Foundation

/// The one policy for removing the SoundBridge driver.
///
/// `tools/uninstall_driver.sh` and the app's "Uninstall Driver" item remove the
/// same bundle, and before P4 Batch 1A they disagreed about almost everything.
/// The script checked the bundle identifier, refused a symlink, and left
/// `coreaudiod` alone. The app killed the Host by name, deleted
/// `/tmp/soundbridge-*` with a wildcard, removed whatever sat at the HAL path
/// without identifying it, and ended with `killall coreaudiod` — so one click
/// could cut audio for every running process and delete files that were never
/// ours.
///
/// These values are the script's. The decisions are pure so they can be tested
/// without a HAL directory, and the strings the UI shows come from here so the
/// screen cannot promise something the policy does not do.
enum DriverUninstallPolicy {

    /// The only path this policy will ever remove.
    static let driverPath = DriverBundleLocation.driverPath

    /// A bundle at `driverPath` is ours only if it says so.
    static let expectedBundleIdentifier = DriverBundleLocation.bundleIdentifier

    /// The removal asks for administrator rights once, for exactly this string.
    ///
    /// No wildcard, no second path, no daemon. `tools/uninstall_driver.sh` runs
    /// the same command through the same prompt.
    static var removalCommand: String { "/bin/rm -rf '\(driverPath)'" }

    /// Whether a removal restarts `coreaudiod`. It never does: the loaded copy
    /// survives until the next restart, and cutting audio for every running
    /// process is the user's decision, not a side effect of uninstalling. The
    /// advice in `restartAdvice` is text; nothing here executes it.
    static let restartsCoreAudio = false

    /// What is at the HAL path, read without privileges.
    struct Identity: Equatable {
        var isPresent: Bool
        var isSymlink: Bool
        var isDirectory: Bool
        var bundleIdentifier: String?

        init(isPresent: Bool, isSymlink: Bool, isDirectory: Bool, bundleIdentifier: String?) {
            self.isPresent = isPresent
            self.isSymlink = isSymlink
            self.isDirectory = isDirectory
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// What to do about it.
    enum Decision: Equatable {
        case remove
        case nothingToRemove
        case refuse(String)
    }

    /// The checks `uninstall_driver.sh` performs, as a pure function.
    ///
    /// Order matters: a symlink first (a link is not a bundle even when it
    /// points at one), then absence, then shape, then identity. A bundle whose
    /// `Info.plist` cannot be read is unidentifiable and is left alone.
    static func decide(_ identity: Identity) -> Decision {
        if identity.isSymlink {
            return .refuse("the HAL path is a symlink, not a bundle")
        }
        guard identity.isPresent else { return .nothingToRemove }
        guard identity.isDirectory else {
            return .refuse("the HAL path is a file, not a bundle")
        }
        guard let identifier = identity.bundleIdentifier, !identifier.isEmpty else {
            return .refuse("the bundle has no readable Info.plist")
        }
        guard identifier == expectedBundleIdentifier else {
            return .refuse("the HAL path declares '\(identifier)', not \(expectedBundleIdentifier)")
        }
        return .remove
    }

    /// What a removal deletes. The confirmation sheet shows this list verbatim.
    static let removed: [String] = [
        driverPath,
        "Onboarding state, so the next launch explains the install again",
    ]

    /// What a removal keeps, and why. Nothing here is deleted by the app: EQ
    /// values live in the user's defaults (`eq_default_*`) and survive a
    /// reinstall on purpose, and the logs are what a reinstall gets diagnosed
    /// from.
    static let kept: [String] = [
        "The SoundBridge app itself",
        "EQ settings and the saved EQ configuration",
        "Logs in ~/Library/Logs/SoundBridge",
    ]

    /// The one thing this policy cannot do for the user, stated and never run.
    static let restartAdvice = "coreaudiod keeps its loaded copy until it restarts. Log out and back in, or restart the Mac, when you are ready."
}
