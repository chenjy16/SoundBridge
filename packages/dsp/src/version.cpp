/**
 * @file version.cpp
 * @brief Version information for SoundBridge DSP library
 */

#include "soundbridge_dsp.h"

#ifndef SOUNDBRIDGE_DSP_VERSION
#define SOUNDBRIDGE_DSP_VERSION "1.0.0-dev"
#endif

const char* soundbridge_dsp_get_version(void) {
    return SOUNDBRIDGE_DSP_VERSION;
}
