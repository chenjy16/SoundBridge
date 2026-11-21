import XCTest
import CoreAudio
@testable import SoundBridgeApp

// MARK: - The one explicit switch
//
// P2 Batch 2's product rule has two halves, and this file is the second one:
//
//   * nothing automatic may change the macOS default output (proved in the Host
//     suite, `DefaultOutputGovernanceTests`), and
//   * the user must still be able to change it by clicking a device.
//
// `DefaultOutputSwitch` is the only code in the app that writes the default
// output. These tests drive it through `DefaultOutputWriting`, so they can count
// writes without touching the developer's audio.

/// Records write requests and can be told to fail, which is how the failure
/// paths are exercised without a live CoreAudio error.
final class RecordingDefaultOutputWriter: DefaultOutputWriting {
    private(set) var writes: [AudioDeviceID] = []
    var status: OSStatus = noErr

    func writeDefaultOutput(_ deviceID: AudioDeviceID) -> OSStatus {
        writes.append(deviceID)
        return status
    }
}

final class DefaultOutputSwitchTests: XCTestCase {

    private let physicalID: AudioDeviceID = 41
    private let proxyID: AudioDeviceID = 90

    private func device(id: AudioDeviceID = 41, name: String = "ULTRAGEAR+") -> OutputDevice {
        OutputDevice(id: id, name: name, uid: "AppleUSBAudioEngine:LG:ULTRAGEAR+:1", isFixedVolume: true)
    }

    func testTheRecordingWriterIsNotANoOp() {
        // Without this, "no writes" would pass because the writer was never wired.
        let writer = RecordingDefaultOutputWriter()
        let result = DefaultOutputSwitch(writer: writer)
            .switchToDevice(device(), proxyDeviceID: proxyID)

        XCTAssertTrue(result.didSwitch)
        XCTAssertEqual(writer.writes, [proxyID])
    }

    func testUserChoosingSoundBridgeWritesTheProxyExactlyOnce() {
        let writer = RecordingDefaultOutputWriter()

        let result = DefaultOutputSwitch(writer: writer)
            .switchToDevice(device(), proxyDeviceID: proxyID)

        XCTAssertEqual(result, .switched(deviceID: proxyID, throughProxy: true))
        XCTAssertEqual(writer.writes.count, 1, "one click is one write, not a retry loop")
        XCTAssertEqual(writer.writes.first, proxyID,
                       "audio should keep flowing through the SoundBridge proxy")
    }

    func testUserChoosingADeviceWithoutAProxyWritesThatDevice() {
        let writer = RecordingDefaultOutputWriter()

        let result = DefaultOutputSwitch(writer: writer)
            .switchToDevice(device(), proxyDeviceID: nil)

        XCTAssertEqual(result, .switched(deviceID: physicalID, throughProxy: false))
        XCTAssertEqual(writer.writes, [physicalID])
    }

    func testAFailedWriteIsReportedAndNotRetried() {
        let writer = RecordingDefaultOutputWriter()
        writer.status = kAudioHardwareBadObjectError

        let result = DefaultOutputSwitch(writer: writer)
            .switchToDevice(device(), proxyDeviceID: proxyID)

        XCTAssertFalse(result.didSwitch)
        XCTAssertEqual(writer.writes, [proxyID], "a failure must not turn into a silent retry")
        guard case .failed(let deviceID, let status, let message) = result else {
            return XCTFail("expected a reported failure, got \(result)")
        }
        XCTAssertEqual(deviceID, proxyID)
        XCTAssertEqual(status, kAudioHardwareBadObjectError)
        XCTAssertTrue(message.contains("ULTRAGEAR+"),
                      "the message has to name the device the user asked for")
    }

    func testCallingTwiceWritesTwiceBecauseTheUserAskedTwice() {
        // Two clicks are two user actions. This is not the automatic path: there
        // is no timer, no notification and no retry behind either call.
        let writer = RecordingDefaultOutputWriter()
        let outputSwitch = DefaultOutputSwitch(writer: writer)

        _ = outputSwitch.switchToDevice(device(), proxyDeviceID: proxyID)
        _ = outputSwitch.switchToDevice(device(), proxyDeviceID: proxyID)

        XCTAssertEqual(writer.writes, [proxyID, proxyID])
    }
}

// MARK: - Source-level gate
//
// The switch above is only the *only* switch if nothing else writes. App sources
// are read, not imported, so the whole module can be checked rather than the one
// type the tests can reach.

final class AppDefaultOutputSourceTests: XCTestCase {

    private var appSources: URL {
        URL(fileURLWithPath: #filePath)          // Tests/SoundBridgeAppTests/<file>
            .deletingLastPathComponent()          // Tests/SoundBridgeAppTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // apps/mac/SoundBridgeApp
            .appendingPathComponent("Sources")
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

    /// Drop comment-only lines so a comment that names a removed symbol does not
    /// read as a reference to it.
    private func code(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
                    && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    func testOnlyTheExplicitSwitchWritesTheDefaultOutput() throws {
        var writers: [String] = []
        for file in try swiftFiles() {
            let text = code(try String(contentsOf: file, encoding: .utf8))
            if writesDefaultOutput(text) { writers.append(file.lastPathComponent) }
        }
        XCTAssertEqual(writers, ["DefaultOutputSwitch.swift"],
                       "a default-output write appeared outside the one explicit switch")
    }

    /// `AudioObjectSetPropertyData` appears in the app for volume and mute too, so
    /// the write has to be the *default-output* one: both symbols within a few
    /// lines of each other.
    private func writesDefaultOutput(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where line.contains("kAudioHardwarePropertyDefaultOutputDevice") {
            let lower = max(0, index - 10)
            let upper = min(lines.count - 1, index + 10)
            if lines[lower...upper].contains(where: { $0.contains("AudioObjectSetPropertyData") }) {
                return true
            }
        }
        return false
    }

    func testTheAppNeverWritesTheSystemOutputDevice() throws {
        for file in try swiftFiles() {
            let text = code(try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(
                text.contains("kAudioHardwarePropertyDefaultSystemOutputDevice"),
                "\(file.lastPathComponent) mentions the system output device"
            )
        }
    }

    func testTheRemovedQuitRestoreStaysRemoved() throws {
        for file in try swiftFiles() {
            let text = code(try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(text.contains("performCleanup("),
                           "\(file.lastPathComponent) still calls the quit-time default-output restore")
            XCTAssertFalse(text.contains("findDeviceByUID("),
                           "\(file.lastPathComponent) still resolves devices for the quit-time restore")
        }
    }

    func testTheSwitchIsReachableOnlyFromTheDeviceList() throws {
        // One production caller, and it is the menu bar's device list. Anything
        // else — a launch hook, a host-state observer, a notification handler —
        // would be an automatic switch wearing a user-action costume.
        var callers: [String] = []
        for file in try swiftFiles() {
            let text = code(try String(contentsOf: file, encoding: .utf8))
            if text.contains("switchDevice(to:") { callers.append(file.lastPathComponent) }
        }
        XCTAssertEqual(callers, ["MenuBarView.swift"],
                       "the default-output switch must be reachable from the device list only")
    }

    func testVolumeAndEQCodeNeverReachTheSwitch() throws {
        // The product rule is explicit: adjusting volume or EQ is not consent to
        // move the system output.
        for name in ["Services/EQController.swift", "Views/BasicEQView.swift"] {
            let text = code(try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8))
            XCTAssertFalse(text.contains("switchToDevice(") || text.contains("switchDevice("),
                           "\(name) must not reach the default-output switch")
        }

        // `VolumeController` owns the two *different* verbs: volume goes through
        // CoreAudio properties, the output switch goes through `DefaultOutputSwitch`
        // and appears exactly once, in `switchDevice(to:)`.
        let controller = code(try String(
            contentsOf: appSources.appendingPathComponent("Services/VolumeController.swift"),
            encoding: .utf8
        ))
        let calls = controller.components(separatedBy: "switchToDevice(").count - 1
        XCTAssertEqual(calls, 1, "expected one call site, inside switchDevice(to:)")
    }

    func testTheReconnectButtonNoLongerBouncesTheOutput() throws {
        let menu = code(try String(
            contentsOf: appSources.appendingPathComponent("Views/MenuBarView.swift"),
            encoding: .utf8
        ))
        XCTAssertFalse(menu.contains("bounceDevice("),
                       "Reconnect Audio must re-establish the Host's path, not move the default output")
        XCTAssertTrue(menu.contains("requestAudioReconnect()"))

        let controller = code(try String(
            contentsOf: appSources.appendingPathComponent("Services/VolumeController.swift"),
            encoding: .utf8
        ))
        XCTAssertFalse(controller.contains("func bounceDevice"),
                       "the App-side bounce was the trigger for the Host-side one")
    }
}
