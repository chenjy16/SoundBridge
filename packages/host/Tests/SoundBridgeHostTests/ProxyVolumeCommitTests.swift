import XCTest
import CoreAudio
import CSoundBridgeAudio
@testable import SoundBridgeHost

// MARK: - P1-1: the commit must not wait for playback
//
// 1.2.0 observation: a volume or mute change made while nothing is playing
// "does not take effect", and reapplying it during playback fixes it.
//
// The mechanism is the driver's. `UniversalAudioHandler` installs the
// shared-memory mapping into `SoundBridgeVolumeControl` / `SoundBridgeMuteControl`
// only from `OnStartIO`, so with no IO client a control change stops at the HAL
// control. The next `OnStartIO` then runs `rf_sync_driver_volume_state()`, which
// adopts the committed shared-memory state and pushes it *back* into the rebuilt
// control — silently discarding what the user just chose.
//
// The fix is on the Host side and needs no protocol change: the Host already
// receives the CoreAudio property notification, and it already owns the mapping.
// It now publishes the observed state with `rf_publish_volume_state()`, which is
// the same authoritative write `createMemory()` uses, so the driver's next
// handshake adopts the user's value instead of overwriting it.
//
// These tests drive `ProxyDeviceManager.commitObservedProxyVolumeState()`, which
// is what the notification handlers call. They do not prove that macOS delivers
// the notification — that needs a live device and is listed as a real-machine
// item in the report.

/// A `DeviceVolumeHAL` that answers from a dictionary and records every write.
final class RecordingDeviceVolumeHAL: DeviceVolumeHAL {
    /// What the fake device currently reports. `nil` models a device that will
    /// not answer, which is the "control delivery failed" path.
    var volumeByDevice: [AudioDeviceID: Float32] = [:]
    var muteByDevice: [AudioDeviceID: Bool] = [:]

    /// Answers for the next reads, in order, before falling back to the
    /// dictionary. Lets a test model a change that lands in the middle of a
    /// commit.
    var scriptedVolumeReads: [Float32] = []

    private(set) var writtenVolumes: [(deviceID: AudioDeviceID, volume: Float32)] = []
    private(set) var writtenMutes: [(deviceID: AudioDeviceID, muted: Bool)] = []

    func volume(_ deviceID: AudioDeviceID) -> Float32? {
        if !scriptedVolumeReads.isEmpty { return scriptedVolumeReads.removeFirst() }
        return volumeByDevice[deviceID]
    }

    func muted(_ deviceID: AudioDeviceID) -> Bool? {
        guard muteByDevice[deviceID] != nil else { return nil }
        return muteByDevice[deviceID]
    }

    func setVolume(_ deviceID: AudioDeviceID, volume: Float32) -> Bool {
        writtenVolumes.append((deviceID, volume))
        volumeByDevice[deviceID] = volume
        return true
    }

    func setMuted(_ deviceID: AudioDeviceID, muted: Bool) -> Bool {
        writtenMutes.append((deviceID, muted))
        muteByDevice[deviceID] = muted
        return true
    }

    func volumesWritten(to deviceID: AudioDeviceID) -> [Float32] {
        writtenVolumes.filter { $0.deviceID == deviceID }.map(\.volume)
    }
}

final class ProxyVolumeCommitTests: XCTestCase {

    private let physicalUID = "AppleUSBAudioEngine:LG:ULTRAGEAR+:1"
    private var proxyUID: String { physicalUID + "-soundbridge" }

    private let physicalID: AudioDeviceID = 41
    private let proxyID: AudioDeviceID = 90
    private let speakersID: AudioDeviceID = 99

    private var sandbox: URL!
    private var registry: DeviceRegistry!
    private var memory: SharedMemoryManager!
    private var persistence: VolumePersistence!
    private var hal: RecordingDefaultOutputHAL!
    private var volumeHAL: RecordingDeviceVolumeHAL!
    private var proxyManager: ProxyDeviceManager!

    override func setUpWithError() throws {
        try super.setUpWithError()

        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeVolumeCommit-\(UUID().uuidString)", isDirectory: true)
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
        persistence = VolumePersistence(fileURL: sandbox.appendingPathComponent("volume.json"))

        // The default output is the built-in speakers: a user who has not asked
        // SoundBridge to take over. Committing must still work.
        hal = RecordingDefaultOutputHAL(defaultOutputID: speakersID)
        hal.add(id: speakersID, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
        hal.add(id: proxyID, uid: proxyUID, name: "ULTRAGEAR+ (SoundBridge)")
        hal.add(id: physicalID, uid: physicalUID, name: "ULTRAGEAR+")

        volumeHAL = RecordingDeviceVolumeHAL()

        proxyManager = ProxyDeviceManager(
            registry: registry,
            volumePersistence: persistence,
            lifecycleGate: HostLifecycleGate(),
            hal: hal,
            volumeHAL: volumeHAL
        )
        // The same wiring `main.swift` installs: commit → shared memory.
        proxyManager.onProxyVolumeStateCommitted = { [weak self] uid, scalar, muted in
            self?.memory.publishVolumeState(for: uid, scalar: scalar, muted: muted) ?? false
        }

        let device = PhysicalDevice(
            id: physicalID, name: "ULTRAGEAR+", uid: physicalUID,
            manufacturer: "Fake", transportType: 0, isOutput: true,
            validationPassed: true, validationNote: nil, isFixedVolume: true
        )
        registry.update([device])

        XCTAssertNotNil(memory.createMemory(for: physicalUID, persistence: persistence),
                        "the mapping is the thing under test")
        XCTAssertEqual(proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID),
                       .routed(proxyDeviceID: proxyID, defaultOutputIsProxy: false))
        drainMainQueue()
    }

    override func tearDownWithError() throws {
        proxyManager = nil
        memory?.cleanup()
        memory = nil
        volumeHAL = nil
        hal = nil
        persistence = nil
        registry = nil
        try? FileManager.default.removeItem(at: sandbox)
        sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Run the work `volumeForwardQueue` (`DispatchQueue.main`) has queued.
    private func drainMainQueue(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private var mapping: UnsafeMutablePointer<RFSharedAudio>? {
        memory.getMemory(for: physicalUID)
    }

    private func revision() -> UInt64 {
        guard let mapping else { return 0 }
        return rf_get_state_revision(mapping)
    }

    private func committedScalar() -> Float32? {
        memory.readVolumeState(for: physicalUID).map { $0.scalar }
    }

    private func committedMuted() -> Bool? {
        memory.readVolumeState(for: physicalUID).map { $0.muted }
    }

    /// Poll until the debounced writer has published the file, so the assertion
    /// is about the disk and not about the in-memory cache.
    private func persistedOnDisk(uid: String, timeout: TimeInterval = 3.0) -> DeviceVolumeState? {
        let url = sandbox.appendingPathComponent("volume.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: DeviceVolumeState].self, from: data),
               let state = decoded[uid] {
                return state
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    // MARK: - Volume

    func testVolumeChangeWithoutAnActiveIOClientReachesSharedMemory() {
        // No play() has happened, so `OnStartIO` never ran: this is the 1.2.0
        // situation where the change used to stop at the HAL control.
        volumeHAL.volumeByDevice[proxyID] = 0.72
        let before = revision()

        proxyManager.commitObservedProxyVolumeState()

        XCTAssertEqual(committedScalar() ?? -1, 0.72, accuracy: 1e-6,
                       "the change must be committed without an IO client")
        XCTAssertEqual(revision(), before &+ 1, "a committed change is a new revision")
    }

    func testTheNextIOStartAdoptsTheCommittedVolumeInsteadOfOverwritingIt() {
        // This is the observation, expressed as the driver's own handshake:
        // start playback later and the committed value must win.
        volumeHAL.volumeByDevice[proxyID] = 0.72
        proxyManager.commitObservedProxyVolumeState()

        guard let mapping else { return XCTFail("no mapping") }
        var adopted = RFVolumeStateSnapshot()
        // A freshly built VolumeControl sits at MaxRawVolume, scalar 1.0.
        let outcome = rf_sync_driver_volume_state(mapping, 1.0, false, &adopted)

        XCTAssertEqual(outcome, RF_VOLUME_SYNC_ADOPTED)
        XCTAssertEqual(adopted.scalar, 0.72, accuracy: 1e-6,
                       "IO start reset the user's volume to the control default")
        XCTAssertEqual(rf_load_volume_scalar(mapping), 0.72, accuracy: 1e-6,
                       "the render gain must come from the committed value")
    }

    func testVolumeChangeDuringPlaybackIsCommittedWithANewRevision() {
        // With IO active the driver mirrors the control into shared memory
        // itself (`rf_store_volume_scalar`), which deliberately does not move
        // `state_revision`. The Host's commit is what makes the change
        // authoritative for the next handshake.
        guard let mapping else { return XCTFail("no mapping") }
        rf_store_volume_scalar(mapping, 0.55)
        let before = revision()

        volumeHAL.volumeByDevice[proxyID] = 0.55
        proxyManager.commitObservedProxyVolumeState()

        XCTAssertEqual(revision(), before &+ 1)
        XCTAssertEqual(committedScalar() ?? -1, 0.55, accuracy: 1e-6)
    }

    func testConsecutiveVolumeChangesEachCommit() {
        let before = revision()
        for value: Float32 in [0.2, 0.55, 0.9] {
            volumeHAL.volumeByDevice[proxyID] = value
            proxyManager.commitObservedProxyVolumeState()
            XCTAssertEqual(committedScalar() ?? -1, value, accuracy: 1e-6)
        }
        XCTAssertEqual(revision(), before &+ 3,
                       "three real changes are three revisions; a slider drag must not be deduplicated away")
    }

    func testRepeatingTheSameVolumeDoesNotBumpTheRevision() {
        volumeHAL.volumeByDevice[proxyID] = 0.4
        proxyManager.commitObservedProxyVolumeState()
        let afterFirst = revision()

        // HAL notification bursts repeat the same value; that is not a change.
        proxyManager.commitObservedProxyVolumeState()
        XCTAssertEqual(revision(), afterFirst)
    }

    // MARK: - Mute

    func testMuteChangeWithoutAnActiveIOClientReachesSharedMemory() {
        volumeHAL.volumeByDevice[proxyID] = 0.6
        volumeHAL.muteByDevice[proxyID] = true
        let before = revision()

        proxyManager.commitObservedProxyVolumeState()

        XCTAssertEqual(committedMuted(), true, "mute must be committed without an IO client")
        XCTAssertEqual(committedScalar() ?? -1, 0.6, accuracy: 1e-6,
                       "muting must not disturb the scalar")
        XCTAssertEqual(revision(), before &+ 1)
    }

    func testTheNextIOStartAdoptsTheCommittedMuteState() {
        volumeHAL.volumeByDevice[proxyID] = 0.6
        volumeHAL.muteByDevice[proxyID] = true
        proxyManager.commitObservedProxyVolumeState()

        guard let mapping else { return XCTFail("no mapping") }
        var adopted = RFVolumeStateSnapshot()
        XCTAssertEqual(rf_sync_driver_volume_state(mapping, 1.0, false, &adopted), RF_VOLUME_SYNC_ADOPTED)
        XCTAssertEqual(adopted.muted, 1)
        XCTAssertEqual(adopted.scalar, 0.6, accuracy: 1e-6)
    }

    func testUnmutingWithoutPlaybackIsCommitted() {
        volumeHAL.volumeByDevice[proxyID] = 0.6
        volumeHAL.muteByDevice[proxyID] = true
        proxyManager.commitObservedProxyVolumeState()

        volumeHAL.muteByDevice[proxyID] = false
        proxyManager.commitObservedProxyVolumeState()

        XCTAssertEqual(committedMuted(), false)
        XCTAssertEqual(committedScalar() ?? -1, 0.6, accuracy: 1e-6,
                       "unmuting must restore, not reset, the scalar")
    }

    // MARK: - Restart and reconnection

    func testTheCommittedVolumeIsOnDiskAfterTheDebounce() {
        volumeHAL.volumeByDevice[proxyID] = 0.66
        proxyManager.commitObservedProxyVolumeState()

        let onDisk = persistedOnDisk(uid: physicalUID)
        XCTAssertEqual(onDisk?.volumeScalar ?? -1, 0.66, accuracy: 1e-6)
        XCTAssertEqual(onDisk?.isMuted, false)
    }

    func testAHostRestartRestoresTheCommittedVolume() {
        volumeHAL.volumeByDevice[proxyID] = 0.66
        proxyManager.commitObservedProxyVolumeState()
        XCTAssertNotNil(persistedOnDisk(uid: physicalUID), "nothing to restore from")

        // What a fresh Host does: a new persistence reader, a new mapping, and
        // VolumeStateResolver's documented priority.
        let restarted = VolumePersistence(fileURL: sandbox.appendingPathComponent("volume.json"))
        let resolution = VolumeStateResolver.resolve(
            persisted: restarted.loadIfPresent(uid: physicalUID),
            recovered: nil
        )
        XCTAssertEqual(resolution.scalar, 0.66, accuracy: 1e-6)
        XCTAssertEqual(resolution.source, .persisted)
    }

    func testRoutingResolutionKeepsTheCommittedValueAndStillCommitsAfterwards() {
        volumeHAL.volumeByDevice[proxyID] = 0.5
        proxyManager.commitObservedProxyVolumeState()
        XCTAssertEqual(committedScalar() ?? -1, 0.5, accuracy: 1e-6)

        // CoreAudio restart / driver reconnection: the Host resolves the route
        // again, which tears the listeners down and rebuilds them.
        proxyManager.invalidateDeviceReferences()
        XCTAssertEqual(proxyManager.resolveProxyRouting(forPhysicalUID: physicalUID),
                       .routed(proxyDeviceID: proxyID, defaultOutputIsProxy: false))
        drainMainQueue()

        XCTAssertEqual(committedScalar() ?? -1, 0.5, accuracy: 1e-6,
                       "re-resolving the route must not change the committed value")

        volumeHAL.volumeByDevice[proxyID] = 0.81
        proxyManager.commitObservedProxyVolumeState()
        XCTAssertEqual(committedScalar() ?? -1, 0.81, accuracy: 1e-6,
                       "a change after reconnection must still be committed")
    }

    // MARK: - Failure handling

    func testAnUnreadableControlCommitsNothing() {
        let before = revision()
        volumeHAL.volumeByDevice[proxyID] = nil  // CoreAudio will not answer

        proxyManager.commitObservedProxyVolumeState()

        XCTAssertEqual(revision(), before, "no value was observed, so nothing may be committed")
        XCTAssertNil(persistence.loadIfPresent(uid: physicalUID))
    }

    func testAMissingMappingIsReportedAndTheDiskEntryIsStillWritten() {
        // The mapping is gone (cleanup, or a route the Host has no file for).
        volumeHAL.volumeByDevice[proxyID] = 0.44
        memory.cleanup()

        proxyManager.commitObservedProxyVolumeState()
        XCTAssertNil(committedScalar(), "a closed manager cannot publish")

        // Persisting first is what keeps the change recoverable: the next Host
        // start resolves from this entry.
        let onDisk = persistedOnDisk(uid: physicalUID)
        XCTAssertEqual(onDisk?.volumeScalar ?? -1, 0.44, accuracy: 1e-6)
    }

    func testAChangeThatLandsMidCommitIsConverged() {
        // First read is the value being committed, the re-read is a second
        // change that arrived while it was being published. From then on the
        // control reports the newer value.
        volumeHAL.volumeByDevice[proxyID] = 0.85
        volumeHAL.scriptedVolumeReads = [0.3]

        proxyManager.commitObservedProxyVolumeState()

        XCTAssertEqual(committedScalar() ?? -1, 0.85, accuracy: 1e-6,
                       "the later change must win, otherwise the next handshake reverts it")
    }

    // MARK: - The default-output rule is unchanged

    func testCommittingDoesNotDependOnTheProxyBeingTheDefaultOutput() {
        XCTAssertNotEqual(hal.defaultOutputID, proxyID, "the user is listening on the speakers")

        volumeHAL.volumeByDevice[proxyID] = 0.73
        proxyManager.commitObservedProxyVolumeState()

        XCTAssertEqual(committedScalar() ?? -1, 0.73, accuracy: 1e-6,
                       "committing is always correct; only forwarding is gated")
        XCTAssertEqual(hal.writes, [], "committing must not touch the default output")
    }
}

// MARK: - Wiring gate
//
// The suite above can only drive what a test target can reach. The two links it
// cannot reach are the CoreAudio notification that triggers a commit and the
// `main.swift` closure that publishes it, so those are asserted against the
// sources — the same technique `HostDefaultOutputSourceTests` uses for the
// paths `main.swift` owns.

final class HostVolumeCommitSourceTests: XCTestCase {

    private var hostSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: hostSources.appendingPathComponent(name), encoding: .utf8)
    }

    private func code(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
                    && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    func testTheHostWiresTheCommitToTheSharedMemoryPublisher() throws {
        let main = code(try source("SoundBridgeHost/main.swift"))
        XCTAssertTrue(main.contains("proxyManager.onProxyVolumeStateCommitted"),
                      "nothing wires the commit callback, so a change would never be published")
        XCTAssertTrue(main.contains("memoryManager.publishVolumeState(for: uid, scalar: scalar, muted: muted)"),
                      "the callback must be the Host's authoritative publish path")
    }

    func testBothNotificationHandlersCommit() throws {
        // Sliced from the raw source, because the end markers are comments.
        let manager = try source("SoundBridgeHost/Devices/ProxyDeviceManager.swift")

        let volumeHandler = try XCTUnwrap(
            slice(of: manager, from: "func handleProxyVolumeChanged(", to: "func handleProxyMuteChanged("))
        XCTAssertTrue(code(volumeHandler).contains("commitObservedProxyVolumeState()"),
                      "a volume notification must commit the state")

        let muteHandler = try XCTUnwrap(
            slice(of: manager, from: "func handleProxyMuteChanged(", to: "// MARK: - Committing the state"))
        XCTAssertTrue(code(muteHandler).contains("commitObservedProxyVolumeState()"),
                      "a mute notification must commit the state")
    }

    func testForwardingStillRequiresTheDefaultOutputGate() throws {
        let manager = try source("SoundBridgeHost/Devices/ProxyDeviceManager.swift")
        let forwarding = try XCTUnwrap(
            slice(of: manager, from: "private func forwardProxyVolumeToPhysical(", to: "private func proxyVolumeChangedCallback")
        )
        XCTAssertTrue(forwarding.contains("mayForwardToPhysical("),
                      "P2 Batch 2's gate must stay on the forwarding path")
        XCTAssertFalse(forwarding.contains("onProxyVolumeStateCommitted"),
                       "committing and forwarding are separate decisions")
    }

    func testNoRealTimePathCommitsVolume() throws {
        // The commit persists to disk and takes a lock: it must never be
        // reachable from a render callback.
        let renderer = code(try source("SoundBridgeHost/Audio/AudioRenderer.swift"))
        XCTAssertFalse(renderer.contains("publishVolumeState"))
        XCTAssertFalse(renderer.contains("volumePersistence"))
        XCTAssertFalse(renderer.contains("commitObservedProxyVolumeState"))
    }

    private func slice(of text: String, from start: String, to end: String) -> String? {
        guard let startRange = text.range(of: start),
              let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }
}
