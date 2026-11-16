// Empty C file required by SwiftPM for C targets.
// CSoundBridgeAudio is header-only (all protocol helpers are static inline),
// but SwiftPM's default build engine emits a link input for every C target and
// fails with "Build input file cannot be found: .../CSoundBridgeAudio.o" when
// the target has no translation unit.
