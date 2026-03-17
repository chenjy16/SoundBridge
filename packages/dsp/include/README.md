# packages/dsp/include/

Public C API headers for the SoundBridge DSP library.

## Files

- `soundbridge_dsp.h` - Engine lifecycle, parameter control, audio processing
- `soundbridge_types.h` - POD types, enums, structs

## Design

Stable C ABI for cross-language compatibility:
- No C++ templates or exceptions
- POD types only
- Explicit array sizes
- Thread-safety documented per function

Safe for consumption from C, Objective-C++, and Swift.
