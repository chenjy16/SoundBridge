import Darwin
import Foundation
import os.log

// notify_post is available via <notify.h> but not always visible in cross-compilation.
@_silgen_name("notify_post")
private func _notify_post(_ name: UnsafePointer<CChar>) -> UInt32

private let logger = Logger(subsystem: "com.soundbridge.host", category: "DeviceRegistry")

// MARK: - IPC payload

/// One device, as the App sees it.
struct HostDeviceInfo: Codable, Equatable {
    let name: String
    let uid: String
    let isFixedVolume: Bool
}

/// The whole of `device-state.json`.
///
/// Extracted from a function-local type so the wire format has a test: the keys
/// here are a contract with an independently-versioned App, and the one that
/// changed meaning in Phase 6A (`activeDeviceUID`) had no test at all.
struct HostDeviceStatePayload: Codable, Equatable {
    let devices: [HostDeviceInfo]
    /// 兼容旧版：仍表示 Host 管理的物理设备 UID。
    let activeDeviceUID: String?
    /// The proxy target this Host manages. Not the same question as the default
    /// output: a user listening on the built-in speakers still has a proxy.
    let managedProxyUID: String?
    /// The device CoreAudio is actually sending audio to.
    let systemDefaultOutputUID: String?
    let lifecycle: HostLifecycleSnapshot?
    var protocolVersion: Int? = nil
    var sessionID: String? = nil
    var revision: UInt64? = nil
    /// 独立能力标记；旧版 JSON 没有这两个字段。
    var controlCommitProtocol: Int? = nil
    /// nil 表示尚无有效设备提交或正在停止，不表示设备集合一致。
    var controlCommitRevision: UInt64? = nil
}

class DeviceRegistry {
    private let lock = NSRecursiveLock()
    private let controlFilePath: String
    private let deviceStateURL: URL
    private let scheduleStateRetry: (TimeInterval, @escaping () -> Void) -> Void
    private let notify: (String) -> Void
    private var sessionID: UUID?
    private var publishingEnabled = false
    private var stateRetryScheduled = false
    private var stateRetryGeneration: UInt64 = 0
    private var stateRetryDelay: TimeInterval = 1
    private var controlRevision: UInt64 = 0
    private var committedControlRevision: UInt64?
    private var stateRevision: UInt64 = 0
    private var storedDevices: [PhysicalDevice] = []
    private var storedManagedProxyUID: String?
    private var storedSystemDefaultOutputUID: String?
    private var storedLifecycle: HostLifecycleSnapshot?

    init(
        controlFilePath: String = SoundBridgeConfig.controlFilePath,
        deviceStateURL: URL = PathManager.appSupportDir.appendingPathComponent("device-state.json"),
        scheduleStateRetry: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        notify: @escaping (String) -> Void = { name in _ = _notify_post(name) }
    ) {
        self.controlFilePath = controlFilePath
        self.deviceStateURL = deviceStateURL
        self.scheduleStateRetry = scheduleStateRetry
        self.notify = notify
    }

    /// 必须在持锁后、任何状态发布前调用。
    func beginSession(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        precondition(sessionID == nil, "不能在同一个 registry 中重用或替换会话")
        sessionID = id
        publishingEnabled = true
    }

    /// 在释放实例锁前禁用发布，并使已经排队的重试失效。
    func endSession() {
        lock.lock()
        defer { lock.unlock() }
        publishingEnabled = false
        stateRetryScheduled = false
        stateRetryGeneration &+= 1
    }

    private(set) var devices: [PhysicalDevice] {
        get { lock.lock(); defer { lock.unlock() }; return storedDevices }
        set { lock.lock(); defer { lock.unlock() }; storedDevices = newValue }
    }

    /// The physical device whose proxy this Host is routing through.
    ///
    /// This is what `activeProxyUID` meant in 1.1: the Host's own bookkeeping,
    /// not the system's. A user who switches the output to the built-in speakers
    /// has not stopped this Host from managing the HDMI proxy.
    var managedProxyUID: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedManagedProxyUID }
        set { lock.lock(); defer { lock.unlock() }; storedManagedProxyUID = newValue }
    }

    /// The device macOS is sending audio to right now, as CoreAudio reports it.
    ///
    /// Kept apart from `managedProxyUID` because the two disagree exactly when
    /// the user is listening somewhere else — the case the 1.2.0 reconnect got
    /// wrong by treating its own routing state as the system's.
    var systemDefaultOutputUID: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedSystemDefaultOutputUID }
        set { lock.lock(); defer { lock.unlock() }; storedSystemDefaultOutputUID = newValue }
    }

    /// 旧字段保留受管物理设备的含义，系统默认输出使用独立字段。
    var activeDeviceUID: String? {
        get { managedProxyUID }
        set { managedProxyUID = newValue }
    }

    /// Latest lifecycle snapshot, mirrored into `device-state.json`.
    ///
    /// The App needs to tell "Host running" apart from "Host running and audio
    /// works". Both used to look identical from the outside because the only
    /// signal was the process existing.
    var lifecycle: HostLifecycleSnapshot? {
        get { lock.lock(); defer { lock.unlock() }; return storedLifecycle }
        set { lock.lock(); defer { lock.unlock() }; storedLifecycle = newValue }
    }

    /// 控制文件未发布时保留上一份内存快照，调用方可以安排重试。
    /// 状态文件是独立通道，失败不能回滚已经发布的控制文件。
    @discardableResult
    func update(_ newDevices: [PhysicalDevice]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let previousDevices = storedDevices
        storedDevices = newDevices
        guard writeControlFile() else {
            storedDevices = previousDevices
            return false
        }
        writeDeviceStateFile()
        return true
    }

    func find(uid: String) -> PhysicalDevice? {
        return devices.first { $0.uid == uid }
    }

    func findAdded(comparing old: [PhysicalDevice]) -> [PhysicalDevice] {
        return devices.filter { new in
            !old.contains { $0.uid == new.uid }
        }
    }

    func findRemoved(comparing old: [PhysicalDevice]) -> [PhysicalDevice] {
        return old.filter { old in
            !devices.contains { $0.uid == old.uid }
        }
    }

    @discardableResult
    func writeControlFile() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard publishingEnabled, let sessionID, controlRevision < UInt64.max else {
            logger.error("Cannot publish control file without a valid session and revision")
            return false
        }
        guard storedDevices.allSatisfy({
            !$0.name.isEmpty && !$0.uid.isEmpty &&
            !$0.name.contains("|") && !$0.name.contains("\n") && !$0.name.contains("\r") &&
            !$0.uid.contains("|") && !$0.uid.contains("\n") && !$0.uid.contains("\r")
        }), Set(storedDevices.map({ $0.uid })).count == storedDevices.count else {
            logger.error("Cannot publish invalid or duplicate device records")
            return false
        }
        controlRevision += 1
        // 旧 Driver 忽略没有竖线的首行，仍按原格式读取设备记录。
        let header = "#SB-CONTROL 1 \(sessionID.uuidString) \(controlRevision) \(getuid()) \(storedDevices.count)"
        let content = ([header] + storedDevices.map { "\($0.name)|\($0.uid)" }).joined(separator: "\n")
        guard AtomicFileWriter.replace(at: controlFilePath, with: Data(content.utf8)) else { return false }
        committedControlRevision = controlRevision
        notify("com.soundbridge.devices-changed")
        return true
    }

    /// Write device-state.json for the menu bar App IPC.
    /// Contains only device list and active device — no volume/mute state.
    func writeDeviceStateFile() {
        lock.lock()
        defer { lock.unlock() }
        guard publishingEnabled, let sessionID, stateRevision < UInt64.max else {
            logger.error("Cannot publish device state without a valid session and revision")
            return
        }
        stateRevision += 1
        let outcome = storedLifecycle?.outcome
        let observableCommit: UInt64? = (outcome == .starting || outcome == .stopping || outcome == .stopped)
            ? nil : committedControlRevision
        let state = HostDeviceStatePayload(
            devices: devices.map {
                HostDeviceInfo(name: $0.name, uid: $0.uid, isFixedVolume: $0.isFixedVolume)
            },
            activeDeviceUID: managedProxyUID,
            managedProxyUID: managedProxyUID,
            systemDefaultOutputUID: systemDefaultOutputUID,
            lifecycle: lifecycle,
            protocolVersion: 1,
            sessionID: sessionID.uuidString,
            revision: stateRevision,
            controlCommitProtocol: 1,
            controlCommitRevision: observableCommit
        )

        do {
            let data = try JSONEncoder().encode(state)
            guard AtomicFileWriter.replace(at: deviceStateURL.path, with: data) else {
                scheduleDeviceStateRetry()
                return
            }
            stateRetryScheduled = false
            stateRetryGeneration &+= 1
            stateRetryDelay = 1
            notify("com.soundbridge.device-state-changed")
            logger.info("Wrote device-state.json (\(self.devices.count) devices)")
        } catch {
            logger.error("Failed to encode device-state.json: \(error.localizedDescription)")
            scheduleDeviceStateRetry()
        }
    }

    /// 失败只保留一次待执行重试；每次重试读取最新内存状态，退避上限 30 秒。
    /// 调度器必须异步执行，以免在持锁的发布调用中递归重试。
    private func scheduleDeviceStateRetry() {
        guard publishingEnabled, !stateRetryScheduled else { return }
        stateRetryScheduled = true
        stateRetryGeneration &+= 1
        let generation = stateRetryGeneration
        let delay = stateRetryDelay
        stateRetryDelay = min(stateRetryDelay * 2, 30)
        scheduleStateRetry(delay) { [weak self] in
            self?.retryDeviceState(generation: generation)
        }
    }

    private func retryDeviceState(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard publishingEnabled, stateRetryScheduled, generation == stateRetryGeneration else { return }
        stateRetryScheduled = false
        writeDeviceStateFile()
    }
}
