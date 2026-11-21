import SwiftUI
import AppKit

// Cache font lookup once at launch
private let soundbridgeFont: Font = {
    let size: CGFloat = 22
    let possibleNames = [
        "SignPainterHouseScript",
        "SignPainter-HouseScript",
        "SignPainter House Script",
        "SignPainter"
    ]
    for name in possibleNames {
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
    }
    return .system(size: size, weight: .bold)
}()

struct MenuBarView: View {
    /// The App-owned EQ writer, passed in by `AppDelegate`.
    ///
    /// This used to be `@StateObject private var eqController = EQController(…)`,
    /// which meant the writer was created the first time the popover rendered.
    /// A user who never opened the menu bar had no writer at all, and the Host's
    /// new mapping stayed at `eq_sequence = 0` (Gate 3). Observing an instance
    /// that already exists is the whole fix: the view is now only a reader.
    @ObservedObject private var eqController: EQController
    @StateObject private var volumeController = VolumeController.shared
    @StateObject private var hostStatus = HostStatusModel.shared
    @State private var showDeviceList = false
    /// Set when an explicit switch failed. The list stays open and the user is
    /// told why: a silent failure is what would invite a "just try again in a
    /// loop" fix, which P2 Batch 2 forbids.
    @State private var switchFailure: String?

    init(eqController: EQController) {
        self.eqController = eqController
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. Device name header + dropdown arrow
            DeviceHeader(
                deviceName: volumeController.activeDeviceName,
                isExpanded: $showDeviceList
            )

            Divider()
                .padding(.horizontal, 12)

            // 1.5 Host status. Only rendered when there is something to say:
            // a healthy popover is unchanged, which is what "do not rework the
            // UI" means in practice. The sentence comes from `HostRunState`,
            // so this row can never disagree with the log line or the notice.
            if hostStatus.showsStatusLine {
                HostStatusRow(state: hostStatus.state)

                Divider()
                    .padding(.horizontal, 12)
            }

            // 2. Volume slider (only for fixed-volume devices)
            if volumeController.isFixedVolumeDevice {
                VolumeSliderRow(
                    volume: Binding(
                        get: { volumeController.currentVolume },
                        set: { volumeController.setVolume($0) }
                    ),
                    isMuted: volumeController.isMuted,
                    onToggleMute: {
                        volumeController.setMute(!volumeController.isMuted)
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                Text("This device supports native volume control")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }

            Divider()
                .padding(.horizontal, 12)

            // 2.5 EQ controls
            BasicEQView(eqController: eqController)

            Divider()
                .padding(.horizontal, 12)

            // 3. Device list (expandable)
            if showDeviceList {
                DeviceListSection(
                    devices: volumeController.allDevices,
                    activeUID: volumeController.activeDeviceUID,
                    onSelect: { device in
                        // The one explicit default-output switch in the product.
                        let result = volumeController.switchDevice(to: device)
                        if let failure = result.failureMessage {
                            switchFailure = failure
                        } else {
                            showDeviceList = false
                        }
                    }
                )
            }

            // 4. Reconnect audio + Footer
            ReconnectAudioButton()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            // 5. Host-only restart. Below "Reconnect Audio" and deliberately
            // its own row: that one rebuilds the audio path inside the running
            // Host (same process, same session, same mapping); this one replaces
            // the Host process, which is what publishes a new mapping.
            RestartHostButton()
                .padding(.horizontal, 8)
                .padding(.vertical, 0)

            FooterBar()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .transaction { $0.animation = nil }
        .onReceive(volumeController.$activeDeviceUID) { uid in
            guard !uid.isEmpty else { return }
            eqController.attachSharedMemory(for: uid)
        }
        // A notification cannot be replayed: whatever the Host published while
        // the panel was closed was only seen by `IPCController`. Re-resolve on
        // open so the first frame already reflects the current Host, instead
        // of showing the value captured at launch.
        .onAppear { hostStatus.refresh() }
        .alert(
            "Could not switch output",
            isPresented: Binding(
                get: { switchFailure != nil },
                set: { if !$0 { switchFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { switchFailure = nil }
        } message: {
            Text(switchFailure ?? "")
        }
    }
}

// MARK: - Host Status Row

/// One line describing what the audio host is doing, shown only when that is
/// not the obvious "nothing to report".
///
/// Deliberately not a button and not a link. Every problem that has a remedy
/// the app can perform is already handled by reconnecting to the host; the ones
/// that need a download are explained by `DriverCompatibilityNotice`, which is
/// where the versions and the release page belong. Adding an action here would
/// be the upgrade entry point Phase 2.1.4 removed.
struct HostStatusRow: View {
    let state: HostRunState

    private var tint: Color {
        state.isProblem ? .orange : .secondary
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.isProblem ? "exclamationmark.triangle.fill" : "clock")
                .font(.system(size: 11))
                .foregroundColor(tint)

            Text(state.shortMessage)
                .font(.system(size: 11))
                .foregroundColor(tint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Device Header

struct DeviceHeader: View {
    let deviceName: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                Text(deviceName.isEmpty ? "No Device" : deviceName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Volume Slider

struct VolumeSliderRow: View {
    @Binding var volume: Float
    let isMuted: Bool
    let onToggleMute: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleMute) {
                Image(systemName: muteIcon)
                    .font(.system(size: 12))
                    .foregroundColor(isMuted ? .red : .secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            Slider(value: Binding(
                get: { Double(volume) },
                set: { volume = Float($0) }
            ), in: 0...1)

            Text("\(Int(volume * 100))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var muteIcon: String {
        if isMuted || volume <= 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}

// MARK: - Device List

struct DeviceListSection: View {
    let devices: [OutputDevice]
    let activeUID: String
    let onSelect: (OutputDevice) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(devices) { device in
                DeviceRow(
                    device: device,
                    isActive: device.uid == activeUID,
                    onSelect: { onSelect(device) }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

struct DeviceRow: View {
    let device: OutputDevice
    let isActive: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isActive ? .accentColor : .secondary)

                Text(device.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if device.isFixedVolume {
                    Text("Fixed")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Reconnect Audio

struct ReconnectAudioButton: View {
    @State private var isBouncing = false
    @State private var showDone = false

    var body: some View {
        Button(action: reconnect) {
            HStack(spacing: 6) {
                if isBouncing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: showDone ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundColor(showDone ? .green : .secondary)
                }
                Text(showDone ? "Reconnected" : "Reconnect Audio")
                    .font(.system(size: 11))
                    .foregroundColor(showDone ? .green : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .disabled(isBouncing)
    }

    private func reconnect() {
        isBouncing = true
        VolumeController.shared.requestAudioReconnect()
        // Show feedback after the Host has had time to re-establish the path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isBouncing = false
            showDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showDone = false
            }
        }
    }
}

// MARK: - Restart Host

/// User-facing Host-only restart.
///
/// The click reaches `AppDelegate.requestHostRestart()`, which applies the gate
/// (`HostRestartEntry`: no restart while uninstalling or terminating) and then
/// calls the same `restartHost()` the supervisor tests drive — never a second
/// process-launching path, never `killall`, never a `Process()` of its own.
///
/// The disabled window below is feedback, not the concurrency control: a second
/// click that does get through is coalesced by `HostSupervisor`, and the instance
/// lock prevents a second Host regardless. It is only long enough for the stop,
/// the graceful exit and the relaunch to be under way.
struct RestartHostButton: View {
    @State private var isRequesting = false
    @State private var refusal: String?

    var body: some View {
        Button(action: restart) {
            HStack(spacing: 6) {
                if isRequesting {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Text(isRequesting ? "Restarting Host…" : "Restart Host")
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                if let refusal {
                    Text(refusal)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .disabled(isRequesting)
    }

    private func restart() {
        refusal = nil
        guard let appDelegate = NSApp.delegate as? AppDelegate else {
            // Not reachable in the app (`@main` is the delegate). Saying so beats
            // a click that visibly does nothing.
            refusal = "Unavailable"
            return
        }

        let outcome = appDelegate.requestHostRestart()
        guard outcome == .requested else {
            switch outcome {
            case .refusedUninstalling: refusal = "Uninstalling"
            case .refusedShuttingDown: refusal = "Shutting down"
            case .requested: break
            }
            return
        }

        isRequesting = true
        // SIGTERM → the Host's ordered teardown → relaunch → lock. The label is
        // back to "Restart Host" once that has had time to finish; the state it
        // actually ended in is reported by the Host status row above, not here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            isRequesting = false
        }
    }
}

// MARK: - Footer

struct FooterBar: View {
    var body: some View {
        HStack(spacing: 8) {
            UninstallButton()
            Spacer()
            QuitButton()
        }
    }
}

struct UninstallButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: performUninstall) {
            Text("Uninstall Driver")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(isHovered ? .white : .red.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.red : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }

    /// Remove the driver the same way `tools/uninstall_driver.sh` does.
    ///
    /// P4 Batch 1A rewrote this. It used to kill the Host by name, delete
    /// `/tmp/soundbridge-*` with a wildcard, `rm -rf` whatever sat at the HAL
    /// path without checking whose it was, and finish with `killall coreaudiod`
    /// inside the same privileged command. Every one of those is now the
    /// policy's decision, made before the prompt:
    ///
    ///   1. identify the bundle (unprivileged, and refuse anything else)
    ///   2. ask the supervisor to stop the Host, and wait for it
    ///   3. remove one constant path, once
    ///   4. verify it is gone, and only then clear onboarding state
    private func performUninstall() {
        switch DriverUninstallPolicy.decide(DriverUninstaller.readIdentity()) {
        case .nothingToRemove:
            presentUninstallMessage(
                title: "Driver Not Installed",
                message: "There is no SoundBridge driver at \(DriverUninstallPolicy.driverPath). Nothing was removed."
            )
            return
        case .refuse(let reason):
            presentUninstallMessage(
                title: "Driver Left Alone",
                message: "\(DriverUninstallPolicy.driverPath) was not removed: \(reason). Nothing was changed."
            )
            return
        case .remove:
            break
        }

        let alert = NSAlert()
        alert.messageText = "Uninstall SoundBridge Driver"
        alert.informativeText = """
        This removes:
        \(DriverUninstallPolicy.removed.map { "• \($0)" }.joined(separator: "\n"))

        This keeps:
        \(DriverUninstallPolicy.kept.map { "• \($0)" }.joined(separator: "\n"))
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall Driver")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        // Order, and why: the Host goes first, through the supervisor, and the
        // bundle is removed only in the completion. `shutdown(intent: .uninstall)`
        // sets the supervisor's shutdown latch, so a Host exit observed during
        // the removal is not read as a crash and relaunched against a driver
        // that is being deleted.
        // A value type cannot be captured weakly, and it does not need to be:
        // the completion runs on the main queue and touches no view state.
        appDelegate.prepareForUninstall {
            DispatchQueue.main.async { self.removeDriverAndFinish() }
        }
    }

    /// Step 3 and 4, on the main thread, after the Host is gone.
    private func removeDriverAndFinish() {
        do {
            try DriverUninstaller.remove()
        } catch {
            // Nothing else has been touched: onboarding state is cleared only
            // after the path is confirmed gone.
            presentUninstallMessage(
                title: "Driver Not Removed",
                message: "\(error.localizedDescription)\n\nThe app is still running and your EQ settings are untouched."
            )
            return
        }

        // The driver is gone, so the next launch should explain the install
        // again. EQ values (`eq_default_*`), logs and Application Support are
        // deliberately kept: they are what a reinstall resumes from.
        let defaults = UserDefaults.standard
        for key in ["hasCompletedOnboarding", "onboardingVersion",
                    "driverInstallDate", "lastDriverVersionCheck"] {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()

        let done = NSAlert()
        done.messageText = "Driver Removed"
        done.informativeText = """
        \(DriverUninstallPolicy.driverPath) is gone. \(DriverUninstallPolicy.restartAdvice)

        Kept: \(DriverUninstallPolicy.kept.joined(separator: ", ")).
        """
        done.alertStyle = .informational
        done.addButton(withTitle: "Quit SoundBridge")
        done.runModal()

        NSApp.terminate(nil)
    }

    private func presentUninstallMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

struct QuitButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            NSApp.terminate(nil)
        }) {
            Text("Quit SoundBridge")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(isHovered ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}
