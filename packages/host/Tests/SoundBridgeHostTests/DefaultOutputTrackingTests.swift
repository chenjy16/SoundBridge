import XCTest
@testable import SoundBridgeHost

// MARK: - Which default output is whose
//
// Phase 6A, Bug #2. In 1.2.0 one property carried both facts:
//
//   `activeProxyUID` — what the *Host* was managing — was written into
//   `registry.activeDeviceUID`, which the App reads as "the default output".
//
// So a user who switched to the Mac mini speakers still looked, from the Host's
// point of view, like someone routed through the HDMI proxy; the next Reconnect
// dutifully put the output back on the proxy they had just left.
//
// These tests pin the bookkeeping that separates the two facts. P2 Batch 2 went
// further and removed the last code that could act on the confusion: no Host
// path writes the default output any more, on a reconnect or anywhere else. The
// write-count evidence lives in `DefaultOutputGovernanceTests`; what is left
// here is the policy and the wire format.

final class DefaultOutputTrackingTests: XCTestCase {

    private let hdmiUID = "AppleUSBAudioEngine:LG Electronics:ULTRAGEAR+:1"
    private var hdmiProxyUID: String { hdmiUID + "-soundbridge" }

    // MARK: - Owner classification

    func testAProxyUIDIsClassifiedAsAProxyOfItsPhysicalDevice() {
        let owner = DefaultOutputPolicy.owner(uid: hdmiProxyUID, managedPhysicalUIDs: [hdmiUID])
        XCTAssertEqual(owner, .proxy(physicalUID: hdmiUID))
        XCTAssertEqual(owner.physicalUID, hdmiUID)
        XCTAssertTrue(owner.isProxy(of: hdmiUID))
    }

    func testAManagedPhysicalUIDIsClassifiedAsManagedPhysical() {
        let owner = DefaultOutputPolicy.owner(uid: hdmiUID, managedPhysicalUIDs: [hdmiUID])
        XCTAssertEqual(owner, .managedPhysical(physicalUID: hdmiUID))
        XCTAssertFalse(owner.isProxy(of: hdmiUID))
    }

    func testBuiltInSpeakersAreUnmanaged() {
        let owner = DefaultOutputPolicy.owner(
            uid: "BuiltInSpeakerDevice",
            managedPhysicalUIDs: [hdmiUID]
        )
        XCTAssertEqual(owner, .unmanaged(uid: "BuiltInSpeakerDevice"))
        XCTAssertNil(owner.physicalUID)
    }

    func testAnUnavailableUIDIsUnknown() {
        XCTAssertEqual(DefaultOutputPolicy.owner(uid: nil, managedPhysicalUIDs: [hdmiUID]), .unknown)
        XCTAssertEqual(DefaultOutputPolicy.owner(uid: "", managedPhysicalUIDs: [hdmiUID]), .unknown)
    }

    func testAnotherProxyIsNotManaged() {
        let uid = "another-device-soundbridge"
        XCTAssertEqual(DefaultOutputPolicy.owner(uid: uid, managedPhysicalUIDs: [hdmiUID]), .unmanaged(uid: uid))
    }

    func testRecoverySelectsAvailableTargetWithoutTakingDefaultOwnership() {
        let other = "new-hdmi"
        XCTAssertEqual(DefaultOutputPolicy.recoveryTarget(current: .unmanaged(uid: "speaker"),
                       previousUID: hdmiUID, availableUIDs: [other]), other)
        XCTAssertEqual(DefaultOutputPolicy.recoveryTarget(current: .unknown,
                       previousUID: hdmiUID, availableUIDs: [other, hdmiUID]), hdmiUID)
        XCTAssertEqual(DefaultOutputPolicy.recoveryTarget(current: .proxy(physicalUID: other),
                       previousUID: hdmiUID, availableUIDs: [hdmiUID, other]), other)
        XCTAssertNil(DefaultOutputPolicy.recoveryTarget(current: .none,
                     previousUID: hdmiUID, availableUIDs: []))
    }

    func testVolumeForwardingRequiresCurrentMatchingProxy() {
        let owners: [DefaultOutputOwner] = [
            .unknown, .none, .unmanaged(uid: "speaker"), .managedPhysical(physicalUID: hdmiUID),
            .proxy(physicalUID: "other")
        ]
        for owner in owners {
            XCTAssertFalse(DefaultOutputPolicy.mayForwardVolume(current: owner, physicalUID: hdmiUID))
        }
        XCTAssertTrue(DefaultOutputPolicy.mayForwardVolume(current: .proxy(physicalUID: hdmiUID),
                      physicalUID: hdmiUID))
    }

    // MARK: - A user switch is visible without being undone
    //
    //  current default          what happens
    //  -----------------------  ----------------------------------------
    //  SoundBridge proxy        stays; the Host forwards volume through it
    //  Mac mini speakers        stays; nothing in the Host reverts it
    //  physical HDMI            stays; the Host only stops forwarding
    //  another device           stays
    //  user picks the proxy     allowed — that is the explicit action
    //
    // P2 Batch 2 deleted `reconnectMayRebindDefault` and `skipReason`: there is
    // no longer a reconnect path that may rebind the default output, so the
    // policy that governed it had nothing left to govern.

    func testAUserSwitchAwayIsVisibleWithoutBeingUndone() {
        // Model the sequence: proxy is default → user picks the speakers. The
        // Host records both facts and has no operation left that could revert
        // the second one.
        let before = DefaultOutputPolicy.owner(uid: hdmiProxyUID, managedPhysicalUIDs: [hdmiUID])
        let after = DefaultOutputPolicy.owner(uid: "BuiltInSpeakerDevice", managedPhysicalUIDs: [hdmiUID])

        XCTAssertEqual(before.physicalUID, hdmiUID)
        XCTAssertNil(after.physicalUID)
        XCTAssertNotEqual(before, after)
        XCTAssertFalse(DefaultOutputPolicy.mayForwardVolume(current: after, physicalUID: hdmiUID),
                       "forwarding stops when the audio leaves the proxy")
    }

    func testTheProxyRemainsAClassifiableTargetAfterTheUserLeavesIt() {
        // Going *to* the proxy is the user's own action, so nothing in the policy
        // may read as "the proxy is not selectable any more".
        let owner = DefaultOutputPolicy.owner(uid: hdmiProxyUID, managedPhysicalUIDs: [hdmiUID])
        XCTAssertEqual(owner, .proxy(physicalUID: hdmiUID))
        XCTAssertTrue(DefaultOutputPolicy.mayForwardVolume(current: owner, physicalUID: hdmiUID))
    }

    // MARK: - Registry keeps two facts, not one

    func testSwitchingTheDefaultOutputDoesNotEmptyTheManagedProxy() {
        // This is the exact 1.2.0 bug: writing the system default used to clear
        // the Host's own routing state, so the Host forgot which proxy it owned.
        let registry = DeviceRegistry()
        registry.managedProxyUID = hdmiUID
        registry.systemDefaultOutputUID = "BuiltInSpeakerDevice"

        XCTAssertEqual(registry.managedProxyUID, hdmiUID)
        XCTAssertEqual(registry.systemDefaultOutputUID, "BuiltInSpeakerDevice")
    }

    func testTheDeprecatedAliasPreservesManagedDeviceSemantics() {
        let registry = DeviceRegistry()
        registry.systemDefaultOutputUID = "BuiltInSpeakerDevice"
        registry.activeDeviceUID = hdmiUID

        XCTAssertEqual(registry.systemDefaultOutputUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(registry.managedProxyUID, hdmiUID)
        XCTAssertEqual(registry.activeDeviceUID, hdmiUID)
    }

    // MARK: - The wire format says the same thing

    private func payload(
        managedProxyUID: String?,
        systemDefaultOutputUID: String?
    ) -> HostDeviceStatePayload {
        HostDeviceStatePayload(
            devices: [HostDeviceInfo(name: "ULTRAGEAR+", uid: hdmiUID, isFixedVolume: true)],
            activeDeviceUID: managedProxyUID,
            managedProxyUID: managedProxyUID,
            systemDefaultOutputUID: systemDefaultOutputUID,
            lifecycle: nil
        )
    }

    func testPayloadSeparatesManagedProxyFromSystemDefault() throws {
        let data = try JSONEncoder().encode(
            payload(managedProxyUID: hdmiUID, systemDefaultOutputUID: "BuiltInSpeakerDevice")
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["managedProxyUID"] as? String, hdmiUID)
        XCTAssertEqual(json["systemDefaultOutputUID"] as? String, "BuiltInSpeakerDevice")
        XCTAssertEqual(json["activeDeviceUID"] as? String, hdmiUID,
                       "the legacy key must retain the managed physical UID")
    }

    func testAnOlderAppReadingThisPayloadRetainsLegacySemantics() throws {
        // 旧版只读取 activeDeviceUID，该字段仍是受管物理设备 UID。
        struct LegacyState: Decodable {
            let activeDeviceUID: String?
        }

        let data = try JSONEncoder().encode(
            payload(managedProxyUID: hdmiUID, systemDefaultOutputUID: "BuiltInSpeakerDevice")
        )
        let legacy = try JSONDecoder().decode(LegacyState.self, from: data)

        XCTAssertEqual(legacy.activeDeviceUID, hdmiUID)
        XCTAssertNotEqual(legacy.activeDeviceUID, "BuiltInSpeakerDevice")
    }

    // MARK: - 写入次数证据
    //
    // 原此处的 `ReconnectTransaction` / `ShutdownOutputTransaction` 测试与其
    // 假 HAL 已随 P2 Batch 2 删除：两个事务本身就是自动写入默认输出的实现。
    // 取代它们的证据在 `DefaultOutputGovernanceTests` 中——用生产对象 +
    // `RecordingDefaultOutputHAL` 跑完整生命周期，断言写入次数为 0。

    func testPayloadLeavesBothUIDsAbsentWhenNeitherIsKnown() throws {
        let data = try JSONEncoder().encode(payload(managedProxyUID: nil, systemDefaultOutputUID: nil))
        let decoded = try JSONDecoder().decode(HostDeviceStatePayload.self, from: data)

        XCTAssertNil(decoded.managedProxyUID)
        XCTAssertNil(decoded.systemDefaultOutputUID)
        XCTAssertNil(decoded.activeDeviceUID)
        XCTAssertEqual(decoded.devices.count, 1)
    }
}
