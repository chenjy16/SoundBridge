import Foundation

/// Where the HAL driver lives, and what identifies it as ours.
///
/// One constant for three readers that used to spell the path out themselves:
/// the installer package writes here, the version gate reads here, and the
/// uninstall path deletes only here (`DriverUninstallPolicy`). The identifier is
/// the same one `tools/uninstall_driver.sh` checks before it removes anything,
/// so a directory that merely shares the name is never treated as this driver.
enum DriverBundleLocation {
    /// The only path this product installs to or removes from.
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"

    /// The bundle identifier a directory at `driverPath` must declare.
    static let bundleIdentifier = "com.soundbridge.driver"

    /// The plist that carries that identifier.
    static var infoPlistPath: String { driverPath + "/Contents/Info.plist" }
}

/// What this build knows about the installed HAL driver.
///
/// It does not install one (P4 Batch 1A). Until this change the app carried a
/// second install transaction — an `osascript` that copied the bundle out of
/// `Contents/Resources`, `chown`/`chmod`-ed it, renamed it into the HAL
/// directory and ended with `killall coreaudiod` — while the package in `dist/`
/// performed the same replace through `tools/sb_install_transaction.sh`, with a
/// staging copy, a backup, a verification pass and a rollback.
///
/// Two implementations meant two safety levels for one operation. The app's
/// version could leave a half-copied bundle behind on a full disk, could not
/// roll back, and cut audio for every running process on the way out. None of
/// that was true of the package. So the package is now the only thing that
/// writes to `/Library/Audio/Plug-Ins/HAL`, onboarding points at it
/// (`DriverInstallGuide`), and this type is a read-only view of the result.
final class DriverInstaller {
    /// Path of the installed driver bundle — the one the package writes.
    private var installedDriverURL: URL {
        URL(fileURLWithPath: DriverBundleLocation.driverPath)
    }

    /// Compare what is installed right now against what this build ships.
    ///
    /// Reading the installed `Info.plist` is cheap, unprivileged and safe to run
    /// at launch. Every install decision resolves through here, and after P4
    /// Batch 1A this is the *only* way the app learns that an install worked:
    /// the installer package runs in its own process, so the page that pointed
    /// at it turns green from the filesystem, never from "the user clicked".
    func currentInstallStatus() -> DriverVersionStatus {
        DriverVersionGate.evaluate(
            bundleURL: installedDriverURL,
            expectedVersion: VersionManager.bundledDriverVersion() ?? "",
            expectedProtocol: DriverVersionGate.expectedProtocolVersion
        )
    }

    /// Whether a driver bundle exists at the install path.
    ///
    /// This is a display helper, not an install gate — a bundle can exist and
    /// still be the wrong version. Use `currentInstallStatus()` for decisions.
    ///
    /// Phase 2.1.4 removed `isDriverLoaded()`, which used to sit above this and
    /// shell out to `system_profiler SPAudioDataType` looking for the word
    /// "SoundBridge". That output lists audio *devices*, not loaded bundles, so
    /// the answer mixed "HAL loaded the driver" with "the Host created a proxy
    /// device" and was wrong whenever the Host was down. The Host's lifecycle
    /// report answers it properly, per level, via IPC.
    func isDriverInstalled() -> Bool {
        FileManager.default.fileExists(atPath: installedDriverURL.path)
    }
}
