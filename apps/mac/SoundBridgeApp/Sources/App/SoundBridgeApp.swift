import SwiftUI
import Foundation
import Darwin
import AppKit
import CoreText
import CoreGraphics
import CoreAudio
import Sparkle

// Main entry point - AppKit-based app with SwiftUI views
@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var hostProcess: Process?
    var eventMonitor: EventMonitor?
    var onboardingCoordinator: OnboardingCoordinator?
    var updaterController: SPUStandardUpdaterController?
    var driverUpdateWindow: DriverUpdateWindow?
    /// Set to true during uninstall to suppress Host terminationHandler from
    /// calling NSApp.terminate prematurely.
    var isUninstalling = false
    /// One compatibility alert per launch. The check runs once anyway; this keeps
    /// a future second caller from stacking windows on top of each other.
    private var didPresentCompatibilityNotice = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register custom font
        registerCustomFont()

        // Initialize Sparkle updater
        initializeUpdater()

        // Check if onboarding is needed
        if !OnboardingState.hasCompleted() {
            // Will switch to .regular in showOnboarding()
            showOnboarding()
            return
        }

        // Onboarding complete - run as menu bar app only
        NSApp.setActivationPolicy(.accessory)

        // Check for driver version mismatch (lazy update)
        checkDriverVersionMismatch()

        // Launch audio host if not already running
        launchHostIfNeeded()

        // Start IPC monitoring for device state updates from Host
        IPCController.shared.onDeviceStateChanged = { [weak self] state in
            VolumeController.shared.refreshDeviceList()
            VolumeController.shared.findAndBindProxyDevice()
            self?.applyHostLifecycle(state.lifecycle)
        }
        IPCController.shared.startMonitoring()

        // The lock decides "is a Host alive"; the report decides what it is doing.
        // Reading only the file is how a killed Host kept looking healthy.
        applyHostLifecycle(IPCController.shared.latestLifecycle)

        // Retry proxy device binding after a short delay to handle the race
        // where Host hasn't created the proxy device yet at startup.
        // Run on background queue to avoid blocking main thread if CoreAudio HAL
        // is slow to respond (e.g. coreaudiod proxy system not ready).
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
            VolumeController.shared.refreshDeviceList()
            VolumeController.shared.findAndBindProxyDevice()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) {
            VolumeController.shared.refreshDeviceList()
            VolumeController.shared.findAndBindProxyDevice()
        }

        // Set up menu bar UI
        setupMenuBar()
    }

    func initializeUpdater() {
        // Without a feed URL and EdDSA public key in Info.plist, Sparkle reports
        // "Unable to check for updates" on every launch. Stay quiet until the
        // release feed is configured.
        guard VersionManager.isUpdaterConfigured else {
            print("⚠️ Update feed not configured (SUFeedURL/SUPublicEDKey) - Sparkle disabled")
            return
        }

        // Initialize Sparkle with standard user driver
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        print("✓ Sparkle updater initialized")

        // Trigger a background check on launch so updates are offered immediately
        updaterController?.updater.checkForUpdatesInBackground()
    }

    /// Inspect the installed driver at launch and record what was found.
    ///
    /// Phase 2.1.3 removed the prompt this used to raise. The gate still runs so
    /// a mismatch is visible in logs and in the returned status, but nothing on
    /// this path may open a window: an unsolicited upgrade prompt is a product
    /// decision this build does not make. See `DriverUpgradePolicy`.
    ///
    /// `showDriverUpdatePrompt` / `performDriverUpdate` are kept intact and
    /// deliberately unwired — the capability stays tested, the entry point is
    /// not shipped.
    @discardableResult
    func checkDriverVersionMismatch() -> DriverVersionStatus {
        let status = DriverInstaller().currentInstallStatus()

        switch status {
        case .notInstalled:
            print("Driver not installed - no version check to run")
        case .compatible:
            print("✓ Driver is up to date (\(status.summary))")
        case .newer:
            // Overwriting a newer driver with an older one is a silent downgrade.
            print("Installed driver is newer than this build - leaving it alone (\(status.summary))")
        case .expectedVersionUnavailable:
            print("Bundled driver version is unknown - skipping version check")
        case .outdated, .metadataUnreadable, .protocolIncompatible:
            // Recorded, not acted on. No install, no download, no coreaudiod
            // restart — but also not silent: a user with no audio deserves the
            // reason. The notice carries no install action (2.1.4 §2.4).
            print("Driver is not usable by this build (\(status.summary)); no upgrade prompt is shown")
        }

        presentCompatibilityNoticeIfNeeded(status)
        return status
    }

    /// Explain an unusable driver once per launch.
    ///
    /// Text only. `DriverCompatibilityNotice` has no install path, this method
    /// calls nothing privileged, and the download location comes from the app's
    /// own `SUFeedURL` rather than from a URL typed in here.
    ///
    /// `shouldPresent` is checked separately from `make` since Phase 3.2C:
    /// `make` now also describes "the driver is newer than this app", which is a
    /// state to explain on screen rather than an alert to raise at launch. This
    /// guard is what keeps that notice off the launch path.
    private func presentCompatibilityNoticeIfNeeded(_ status: DriverVersionStatus) {
        guard !didPresentCompatibilityNotice else { return }
        guard DriverCompatibilityNotice.shouldPresent(for: status) else { return }
        guard let notice = DriverCompatibilityNotice.make(
            for: status,
            appVersion: VersionManager.appVersion() ?? "unknown",
            releasePageURL: DriverCompatibilityNotice.configuredReleasePageURL
        ) else {
            return
        }

        didPresentCompatibilityNotice = true
        print("[Compatibility] \(notice.lines.joined(separator: " | "))")
        showAlert(notice.title, notice.message)
    }

    /// Fold the Host's lifecycle report into the state the UI shows.
    ///
    /// Two inputs on purpose: the instance lock answers "is a Host alive" and the
    /// report answers "what is it doing". Trusting either one alone is the bug
    /// this replaces — a stale `ready` file from a killed Host, or a live Host
    /// that never found its proxy device and said nothing.
    private func applyHostLifecycle(_ report: HostLifecycleReport?) {
        let state = HostRunState.resolve(
            report: report,
            hostRunning: HostInstanceProbe.isHostRunning()
        )
        HostStatusModel.shared.update(state, report: report)

        if state.isProblem {
            print("[HostState] \(state.shortMessage) — \(report?.detail ?? "no detail reported")")
        }
    }

    /// Present the driver update window.
    ///
    /// Not called from any launch path as of Phase 2.1.3. Kept so a future
    /// release can wire it to an explicit user action without rebuilding the
    /// upgrade flow from scratch.
    ///
    /// The policy check is deliberately inside the function rather than at each
    /// call site: one switch is easier to review than an argument about whether
    /// every caller remembered, and it means a future caller cannot ship an
    /// unsolicited prompt by accident.
    func showDriverUpdatePrompt(currentVersion: String, newVersion: String) {
        guard DriverUpgradePolicy.allowsUserFacingPrompt else {
            print("Driver update prompt suppressed by DriverUpgradePolicy (\(currentVersion) -> \(newVersion))")
            return
        }

        // Close existing window if any
        driverUpdateWindow?.close()

        // Create and show driver update window
        driverUpdateWindow = DriverUpdateWindow(
            currentVersion: currentVersion,
            newVersion: newVersion,
            onUpdate: { [weak self] in
                self?.performDriverUpdate()
            },
            onDismiss: { [weak self] in
                self?.driverUpdateWindow?.close()
                self?.driverUpdateWindow = nil
            }
        )

        driverUpdateWindow?.center()
        driverUpdateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func performDriverUpdate() {
        // Close the update window
        driverUpdateWindow?.close()
        driverUpdateWindow = nil

        // Use existing DriverInstaller logic. The install intent is derived from
        // the current status rather than assumed: this is an upgrade path, so a
        // first install cannot be launched from here, and a compatible or newer
        // driver is refused by the installer's intent check.
        let installer = DriverInstaller()

        Task {
            do {
                let status = installer.currentInstallStatus()
                guard let intent = status.installIntent, !intent.isFirstInstall else {
                    print("Driver update requested but nothing to upgrade (\(status.summary))")
                    return
                }

                try await installer.installDriver(intent: intent)

                // Re-read the gate instead of trusting the call above. This is
                // what makes a phantom "updated to X" alert impossible: the
                // alert now reflects what is actually on disk.
                let verified = installer.currentInstallStatus()
                print("Driver update finished: \(verified.summary)")

                await MainActor.run {
                    let alert = NSAlert()
                    if verified.isCompatible {
                        alert.messageText = "Driver Updated"
                        alert.informativeText = "The SoundBridge audio driver has been updated to version \(VersionManager.bundledDriverVersion() ?? "unknown")."
                        alert.alertStyle = .informational
                    } else if case .newer = verified {
                        alert.messageText = "Driver Kept"
                        alert.informativeText = "The installed driver is newer than this build, so it was left untouched (\(verified.summary))."
                        alert.alertStyle = .informational
                    } else {
                        alert.messageText = "Update Failed"
                        alert.informativeText = "The driver still does not match this build: \(verified.summary)"
                        alert.alertStyle = .critical
                    }
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                print("Driver update failed: \(error)")
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Update Failed"
                    alert.informativeText = "Failed to update driver: \(error.localizedDescription)"
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    func showOnboarding() {
        // Switch to regular activation policy to show window properly
        NSApp.setActivationPolicy(.regular)

        // Create and show onboarding
        onboardingCoordinator = OnboardingCoordinator()
        onboardingCoordinator?.show(onComplete: { [weak self] in
            print("Onboarding completion callback called")
            self?.launchHostIfNeeded()
            self?.setupMenuBar()
            // Retry proxy binding after host has time to start
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
                VolumeController.shared.refreshDeviceList()
                VolumeController.shared.findAndBindProxyDevice()
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) {
                VolumeController.shared.refreshDeviceList()
                VolumeController.shared.findAndBindProxyDevice()
            }
            print("Host and menu bar setup complete")
        })

        print("Showing onboarding")
    }

    func setupMenuBar() {
        print("setupMenuBar() called")

        // Hide from Dock (menu bar only)
        NSApp.setActivationPolicy(.accessory)
        print("Activation policy set to .accessory")

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        print("Status bar item created: \(statusItem != nil)")

        if let button = statusItem?.button {
            // Load logo SVG and set as template for light/dark mode adaptation
            if let logoImage = loadLogoImage() {
                logoImage.isTemplate = true // Makes it adapt to light/dark mode
                button.image = logoImage
            } else {
                // Fallback to system icon if logo fails to load
                button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "SoundBridge")
            }
            button.action = #selector(togglePopover)
            button.target = self
            print("Status bar button configured with waveform icon")
        } else {
            print("ERROR: Could not get status bar button!")
        }

        // Create popover with menu content
        popover = NSPopover()
        popover?.behavior = .transient
        popover?.animates = false
        popover?.contentViewController = NSHostingController(rootView: MenuBarView())
        
        // Set up event monitor to dismiss popover when clicking outside
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let popover = self?.popover, popover.isShown {
                self?.popover?.performClose(event)
            }
        }
        print("Menu bar setup complete - icon should be visible")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // If uninstalling, driver and host are already gone — skip heavy cleanup
        if isUninstalling {
            print("=== applicationWillTerminate (uninstall mode, skipping cleanup) ===")
            return
        }

        let logsDir = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Logs/SoundBridge")

        try? FileManager.default.createDirectory(
            at: logsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let logFile = logsDir.appendingPathComponent("app.log").path

        // Open log file handle once and reuse for all messages
        let logHandle: FileHandle? = {
            if !FileManager.default.fileExists(atPath: logFile) {
                FileManager.default.createFile(atPath: logFile, contents: nil)
            }
            let handle = FileHandle(forWritingAtPath: logFile)
            handle?.seekToEndOfFile()
            return handle
        }()

        func log(_ message: String) {
            let logMessage = "[\(Date())] \(message)\n"
            if let data = logMessage.data(using: .utf8) {
                logHandle?.write(data)
            }
            print(message)
        }

        log("=== applicationWillTerminate CALLED ===")

        // Clean up CoreAudio listeners to prevent leaks
        VolumeController.shared.cleanup()

        // Stop IPC monitoring
        IPCController.shared.stopMonitoring()

        // Perform cleanup directly from the app
        performCleanup(logger: log)

        terminateHostAndProxies(logger: log)

        logHandle?.closeFile()
        print("=== applicationWillTerminate COMPLETE ===")
    }

    /// Best-effort fallback to stop any running SoundBridgeHost even if we did not launch it.
    private func terminateHostAndProxies(logger: (String) -> Void) {
        if let process = hostProcess, process.isRunning {
            logger("Terminating tracked host process (pid \(process.processIdentifier))...")
            process.terminate()
            waitForProcessExit(process, timeout: 0.15, logger: logger)
            if process.isRunning {
                logger("Host still running, sending SIGKILL")
                kill(process.processIdentifier, SIGKILL)
            }
        }

        logger("Attempting best-effort shutdown via pgrep/kill for any remaining hosts")

        let pgrep = Process()
        pgrep.launchPath = "/usr/bin/pgrep"
        pgrep.arguments = ["-f", "SoundBridgeHost"]

        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()

        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            logger("Failed to run pgrep: \(error)")
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .compactMap({ Int32($0) }),
              !output.isEmpty else {
            logger("No additional SoundBridgeHost processes found")
            return
        }

        for pid in output {
            guard pid != getpid() else { continue }
            logger("Sending SIGTERM to SoundBridgeHost pid \(pid)")
            kill(pid, SIGTERM)
            if !waitForPIDExit(pid, timeout: 0.15) {
                logger("PID \(pid) still alive, sending SIGKILL")
                kill(pid, SIGKILL)
            }
        }

        // Remove any lingering shared memory/control files so the driver tears down proxies
        cleanupTempIPC(logger: logger)
    }

    /// Poll a Process for exit up to timeout seconds.
    private func waitForProcessExit(_ process: Process, timeout: TimeInterval, logger: (String) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            logger("Process \(process.processIdentifier) did not exit within \(timeout)s")
        }
    }

    /// Poll a PID for exit up to timeout seconds.
    private func waitForPIDExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 {
                return true // no longer running
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return kill(pid, 0) != 0
    }

    /// Clean up temporary files that keep proxies alive.
    ///
    /// `.lock` files are skipped. The Host's single-instance lock lives in the
    /// same directory, and unlinking it is not harmless: the next Host creates a
    /// *new* inode and locks that, so two Hosts can each believe they are the only
    /// one. A leftover lock file costs nothing; a deleted one costs a shared
    /// memory mapping.
    private func cleanupTempIPC(logger: (String) -> Void) {
        let fm = FileManager.default
        let controlFile = "/tmp/soundbridge-devices.txt"
        if fm.fileExists(atPath: controlFile) {
            logger("Removing control file \(controlFile)")
            unlink(controlFile)
        }

        // Remove shared memory files the driver might watch
        if let tmpItems = try? fm.contentsOfDirectory(atPath: "/tmp") {
            for item in tmpItems where item.hasPrefix("soundbridge-") {
                if item.hasSuffix(HostInstanceProbe.lockSuffix) {
                    logger("Keeping instance lock file /tmp/\(item)")
                    continue
                }
                let path = "/tmp/\(item)"
                logger("Removing shared memory file \(path)")
                unlink(path)
            }
        }
    }

    func performCleanup(logger: (String) -> Void = { print($0) }) {
        logger("[Cleanup] Starting cleanup process...")

        // 1. Restore default device to physical device (if currently on proxy)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var currentDeviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        if AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &currentDeviceID
        ) == noErr {
            // Get current device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

            let nameStatus = withUnsafeMutablePointer(to: &deviceName) { ptr in
                AudioObjectGetPropertyData(currentDeviceID, &nameAddress, 0, nil, &nameSize, ptr)
            }
            if nameStatus == noErr, let name = deviceName?.takeUnretainedValue() as String? {

                // If currently on a SoundBridge proxy, switch back to physical device
                if name.contains("SoundBridge") {
                    logger("[Cleanup] Currently on proxy device: \(name)")

                    // Get proxy UID
                    var uidAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )

                    var deviceUID: Unmanaged<CFString>?
                    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

                    let uidStatus = withUnsafeMutablePointer(to: &deviceUID) { ptr in
                        AudioObjectGetPropertyData(currentDeviceID, &uidAddress, 0, nil, &uidSize, ptr)
                    }
                    if uidStatus == noErr, let proxyUIDStr = deviceUID?.takeUnretainedValue() as String? {

                        // Extract physical device UID (remove "-soundbridge" suffix)
                        if let physicalUID = proxyUIDStr.components(separatedBy: "-soundbridge").first {
                            logger("[Cleanup] Looking for physical device with UID: \(physicalUID)")

                            // Find the physical device
                            if let physicalDeviceID = findDeviceByUID(physicalUID) {
                                logger("[Cleanup] Restoring default device to physical device (ID: \(physicalDeviceID))")

                                var newDeviceID = physicalDeviceID
                                let result = AudioObjectSetPropertyData(
                                    AudioObjectID(kAudioObjectSystemObject),
                                    &propertyAddress,
                                    0,
                                    nil,
                                    UInt32(MemoryLayout<AudioDeviceID>.size),
                                    &newDeviceID
                                )

                                // Also restore system output device
                                var systemAddress = AudioObjectPropertyAddress(
                                    mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                    mScope: kAudioObjectPropertyScopeGlobal,
                                    mElement: kAudioObjectPropertyElementMain
                                )
                                var systemDeviceID = physicalDeviceID
                                AudioObjectSetPropertyData(
                                    AudioObjectID(kAudioObjectSystemObject),
                                    &systemAddress,
                                    0,
                                    nil,
                                    UInt32(MemoryLayout<AudioDeviceID>.size),
                                    &systemDeviceID
                                )

                                if result == noErr {
                                    logger("[Cleanup] Restored to physical device")
                                    // CoreAudio device switch is synchronous, no sleep needed
                                } else {
                                    logger("[Cleanup] WARNING: Failed to restore device (error \(result))")
                                }
                            } else {
                                logger("[Cleanup] WARNING: Could not find physical device with UID: \(physicalUID)")
                            }
                        }
                    }
                } else {
                    logger("[Cleanup] Already on physical device: \(name)")
                }
            }
        }

        // 2. Remove control file - driver will detect and remove proxies
        let controlFilePath = "/tmp/soundbridge-devices.txt"
        logger("[Cleanup] Removing control file: \(controlFilePath)")
        unlink(controlFilePath)

        // 3. Wait for driver to remove devices (driver polls every 100ms)
        logger("[Cleanup] Waiting for driver to remove proxy devices...")
        Thread.sleep(forTimeInterval: 0.5)

        logger("[Cleanup] Cleanup complete")
    }

    func findDeviceByUID(_ targetUID: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        // Find device with matching UID
        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

            let uidStatus = withUnsafeMutablePointer(to: &deviceUID) { ptr in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
            }
            if uidStatus == noErr, let uid = deviceUID?.takeUnretainedValue() as String? {
                if uid == targetUID {
                    return deviceID
                }
            }
        }

        return nil
    }

    // Phase 2.1.4 removed `checkAndLoadDriverIfNeeded()` and `isDriverLoaded()`
    // from this class. Both were dead (zero call sites) and neither answered a
    // question this build is allowed to act on.
    //
    // `isDriverLoaded()` shelled out to `system_profiler SPAudioDataType`, which
    // lists *audio devices* — proxies the Host creates — so it reported a
    // missing driver whenever the Host was down, and conflated "HAL loaded the
    // bundle" with "a proxy device exists".
    //
    // `checkAndLoadDriverIfNeeded()` would have requested admin rights to run
    // `killall coreaudiod` as part of a launch check, and shown developer text
    // (`cd packages/driver && ./install.sh`) to end users. Phase 2.1.4 forbids
    // both.
    //
    // The question they were reaching for is now answered by the Host's own
    // lifecycle report (`driverFile`, `driverLoad`, `halDiscovery`,
    // `proxyDevice`), which arrives through IPC and is rendered by
    // `HostRunState`. Nothing on the app side inspects the HAL directory or
    // restarts `coreaudiod`; the only remaining caller of `killall coreaudiod`
    // is `DriverInstaller`, inside an explicit install after a user action.

    /// Launch the Host unless one already holds this user's instance lock.
    ///
    /// The lock replaced `pgrep -f SoundBridgeHost`. Process-name matching had no
    /// atom — two launches a millisecond apart both saw "not running" — and it
    /// matched any command line containing the string. The Host now takes an
    /// exclusive `flock` for its whole life, so asking the same file is both
    /// raceless and immune to look-alikes.
    func launchHostIfNeeded() {
        if HostInstanceProbe.isHostRunning() {
            let owner = HostInstanceProbe.ownerDescription() ?? "owner unknown"
            print("SoundBridgeHost already running (\(owner)); not starting a second one")
            applyHostLifecycle(IPCController.shared.latestLifecycle)
            return
        }

        print("No SoundBridgeHost owns \(HostInstanceProbe.lockPath()); launching one")
        startHost()
    }

    func startHost() {
        // Find the host executable - try multiple possible locations
        let fileManager = FileManager.default
        var possiblePaths: [String] = []

        // PRIORITY 1: Check for auxiliary executable in .app bundle (production)
        if let helperURL = Bundle.main.url(forAuxiliaryExecutable: "SoundBridgeHost") {
            possiblePaths.append(helperURL.path)
        }

        // PRIORITY 2: Check for embedded binary in MacOS directory (for distribution)
        if let executablePath = Bundle.main.executableURL?.deletingLastPathComponent().path {
            let embeddedHost = "\(executablePath)/SoundBridgeHost"
            possiblePaths.append(embeddedHost)
        }

        // PRIORITY 3: Check Contents/Helpers/ directory
        if let bundlePath = Bundle.main.bundlePath as String? {
            possiblePaths.append("\(bundlePath)/Contents/Helpers/SoundBridgeHost")
        }

        #if DEBUG
        // Development builds - relative to app bundle
        var possibleBasePaths: [String] = []

        if let appPath = Bundle.main.bundlePath as String? {
            // If running from Xcode/build, go up to project root
            let appURL = URL(fileURLWithPath: appPath)
            if appPath.contains("/SoundBridgeApp/") {
                let projectRoot = appURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                possibleBasePaths.append(projectRoot.path)
            }
        }

        // Try current working directory
        if let cwd = fileManager.currentDirectoryPath as String? {
            possibleBasePaths.append(cwd)
        }

        // Try home directory
        if let homeDir = ProcessInfo.processInfo.environment["HOME"] {
            possibleBasePaths.append("\(homeDir)/soundbridge")
        }

        // Build development paths
        for basePath in possibleBasePaths {
            // Try release build (with architecture subdirectory)
            if let arch = getArchitecture() {
                possiblePaths.append("\(basePath)/packages/host/.build/\(arch)/release/SoundBridgeHost")
            }
            possiblePaths.append("\(basePath)/packages/host/.build/release/SoundBridgeHost")
            // Try debug build
            if let arch = getArchitecture() {
                possiblePaths.append("\(basePath)/packages/host/.build/\(arch)/debug/SoundBridgeHost")
            }
            possiblePaths.append("\(basePath)/packages/host/.build/debug/SoundBridgeHost")
        }

        // Also try absolute path based on current user
        if let homeDir = ProcessInfo.processInfo.environment["HOME"] {
            if let arch = getArchitecture() {
                possiblePaths.append("\(homeDir)/soundbridge/packages/host/.build/\(arch)/release/SoundBridgeHost")
            }
            possiblePaths.append("\(homeDir)/soundbridge/packages/host/.build/release/SoundBridgeHost")
        }

        // Try environment variable if set
        if let soundbridgeRoot = ProcessInfo.processInfo.environment["SOUNDBRIDGE_ROOT"] {
            if let arch = getArchitecture() {
                possiblePaths.append("\(soundbridgeRoot)/packages/host/.build/\(arch)/release/SoundBridgeHost")
            }
            possiblePaths.append("\(soundbridgeRoot)/packages/host/.build/release/SoundBridgeHost")
        }
        #endif

        guard let hostPath = possiblePaths.first(where: { fileManager.fileExists(atPath: $0) }) else {
            print("ERROR: Could not find SoundBridgeHost executable")
            print("Searched in:")
            for path in possiblePaths {
                print("  - \(path)")
            }
            showAlert("SoundBridge Host Not Found", "Please build the host first:\ncd packages/host && swift build -c release")
            return
        }

        hostProcess = Process()
        hostProcess?.launchPath = hostPath
        hostProcess?.arguments = []

        // Capture output for debugging
        let outputPipe = Pipe()
        hostProcess?.standardOutput = outputPipe
        hostProcess?.standardError = outputPipe

        hostProcess?.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self else { return }
                print("SoundBridgeHost terminated (status: \(process.terminationStatus), reason: \(process.terminationReason.rawValue))")
                // During uninstall, Host is killed intentionally — don't auto-quit
                if !self.isUninstalling {
                    NSApp.terminate(nil)
                }
            }
        }

        do {
            try hostProcess?.run()
            print("Started SoundBridgeHost at: \(hostPath)")
        } catch {
            print("Failed to launch host: \(error)")
            showAlert("Failed to Launch Host", error.localizedDescription)
        }
    }

    func getArchitecture() -> String? {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let arch = String(cString: machine)
        
        // Map to SwiftPM architecture names
        if arch.contains("arm64") {
            return "arm64-apple-macosx"
        } else if arch.contains("x86_64") {
            return "x86_64-apple-macosx"
        }
        return nil
    }
    
    func loadLogoImage() -> NSImage? {
        let fileManager = FileManager.default
        var logoURL: URL?

        // PRIORITY 1: Try using Bundle's resource API (works across bundle structures)
        // First try to find the resource bundle
        if let resourceBundleURL = Bundle.main.url(forResource: "SoundBridgeApp_SoundBridgeApp", withExtension: "bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL),
           let logoPath = resourceBundle.url(forResource: "icons/soundbridge-menu", withExtension: "svg") {
            print("Found menu icon via resource bundle API: \(logoPath.path)")
            logoURL = logoPath
        }

        // PRIORITY 2: Try SwiftPM resource bundle (production builds)
        // SwiftPM creates a separate bundle named "<Target>_<Target>.bundle"
        if logoURL == nil, let executableURL = Bundle.main.executableURL {
            let bundleName = "SoundBridgeApp_SoundBridgeApp.bundle"
            let resourceBundleURL = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName)
                .appendingPathComponent("Resources/icons/soundbridge-menu.svg")

            if fileManager.fileExists(atPath: resourceBundleURL.path) {
                print("Found logo in SwiftPM bundle: \(resourceBundleURL.path)")
                logoURL = resourceBundleURL
            }
        }

        // PRIORITY 3: Try main bundle's built-in resource lookup
        if logoURL == nil, let mainBundleURL = Bundle.main.url(forResource: "icons/soundbridge-menu", withExtension: "svg") {
            print("Found menu icon via main bundle: \(mainBundleURL.path)")
            logoURL = mainBundleURL
        }

        // PRIORITY 4: Try main bundle resources (alternative bundle structure)
        if logoURL == nil, let resourcePath = Bundle.main.resourcePath {
            let possiblePaths = [
                "\(resourcePath)/Resources/icons/soundbridge-menu.svg",
                "\(resourcePath)/icons/soundbridge-menu.svg"
            ]

            for path in possiblePaths {
                if fileManager.fileExists(atPath: path) {
                    print("Found logo in main bundle: \(path)")
                    logoURL = URL(fileURLWithPath: path)
                    break
                }
            }
        }

        // PRIORITY 5: Development - relative to executable
        if logoURL == nil, let executablePath = Bundle.main.executablePath {
            let executableDir = (executablePath as NSString).deletingLastPathComponent
            let sourcePath = (executableDir as NSString).appendingPathComponent("../../../Sources/Resources/icons/soundbridge-menu.svg")
            let normalizedPath = (sourcePath as NSString).standardizingPath
            if fileManager.fileExists(atPath: normalizedPath) {
                print("Found logo in development Sources: \(normalizedPath)")
                logoURL = URL(fileURLWithPath: normalizedPath)
            }
        }

        // PRIORITY 6: Development - absolute path from repo root
        if logoURL == nil {
            let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? ""
            let absolutePath = "\(homeDir)/soundbridge/apps/mac/SoundBridgeApp/Sources/Resources/icons/soundbridge-menu.svg"
            if fileManager.fileExists(atPath: absolutePath) {
                print("Found menu icon at absolute path: \(absolutePath)")
                logoURL = URL(fileURLWithPath: absolutePath)
            }
        }

        guard let url = logoURL else {
            print("Failed to find soundbridge-menu.svg in any location")
            return nil
        }

        // Load SVG (NSImage supports SVG on macOS 10.15+)
        guard let image = NSImage(contentsOf: url) else {
            print("Failed to load image from: \(url.path)")
            return nil
        }

        // Resize to appropriate menu bar size (typically 18-22px)
        let size = NSSize(width: 16, height: 16)
        let resizedImage = NSImage(size: size)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1.0)
        resizedImage.unlockFocus()

        print("Successfully loaded and resized logo")
        return resizedImage
    }
    
    func registerCustomFont() {
        let fileManager = FileManager.default
        var fontURL: URL?

        // PRIORITY 1: Try using Bundle's resource API (works across bundle structures)
        if let resourceBundleURL = Bundle.main.url(forResource: "SoundBridgeApp_SoundBridgeApp", withExtension: "bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL),
           let fontPath = resourceBundle.url(forResource: "fonts/SignPainterHouseScript", withExtension: "ttf") {
            print("Found font via resource bundle API: \(fontPath.path)")
            fontURL = fontPath
        }

        // PRIORITY 2: Try SwiftPM resource bundle (production builds)
        if fontURL == nil, let executableURL = Bundle.main.executableURL {
            let bundleName = "SoundBridgeApp_SoundBridgeApp.bundle"
            let resourceBundleURL = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName)
                .appendingPathComponent("Resources/fonts/SignPainterHouseScript.ttf")

            if fileManager.fileExists(atPath: resourceBundleURL.path) {
                print("Found font in SwiftPM bundle: \(resourceBundleURL.path)")
                fontURL = resourceBundleURL
            }
        }

        // PRIORITY 3: Try main bundle's built-in resource lookup
        if fontURL == nil, let mainBundleURL = Bundle.main.url(forResource: "fonts/SignPainterHouseScript", withExtension: "ttf") {
            print("Found font via main bundle: \(mainBundleURL.path)")
            fontURL = mainBundleURL
        }

        // PRIORITY 4: Try main bundle resources (alternative bundle structure)
        if fontURL == nil, let resourcePath = Bundle.main.resourcePath {
            let possiblePaths = [
                "\(resourcePath)/Resources/fonts/SignPainterHouseScript.ttf",
                "\(resourcePath)/fonts/SignPainterHouseScript.ttf"
            ]

            for path in possiblePaths {
                if fileManager.fileExists(atPath: path) {
                    print("Found font in main bundle: \(path)")
                    fontURL = URL(fileURLWithPath: path)
                    break
                }
            }
        }

        // PRIORITY 5: Development - relative to executable
        if fontURL == nil, let executablePath = Bundle.main.executablePath {
            let executableDir = (executablePath as NSString).deletingLastPathComponent
            let sourcePath = (executableDir as NSString).appendingPathComponent("../../../Sources/Resources/fonts/SignPainterHouseScript.ttf")
            let normalizedPath = (sourcePath as NSString).standardizingPath
            if fileManager.fileExists(atPath: normalizedPath) {
                print("Found font in development Sources: \(normalizedPath)")
                fontURL = URL(fileURLWithPath: normalizedPath)
            }
        }

        // PRIORITY 6: Development - absolute path from repo root
        if fontURL == nil {
            let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? ""
            let absolutePath = "\(homeDir)/soundbridge/apps/mac/SoundBridgeApp/Sources/Resources/fonts/SignPainterHouseScript.ttf"
            if fileManager.fileExists(atPath: absolutePath) {
                print("Found font at absolute path: \(absolutePath)")
                fontURL = URL(fileURLWithPath: absolutePath)
            }
        }

        guard let url = fontURL else {
            print("Failed to find SignPainterHouseScript.ttf in any location")
            return
        }

        var error: Unmanaged<CFError>?
        let result = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)

        if result {
            print("Successfully registered custom font")
        } else if let error = error {
            print("Failed to register font: \(error.takeRetainedValue())")
        }
    }
    
    func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
                eventMonitor?.stop()
            } else {
                // Position the popover directly below the menu bar button
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

                // Make popover window key immediately for proper glass effect
                if let popoverWindow = popover.contentViewController?.view.window {
                    popoverWindow.makeKeyAndOrderFront(nil)
                }

                // On macOS 15+ (Tahoe/Sequoia), NSPopover positioning can be off on external
                // monitors. Manually reposition if needed.
                if #available(macOS 15.0, *) {
                    if let popoverWindow = popover.contentViewController?.view.window,
                       let buttonWindow = button.window {
                        let buttonScreenFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
                        let popoverFrame = popoverWindow.frame

                        // Calculate where the popover should be: directly below the button
                        let targetY = buttonScreenFrame.minY - popoverFrame.height

                        // Only adjust if there's a significant gap (more than 10 pixels)
                        if abs(popoverFrame.maxY - buttonScreenFrame.minY) > 10 {
                            popoverWindow.setFrameOrigin(NSPoint(x: popoverFrame.origin.x, y: targetY))
                        }
                    }
                }

                eventMonitor?.start()
            }
        }
    }
}

// EventMonitor to detect clicks outside the popover
class EventMonitor {
    private var monitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// Main entry point - check for command-line flags before launching app
extension AppDelegate {
    static func main() {
        // Check for --reset-onboarding flag
        if CommandLine.arguments.contains("--reset-onboarding") {
            OnboardingState.reset()
            print("Onboarding reset - will show on next launch")
        }

        // Launch the app
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
