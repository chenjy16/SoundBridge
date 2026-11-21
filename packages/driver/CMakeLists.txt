cmake_minimum_required(VERSION 3.20)
project(SoundBridgeDriver VERSION 1.2.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Build type
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# macOS: build universal binary (arm64 + x86_64)
if(APPLE)
    if(NOT CMAKE_OSX_ARCHITECTURES)
        set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "Build architectures" FORCE)
    endif()
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version" FORCE)
    message(STATUS "Building for macOS architectures: ${CMAKE_OSX_ARCHITECTURES}")
endif()

# Compiler flags
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG")
set(CMAKE_CXX_FLAGS_DEBUG "-O0 -g -fsanitize=address")

# libASPL
add_subdirectory(vendor/libASPL)

# SoundBridge Driver sources
set(DRIVER_SOURCES
    src/Plugin.cpp
)

# Create the driver bundle
add_library(SoundBridgeDriver MODULE ${DRIVER_SOURCES})

target_include_directories(SoundBridgeDriver
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/include
        ${CMAKE_CURRENT_SOURCE_DIR}/vendor/libASPL/include
        ${CMAKE_CURRENT_SOURCE_DIR}/vendor/libASPL/src
)

target_link_libraries(SoundBridgeDriver
    PRIVATE
        libASPL
        "-framework CoreAudio"
        "-framework CoreFoundation"
        "-framework AudioToolbox"
)

# Bundle properties
set_target_properties(SoundBridgeDriver PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "driver"
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist
    OUTPUT_NAME "SoundBridgeDriver"
)

# Install to /Library/Audio/Plug-Ins/HAL/
# This requires sudo - use install script instead
# install(TARGETS SoundBridgeDriver
#     BUNDLE DESTINATION "/Library/Audio/Plug-Ins/HAL"
# )

message(STATUS "SoundBridge HAL Driver configured")
message(STATUS "  Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "  Multi-format: YES (int16/24/32, float32/64)")
message(STATUS "  Multi-rate: YES (44.1-192 kHz)")
message(STATUS "  Multi-channel: YES (1-8 channels)")
message(STATUS "  Install manually to: /Library/Audio/Plug-Ins/HAL/")

# ============================================================================
# Testing
# ============================================================================
#
# Every suite under tests/ is self-contained: it includes src/*.hpp, the C++
# standard library and POSIX, and provides its own main(). None of them reference
# libASPL or CoreAudio, so each one is a plain executable. Linking the bundle's
# libraries here would make the tests need a HAL runtime they do not use, and
# would tie them to a driver installation they are supposed to run without.
#
#   cmake -S packages/driver -B <scratch>
#   cmake --build <scratch> --target soundbridge_driver_control_protocol_tests
#   ctest --test-dir <scratch>

option(SB_DRIVER_BUILD_TESTS "Build the driver's C++ unit tests" ON)

if(SB_DRIVER_BUILD_TESTS)
    enable_testing()

    add_executable(soundbridge_driver_control_protocol_tests   tests/ControlProtocolTests.cpp)
    add_executable(soundbridge_driver_producer_token_tests     tests/ProducerTokenTests.cpp)
    add_executable(soundbridge_driver_mapping_retirement_tests tests/MappingRetirementTests.cpp)

    foreach(suite_target IN ITEMS
        soundbridge_driver_control_protocol_tests
        soundbridge_driver_producer_token_tests
        soundbridge_driver_mapping_retirement_tests
    )
        # The suites include their subjects by relative path, so these are not
        # strictly required; they keep an include of "RFSharedAudio.h" or a
        # sibling header resolving if one is ever added.
        target_include_directories(${suite_target} PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}/include
            ${CMAKE_CURRENT_SOURCE_DIR}/src
        )

        # Not -Wpedantic: RFSharedAudio.h is a C11 header shared with the HAL
        # runtime (_Atomic, flexible array members) and every suite includes it,
        # so -Wpedantic reports ~228 C-extension notes about the protocol header
        # rather than about the test code. Those cannot be fixed here without
        # changing the ABI header itself.
        target_compile_options(${suite_target} PRIVATE
            -Wall -Wextra
        )

        add_test(NAME ${suite_target} COMMAND ${suite_target})
        set_tests_properties(${suite_target} PROPERTIES
            TIMEOUT 60
            LABELS "unit"
        )

        message(STATUS "Test suite configured: ${suite_target}")
    endforeach()
endif()
