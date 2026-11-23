# SoundBridge — Hardware Realtime Validation Readiness Assessment

**Phase:** F1 of F0–F2 (inspection and preparation only)
**Status:** assessment complete; **no hardware realtime validation has been run**
**Software integration verdict, unchanged:** `PASS — SOFTWARE INTEGRATION VERIFIED; HARDWARE REALTIME VALIDATION PENDING`

This document answers one question: *can a genuine, human-supervised CoreAudio
hardware validation be executed on this machine, and what exactly is missing
before it can be?*

Everything here was obtained with read-only means: `AudioObjectGetPropertyData`
from a separate observer process, `log show`/`log stream` queries, `plist` and
`lipo` reads, `pgrep`, and directory listings. No device setting, routing
decision, process, service, driver, or log configuration was changed. See §8 for
the command ledger.

---

## 1. Environment inventory

Captured **2026-11-23T07:09:42Z** by
`build/hwvalidate/sb-hw-validate inventory` (raw output:
`build/hwvalidate/inventory.json`).

| Item | Value | How obtained |
|---|---|---|
| macOS version | 27.2.1 (Build 26B131) | `sw_vers` / `ProcessInfo` |
| Model | Mac16,10 (Mac mini) | `hw.model` |
| Architecture | arm64 (Apple M4), binaries are universal `x86_64 arm64` | `uname -m`, `lipo -info` |
| Logical cores | 10 | `ProcessInfo.processorCount` |
| Memory | 16 GB | `hw.memsize` |
| Free disk (at capture) | ~125 GiB | `df -h /` |

### 1.1 Physical and virtual audio devices

UIDs are reported verbatim. They are stable across reboots and are what the
harness and the runbook use; display names are shown only for the operator.

| # | Name | Transport | UID | Channels | Rates (Hz) | IO buffer range | Current frames | Deadline @ current format |
|---|---|---|---|---|---:|---|---:|---:|
| 1 | **PHL 279M1RV** (default output) | HDMI | `410C54C2-0000-0000-051F-0103803C2278` | 2 | 32000, 44100, 48000 | 15–4096 | 512 | 10666.7 µs |
| 2 | LG ULTRAGEAR+ | DisplayPort | `1E6D4678-0000-0000-0424-0104C5462778` | 8 | 32000, 44100, 48000, 96000, 192000 | 15–2304 | 512 | 10666.7 µs |
| 3 | BlackHole 16ch | virtual | `BlackHole16ch_UID` | 16 | 8000 … 768000 | 15–4096 | 512 | 10666.7 µs |
| 4 | Mac mini扬声器 | built-in | `BuiltInSpeakerDevice` | 2 | 44100, 48000, 88200, 96000 | 15–4096 | 512 | 10666.7 µs |
| 5 | 多输出设备 | aggregate | `~:AMS2_StackedOutput:0` | 2 | 8000 … 768000 | 15–4096 | 512 | 10666.7 µs |

**Default output at capture:** PHL 279M1RV, UID
`410C54C2-0000-0000-051F-0103803C2278`, `kAudioDevicePropertyNominalSampleRate`
= 48000, `kAudioDevicePropertyBufferFrameSize` = 512, 2 output channels,
`kAudioDevicePropertyDeviceIsRunning` = false in the observer process while
`kAudioDevicePropertyDeviceIsRunningSomewhere` = true — i.e. **another process
currently has that device open**, which is expected on a machine that is playing
something. No SoundBridge device appears in this list (§2.2).

**Default input at capture (inventory only):** BlackHole 16ch,
`BlackHole16ch_UID`. Recorded because the runbook requires it, and because it is
a virtual device: nothing may be inferred from it about the output path.

**Active output format:** 48000 Hz / 512 frames / 2 channels on the default
output. "Active" here means the device's current nominal rate and frame size as
CoreAudio reports them, not a preference or a saved setting.

### 1.2 Device-set assumptions that must not be inherited

* `kAudioDevicePropertyBufferFrameSize` is the device's **current** IO buffer, so
  reading it is legitimate evidence. `kAudioDevicePropertyBufferFrameSizeRange`
  is the *allowed range*; it is not evidence of the active size. Both are
  recorded separately above and in the harness result.
* The sample rate is read from `kAudioDevicePropertyNominalSampleRate` **and**
  from the first output stream's `kAudioStreamPropertyPhysicalFormat` /
  `kAudioStreamPropertyVirtualFormat`. Where the two disagree the stream format
  wins, and the harness records both so the disagreement is visible rather than
  silently resolved.
* No value above was derived from a configuration file, a preference, or a
  preset.

### 1.3 Fallback output for recovery

The runbook needs a physical device that does **not** depend on the SoundBridge
driver, so that the operator can restore audible output if the test goes wrong.
Candidates present on this machine:

| Candidate | Suitable as fallback | Why |
|---|---|---|
| Mac mini扬声器 (`BuiltInSpeakerDevice`) | **yes** | built-in, independent of HDMI/DP, present even if the display sleeps |
| PHL 279M1RV (`410C54C2-…`) | yes | this is the current default, so restoring to it is the least surprising outcome |
| LG ULTRAGEAR+ (`1E6D4678-…`) | yes | independent second display path |
| BlackHole 16ch | no | virtual; produces no audible output, so it cannot prove restoration |
| 多输出设备 | no | aggregate; its membership can change underneath the test |

**Recommendation:** restore to whichever device the operator recorded as the
original default (currently PHL 279M1RV), using `BuiltInSpeakerDevice` only as
the audible sanity check when the display path is itself suspect.

---

## 2. SoundBridge installation and runtime inventory

### 2.1 Driver

| Item | Value |
|---|---|
| Bundle path | `/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver` |
| `CFBundleIdentifier` | `com.soundbridge.driver` |
| Version | 1.2.0 (`CFBundleShortVersionString`) |
| Architectures | universal `x86_64 arm64` |
| Shared-memory protocol | `RF_AUDIO_PROTOCOL_VERSION` = `0x00020200` (131584), header 320 bytes, `audio_data` at offset 320 |
| Loaded by | coreaudiod, visible as process `Core Audio Driver (SoundBridgeDriver.driver)` (pid 48806 at capture) |

The driver is **installed and loaded**. That is a statement about the HAL plugin
being resident in coreaudiod, not about a device existing: the proxy device is
only created while a Host publishes a mapping (§2.3).

### 2.2 CoreAudio device enumeration

**No SoundBridge device is currently enumerated.** The device list in §1.1
contains five devices and none of them is the proxy. This is the expected state,
because the proxy is driven by a control file and a shared-memory mapping that
only exist while the Host runs:

* `/tmp/soundbridge-devices.txt` (control file, `PathManager.controlFilePath`)
  **does not exist**.
* No `/tmp/soundbridge-<uid>-<deviceUID>` mapping exists (directory listing of
  `/tmp` filtered for `soundbridge` returned nothing).

Consequence: the harness cannot sample driver counters today, and any attempt to
run a collection would (correctly) fail with `NO CORE AUDIO IO OBSERVED` rather
than invent data — verified, see §6.3.

### 2.3 Host

| Item | Value |
|---|---|
| Binary | `/Applications/SoundBridge.app/Contents/MacOS/SoundBridgeHost` (universal, ad-hoc signed) |
| Version | 1.2.0 (matches `VERSION`, `CFBundleShortVersionString`, and the driver) |
| Process state | **not running** (`pgrep` finds no `SoundBridgeHost`) |
| Launch mechanism | spawned as a child process by `SoundBridgeApp` (`HostSupervisor`), not by launchd |
| Single-instance guard | `flock` on `/tmp/soundbridge-host-<uid>.lock` (`RF_INSTANCE_LOCK_PATH_PREFIX`) |
| launchd services | none for SoundBridge (`launchctl list` contains no `soundbridge` label) |
| System extensions | none; the driver is a HAL plugin under `/Library/Audio/Plug-Ins/HAL`, not a `DriverKit`/kext extension |
| App bundle | `/Applications/SoundBridge.app`, `com.soundbridge.menubar` 1.2.0; a second copy exists at `dist/SoundBridge.app` |

The Host writes its mapping, control file, device-state JSON, and heartbeat while
it runs, and removes them on clean shutdown. Because it is not running, none of
those artefacts exist and **no SoundBridge telemetry is being produced at all**
right now.

### 2.4 Installer, uninstaller, and build commands that exist

Read, not executed.

| Purpose | Path |
|---|---|
| Build everything (DSP, driver, Host, App) | `make build` → `tools/build_release.sh` |
| Assemble `dist/SoundBridge.app` | `make bundle` → `tools/create_app_bundle.sh` |
| Ad-hoc sign App/Host/Driver | `make sign` → `tools/codesign.sh` |
| Signature verification | `make verify`, `tools/verify_signatures.sh` |
| DMG | `make dmg` → `tools/create_dmg.sh`, `tools/verify_dmg_contents.sh` |
| Installer PKG (build only) | `tools/build_installer_pkg.sh`, `tools/verify_installer_pkg.sh` |
| Driver install transaction | `tools/sb_install_transaction.sh` (writes to `/Library/Audio/Plug-Ins/HAL`, needs `sudo`) |
| Driver uninstall | `tools/uninstall_driver.sh` (needs `sudo`) |
| Version consistency | `tools/verify_version_consistency.sh`, `tools/check_protocol_layout.sh` |

Note the asymmetry the runbook must respect: `make dmg` replaces the **App** but
cannot replace the **system driver**; driver installation is a separate,
privileged, transactional step that is explicitly out of scope for F0–F2.

### 2.5 Logging, telemetry, and what the Host already exposes

* Subsystem `com.soundbridge.host`, **19 categories**: `AtomicFile`,
  `AudioEngine`, `AudioRenderer`, `CoreAudioRecovery`, `CoreAudioRestart`,
  `DefaultOutput`, `DefaultOutputHAL`, `DegradedRecovery`, `DeviceDiscovery`,
  `DeviceMonitor`, `DeviceRegistry`, `DriverLifecycle`, `HostInstanceLock`,
  `HostLifecycle`, `Main`, `ProxyDeviceManager`, `SharedMemoryManager`,
  `Shutdown`, `VolumePersistence`.
* Timing lines are emitted by `AudioRenderer.drainTiming()`
  (`Audio/AudioRenderer.swift:457`) as
  `logger.notice("Callback timing: \(line, privacy: .public)")` — **public and
  therefore parseable** from outside the process. Format:

  ```
  Callback timing: n=<obs> min=<µs>us p50=<µs>us p95=<µs>us p99=<µs>us max=[>=]<µs>us overBudget=<n> excess=<ms>ms silence=<n> dsp=L<dB>/R<dB>dB pre=L<dB>/R<dB>dB cpu=<%>%
  ```

* Cadence: `drainTiming()` is called once per connection poll
  (`SoundBridgeConfig.connectionPollInterval` = 1.0 s,
  `Constants.swift:94`) and logs **every fifth poll** (~5 s), plus immediately
  whenever `overBudget` moves, so a fault is never throttled away.
* Histogram implementation: `RFRealtimeTelemetry` (C) with
  2 µs buckets (`RF_RT_LATENCY_BUCKET_WIDTH_NS` = 2000, 8192 buckets + 1
  overflow), read on the control thread through
  `AudioRenderer.takeTimingSnapshot()` (`AudioRenderer.swift:419`) using
  `rf_rt_hist_quantile_bucket()` (`RFRealtimeTelemetry.c:136`). The deadline
  used for a sample is computed at record time as
  `frameCount * 1e9 / renderSampleRate` ns (`AudioRenderer.swift:390`), which is
  the correct per-callback deadline — not a fixed 512-frame constant.
* `overBudget` / `overBudgetExcessMilliseconds` come from the same histogram
  (`rf_rt_hist_over_budget`, `rf_rt_hist_over_budget_excess_ns`).
* Driver counters live in the shared mapping and have C readers:
  `rf_get_underrun_count`, `rf_get_underrun_frames`, `rf_get_overrun_count`
  (`RFSharedAudio.h:1574-1584`), plus `rf_get_driver_heartbeat`,
  `rf_get_host_heartbeat`, `rf_get_driver_connected`.

### 2.6 Two Host-side gaps found during inspection

These are findings about the current code, not changes made to it.

1. **`TimingSnapshot` has no p99.9.** It exposes
   `observations / overBudget / overBudgetExcessMilliseconds / min / p50 / p95 /
   p99 / max` only (`AudioRenderer.swift:395-407`). The C side already supports
   an arbitrary percentile (`rf_rt_hist_quantile_bucket(hist, percentile_bp)`), so
   the smallest safe follow-up is **one additional field** computed with
   `rf_rt_hist_quantile_bucket(latency, 9990)` plus one term in the log format
   string. No C change, no protocol change, no allocation, no work added to the
   callback.
2. **Quantiles are cumulative since `AudioRenderer` construction, not per
   window.** `takeTimingSnapshot()` reads the same monotonically growing
   histogram every time; nothing resets it. Per-window *counters*
   (callbacks, `overBudget`, excess, underruns) are recoverable by differencing,
   but per-window *quantiles* are not. Recovering them without touching the
   realtime path would require exposing the bucket counts once per drain so the
   observer can subtract two cumulative snapshots (≈32 KB copied on the control
   thread every ~5 s). This is documented as a limitation rather than
   implemented, because it is a production change.

Also noted: `SharedMemoryManager.swift:681-706` logs
`⚠️ Buffer underrun: +N (total: T) [uid]` with `N` and `T` interpolated **without**
`privacy: .public`, so in the unified log they arrive as `<private>` and cannot
be parsed. The harness therefore reads the counters directly out of the live
mapping instead (§6.2), which is strictly better evidence anyway.

### 2.7 What changed once A1 was approved (launch only)

The inventory above was captured with no Host running. After A1 (launch the App,
nothing else) the following was observed, read-only. It is recorded here because
it settles two questions the pre-launch inventory could only predict.

| Observation | Value |
|---|---|
| Host spawned as a child of the App | yes — `SoundBridgeApp` pid 71605, `SoundBridgeHost` pid 71610 |
| Proxy devices enumerated | **two**: `PHL 279M1RV (SoundBridge)`, `LG ULTRAGEAR+ (SoundBridge)` |
| Proxy device UIDs | `<physicalUID>-soundbridge`, e.g. `410C54C2-0000-0000-051F-0103803C2278-soundbridge` |
| Proxy format | 48000 Hz / 512 frames / 2 ch, `isRunning` false, `isRunningSomewhere` false |
| **Default output after launch** | **unchanged** — still PHL 279M1RV, `410C54C2-…` (the physical device, not the proxy) |
| `/tmp/soundbridge-devices.txt` | present, `#SB-CONTROL 1 <session> 3 501 2` + two device records |
| `/tmp/soundbridge-501-<physicalUID>` | present for both physical devices, 65856 bytes, mode `0666` |
| `/tmp/soundbridge-host-501.lock` | present |
| Host heartbeat | advancing (178 → 259 over ~80 s) |
| `driverConnected` / `driverHeartbeat` | **0 / 0** on both mappings — the driver has not attached, because nothing is playing *into* a proxy |
| `underrunCount` (PHL mapping) | rising (~469 per 5 s polling window) while `driverConnected = 0` |
| Host callback timing | live and genuine: `n` ≈ 93.75/s, `p50` 6 µs, `p99` 10 µs, `max` 322 µs, `overBudget` 0, `silence` ≈ all observations |

Two facts worth carrying into F3:

1. **The mapping is keyed by the physical UID**, while CoreAudio exposes the proxy
   as `<physicalUID>-soundbridge`. Passing the proxy UID to the probe originally
   produced `mapping-not-present`. Both tools now strip the suffix themselves
   (mirroring `ProxyDeviceManager`, `ProxyDeviceManager.swift:263`), and the
   `--device-uid` a runbook reader is told to use is the proxy UID from the device
   list.
2. **`underrunCount > 0` with `driverConnected = 0` is not a dropout.** It is the
   Host's consumer finding an empty ring because no source is attached. The
   underrun counter only becomes meaningful once `driverConnected = 1` and
   playbacks start, which is why the F3 report must pair the counter with the
   connection state at the same timestamp.

The Host's own render callback is already running against the physical device —
that is the normal operating state after launch, produces silence, and is **not**
a hardware validation result: no playback was started, no routing was changed, and
no operator listened.

---

## 3. Observability of the twelve required metrics

Legend for "collectable without changing production code": **yes** = an
out-of-process reader suffices today.

| # | Metric | Source symbol | Collection mechanism | No prod change | Continuous | Timestamps | Realtime impact | Status |
|---|---|---|---|---|:--:|---|:--:|---|
| 1 | Actual sample rate | `kAudioDevicePropertyNominalSampleRate`, `kAudioStreamPropertyPhysicalFormat.mSampleRate` | `AudioObjectGetPropertyData` from observer process | yes | yes (per window + listener) | yes (window start/end, ISO 8601 with ms) | none | **READY** |
| 2 | Actual IO buffer size | `kAudioDevicePropertyBufferFrameSize` | same | yes | yes | yes | none | **READY** |
| 3 | Sample-rate changes | `kAudioDevicePropertyNominalSampleRate` listener | `AudioObjectAddPropertyListenerBlock` in observer, plus bucket-key diff per window | yes | yes | yes (listener callback time) | none | **READY** |
| 4 | Buffer-size changes | `kAudioDevicePropertyBufferFrameSize` listener | same; a change splits the window | yes | yes | yes | none | **READY** |
| 5 | Host callback timing (per-window histogram) | `AudioRenderer.TimingSnapshot` via `drainTiming()` | parse `log show --last 12s --style compact --predicate 'subsystem=="com.soundbridge.host"'` polled every 5 s, filtered to the `SoundBridgeHost` process | yes | yes (~5 s cadence) | yes (log timestamp) | none (log is written on the control thread) | **CORRECTED IN A2–A4** — this row claimed READY at F1 time, and that was wrong: `log stream` into a pipe delivered nothing while the Host was running (block buffering), so the path as described had never worked. `log show --last 12s` polling is the verified replacement (A2–A4 report §12). Remaining limitation unchanged: quantiles are cumulative, per-window deltas exist for counts only; no p99.9 (§2.6) |
| 6 | `overBudget` | `rf_rt_hist_over_budget` → `TimingSnapshot.overBudget` | cumulative value differenced per window | yes | yes | yes | none | **READY** |
| 7 | `overBudgetExcessMilliseconds` | `rf_rt_hist_over_budget_excess_ns` | cumulative value differenced per window | yes | yes | yes | none | **READY** |
| 8 | Driver underruns | `rf_get_underrun_count` / `rf_get_underrun_frames` / `rf_get_overrun_count` | `sb-shm-probe`: read-only `mmap` of the live mapping by a separate process | yes | yes (per window) | yes (sample time) | none | **READY**, but only while a mapping exists. The Host's own log line is **NOT OBSERVABLE** (redacted) |
| 9 | Host restart / recovery | `DeviceMonitor`, `CoreAudioRecovery`, `HostLifecycle` log lines | `log show --last 12s` polling classifiers + operator marker | yes | yes | yes | none | **CORRECTED IN A2–A4** — collection moved off `log stream` for the same block-buffering defect as #5; the polling path is what actually reads these lines. Needs the event to actually happen; absent events are reported as zero observed, never as passing |
| 10 | Device removal / reappearance | `kAudioObjectPropertyDeviceList` listener + `kAudioDevicePropertyDeviceIsAlive` | observer listener + per-window `snapshot(device:)` failure | yes | yes | yes | none | **READY TO DETECT**; **executing** the removal is `REQUIRES USER APPROVAL` |
| 11 | Audible symptoms | human operator | `sb-hw-validate marker --note "..."` appended to `markers.jsonl` | n/a | yes | yes | none | **READY WITH MANUAL ACTION** |
| 12 | Original default output | `kAudioHardwarePropertyDefaultOutputDevice` → device UID | recorded by `inventory` before the test and re-checked after | yes | yes | yes | none | **READY** |

### 3.1 Metrics that remain unobservable

Stated plainly, because the task requires that these never be filled in:

| Metric | Why unobservable | Smallest safe follow-up |
|---|---|---|
| **p99.9 latency** | not exposed by `TimingSnapshot` | add one field using `rf_rt_hist_quantile_bucket(latency, 9990)`; no C or protocol change |
| **Per-window quantiles** | histogram is monotonic since construction; snapshot has no reset and exposes no bucket counts | expose bucket counts per drain so the observer can subtract snapshots |
| **Driver underrun count via the Host log line** | `+N (total: T)` interpolated without `privacy: .public` → `<private>` | mark that one line `.public` — **not needed**, see note |
| **Driver dropout *audibility*** | a counter cannot prove a listener heard nothing | human operator observation (metric 11) |

> Note: the underrun counter itself is observable out-of-band, so the redacted
> log line is a nuisance rather than a blocker. No production change is proposed
> for it.

---

## 4. Feasibility of a hardware test

The eight questions from the task, each classified with the evidence behind it.

| # | Question | Classification | Evidence |
|---|---|---|---|
| 1 | Can the installed driver be used without reinstalling it? | **READY** | driver 1.2.0 is installed at the HAL path, loaded by coreaudiod (pid 48806), protocol matches the installed Host binary; nothing about the test requires a driver write |
| 2 | Can the Host be launched safely without modifying system state? | **READY WITH MANUAL ACTION** | `SoundBridgeHost` is spawned by the App; launching it creates `/tmp/soundbridge-<uid>-<deviceUID>`, `/tmp/soundbridge-devices.txt` and the `device-state.json` under Application Support, which makes the proxy device appear in the device list. That is a *device-list* change, not a routing change; it is reversed by quitting the App/Host, and it must be an explicit operator step, not something the harness does |
| 3 | Does the Host expose sufficient runtime timing telemetry? | **READY**, with two documented gaps | `Callback timing:` public line at ~5 s cadence carries p50/p95/p99/max/overBudget/excess/cpu; **p99.9 and per-window quantiles are NOT OBSERVABLE** (§3.1) |
| 4 | Can real CoreAudio IO callbacks be distinguished from test-fixture callbacks? | **READY** | three independent discriminators, all required: (a) only log lines whose emitting process is `SoundBridgeHost` are accepted (the tuning-forks hazard: `xctest` writes to the same subsystem); (b) `kAudioDevicePropertyDeviceIsRunning(Somewhere)` must be true on the target device; (c) observed callback rate must be within 0.7–1.3 × `sampleRate / frames` — a timer loop cannot satisfy that on a real 512-frame device for 30 minutes |
| 5 | Does the driver expose a reliable underrun counter? | **READY** | `rf_get_underrun_count` / `_frames` / `rf_get_overrun_count` over the live mapping; reads are plain atomic loads from a separate process; verified path derivation matches the driver's own `/tmp/soundbridge-<owner>-<safeUID>` naming. Only available while a mapping exists |
| 6 | Can device removal/reappearance be tested without unsafe operations? | **REQUIRES USER APPROVAL** | it necessarily changes the active output route and relies on the physical device coming back; explicitly out of scope for F0–F2 and listed in §7 |
| 7 | Is a separate physical output device available for recovery and restoration? | **READY** | `BuiltInSpeakerDevice`, plus two display-attached outputs (§1.3) |
| 8 | Can the Mac remain available for a supervised 30-minute test? | **REQUIRES USER APPROVAL** | scheduling, presence, and "don't touch the machine for 30 minutes" are the user's decisions; the harness itself needs nothing else |

### 4.1 Aggregate readiness

| Gate | State |
|---|---|
| Driver installed and loadable | READY |
| Host buildable and launchable | READY (launch is a manual operator step) |
| Genuine-callback proof available | READY |
| Timing telemetry sufficient for a verdict | READY for p50/p95/p99/max/overBudget/excess; **p99.9 unobservable** |
| Driver underrun evidence | READY out-of-band |
| Recovery/restore procedure defined | READY (runbook) |
| Device-removal scenario | REQUIRES USER APPROVAL |
| 30-minute supervised window | REQUIRES USER APPROVAL |

No gate is `NOT READY`. The blockers are approvals and two telemetry fields, not
capability.

---

## 5. What the harness relies on, and what it refuses to do

The prepared harness (§6) is an **out-of-process observer**. It never touches the
render callback and it never synthesizes one. Specifically it will not:

* replay DSP in-process, run a synthetic callback loop, or build a mock
  `AudioBufferList`;
* read a fixture-only ring buffer or fabricate device metadata;
* report a window it did not observe, or report a zero it did not measure;
* start playback, change the default device, install/uninstall anything, or
  restart CoreAudio.

If no genuine Host callback activity is observed, it exits non-zero with
`NO CORE AUDIO IO OBSERVED` and still writes a result file that says so.

---

## 6. Prepared tooling (F2)

Both live under `tools/hardware-validation/`, which follows the repository's
existing convention of one directory per tool family (`tools/poc`, `tools/dmg`).

### 6.1 `sb-hw-validate.swift`

Single-file Swift CLI, four subcommands, no dependencies beyond Foundation /
CoreAudio / AudioToolbox.

```
inventory  --out <file>                     read-only device/format/OS dump
collect    --device-uid <UID> --out-dir <d> [--duration 1800] [--window 10]
                                            observe a live run, write result.json + result.md
           [--cpu-load N]                   H7: start N reversible /usr/bin/yes loops, killed on exit
           [--shm-probe <path>]             path to sb-shm-probe if not next to the binary
report     --results <result.json> [--out <md>]
                                            re-render Markdown, no re-measurement
marker     --out-dir <d> --note "..."       operator timeline entry (merged into the result)
```

Behaviour that matters for honesty:

* Windows are cut by **actual** `(sampleRate, frames)` bucket; a change emits a
  `format-changed` record with old/new values, old/new deadlines and a timestamp,
  and starts a new window. `overBudget` is never summed across two deadlines.
* Callbacks/`overBudget`/excess/underruns are **per-window deltas**; quantiles
  are flagged `quantilesAreCumulative: true` so they cannot be mistaken for
  per-window values.
* Log lines are accepted only if the emitting process is `SoundBridgeHost`; every
  other process on the subsystem is counted in `telemetry.logSources` and
  dropped. (`xctest` runs write to the same subsystem, so this is not
  hypothetical — see §7.1 of the validation report.)
* Driver counters come from `sb-shm-probe`, not from the redacted Host log line.
* The verdict is one of the four task-mandated strings, and a missing required
  metric forces `INCOMPLETE` or `CONDITIONAL PASS` — never `PASS`.

### 6.2 `sb-shm-probe.c`

Read-only `mmap(PROT_READ, MAP_SHARED)` of `/tmp/soundbridge-<owner>-<sanitizedUID>`,
validated with `rf_validate_header()` before any field is read, printing one JSON
line: protocol, header size, sample rate, channels, ring capacity, format,
`driverConnected`, `driverHeartbeat`, `hostHeartbeat`, `underrunCount`,
`underrunFrames`, `overrunCount`. Exit codes: `3` = mapping not present,
`5` = header invalid. It never opens the file for writing and never unlinks it.

### 6.3 Negative verification already performed

| Check | Command | Result |
|---|---|---|
| Toolchain | `swiftc -O -swift-version 5 …` | builds, no warnings |
| Toolchain | `clang -O2 -std=c11 -Wall -Wextra …` | builds, no warnings |
| Probe without a mapping | `sb-shm-probe --uid <UID> --once` | exit 3, `{"error":"mapping-not-present", …}` — does not invent counters |
| Harness with no Host | `sb-hw-validate collect --duration 6 --window 2` | exit 4, `NO CORE AUDIO IO OBSERVED … (log sources seen: none)`, `windowsRecorded: 0`, verdict `INCOMPLETE — REQUIRED HARDWARE EVIDENCE MISSING` |
| Process filter | regex applied to a real `xctest` line and a synthetic `SoundBridgeHost` line | `xctest` rejected, `SoundBridgeHost` accepted |

The third and fourth rows are the important ones: they show the harness refuses
to synthesize a callback stream when nothing is rendering.

---

## 7. Actions that require explicit user approval

Nothing in this list was performed.

| # | Action | Why approval is needed |
|---|---|---|
| A1 | Launch `SoundBridge.app` / `SoundBridgeHost` so the proxy device appears | changes the CoreAudio device list and creates `/tmp` mapping + control file |
| A2 | Select the SoundBridge device as the macOS default output | changes system routing |
| A3 | Start real audio playback through the SoundBridge device | produces real IO and audible output |
| A4 | Run H1–H5, H7 for 30 minutes with the harness attached | consumes the machine, produces audio |
| A5 | Any CPU-load scenario (H7) beyond a short smoke run | deliberately loads a 10-core machine |
| A6 | H8 device removal / re-appearance | changes the active route and depends on the device returning |
| A7 | Install, replace, or uninstall the driver | writes to `/Library/Audio/Plug-Ins/HAL` via `sudo` |
| A8 | Restart coreaudiod or reboot | disrupts all system audio |
| A9 | Change SIP or security settings; approve a system extension | system-wide security change (not needed: the driver is a HAL plugin) |
| A10 | Add the p99.9 field and/or expose bucket counts (production change) | production code change, currently only proposed |
| A11 | Enable private-data logging system-wide to un-redact the underrun line | system-wide log configuration change; **not recommended** — `sb-shm-probe` already covers it |
| A12 | Commit / tag / push any of this work | git write operations |

---

## 8. Command ledger — what was actually executed

All read-only. Nothing in this list changes audio state, services, or files
outside the repository's ignored `build/` directory.

```
git rev-parse --abbrev-ref HEAD ; git rev-parse HEAD ; git status --short
sw_vers ; uname -m ; sysctl -n hw.model hw.memsize hw.ncpu ; df -h /
defaults read /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist CFBundleShortVersionString
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" /Applications/SoundBridge.app/Contents/Info.plist
lipo -info /Applications/SoundBridge.app/Contents/MacOS/SoundBridgeHost
lipo -info /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/MacOS/SoundBridgeDriver
pgrep -fl "SoundBridgeHost|SoundBridge.app|SoundBridgeDriver"
ls /tmp | grep -i soundbridge
launchctl list | grep -i soundbridge
log show --last 3d --predicate 'subsystem == "com.soundbridge.host"' --style compact
build/hwvalidate/sb-hw-validate inventory --out build/hwvalidate/inventory.json
build/hwvalidate/sb-hw-validate collect --device-uid … --duration 6 --window 2   (negative test)
build/hwvalidate/sb-shm-probe --uid … --once                                     (negative test)
```

Commands that were **prepared but deliberately not executed** (they would install,
disrupt, or route) are listed in the runbook, §"Commands that are not run during
F0–F2".

**System state at the end of this assessment is identical to the start:** default
output still PHL 279M1RV, no Host running, no SoundBridge device enumerated, no
driver or service touched, no audio played.
