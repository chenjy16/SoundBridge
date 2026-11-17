import CSoundBridgeAudio
import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "HostInstanceLock")

// `flock(2)` shares its name with `struct flock` in the Darwin module, so the
// function itself is not nameable from Swift. Bind it explicitly, the same way
// main.swift binds notify_register_dispatch.
@_silgen_name("flock")
private func _lockFileDescriptor(_ fd: Int32, _ operation: Int32) -> Int32

/// Why a second Host was told to go away, or why the first one could not even
/// ask. Kept separate from the lifecycle outcomes so a lock problem is never
/// reported as a shared-memory or driver problem.
enum HostInstanceAcquireResult: Equatable {
    /// This process owns the lock and may touch shared memory.
    case acquired
    /// Another live process owns the lock for this UID.
    case heldByAnotherInstance(owner: String?)
    /// The lock file could not be opened or locked for a reason that is not
    /// contention (permissions, read-only /tmp, a symlink planted at the path).
    case failed(reason: String)
}

/// Exit statuses the Host uses so a log reader (or the App) can tell a startup
/// refusal from a crash.
enum HostExitCode {
    static let instanceConflict: Int32 = 3
    static let instanceLockFailure: Int32 = 4
}

/// Process-level single-instance guard for `SoundBridgeHost`.
///
/// The lock is a POSIX `flock` on an open descriptor, not the existence of a
/// file. That distinction is the whole point: `pgrep -f SoundBridgeHost` (what
/// the App used to rely on) is a check with no atom, so two Hosts can both pass
/// it and then unlink each other's shared memory, leaving the driver talking to
/// whichever mapping won and the other process consuming frames nobody writes.
///
/// Properties this buys, and why each is here:
///
/// - `LOCK_EX | LOCK_NB`: the kernel arbitrates. Exactly one of N racing
///   processes gets the lock; the rest fail immediately instead of queueing.
/// - The descriptor is held for the life of the process, so `exit()`, SIGTERM
///   and SIGKILL all release it without any cleanup code running. A crashed
///   Host cannot leave the lock held.
/// - The path is per-UID, so two logged-in users never contend, while two
///   instances of the same user always do.
/// - The file is never removed on release. Unlinking a lock file is how a lock
///   stops protecting anything: the next process creates a *new* inode and both
///   can hold "the" lock. A leftover file is harmless, because an unheld flock
///   is not a held lock.
/// - `O_NOFOLLOW` + an inode check after locking: someone else replacing or
///   unlinking the path (the App sweeps `/tmp/soundbridge-*` on quit) would
///   otherwise leave us holding a lock on an inode no other process will open.
final class HostInstanceLock {
    /// `/tmp` rather than a per-user temp dir on purpose: the path has to be
    /// derivable by every process of this user (App, Host, a second App launch)
    /// without sharing defaults. `/tmp`'s sticky bit keeps other users from
    /// unlinking a file we own.
    ///
    /// The prefix and suffix come from `RFSharedAudio.h` because the App asks the
    /// same question about the same file. Two definitions would eventually mean
    /// two paths, and then "is a Host running?" has no answer.
    static func defaultPath(uid: uid_t = getuid()) -> String {
        return "\(RF_INSTANCE_LOCK_PATH_PREFIX)\(uid)\(RF_INSTANCE_LOCK_PATH_SUFFIX)"
    }

    /// Rejects paths the App's `/tmp/soundbridge-*` sweep would delete. The App
    /// skips `.lock` files now, but a name that cannot collide is cheaper to
    /// reason about than a name that depends on the other side remembering.
    static let lockSuffix = RF_INSTANCE_LOCK_PATH_SUFFIX

    let path: String
    private var fd: Int32 = -1
    private(set) var isHeld = false

    init(path: String = HostInstanceLock.defaultPath()) {
        self.path = path
    }

    deinit {
        release()
    }

    /// Try to become the single Host for this UID.
    ///
    /// Bounded retry: if the path is replaced between `open` and `flock`, the
    /// lock we hold is on an orphan inode, so we start over instead of
    /// pretending to be exclusive.
    func acquire(maxAttempts: Int = 3) -> HostInstanceAcquireResult {
        if isHeld { return .acquired }

        for attempt in 1...maxAttempts {
            // No O_EXCL: the file is expected to persist. Existence is not the
            // lock, and requiring absence would turn a reboot-surviving file
            // into a permanently broken launch.
            let candidate = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
            guard candidate >= 0 else {
                let code = errno
                let reason = String(cString: strerror(code))
                logger.error("Cannot open instance lock \(self.path, privacy: .public): \(reason, privacy: .public)")
                return .failed(reason: "open: \(reason)")
            }

            if _lockFileDescriptor(candidate, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                close(candidate)
                if code == EWOULDBLOCK || code == EAGAIN {
                    let owner = Self.describeOwner(path: path)
                    logger.notice("Instance lock held by \(owner ?? "unknown", privacy: .public)")
                    return .heldByAnotherInstance(owner: owner)
                }
                let reason = String(cString: strerror(code))
                logger.error("flock failed on \(self.path, privacy: .public): \(reason, privacy: .public)")
                return .failed(reason: "flock: \(reason)")
            }

            // The lock is ours, but is the file still the one at `path`? The App
            // unlinks /tmp/soundbridge-* on quit; if that ran between our open
            // and our flock, another Host would create a fresh file and we would
            // both be "exclusive".
            guard Self.pathRefersToSameFile(fd: candidate, path: path) else {
                logger.warning("Instance lock file was replaced during acquisition (attempt \(attempt)); retrying")
                _ = _lockFileDescriptor(candidate, LOCK_UN)
                close(candidate)
                continue
            }

            fd = candidate
            isHeld = true
            writeOwnerRecord()
            logger.info("Instance lock acquired: \(self.path, privacy: .public) (pid \(getpid()))")
            return .acquired
        }

        return .failed(reason: "lock file kept being replaced")
    }

    /// Release on the normal exit path. The file stays; see the type comment.
    func release() {
        guard fd >= 0 else { return }
        if isHeld {
            _ = _lockFileDescriptor(fd, LOCK_UN)
        }
        close(fd)
        fd = -1
        isHeld = false
    }

    /// What the current owner recorded, for logs and for a second instance's
    /// diagnostic message. Returns `nil` when the file holds nothing readable.
    func describeOwner() -> String? {
        return Self.describeOwner(path: path)
    }

    // MARK: - Non-owning probe

    /// Is a Host holding the lock right now?
    ///
    /// Used by the App to answer "is a Host running" without spawning `pgrep`
    /// and pattern-matching a process name. It opens the same path, so it races
    /// with a starting Host exactly the way the Host races with itself.
    static func isHeld(path: String = HostInstanceLock.defaultPath()) -> Bool {
        let probe = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard probe >= 0 else { return false }
        defer { close(probe) }

        if _lockFileDescriptor(probe, LOCK_EX | LOCK_NB) != 0 {
            return errno == EWOULDBLOCK || errno == EAGAIN
        }

        // We got it, so nobody else holds it. Give it straight back.
        _ = _lockFileDescriptor(probe, LOCK_UN)
        return false
    }

    // MARK: - Private

    private func writeOwnerRecord() {
        guard fd >= 0 else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let record = "pid=\(getpid()) uid=\(getuid()) since=\(stamp)\n"
        guard let data = record.data(using: .utf8) else { return }

        // Best effort: a read-only-but-lockable descriptor would make this fail,
        // and a missing owner line must never stop the Host from starting.
        _ = ftruncate(fd, 0)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = pwrite(fd, base, raw.count, 0)
        }
    }

    private static func pathRefersToSameFile(fd: Int32, path: String) -> Bool {
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { return false }

        var onDisk = stat()
        guard lstat(path, &onDisk) == 0 else { return false }

        return opened.st_dev == onDisk.st_dev && opened.st_ino == onDisk.st_ino
    }

    private static func describeOwner(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The one place that decides whether startup may continue.
///
/// Extracted so a test can prove "no lock, no shared memory" without launching
/// a second real Host, and so `main.swift` reads as a sequence of decisions
/// instead of an if-let ladder.
struct HostStartupGate {
    enum Decision: Equatable {
        case proceed
        case refuseInstanceConflict(owner: String?)
        case refuseLockFailure(reason: String)
    }

    let lock: HostInstanceLock

    init(lock: HostInstanceLock = HostInstanceLock()) {
        self.lock = lock
    }

    func evaluate() -> Decision {
        switch lock.acquire() {
        case .acquired:
            return .proceed
        case .heldByAnotherInstance(let owner):
            return .refuseInstanceConflict(owner: owner)
        case .failed(let reason):
            return .refuseLockFailure(reason: reason)
        }
    }
}
