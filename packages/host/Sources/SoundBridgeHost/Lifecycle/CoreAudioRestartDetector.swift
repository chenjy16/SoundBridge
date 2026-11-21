import Foundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "CoreAudioRestart")

// MARK: - Observations

/// The routing this Host believed it had, expressed so that "the proxy is gone"
/// can be told apart from "the device was unplugged".
///
/// Both halves matter. `physicalStillPresent && !proxyPresent` is the signature
/// of a HAL rebuild: the device the driver was bridging is still enumerated, but
/// the virtual device that bridged it is not. When the physical device is gone
/// too, the ordinary unplug path already handles it and recovery must not run.
struct ExpectedRouting: Equatable {
    var physicalUID: String
    /// The physical device is still in the enumerated list.
    var physicalStillPresent: Bool
    /// The driver's proxy for that physical device is still in the HAL list.
    var proxyPresent: Bool
}

/// One reading of the HAL object graph, taken when a device notification lands.
///
/// Everything here is queryable without assuming any AudioObjectID from before
/// the notification is still valid — which is the whole problem: after
/// `coreaudiod` restarts, every ID the Host held names nothing.
struct CoreAudioObservation: Equatable {
    /// 查询失败时设备数量不构成有效快照；保留错误码供重建判定。
    var deviceListQueryFailed: Bool
    var deviceListQueryStatus: OSStatus?
    /// How many physical output devices that query returned.
    var physicalDeviceCount: Int
    /// `nil` when the Host was not routing through anything, in which case a
    /// missing proxy says nothing about CoreAudio.
    var routing: ExpectedRouting?

    init(
        deviceListQueryFailed: Bool = false,
        deviceListQueryStatus: OSStatus? = nil,
        physicalDeviceCount: Int,
        routing: ExpectedRouting? = nil
    ) {
        self.deviceListQueryFailed = deviceListQueryFailed
        self.deviceListQueryStatus = deviceListQueryStatus
        self.physicalDeviceCount = physicalDeviceCount
        self.routing = routing
    }
}

/// What the detector concluded from a run of observations.
enum CoreAudioRestartSignal: Equatable {
    /// Nothing unusual: a plug, an unplug, or a default-device change.
    case none
    /// Looks like a rebuild, but one sample cannot tell it apart from an ordinary
    /// unplug. The caller keeps going and observes the next notification.
    case suspected(reason: String)
    /// Enough evidence. The caller must treat every held AudioObjectID as stale.
    case confirmed(reason: String)
}

// MARK: - Detector

/// Distinguishes "CoreAudio rebuilt its object graph" from "a device was plugged".
///
/// The failure this exists for: `killall coreaudiod` invalidates every
/// AudioObjectID the Host holds. Device notifications then arrive for a list that
/// has nothing to do with the one the Host was tracking, listeners are removed
/// from objects that no longer exist (`kAudioHardwareBadObjectError`, observed as
/// OSStatus 560947818 on the real machine), and the proxy device the driver had
/// just published is deactivated while the Host keeps treating its own stale
/// mapping as authoritative.
///
/// The rules are deliberately conservative, because the cost of a false positive
/// is restarting the audio engine while the user is listening:
///
/// - 普通查询失败只安排一次有界重查，不能当作重建或空设备列表；
/// - 系统对象返回 BadObject 时保留证据，连续出现或随后为空时确认重建；
/// - 物理设备仍存在但代理消失时，经连续样本确认；
/// - 单独的设备数降为零只表示可能拔出了最后一台设备。
///
/// The detector holds no CoreAudio state, takes its own history as input, and is
/// therefore exercisable without a running `coreaudiod`.
struct CoreAudioRestartDetector {
    /// Consecutive suspect samples needed before the signal becomes confirmed.
    let confirmAfter: Int

    private(set) var consecutiveSuspects = 0
    private(set) var lastDeviceCount: Int?
    private var suspectKey: String?
    private var invalidSystemObjectEvidence = false

    init(confirmAfter: Int = 2) {
        self.confirmAfter = max(1, confirmAfter)
    }

    /// Feed one observation. Returns the strongest conclusion it supports.
    mutating func observe(_ observation: CoreAudioObservation) -> CoreAudioRestartSignal {
        if observation.deviceListQueryFailed {
            let status = observation.deviceListQueryStatus
            if status == kAudioHardwareBadObjectError {
                invalidSystemObjectEvidence = true
                return suspect(key: "system-object", reason: "HAL system object rejected the device-list query as invalid")
            }
            // 一般错误没有重建证据；不能用错误结果重置最后的有效设备数。
            invalidSystemObjectEvidence = false
            consecutiveSuspects = 0
            suspectKey = nil
            return .suspected(reason: "HAL device-list query failed (OSStatus \(status.map(String.init) ?? "unknown"))")
        }

        let previousCount = lastDeviceCount
        lastDeviceCount = observation.physicalDeviceCount
        if observation.physicalDeviceCount == 0, invalidSystemObjectEvidence {
            invalidSystemObjectEvidence = false
            consecutiveSuspects = 0
            suspectKey = nil
            return .confirmed(reason: "the HAL system object was invalid before the device list became empty")
        }
        invalidSystemObjectEvidence = false

        if let routing = observation.routing,
           routing.physicalStillPresent,
           !routing.proxyPresent,
           observation.physicalDeviceCount > 0 {
            return suspect(key: "proxy:\(routing.physicalUID)",
                           reason: "proxy for \(routing.physicalUID) vanished while the physical device is still enumerated")
        }
        consecutiveSuspects = 0
        suspectKey = nil
        if observation.physicalDeviceCount == 0, let previousCount, previousCount > 0 {
            return .suspected(reason: "device list went from \(previousCount) to 0")
        }
        return .none
    }

    private mutating func suspect(key: String, reason: String) -> CoreAudioRestartSignal {
        if suspectKey != key { consecutiveSuspects = 0; suspectKey = key }
        consecutiveSuspects += 1
        if consecutiveSuspects >= confirmAfter {
            consecutiveSuspects = 0
            suspectKey = nil
            invalidSystemObjectEvidence = false
            logger.error("CoreAudio restart confirmed: \(reason, privacy: .public)")
            return .confirmed(reason: reason)
        }
        return .suspected(reason: reason)
    }

    /// Forget the sample history. Called after a recovery pass so the next
    /// episode starts counting from zero instead of inheriting the previous one.
    mutating func reset() {
        consecutiveSuspects = 0
        lastDeviceCount = nil
        suspectKey = nil
        invalidSystemObjectEvidence = false
    }
}
