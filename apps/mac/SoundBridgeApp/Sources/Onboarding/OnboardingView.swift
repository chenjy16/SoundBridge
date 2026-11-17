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

/// Driver installation page with progress and completion state
///
/// Phase 2.1.4 split two things that used to share one switch. A machine with no
/// driver needs an **install** action, and onboarding is the one place the app is
/// allowed to ask for it. A machine whose driver is present but unusable needs an
/// **explanation**, not a button: no entry point may copy files or restart
/// `coreaudiod` (§2.3). So the gate is read first, and its answer decides which of
/// the two this page shows.
private struct DriverInstallStepView: View {
    let onBack: () -> Void
    let onComplete: () -> Void

    @StateObject private var installer = DriverInstaller()
    /// What the version gate said about the bundle on disk.
    ///
    /// `nil` until `onAppear` reads it. Assumed nothing: defaulting to
    /// `.notInstalled` would flash an Install button on a machine that already
    /// has a working driver, and defaulting to "incompatible" would flash an
    /// error at someone who simply has not installed yet.
    @State private var status: DriverVersionStatus?

    /// Only a genuinely absent driver gets an install action.
    private var isFirstInstall: Bool {
        status == .notInstalled
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
        VStack(spacing: 24) {
            Spacer()

            if installer.state.isComplete {
                completionContent
            } else {
                installContent
            }

            Spacer()

            // Bottom buttons
            HStack {
                if !installer.state.isComplete {
                    Button("Back") {
                        onBack()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }

                Spacer()

                if installer.state.isComplete {
                    Button(action: onComplete) {
                        Text("Open SoundBridge")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 160)
                    }
                    .keyboardShortcut(.return)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                } else if isFirstInstall {
                    // One button for both the first attempt and a retry, because
                    // both are the same intent: nothing is installed.
                    Button(action: installDriver) {
                        Text(installer.state.isFailed ? "Retry" : "Install Driver")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 120)
                    }
                    .keyboardShortcut(.return)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 40)
        .onAppear {
            // Only skip ahead when the installed driver actually matches this
            // build. Existence alone used to jump straight to the completion
            // screen, hiding an outdated driver behind a green checkmark.
            let current = installer.currentInstallStatus()
            status = current
            if current.isCompatible {
                installer.state = .complete
                installer.progress = 1.0
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
                Text("An audio driver is required to enable volume control. This requires an administrator password.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if installer.state != .notStarted {
                VStack(spacing: 8) {
                    ProgressView(value: installer.progress)
                        .frame(width: 300)

                    Text(installer.state.description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
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

    private func installDriver() {
        // The intent is not inferred here. This page only ever performs a first
        // install, and `DriverInstaller` refuses it if the bundle is no longer
        // absent — for example when another process installed one while this
        // window was open.
        //
        // The guard is the second of two: the install button only exists for
        // `isFirstInstall`, but a page can be resized, re-run or, in a future
        // change, reused for another state. Running the installer against
        // `.newer` would replace a driver that is ahead of this build.
        guard isFirstInstall else {
            print("[Onboarding] install ignored for state \(status?.summary ?? "unknown")")
            return
        }
        Task {
            do {
                try await installer.installDriver(intent: .firstInstall)
            } catch {
                await MainActor.run {
                    installer.state = .failed(error.localizedDescription)
                    // Re-read the gate: the failure may be `intentDoesNotMatchStatus`
                    // because the driver appeared meanwhile, in which case the page
                    // should switch to the explanation instead of offering Retry.
                    status = installer.currentInstallStatus()
                }
            }
        }
    }
}
