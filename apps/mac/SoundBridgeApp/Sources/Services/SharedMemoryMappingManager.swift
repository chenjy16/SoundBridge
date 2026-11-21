import Foundation
import Combine
import Darwin
import os.log
import CSoundBridgeAudio

private let logger = Logger(subsystem: "com.soundbridge.app", category: "SharedMemoryMappingManager")

// MARK: - Identity

/// What distinguishes one published mapping incarnation from another.
///
/// The path is deliberately **not** part of it. The Host publishes with
/// `rename(staging, path)`, so the path is stable across incarnations while the
/// inode underneath changes (`SharedMemoryManager.createMemory`). Anything that
/// keys off the path alone would treat the old file as current forever — the
/// stale-mmap bug P2 Batch 3 exists to remove.
struct SharedMemoryIdentity: Equatable {
    /// File-system identity of the mapped inode. `fstat` on the descriptor we
    /// actually mapped, never `stat` on the path afterwards.
    let device: dev_t
    let inode: ino_t
    /// `admission_epoch` — the Host writes a fresh random value into every new
    /// mapping before it publishes. Existing ABI, no header change needed.
    let epoch: UInt64
    /// The Host session (`_reserved` "SB6A" marker + UUID) that created it.
    /// Second, independent evidence: a restarted Host has a new session.
    let hostSession: UUID?
}

/// Result of one attach attempt. Every failure mode in the task's
/// DISCOVER → OPEN → IDENTIFY → MMAP → VALIDATE → PUBLISH pipeline has a case,
/// so a caller can tell "no Host yet" from "wrong incarnation" from "corrupt".
enum SharedMemoryAttachOutcome: Equatable {
    case attached(SharedMemoryIdentity, generation: UInt64)
    case alreadyCurrent(SharedMemoryIdentity)
    case fileMissing
    case openFailed(Int32)
    case identityUnreadable(Int32)
    case fileTooSmall(Int)
    case mapFailed(Int32)
    case invalidHeader(String)
    case notAnIncarnation(String)
    /// The path changed between `open` and `publish`: a newer incarnation exists.
    case superseded

    var didAttach: Bool {
        if case .attached = self { return true }
        return false
    }

    var isCurrent: Bool {
        switch self {
        case .attached, .alreadyCurrent: return true
        default: return false
        }
    }
}

/// One real `munmap`, as it happened.
///
/// `executor` is the pthread that ran the call, captured *inside* the unmap work
/// rather than where it was scheduled. A test can therefore say "the writer
/// thread did not do this" with a fact instead of a reading of the code.
struct SharedMemoryMappingUnmapRecord: Equatable {
    let generation: UInt64
    let inode: ino_t
    /// True when the caller was already on `attachQueue` (attach/publish/retire/
    /// stop). False when the release had to be handed to the queue.
    let inline: Bool
    let executor: UInt64
    /// How long the `munmap` call itself took. Measured around the call, so a
    /// page-table teardown that suddenly costs milliseconds on a real run is a
    /// number in the log rather than a guess.
    let durationMicroseconds: UInt64

    static func currentThreadIdentifier() -> UInt64 {
        UInt64(UInt(bitPattern: pthread_self()))
    }
}

/// Thread-safe list of what was unmapped and by whom.
///
/// Deliberately a separate object: an async unmap must still run and still be
/// recorded if the manager itself has already been released.
final class UnmapLedger {
    private let lock = NSLock()
    private var records: [SharedMemoryMappingUnmapRecord] = []

    func record(
        generation: UInt64,
        inode: ino_t,
        inline: Bool,
        executor: UInt64,
        durationMicroseconds: UInt64
    ) {
        lock.lock()
        records.append(
            SharedMemoryMappingUnmapRecord(
                generation: generation, inode: inode, inline: inline,
                executor: executor, durationMicroseconds: durationMicroseconds
            )
        )
        lock.unlock()
    }

    var all: [SharedMemoryMappingUnmapRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

/// What an EQ write achieved.
///
/// There is deliberately no `retry` case and no timeout: a write either lands in
/// the active incarnation or it does not happen at all.
enum SharedMemoryWriteResult: Equatable {
    case written(generation: UInt64)
    /// No incarnation is active — never attached, retired, or the Host is gone.
    /// The caller keeps its own state (the App is the EQ block's only writer) and
    /// re-applies it when `onMappingPublished` fires.
    case unavailable
}

// MARK: - Manager

/// Owns the App's single shared-memory mapping.
///
/// P2 Batch 3 replaced per-object `mmap` ownership (`EQController` used to hold
/// a raw pointer and a size) with one manager that answers three questions in
/// one place: *which incarnation is current*, *may this write enter it*, and
/// *when is it safe to unmap the previous one*.
///
/// Concurrency model — deliberately the simplest one that can be proved:
///
/// 1. **One writer of `active`.** `lock` guards `active`, each mapping's
///    `retired` / `leases` / `unmapped` flags, and the generation counter.
///    Nothing else may touch them.
/// 2. **One attach at a time.** Every open / fstat / mmap / validate / publish
///    runs on `attachQueue`, a serial queue. Two notifications cannot race to
///    publish, so an older attach can never overwrite a newer one (§12 D).
/// 3. **No I/O under the lock.** Each step is a separate function call; the lock
///    is held only for pointer bookkeeping, never across `open`, `mmap`,
///    `lstat` or `munmap`. The UI thread never blocks on file I/O either: the
///    public entry points are `async` onto `attachQueue`.
/// 4. **Leases, not sleeps.** A writer takes a lease under `lock` before it
///    dereferences the pointer and releases it after. `munmap` happens only when
///    `retired && leases == 0`, and the `unmapped` flag makes that decision
///    single-shot, so a double `munmap` is impossible rather than unlikely.
final class SharedMemoryMappingManager {

    static let shared = SharedMemoryMappingManager()

    // MARK: Mapping

    /// One incarnation, kept alive by strong references for as long as a writer
    /// holds a lease. The memory is released explicitly, never in `deinit`, so
    /// there is exactly one place that decides when `munmap` may run.
    private final class AttachedMapping {
        let pointer: UnsafeMutablePointer<RFSharedAudio>
        let size: Int
        let identity: SharedMemoryIdentity
        let generation: UInt64
        var retired = false
        var leases = 0
        var unmapped = false

        init(
            pointer: UnsafeMutablePointer<RFSharedAudio>,
            size: Int,
            identity: SharedMemoryIdentity,
            generation: UInt64
        ) {
            self.pointer = pointer
            self.size = size
            self.identity = identity
            self.generation = generation
        }
    }

    // MARK: State

    private let lock = NSLock()
    private var active: AttachedMapping?
    private var generationCounter: UInt64 = 0
    private var fallbackTimer: DispatchSourceTimer?

    /// P2 Batch 4: every real `munmap` this manager performs is recorded here.
    ///
    /// The record is written by the thread that actually unmaps, so a test can
    /// assert both "exactly once" and "not on the writer's thread" instead of
    /// trusting a comment. It lives outside the manager so an async unmap that
    /// outlives the manager still records and still runs.
    private let unmaps = UnmapLedger()

    var unmapRecords: [SharedMemoryMappingUnmapRecord] { unmaps.all }

    /// Marks work that is already running on `attachQueue`, so `performUnmap`
    /// can run inline instead of queueing behind itself.
    private let queueKey = DispatchSpecificKey<UInt8>()

    /// The device whose mapping the App last asked for.
    ///
    /// Confined to `attachQueue`: every read and write happens there. It is kept
    /// even when the attach failed, which is what lets the fallback timer retry a
    /// Host that had not published yet — the "Host is starting" case. In
    /// production `deviceUIDProvider` takes precedence, so this can never pin the
    /// writer to a device the user has left.
    private var desiredUID: String?

    /// All attach work is serialised here. See (2) above.
    private let attachQueue = DispatchQueue(label: "com.soundbridge.app.mapping.attach")

    /// Production: `/tmp/soundbridge-<uid>-<sanitized uid>` via `PathManager`.
    /// Tests inject a throwaway directory so a fixture can never open, truncate
    /// or unlink a real shared-memory file.
    private let pathForUID: (String) -> String

    /// How often the structural fallback re-checks the inode. A notification
    /// that never arrives must cost a couple of seconds, not a session.
    private let fallbackInterval: TimeInterval = 2.0

    /// Asks the App which device's mapping should be current. Set by
    /// `AppDelegate`; `nil` in tests that attach paths directly.
    var deviceUIDProvider: (() -> String?)?

    /// Fired on the main queue when a new incarnation becomes active.
    ///
    /// `generation` increments once per publication, which is how the EQ writer
    /// knows its previous write went to a mapping that no longer exists.
    let mappingPublished = PassthroughSubject<(identity: SharedMemoryIdentity, generation: UInt64), Never>()

    /// Fired on the main queue when the current mapping is retired.
    let mappingUnavailable = PassthroughSubject<Void, Never>()

    init(pathForUID: @escaping (String) -> String = { SharedMemoryMappingManager.defaultPath(forUID: $0) }) {
        self.pathForUID = pathForUID
        attachQueue.setSpecific(key: queueKey, value: 1)
    }

    /// Mirrors `PathManager.sharedMemoryPath(uid:)` in the Host and
    /// `SharedMemoryPath()` in the driver. Kept byte-identical on purpose: the
    /// three sides must agree on the file, and this is the only copy in the App.
    static func defaultPath(forUID uid: String, ownerUID: uid_t = getuid()) -> String {
        let safeUID = uid
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "/tmp/soundbridge-\(ownerUID)-\(safeUID)"
    }

    // MARK: Lifecycle

    /// Install the fallback timer and attach once. Called once from
    /// `AppDelegate`, so the mapping does not depend on any View existing.
    func start() {
        attachQueue.async { [weak self] in
            guard let self else { return }
            self.installFallbackTimer()
            guard let uid = self.requestedUID(), !uid.isEmpty else { return }
            _ = self.attachWork(uid: uid, depth: 0)
        }
    }

    func stop() {
        fallbackTimer?.cancel()
        fallbackTimer = nil
        // Synchronous on purpose: this runs from `applicationWillTerminate`, and
        // leaving a writer mid-flight would mean unmapping under it.
        //
        // It is also the drain point for P2 Batch 4's async unmaps: a serial
        // queue runs what is already enqueued before the sync block, so every
        // unmap scheduled up to here has completed by the time this returns.
        attachQueue.sync { [weak self] in
            self?.retireActive(reason: "the App is terminating")
        }
    }

    private func installFallbackTimer() {
        dispatchPrecondition(condition: .onQueue(attachQueue))
        guard fallbackTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: attachQueue)
        timer.schedule(
            deadline: .now() + fallbackInterval,
            repeating: fallbackInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            self?.revalidateWork()
        }
        timer.resume()
        fallbackTimer = timer
    }

    // MARK: Public entry points

    /// Ask for `uid`'s mapping to become current. Returns immediately; the work
    /// happens on the attach queue so a slow `coreaudiod` cannot stall the UI.
    func requestAttach(for uid: String) {
        guard !uid.isEmpty else { return }
        attachQueue.async { [weak self] in
            _ = self?.attachWork(uid: uid, depth: 0)
        }
    }

    /// Cheap structural check: is the file at the path still the inode we mapped?
    ///
    /// This is the notification-loss answer (§12 E). It costs one `lstat` and
    /// runs at `fallbackInterval`, not per EQ write: a per-write `stat` would be
    /// the "high-frequency file-system scan" the task forbids, and it would not
    /// add safety — the write path is already protected by the lease + retire
    /// flags, not by re-reading the path.
    func revalidate() {
        attachQueue.async { [weak self] in
            self?.revalidateWork()
        }
    }

    /// The incarnation a writer would currently enter, for diagnostics and tests.
    var currentIdentity: SharedMemoryIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return active?.identity
    }

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return active?.generation ?? 0
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active.map { !$0.retired } ?? false
    }

    /// Perform one attach synchronously. Serialised on the attach queue, so it is
    /// safe to call from several threads — which is how the concurrency tests
    /// drive "two notifications at once" without a real notification channel.
    func attachSynchronously(uid: String) -> SharedMemoryAttachOutcome {
        attachQueue.sync { attachWork(uid: uid, depth: 0) }
    }

    func attachSynchronously(path: String) -> SharedMemoryAttachOutcome {
        attachQueue.sync { attachPath(path, depth: 0) }
    }

    // MARK: Writer path

    /// Run `body` against the active mapping, or report that there is none.
    ///
    /// The lease is taken and released around `body`, so a replacement that
    /// lands while `body` runs cannot unmap the memory underneath it.
    @discardableResult
    func write(_ body: (UnsafeMutablePointer<RFSharedAudio>) -> Void) -> SharedMemoryWriteResult {
        lock.lock()
        guard let mapping = active, !mapping.retired else {
            lock.unlock()
            return .unavailable
        }
        mapping.leases += 1
        let pointer = mapping.pointer
        let generation = mapping.generation
        lock.unlock()

        body(pointer)

        releaseLease(mapping)
        return .written(generation: generation)
    }

    /// Convenience for the EQ writer. The App is the only writer of the EQ block
    /// (`rf_store_eq_snapshot` has no other caller), so re-applying this after a
    /// new incarnation appears cannot overwrite anything the Host maintains.
    ///
    /// The lease taken by `write` protects the memory; this lock protects the
    /// *seqlock*. `rf_store_eq_snapshot` reads `eq_sequence`, copies the payload,
    /// then stores `seq + 2` — a single-writer contract. Two concurrent writers
    /// can both read the same even value and leave the block looking like a
    /// write is forever in progress, at which point the Host's reader gives up
    /// and falls back to a stale snapshot. Ordered `eqCommitLock` (never taken
    /// while holding `lock`) keeps the sequence coherent for the price of one
    /// uncontended lock per EQ change.
    @discardableResult
    func writeEQSnapshot(_ snapshot: RFEQSnapshot) -> SharedMemoryWriteResult {
        eqCommitLock.lock()
        defer { eqCommitLock.unlock() }
        return write { memory in
            var copy = snapshot
            rf_store_eq_snapshot(memory, &copy)
        }
    }

    /// Serialises commits into the EQ block so `eq_sequence` cannot be torn by
    /// two writers. Lock order is always `eqCommitLock` → `lock`; nothing takes
    /// them the other way round, so this cannot deadlock against `publish` or
    /// `retireActive`.
    private let eqCommitLock = NSLock()

    private func releaseLease(_ mapping: AttachedMapping) {
        var toUnmap: AttachedMapping?
        lock.lock()
        mapping.leases -= 1
        if mapping.leases == 0, mapping.retired, !mapping.unmapped {
            mapping.unmapped = true
            toUnmap = mapping
        }
        lock.unlock()
        if let toUnmap {
            performUnmap(toUnmap)
        }
    }

    /// The single place that calls `munmap` for a mapping that was published.
    ///
    /// P2 Batch 3 left the question open: `releaseLease` runs on whichever
    /// thread finished writing, and EQ writes are driven from the main queue, so
    /// "the last lease is released by the UI thread" was a real possibility and
    /// the unmap happened there. Batch 4 makes the thread of record unambiguous:
    /// the unmap runs on `attachQueue`, inline when the caller is already on it
    /// (attach/publish/retire/stop) and asynchronously otherwise (a writer's
    /// last lease release).
    ///
    /// Safety of the async path, point by point:
    /// - a retired mapping accepts no new lease (`write` refuses `retired`), so
    ///   `leases == 0` cannot go back up;
    /// - `unmapped` is set under `lock` before anything is queued, so at most one
    ///   task can exist per incarnation — a double `munmap` is structurally
    ///   impossible, not merely unlikely;
    /// - the closure captures `mapping` strongly, so `pointer`, `size` and
    ///   identity stay valid until the task runs and the object cannot be
    ///   destroyed underneath it;
    /// - `lock` is not held here, so waiting for the queue never happens inside
    ///   the critical section.
    private func performUnmap(_ mapping: AttachedMapping) {
        let ledger = unmaps
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            Self.runUnmap(mapping, inline: true, ledger: ledger)
            return
        }
        // `self` is deliberately not captured: the unmap must run and be
        // recorded even if the manager has already been released.
        attachQueue.async {
            Self.runUnmap(mapping, inline: false, ledger: ledger)
        }
    }

    /// The one place a real `munmap` happens, so it is also the one place the
    /// ledger and the log can be written from.
    ///
    /// The log line is the runtime outlet for the retirement lifecycle: the Host
    /// logs its own side (`Render path: inFlight=… deferred=… retireTimeouts=…`),
    /// and this line pairs with it — same generation, the identity of the thread
    /// that actually freed the pages, and how long it took. `os.Logger` supplies
    /// the timestamp, so no clock is read here just to fill a field list.
    private static func runUnmap(_ mapping: AttachedMapping, inline: Bool, ledger: UnmapLedger) {
        let started = DispatchTime.now().uptimeNanoseconds
        munmap(mapping.pointer, mapping.size)
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        let microseconds = elapsed / 1_000
        let executor = SharedMemoryMappingUnmapRecord.currentThreadIdentifier()

        ledger.record(
            generation: mapping.generation,
            inode: mapping.identity.inode,
            inline: inline,
            executor: executor,
            durationMicroseconds: microseconds
        )
        logger.notice(
            "munmap generation=\(mapping.generation) inode=\(UInt64(mapping.identity.inode)) inline=\(inline) executor=\(executor, format: .hex) duration_us=\(microseconds)"
        )
    }

    // MARK: Attach pipeline

    private func requestedUID() -> String? {
        if let uid = deviceUIDProvider?(), !uid.isEmpty { return uid }
        return desiredUID
    }

    private func revalidateWork() {
        dispatchPrecondition(condition: .onQueue(attachQueue))
        guard let uid = requestedUID(), !uid.isEmpty else { return }
        let path = pathForUID(uid)

        var onDisk = stat()
        guard lstat(path, &onDisk) == 0 else {
            // No file: either the Host has not published yet or it cleaned up.
            // Either way the previous incarnation must stop accepting writes.
            retireActive(reason: "the shared-memory file is gone")
            return
        }
        let current = currentIdentity
        if current?.device == onDisk.st_dev, current?.inode == onDisk.st_ino {
            return
        }
        _ = attachWork(uid: uid, depth: 0)
    }

    /// Retries only when the path was replaced mid-attach, and only a bounded
    /// number of times. A rename during `open` is expected (the Host publishes
    /// by renaming); a loop that never converges means the Host is republishing
    /// faster than we can attach, which the next timer tick will pick up.
    private func attachWork(uid: String, depth: Int) -> SharedMemoryAttachOutcome {
        // Remembered before the attempt, so a Host that has not published yet is
        // retried by the fallback timer instead of never being asked again.
        desiredUID = uid
        let outcome = attachPath(pathForUID(uid), depth: depth)
        if case .superseded = outcome, depth < 3 {
            return attachWork(uid: uid, depth: depth + 1)
        }
        return outcome
    }

    private func attachPath(_ path: String, depth: Int) -> SharedMemoryAttachOutcome {
        dispatchPrecondition(condition: .onQueue(attachQueue))

        // OPEN
        let fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT {
                logger.info("No mapping yet at \(path, privacy: .public)")
                return .fileMissing
            }
            logger.error("open(\(path, privacy: .public)) failed: \(String(cString: strerror(code)), privacy: .public)")
            return .openFailed(code)
        }
        defer { close(fd) }

        // IDENTIFY — on the descriptor, so this is the inode we are about to map.
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            return .identityUnreadable(errno)
        }

        // A duplicate notification for the incarnation we already hold: adopt it
        // as current and touch nothing. This is what keeps repeated notifications
        // from churning the mapping (and from flushing EQ twice).
        if let current = currentIdentity {
            if current.device == opened.st_dev, current.inode == opened.st_ino {
                return .alreadyCurrent(current)
            }
            // The path points at a different inode now. Whatever the outcome of
            // validating the new one, the mapping we hold is history: retire it
            // *before* the attempt, so a failed attach cannot leave the writer
            // pointing at an exit inode (task §2.2 / §4.4).
            retireActive(reason: "the path now points at a different inode")
        }

        guard opened.st_size >= MemoryLayout<RFSharedAudio>.size else {
            logger.error("Mapping at \(path, privacy: .public) is \(opened.st_size) bytes, smaller than the header")
            return .fileTooSmall(Int(opened.st_size))
        }

        // MMAP
        let size = Int(opened.st_size)
        let raw = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard raw != MAP_FAILED, let raw else {
            return .mapFailed(errno)
        }
        let pointer = raw.assumingMemoryBound(to: RFSharedAudio.self)

        func discard(_ outcome: SharedMemoryAttachOutcome) -> SharedMemoryAttachOutcome {
            munmap(pointer, size)
            return outcome
        }

        // VALIDATE — the shared C rule the driver also uses. A layout mismatch is
        // refused rather than attached best-effort.
        let validation = rf_validate_header(pointer)
        guard validation == RF_VALIDATE_OK else {
            let reason = String(cString: rf_validate_result_string(validation))
            logger.error("Mapping at \(path, privacy: .public) rejected: \(reason, privacy: .public)")
            return discard(.invalidHeader(reason))
        }

        guard let session = Self.hostSession(of: pointer) else {
            return discard(.notAnIncarnation("the Host session marker is absent"))
        }
        let epoch = rf_admission_epoch(pointer)
        guard epoch != 0 else {
            return discard(.notAnIncarnation("the admission epoch is zero"))
        }

        // Still the same inode at the path? A Host that renamed a new mapping in
        // while we were validating means this one is already history.
        var onDisk = stat()
        guard lstat(path, &onDisk) == 0,
              onDisk.st_dev == opened.st_dev,
              onDisk.st_ino == opened.st_ino else {
            return discard(.superseded)
        }

        let identity = SharedMemoryIdentity(
            device: opened.st_dev,
            inode: opened.st_ino,
            epoch: epoch,
            hostSession: session
        )

        return publish(pointer: pointer, size: size, identity: identity)
    }

    /// PUBLISH: swap `active` under the lock, retire the previous incarnation and
    /// unmap it only if nobody is inside it.
    private func publish(
        pointer: UnsafeMutablePointer<RFSharedAudio>,
        size: Int,
        identity: SharedMemoryIdentity
    ) -> SharedMemoryAttachOutcome {
        lock.lock()
        if let current = active, current.identity == identity {
            lock.unlock()
            munmap(pointer, size)
            return .alreadyCurrent(current.identity)
        }
        generationCounter &+= 1
        let mapping = AttachedMapping(
            pointer: pointer,
            size: size,
            identity: identity,
            generation: generationCounter
        )
        let previous = active
        previous?.retired = true
        active = mapping

        var toUnmap: AttachedMapping?
        if let previous, previous.leases == 0, !previous.unmapped {
            previous.unmapped = true
            toUnmap = previous
        }
        lock.unlock()

        if let toUnmap {
            performUnmap(toUnmap)
        }

        logger.info(
            "Attached incarnation inode=\(identity.inode) epoch=\(identity.epoch) generation=\(mapping.generation)"
        )
        let generation = mapping.generation
        DispatchQueue.main.async { [weak self] in
            self?.mappingPublished.send((identity, generation))
        }
        return .attached(identity, generation: generation)
    }

    private func retireActive(reason: String) {
        lock.lock()
        guard let mapping = active else {
            lock.unlock()
            return
        }
        active = nil
        mapping.retired = true
        var toUnmap: AttachedMapping?
        if mapping.leases == 0, !mapping.unmapped {
            mapping.unmapped = true
            toUnmap = mapping
        }
        lock.unlock()

        if let toUnmap {
            performUnmap(toUnmap)
        }
        logger.notice("Retired the active mapping: \(reason, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.mappingUnavailable.send(())
        }
    }

    // MARK: Header identity helpers

    /// Read the Host session out of the reserved area.
    ///
    /// `rf_set_host_session` writes a 4-byte "SB6A" marker followed by a 16-byte
    /// RFC 4122 UUID, once, before the mapping is published. There is no C helper
    /// that extracts it, so the 28 reserved bytes are read directly — this is
    /// reading existing ABI, not extending it.
    static func hostSession(of memory: UnsafePointer<RFSharedAudio>) -> UUID? {
        var reserved = memory.pointee._reserved
        let marker: [UInt8] = withUnsafeBytes(of: &reserved) { Array($0.prefix(4)) }
        guard marker == [0x53, 0x42, 0x36, 0x41] else { return nil }   // "SB6A"
        return withUnsafeBytes(of: &reserved) { raw -> UUID? in
            guard raw.count >= 20 else { return nil }
            var bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &bytes) { destination in
                destination.copyBytes(from: raw[4..<20])
            }
            return UUID(uuid: bytes)
        }
    }
}
