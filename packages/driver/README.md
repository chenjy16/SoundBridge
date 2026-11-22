# SoundBridge HAL Driver

A CoreAudio HAL (Hardware Abstraction Layer) plugin for macOS that creates virtual proxy output devices. When an app sends audio to a proxy device, the driver writes it into shared memory. The host process reads from shared memory, runs DSP, and renders to the real hardware device.

The driver runs inside `coreaudiod` (not as a standalone process). When installed at `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver`, macOS loads it as a system audio plugin.

## How it works

```
Application audio
    |
    v
+--------------------------+
| macOS CoreAudio (HAL)    |
| routes output to proxy   |
+-----------+--------------+
            |
            v
+--------------------------+
| SoundBridgeDriver          |
| (this plugin)            |
|                          |
| OnWriteMixedOutput()     |
| - format conversion      |
| - sample rate conversion |
| - ring buffer write      |
+-----------+--------------+
            | shared memory (mmap)
            | /tmp/soundbridge-<ownerUID>-<deviceUID>
            v
+--------------------------+
| SoundBridgeHost            |
| - ring buffer read       |
| - DSP processing         |
| - hardware output        |
+--------------------------+
```

## Files

| File | Purpose |
|---|---|
| `src/Plugin.cpp` | Driver runtime logic: plugin factory, device creation/removal, IO handling, health checks |
| `include/RFSharedAudio.h` | Shared memory protocol and ring buffer helpers |
| `CMakeLists.txt` | Build config for `SoundBridgeDriver.driver` |
| `Info.plist` | Bundle metadata, factory UUID, bundle identifier (`com.soundbridge.driver`) |
| `install.sh` | Installs `build/SoundBridgeDriver.driver` to `/Library/Audio/Plug-Ins/HAL/` |
| `uninstall.sh` | Removes the installed driver bundle |
| `VERSION` | Driver version (`2.0.8`) |
| `vendor/libASPL/` | Third-party C++ wrapper around CoreAudio HAL plugin APIs |

`include/RFSharedAudio.h` is intentionally kept in sync with:
`packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h`

## Entry point

```cpp
extern "C" void* SoundBridgeDriverPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID)
```

If `typeUUID` matches `kAudioServerPlugInTypeUUID`, this function lazily creates global driver state and returns the plugin reference. The factory UUID is `B3F04000-8F04-4F84-A72E-B2D4F8E6F1DA` (declared in `Info.plist`).

## Device lifecycle

The driver does not hardcode proxy devices. It reconciles desired devices from a host-written control file.

### Control file: `/tmp/soundbridge-devices.txt`

Format per line:

```
DeviceName|DeviceUID
```

`MonitorControlFile()` calls `SyncDevices()` every ~1 second (10x 100ms sleeps).

`SyncDevices()` behavior:

- Add proxy device when UID exists in control file, heartbeat for that UID is fresh, and UID is not in cooldown.
- Remove proxy device when UID is no longer desired (missing from file or heartbeat stale).
- Enforce a 10-second cooldown (`DEVICE_COOLDOWN_SEC`) after removal to prevent rapid add/remove cycling.

### Proxy device creation

`CreateProxyDevice()` creates one output-only proxy device with:

- Name: `"<OriginalName> (SoundBridge)"`
- UID: `"<OriginalUID>-soundbridge"`
- Manufacturer: `"SoundBridge"`
- Default format: 48 kHz, 2 channels
- Mixing enabled
- Stream controls via `AddStreamWithControlsAsync(aspl::Direction::Output)`
- IO/control callbacks handled by `UniversalAudioHandler`

## Audio path

### OnStartIO

When the first client starts IO, the handler:

1. Opens `/tmp/soundbridge-<ownerUID>-<sanitized-deviceUID>`
2. Maps shared memory with `PROT_READ | PROT_WRITE` and `MAP_SHARED`
3. Validates protocol version, sample rate, and channel count
4. Sets `driver_connected = 1`
5. Pre-allocates conversion buffers (`4096 * RF_MAX_CHANNELS` frames)
6. Prefills half the ring with silence to reduce cold-start underruns
7. Retries up to 15 times with exponential backoff (30ms base, capped growth) if connection is not ready

IO clients are reference-counted; `OnStopIO` disconnects shared memory when the last client stops.

### OnWriteMixedOutput

This callback runs on the audio IO thread for each buffer. It:

1. Updates `driver_heartbeat` and `driver_connected` via `rf_update_driver_heartbeat()`
2. Reads current stream `AudioStreamBasicDescription`
3. Rebuilds conversion/resampler state on format changes (sample rate/channel count)
4. Converts input to interleaved float32
5. Compensates timestamp gaps/overlaps by prepending silence or skipping frames
6. Applies linear-interpolation sample-rate conversion when needed
7. Applies adaptive drift compensation around target ring fill
8. Writes frames with `rf_ring_write()` and logs periodic stats every 30 seconds

Implemented input conversion paths in `ConvertToFloat32Interleaved()`:

- Float32 (interleaved and non-interleaved)
- Signed Int16
- Signed Int24 (packed 3-byte)
- Signed Int32

## Shared memory layout (`RFSharedAudio`)

Defined in `include/RFSharedAudio.h` (the single source; the copies under the host,
app and dsp include paths must stay byte-identical, checked by
`tools/sync_shared_header.sh --check`).

In this build, `RF_AUDIO_PROTOCOL_VERSION` is `0x00020200` and
`sizeof(RFSharedAudio)` is **320 bytes**; `audio_data[]` begins at offset 320.

### Header sections

The table below lists section offsets only. The field-by-field definition, the
memory orders and the admission rules live in the header itself — do not copy them
into prose that can drift.

| Offset | Section | Notes |
|---|---|---|
| 0 | Protocol info | `protocol_version`, `header_size` |
| 8 | Negotiated format | sample rate, channels, format, byte sizes |
| 28 | Ring configuration | `ring_capacity_frames` (power of two), `ring_duration_ms` |
| 36 | Capability flags | `RF_CAP_*` bitmasks |
| 48 | Timing and sync | `creation_timestamp`, `format_change_counter` |
| 64 | Ring indices | `write_index` (producer), `read_index` (consumer) |
| 80 | Statistics | written/read frames, overrun, underrun, format mismatch |
| 120 | Status flags | connected flags, driver/host heartbeats |
| 144 | Volume / mute | `volume_scalar` (0.0–1.0), `mute_state` |
| 152 | EQ control | `eq_sequence` SeqLock + 48-byte `eq_snapshot` |
| 204 | Volume state model | `volume_mode`, `state_initialized`, `state_revision`, `underrun_frames` |
| 228 | Reserved | 28 bytes, kept at a fixed offset so growth cannot swallow the admission block |
| 256 | Admission | `admission_state` @256, `admission_epoch` @264, `producer_owner_token` @272, `admission_claim_seq` @280, `_reserved2[32]` @288 |
| 320 | `audio_data[]` | flexible array member, must stay last |

Layout is asserted at compile time (`static_assert`) and in both C11 and C++17 by
`tools/check_protocol_layout.sh`. Adding or reordering a field requires bumping
`RF_AUDIO_PROTOCOL_VERSION` and re-syncing all four header copies.

### Total mapped size

```
sizeof(RFSharedAudio) + (ring_capacity_frames * channels * bytes_per_sample)
```

Example at 48 kHz, 2 channels, float32, 100 ms (in this build, capacity is rounded
up to 8192 frames, giving the 65856-byte mapping seen at runtime):
`320 + (8192 * 2 * 4) = 65856` bytes.

### Ring buffer behavior

Single producer (driver) and single consumer (host), with monotonically increasing 64-bit indices.

- Overflow (`used + write > capacity`): advance `read_index` and increment `overrun_count`
- Underrun on host read: host emits silence and increments `underrun_count`

`rf_ring_write()` accepts float32 input and stores samples in negotiated shared format. `rf_ring_read()` outputs float32 for host-side processing.

## Health monitoring

Current liveness checks are applied during proxy-device sync (not in the per-buffer IO callback path):

- `HostHeartbeatFresh()` maps `/tmp/soundbridge-<ownerUID>-<deviceUID>` read-only, tracks `host_heartbeat` changes, and treats heartbeat as stale after 15 seconds with no change (`HEARTBEAT_TIMEOUT_SEC` in `Plugin.cpp`).
- `SyncDevices()` only keeps/adds devices with fresh heartbeat state; stale entries are skipped and existing stale devices are removed.

`UniversalAudioHandler` also includes `IsHealthy()` and `AttemptRecovery()` helpers for shared-memory/file/ring validation, but they are not currently called from `OnWriteMixedOutput()`.

## Heartbeat protocol

- Driver calls `rf_update_driver_heartbeat()` on each `OnWriteMixedOutput` callback.
- Host calls `rf_update_host_heartbeat()` on a timer (`DispatchSourceTimer` in host code, default 1s interval).

A host heartbeat with no observed change for 15 seconds is treated as stale by `HostHeartbeatFresh()`. The timeout is longer than the Host's 1 s heartbeat interval because the Host may be descheduled or swapping; the driver only needs to distinguish "alive" from "gone", and removing a device is disruptive.

## Building

Requirements:

- macOS (HAL driver target)
- CMake >= 3.20
- C++17 toolchain

```sh
cd packages/driver
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Output bundle: `build/SoundBridgeDriver.driver`

Debug build (AddressSanitizer enabled by project flags):

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
```

## Installing

```sh
cd packages/driver
./install.sh
sudo killall coreaudiod
```

Notes:

- `install.sh` expects `./build/SoundBridgeDriver.driver` to exist.
- Script prompts for admin rights (`sudo`) internally for copy/ownership changes.
- Install target: `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver`
- Restarting `coreaudiod` is required for load/unload and interrupts audio briefly.

## Uninstalling

```sh
cd packages/driver
./uninstall.sh
sudo killall coreaudiod
```

## Logging

- `os_log` subsystem: `com.soundbridge.driver`
- Fallback file log: `/tmp/soundbridge-driver-debug.log`

Example unified log query:

```sh
log show --predicate 'subsystem == "com.soundbridge.driver"' --last 5m
```

## Troubleshooting

| Symptom | Check |
|---|---|
| No proxy devices appear | Confirm host is running and `/tmp/soundbridge-devices.txt` exists |
| `OnStartIO` fails after retries | Confirm shared memory files exist: `ls /tmp/soundbridge-*` |
| Audio dropouts | Inspect overrun/underrun stats in logs |
| Driver not loading | Verify install path and restart `coreaudiod` |
| Stale proxy devices | Remove stale `/tmp/soundbridge-devices.txt` entry source and restart host/`coreaudiod` |

## Constants

| Constant | Value |
|---|---|
| `DEFAULT_SAMPLE_RATE` | 48000 |
| `DEFAULT_CHANNELS` | 2 |
| `HEALTH_CHECK_INTERVAL_SEC` | 3 (defined; helper currently not invoked from callback loop) |
| `HEARTBEAT_INTERVAL_SEC` | 1 (defined; driver heartbeat is currently callback-driven) |
| `HEARTBEAT_TIMEOUT_SEC` | 15 |
| `STATS_LOG_INTERVAL_SEC` | 30 |
| `DEVICE_COOLDOWN_SEC` | 10 |
| `RF_MAX_CHANNELS` | 8 |
| `RF_RING_DURATION_MS_DEFAULT` | 100 |
| `RF_AUDIO_PROTOCOL_VERSION` | `0x00020200` |
