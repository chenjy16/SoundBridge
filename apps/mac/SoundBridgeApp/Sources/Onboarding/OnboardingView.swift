import SwiftUI
import AppKit

// MARK: - Onboarding Step

/// The two steps in the simplified onboarding flow
enum OnboardingStep {
    case welcome
    case driverInstall
}

// MARK: - OnboardingView

/// Simplified two-step onboarding: Welcome → Driver Installation
struct OnboardingView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    @State private var currentStep: OnboardingStep = .welcome

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            switch currentStep {
            case .welcome:
                WelcomeStepView(onNext: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentStep = .driverInstall
                    }
                })
            case .driverInstall:
                DriverInstallStepView(
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep = .welcome
                        }
                    },
                    onComplete: {
                        coordinator.complete()
                    }
                )
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}

// MARK: - Step 1: Welcome

/// Welcome page introducing SoundBridge and its core functionality
private struct WelcomeStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App icon / brand
            AppIconView(size: 64)

            VStack(spacing: 12) {
                Text("Welcome to SoundBridge")
                    .font(.system(size: 28, weight: .bold))

                Text("SoundBridge lets you control HDMI monitor volume with your keyboard volume keys")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Spacer()

            Button(action: onNext) {
                Text("Next")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 120)
            }
            .keyboardShortcut(.return)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Step 2: Driver Installation

/// Driver installation page: a guide to the official installer package.
///
/// P4 Batch 1A: this page no longer installs anything. It used to run a second,
/// untransactional copy of the install — an administrator `osascript` that
/// copied the bundle out of `Contents/Resources` and ended with `killall
/// coreaudiod` — while the release's `.pkg` performed the same replace through
/// `tools/sb_install_transaction.sh`, with a staging copy, a backup and a
/// rollback. Onboarding now points at the package, and the page turns green only
/// when the version gate says the installed driver matches this build — never
/// because a button was clicked.
///
/// The gate is read first: a machine with no driver gets the install guide, a
/// machine whose driver cannot be used gets an explanation and no action (§2.3),
/// and a machine that already matches skips straight to completion.
private struct DriverInstallStepView: View {
    let onBack: () -> Void
    let onComplete: () -> Void

    private let installer = DriverInstaller()

    /// What the version gate said about the bundle on disk.
    ///
    /// `nil` until `onAppear` reads it. Assumed nothing: defaulting to
    /// `.notInstalled` would flash the install guide on a machine that already
    /// has a working driver, and defaulting to "incompatible" would flash an
    /// error at someone who simply has not installed yet.
    @State private var status: DriverVersionStatus?

    /// Set once the user has been sent to Installer. Coming back from Installer
    /// is what `didBecomeActive` reports, and re-reading is the only thing that
    /// can turn this page green.
    @State private var isWaitingForInstaller = false

    /// The driver on disk is the one this build needs. Everything the page
    /// shows after an install hangs off this answer, not off a return value.
    private var isInstalledAndUsable: Bool {
        status?.isCompatible == true
    }

    /// Only a genuinely absent driver gets the install guide.
    private var isFirstInstall: Bool {
        status == .notInstalled
    }

    /// Where the package is, or where to get it. Re-evaluated on every render so
    /// a package downloaded while the window was open is picked up.
    private var guideAction: DriverInstallGuide.Action {
        DriverInstallGuide.action(
            appVersion: VersionManager.appVersion(),
            releasePageURL: DriverCompatibilityNotice.configuredReleasePageURL
        )
    }

    /// The text shown instead of an install action when the installed bundle
    /// cannot be used. `nil` for statuses that need no explanation.
    private var notice: DriverCompatibilityNotice? {
        guard let status else { return nil }
        return DriverCompatibilityNotice.make(
            for: status,
            appVersion: VersionManager.appVersion() ?? "unknown",
            releasePageURL: DriverCompatibilityNotice.configuredReleasePageURL
        )
    }

    /// The line above the body.
    ///
    /// A notice brings its own title, and since Phase 3.2C that includes
    /// `"App and Driver Versions Do Not Match"` for `.newer`. The old hardcoded
    /// headline — `"Driver Cannot Be Used"` — is wrong for that state: the
    /// driver is fine, this build is the old half.
    private var headline: String {
        if let notice { return notice.title }
        guard status != nil else { return "Audio Driver" }
        return isFirstInstall ? "Install Audio Driver" : "Driver Cannot Be Used"
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            if isInstalledAndUsable {
                completionContent
            } else {
                installContent
            }

            Spacer(minLength: 0)

            // Bottom buttons
            HStack {
                if !isInstalledAndUsable {
                    Button("Back") {
                        onBack()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }

                Spacer()

                actionButtons
            }
            .padding(.bottom, 32)
        }
        .padding(.horizontal, 40)
        .onAppear(perform: readInstalledState)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from Installer is exactly this notification. The gate
            // is re-read; nothing here trusts the click that opened the package.
            guard isWaitingForInstaller else { return }
            readInstalledState()
        }
    }

    /// The one place this page decides what to offer.
    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 10) {
            if isInstalledAndUsable {
                Button(action: onComplete) {
                    Text("Open SoundBridge")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 160)
                }
                .keyboardShortcut(.return)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            } else if isFirstInstall {
                // Retry is a re-read, not a second install: the package owns the
                // install, so the only thing left to do here is check again.
                if case .openPackage = guideAction {
                    Button("Check Again", action: readInstalledState)
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                }

                switch guideAction {
                case .openPackage(let url):
                    Button { open(url) } label: {
                        Text("Open Installer Package")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 170)
                    }
                    .keyboardShortcut(.return)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                case .openReleasePage(let url):
                    Button { open(url) } label: {
                        Text("Open Release Page")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 170)
                    }
                    .keyboardShortcut(.return)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                case .namePackage:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - Install Content

    @ViewBuilder
    private var installContent: some View {
        VStack(spacing: 16) {
            Image(systemName: isFirstInstall ? "gearshape.2.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(isFirstInstall ? .accentColor : .orange)

            Text(headline)
                .font(.system(size: 22, weight: .semibold))

            if let notice {
                // The compatibility path: versions, protocol, and where to get
                // the full package. No button, because this page cannot install
                // an upgrade — that is the whole point of §2.3.
                VStack(spacing: 10) {
                    ForEach(notice.lines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }
                }
            } else if status == nil {
                Text("Checking the installed audio driver…")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            } else {
                installGuide
            }
        }
    }

    // MARK: - Install Guide

    /// What happens when the user opens the package, and how this page learns
    /// that it worked. The step about "Check Again" is not filler: the package
    /// runs in its own process and can be cancelled, so the filesystem is the
    /// only report this page accepts.
    @ViewBuilder
    private var installGuide: some View {
        VStack(spacing: 12) {
            Text("SoundBridge's audio driver is installed by the official installer package, not by this app. The package stages the new driver, verifies it, and restores the previous one if anything fails — so a cancelled or failed install cannot leave a half-replaced bundle behind.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            guidanceLine

            VStack(alignment: .leading, spacing: 7) {
                step(1, "Open the installer package.")
                step(2, "Approve the administrator prompt. The package writes \(DriverBundleLocation.driverPath) and keeps the previous bundle until the new one has been verified.")
                step(3, "Return here and choose Check Again. This page reports success only when the installed driver matches this build.")
            }
            .frame(maxWidth: 450, alignment: .leading)

            if isWaitingForInstaller {
                Text("Waiting for Installer. This page checks again when you come back.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Where the package is, or where to get it. Stated before the steps so the
    /// button below is never a surprise.
    @ViewBuilder
    private var guidanceLine: some View {
        switch guideAction {
        case .openPackage(let url):
            Text("Package found: \(url.lastPathComponent)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        case .openReleasePage:
            Text("The installer package is not next to the app. Download \(DriverInstallGuide.packageFileName(appVersion: VersionManager.appVersion() ?? "<version>")) from the release page, open it, then come back here.")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        case .namePackage(let name):
            Text("The installer package is not next to the app. Open \(name) from wherever the release was downloaded.")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Completion Content

    @ViewBuilder
    private var completionContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Installation Complete")
                .font(.system(size: 22, weight: .semibold))

            Text("Select the SoundBridge device in System Settings → Sound to get started")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            // Visual hint for Control Center → Sound
            HStack(spacing: 6) {
                Image(systemName: "switch.2")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text("Control Center")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text("Sound")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

    /// Ask LaunchServices to open the package (or the release page). Installing
    /// is Installer's job from here; this page only records that it is waiting,
    /// so the next `didBecomeActive` re-reads the gate instead of trusting a
    /// click. No privilege is requested here and nothing is copied.
    private func open(_ url: URL) {
        isWaitingForInstaller = true
        if !NSWorkspace.shared.open(url) {
            print("[Onboarding] could not open \(url.path)")
        }
    }

    /// Read the gate and let it — not the user's last action — decide the page.
    ///
    /// This is the rule that keeps a failed, cancelled or partial install from
    /// being reported as success: the only input is the installed bundle's own
    /// `Info.plist` compared against what this build ships.
    private func readInstalledState() {
        let current = installer.currentInstallStatus()
        status = current
        if current.isCompatible {
            isWaitingForInstaller = false
        }
        print("[Onboarding] driver state: \(current.summary)")
    }
}
