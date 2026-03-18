import Foundation
import CoreAudio
import AudioToolbox
import CSoundBridgeAudio
import CSoundBridgeDSP
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "AudioRenderer")

class AudioRenderer {
    private let memoryManager: SharedMemoryManager
    private let proxyManager: ProxyDeviceManager
    private var didLogRenderInfo = false
    private var debugRenderCount: Int = 0
    private var testTonePhase: Float = 0
    private var tempBuffer: [Float] = []
    private let useTestTone: Bool
    private var dspEngine: OpaquePointer?

    // Gain Stage state
    private var currentGain: Float = -1.0  // negative = uninitialized, snap on first frame
    private let smoothingCoeff: Float = 0.995  // ~10ms at 48kHz

    // EQ state
    private var lastEQSnapshot = RFEQSnapshot()
    private var presetApplied = false

    init(
        memoryManager: SharedMemoryManager,
        proxyManager: ProxyDeviceManager
    ) {
        self.memoryManager = memoryManager
        self.proxyManager = proxyManager
        self.useTestTone = (ProcessInfo.processInfo.environment["RF_TEST_TONE"] == "1")
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
    }

    /// Update DSP engine sample rate when physical device changes.
    /// Called from AudioEngine when a sample rate mismatch is detected.
    func updateSampleRate(_ sampleRate: UInt32) {
        guard let engine = dspEngine else { return }
        let result = soundbridge_dsp_set_sample_rate(engine, sampleRate)
        if result == SOUNDBRIDGE_OK {
            print("[AudioRenderer] DSP sample rate updated to \(sampleRate)Hz")
        } else {
            print("[AudioRenderer] Failed to update DSP sample rate (error: \(result.rawValue))")
        }
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

    private func render(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        if !didLogRenderInfo {
            didLogRenderInfo = true
            let numBuffers = Int(bufferList.pointee.mNumberBuffers)
            var sizes: [UInt32] = []
            for i in 0..<numBuffers {
                let buf = UnsafeMutableAudioBufferListPointer(bufferList)[i]
                sizes.append(buf.mDataByteSize)
            }
            print("[AudioRenderer] First render: frames=\(frameCount) buffers=\(numBuffers) sizes=\(sizes)")
        }

        let sharedMem: UnsafeMutablePointer<RFSharedAudio>?

        if let activeUID = proxyManager.activeProxyUID {
            sharedMem = memoryManager.getMemory(for: activeUID)
        } else {
            sharedMem = memoryManager.getFirstMemory()
        }

        guard let mem = sharedMem else {
            outputSilence(bufferList: bufferList, frameCount: frameCount)
            return
        }

        let channelCount = Int(bufferList.pointee.mNumberBuffers)
        let needed = Int(frameCount) * channelCount
        if tempBuffer.count < needed {
            tempBuffer = [Float](repeating: 0, count: needed)
        } else {
            for i in 0..<needed {
                tempBuffer[i] = 0
            }
        }
        let framesRead: UInt32

        if useTestTone {
            let sampleRate = Float(SoundBridgeConfig.activeSampleRate)
            let freq: Float = 440.0
            let phaseInc = (2.0 * Float.pi * freq) / sampleRate
            for i in 0..<Int(frameCount) {
                let sample = sin(testTonePhase) * 0.2
                for ch in 0..<channelCount {
                    tempBuffer[i * channelCount + ch] = sample
                }
                testTonePhase += phaseInc
                if testTonePhase > 2.0 * Float.pi {
                    testTonePhase -= 2.0 * Float.pi
                }
            }
            framesRead = frameCount
        } else {
            framesRead = rf_ring_read(mem, &tempBuffer, frameCount)
        }

        // === EQ Processing ===
        if let engine = dspEngine, framesRead > 0 {
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

            // Process audio through DSP (in-place on tempBuffer)
            tempBuffer.withUnsafeMutableBufferPointer { bufPtr in
                soundbridge_dsp_process_interleaved(engine, bufPtr.baseAddress!, bufPtr.baseAddress!, framesRead)
            }
        }

        // === Gain Stage (Linear Passthrough) ===
        // macOS volumeScalar is already perceptually mapped (Weber-Fechner),
        // so we use it directly as the physical gain — no additional curve.
        let volumeScalar = rf_load_volume_scalar(mem)
        let isMuted = rf_load_mute_state(mem) != 0
        let sampleCount = Int(framesRead) * channelCount

        let targetGain: Float = (isMuted || volumeScalar <= 0.0) ? 0.0 : volumeScalar

        // Snap to target on first frame to avoid startup fade artifact
        if currentGain < 0.0 {
            currentGain = targetGain
        }

        if targetGain == 0.0 {
            // Mute / zero volume: hard silence, no smoothing tail
            currentGain = 0.0
            for i in 0..<sampleCount {
                tempBuffer[i] = 0
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
                    tempBuffer[i * channelCount + ch] *= currentGain
                }
            }
        }

        if debugRenderCount < 5 || (debugRenderCount % 500 == 0) {
            debugRenderCount += 1
            if sampleCount > 0 {
                var maxAbs: Float = 0
                for i in 0..<sampleCount {
                    let v = abs(tempBuffer[i])
                    if v > maxAbs { maxAbs = v }
                }
                print("[AudioRenderer] Debug: framesRead=\(framesRead) maxAbs=\(String(format: "%.6f", maxAbs)) gain=\(String(format: "%.4f", currentGain)) volumeScalar=\(String(format: "%.4f", volumeScalar)) muted=\(isMuted)")
            } else {
                print("[AudioRenderer] Debug: framesRead=0")
            }
        } else {
            debugRenderCount += 1
        }

        deinterleave(
            source: tempBuffer,
            bufferList: bufferList,
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

    private func outputSilence(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buf in buffers {
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<min(count, Int(frameCount)) {
                data[i] = 0
            }
        }
    }

    private func deinterleave(
        source: [Float],
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        framesRead: UInt32,
        totalFrames: UInt32
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let channelCount = buffers.count

        for (ch, buf) in buffers.enumerated() {
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let capacity = Int(buf.mDataByteSize) / MemoryLayout<Float>.size

            // 写入已读帧
            for i in 0..<min(Int(framesRead), capacity) {
                let srcIndex = i * channelCount + ch
                data[i] = srcIndex < source.count ? source[srcIndex] : 0
            }

            // 剩余帧填零
            for i in Int(framesRead)..<min(Int(totalFrames), capacity) {
                data[i] = 0
            }
        }
    }
}
