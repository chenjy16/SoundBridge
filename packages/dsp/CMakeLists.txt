cmake_minimum_required(VERSION 3.20)

# The DSP library ships inside SoundBridge.app and reports its identity through
# soundbridge_dsp_get_version(), so it follows the product version in the
# repository VERSION file instead of keeping a number of its own (audit finding
# F-20: it used to say 1.0.0 while the release said 1.2.0). Nothing consumes the
# DSP as an independently versioned library, so there is no compatibility
# boundary that a separate semver would protect.
#
# The VERSION file is read before project() so the project version - and with it
# the value compiled into version.cpp - is derived rather than hand-maintained.
set(SOUNDBRIDGE_PRODUCT_VERSION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../../VERSION")
if(EXISTS "${SOUNDBRIDGE_PRODUCT_VERSION_FILE}")
    file(READ "${SOUNDBRIDGE_PRODUCT_VERSION_FILE}" SOUNDBRIDGE_PROJECT_VERSION)
    string(STRIP "${SOUNDBRIDGE_PROJECT_VERSION}" SOUNDBRIDGE_PROJECT_VERSION)
endif()

if(NOT SOUNDBRIDGE_PROJECT_VERSION MATCHES "^[0-9]+(\\.[0-9]+)*$")
    # Building the DSP outside the repository (or with an empty VERSION file).
    # 0.0.0 is deliberately not a release number: it cannot be mistaken for one.
    message(WARNING
        "No product version in ${SOUNDBRIDGE_PRODUCT_VERSION_FILE}; "
        "the library will report 0.0.0.")
    set(SOUNDBRIDGE_PROJECT_VERSION "0.0.0")
endif()

project(soundbridge_dsp VERSION ${SOUNDBRIDGE_PROJECT_VERSION} LANGUAGES C CXX)

# C++ standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# C standard
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Build type
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# Compiler flags
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    # NOTE: -ffast-math is deliberately NOT used. It enables a bundle
    # (-funsafe-math-optimizations, -freciprocal-math, -fassociative-math,
    # -fno-signed-zeros, -fno-trapping-math, -ffinite-math-only,
    # -fno-honor-nans/infinities) whose individual members cannot be fully
    # restored afterwards: appending -fno-finite-math-only only brings back
    # std::isfinite, leaving reciprocal substitution and reassociation active.
    # The DSP relies on std::isfinite (biquad / limiter guards, preset
    # validation) and on a stable, reproducible transfer function, so plain
    # -O3 is used. -fno-math-errno is safe and well understood: it only stops
    # the compiler from maintaining errno for math functions, it does not
    # change any computed value.
    add_compile_options(
        -Wall
        -Wextra
        -Wpedantic
        -Wno-unused-parameter
        $<$<CONFIG:Release>:-O3>
        $<$<CONFIG:Release>:-fno-math-errno>
        $<$<CONFIG:Debug>:-g>
        $<$<CONFIG:Debug>:-O0>
        $<$<CONFIG:Debug>:-fsanitize=address>
    )

    # Link sanitizer in debug mode
    if(CMAKE_BUILD_TYPE STREQUAL "Debug")
        add_link_options(-fsanitize=address)
    endif()
endif()

# ============================================================================
# Sanitizer builds
# ============================================================================
# SOUNDBRIDGE_DSP_SANITIZE=thread|address|undefined instruments the whole DSP
# tree. Two constraints make this a dedicated configuration rather than a flag
# you can bolt onto an existing build directory:
#
#  1. Sanitizers are single-architecture. The default macOS build is a universal
#     binary (arm64;x86_64) and ThreadSanitizer refuses to instrument one, so
#     the architecture list is forced down to the host architecture here, before
#     the APPLE block below gets a chance to set the universal default.
#  2. Debug hardcodes -fsanitize=address (above). Asking for a different
#     sanitizer on top of that produces conflicting runtimes, so Debug is
#     rejected outright.
#
# Usage:
#   cmake -S packages/dsp -B build-tsan \
#         -DCMAKE_BUILD_TYPE=RelWithDebInfo -DSOUNDBRIDGE_DSP_SANITIZE=thread
#   cmake --build build-tsan --target soundbridge_dsp_tests
#   ./build-tsan/tests/soundbridge_dsp_tests
set(SOUNDBRIDGE_DSP_SANITIZE "" CACHE STRING
    "Sanitizer for the DSP build (empty, address, thread, undefined)")

if(SOUNDBRIDGE_DSP_SANITIZE)
    if(CMAKE_BUILD_TYPE STREQUAL "Debug")
        message(FATAL_ERROR
            "Debug already hardcodes -fsanitize=address. Build sanitizer "
            "variants with -DCMAKE_BUILD_TYPE=RelWithDebInfo.")
    endif()

    set(CMAKE_OSX_ARCHITECTURES "${CMAKE_HOST_SYSTEM_PROCESSOR}"
        CACHE STRING "Build architectures" FORCE)

    add_compile_options(
        -fsanitize=${SOUNDBRIDGE_DSP_SANITIZE}
        -fno-omit-frame-pointer
        -g
    )
    add_link_options(-fsanitize=${SOUNDBRIDGE_DSP_SANITIZE})

    message(STATUS "Sanitizer: ${SOUNDBRIDGE_DSP_SANITIZE} "
                   "(architecture forced to ${CMAKE_OSX_ARCHITECTURES})")
endif()

# macOS specific: build universal binary (arm64 + x86_64)
if(APPLE)
    if(NOT CMAKE_OSX_ARCHITECTURES)
        set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "Build architectures" FORCE)
    endif()
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version" FORCE)
    message(STATUS "Building for macOS architectures: ${CMAKE_OSX_ARCHITECTURES}")

    # Per-architecture optimization flags using Apple Clang's -Xarch_ prefix
    add_compile_options(-Xarch_arm64 -mcpu=apple-m1)
    add_compile_options(-Xarch_x86_64 -msse4.2)
endif()

# ============================================================================
# SoundBridge DSP Library
# ============================================================================

# Public headers
set(PUBLIC_HEADERS
    include/soundbridge_types.h
    include/soundbridge_dsp.h
)

# Source files
set(SOURCES
    src/engine.cpp
    src/biquad.cpp
    src/smoothing.cpp
    src/preset.cpp
    src/limiter.cpp
    src/version.cpp
)

# Create static library
add_library(soundbridge_dsp STATIC
    ${SOURCES}
    ${PUBLIC_HEADERS}
)

# Include directories
target_include_directories(soundbridge_dsp
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

# Compiler definitions
target_compile_definitions(soundbridge_dsp PRIVATE
    SOUNDBRIDGE_DSP_VERSION="${PROJECT_VERSION}"
)

# Platform-specific settings
if(APPLE)
    # Link Accelerate framework for optimized math
    target_link_libraries(soundbridge_dsp PRIVATE "-framework Accelerate")
endif()

# ============================================================================
# Testing
# ============================================================================

option(BUILD_TESTS "Build unit tests" ON)

if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

# ============================================================================
# Objective-C++ Bridge (macOS/iOS)
# ============================================================================

option(BUILD_BRIDGE "Build Objective-C++ bridge for Swift" ON)

if(BUILD_BRIDGE AND APPLE)
    add_subdirectory(bridge)
endif()

# ============================================================================
# Tools
# ============================================================================

option(BUILD_TOOLS "Build command-line tools" ON)

if(BUILD_TOOLS)
    add_subdirectory(tools)
endif()

# ============================================================================
# Installation (optional)
# ============================================================================

install(TARGETS soundbridge_dsp
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)

install(FILES ${PUBLIC_HEADERS}
    DESTINATION include/soundbridge
)

# ============================================================================
# Summary
# ============================================================================

message(STATUS "")
message(STATUS "SoundBridge DSP Configuration:")
message(STATUS "  Version: ${PROJECT_VERSION}")
message(STATUS "  Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "  C++ standard: ${CMAKE_CXX_STANDARD}")
message(STATUS "  Build tests: ${BUILD_TESTS}")
if(APPLE)
    message(STATUS "  macOS architectures: ${CMAKE_OSX_ARCHITECTURES}")
    message(STATUS "  macOS deployment target: ${CMAKE_OSX_DEPLOYMENT_TARGET}")
    message(STATUS "  Build ObjC++ bridge: ${BUILD_BRIDGE}")
endif()
message(STATUS "  Self-contained: RBJ biquad implementation (no external DSP libs)")
message(STATUS "")
