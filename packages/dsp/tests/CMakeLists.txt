cmake_minimum_required(VERSION 3.20)

# Enable testing
enable_testing()

# Test executable
add_executable(soundbridge_dsp_tests
    test_main.cpp
    test_biquad.cpp
    test_smoothing.cpp
    test_preset.cpp
    test_engine.cpp
    test_frequency_response.cpp
    test_config_mailbox.cpp
    test_limiter.cpp
    test_buffer_math.cpp
    test_version.cpp
)

# Link against DSP library
target_link_libraries(soundbridge_dsp_tests PRIVATE soundbridge_dsp)

# The library must report the repository's product version, not a number kept in
# sync by hand (audit finding F-20). Read the same VERSION file the library
# derives its project version from, so test and library cannot agree on a stale
# value.
set(SOUNDBRIDGE_PRODUCT_VERSION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../../../VERSION")
if(EXISTS "${SOUNDBRIDGE_PRODUCT_VERSION_FILE}")
    file(READ "${SOUNDBRIDGE_PRODUCT_VERSION_FILE}" SOUNDBRIDGE_EXPECTED_VERSION)
    string(STRIP "${SOUNDBRIDGE_EXPECTED_VERSION}" SOUNDBRIDGE_EXPECTED_VERSION)
else()
    set(SOUNDBRIDGE_EXPECTED_VERSION "${PROJECT_VERSION}")
endif()
target_compile_definitions(soundbridge_dsp_tests PRIVATE
    SOUNDBRIDGE_EXPECTED_VERSION="${SOUNDBRIDGE_EXPECTED_VERSION}"
)

# Include test utilities
target_include_directories(soundbridge_dsp_tests PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/../src
)

# Compiler flags for tests
target_compile_options(soundbridge_dsp_tests PRIVATE
    -Wall -Wextra -Wpedantic
)

# Add test to CTest
add_test(NAME soundbridge_dsp_tests COMMAND soundbridge_dsp_tests)

# Set test properties
set_tests_properties(soundbridge_dsp_tests PROPERTIES
    TIMEOUT 60
    LABELS "unit"
)

message(STATUS "Test suite configured: soundbridge_dsp_tests")
