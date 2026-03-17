// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SoundBridgeHost",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "CSoundBridgeAudio",
            path: "Sources/CSoundBridgeAudio",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SoundBridgeHost",
            dependencies: ["CSoundBridgeAudio"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
    ]
)
