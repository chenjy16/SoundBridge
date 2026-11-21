import Darwin
import Foundation

// Darwin notify API — not always visible during x86_64 cross-compilation.
@_silgen_name("notify_register_dispatch")
private func _notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ out_token: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping @convention(block) (Int32) -> Void
) -> UInt32

@_silgen_name("notify_cancel")
private func _notify_cancel(_ token: Int32) -> UInt32

/// Device info transmitted via IPC (device-state.json).
/// Contains only device list and active device — no volume/mute state.
struct IPCDeviceInfo: Codable, Equatable {
    let name: String
    let uid: String
    let isFixedVolume: Bool
}

struct IPCDeviceState: Codable, Equatable {
    let devices: [IPCDeviceInfo]
    /// Deprecated: this retains the managed physical device UID.
    /// Kept because it is the only key a pre-6A Host writes, and the device list
    /// still needs an answer on such a machine.
    let activeDeviceUID: String?
    /// The proxy target this Host is managing. Present only from a Phase 6A Host.
    /// Deliberately *not* the same question as the default output: a user who
    /// switched to the built-in speakers still has a managed proxy.
    let managedProxyUID: String?
    /// The device CoreAudio is actually sending audio to. Present only from a
    /// Phase 6A Host, where it is the authoritative answer.
    let systemDefaultOutputUID: String?
    /// Optional on purpose: a Host from before 1.2.0 does not write it, and this
    /// build must keep working with one. When present it carries the seven
    /// lifecycle levels, which is the difference between "a Host process exists"
    /// and "audio is actually flowing".
    let lifecycle: HostLifecycleReport?
    let protocolVersion: Int?
    let sessionID: String?
    let revision: UInt64?
    let controlCommitProtocol: Int?
    let controlCommitRevision: UInt64?

    /// The default output, preferring the explicit Phase 6A field.
    var effectiveDefaultOutputUID: String? {
        systemDefaultOutputUID ?? activeDeviceUID
    }
}

/// Handles IPC with the Host process via `device-state.json`.
///
/// - Host writes this file only on device plug/unplug (low frequency).
/// - App monitors the file via DispatchSource for changes.
/// - Volume/mute state is NOT included — that flows through CoreAudio API.
class IPCController {
    enum ControlConsistency: Equatable {
        case legacy, uncommitted, verified, pending
    }

    static let shared = IPCController()

    private let fileURL: URL
    private let controlURL: URL
    private let lockState: () -> HostInstanceProbe.State
    private let registerDarwin: Bool
    private let watcherOpened: (() -> Void)?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var watcherRetry: DispatchWorkItem?
    private let watcherRetryDelay: TimeInterval = 1
    private var watcherGeneration: UInt64 = 0
    private var monitoring = false
    private var acceptedLock: HostInstanceProbe.State?
    private var acceptedStates: [UUID: IPCDeviceState] = [:]
    private var capableSessions: Set<UUID> = []
    private var darwinNotifyToken: Int32 = 0
    private var darwinNotifyRegistered = false
    var onDeviceStateChanged: ((IPCDeviceState) -> Void)?
    var onDeviceStateUnavailable: (() -> Void)?
    /// verified 只表示控制文件中的设备名称与 UID 已关联，不证明实际音频流动。
    private(set) var latestControlConsistency: ControlConsistency = .pending
    /// Latest Host lifecycle report, or `nil` when the Host has not written one.
    ///
    /// Kept here as well as in `onDeviceStateChanged` so a caller that appears
    /// after the first notification can still read the current state instead of
    /// waiting for the next device change.
    private(set) var latestLifecycle: HostLifecycleReport?
    /// Latest whole state, for the same reason as `latestLifecycle`.
    private(set) var latestState: IPCDeviceState?

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("SoundBridge")

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true,
            attributes: nil
        )

        self.fileURL = appSupport.appendingPathComponent("device-state.json")
        self.controlURL = URL(fileURLWithPath: "/tmp/soundbridge-devices.txt")
        self.lockState = { HostInstanceProbe.state() }
        self.registerDarwin = true
        self.watcherOpened = nil
    }

    /// 注入路径、锁观察和注册窗口，供隔离测试使用。
    init(fileURL: URL, lockState: @escaping () -> HostInstanceProbe.State, registerDarwin: Bool = false,
         watcherOpened: (() -> Void)? = nil,
         controlURL: URL = URL(fileURLWithPath: "/tmp/soundbridge-devices.txt")) {
        self.fileURL = fileURL
        self.controlURL = controlURL
        self.lockState = lockState
        self.registerDarwin = registerDarwin
        self.watcherOpened = watcherOpened
    }

    /// 所有 watcher、读取和发布都在主队列串行执行。
    func startMonitoring() {
        precondition(Thread.isMainThread)
        stopMonitoring()
        monitoring = true
        if registerDarwin {
            let status = _notify_register_dispatch(
                "com.soundbridge.device-state-changed", &darwinNotifyToken, .main
            ) { [weak self] _ in self?.refreshAndNotify() }
            darwinNotifyRegistered = status == 0
            if status != 0 { print("[IPCController] Darwin notification registration failed: \(status)") }
        }
        armFileWatcher()
        refreshAndNotify()
    }

    private func armFileWatcher() {
        precondition(Thread.isMainThread)
        watcherGeneration &+= 1
        let generation = watcherGeneration
        fileWatcher?.cancel()
        fileWatcher = nil
        guard monitoring else { return }
        let fd = open(fileURL.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else {
            scheduleWatcherRetry()
            return
        }
        watcherOpened?()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setRegistrationHandler { [weak self] in
            guard let self, self.monitoring, self.watcherGeneration == generation else { return }
            var watched = stat()
            var current = stat()
            guard fstat(fd, &watched) == 0, lstat(self.fileURL.path, &current) == 0,
                  watched.st_dev == current.st_dev, watched.st_ino == current.st_ino else {
                // 注册前的替换不会产生 vnode 事件；限速重挂并立即读取当前路径。
                self.scheduleWatcherRetry()
                self.refreshAndNotify()
                return
            }
            self.refreshAndNotify()
        }
        source.setEventHandler { [weak self] in
            guard let self, self.monitoring, self.watcherGeneration == generation else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.armFileWatcher()
                if self.fileWatcher == nil { self.refreshAndNotify() }
            } else {
                self.refreshAndNotify()
            }
        }
        source.setCancelHandler { close(fd) }
        fileWatcher = source
        source.resume()
        // 立即读取；注册完成后还要核对 inode，以覆盖注册前替换的窗口。
        refreshAndNotify()
    }

    /// 文件持续替换或不可访问时限速重试，避免注册失败后占满主队列。
    private func scheduleWatcherRetry() {
        precondition(Thread.isMainThread)
        guard monitoring, watcherRetry == nil else { return }
        watcherGeneration &+= 1
        let generation = watcherGeneration
        fileWatcher?.cancel()
        fileWatcher = nil
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.monitoring, self.watcherGeneration == generation else { return }
            self.watcherRetry = nil
            self.armFileWatcher()
            self.refreshAndNotify()
        }
        watcherRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + watcherRetryDelay, execute: retry)
    }

    func stopMonitoring() {
        precondition(Thread.isMainThread)
        monitoring = false
        watcherGeneration &+= 1
        watcherRetry?.cancel()
        watcherRetry = nil
        if darwinNotifyRegistered {
            _ = _notify_cancel(darwinNotifyToken)
            darwinNotifyRegistered = false
        }
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    /// 唤醒只是提示；权威数据来自文件及当前持锁 Session。
    func refreshAndNotify() {
        precondition(Thread.isMainThread)
        if monitoring && fileWatcher == nil && watcherRetry == nil {
            armFileWatcher()
            if fileWatcher != nil { return }
        }
        let previous = latestState
        if let state = readDeviceState(), state != previous {
            onDeviceStateChanged?(state)
        } else if previous != nil && latestState == nil {
            onDeviceStateUnavailable?()
        }
    }

    /// 从稳定的普通文件读取控制提交；不能把路径存在或数字相等当作能力证明。
    private func controlMatches(_ state: IPCDeviceState, session: UUID, revision: UInt64) -> Bool {
        let fd = open(controlURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var opened = stat()
        var current = stat()
        let limit = 1024 * 1024
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == getuid(), opened.st_size >= 0, opened.st_size <= limit else { return false }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return false }
            if count == 0 { break }
            guard data.count + count <= limit else { return false }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard lstat(controlURL.path, &current) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0"), !text.contains("\r") else { return false }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return false }
        let fields = lines.removeFirst().split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 6, fields[0] == "#SB-CONTROL", fields[1] == "1",
              let controlSession = UUID(uuidString: String(fields[2])), controlSession == session,
              let controlRevision = UInt64(fields[3]), controlRevision > 0, controlRevision == revision,
              let owner = UInt32(fields[4]), owner == getuid(), owner == opened.st_uid,
              let count = Int(fields[5]), count >= 0, count <= 65535, count == lines.count else { return false }
        var records: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
                  records.updateValue(String(parts[0]), forKey: String(parts[1])) == nil else { return false }
        }
        var jsonRecords: [String: String] = [:]
        for device in state.devices {
            guard jsonRecords.updateValue(device.name, forKey: device.uid) == nil else { return false }
        }
        return records == jsonRecords
    }

    func readDeviceState() -> IPCDeviceState? {
        precondition(Thread.isMainThread)
        let before = lockState()
        guard case .held(let liveSession) = before else {
            latestLifecycle = nil
            latestState = nil
            latestControlConsistency = .pending
            acceptedLock = nil
            return nil
        }
        if acceptedLock != before {
            latestLifecycle = nil
            latestState = nil
            latestControlConsistency = .pending
            acceptedLock = before
        }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty,
              let state = try? JSONDecoder().decode(IPCDeviceState.self, from: data) else { return nil }
        guard lockState() == before else {
            latestLifecycle = nil
            latestState = nil
            latestControlConsistency = .pending
            acceptedLock = nil
            return nil
        }
        if let liveSession {
            guard state.protocolVersion == 1, let raw = state.sessionID,
                  UUID(uuidString: raw) == liveSession, let revision = state.revision, revision > 0 else { return nil }
            if let previous = acceptedStates[liveSession], let lastRevision = previous.revision {
                guard revision > lastRevision || (revision == lastRevision && state == previous) else { return nil }
            }
            if let capability = state.controlCommitProtocol {
                guard capability == 1 else {
                    latestLifecycle = nil; latestState = nil; latestControlConsistency = .pending
                    return nil
                }
                capableSessions.insert(liveSession)
                if let commit = state.controlCommitRevision {
                    guard commit > 0, controlMatches(state, session: liveSession, revision: commit),
                          lockState() == before else {
                        latestLifecycle = nil; latestState = nil; latestControlConsistency = .pending
                        return nil
                    }
                    latestControlConsistency = .verified
                } else {
                    // starting、stopping、stopped 或首次提交前：只有生命周期可观察。
                    latestControlConsistency = .uncommitted
                }
            } else {
                guard state.controlCommitRevision == nil, !capableSessions.contains(liveSession) else {
                    latestLifecycle = nil; latestState = nil; latestControlConsistency = .pending
                    return nil
                }
                latestControlConsistency = .legacy
            }
            acceptedStates[liveSession] = state
        } else {
            // 旧 Host 不具备 Session 和 Revision；不能接受不完整的新格式。
            guard state.protocolVersion == nil, state.sessionID == nil, state.revision == nil,
                  state.controlCommitProtocol == nil, state.controlCommitRevision == nil else { return nil }
            latestControlConsistency = .legacy
        }
        latestLifecycle = state.lifecycle
        latestState = state
        return state
    }
}
