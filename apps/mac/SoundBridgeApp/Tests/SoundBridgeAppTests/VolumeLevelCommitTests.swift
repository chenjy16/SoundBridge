import XCTest
import CoreAudio
@testable import SoundBridgeApp

// MARK: - P1-1 on the app side: "accepted" is not "applied"
//
// `VolumeController.setVolume`/`setMute` used to return `Void` and publish the
// requested value to `@Published currentVolume` / `isMuted` whenever one HAL
// element answered `noErr`. The menu bar therefore showed a value the audio path
// was not using. `VolumeLevelCommit` is the decision that was missing: write,
// then — for the proxy — read back what the device reports, and let the caller
// publish only that.
//
// The commit logic is tested here through `VolumeLevelWriting`, so every branch
// is reachable without audio hardware. The wiring (that the controller publishes
// `applied` and nothing else) is checked at the source level below, because
// `VolumeController` is a singleton whose `init` talks to CoreAudio.

/// A `VolumeLevelWriting` that models a device's elements.
final class RecordingVolumeLevel: VolumeLevelWriting {
    /// Elements the fake device exposes. A write or read for anything else
    /// answers like a real device does for an element it does not have.
    var supportedElements: Set<UInt32> = [kAudioObjectPropertyElementMain]

    /// What the device ends up holding after a successful write.
    private(set) var scalar: Float = 1.0
    private(set) var mute: Bool = false

    /// When set, reads report this instead of what was written — a device that
    /// clamps, quantises differently, or silently ignores the write.
    var reportedScalar: Float?
    var reportedMute: Bool?

    /// Models a control that accepts writes but refuses to answer reads.
    var readbackFails = false

    static let elementRejected: OSStatus = -50   // paramErr: "no such element"

    private(set) var scalarWrites: [(deviceID: AudioObjectID, element: UInt32, value: Float)] = []
    private(set) var muteWrites: [(deviceID: AudioObjectID, element: UInt32, value: Bool)] = []
    private(set) var scalarReads: [(deviceID: AudioObjectID, element: UInt32)] = []
    private(set) var muteReads: [(deviceID: AudioObjectID, element: UInt32)] = []

    func writeScalar(_ value: Float, to deviceID: AudioObjectID, element: UInt32) -> OSStatus {
        scalarWrites.append((deviceID, element, value))
        guard supportedElements.contains(element) else { return Self.elementRejected }
        scalar = value
        return noErr
    }

    func readScalar(from deviceID: AudioObjectID, element: UInt32) -> Float? {
        scalarReads.append((deviceID, element))
        guard !readbackFails, supportedElements.contains(element) else { return nil }
        return reportedScalar ?? scalar
    }

    func writeMute(_ muted: Bool, to deviceID: AudioObjectID, element: UInt32) -> OSStatus {
        muteWrites.append((deviceID, element, muted))
        guard supportedElements.contains(element) else { return Self.elementRejected }
        mute = muted
        return noErr
    }

    func readMute(from deviceID: AudioObjectID, element: UInt32) -> Bool? {
        muteReads.append((deviceID, element))
        guard !readbackFails, supportedElements.contains(element) else { return nil }
        return reportedMute ?? mute
    }

    var writtenScalarValues: [Float] { scalarWrites.map(\.value) }
}

final class VolumeLevelCommitTests: XCTestCase {

    private let proxyID: AudioDeviceID = 90
    private let physicalID: AudioDeviceID = 41

    private var level: RecordingVolumeLevel!
    private var commit: VolumeLevelCommit!

    override func setUp() {
        super.setUp()
        level = RecordingVolumeLevel()
        commit = VolumeLevelCommit(level: level)
    }

    override func tearDown() {
        commit = nil
        level = nil
        super.tearDown()
    }

    // MARK: - Volume

    func testAProxyWriteThatTheDeviceConfirmsIsCommitted() {
        let result = commit.setVolume(0.5, target: .proxy(proxyID))

        XCTAssertEqual(result, .committed(0.5))
    }

    func testTheMainElementIsUsedWhenTheDeviceHasIt() {
        _ = commit.setVolume(0.5, target: .proxy(proxyID))

        // The app has always preferred the master control and stopped there.
        XCTAssertEqual(level.scalarWrites.map(\.element), [kAudioObjectPropertyElementMain])
    }

    func testChannelsAreTriedWhenTheDeviceHasNoMainElement() {
        level.supportedElements = [1, 2]

        let result = commit.setVolume(0.5, target: .proxy(proxyID))

        XCTAssertEqual(result, .committed(0.5))
        XCTAssertEqual(level.scalarWrites.map(\.element), [kAudioObjectPropertyElementMain, 1, 2],
                       "every element is attempted, as before")
    }

    func testTheReadbackAsksTheElementThatAcceptedTheWrite() {
        level.supportedElements = [2]

        _ = commit.setVolume(0.5, target: .proxy(proxyID))

        XCTAssertEqual(level.scalarReads.map(\.element), [2])
    }

    func testAWriteThatEveryElementRefusesIsRejected() {
        level.supportedElements = []

        let result = commit.setVolume(0.5, target: .proxy(proxyID))

        XCTAssertEqual(result, .rejected(RecordingVolumeLevel.elementRejected))
        XCTAssertTrue(level.scalarReads.isEmpty, "a rejected write has nothing to verify")
    }

    func testAWriteAndAReadbackThatDisagreeIsNotCommitted() {
        // The device accepted the write and kept its old value. 1.2.0 showed the
        // requested value here.
        level.reportedScalar = 0.2

        let result = commit.setVolume(0.8, target: .proxy(proxyID))

        XCTAssertEqual(result, .notVerified(requested: 0.8, actual: 0.2))
    }

    func testAWriteTheDeviceWillNotConfirmIsNotCommitted() {
        level.readbackFails = true

        let result = commit.setVolume(0.8, target: .proxy(proxyID))

        XCTAssertEqual(result, .notVerified(requested: 0.8, actual: nil))
    }

    func testQuantisationInsideOneRawStepIsACommit() {
        // The proxy holds `scalar = (raw / 48)^2`. A request halfway between two
        // raw steps comes back up to half a step away; that is the setter, not a
        // dropped write.
        let requested: Float = 0.53
        let oneStepHigher = pow(sqrt(requested) + 1.0 / VolumeLevelCommit.taperSteps, 2)
        level.reportedScalar = oneStepHigher

        let result = commit.setVolume(requested, target: .proxy(proxyID))

        XCTAssertEqual(result, .committed(oneStepHigher),
                       "the committed value is what the device reports, not the request")
    }

    func testQuantisationJustOutsideOneRawStepIsNotACommit() {
        let requested: Float = 0.53
        let twoStepsHigher = pow(sqrt(requested) + 2.0 / VolumeLevelCommit.taperSteps, 2)
        level.reportedScalar = twoStepsHigher

        let result = commit.setVolume(requested, target: .proxy(proxyID))

        XCTAssertEqual(result, .notVerified(requested: requested, actual: twoStepsHigher))
    }

    func testAPhysicalDeviceIsTrustedOnItsStatusAlone() {
        // Third-party devices may quantise far more coarsely than the proxy, and
        // refusing their valid changes would be a regression.
        level.reportedScalar = 0.1

        let result = commit.setVolume(0.7, target: .physical(physicalID))

        XCTAssertEqual(result, .committed(0.7))
        XCTAssertTrue(level.scalarReads.isEmpty, "a physical device is not read back")
    }

    func testOutOfRangeRequestsAreClamped() {
        XCTAssertEqual(commit.setVolume(1.7, target: .proxy(proxyID)), .committed(1.0))
        XCTAssertEqual(commit.setVolume(-0.4, target: .proxy(proxyID)), .committed(0.0))
        XCTAssertEqual(level.writtenScalarValues, [1.0, 0.0])
    }

    func testNoTargetIsReportedAsUnavailable() {
        XCTAssertEqual(commit.setVolume(0.5, target: .none), .unavailable)
        XCTAssertEqual(commit.setVolume(0.5, target: .proxy(kAudioObjectUnknown)), .unavailable)
        XCTAssertTrue(level.scalarWrites.isEmpty)
    }

    // MARK: - Mute

    func testAProxyMuteThatTheDeviceConfirmsIsCommitted() {
        XCTAssertEqual(commit.setMute(true, target: .proxy(proxyID)), .committed(true))
        XCTAssertEqual(commit.setMute(false, target: .proxy(proxyID)), .committed(false))
    }

    func testAMuteTheDeviceDidNotTakeIsNotCommitted() {
        level.reportedMute = false

        let result = commit.setMute(true, target: .proxy(proxyID))

        XCTAssertEqual(result, .notVerified(requested: true, actual: false))
    }

    func testAMuteTheDeviceWillNotConfirmIsNotCommitted() {
        level.readbackFails = true

        XCTAssertEqual(commit.setMute(true, target: .proxy(proxyID)),
                       .notVerified(requested: true, actual: nil))
    }

    func testARejectedMuteIsRejected() {
        level.supportedElements = []

        XCTAssertEqual(commit.setMute(true, target: .proxy(proxyID)),
                       .rejected(RecordingVolumeLevel.elementRejected))
    }

    func testAPhysicalMuteIsTrustedOnItsStatusAlone() {
        level.reportedMute = false

        XCTAssertEqual(commit.setMute(true, target: .physical(physicalID)), .committed(true))
        XCTAssertTrue(level.muteReads.isEmpty)
    }

    // MARK: - The tolerance itself

    func testOneRawStepIsTheTolerance() {
        let requested: Float = 0.36
        let exactlyOneStep = pow(sqrt(requested) + 1.0 / 48.0, 2)

        XCTAssertTrue(VolumeLevelCommit.isWithinOneRawStep(requested, requested))
        XCTAssertTrue(VolumeLevelCommit.isWithinOneRawStep(requested, exactlyOneStep))
        XCTAssertFalse(VolumeLevelCommit.isWithinOneRawStep(requested, pow(sqrt(requested) + 1.5 / 48.0, 2)))
    }

    func testTheToleranceMatchesTheDriversTaper() {
        // `RF_VOLUME_RAW_MAX`, which the driver passes to the control. If this
        // ever changes, the tolerance is measuring the wrong device.
        XCTAssertEqual(VolumeLevelCommit.taperSteps, 48)
    }
}

// MARK: - Source-level gate
//
// What the menu bar shows is decided inside `VolumeController`, a singleton whose
// `init` enumerates CoreAudio devices. The sources are read rather than
// constructed, the way `AppDefaultOutputSourceTests` checks the default-output
// rule.

final class AppVolumeCommitSourceTests: XCTestCase {

    private var appSources: URL {
        URL(fileURLWithPath: #filePath)          // Tests/SoundBridgeAppTests/<file>
            .deletingLastPathComponent()          // Tests/SoundBridgeAppTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // apps/mac/SoundBridgeApp
            .appendingPathComponent("Sources")
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        XCTAssertFalse(files.isEmpty, "no App sources found at \(appSources.path)")
        return files
    }

    /// Drop comment-only lines so prose about a removed symbol does not read as
    /// a reference to it.
    private func code(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
                    && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    /// Slice on the original text: the markers below include comment lines, so
    /// the comments can only be stripped afterwards.
    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(text.range(of: start), "missing '\(start)'")
        let endRange = try XCTUnwrap(text.range(of: end, range: startRange.upperBound..<text.endIndex),
                                     "missing '\(end)' after '\(start)'")
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    func testTheMenuBarOnlyShowsWhatTheDeviceCommitted() throws {
        let text = try source("Services/VolumeController.swift")
        let body = code(try slice(text, from: "func setVolume(_ value: Float)",
                                  to: "// MARK: - Volume Listening"))

        let assignments = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("currentVolume =") || $0.contains("isMuted =") }

        XCTAssertEqual(assignments, ["self?.currentVolume = applied", "self?.isMuted = applied"],
                       "the published state must come from the commit result and nowhere else")
    }

    func testTheControlPathReportsItsResult() throws {
        let text = try source("Services/VolumeController.swift")

        XCTAssertTrue(text.contains("@discardableResult\n    func setVolume(_ value: Float) -> VolumeCommitResult"),
                      "setVolume must return an explicit result")
        XCTAssertTrue(text.contains("@discardableResult\n    func setMute(_ muted: Bool) -> MuteCommitResult"),
                      "setMute must return an explicit result")
        XCTAssertTrue(text.contains("levelCommit.setVolume(value, target: target)"))
        XCTAssertTrue(text.contains("levelCommit.setMute(muted, target: target)"))
    }

    func testEveryVolumeAndMuteWriteLivesInOnePlace() throws {
        var scalarWriters: [String] = []
        var muteWriters: [String] = []

        for file in try swiftFiles() {
            let text = code(try String(contentsOf: file, encoding: .utf8))
            if writes(selector: "kAudioDevicePropertyVolumeScalar", in: text) {
                scalarWriters.append(file.lastPathComponent)
            }
            if writes(selector: "kAudioDevicePropertyMute", in: text) {
                muteWriters.append(file.lastPathComponent)
            }
        }

        XCTAssertEqual(scalarWriters, ["VolumeLevelControl.swift"],
                       "a volume write appeared outside the commit helper")
        XCTAssertEqual(muteWriters, ["VolumeLevelControl.swift"],
                       "a mute write appeared outside the commit helper")
    }

    /// Both symbols within a few lines of each other, so a file that merely
    /// mentions the selector (a reader, a listener address) is not counted.
    private func writes(selector: String, in text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where line.contains(selector) {
            let lower = max(0, index - 6)
            let upper = min(lines.count - 1, index + 6)
            if lines[lower...upper].contains(where: { $0.contains("AudioObjectSetPropertyData") }) {
                return true
            }
        }
        return false
    }
}
