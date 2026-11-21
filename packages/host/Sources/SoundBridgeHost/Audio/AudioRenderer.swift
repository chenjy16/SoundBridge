import Foundation
import Darwin
import CoreAudio
import AudioToolbox
import CSoundBridgeAudio
import CSoundBridgeDSP
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "AudioRenderer")

/// Per-callback diagnostics that may not allocate, log or block.
///
/// The audio callback records into this box and a control thread reads it out;
/// nothing is formatted on the audio thread.
///
/// P3 Batch 1.5: the storage is a C11-atomic struct in
/// `RFRealtimeTelemetry.c`, not an `os_unfair_lock` around Swift properties.
/// The lock used to be taken on every callback that carried an underrun, which
/// is exactly the common case while nothing is playing — so "only the error
/// path locks" was not true. A lock can be held by a preempted control thread
/// for an unbounded time, and a short critical section says nothing about how
/// long a waiter waits. Every note call is now one lock-free
/// read-modify-write with no owner to wait for.
final class RenderDiagnostics {
    struct FirstPass {
        var frames: UInt32
        var channels: Int
        var bytes: [UInt32]
    }

    struct Snapshot {
        var firstPass: FirstPass?
        var memoryUnavailable: UInt64
        var capacityExceeded: UInt64
        var channelMismatch: UInt64
        var underrunFrames: UInt64
        var silenceFallbacks: UInt64
        var dspBypassed: Bool
    }

    /// Allocated once; `nil` only when `calloc` failed, in which case the
    /// callback records nothing rather than not running.
    private let counters: OpaquePointer?

    init() {
        counters = rf_rt_counters_create()
    }

    deinit {
        if let counters {
            rf_rt_counters_destroy(counters)
        }
    }

    /// True when every counter is lock-free on this platform.
    var isLockFree: Bool {
        rf_rt_counters_is_lock_free(counters) != 0
    }

    /// Called once, from the first callback. REALTIME-SAFE.
    func recordFirstPass(frames: UInt32, buffers: UnsafeMutableAudioBufferListPointer) {
        var bytes = (UInt32(0), UInt32(0), UInt32(0), UInt32(0))
        for (index, buffer) in buffers.enumerated() where index < 4 {
            switch index {
            case 0: bytes.0 = buffer.mDataByteSize
            case 1: bytes.1 = buffer.mDataByteSize
            case 2: bytes.2 = buffer.mDataByteSize
            default: bytes.3 = buffer.mDataByteSize
            }
        }
        // Stack tuple + rebound pointer: the callback may not allocate, and a
        // Swift Array here would be a malloc on the IO thread.
        var packed = (bytes.0, bytes.1, bytes.2, bytes.3)
        withUnsafePointer(to: &packed) { pointer in
            pointer.withMemoryRebound(to: UInt32.self, capacity: 4) { rebounded in
                rf_rt_counters_record_first_pass(
                    counters, frames, UInt32(buffers.count), rebounded, 4)
            }
        }
    }

    /// REALTIME-SAFE.
    func noteMemoryUnavailable() {
        rf_rt_counters_note_refusal(counters, RF_RT_REFUSAL_MEMORY_UNAVAILABLE)
    }

    /// REALTIME-SAFE.
    func noteCapacityExceeded() {
        rf_rt_counters_note_refusal(counters, RF_RT_REFUSAL_CAPACITY_EXCEEDED)
    }

    /// REALTIME-SAFE.
    func noteChannelMismatch() {
        rf_rt_counters_note_refusal(counters, RF_RT_REFUSAL_CHANNEL_MISMATCH)
    }

    /// REALTIME-SAFE.
    func noteUnderrun(frames: UInt32) {
        rf_rt_counters_note_underrun(counters, frames)
    }

    /// REALTIME-SAFE. A silence block that was not one of the three refusals.
    func noteSilenceFallback() {
        rf_rt_counters_note_silence_fallback(counters)
    }

    /// Control thread only: allocates the array the callback is not allowed to.
    func snapshot(dspBypassed: Bool) -> Snapshot {
        var raw = rf_rt_render_snapshot()
        rf_rt_counters_read(counters, &raw)

        let firstPass: FirstPass?
        if raw.first_pass_recorded != 0 {
            let bytes: [UInt32] = [
                raw.first_pass_bytes.0, raw.first_pass_bytes.1,
                raw.first_pass_bytes.2, raw.first_pass_bytes.3,
            ]
            firstPass = FirstPass(
                frames: raw.first_pass_frames,
                channels: Int(raw.first_pass_channels),
                bytes: Array(bytes.prefix(Int(raw.first_pass_channels)))
            )
        } else {
            firstPass = nil
        }

        return Snapshot(
            firstPass: firstPass,
            memoryUnavailable: raw.refusals.0,
            capacityExceeded: raw.refusals.1,
            channelMismatch: raw.refusals.2,
            underrunFrames: raw.underrun_frames,
            silenceFallbacks: raw.silence_fallbacks,
            dspBypassed: dspBypassed
        )
    }
}

/// The Host's audio callback.
///
/// Real-time contract (P2 Batch 4): `render(bufferList:frameCount:)` runs on
/// CoreAudio's IO thread and does no allocation, no deallocation, no logging,
/// no file-system work, no DSP construction and no blocking wait. It enters the
/// published mapping through `SharedMemoryManager.enterRenderMemory()` and
/// leaves through `exitRenderMemory()`, which is also what keeps the mmap alive
/// for the whole callback.
class AudioRenderer {
    private let memoryManager: SharedMemoryManager
    private let diagnostics = RenderDiagnostics()
    private var testTonePhase: Float = 0
    private let useTestTone: Bool
    private var dspEngine: OpaquePointer?

    // MARK: - Realtime latency telemetry (P3 Batch 1.5)

    /// Fixed-capacity histogram of callback durations, allocated once.
    ///
    /// One extra `mach_absolute_time()` pair and one atomic increment per
    /// callback: no allocation, no lock, no logging, no retry loop. `nil` only
    /// when `calloc` failed, in which case the callback runs unmeasured rather
    /// than not at all.
    private let latency: OpaquePointer?

    /// `mach_absolute_time` ticks are not nanoseconds on every platform. The
    /// ratio is resolved once here so the callback only does integer maths.
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64

    /// Render-thread-only. Written inside `render()` and read nowhere else.
    ///
    /// It sizes the per-callback budget without asking
    /// `SoundBridgeConfig.activeSampleRate`, which takes a lock a render
    /// callback may not acquire.
    private var renderSampleRate: UInt32

    /// Render-thread-only. Set after the one-time `recordFirstPass`, so the
    /// normal callback path never asks `RenderDiagnostics` for a locked answer.
    /// Before P3 Batch 1.5 every callback acquired that lock just to be told
    /// "already recorded".
    private var firstPassRecordedLocally = false

    /// Control-thread-only drain cursors. Nothing on the IO thread reads them.
    private var reportedObservations: UInt64 = 0
    private var reportedOverBudget: UInt64 = 0
    private var reportedSilence: UInt64 = 0
    private var drainTicks: UInt64 = 0

    /// Sentinel values mirrored from `RFRealtimeTelemetry.h`, which Swift sees
    /// only as constants on an opaque handle.
    private static let emptyBucket: UInt32 = 0xFFFF_FFFF
    private static let overflowBucket: UInt32 = 2048

    // Gain Stage state
    private var currentGain: Float = -1.0  // negative = uninitialized, snap on first frame
    // One-pole smoothing coefficient. 0.995 at 48 kHz is a ~4.2 ms time
    // constant (0.995^199 ~= 1/e), which is why volume-key steps do not click.
    private let smoothingCoeff: Float = 0.995

    // EQ state
    private var lastEQSnapshot = RFEQSnapshot()
    private var presetApplied = false

    // What `drainDiagnostics()` has already written to a log. A fault that
    // repeats every callback must not turn into one line per poll.
    private var reportedFirstPass = false
    private var reportedUnavailable: UInt64 = 0
    private var reportedOversized: UInt64 = 0
    private var reportedMismatch: UInt64 = 0

    // Pre-allocated mixing buffer.
    //
    // Sized from the same frozen helper the Host uses to size the shared-memory
    // ring, at the highest sample rate the HAL path accepts, so "the largest
    // block the callback can be asked for" has a real derivation instead of a
    // guessed constant. Channels are capped at the ABI's own limit (1-8).
    let renderCapacityFrames: Int
    let renderCapacityChannels: Int
    private let renderBuffer: UnsafeMutablePointer<Float>
    private let renderBufferLength: Int

    init(memoryManager: SharedMemoryManager) {
        self.memoryManager = memoryManager
        self.useTestTone = (ProcessInfo.processInfo.environment["RF_TEST_TONE"] == "1")
        self.renderCapacityFrames = SoundBridgeConfig.maxCallbackFrames
        self.renderCapacityChannels = SoundBridgeConfig.maxCallbackChannels
        self.renderBufferLength = renderCapacityFrames * renderCapacityChannels
        self.renderBuffer = UnsafeMutablePointer<Float>.allocate(capacity: renderBufferLength)
        self.renderBuffer.initialize(repeating: 0, count: renderBufferLength)

        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0 {
            // Identity fallback: reporting ticks as nanoseconds is wrong on a
            // platform with a ratio, but it is bounded and visible, whereas a
            // divide-by-zero on the IO thread is neither.
            timebase.numer = 1
            timebase.denom = 1
        }
        self.timebaseNumer = UInt64(timebase.numer)
        self.timebaseDenom = UInt64(timebase.denom)
        self.renderSampleRate = SoundBridgeConfig.activeSampleRate
        self.latency = rf_rt_hist_create()

        self.dspEngine = soundbridge_dsp_create(SoundBridgeConfig.activeSampleRate)

        // Apply initial preset immediately so DSP is always active
        if let engine = dspEngine {
            applyInitialPreset(engine: engine)
            presetApplied = true
        }
    }

    deinit {
        if let engine = dspEngine {
            soundbridge_dsp_destroy(engine)
        }
        if let latency {
            rf_rt_hist_destroy(latency)
        }
        renderBuffer.deinitialize(count: renderBufferLength)
        renderBuffer.deallocate()
    }

    /// Test seam (P2 Batch 4 RT suite): the address of the pre-allocated
    /// scratch buffer.
    ///
    /// A callback that allocated or resized its mixing buffer would show up as a
    /// different address here, so `testContinuousCallbacksReuseTheScratchBuffer`
    /// can assert it instead of reading the source. Production code never calls
    /// this.
    var renderBufferBaseAddress: UnsafeMutablePointer<Float> { renderBuffer }

    /// Control thread view of what the callback recorded.
    ///
    /// Pure: it formats nothing and logs nothing, so it is safe to read from a
    /// test as often as needed. The logging lives in `drainDiagnostics()`.
    func takeDiagnostics() -> RenderDiagnostics.Snapshot {
        diagnostics.snapshot(
            dspBypassed: dspEngine.map { soundbridge_dsp_get_bypass($0) } ?? true
        )
    }

    /// Control thread drain: writes what changed since the previous call.
    ///
    /// This is the only path by which the render path's diagnostics reach a
    /// log. It runs on the connection poll (main queue), never on the IO
    /// thread, and it stays quiet once the counters stop moving. Without a
    /// drain the callback's errors would be recorded and never read: the
    /// silence they produce would look like any other silence.
    func drainDiagnostics() {
        let snapshot = takeDiagnostics()

        if let firstPass = snapshot.firstPass, !reportedFirstPass {
            reportedFirstPass = true
            print(
                "[AudioRenderer] First render: frames=\(firstPass.frames) buffers=\(firstPass.channels) sizes=\(firstPass.bytes)"
            )
        }

        guard snapshot.memoryUnavailable != reportedUnavailable
                || snapshot.capacityExceeded != reportedOversized
                || snapshot.channelMismatch != reportedMismatch else {
            return
        }
        reportedUnavailable = snapshot.memoryUnavailable
        reportedOversized = snapshot.capacityExceeded
        reportedMismatch = snapshot.channelMismatch
        logger.error(
            "Render refused a block: memoryUnavailable=\(snapshot.memoryUnavailable) oversized=\(snapshot.capacityExceeded) channelMismatch=\(snapshot.channelMismatch)"
        )
    }

    // MARK: - Callback latency telemetry (P3 Batch 1.5)

    /// `RF_RT_LATENCY_BUCKET_WIDTH_NS` is 2 us, so the overflow floor is
    /// `RF_RT_LATENCY_BUCKET_COUNT * 2 us` = 16.384 ms. A maximum in the
    /// overflow bucket is reported as that floor, never as a precise value.
    private static let overflowFloorMicroseconds =
        Double(RF_RT_LATENCY_BUCKET_COUNT) * Double(RF_RT_LATENCY_BUCKET_WIDTH_NS) / 1_000.0

    /// Convert ticks to nanoseconds and record one observation.
    ///
    /// RT body. Integer maths only: the timebase ratio was resolved at
    /// construction, so this is one multiply, one divide by a small constant
    /// and one atomic increment. No allocation, no lock, no logging.
    @inline(__always)
    private func recordCallbackDuration(since start: UInt64, frameCount: UInt32) {
        let elapsed = mach_absolute_time() &- start
        let nanoseconds: UInt64
        if timebaseNumer == timebaseDenom {
            nanoseconds = elapsed
        } else {
            nanoseconds = (elapsed / timebaseDenom) * timebaseNumer
                + (elapsed % timebaseDenom) * timebaseNumer / timebaseDenom
        }

        let rate = renderSampleRate == 0 ? SoundBridgeConfig.defaultSampleRate : renderSampleRate
        let budget = UInt64(frameCount) * 1_000_000_000 / UInt64(rate)
        rf_rt_hist_observe(latency, nanoseconds, budget)
    }

    /// Control-thread view of the latency window since construction.
    struct TimingSnapshot {
        var observations: UInt64
        var overBudget: UInt64
        var overBudgetExcessMilliseconds: Double
        var minMicroseconds: Double?
        var p50Microseconds: Double?
        var p95Microseconds: Double?
        var p99Microseconds: Double?
        var maxMicroseconds: Double?
        /// True when `maxMicroseconds` is the lower edge of the overflow bucket:
        /// the real maximum is at least that value, never equal to it.
        var maxIsSaturated: Bool
    }

    private static func microseconds(forBucket bucket: UInt32, upperEdge: Bool) -> Double? {
        guard bucket != emptyBucket, bucket < overflowBucket else { return nil }
        let nanoseconds = upperEdge
            ? rf_rt_hist_bucket_upper_ns(bucket)
            : rf_rt_hist_bucket_lower_ns(bucket)
        return Double(nanoseconds) / 1_000.0
    }

    /// Pure snapshot. Formats nothing and logs nothing, so tests may call it as
    /// often as they like.
    func takeTimingSnapshot() -> TimingSnapshot {
        guard let latency else {
            return TimingSnapshot(
                observations: 0, overBudget: 0, overBudgetExcessMilliseconds: 0,
                minMicroseconds: nil, p50Microseconds: nil, p95Microseconds: nil,
                p99Microseconds: nil, maxMicroseconds: nil, maxIsSaturated: false
            )
        }

        let first = rf_rt_hist_first_bucket(latency)
        let last = rf_rt_hist_last_bucket(latency)
        let saturated = last != Self.emptyBucket && last >= Self.overflowBucket

        return TimingSnapshot(
            observations: rf_rt_hist_observations(latency),
            overBudget: rf_rt_hist_over_budget(latency),
            overBudgetExcessMilliseconds:
                Double(rf_rt_hist_over_budget_excess_ns(latency)) / 1_000_000.0,
            minMicroseconds: Self.microseconds(forBucket: first, upperEdge: false),
            p50Microseconds: Self.microseconds(
                forBucket: rf_rt_hist_quantile_bucket(latency, 5000), upperEdge: true),
            p95Microseconds: Self.microseconds(
                forBucket: rf_rt_hist_quantile_bucket(latency, 9500), upperEdge: true),
            p99Microseconds: Self.microseconds(
                forBucket: rf_rt_hist_quantile_bucket(latency, 9900), upperEdge: true),
            maxMicroseconds: saturated
                ? Self.overflowFloorMicroseconds
                : Self.microseconds(forBucket: last, upperEdge: true),
            maxIsSaturated: saturated
        )
    }

    /// Control thread only: emit one line per window when there is new data.
    ///
    /// Wired to the same connection poll as `drainDiagnostics()`. Without a
    /// production reader the histogram would be the same dead end the P2 Batch
    /// 4 counters were before `drainDiagnostics()` existed: counted on the IO
    /// thread, never printed.
    func drainTiming() {
        drainTicks &+= 1
        let snapshot = takeTimingSnapshot()
        let diagnostics = takeDiagnostics()

        guard snapshot.observations != reportedObservations
                || diagnostics.silenceFallbacks != reportedSilence else { return }

        let overBudgetMoved = snapshot.overBudget != reportedOverBudget
        // One line per poll would be one line per second forever. Report on
        // every fifth poll, and immediately whenever the over-budget count
        // moves, so a fault is never throttled away.
        guard drainTicks % 5 == 0 || overBudgetMoved else { return }

        reportedObservations = snapshot.observations
        reportedOverBudget = snapshot.overBudget
        reportedSilence = diagnostics.silenceFallbacks

        func micro(_ value: Double?) -> String {
            guard let value else { return "n/a" }
            return String(format: "%.1f", value)
        }

        let line = String(
            format: "n=%llu min=%@us p50=%@us p95=%@us p99=%@us max=%@%@us overBudget=%llu excess=%.1fms silence=%llu",
            snapshot.observations,
            micro(snapshot.minMicroseconds),
            micro(snapshot.p50Microseconds),
            micro(snapshot.p95Microseconds),
            micro(snapshot.p99Microseconds),
            snapshot.maxIsSaturated ? ">=" : "",
            micro(snapshot.maxMicroseconds),
            snapshot.overBudget,
            snapshot.overBudgetExcessMilliseconds,
            diagnostics.silenceFallbacks
        )
        logger.notice("Callback timing: \(line, privacy: .public)")
    }

    /// Rebuild the DSP for a new rate. Control thread only.
    ///
    /// `soundbridge_dsp_set_sample_rate` rewrites `sample_rate`, the preamp
    /// smoother, `coeff_transition_samples`, every biquad's coefficients and
    /// the limiter threshold — the same fields
    /// `soundbridge_dsp_process_interleaved` reads on the IO thread.
    ///
    /// P2 Batch 4 sequenced this after `AudioOutputUnitStop` only. That is an
    /// assumption about CoreAudio, not an observation. The guard below adds the
    /// observation: the rebuild is refused unless the render path reports that
    /// no callback is inside it.
    ///
    /// Residual assumption, stated rather than hidden: CoreAudio must not call
    /// the render proc of a stopped output unit. The idle check cannot close
    /// that gap by itself — it proves only that no callback was inside at the
    /// moment of the check.
    @discardableResult
    func updateSampleRate(_ sampleRate: UInt32) -> Bool {
        guard let engine = dspEngine else { return false }
        guard memoryManager.waitForRenderPathIdle(timeout: SoundBridgeConfig.cleanupWaitTimeout) else {
            logger.error(
                "Refusing to rebuild DSP at \(sampleRate) Hz: a render callback is still inside the mapping"
            )
            return false
        }
        let result = soundbridge_dsp_set_sample_rate(engine, sampleRate)
        if result == SOUNDBRIDGE_OK {
            print("[AudioRenderer] DSP sample rate updated to \(sampleRate)Hz")
        } else {
            print("[AudioRenderer] Failed to update DSP sample rate (error: \(result.rawValue))")
        }
        return result == SOUNDBRIDGE_OK
    }

    func createRenderCallback() -> AURenderCallback {
        return { (
            inRefCon,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            ioData
        ) -> OSStatus in
            guard let bufferList = ioData else {
                return noErr
            }

            let renderer = Unmanaged<AudioRenderer>.fromOpaque(inRefCon).takeUnretainedValue()
            renderer.render(bufferList: bufferList, frameCount: inNumberFrames)

            return noErr
        }
    }

    /// The render body. Internal rather than private so the RT-safety tests can
    /// drive it with a real `AudioBufferList` and a real mapping, without
    /// CoreAudio: the callback CoreAudio calls is the same function.
    ///
    /// Everything below this line runs on the IO thread.
    func render(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        // P3 Batch 1.5: one clock read here, one in `recordCallbackDuration`.
        // The `defer` covers every return path, including the three refusal
        // paths, so "the block was refused" does not also mean "unmeasured".
        let started = mach_absolute_time()
        defer { recordCallbackDuration(since: started, frameCount: frameCount) }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let channelCount = buffers.count

        // The first-pass record was the only thing in `RenderDiagnostics` that
        // the normal path used to touch: `hasRecordedFirstPass` took an
        // `os_unfair_lock` on every callback just to answer "already done".
        // The local flag answers it once and then keeps diagnostics off the hot
        // path entirely. Only this renderer writes its own counters, so the two
        // views cannot disagree for longer than the first callback.
        if !firstPassRecordedLocally {
            diagnostics.recordFirstPass(frames: frameCount, buffers: buffers)
            firstPassRecordedLocally = true
        }

        // Capacity guards before anything is written. An oversized block is
        // refused, not truncated: the ring writes `frames * channels` floats
        // and there is nowhere else for them to go.
        guard frameCount <= UInt32(renderCapacityFrames),
              channelCount <= renderCapacityChannels else {
            diagnostics.noteCapacityExceeded()
            diagnostics.noteSilenceFallback()
            outputSilence(buffers: buffers, frameCount: frameCount)
            return
        }

        guard let mem = memoryManager.enterRenderMemory() else {
            diagnostics.noteMemoryUnavailable()
            diagnostics.noteSilenceFallback()
            outputSilence(buffers: buffers, frameCount: frameCount)
            return
        }
        // Balances the entry above; the mapping cannot be released until this
        // runs, which is what makes the raw pointer safe for the whole body.
        defer { memoryManager.exitRenderMemory() }

        // Cache the mapping's own rate for the budget calculation: one load, no
        // lock, and it is the rate the ring is actually running at.
        let mappingRate = mem.pointee.sample_rate
        if mappingRate >= 8_000 { renderSampleRate = mappingRate }

        // The ring buffer's layout decides the interleave of the output. A
        // mapping with a different channel count cannot be deinterleaved into
        // this AudioBufferList, so it is silence rather than noise.
        let ringChannels = Int(mem.pointee.channels)
        guard ringChannels == channelCount, ringChannels <= renderCapacityChannels else {
            diagnostics.noteChannelMismatch()
            diagnostics.noteSilenceFallback()
            outputSilence(buffers: buffers, frameCount: frameCount)
            return
        }

        let needed = Int(frameCount) * channelCount
        renderBuffer.update(repeating: 0, count: needed)

        let framesRead: UInt32

        if useTestTone {
            // The mapping's own rate: reading it costs a load, whereas
            // `SoundBridgeConfig.activeSampleRate` takes a lock.
            let sampleRate = Float(mem.pointee.sample_rate)
            let freq: Float = 440.0
            let phaseInc = (2.0 * Float.pi * freq) / sampleRate
            for i in 0..<Int(frameCount) {
                let sample = sin(testTonePhase) * 0.2
                for ch in 0..<channelCount {
                    renderBuffer[i * channelCount + ch] = sample
                }
                testTonePhase += phaseInc
                if testTonePhase > 2.0 * Float.pi {
                    testTonePhase -= 2.0 * Float.pi
                }
            }
            framesRead = frameCount
        } else {
            // Single-reader call site (Batch 1): the only rf_ring_read caller.
            // Out-param reports the zero-filled (underrun) tail; the underrun
            // bookkeeping itself lives in the ring counters that telemetry reads.
            var zeroFilled: UInt32 = 0
            framesRead = rf_ring_read(mem, renderBuffer, frameCount, &zeroFilled)
            if zeroFilled > 0 {
                diagnostics.noteUnderrun(frames: zeroFilled)
            }
            // A block that carried no audio at all is the fourth way this
            // callback emits silence; counting it keeps "how often did the
            // output contain no signal" a single number.
            if framesRead == 0 {
                diagnostics.noteSilenceFallback()
            }
        }

        // === EQ Processing ===
        // The DSP engine is stereo-only: `soundbridge_dsp_process_interleaved`
        // indexes `i * 2`. Running it on a mono or multi-channel block would
        // read the wrong samples, so it is skipped rather than guessed at.
        if let engine = dspEngine, framesRead > 0, channelCount == 2 {
            var eqSnapshot = RFEQSnapshot()
            rf_load_eq_snapshot(mem, &eqSnapshot)

            // Detect changes from last snapshot and update DSP parameters
            let changed = withUnsafeBytes(of: &eqSnapshot) { newBytes in
                withUnsafeBytes(of: &lastEQSnapshot) { oldBytes in
                    memcmp(newBytes.baseAddress!, oldBytes.baseAddress!, MemoryLayout<RFEQSnapshot>.size) != 0
                }
            }

            if changed {
                withUnsafePointer(to: &eqSnapshot.bands) { ptr in
                    ptr.withMemoryRebound(to: Float.self, capacity: 10) { floatPtr in
                        for i in 0..<10 {
                            soundbridge_dsp_update_band_gain(engine, UInt32(i), floatPtr[i])
                        }
                    }
                }
                soundbridge_dsp_update_preamp(engine, eqSnapshot.preamp)
                soundbridge_dsp_set_bypass(engine, eqSnapshot.bypass)
                lastEQSnapshot = eqSnapshot
            }

            // Process audio through DSP (in-place on the pre-allocated buffer)
            soundbridge_dsp_process_interleaved(engine, renderBuffer, renderBuffer, framesRead)
        }

        // === Gain Stage ===
        // The scalar in shared memory is the taper's input, so the gain must
        // come from VolumeTaper — the same 48 dB Pow2 curve the driver's
        // VolumeControl exposes. Deriving the formula inline here is exactly
        // how the two sides drifted apart by up to ~29 dB before Phase 2.1.
        let volumeScalar = VolumeTaper.sanitize(rf_load_volume_scalar(mem), fallback: 0.0)
        let isMuted = rf_load_mute_state(mem) != 0
        let sampleCount = Int(framesRead) * channelCount

        let targetGain: Float = (isMuted || volumeScalar <= 0.0)
            ? 0.0
            : VolumeTaper.gain(forScalar: volumeScalar)

        // Snap to target on first frame to avoid startup fade artifact
        if currentGain < 0.0 {
            currentGain = targetGain
        }

        if targetGain == 0.0 {
            // Mute / zero volume: hard silence, no smoothing tail
            currentGain = 0.0
            for i in 0..<sampleCount {
                renderBuffer[i] = 0
            }
        } else if targetGain == 1.0 && currentGain > 0.999 {
            // Full volume: bit-perfect passthrough
            currentGain = 1.0
        } else {
            for i in 0..<Int(framesRead) {
                currentGain = currentGain * smoothingCoeff + targetGain * (1.0 - smoothingCoeff)
                // Kill denormals / near-zero residue
                if currentGain < 1.0e-6 { currentGain = 0.0 }
                for ch in 0..<channelCount {
                    renderBuffer[i * channelCount + ch] *= currentGain
                }
            }
        }

        deinterleave(
            source: renderBuffer,
            bufferList: buffers,
            framesRead: framesRead,
            totalFrames: frameCount
        )
    }

    private func applyInitialPreset(engine: OpaquePointer) {
        var preset = soundbridge_preset_t()
        preset.num_bands = 10
        preset.preamp_db = 0.0
        preset.limiter_enabled = true

        // Band 0: lowShelf, 32 Hz, enabled
        preset.bands.0.frequency_hz = 32.0
        preset.bands.0.gain_db = 0.0
        preset.bands.0.q_factor = 0.7
        preset.bands.0.type = SOUNDBRIDGE_FILTER_LOW_SHELF
        preset.bands.0.enabled = true

        // Band 1: lowShelf, 64 Hz, enabled
        preset.bands.1.frequency_hz = 64.0
        preset.bands.1.gain_db = 0.0
        preset.bands.1.q_factor = 0.7
        preset.bands.1.type = SOUNDBRIDGE_FILTER_LOW_SHELF
        preset.bands.1.enabled = true

        // Band 2: lowShelf, 125 Hz, enabled
        preset.bands.2.frequency_hz = 125.0
        preset.bands.2.gain_db = 0.0
        preset.bands.2.q_factor = 0.7
        preset.bands.2.type = SOUNDBRIDGE_FILTER_LOW_SHELF
        preset.bands.2.enabled = true

        // Band 3: peak, 250 Hz, DISABLED
        preset.bands.3.frequency_hz = 250.0
        preset.bands.3.gain_db = 0.0
        preset.bands.3.q_factor = 1.0
        preset.bands.3.type = SOUNDBRIDGE_FILTER_PEAK
        preset.bands.3.enabled = false

        // Band 4: peak, 500 Hz, enabled
        preset.bands.4.frequency_hz = 500.0
        preset.bands.4.gain_db = 0.0
        preset.bands.4.q_factor = 1.2
        preset.bands.4.type = SOUNDBRIDGE_FILTER_PEAK
        preset.bands.4.enabled = true

        // Band 5: peak, 1000 Hz, enabled
        preset.bands.5.frequency_hz = 1000.0
        preset.bands.5.gain_db = 0.0
        preset.bands.5.q_factor = 1.2
        preset.bands.5.type = SOUNDBRIDGE_FILTER_PEAK
        preset.bands.5.enabled = true

        // Band 6: peak, 2000 Hz, DISABLED
        preset.bands.6.frequency_hz = 2000.0
        preset.bands.6.gain_db = 0.0
        preset.bands.6.q_factor = 1.0
        preset.bands.6.type = SOUNDBRIDGE_FILTER_PEAK
        preset.bands.6.enabled = false

        // Band 7: peak, 4000 Hz, DISABLED
        preset.bands.7.frequency_hz = 4000.0
        preset.bands.7.gain_db = 0.0
        preset.bands.7.q_factor = 1.0
        preset.bands.7.type = SOUNDBRIDGE_FILTER_PEAK
        preset.bands.7.enabled = false

        // Band 8: highShelf, 8000 Hz, enabled
        preset.bands.8.frequency_hz = 8000.0
        preset.bands.8.gain_db = 0.0
        preset.bands.8.q_factor = 0.7
        preset.bands.8.type = SOUNDBRIDGE_FILTER_HIGH_SHELF
        preset.bands.8.enabled = true

        // Band 9: highShelf, 16000 Hz, enabled
        preset.bands.9.frequency_hz = 16000.0
        preset.bands.9.gain_db = 0.0
        preset.bands.9.q_factor = 0.7
        preset.bands.9.type = SOUNDBRIDGE_FILTER_HIGH_SHELF
        preset.bands.9.enabled = true

        soundbridge_dsp_apply_preset(engine, &preset)
    }

    private func outputSilence(buffers: UnsafeMutableAudioBufferListPointer, frameCount: UInt32) {
        for buf in buffers {
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<min(count, Int(frameCount)) {
                data[i] = 0
            }
        }
    }

    private func deinterleave(
        source: UnsafePointer<Float>,
        bufferList: UnsafeMutableAudioBufferListPointer,
        framesRead: UInt32,
        totalFrames: UInt32
    ) {
        let buffers = bufferList
        let channelCount = buffers.count

        for (ch, buf) in buffers.enumerated() {
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let capacity = Int(buf.mDataByteSize) / MemoryLayout<Float>.size

            // Both ends are clamped before the ranges are formed: a buffer
            // shorter than the block (framesRead > capacity) would otherwise
            // build an empty-but-inverted range and trap on the IO thread.
            let readable = min(Int(framesRead), capacity)
            let total = min(Int(totalFrames), capacity)

            // 写入已读帧
            for i in 0..<readable {
                data[i] = source[i * channelCount + ch]
            }

            // 剩余帧填零
            if readable < total {
                for i in readable..<total {
                    data[i] = 0
                }
            }
        }
    }
}
