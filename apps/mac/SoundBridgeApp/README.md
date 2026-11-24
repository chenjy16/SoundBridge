# `SoundBridgeApp`

Menu bar app for SoundBridge on macOS. Built with SwiftUI + AppKit.

Last reviewed: 2026-11-24 (1.2.1).

## Purpose

`SoundBridgeApp` is the control plane for SoundBridge:

- Presents onboarding and settings UI.
- Manages EQ and volume state.
- Starts `SoundBridgeHost` when needed.
- Detects the installed HAL driver and tells the user which version the build
  needs; it never installs the driver itself (the PKG does that).

It does not run real-time DSP processing.

## Key Capabilities

- Three EQ macro controls (Bass / Mids / Treble) over a 10-band engine, plus reset.
- First-run onboarding that points at the official PKG and verifies the installed
  driver matches this build.
- Driver protocol gate: an old driver with a new app is reported at launch instead
  of producing silence.
- No automatic update channel in 1.2.1 (`SUPublicEDKey` is empty; `Sparkle.framework`
  is linked but unused).
- Menu bar-only interaction model.

## Prerequisites

- macOS 13 or newer.
- Xcode command line tools (`xcode-select --install`).
- Built host binary at one of the expected host paths (recommended: `packages/host/.build/release/SoundBridgeHost`).
- Driver bundle available for install/update flows (`SoundBridgeDriver.driver` from `packages/driver`).

## Build

```bash
cd apps/mac/SoundBridgeApp
swift build
```

Release build:

```bash
cd apps/mac/SoundBridgeApp
swift build -c release
```

## Run (Development)

Recommended flow from repo root:

```bash
cd packages/host
swift build -c release

cd ../../apps/mac/SoundBridgeApp
swift run
```

If host discovery fails, the app prompts with:

```bash
cd packages/host && swift build -c release
```

## Runtime Behavior

- On first launch, onboarding is shown until completed.
- On normal launch after onboarding, the app runs as a menu bar accessory app.
- The app launches `SoundBridgeHost` if it is not already running.
- On app termination, cleanup runs and host processes are terminated.

## Data and State Paths

- App log: `~/Library/Logs/SoundBridge/app.log`
- Driver install target: `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver`
- EQ / volume defaults: `com.soundbridge.menubar` (`eq_default_*` keys)

## Developer Flags and Environment

- `--reset-onboarding`: clears onboarding state before app startup.
- `SOUNDBRIDGE_ROOT`: optional root path used during host binary discovery.
- `ENABLE_LIQUID_GLASS=1`: forces `LIQUID_GLASS_AVAILABLE` compile define in `Package.swift`.

## Troubleshooting

- Host not found:
  - Build host in `packages/host` and relaunch app.
- Driver missing or out of date:
  - Install the PKG; the app never installs the driver itself. An old driver with
    a new app shows a protocol-mismatch notice instead of producing audio.
OBS-1 (volume/mute persistence) and OBS-2 (EQ persistence) were addressed in
1.2.1. See [`RELEASE_NOTES.md`](../../../docs/RELEASE_NOTES.md) §3.1–§3.2 for the
fixes and [`Known-Limitations.md`](../../../docs/risks/Known-Limitations.md) for
remaining validation gaps.
