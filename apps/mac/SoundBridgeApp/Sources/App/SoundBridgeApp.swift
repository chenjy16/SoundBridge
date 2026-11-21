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
    /// The App's single EQ writer.
    ///
    /// Created with this delegate — before `SharedMemoryMappingManager.start()`
    /// and before any View exists. That ordering is the Gate 3 fix:
    /// `mappingPublished` does not replay, so a writer that only appeared when
    /// the popover opened left the Host's new mapping at `eq_sequence = 0` while
    /// `UserDefaults` held the real values.
    private let eqService = EQService.shared
    /// The App's single owner of the Host process.
    ///
    /// Replaces `hostProcess` and the termination handler that called
    /// `NSApp.terminate(nil)`: a Host that dies is a state to report and recover
    /// from, not a reason for the App to exit.
    private let hostSupervisor = HostSupervisor()
    /// Set for the whole of `applicationWillTerminate`. A restart accepted after
    /// this point would be cancelled by the shutdown a few lines later, and the
    /// user would see a Host disappear instead of being replaced.
    private(set) var isTerminating = false
    /// The policy in front of `restartHost()`. See `HostRestartEntry`.
    private lazy var hostRestartEntry = HostRestartEntry(
        supervisor: hostSupervisor,
        isUninstalling: { [weak self] in self?.isUninstalling ?? true },
        isTerminating: { [weak self] in self?.isTerminating ?? true }
    )
    var eventMonitor: EventMonitor?
    var onboardingCoordinator: OnboardingCoordinator?
    var updaterController: SPUStandardUpdaterController?
    /// Set to true during uninstall. `prepareForUninstall(completion:)` has
    /// already stopped the Host and latched the supervisor shut; this flag keeps
    /// `applicationWillTerminate` from re-running cleanup for an install that is
    /// being removed.
    var isUninstalling = false
    /// One "Host not found" alert per launch. Retrying cannot make a missing
    /// binary appear, so the supervisor reports `degraded` and this shows once.
    private var didPresentHostMissingAlert = false
    /// One compatibility alert per launch. The check runs once anyway; this keeps
    /// a future second caller from stacking windows on top of each other.
    private var didPresentCompatibilityNotice = false
    /// Slow fallback re-resolve of the Host state; see
    /// `startHostStatusFallbackTimer()`.
    private var hostStatusTimer: DispatchSourceTimer?
    /// How long to wait for a Host to finish its own shutdown before the App
    /// escalates. The Host's ordered teardown (stop listeners → detach from the
    /// driver → unlink shared memory → publish `stopped` → drop the instance
    /// lock) needs roughly 1.2s on a loaded machine, so 0.15s could only ever
    /// end in SIGKILL. SIGKILL skips state saving and lock release, which is
    /// exactly what made a killed Host look healthy to the next launch.
    private let hostTerminationTimeout: TimeInterval = 2.5

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register custom font
        registerCustomFont()

        // Supervisor state is logged here and folded into the menu bar state.
        // Nothing on this path may quit the App: that was the Gate 3 defect.
        hostSupervisor.onStateChange = { [weak self] state in
            self?.hostSupervisorDidChange(to: state)
        }

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
            // The Host reports a new state after it publishes a mapping. Treat
            // that as a hint and re-read the identity from the file rather than
            // trusting it: a notification is not a state.
            SharedMemoryMappingManager.shared.revalidate()
        }
        IPCController.shared.onDeviceStateUnavailable = { [weak self] in
            self?.applyHostLifecycle(nil)
            SharedMemoryMappingManager.shared.revalidate()
        }
        IPCController.shared.startMonitoring()

        // The EQ writer's mapping is owned here, not by `MenuBarView`.
        //
        // P2 Batch 3: the attach used to happen only in the menu bar's
        // `onReceive`, so a closed popover meant the App kept writing into
        // whichever inode it had mapped first. An App-level owner plus a
        // structural fallback means the mapping follows the Host even when no
        // View was ever created.
        SharedMemoryMappingManager.shared.deviceUIDProvider = { VolumeController.shared.activeDeviceUID }
        SharedMemoryMappingManager.shared.start()

        // The lock decides "is a Host alive"; the report decides what it is doing.
        // Reading only the file is how a killed Host kept looking healthy.
        applyHostLifecycle(IPCController.shared.latestLifecycle)

        // Let the menu bar ask for a fresh answer when it opens, and keep a slow
        // fallback running for the case where a notification is lost.
        HostStatusModel.shared.refreshHandler = { [weak self] in
            self?.resyncHostStatus()
        }
        startHostStatusFallbackTimer()

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
    /// P4 Batch 1A removed the unwired `showDriverUpdatePrompt` /
    /// `performDriverUpdate` pair that used to sit below this comment. They were
    /// the second install transaction: the package is the only thing that writes
    /// to the HAL directory now, and a window offering an in-app update would
    /// have promised something the app can no longer do.
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

    /// Low-frequency re-resolve of the Host state.
    ///
    /// The Darwin notification is the primary mechanism; this exists because a
    /// notification that never arrives used to leave the popover saying "Audio
    /// host is not running" about a Host that had been healthy for minutes. Five
    /// seconds of staleness is the floor this build accepts, not a substitute for
    /// the event channel.
    private func startHostStatusFallbackTimer() {
        hostStatusTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.resyncHostStatus()
        }
        timer.resume()
        hostStatusTimer = timer
    }

    /// Re-read the Host's report from disk and re-resolve the UI state.
    ///
    /// Reading first is what makes this a fallback rather than a repeat of the
    /// last value: `latestLifecycle` is only as fresh as the last notification
    /// that arrived, so a lost one would otherwise be re-applied every tick and
    /// look exactly like a state that never changed.
    ///
    /// Low frequency on purpose. The notification channel is the mechanism;
    /// this only bounds how long a missed notification costs.
    private func resyncHostStatus() {
        IPCController.shared.refreshAndNotify()
        applyHostLifecycle(IPCController.shared.latestLifecycle)
    }

    /// Fold the Host's lifecycle report into the state the UI shows.
    ///
    /// Two inputs on purpose: the instance lock answers "is a Host alive" and the
    /// report answers "what is it doing". Trusting either one alone is the bug
    /// this replaces — a stale `ready` file from a killed Host, or a live Host
    /// that never found its proxy device and said nothing.
    private func applyHostLifecycle(_ report: HostLifecycleReport?) {
        let lock = HostInstanceProbe.state()
        let validatedReport: HostLifecycleReport?
        let state: HostRunState
        switch lock {
        case .held(let session):
            let latest = IPCController.shared.latestState
            let sameSession = session.map { latest?.sessionID.flatMap(UUID.init(uuidString:)) == $0 }
                ?? (latest?.sessionID == nil && latest?.protocolVersion == nil)
            validatedReport = sameSession && latest?.lifecycle == report ? report : nil
            state = HostRunState.resolve(report: validatedReport, hostRunning: true)
        case .notRunning:
            validatedReport = nil
            // The lock is free, but a supervisor that gave up is not the same
            // thing as a Host nobody asked to start. Reporting `notRunning` here
            // would hide the difference and invite a restart loop.
            state = hostSupervisor.isDegraded ? .degraded : .notRunning
        case .unavailable:
            validatedReport = nil
            state = .unknown
        }
        HostStatusModel.shared.update(state, report: validatedReport)

        if state.isProblem {
            print("[HostState] \(state.shortMessage) — \(validatedReport?.detail ?? "no detail reported")")
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
        // The view observes the App's writer; it never creates one. A closed
        // popover is then only a closed window, not a missing EQ writer.
        popover?.contentViewController = NSHostingController(rootView: MenuBarView(eqController: eqService.controller))
        
        // Set up event monitor to dismiss popover when clicking outside
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let popover = self?.popover, popover.isShown {
                self?.popover?.performClose(event)
            }
        }
        print("Menu bar setup complete - icon should be visible")
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true

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

        // Release the shared-memory mapping last, after every writer has been
        // told to stop, so the last `munmap` cannot land under an in-flight EQ
        // write.
        SharedMemoryMappingManager.shared.stop()

        // Stop IPC monitoring
        IPCController.shared.stopMonitoring()

        // 共享资源和默认输出只能由持锁的 Host 清理。The supervisor owns the
        // process, so it also owns the ordered stop: SIGTERM, bounded grace,
        // SIGKILL. Waiting here is the App's one synchronous wait, and it exists
        // so the Host cannot outlive the delegate that launched it.
        hostSupervisor.shutdown(intent: .appTermination, waitTimeout: hostTerminationTimeout + 0.5) {
            log("Host supervisor released the Host it owned")
        }

        logHandle?.closeFile()
        print("=== applicationWillTerminate COMPLETE ===")
    }

    // The Host stop path lives in `HostSupervisor` since Gate 3. What was here —
    // `terminateHostAndProxies` plus a `Process` poll on the main thread — could
    // only ever stop the process that this App happened to hold in a variable,
    // and it had no answer for "who restarts it". The supervisor keeps the same
    // SIGTERM → bounded grace → SIGKILL escalation, but does the waiting on its
    // own queue; `applicationWillTerminate` is the one caller that waits.
    //
    // Untracked Host processes and shared IPC resources are still left alone: they
    // belong to whichever process holds the instance lock.

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

    // P2 Batch 2 removed `performCleanup()` and `findDeviceByUID(_:)` from this
    // class. Both were dead (zero call sites), and what they described was the
    // last automatic default-output write in the product: on quit, if the system
    // output happened to be a SoundBridge proxy, `performCleanup` moved it to the
    // physical device — and also wrote `kAudioHardwarePropertyDefaultSystemOutputDevice`.
    // Quitting is not a request to change where the machine's audio goes, so
    // there is nothing here to keep. `DefaultOutputSwitch` is now the only code in
    // the app that writes the default output, and it is reached from one place:
    // a click in the device list.

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
    // restarts `coreaudiod`: after P4 Batch 1A the app has no `killall` at all.
    // The package installs, `tools/uninstall_driver.sh` and the app's uninstall
    // item remove through one shared policy, and neither restarts the daemon.

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

    /// Start the Host through the supervisor.
    ///
    /// The supervisor owns the `Process` from here on: it decides when a launch
    /// counts as successful (the instance lock is taken within `launchTimeout`),
    /// when an exit is a crash to recover from, and when repeated failures become
    /// `degraded`. `AppDelegate` no longer holds the process, and nothing on this
    /// path reacts to a Host exit by quitting.
    func startHost() {
        hostSupervisor.start()
    }

    /// Host-only restart: terminate the Host this App owns, wait for it to exit,
    /// and start a replacement. The App keeps its PID, its mapping manager and
    /// its EQ writer; the new Host gets a new session and a new mapping, and
    /// `EQController` re-applies the persisted EQ when that publication arrives.
    ///
    /// Reached from the popover's "Restart Host" item through
    /// `requestHostRestart()`; `HostSupervisorTests` drives the same call path.
    func restartHost() {
        hostSupervisor.restart()
    }

    /// The user-facing entry: "Restart Host" in the menu bar popover.
    ///
    /// Refused while uninstalling or terminating, where a replacement Host would
    /// be undone immediately. Every other case is the supervisor's to judge, and
    /// it coalesces a click that arrives while a stop is already in flight.
    @discardableResult
    func requestHostRestart() -> HostRestartOutcome {
        let outcome = hostRestartEntry.request { [weak self] in self?.restartHost() }
        print("[HostSupervisor] Restart Host item: \(outcome.description)")
        return outcome
    }

    /// Uninstall path: stop the Host through the supervisor, then let the caller
    /// remove the driver.
    ///
    /// The completion is the ordering, not a convenience: `shutdown(intent:
    /// .uninstall)` sets the supervisor's shutdown latch as it stops the process,
    /// so a Host exit observed during the removal is not read as a crash and
    /// relaunched. Starting the removal before that latch is set would race a
    /// relaunch against a driver that is being deleted, which is exactly what
    /// the old `killall SoundBridgeHost` inside the privileged script invited.
    ///
    /// P4 Batch 1A: nothing here kills the Host by name any more. A `killall`
    /// skipped the Host's ordered teardown and could match a Host this App does
    /// not own.
    func prepareForUninstall(completion: @escaping () -> Void) {
        isUninstalling = true
        hostSupervisor.shutdown(intent: .uninstall, completion: completion)
    }

    /// Fold a supervisor transition into the log and the menu bar.
    ///
    /// Deliberately no `NSApp.terminate`: the App outliving the Host is the whole
    /// point of the supervisor. `degraded` is reported as a state, so the popover
    /// can say so instead of the App disappearing.
    private func hostSupervisorDidChange(to state: HostSupervisorState) {
        switch state {
        case .degraded(let failure, let attempts):
            print("[HostSupervisor] degraded after \(attempts) attempt(s): \(failure.description)")
            HostStatusModel.shared.update(.degraded)
            if case .executableMissing = failure {
                presentHostMissingAlertOnce()
            }
        default:
            print("[HostSupervisor] \(state.description)")
        }
    }

    /// The old launch path alerted on a missing binary. Keep that one message,
    /// once per launch, now that locating the executable is the locator's job.
    private func presentHostMissingAlertOnce() {
        guard !didPresentHostMissingAlert else { return }
        didPresentHostMissingAlert = true
        showAlert("SoundBridge Host Not Found", "Please build the host first:\ncd packages/host && swift build -c release")
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
