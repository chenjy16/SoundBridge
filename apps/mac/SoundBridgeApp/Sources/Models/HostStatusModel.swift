import Combine
import Foundation

/// The single place the menu bar reads the Host's state from.
///
/// `AppDelegate.applyHostLifecycle(_:)` is the only writer. Views observe it
/// instead of asking "did the Host start" themselves, because the two inputs
/// that answer it — the instance lock and the Host's own report — already live
/// behind that one method.
///
/// Deliberately thin. Everything readable about a state (its sentence, whether
/// it is a problem) belongs to `HostRunState`; this class only carries the value
/// across the main-thread/UI boundary.
final class HostStatusModel: ObservableObject {
    static let shared = HostStatusModel()

    @Published private(set) var state: HostRunState = .notRunning

    /// Last report seen, kept so a refresh can re-resolve without waiting for
    /// the next IPC tick. Not published: no view renders it directly.
    private(set) var lastReport: HostLifecycleReport?

    /// Re-resolve from the current file and lock, without waiting for a
    /// notification.
    ///
    /// Set by `AppDelegate`, which is the only place that knows how to ask both
    /// questions. Called from the menu bar's `onAppear` and from a low-frequency
    /// fallback timer: a notification that never arrives must cost a few
    /// seconds, not require the user to close and reopen the panel.
    var refreshHandler: (() -> Void)?

    private init() {}

    /// Ask the owner to re-resolve. Safe to call from any thread.
    func refresh() {
        refreshHandler?()
    }

    /// Take a resolution made by the caller.
    ///
    /// `AppDelegate` does the resolving because it alone knows whether the lock
    /// is held at this instant; passing the answer in keeps this type free of
    /// file and process inspection.
    ///
    /// Hop to the main queue rather than requiring it. Callers arrive from the
    /// IPC notification callback, the initial synchronous read, and the launch
    /// path — only some of those are already on the main thread, and a dropped
    /// update here means the popover shows the previous state forever.
    func update(_ state: HostRunState, report: HostLifecycleReport? = nil) {
        let apply = { [weak self] in
            guard let self else { return }
            if let report {
                self.lastReport = report
            }
            guard state != self.state else { return }
            self.state = state
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Whether the menu bar should show a status line at all.
    ///
    /// Hiding the healthy case keeps the popover unchanged for users whose audio
    /// works — the "no large UI rework" constraint. `starting` is included
    /// because a silent popover during launch looks like a hang, and Phase 6A
    /// added `recovering` / `stopping` for the same reason: those are the moments
    /// a user is most likely to open the panel and wonder what is happening.
    var showsStatusLine: Bool {
        state.isProblem || state.isTransitional
    }
}
