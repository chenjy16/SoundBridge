// SwiftPM-compatibility translation unit for this C target.
//
// The protocol helpers in `include/RFSharedAudio.h` are all `static inline`, so
// this target once needed a translation unit only because SwiftPM's default
// build engine emits a link input for every C target and fails with
// "Build input file cannot be found: .../CSoundBridgeAudio.o" when the target
// has none. It stays empty now that `RFRealtimeTelemetry.c` provides a real
// one: removing it would make the target depend on that file continuing to
// exist, and the cost of keeping it is one empty object.
