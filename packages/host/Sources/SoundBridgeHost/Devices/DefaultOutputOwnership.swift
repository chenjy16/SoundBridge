import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "DefaultOutput")

// MARK: - Ownership

/// Who owns the system default output right now.
///
/// The distinction this type exists to keep is the one the 1.2.0 field test
/// broke: "the proxy this Host manages" and "the device macOS is currently
/// sending audio to" are two different facts. Collapsing them into one variable
/// made a user who switched to the built-in speakers disappear from the Host's
/// view, and the next reconnect put the output back on the proxy they had just
/// left.
enum DefaultOutputOwner: Equatable {
    /// 查询成功，且系统没有默认输出设备。
    case none
    /// 查询失败或无法确定当前设备的归属。
    case unknown
    /// A SoundBridge proxy is the default; `physicalUID` is the device behind it.
    case proxy(physicalUID: String)
    /// A physical device this Host has a proxy for is the default. The ordinary
    /// path to this state is the user picking the HDMI output in System
    /// Settings or in the App; P2 Batch 2 removed the Host's own switch away
    /// from it.
    case managedPhysical(physicalUID: String)
    /// Anything else: built-in speakers, a virtual device, an HDMI output this
    /// Host does not bridge. Nothing here is the Host's to change.
    case unmanaged(uid: String)

    /// The physical UID behind the default device, when there is one.
    var physicalUID: String? {
        switch self {
        case .proxy(let uid), .managedPhysical(let uid): return uid
        case .unmanaged, .none, .unknown: return nil
        }
    }

    /// Whether the default output is currently the proxy of `physicalUID`.
    func isProxy(of physicalUID: String) -> Bool {
        if case .proxy(let uid) = self { return uid == physicalUID }
        return false
    }
}

/// Reconnect 的实际切换时序。依赖由调用者提供，测试可使用隔离的假 HAL。
/// CoreAudio 没有比较并交换接口，因此最后一次读取与设置之间仍有竞态。
// P2 Batch 2 removed `ReconnectTransaction` and `ShutdownOutputTransaction`,
// and with them the last two ways the Host could move the system default
// output on its own: a proxy → physical → proxy bounce during a reconnect, and
// a restore-to-physical during shutdown. A reconnect now re-establishes the
// Host's own route (`ProxyDeviceManager.remapAfterCoreAudioRebuild`) and a
// shutdown tears down without touching the default output.

// MARK: - Policy

/// Rules that read the default output, expressed separately from the code that
/// observes it.
///
/// `Reconnect Audio` is documented as "restore the Host, driver and proxy
/// connections". It is not a request to re-assert ownership of the default
/// output device, and the difference is only visible in the one case that broke:
/// a user who is deliberately listening on something else.
enum DefaultOutputPolicy {

    /// Classify a default-output UID without assuming it is still valid.
    ///
    /// - Parameters:
    ///   - uid: the default device's UID, or `nil` when the query failed.
    ///   - managedPhysicalUIDs: physical devices this Host currently has a
    ///     registered proxy target for.
    static func owner(uid: String?, managedPhysicalUIDs: Set<String>) -> DefaultOutputOwner {
        guard let uid, !uid.isEmpty else { return .unknown }

        let suffix = "-soundbridge"
        if uid.hasSuffix(suffix) {
            let physicalUID = String(uid.dropLast(suffix.count))
            guard managedPhysicalUIDs.contains(physicalUID) else { return .unmanaged(uid: uid) }
            return .proxy(physicalUID: physicalUID)
        }
        if managedPhysicalUIDs.contains(uid) {
            return .managedPhysical(physicalUID: uid)
        }
        return .unmanaged(uid: uid)
    }

    /// 恢复只选择内部路由目标，不改变系统默认输出。
    static func recoveryTarget(current: DefaultOutputOwner, previousUID: String?, availableUIDs: [String]) -> String? {
        let available = Set(availableUIDs)
        if let uid = current.physicalUID, available.contains(uid) { return uid }
        if let uid = previousUID, available.contains(uid) { return uid }
        return availableUIDs.first
    }

    /// 只有受管代理仍为默认输出时，才可向物理设备转发音量或静音。
    static func mayForwardVolume(current: DefaultOutputOwner, physicalUID: String) -> Bool {
        current.isProxy(of: physicalUID)
    }

    // P2 Batch 2 removed `reconnectMayRebindDefault` and `skipReason`. Both
    // existed to decide *whether to write* the default output; nothing in this
    // module writes it any more, so a policy that authorises a write would be
    // dead weight that reads like permission.
}
