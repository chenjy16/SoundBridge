import Foundation
@preconcurrency import AppKit

/// Driver installation states
enum DriverInstallState: Equatable {
    case notStarted
    case checkingExisting
    case copying
    case settingPermissions
    case restartingAudio
    case verifying
    case complete
    case failed(String)

    var isComplete: Bool {
        if case .complete = self {
            return true
        }
        return false
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    var description: String {
        switch self {
        case .notStarted:
            return "Ready to install"
        case .checkingExisting:
            return "Checking for existing driver..."
        case .copying:
            return "Copying driver files..."
        case .settingPermissions:
            return "Setting permissions..."
        case .restartingAudio:
            return "Restarting audio system..."
        case .verifying:
            return "Verifying installation..."
        case .complete:
            return "Installation complete!"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

/// Handles driver installation and verification
class DriverInstaller: ObservableObject {
    @Published var state: DriverInstallState = .notStarted
    @Published var progress: Double = 0.0

    private let driverName = "SoundBridgeDriver.driver"
    private let driverDestination = "/Library/Audio/Plug-Ins/HAL"

    /// Path of the driver bundle this app installs.
    private var installedDriverURL: URL {
        URL(fileURLWithPath: "\(driverDestination)/\(driverName)")
    }

    /// Compare what is installed right now against what this build ships.
    ///
    /// Reading the installed `Info.plist` is cheap, unprivileged and safe to run
    /// at launch. Every install decision resolves through here, so the privileged
    /// copy step only runs for a reason the caller can name.
    func currentInstallStatus() -> DriverVersionStatus {
        DriverVersionGate.evaluate(
            bundleURL: installedDriverURL,
            expectedVersion: VersionManager.bundledDriverVersion() ?? "",
            expectedProtocol: DriverVersionGate.expectedProtocolVersion
        )
    }

    /// Install the driver with progress updates.
    ///
    /// A previous version short-circuited on `isDriverInstalled()`, so a version
    /// mismatch detected at launch was never repaired: the call returned
    /// `.complete` without copying anything, and the caller reported a successful
    /// update that never happened. The gate below replaces that check.
    ///
    /// The caller must say *why* it is installing. A launch check that noticed a
    /// version mismatch can no longer reach the privileged copy step by accident:
    /// it has no intent to pass. Only `OnboardingView`'s first-install flow does.
    func installDriver(intent: DriverInstallIntent) async throws {
        await MainActor.run { state = .checkingExisting; progress = 0.1 }

        let status = currentInstallStatus()
        print("Driver install gate: intent=\(intent.summary) status=\(status.summary)")

        guard intent.permits(status) else {
            print("Driver install gate: \(intent.summary) is not allowed against \(status.summary)")
            throw DriverInstallError.intentDoesNotMatchStatus(
                intent: intent.summary,
                status: status.summary
            )
        }

        await MainActor.run { state = .copying; progress = 0.3 }

        // Find driver bundle in app resources
        guard let driverSource = findDriverBundle() else {
            throw DriverInstallError.driverNotFound
        }

        // Install driver with single admin prompt (copy + permissions + restart)
        try await installDriverWithPrivileges(from: driverSource)

        // Update progress through the stages
        await MainActor.run { state = .settingPermissions; progress = 0.5 }

        await MainActor.run { state = .restartingAudio; progress = 0.7 }

        // Wait for audio system to restart
        print("Waiting for audio system to restart...")
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        await MainActor.run { state = .verifying; progress = 0.9 }

        // Verify by re-running the same gate rather than looking for the file.
        // File existence was exactly what let a stale driver pass verification.
        let verified = currentInstallStatus()
        guard verified.isCompatible else {
            print("Driver verification failed: \(verified.summary)")
            throw DriverInstallError.verificationFailed
        }

        await MainActor.run { state = .complete; progress = 1.0 }
        print("Driver installed successfully: \(verified.summary)")
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

    /// Find driver bundle in app resources
    private func findDriverBundle() -> String? {
        // For development: check if running from build directory
        if let bundlePath = Bundle.main.resourcePath {
            let driverPath = "\(bundlePath)/\(driverName)"
            if FileManager.default.fileExists(atPath: driverPath) {
                return driverPath
            }
        }

        // For production: driver should be in Resources
        if let resourcePath = Bundle.main.path(forResource: "SoundBridgeDriver", ofType: "driver") {
            return resourcePath
        }

        print("WARNING: Driver bundle not found in app resources")
        return nil
    }

    /// Install driver with single admin prompt (combines copy, permissions, and restart)
    private func installDriverWithPrivileges(from source: String) async throws {
        // Escape single quotes in paths for shell
        let escapedSource = source.replacingOccurrences(of: "'", with: "'\\''")
        let driverPath = "\(driverDestination)/\(driverName)"
        let escapedDriverPath = driverPath.replacingOccurrences(of: "'", with: "'\\''")

        // Staged replace, not a merge.
        //
        // `cp -R src dest/` against an existing bundle copies *into* it: every
        // file the incoming build does not contain survives. An upgrade could
        // therefore leave a half-old, half-new driver that still reports the new
        // version from its Info.plist — the half-installed state that makes
        // "installed version" and "what is actually loaded" disagree.
        //
        // The new bundle is staged next to the old one in the same directory and
        // swapped in by rename, so the installed bundle is always exactly the one
        // this app ships, and the window in which no bundle exists is one rename
        // rather than one recursive copy.
        let stagingPath = "\(driverDestination)/.\(driverName).new"
        let escapedStaging = stagingPath.replacingOccurrences(of: "'", with: "'\\''")

        // Combine all operations into single command chain
        let script = """
        do shell script "rm -rf '\(escapedStaging)' && \
        cp -R '\(escapedSource)' '\(escapedStaging)' && \
        chown -R root:wheel '\(escapedStaging)' && \
        chmod -R 755 '\(escapedStaging)' && \
        rm -rf '\(escapedDriverPath)' && \
        mv '\(escapedStaging)' '\(escapedDriverPath)' && \
        killall coreaudiod" with administrator privileges
        """

        // Run AppleScript on background queue to avoid blocking UI
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let appleScript = NSAppleScript(source: script)
                var errorDict: NSDictionary?
                appleScript?.executeAndReturnError(&errorDict)

                if let errorDict = errorDict,
                   let errorMessage = errorDict["NSAppleScriptErrorMessage"] as? String {
                    print("Failed to install driver: \(errorMessage)")
                    continuation.resume(throwing: DriverInstallError.copyFailed(errorMessage))
                } else {
                    print("Driver installed and coreaudiod restarted")
                    continuation.resume()
                }
            }
        }
    }

    // Phase 2.1.4 removed three unused private helpers here:
    // `copyDriverWithPrivileges`, `setDriverPermissions` and `restartAudio`.
    //
    // `installDriverWithPrivileges` already performs all three steps in one
    // `do shell script ... with administrator privileges`, so these were never
    // called. Keeping them cost more than dead bytes: each was a separate site
    // that could ask for admin rights and a separate `killall coreaudiod` in the
    // source tree, which makes "what can this build do without a user action?"
    // harder to answer than it should be. There is now exactly one privileged
    // code path, and it is reachable only from `installDriver(intent:)` after an
    // intent check and an explicit user action.
}

/// Driver installation errors
enum DriverInstallError: Error, LocalizedError {
    case driverNotFound
    case copyFailed(String)
    case verificationFailed
    /// The caller asked for something the installed state does not justify — a
    /// first install over an existing bundle, or an upgrade over a compatible or
    /// newer one.
    case intentDoesNotMatchStatus(intent: String, status: String)

    var errorDescription: String? {
        switch self {
        case .intentDoesNotMatchStatus(let intent, let status):
            return "Refusing to install (\(intent)) against an installed driver that does not need it (\(status))"
        case .driverNotFound:
            return "Driver bundle not found in app resources"
        case .copyFailed(let message):
            return "Failed to copy driver: \(message)"
        case .verificationFailed:
            return "Driver installation could not be verified"
        }
    }
}
