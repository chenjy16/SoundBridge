import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "CoreAudioRecovery")

// MARK: - Retry schedule

/// Bounded, spaced-out attempts for one recovery episode.
///
/// A tight retry loop is worse than none: each attempt re-registers HAL
/// listeners and rewrites the control file, so a Host that spins makes the
/// driver create and remove proxy devices continuously. The first delay is zero
/// because the usual cause — a rebuild that has already finished — is fixed by
/// the first attempt; the later delays give a HAL that is still coming up time
/// to answer.
struct RecoveryBackoff: Equatable {
    private let delays: [TimeInterval]
    private(set) var attemptsMade = 0

    init(delays: [TimeInterval] = [0, 1.0, 2.0, 4.0]) {
        self.delays = delays.isEmpty ? [0] : delays
    }

    /// How many attempts this schedule allows.
    var plannedAttempts: Int { delays.count }

    /// Consume the next slot. Returns the delay to wait, or `nil` when spent.
    mutating func nextDelay() -> TimeInterval? {
        guard attemptsMade < delays.count else { return nil }
        let delay = delays[attemptsMade]
        attemptsMade += 1
        return delay
    }

    mutating func reset() {
        attemptsMade = 0
    }
}

/// What one attempt achieved.
enum RecoveryAttemptResult: Equatable {
    /// The audio path is back. `detail` goes into the lifecycle snapshot.
    case recovered(detail: String)
    /// 暂时没有可管理的物理设备；继续监听热插拔。
    case waitingForDevice(reason: String)
    /// Worth trying again after the next delay.
    case retryable(reason: String)
    /// More attempts cannot help. Stop and report.
    case terminal(reason: String)
}

/// How an episode ended.
enum CoreAudioRecoveryOutcome: Equatable {
    case recovered(attempts: Int, detail: String)
    case waitingForDevice(attempts: Int, reason: String)
    case failed(attempts: Int, reason: String)
    case exhausted(attempts: Int, lastReason: String)

    var isRecovered: Bool {
        if case .recovered = self { return true }
        return false
    }

    /// One line for the lifecycle `detail` field.
    var diagnostic: String {
        switch self {
        case .recovered(let attempts, let detail):
            return "recovered after \(attempts) attempt(s): \(detail)"
        case .waitingForDevice(let attempts, let reason):
            return "waiting for a device after \(attempts) attempt(s): \(reason)"
        case .failed(let attempts, let reason):
            return "recovery failed after \(attempts) attempt(s): \(reason)"
        case .exhausted(let attempts, let lastReason):
            return "recovery gave up after \(attempts) attempt(s); last reason: \(lastReason)"
        }
    }
}

// MARK: - Episode

/// One bounded recovery episode, with the real work injected.
///
/// The orchestration is the part worth testing: how many attempts run, whether a
/// terminal result stops the loop, and whether success is reported once. The
/// CoreAudio calls themselves live in `main`, which cannot be exercised without a
/// running `coreaudiod`; this type never touches it.
struct CoreAudioRecoveryEpisode {
    var backoff: RecoveryBackoff
    /// Injected so tests run in microseconds. Defaults to a real sleep.
    var sleep: (TimeInterval) -> Void
    var now: () -> TimeInterval
    var episodeTimeout: TimeInterval
    var attemptTimeout: TimeInterval
    var shouldContinue: () -> Bool
    /// 仅在预算检查通过后提交收敛；失败时使用剩余重试次数重新读取。
    var commitAttempt: () -> Bool
    /// 尝试未被提交时回收其资源；停止后的清理由 Shutdown 负责。
    var discardAttempt: () -> Void
    /// 底层同步调用不可强制取消；每个后续步骤必须调用传入的预算检查。
    var attempt: (Int, @escaping () -> Bool) -> RecoveryAttemptResult

    init(
        backoff: RecoveryBackoff = RecoveryBackoff(),
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        episodeTimeout: TimeInterval = 30,
        attemptTimeout: TimeInterval = 5,
        shouldContinue: @escaping () -> Bool = { true },
        commitAttempt: @escaping () -> Bool = { true },
        discardAttempt: @escaping () -> Void = {},
        attempt: @escaping (Int) -> RecoveryAttemptResult
    ) {
        self.init(backoff: backoff, sleep: sleep, now: now, episodeTimeout: episodeTimeout,
                  attemptTimeout: attemptTimeout, shouldContinue: shouldContinue,
                  commitAttempt: commitAttempt, discardAttempt: discardAttempt,
                  attemptWithBudget: { number, _ in attempt(number) })
    }

    init(
        backoff: RecoveryBackoff = RecoveryBackoff(),
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        episodeTimeout: TimeInterval = 30,
        attemptTimeout: TimeInterval = 5,
        shouldContinue: @escaping () -> Bool = { true },
        commitAttempt: @escaping () -> Bool = { true },
        discardAttempt: @escaping () -> Void = {},
        attemptWithBudget: @escaping (Int, @escaping () -> Bool) -> RecoveryAttemptResult
    ) {
        self.backoff = backoff
        self.sleep = sleep
        self.now = now
        self.episodeTimeout = max(episodeTimeout, 0)
        self.attemptTimeout = max(attemptTimeout, 0)
        self.shouldContinue = shouldContinue
        self.commitAttempt = commitAttempt
        self.discardAttempt = discardAttempt
        self.attempt = attemptWithBudget
    }

    /// 预算限制后续步骤；无法中断正在执行的同步 HAL 调用。
    func run() -> CoreAudioRecoveryOutcome {
        var schedule = backoff
        var lastReason = "no attempt was made"
        var attempts = 0
        let episodeDeadline = now() + episodeTimeout

        while let delay = schedule.nextDelay() {
            guard shouldContinue() else { return .failed(attempts: attempts, reason: "recovery cancelled") }
            let remaining = episodeDeadline - now()
            guard remaining > 0 else { return .exhausted(attempts: attempts, lastReason: "episode deadline exceeded") }
            if delay > 0 { sleep(min(delay, remaining)) }
            guard shouldContinue() else { return .failed(attempts: attempts, reason: "recovery cancelled") }
            guard now() < episodeDeadline else {
                return .exhausted(attempts: attempts, lastReason: "episode deadline exceeded")
            }

            attempts += 1
            let deadline = min(episodeDeadline, now() + attemptTimeout)
            let canProceed = { self.shouldContinue() && self.now() < deadline }
            let result = attempt(attempts, canProceed)
            guard shouldContinue() else { return .failed(attempts: attempts, reason: "recovery cancelled") }
            guard now() < episodeDeadline else {
                discardAttempt()
                return .exhausted(attempts: attempts, lastReason: "episode deadline exceeded")
            }
            if now() >= deadline {
                discardAttempt()
                lastReason = "attempt deadline exceeded"
                continue
            }
            switch result {
            case .recovered(let detail):
                guard commitAttempt() else {
                    if shouldContinue() { discardAttempt() }
                    lastReason = "device or default output changed during reconciliation"
                    continue
                }
                return .recovered(attempts: attempts, detail: detail)
            case .waitingForDevice(let reason):
                guard commitAttempt() else {
                    if shouldContinue() { discardAttempt() }
                    lastReason = "device or default output changed during reconciliation"
                    continue
                }
                return .waitingForDevice(attempts: attempts, reason: reason)
            case .terminal(let reason):
                discardAttempt()
                return .failed(attempts: attempts, reason: reason)
            case .retryable(let reason):
                discardAttempt()
                lastReason = reason
            }
        }

        logger.error(
            "CoreAudio recovery exhausted \(attempts) attempt(s); last reason: \(lastReason, privacy: .public)"
        )
        return .exhausted(attempts: attempts, lastReason: lastReason)
    }
}

// MARK: - 带生命周期检查的引擎启动

/// 同步调用不可强制中断；成功或失败返回后均重新检查生命周期。
struct GuardedEngineStart {
    enum Result: Equatable { case started, cancelled }

    static func run(
        canProceed: () -> Bool,
        setup: () throws -> Void,
        start: () throws -> Void
    ) throws -> Result {
        guard canProceed() else { return .cancelled }
        do {
            try setup()
            guard canProceed() else { return .cancelled }
            try start()
        } catch {
            guard canProceed() else { return .cancelled }
            throw error
        }
        guard canProceed() else { return .cancelled }
        return .started
    }
}

// MARK: - 生命周期代际

/// 使恢复或停止前排队的普通设备操作失效。实际设备修改仍须串行调度。
final class HostLifecycleGate {
    private enum Phase { case normal, recovering, stopping }
    private let lock = NSLock()
    private var phase: Phase = .normal
    private var generation: UInt64 = 0
    private var recoveryEvents: UInt64 = 0

    func normalToken() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return phase == .normal ? generation : nil
    }

    func permitsNormal(_ token: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return phase == .normal && (token == nil || token == generation)
    }

    func beginRecovery() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .normal else { return false }
        generation &+= 1
        recoveryEvents &+= 1
        phase = .recovering
        return true
    }

    /// HAL 回调在线程切换前原子地记录事件或获取普通代际。
    func captureEventToken() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        switch phase {
        case .normal: return generation
        case .recovering: recoveryEvents &+= 1; return nil
        case .stopping: return nil
        }
    }

    func recordRecoveryEvent() {
        lock.lock(); defer { lock.unlock() }
        if phase == .recovering { recoveryEvents &+= 1 }
    }

    func recoverySnapshot() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return recoveryEvents
    }

    /// 检查事件并开放普通操作必须共用同一把锁。
    func finishRecovery(ifUnchanged observed: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .recovering, recoveryEvents == observed else { return false }
        generation &+= 1
        phase = .normal
        return true
    }

    /// 失败后的有界观察性收敛使用此出口；不会重新开放 stopping。
    func endRecovery() {
        lock.lock(); defer { lock.unlock() }
        guard phase == .recovering else { return }
        generation &+= 1
        phase = .normal
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        phase = .stopping
    }
}

// MARK: - Gate

/// Single-flight guard for one rebuild episode, plus the latch shutdown sets.
///
/// Distinct from `DegradedRecoveryGate` on purpose: they gate different
/// transitions (proxy-never-appeared versus object-graph-replaced) and only one
/// of them may be in flight at a time, so sharing a flag would let a recovery
/// pass be mistaken for a degraded retry.
struct CoreAudioRecoveryGate {
    private(set) var isRecovering = false
    private(set) var episodes = 0
    /// Set by shutdown. Once set, no new episode may begin: recovery rewrites the
    /// control file and re-registers listeners, both of which a half-torn-down
    /// Host must not do.
    private(set) var isTerminated = false

    /// Refuse all further episodes. Idempotent.
    mutating func terminate() {
        isTerminated = true
    }

    /// Ask for permission to run one episode.
    mutating func begin() -> Bool {
        guard !isTerminated else {
            logger.info("Recovery requested after shutdown began; ignoring")
            return false
        }
        guard !isRecovering else {
            logger.info("Recovery already in flight; ignoring duplicate trigger")
            return false
        }
        isRecovering = true
        episodes += 1
        return true
    }

    /// Release the guard. Must run on every exit path, successful or not.
    mutating func finish() {
        isRecovering = false
    }
}
