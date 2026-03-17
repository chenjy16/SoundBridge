# Bridge library CMake configuration
cmake_minimum_required(VERSION 3.20)

# Bridge library (ObjC++)
add_library(soundbridge_dsp_bridge
    SoundBridgeDSPEngine.mm
)

target_include_directories(soundbridge_dsp_bridge
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_SOURCE_DIR}/include
)

target_link_libraries(soundbridge_dsp_bridge
    PUBLIC
        soundbridge_dsp
)

# Enable Objective-C++ and ARC
set_target_properties(soundbridge_dsp_bridge PROPERTIES
    COMPILE_FLAGS "-x objective-c++ -fobjc-arc"
    LINKER_LANGUAGE CXX
)

# Link Foundation framework
target_link_libraries(soundbridge_dsp_bridge
    PUBLIC
        "-framework Foundation"
)

# Install headers
install(FILES
    SoundBridgeDSPEngine.h
    DESTINATION include/soundbridge/bridge
)

# Install library
install(TARGETS soundbridge_dsp_bridge
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
)
