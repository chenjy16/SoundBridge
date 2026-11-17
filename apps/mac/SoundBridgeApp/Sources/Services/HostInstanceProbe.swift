import Darwin
import Foundation
import CSoundBridgeAudio

// `flock(2)` shares its name with `struct flock` in the Darwin module, so the
// function itself is not nameable from Swift. Bound explicitly, the same way
// IPCController binds the notify_* family.
@_silgen_name("flock")
private func _lockFileDescriptor(_ fd: Int32, _ operation: Int32) -> Int32

/// Answers "is a SoundBridgeHost already running for this user?".
///
/// This replaced `pgrep -f SoundBridgeHost`, which had two problems. It matched
/// any process whose command line contained the string (a build, an editor, a
/// terminal), and it was a check with no atom: two launches a millisecond apart
/// both saw "not running" and both started a Host. The second Host then rebuilt
/// the shared memory out from under the first, which is how the app ended up
/// with a driver attached to a mapping nobody writes.
///
/// The Host holds an exclusive `flock` on the path below for its whole life. Here
/// the same file is opened and the same lock is attempted non-blockingly: if it
/// fails with `EWOULDBLOCK`, a Host is alive. Nothing is written, created, or
/// deleted — a probe that mutated the file would be a worse bug than the one it
/// replaces.
enum HostInstanceProbe {

    /// The suffix every instance lock carries, from the same header.
    ///
    /// Used by the `/tmp` cleanup sweep so it can tell a lock file (which must
    /// survive, because unlinking it would let a second Host take a "free" lock
    /// on a new inode while the first still holds the old one) from the leftover
    /// control files that are safe to remove.
    static let lockSuffix = RF_INSTANCE_LOCK_PATH_SUFFIX

    /// The path the Host locks. Derived from `RFSharedAudio.h` so the two sides
    /// cannot drift into two different files.
    static func lockPath(uid: uid_t = getuid()) -> String {
        return "\(RF_INSTANCE_LOCK_PATH_PREFIX)\(uid)\(RF_INSTANCE_LOCK_PATH_SUFFIX)"
    }

    /// `true` when another process holds the lock.
    ///
    /// A missing file means no Host has ever started under this UID: `false`, not
    /// an error. That includes the case where the App removed `/tmp` leftovers.
    static func isHostRunning(path: String = lockPath()) -> Bool {
        let fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        if _lockFileDescriptor(fd, LOCK_EX | LOCK_NB) != 0 {
            return errno == EWOULDBLOCK || errno == EAGAIN
        }

        // The lock was free, so no Host holds it. Release it immediately: holding
        // it even briefly would make a starting Host think one is already running.
        _ = _lockFileDescriptor(fd, LOCK_UN)
        return false
    }

    /// What the owner recorded, for logs. `nil` when the file holds nothing.
    static func ownerDescription(path: String = lockPath()) -> String? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
