import Foundation
import AppKit

/// Performs the removal `DriverUninstallPolicy` describes.
///
/// This is the app's only privileged command, and it is deliberately a single
/// string in a single file: the policy decided *whether* to remove, this only
/// runs the removal and then asks the filesystem whether it happened. Nothing
/// is staged, copied, chowned or restarted, and no wildcard path is touched.
enum DriverUninstaller {

    enum Failure: LocalizedError {
        /// Authorization was cancelled, or the path survived the command.
        case removalDidNotComplete(String)

        var errorDescription: String? {
            switch self {
            case .removalDidNotComplete(let detail):
                return "The driver could not be removed: \(detail)"
            }
        }
    }

    /// Read the HAL path without privileges.
    ///
    /// This is what makes "identify before deleting" possible: the check runs in
    /// the app's own process, before any administrator prompt is shown, so the
    /// user is never asked for a password to delete something that is not this
    /// driver.
    static func readIdentity(fileManager: FileManager = .default) -> DriverUninstallPolicy.Identity {
        let path = DriverUninstallPolicy.driverPath
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let isSymlink = (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)

        // A symlink is reported as present so the policy can refuse it by name
        // instead of calling it "nothing to remove".
        let plist = exists && !isSymlink
            ? NSDictionary(contentsOfFile: DriverBundleLocation.infoPlistPath)
            : nil

        return DriverUninstallPolicy.Identity(
            isPresent: exists || isSymlink,
            isSymlink: isSymlink,
            isDirectory: isDirectory.boolValue,
            bundleIdentifier: plist?["CFBundleIdentifier"] as? String
        )
    }

    /// Run the removal and verify it.
    ///
    /// The prompt can be dismissed in ways `osascript` reports as success, and
    /// an AppleScript error is not proof that nothing ran, so the filesystem is
    /// the only authority. A throw means "the driver may still be installed":
    /// the caller must not clear state or claim success.
    static func remove(fileManager: FileManager = .default) throws {
        let script = "do shell script \"\(DriverUninstallPolicy.removalCommand)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)

        guard (try? fileManager.attributesOfItem(atPath: DriverUninstallPolicy.driverPath)) == nil else {
            let detail = (error?["NSAppleScriptErrorMessage"] as? String)
                ?? "the path still exists after the removal command"
            throw Failure.removalDidNotComplete(detail)
        }
    }
}
