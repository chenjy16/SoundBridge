# SoundBridge Host

`SoundBridgeHost` is the background audio process used by SoundBridge on macOS.
It discovers physical output devices, creates shared memory endpoints for the HAL driver, runs DSP, and renders audio to the selected physical device.

## What It Does

- Enumerates physical output devices (excluding SoundBridge/Netcat and virtual/aggregate devices)
- Validates candidate devices (active channels, display-audio jack status, format/rate checks)
- Chooses an operating sample rate at startup from the current/selected physical device
- Creates one shared-memory file per physical device (`/tmp/soundbridge-<ownerUID>-<sanitized-deviceUID>`)
- Writes the driver control file (`/tmp/soundbridge-devices.txt`)
- Starts heartbeat updates for driver/host health signaling
- Starts a CoreAudio HAL output unit and renders `ring buffer -> DSP -> hardware`
- Forwards proxy volume/mute changes to the physical device behind it
- Monitors device list/default output changes and sleep/wake recovery hooks
- Never changes the system default output; that switch belongs to the user and the App

## Architecture

```
SoundBridgeHost
  |- DeviceDiscovery      (enumerate + validate physical devices)
  |- DeviceRegistry       (tracks devices, writes /tmp/soundbridge-devices.txt)
  |- SharedMemoryManager  (creates /tmp/soundbridge-<ownerUID>-<deviceUID>, heartbeat timer)
  |- ProxyDeviceManager   (proxy<->physical mapping, default-output ownership, volume/mute forwarding)
  |- AudioRenderer        (reads ring buffer, runs EQ/gain inline in the callback, writes output buffers)
  |- AudioEngine          (HAL output unit setup/start/stop/switch)
  |- DeviceMonitor        (CoreAudio listeners for device/default-output changes)
  |- HostInstanceLock     (single-instance guard)
  |- SleepWakeMonitor     (IOKit notifications and wake recovery)
```

## Runtime Flow

Startup sequence in `main.swift` (the `[Step N]` prefixes are the ones the process prints):

1. Acquires the single-instance lock; a second Host exits before creating or unlinking anything
2. Ensures app support/log directories exist
3. Installs signal handlers and starts sleep/wake monitoring
4. Enumerates physical output devices and records validation status
5. Registers device/default-output listeners (and the CoreAudio-rebuild recovery hooks)
6. Resolves the preferred device and reads its nominal sample rate, then sets `SoundBridgeConfig.activeSampleRate`
7. Creates shared memory for every device and publishes `/tmp/soundbridge-devices.txt` only once all mappings are available
8. Starts the host heartbeat timer
9. Waits for the driver's proxy device with a bounded deadline instead of a fixed sleep
10. Resolves the proxy route without touching the system default output
11. Adopts the committed volume state already written into the mapping
12. Sets up and starts the HAL output unit (DSP runs inline in the render callback)

Shutdown path (`ShutdownSequence`, ordered and run-once):

- Stops the heartbeat and the audio engine, then removes the HAL property listeners
- Removes the control file and waits for the driver to detach before unmapping shared memory
- Leaves the system default output exactly where the user put it
- Leaves `coreaudiod` running (policy: no automatic audio-daemon restart)

## Device and Sample Rate Behavior

- Supported nominal sample rates are snapped to one of:
  `44100, 48000, 88200, 96000, 176400, 192000`.
- The operating sample rate is chosen at startup from the resolved physical output device.
- Device changes move the Host's own render route (`AudioEngine.switchDevice`); the system default output is never written, and not every switch rebuilds the whole pipeline.

## Paths and IPC

- Control file: `/tmp/soundbridge-devices.txt`
- Shared memory per device: `/tmp/soundbridge-<ownerUID>-<sanitized-deviceUID>`

## Key Configuration (`Constants.swift`)

| Setting | Value / Meaning |
|---|---|
| `activeSampleRate` | Runtime-selected sample rate |
| `defaultSampleRate` | Fallback/default sample rate (48000) |
| `defaultChannels` | 2 |
| `defaultFormat` | `RF_FORMAT_FLOAT32` |
| `defaultDurationMs` | 100 |
| `heartbeatInterval` | 1.0s |
| `deviceWaitTimeout` | 2.0s |
| `proxyDiscoveryTimeout` | 5.0s |
| `cleanupWaitTimeout` | 1.2s |
| `physicalDeviceSwitchDelay` | 0.5s |
| `wakeRecoveryDelay` | 1.5s |

## Build

```bash
cd packages/host
swift build -c release
```

## Run

```bash
cd packages/host
./start_host.sh
```

`start_host.sh` launches `.build/release/SoundBridgeHost` when available, otherwise `.build/debug/SoundBridgeHost`.

## Logging

The host logs to stdout/stderr using step-oriented messages from `main.swift` and component-specific prefixes (for example `[AudioEngine]`, `[DeviceMonitor]`, `[Heartbeat]`, `[Cleanup]`).

## Dependencies

- `CSoundBridgeAudio` (shared memory/ring-buffer C interface)
- `CSoundBridgeDSP` (DSP C API)
- Apple frameworks: `CoreAudio`, `AudioToolbox`, `CoreFoundation`, `IOKit`
