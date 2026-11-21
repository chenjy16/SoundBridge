import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "Shutdown")

/// Ordered, run-once teardown.
///
/// `cleanup()` is reachable from two `DispatchSourceSignal` handlers, both on the
/// main queue. They are serialised against each other, but nothing stopped a
/// second teardown request from a different path (a signalled Host that is
/// already stopping, a future termination hook) from running the whole sequence
/// again: a second `unlink` of the control file, a second 1.2 s wait, a second
/// `instanceLock.release()`.
///
/// The individual calls happen to tolerate that today — `stop()` and
/// `memoryManager.cleanup()` both no-op on an empty map — but "the lock is
/// released last" is then an assertion about a sequence that ran twice, and a
/// future teardown step without a nil guard turns it into a crash on quit.
///
/// So the sequence is modelled instead of implied: the steps are an ordered
/// enum, each runs at most once, and the last one is the lock release. Tests can
/// assert the order, the count, and the idempotency without touching CoreAudio
/// or the real lock file.
struct ShutdownSequence {

    /// Teardown steps in execution order.
    ///
    /// Declaration order *is* the contract (`allCases` is the execution list),
    /// so `releaseInstanceLock` may only be moved by deliberately moving it.
    enum Step: String, CaseIterable, Equatable {
        /// Publish `.stopping` first: the App must stop treating a half-torn-down
        /// Host as active before the resources behind that claim disappear.
        case markStopping
        case stopConnectionMonitor
        case stopSleepWakeMonitor
        /// Remove the HAL property listeners.
        ///
        /// Before anything that publishes state: a notification delivered after
        /// this point could otherwise re-enter the device path and write into a
        /// Host that is leaving. Removal must ignore
        /// `kAudioHardwareBadObjectError` — after a rebuild the objects are
        /// already gone.
        case removePropertyListeners
        /// Before the shared memory is unmapped, so no heartbeat writes into a
        /// mapping that is being torn down.
        case stopHeartbeat
        // P2 Batch 2 removed `restorePhysicalDevice` from this list. It put the
        // physical device back as the system default output during a normal
        // quit — a lifecycle event changing the user's default output, which the
        // product forbids. A shutdown now releases resources and leaves the
        // default output exactly where the user put it.
        case stopAudioEngine
        case removeControlFile
        /// The driver reads the control file and its mapping without a lock, so
        /// the unmap path waits for it to notice the Host is gone.
        case waitForDriverDetach
        case unlinkSharedMemory
        case maybeRestartCoreAudio
        /// Publish `.stopped` while the instance lock is still held.
        ///
        /// The App resolves "is a Host alive" from the lock and "what is it
        /// doing" from this file, and the lock outranks the file. Writing the
        /// final state after the release would mean it was never readable as
        /// "stopped" — the lock would already say "gone".
        case publishStopped
        /// Last: the instance lock covers every resource touched above.
        case releaseInstanceLock
    }

    private(set) var executed: [Step] = []
    private(set) var isComplete = false

    /// Run every step once, in order.
    ///
    /// - Parameter body: invoked once per step. It must not throw; a step that
    ///   needs to skip work (the coreaudiod policy, for instance) logs and
    ///   returns.
    /// - Returns: `true` for the pass that performed the teardown, `false` for a
    ///   duplicate request. Callers use the return value to decide whether
    ///   "Cleanup complete" is theirs to log.
    @discardableResult
    mutating func run(_ body: (Step) -> Void) -> Bool {
        guard !isComplete else {
            logger.info("Teardown already ran; ignoring duplicate shutdown request")
            return false
        }

        // Marked before the first step: a step that re-enters shutdown (a signal
        // delivered while a step is on the stack) must not start a second pass.
        isComplete = true

        for step in Step.allCases {
            executed.append(step)
            body(step)
        }
        return true
    }

    /// Whether the recorded order matches the declared order exactly once.
    var ranEveryStepOnce: Bool {
        executed == Step.allCases
    }

    /// The ordering guarantee that is easy to lose in a refactor.
    var releasedLockLast: Bool {
        executed.last == .releaseInstanceLock
    }
}
