/**
 * @file version.cpp
 * @brief Version information for SoundBridge DSP library
 */

#include "soundbridge_dsp.h"

// CMake injects the repository's product version. The fallback only applies to a
// non-CMake build (a hand-written compile command), and 0.0.0 is deliberately
// not something that can be mistaken for a release number.
#ifndef SOUNDBRIDGE_DSP_VERSION
#define SOUNDBRIDGE_DSP_VERSION "0.0.0-dev"
#endif

const char* soundbridge_dsp_get_version(void) {
    return SOUNDBRIDGE_DSP_VERSION;
}
