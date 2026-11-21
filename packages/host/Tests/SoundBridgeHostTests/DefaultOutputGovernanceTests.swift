import XCTest
import CoreAudio
@testable import SoundBridgeHost

// MARK: - The invariant
//
// SoundBridge must never change the macOS default output device
// automatically. Only an explicit user action may do that, and in 1.2.0 that
// action lives in the App (`VolumeController` → `DefaultOutputSwitch`), not in
// the Host.
//
// These tests are the evidence. They drive the *production* lifecycle
// coordinators — `ProxyDeviceManager`, `DeviceMonitor`, `ShutdownSequence` — and
// count every write the Host asks the HAL to perform. The HAL seam is the same
// one production uses (`ProxyDeviceManager(hal:)`), not a stand-in that happens
// to observe nothing because nobody wired it up; `testTheRecordingSeamRecordsAWrite`
// is the meta-test that keeps that claim honest.
//
// What these tests do NOT prove: that the real CoreAudio implementation behaves
// this way on a live system. That needs the P3 pass described in
// `docs/P2-Batch-2-Default-Output-Governance-Report.md`.

/// A `DefaultOutputHAL` that answers from a dictionary and records every write.
final class RecordingDefaultOutputHAL: DefaultOutputHAL {
    /// Every `setDefaultOutput(_:)` request, in order. The whole point of the
    /// suite is that this stays empty.
    private(set) var writes: [AudioDeviceID] = []
    private(set) var defaultOutputReads = 0
    /// What the system would answer. Tests move it directly to model a user
    /// changing the output in System Settings.
    var defaultOutputID: AudioDeviceID
    /// Scripted result for the next write, so the explicit-action test can make
    /// CoreAudio fail without a live system.
    var writeSucceeds = true

    private var uids: [AudioDeviceID: String] = [:]
    private var names: [AudioDeviceID: String] = [:]

    init(defaultOutputID: AudioDeviceID) {
        self.defaultOutputID = defaultOutputID
    }

    func add(id: AudioDeviceID, uid: String, name: String? = nil) {
        uids[id] = uid
        names[id] = name ?? uid
    }

    func remove(id: AudioDeviceID) {
        uids[id] = nil
        names[id] = nil
    }

    func defaultOutputDevice() -> AudioDeviceID? {
        defaultOutputReads += 1
        return defaultOutputID
    }

    func deviceUID(_ deviceID: AudioDeviceID) -> String? { uids[deviceID] }
    func deviceName(_ deviceID: AudioDeviceID) -> String? { names[deviceID] }

    func deviceID(forUID uid: String) -> AudioDeviceID? {
        uids.first(where: { $0.value == uid })?.key
    }

    @discardableResult
    func setDefaultOutput(_ deviceID: AudioDeviceID) -> Bool {
        writes.append(deviceID)
        guard writeSucceeds else { return false }
        defaultOutputID = deviceID
        return true
    }
}

// MARK: - Lifecycle matrix

final class DefaultOutputGovernanceTests: XCTestCase {

    private let physicalUID = "AppleUSBAudioEngine:LG Electronics:ULTRAGEAR+:1"
    private var proxyUID: String { physicalUID + "-soundbridge" }
    private let displayPortUID = "AppleUSBAudioEngine:Dell:U2720Q:2"

    private let physicalID: AudioDeviceID = 41
    private let proxyID: AudioDeviceID = 90
    private let speakersID: AudioDeviceID = 99
    private let displayPortID: AudioDeviceID = 42

    private final class FakeDiscovery: DeviceDiscovery {
        var devices: [PhysicalDevice] = []

        override func enumeratePhysicalDevicesWithStatus() -> PhysicalDeviceEnumeration {
            PhysicalDeviceEnumeration(devices: devices, queryFailed: false,
                                      totalAudioDeviceCount: devices.count)
        }
    }

    private var sandbox: URL!
    private var registry: DeviceRegistry!
    private var memory: SharedMemoryManager!
    private var hal: RecordingDefaultOutputHAL!
    private var proxyManager: ProxyDeviceManager!
    private var engine: AudioEngine!
    private var discovery: FakeDiscovery!
    private var monitor: DeviceMonitor!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeGovernance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let session = UUID()
        registry = DeviceRegistry(
            controlFilePath: sandbox.appendingPathComponent("control").path,
            deviceStateURL: sandbox.appendingPathComponent("state.json"),
            notify: { _ in }
        )
        registry.beginSession(session)

        let root = sandbox!
        memory = SharedMemoryManager(
            sessionID: session,
            pathForUID: { root.appendingPathComponent("mapping-\($0)").path }
        )
        let persistence = VolumePersistence(fileURL: sandbox.appendingPathComponent("volume.json"))

        // The default output is the built-in speakers: a user who never asked
        // SoundBridge to take over. Every automatic path must leave it there.
        hal = RecordingDefaultOutputHAL(defaultOutputID: speakersID)
        hal.add(id: speakersID, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")

        proxyManager = ProxyDeviceManager(registry: registry, volumePersistence: persistence, hal: hal)
        // P2 Batch 4: the render path no longer asks the proxy manager for the
        // active UID; the routing decision is pushed into the mapping manager.
        proxyManager.onManagedProxyChanged = { [weak self] uid in self?.memory?.setPreferredRenderUID(uid) }
        let renderer = AudioRenderer(memoryManager: memory)
        engine = AudioEngine(renderer: renderer, registry: registry)

        discovery = FakeDiscovery()
        monitor = DeviceMonitor(registry: registry, proxyManager: proxyManager, memoryManager: memory,
                                discovery: discovery, audioEngine: engine)
    }

    override func tearDownWithError() throws {
        monitor?.stop()
        memory?.cleanup()
        monitor = nil
        memory = nil
        engine = nil
        proxyManager = nil
        hal = nil
        registry = nil
        try? FileManager.default.removeItem(at: sandbox)
        sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func device(_ uid: String, id: AudioDeviceID, transport: UInt32 = 0) -> PhysicalDevice {
        PhysicalDevice(id: id, name: uid, uid: uid, manufacturer: "Fake", transportType: transport,
                       isOutput: true, validationPassed: true, validationNote: nil, isFixedVolume: true)
    }

    /// Publish the device list the driver would have published, and register the
    /// proxy the driver creates next to it.
    private func publish(_ devices: [PhysicalDevice], withProxies: Bool = true) {
        registry.update(devices)
        discovery.devices = devices
        if withProxies {
            for device in devices where hal.deviceID(forUID: device.uid + "-soundbridge") == nil {
                hal.add(id: proxyID, uid: device.uid + "-soundbridge", name: device.uid + " (SoundBridge)")
            }
        }
    }

    private func hdmi() -> PhysicalDevice { device(physicalUID, id: physicalID) }

    // MARK: - The recording seam is not a no-op

    func testTheRecordingSeamRecordsAWrite() {
        // Without this, every "no writes" assertion below could pass because the
        // probe was never wired to anything.
        XCTAssertTrue(hal.setDefaultOutput(proxyID))
        XCTAssertEqual(hal.writes, [proxyID])
        XCTAssertEqual(hal.defaultOutputID, proxyID)

        hal.writeSucceeds = false
        XCTAssertFalse(hal.setDefaultOutput(speakersID))
        XCTAssertEqual(hal.writes, [proxyID, speakersID])
        XCTAssertEqual(hal.defaultOutputID, proxyID, "a failed write leaves the default output alone")
    }

    // MARK: - Host startup

    func testHostStartupDoesNotChangeTheDefaultOutput() {
        let hdmiDevice = hdmi()
        publish([hdmiDevice])

        let routing = proxyManager.resolveProxyRouting(forPhysicalUID: hdmiDevice.uid)

        XCTAssertEqual(routing, .routed(proxyDeviceID: proxyID, defaultOutputIsProxy: false))
        XCTAssertTrue(routing.isRoutable, "routing through the proxy is a ready state even when the user listens elsewhere")
        XCTAssertEqual(hal.writes, [], "startup must not make the proxy the default output")
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    func testStartupRecordsWhereTheAudioIsGoingWithoutChangingIt() {
        publish([hdmi()])

        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        XCTAssertEqual(registry.systemDefaultOutputUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(hal.defaultOutputID, speakersID)
        XCTAssertEqual(hal.writes, [])
        XCTAssertGreaterThan(hal.defaultOutputReads, 0, "the Host reads the default output; reading is not changing")
    }

    func testStartupReportsWhenTheProxyIsAlreadyTheDefault() {
        // The user picked SoundBridge earlier. That choice survives a restart:
        // the Host notices it and still does not write.
        hal.defaultOutputID = proxyID
        publish([hdmi()])

        let routing = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        XCTAssertEqual(routing, .routed(proxyDeviceID: proxyID, defaultOutputIsProxy: true))
        XCTAssertEqual(hal.writes, [])
    }

    func testStartupWithoutAProxyDeviceDoesNotFallBackToWriting() {
        let hdmiDevice = hdmi()
        publish([hdmiDevice], withProxies: false)

        let routing = proxyManager.resolveProxyRouting(forPhysicalUID: hdmiDevice.uid)

        XCTAssertEqual(routing, .proxyDeviceMissing)
        XCTAssertFalse(routing.isRoutable)
        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    func testHostRestartDoesNotChangeTheDefaultOutput() {
        // A restart tears the object references down and resolves them again —
        // twice, back to back, as a crash loop would.
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        proxyManager.invalidateDeviceReferences()
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    // MARK: - CoreAudio recovery

    func testCoreAudioRebuildRecoveryDoesNotChangeTheDefaultOutput() {
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        let remap = proxyManager.remapAfterCoreAudioRebuild(in: registry.devices)

        XCTAssertTrue(remap.proxyPresent)
        XCTAssertFalse(remap.defaultIsProxy)
        XCTAssertEqual(remap.systemDefaultOutputUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    func testCoreAudioRebuildDoesNotReassertAProxyTheUserPicked() {
        // The proxy *was* the default when the graph was rebuilt. Restoring it is
        // not the Host's job either: a user switch in the meantime must survive.
        hal.defaultOutputID = proxyID
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        let remap = proxyManager.remapAfterCoreAudioRebuild(in: registry.devices)

        XCTAssertTrue(remap.defaultIsProxy)
        XCTAssertEqual(hal.writes, [])
    }

    func testRecoveryNotificationHandlingDoesNotChangeTheDefaultOutput() {
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        proxyManager.beginRecovery()
        monitor.deliverDefaultOutputNotification(token: monitor.captureDeviceEventToken())
        monitor.deliverDeviceNotification(token: monitor.captureDeviceEventToken())
        proxyManager.endRecovery()
        monitor.handleDefaultOutputChanged()

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    // MARK: - Device callbacks

    func testHdmiReappearingDoesNotChangeTheDefaultOutput() {
        let hdmiDevice = hdmi()
        publish([hdmiDevice])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        // Unplug, then plug back in.
        discovery.devices = []
        monitor.handleDeviceListChanged()
        publish([hdmiDevice])
        monitor.handleDeviceListChanged()

        XCTAssertEqual(hal.writes, [], "a returning HDMI monitor is not a request to move the audio there")
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    func testDisplayPortReappearingDoesNotChangeTheDefaultOutput() {
        let dp = device(displayPortUID, id: displayPortID, transport: 1)
        publish([dp])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: dp.uid)

        discovery.devices = []
        monitor.handleDeviceListChanged()
        publish([dp])
        monitor.handleDeviceListChanged()

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    func testPhysicalDeviceDisappearingDoesNotChangeTheDefaultOutput() {
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        discovery.devices = []
        monitor.handleDeviceListChanged()

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    func testProxyDeviceCreationDoesNotChangeTheDefaultOutput() {
        let hdmiDevice = hdmi()
        // The physical device is already published; the driver has not created
        // the proxy yet.
        registry.update([hdmiDevice])
        discovery.devices = [hdmiDevice]
        monitor.handleDeviceListChanged()

        // The proxy appears.
        hal.add(id: proxyID, uid: proxyUID, name: "ULTRAGEAR+ (SoundBridge)")
        monitor.handleDeviceListChanged()

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    func testProxyDeviceDestructionDoesNotChangeTheDefaultOutput() {
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        hal.remove(id: proxyID)
        monitor.handleDeviceListChanged()

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    func testDeviceListChangeWhileDegradedDoesNotChangeTheDefaultOutput() {
        // Host started before the driver published a proxy and went degraded; a
        // late proxy shows up. That is a recovery, not a switch.
        let hdmiDevice = hdmi()
        publish([hdmiDevice], withProxies: false)
        XCTAssertEqual(proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID), .proxyDeviceMissing)

        monitor.setHostState(.degraded)
        var recoveryRequested = false
        monitor.onDegradedRecovery = { recoveryRequested = true }
        hal.add(id: proxyID, uid: proxyUID)
        monitor.handleDeviceListChanged()

        XCTAssertTrue(recoveryRequested)
        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    // MARK: - Default-output notifications (the Host observing a user switch)

    func testDefaultOutputNotificationForAPhysicalDeviceDoesNotSwitchBack() {
        // The user moved the audio from the SoundBridge proxy to the speakers.
        // The Host follows it — it does not undo it.
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)
        hal.defaultOutputID = speakersID

        monitor.handleDefaultOutputChanged()

        XCTAssertEqual(hal.writes, [], "the user's choice is not the Host's to revert")
        XCTAssertEqual(hal.defaultOutputID, speakersID)
        XCTAssertEqual(proxyManager.activeProxyDeviceID, 0,
                       "the Host stops treating the proxy as the audio path")
    }

    func testDefaultOutputNotificationForTheProxyOnlyAdoptsState() {
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)
        hal.defaultOutputID = proxyID

        monitor.deliverDefaultOutputNotification(token: monitor.captureDeviceEventToken())

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(proxyManager.activeProxyDeviceID, proxyID)
        XCTAssertEqual(proxyManager.activePhysicalDeviceID, physicalID)
    }

    // MARK: - Volume and EQ

    func testVolumeOperationsDoNotChangeTheDefaultOutput() {
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        // What a volume change does: restore the persisted level on the proxy,
        // forward it to the physical device, re-read the system default.
        proxyManager.restoreVolumeState(proxyDeviceID: proxyID, physicalUID: physicalUID)
        _ = proxyManager.refreshSystemDefaultOutput()
        _ = proxyManager.currentDefaultOutputOwner()
        proxyManager.notePhysicalSelection(physicalUID)

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    func testEQOperationsDoNotChangeTheDefaultOutput() {
        // EQ gains live in the shared-memory mapping the App writes; the Host's
        // EQ work never reaches the default-output API. Driven here the same way
        // a preset change arrives: a publish and a forwarding refresh.
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        let readings = registry.update(registry.devices)
        XCTAssertTrue(readings)
        proxyManager.restoreVolumeState(proxyDeviceID: proxyID, physicalUID: physicalUID)

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    // MARK: - Shutdown

    func testShutdownSequenceHasNoDefaultOutputStep() {
        let steps = ShutdownSequence.Step.allCases.map(\.rawValue)
        XCTAssertFalse(steps.contains { $0.localizedCaseInsensitiveContains("default") })
        XCTAssertFalse(steps.contains { $0.localizedCaseInsensitiveContains("restore") })
        XCTAssertEqual(steps.last, "releaseInstanceLock")
    }

    func testNormalShutdownLeavesTheDefaultOutputWhereTheUserPutIt() {
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        // The production `cleanup()` order, restricted to the steps that touch
        // the objects this test owns.
        var sequence = ShutdownSequence()
        sequence.run { step in
            switch step {
            case .removePropertyListeners:
                self.monitor.stop()
            case .stopHeartbeat:
                self.memory.stopHeartbeat()
            case .stopAudioEngine:
                self.engine.stop()
            case .unlinkSharedMemory:
                self.memory.cleanup()
            case .releaseInstanceLock:
                self.registry.endSession()
            case .markStopping, .stopConnectionMonitor, .stopSleepWakeMonitor,
                 .removeControlFile, .waitForDriverDetach, .maybeRestartCoreAudio, .publishStopped:
                break
            }
        }

        XCTAssertTrue(sequence.ranEveryStepOnce)
        XCTAssertEqual(hal.writes, [], "a quit is not a licence to change the default output")
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    func testAbnormalExitDoesNotChangeTheDefaultOutput() {
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        // No shutdown sequence at all: the process disappears. `deinit` is the
        // only thing that runs.
        proxyManager = nil
        engine = nil

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }

    // MARK: - No automatic path can be reached through a lifecycle event

    func testEveryAutomaticRouteLeavesTheWriteLogEmpty() {
        // One pass over the events the product names, in the order a busy day
        // produces them, so a future automatic switch has one test to break.
        publish([hdmi()])
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)

        monitor.handleDeviceListChanged()                       // proxy created / listed
        hal.defaultOutputID = speakersID
        monitor.handleDefaultOutputChanged()                    // user picked the speakers
        proxyManager.invalidateDeviceReferences()
        _ = proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID)  // host restart
        _ = proxyManager.remapAfterCoreAudioRebuild(in: registry.devices)  // coreaudiod rebuild
        discovery.devices = []
        monitor.handleDeviceListChanged()                       // unplug
        publish([hdmi()])
        monitor.handleDeviceListChanged()                       // re-plug
        proxyManager.notePhysicalSelection(physicalUID)          // user chose the physical device
        _ = proxyManager.refreshSystemDefaultOutput()

        XCTAssertEqual(hal.writes, [])
        XCTAssertEqual(hal.defaultOutputID, speakersID)
    }
}

// MARK: - Source-level gate
//
// The test suite above can only drive what is reachable from a test target.
// `main.swift` is top-level code and cannot be imported, so the paths it owns
// (startup, degraded recovery, shutdown, the Darwin-notification handlers) are
// gated by reading the sources: exactly one file in the Host may contain a
// default-output write, and nothing may call it.

final class HostDefaultOutputSourceTests: XCTestCase {

    private var hostSources: URL {
        URL(fileURLWithPath: #filePath)          // Tests/SoundBridgeHostTests/<file>
            .deletingLastPathComponent()          // Tests/SoundBridgeHostTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // packages/host
            .appendingPathComponent("Sources")
    }

    private func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: hostSources, includingPropertiesForKeys: nil
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        XCTAssertFalse(files.isEmpty, "no Host sources found at \(hostSources.path)")
        return files
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: hostSources.appendingPathComponent(name), encoding: .utf8)
    }

    /// Drop comment-only lines so a doc comment that *names* a removed symbol
    /// does not read as a reference to it.
    private func code(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
                    && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    func testTheHostNeverWritesTheSystemOutputDevice() throws {
        // The pre-batch `setDefaultOutputDevice` also set
        // `kAudioHardwarePropertyDefaultSystemOutputDevice`. Nothing in the Host
        // may mention it any more.
        for file in try swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                text.contains("kAudioHardwarePropertyDefaultSystemOutputDevice"),
                "\(file.lastPathComponent) mentions the system output device"
            )
        }
    }

    func testOnlyTheHALImplementsTheDefaultOutputWrite() throws {
        var writers: [String] = []
        for file in try swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("AudioObjectSetPropertyData"),
               text.contains("kAudioHardwarePropertyDefaultOutputDevice") {
                writers.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(writers, ["DefaultOutputHAL.swift"],
                       "a default-output write appeared outside the HAL seam")
    }

    func testNothingCallsTheDefaultOutputSetter() throws {
        for file in try swiftFiles() where file.lastPathComponent != "DefaultOutputHAL.swift" {
            let text = code(try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(
                text.contains("setDefaultOutput("),
                "\(file.lastPathComponent) calls setDefaultOutput(_:); the Host must only read the default output"
            )
        }
    }

    func testTheRemovedAutomaticSwitchPathsStayRemoved() throws {
        let main = code(try source("SoundBridgeHost/main.swift"))
        for symbol in ["autoSelectProxy(", "bounceDevice(", "restorePhysicalDevice(",
                       "setDefaultOutputDevice(", "waitForProxyAndSwitch(",
                       "degradedMaySelectDefault"] {
            XCTAssertFalse(main.contains(symbol), "main.swift still references \(symbol)")
        }

        let monitor = code(try source("SoundBridgeHost/Devices/DeviceMonitor.swift"))
        for symbol in ["waitForProxyAndSwitch(", "bounceDevice(", "restorePhysicalDevice("] {
            XCTAssertFalse(monitor.contains(symbol), "DeviceMonitor still references \(symbol)")
        }

        let manager = code(try source("SoundBridgeHost/Devices/ProxyDeviceManager.swift"))
        for symbol in ["func autoSelectProxy", "func bounceDevice", "func restorePhysicalDevice",
                       "func setDefaultOutputDevice", "isDeviceBouncing", "bounceUntilTime",
                       "switchCooldown", "isAutoSwitching"] {
            XCTAssertFalse(manager.contains(symbol), "ProxyDeviceManager still has \(symbol)")
        }
    }

    func testTheRoutingEntryPointTakesADeviceInsteadOfAskingForTheDefault() throws {
        // The old startup asked "what is the default output" and made that
        // device's proxy the default. The new one is told which device to route
        // for, so it cannot derive a switch from the current default.
        let manager = try source("SoundBridgeHost/Devices/ProxyDeviceManager.swift")
        XCTAssertTrue(manager.contains("func resolveProxyRouting(forPhysicalUID physicalUID: String)"))
        XCTAssertTrue(manager.contains("case routed(proxyDeviceID: AudioDeviceID, defaultOutputIsProxy: Bool)"))
    }
}
