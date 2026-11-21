import Foundation
import os.log

private let restartLog = Logger(subsystem: "com.soundbridge.app", category: "HostRestart")

/// What happened to a user-initiated "Restart Host".
///
/// Deliberately not a statement about the Host: `requested` only means the
/// request was forwarded to `HostSupervisor.restart()`, which decides per state
/// (`running`/`launching` → stop then relaunch, `stopping` → coalesced into the
/// stop already in flight, `idle`/`degraded` → launch, `notOwned` → ignored).
/// Reading the outcome of the restart itself would mean blocking on a background
/// process; the supervisor's own state transitions are the answer to that.
enum HostRestartOutcome: Equatable, CustomStringConvertible {
    case requested
    /// The App is uninstalling: there is about to be no driver and no Host, so a
    /// replacement Host is the opposite of what the user asked for.
    case refusedUninstalling
    /// The App is terminating, or the supervisor has already been shut down.
    case refusedShuttingDown

    var description: String {
        switch self {
        case .requested: return "requested"
        case .refusedUninstalling: return "refused (uninstall in progress)"
        case .refusedShuttingDown: return "refused (app is shutting down)"
        }
    }
}

/// The App-side gate in front of `HostSupervisor.restart()`.
///
/// This exists as a type rather than as three `guard`s inside `AppDelegate` so the
/// policy can be exercised without an `NSApplication`: the supervisor, the
/// uninstall flag and the terminating flag are all handed in. The action itself
/// arrives as a closure, because the menu item must reach the same
/// `AppDelegate.restartHost()` the supervisor tests drive — not a second path
/// that happens to call `restart()` too.
///
/// Nothing here decides *whether a Host exists*: that is the supervisor's lock,
/// its state machine and its single-flight rule. This only decides whether the
/// user's click is allowed to reach it at all.
struct HostRestartEntry {

    private let supervisor: HostSupervisor
    private let isUninstalling: () -> Bool
    private let isTerminating: () -> Bool

    init(
        supervisor: HostSupervisor,
        isUninstalling: @escaping () -> Bool,
        isTerminating: @escaping () -> Bool
    ) {
        self.supervisor = supervisor
        self.isUninstalling = isUninstalling
        self.isTerminating = isTerminating
    }

    /// Forward a Host-only restart, or explain why it was refused.
    ///
    /// - Parameter forward: the App's restart action (`AppDelegate.restartHost`).
    ///   Called at most once, and never for a refused request.
    @discardableResult
    func request(forward: () -> Void) -> HostRestartOutcome {
        // Uninstall first: it also shuts the supervisor down, and "uninstall"
        // is the more accurate of the two reasons to report.
        if isUninstalling() {
            restartLog.notice("Host restart refused: uninstall in progress")
            return .refusedUninstalling
        }
        if isTerminating() {
            restartLog.notice("Host restart refused: app is terminating")
            return .refusedShuttingDown
        }
        if supervisor.isShutDown {
            restartLog.notice("Host restart refused: the supervisor is shut down")
            return .refusedShuttingDown
        }

        restartLog.notice("Host restart requested from the menu item")
        forward()
        return .requested
    }
}
