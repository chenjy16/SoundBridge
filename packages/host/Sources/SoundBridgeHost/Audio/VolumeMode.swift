import Foundation

/// How SoundBridge is allowed to change playback volume for a device.
///
/// 1.2.0 ships with `.software` only.
///
/// `.hardware` is declared now — and mirrored into shared memory as
/// `RF_VOLUME_MODE_HARDWARE` — so the protocol does not need a second ABI
/// change later. No code path selects it in Phase 2.1: Phase 2.0 established
/// that `kAudioLevelControlPropertyDecibelValue` is writable on the devices we
/// probed, which is evidence, not proof that the physical volume responds
/// correctly. That belongs to Phase 2.2 behind a real capability model.
enum VolumeMode: UInt32, Codable, CaseIterable {
    /// Host applies gain in its render callback; the physical device is left
    /// at whatever level it currently sits at.
    case software = 0

    /// Host writes the physical device's dB value directly and renders at
    /// unity gain. Not implemented in 1.2.0.
    case hardware = 1

    /// Value written into `RFSharedAudio.volume_mode`.
    var protocolValue: UInt32 { rawValue }

    init(protocolValue: UInt32) {
        self = VolumeMode(rawValue: protocolValue) ?? .software
    }
}
