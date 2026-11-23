import XCTest
import Darwin
import AudioToolbox
@testable import SoundBridgeHost
import CSoundBridgeAudio

// MARK: - Render-path gap coverage: sample-rate change and render-path churn
//
// Two rows of the realtime scenario matrix had no test at all, and both are
// about the Host renderer rather than the engine:
//
//   1. `AudioRenderer.updateSampleRate` refuses to rebuild while a render
//      callback is inside the mapping, and a refused rebuild changes nothing.
//      Before this file there was no test naming `updateSampleRate` anywhere in
//      the repository, so the gate could have been deleted without a red suite.
//   2. A sample-rate change reaches the audio thread at the *next block
//      boundary*, not at the call, which is the property the mailbox hand-off
//      is supposed to give and which only an end-to-end assertion can show.
//   3. Repeated creation/teardown of the render path over one live mapping.

final class HostRealtimeIntegrationTests: XCTestCase {

    private var sandbox: URL!
    private var manager: SharedMemoryManager!
    private let uid = "rt-integration-0"
    private let frames: UInt32 = 256

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let directory = sandbox!
        manager = SharedMemoryManager(
            sessionID: UUID(),
            pathForUID: { "\(directory.path)/soundbridge-\($0)" }
        )
    }

    override func tearDownWithError() throws {
        if manager != nil {
            manager.cleanup()
            manager = nil
        }
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private final class OutputBuffers {
        let list: UnsafeMutableAudioBufferListPointer
        private let storage: [UnsafeMutableRawPointer]

        init(channels: Int, frames: Int) {
            self.list = AudioBufferList.allocate(maximumBuffers: channels)
            list.count = channels
            var storage: [UnsafeMutableRawPointer] = []
            for index in 0..<channels {
                let raw = UnsafeMutableRawPointer.allocate(
                    byteCount: frames * MemoryLayout<Float>.size,
                    alignment: MemoryLayout<Float>.alignment
                )
                raw.initializeMemory(as: Float.self, repeating: 0, count: frames)
                storage.append(raw)
                list[index] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                    mData: raw
                )
            }
            self.storage = storage
        }

        deinit {
            for raw in storage { raw.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    private func makeMapping(_ device: String) throws -> UnsafeMutablePointer<RFSharedAudio> {
        XCTAssertEqual(manager.createMemory(for: device, persistence: NoPersistence()), .created)
        let mem = try XCTUnwrap(manager.getMemory(for: device))
        // The render gate publishes one mapping; name this one so both tests in
        // this file (which share a manager) read the mapping they feed.
        manager.setPreferredRenderUID(device)
        manager.publishVolumeState(for: device, scalar: 1.0, muted: false)

        var snapshot = RFEQSnapshot()
        snapshot.bypass = false
        rf_store_eq_snapshot(mem, &snapshot)

        // Start empty: these tests are about lifecycle, not about signal.
        let capacity = Int(mem.pointee.ring_capacity_frames)
        let channels = Int(mem.pointee.channels)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity * channels)
        defer { scratch.deallocate() }
        var zeroFilled: UInt32 = 0
        while rf_ring_read(mem, scratch, UInt32(capacity), &zeroFilled) > 0 {}
        return mem
    }

    private func feed(
        _ mem: UnsafeMutablePointer<RFSharedAudio>, frames: UInt32
    ) {
        let channels = Int(mem.pointee.channels)
        let staging = UnsafeMutablePointer<Float>.allocate(capacity: Int(frames) * channels)
        defer { staging.deallocate() }
        for index in 0..<Int(frames) * channels { staging[index] = 0.25 }
        var dropped: UInt32 = 0
        _ = rf_ring_write_unchecked(mem, staging, frames, &dropped)
    }

    // MARK: - 1. A rebuild is refused while the render path is busy

    func testSampleRateChangeIsRefusedWhileTheRenderPathIsInsideTheMapping() throws {
        let device = "\(uid)-busy"
        let mem = try makeMapping(device)
        let renderer = AudioRenderer(memoryManager: manager)
        let output = OutputBuffers(channels: Int(mem.pointee.channels), frames: Int(frames))

        feed(mem, frames: frames)
        renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: frames)
        let appliedRate = renderer.takeDiagnostics().dsp.sampleRate
        XCTAssertEqual(appliedRate, mem.pointee.sample_rate,
                       "the engine starts at the mapping's rate")

        // A lease held for the whole call is exactly the state a callback is in:
        // `waitForRenderPathIdle` cannot see it go to zero, so the rebuild must be
        // refused rather than raced.
        let lease = try XCTUnwrap(manager.enterRenderMemory())
        XCTAssertNotNil(lease)
        XCTAssertFalse(
            renderer.updateSampleRate(96_000),
            "a rebuild must be refused while a render callback holds the mapping")
        XCTAssertEqual(renderer.takeDiagnostics().dsp.sampleRate, appliedRate,
                       "a refused rebuild must not change the applied rate")

        manager.exitRenderMemory()

        XCTAssertTrue(renderer.updateSampleRate(96_000), "an idle render path may rebuild")
        XCTAssertEqual(renderer.takeDiagnostics().dsp.sampleRate, appliedRate,
                       "the new rate is published, not applied, until the next block boundary")

        feed(mem, frames: frames)
        renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: frames)
        let report = renderer.takeDiagnostics()
        XCTAssertEqual(report.dsp.sampleRate, 96_000,
                       "the audio thread adopts the new rate at its next block boundary")
        XCTAssertEqual(report.memoryUnavailable, 0)
    }

    // MARK: - 2. Repeated start/stop over one live mapping

    func testRepeatedRenderPathCreationAndTeardownKeepsTheMappingUsable() throws {
        let device = "\(uid)-churn"
        let mem = try makeMapping(device)
        let channels = Int(mem.pointee.channels)

        for iteration in 0..<50 {
            let output = OutputBuffers(channels: channels, frames: Int(frames))
            let renderer = AudioRenderer(memoryManager: manager)
            feed(mem, frames: frames)
            renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: frames)

            let snapshot = renderer.takeDiagnostics()
            XCTAssertEqual(snapshot.memoryUnavailable, 0, "iteration \(iteration)")
            XCTAssertEqual(snapshot.channelMismatch, 0, "iteration \(iteration)")
            XCTAssertEqual(snapshot.dsp.framesProcessed, UInt64(frames), "iteration \(iteration)")
            // `renderer` goes out of scope here: the engine, the histogram and the
            // scratch buffer are released while the mapping outlives all of them.
        }

        // The mapping still serves a fresh render path afterwards.
        let renderer = AudioRenderer(memoryManager: manager)
        let output = OutputBuffers(channels: channels, frames: Int(frames))
        feed(mem, frames: frames)
        renderer.render(bufferList: output.list.unsafeMutablePointer, frameCount: frames)
        XCTAssertEqual(renderer.takeDiagnostics().dsp.framesProcessed, UInt64(frames))
    }
}

private final class NoPersistence: VolumeStatePersisting {
    func loadIfPresent(uid: String) -> DeviceVolumeState? { nil }
    func save(uid: String, volume: Float, muted: Bool) {}
}
