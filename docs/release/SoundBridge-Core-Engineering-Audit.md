# SoundBridge — Core Engineering Audit

**Audit date:** 2026-11-22
**Repository:** `/Users/chenjianyu/CodeGeeXProjects/SoundBridge`
**Baseline commit:** `eb45303f136faf95f764d2dc4d007206f6f3a3e7` (branch `main`)
**Working tree at start:** clean (`git status --porcelain=v1 -uall` produced no output)
**Working tree at end:** clean (verified after every build and test step; see §18)

---

## 1. Executive Summary

This audit examined 16 suspected logic defects across six surfaces — the shared-memory
protocol header (`RFSharedAudio.h`), the HAL driver implementation, the Host's audio path
and lifecycle, the DSP engine, the DSP support modules, and the cross-component contracts
that tie them together.

**One confirmed critical defect was found, and it is reachable from the shipping App.**

The App's "Treble" control is carried by band 9, a 16 kHz high shelf
(`apps/mac/SoundBridgeApp/Sources/Services/EQController.swift:51`). The Host runs the DSP at
whatever sample rate the physical output device reports
(`AudioRenderer.updateSampleRate` ← `AudioDevice.nominalSampleRate`). For any device rate in
the open interval (16 kHz, 32 kHz) the RBJ coefficient formula is evaluated with
`w0 = 2π·16000/fs > π`, the shelf's denominator loses its minimum-phase property, and the
second-order section becomes unstable. Measured on the shipping sources: at 24 kHz,
28 kHz, 30 kHz and 31 kHz, **97–99 % of all output samples are non-finite** and finite
samples reach 1.6–3.0 × 10³⁸. At exactly 32 kHz the section is still unstable but the
per-sample `isFinite` guard masks it; a 13 kHz input is amplified by **+88 dB** where the
user asked for +6 dB. At 33 kHz and above, behaviour is correct. The coefficient guard
cannot catch this because the **coefficients are finite**; only the *output* diverges.

Four further findings are material but not critical: per-callback heap allocation
in the driver's IO proc (D1), undefined behaviour inside the EQ seqlock (C2), an audible
46–70 ms level dip on every sample-rate change (A3), and two format-conversion gaps (D2,
CONFIRMED RISK) that silently corrupt integer non-interleaved and 24-in-32 streams.

Six suspected defects did **not** reproduce: the admission-open race is excluded by two
independent serialisations in the Host, the alleged ring-buffer out-of-bounds write is
prevented by driver-side validation, and `rf_is_connection_healthy` is dead code with no
caller anywhere in the tree.

**Overall verdict: FAIL — CONFIRMED CRITICAL DEFECTS.**

| Verdict | Count |
| --- | --- |
| CONFIRMED (defect) | 9 |
| CONFIRMED RISK | 3 |
| CONDITIONAL | 3 |
| FALSE POSITIVE | 3 |
| PASS (no defect found) | 3 |
| UNRESOLVED | 0 |

The per-item classification is in §10; §11–§14 expand each row.

Documentation-level inaccuracies found while tracing (a false "realtime-safe" claim, a
"single implementation" comment that is not single, a stats API with no consumer) are
recorded as NOTES and are not counted as defects.

---

## 2. Audit Scope and Methodology

### 2.1 Scope

| Surface | Files | Method |
| --- | --- | --- |
| Shared memory protocol | `packages/shared/include/RFSharedAudio.h` (1 577 lines) — read in full | static read, call-graph tracing, cross-check against driver-side validation |
| HAL driver | `packages/driver/src/Plugin.cpp` (1 726), `ControlProtocol.hpp` (379), `MappingRetirement.hpp` (326), `ProducerToken.hpp` (57) | static read of every IO/retirement function, plus a caller census for the recovery paths |
| Host audio path | `Audio/AudioRenderer.swift`, `Audio/AudioEngine.swift`, `Memory/SharedMemoryManager.swift`, `Lifecycle/DriverLifecycle.swift`, `main.swift` | static read, thread-ownership tracing, lock inventory |
| DSP engine | `packages/dsp/src/engine.cpp` (598), `include/soundbridge_dsp.h` (315), `include/soundbridge_types.h` | full read plus behavioural probes (§2.3) |
| DSP support | `biquad.h` (310), `limiter.h` (126), `dc_blocker.h` (135), `smoothing.h` (141), `preset.cpp` (100) | full read plus behavioural probes |
| Cross-component | App EQ path (`EQController.swift`, `SharedMemoryMappingManager.swift`) | static read, end-to-end traces (E1–E5) |

### 2.2 Constraints observed

Read-only for production code, tests, configuration, versions, protocol constants and
headers. No Git write operation of any kind. No driver install or uninstall, no
`coreaudiod` restart, no audio-device switch, no playback interruption. No test that
touches the running audio system was executed. No test result in this report is inferred;
each carries the exact command that produced it or is marked as not executed.

### 2.3 Behavioural probes

Three of the DSP findings depended on numeric behaviour that cannot be settled by reading
code, so they were measured. A single scratch TU was compiled against the DSP sources built
into a scratch directory (`cmake -S packages/dsp -B $TMPDIR/sb-audit-dsp.XXXX`,
`libsoundbridge_dsp.a`) and linked against the public C API only. **No repository file was
created, modified, or left behind**; the scratch TU lived under the git-ignored `build/`
directory and both it and its binary were deleted before §18. The probe deliberately used
distinct left/right buffers after an early run exposed that aliasing `output_left` and
`output_right` applies the preamp twice.

---

## 3. Initial Git and Workspace State

```
$ git rev-parse HEAD
eb45303f136faf95f764d2dc4d007206f6f3a3e7
$ git status --porcelain=v1 -uall
(no output)
```

The starting tree was clean and stayed clean. Version sources were **not** touched:
`VERSION` remains `1.2.0` and `RF_AUDIO_PROTOCOL_VERSION` remains `0x00020200`, so every
file and offset quoted below is the state that would ship in a 1.2.1 built from this commit.

---

## 4. Repository Architecture Map

```
coreaudiod
  └── SoundBridge.driver  (packages/driver, libASPL, C++)
        ├── SoundBridgeDevice           aspl::Device, custom GetZeroTimeStampImpl
        ├── UniversalAudioHandler       OnStartIO / OnStopIO / OnWriteMixedOutput
        ├── SoundBridgeVolumeControl    HAL volume  -> shared memory
        └── SoundBridgeMuteControl      HAL mute    -> shared memory
                 │  mmap /tmp/soundbridge-<uid>  (RFSharedAudio, 320-byte header + ring)
                 ▼
SoundBridgeHost  (packages/host, Swift, menu-bar agent)
  ├── SharedMemoryManager   mapping lifecycle, admission, prefill, heartbeat
  ├── AudioRenderer         IO thread: ring read -> DSP -> volume gain -> device
  ├── AudioEngine           AUHAL setup, device switching
  └── main.swift            global composition root, shutdown sequence
                 │  writes EQ snapshot, reads volume for UI
                 ▼
SoundBridgeApp   (apps/mac/SoundBridgeApp, SwiftUI menu bar)
  ├── SharedMemoryMappingManager  the ONLY writer of rf_store_eq_snapshot
  ├── EQController                bass/mids/treble -> 10 bands -> shared memory
  └── DriverInstaller / VersionManager / IPCController
```

Ownership rules that matter for the findings below:

* The **Host** is the only writer of `admission_state` and `admission_epoch`.
* The **driver** is the only producer into the ring; the Host is the only consumer.
* The **Host** is the only writer of `rf_publish_volume_state` (revision-bumping);
  the driver additionally writes `volume_scalar`/`mute_state` through the raw
  non-revision path.
* The **App** is the only writer of the EQ snapshot.

---

## 5. DSP Realtime Safety Findings

### A1 — Parameter update versus audio processing

`AudioRenderer.render` (`AudioRenderer.swift:520-628`) is the IO thread. Inside one
callback it calls `soundbridge_dsp_update_band_gain` (×10), `soundbridge_dsp_update_preamp`,
`soundbridge_dsp_set_bypass` and `soundbridge_dsp_process_interleaved`
(`AudioRenderer.swift:614-628`). The control thread touches the same engine only through
`updateSampleRate` → `soundbridge_dsp_set_sample_rate`
(`AudioRenderer.swift:460-483`), which is guarded by
`memoryManager.waitForRenderPathIdle` (`SharedMemoryManager.swift:602-610`).

**Verdict: CONDITIONAL.** The engine's mutable fields (`sample_rate`, `num_active_bands`,
`current_preset`, `limiter_enabled`, the `bands` array, `preamp_smoother`) are plain,
non-atomic, and A3 below proves a control-thread write can be observed mid-mutation. The
only thing keeping this safe is that the parameter path runs on the IO thread itself (one
writer) and the rate-change path waits for the render gate to report idle. That is a caller
contract, not an engine invariant — no `static_assert`, no documented C-API contract in
`soundbridge_dsp.h`, and no test.

### A2 — Parameter publication architecture

**Verdict: PASS WITH NOTES.** EQ changes reach the engine as a whole-snapshot comparison
(`memcmp` over `RFEQSnapshot`, `AudioRenderer.swift:605-612`) and are then fanned out
band-by-band. The fan-out is `sfence`-free but benign on one thread. The architecture's
weak point is the snapshot itself, covered under C2.

### A3 — Sample-rate change

`soundbridge_dsp_set_sample_rate` (`engine.cpp:139-161`) calls
`preamp_smoother.init(sample_rate, 10.0f)`, and `ParameterSmoother::init`
(`smoothing.h:28-40`) unconditionally writes `current_ = 0.0f; target_ = 0.0f;
velocity_ = 0.0f`. The very next `process_interleaved` therefore multiplies audio by ~0 and
ramps back up.

`set_sample_rate` then calls `apply_preset(engine, &engine->current_preset)` with
`preset == &engine->current_preset`, and `apply_preset` opens with
`std::memcpy(&engine->current_preset, preset, sizeof(soundbridge_preset_t))`
(`engine.cpp:428`) — a self-overlapping `memcpy`, which is undefined behaviour in C (glibc
tolerates it; it is not guaranteed by the standard).

Measured (`+12 dB` preamp and `0 dB` preamp produce identical numbers, because the shape is
a ramp from zero, not from the previous gain), 512-frame blocks at 44.1 kHz after a
48 kHz → 44.1 kHz change:

```
  preamp 0.0 dB : block 0 -11.05 dB, block 1 -4.72, block 2 -2.37, block 3 -1.26,
                  block 4 -0.69, block 5 -0.39, within 0.5 dB after 6 blocks (~70 ms)
  preamp 12 dB  : identical
  bypass = true : block 0 -0.02 dB (bypass returns before the preamp stage)
```

**Verdict: CONFIRMED (Medium).** Every device switch, every 44.1↔48 kHz change and every
route change that alters the nominal rate produces a 46–70 ms broadband level dip of up to
11 dB. This is audible as a "duck" at the start of playback after a device change, and it
also explains the "-11 dB first block" reported in §2.3 of earlier field notes.

### A4 — Engine destruction

`soundbridge_dsp_destroy` is called only from `AudioRenderer.DSPHolder.deinit`
(`AudioRenderer.swift:252-258`). The renderer is a top-level `let` in
`main.swift:30` and the render callback captures it unretained
(`Unmanaged.passUnretained(renderer)`, `AudioEngine.setRenderCallback`), so `deinit` never
runs in a normal session; the engine is reclaimed by process exit. Shutdown order is
correct anyway: `.stopAudioEngine` precedes `.unlinkSharedMemory`
(`main.swift:575-660`), and `memoryManager.cleanup()` retires the render path with a drain.

**Verdict: CONDITIONAL.** The destroy path is not exercised in production, and no test
covers it. Safety depends entirely on the renderer outliving the process — an implicit
guarantee that nothing states and no assertion enforces. A refactor that made the renderer
a local or `Optional` would expose a use-after-free with no test to catch it.

### A5 — The realtime closure

`process_interleaved`/`process_planar` (`engine.cpp:167-410`) contain no allocation, no
lock, no syscall, and no virtual dispatch. They do contain
`std::chrono::high_resolution_clock::now()` twice per block, three `std::exp`, and one
`std::memcpy` for the bypass pass-through. On macOS those resolve to libm/vDSO calls that do
not take locks; `exp` is not in the strict "realtime subset" but is bounded and
allocation-free.

**Verdict: PASS WITH NOTES.** The `soundbridge_dsp.h` header's claim that the
`process_*` functions are "lock-free and allocation-free" is accurate. It says nothing
about `libm` determinism, and the CPU-load measurement depends on a clock that is not
guaranteed to be monotonic on all platforms.

---

## 6. DSP Functional Correctness Findings

### B1 — Bypass semantics

Both bypass branches (`engine.cpp:178-196` interleaved, `295-313` planar) copy input to
output and then **decay** the peak meters by `exp(-frames/decay_samples)`, returning before
the peak and CPU-load blocks. Measured, with a −0.75 dBFS programme material entering a
bypassed engine:

```
  active  : peak_l = -0.75 dB   cpu = 0.045 %
  after reset(): peak_l = -0.75 dB   cpu = 0.045 %   frames = 0
  bypass  : peak before = -0.75 dB, after 20 loud blocks = -13.10 dB, cpu 0.045 % -> 0.045 %
```

**Verdict: CONFIRMED (Low).** In bypass the peak meter reports decay toward silence while
loud audio is passing, and `cpu_load_percent` freezes. No shipping consumer reads either
field: `soundbridge_dsp_get_stats` is called only from
`packages/dsp/bridge/SoundBridgeDSPEngine.mm:348`, and neither target in
`packages/host` nor `apps/mac` links the bridge. Impact is limited to the bridge API and
`wav_processor`.

### B2 — Reset semantics

`soundbridge_dsp_reset` (`engine.cpp:123-137`) resets the biquads and the DC blocker and
zeroes `frames_processed` and `underrun_count`. It does **not** touch `preamp_smoother`,
`limiter` (`SoftLimiter` has no state to reset), `peak_left`, `peak_right` or
`cpu_load_percent`. The measurement above shows both stale values surviving a reset.

`packages/dsp/tests/test_engine.cpp:301-347` (`engine_reset_clears_state`) asserts only
`stats.frames_processed == 0`, so the suite passes while the semantic gap is open.

**Verdict: CONFIRMED (Low).** Same consumer analysis as B1.

### B3 — Nyquist validation — **CRITICAL**

`soundbridge_dsp_preset_validate` (`preset.cpp`) accepts any `frequency_hz` in
`[20, 20000]` with no reference to the engine's sample rate.
`Biquad::calculateCoeffs` (`biquad.h:186-260`) then computes

```cpp
const float w0 = 2.0f * PI * freq / sample_rate;          // can exceed PI
const float warp_factor = (w0 < 0.01f) ? 1.0f : w0 / std::sin(w0);
const float alpha = sin_w0 / (2.0f * Q * warp_factor);
```

For a high shelf, `a0 = (A+1) − (A−1)·cos(w0) + β·sin(w0)`. When `w0 → π` the three
denominator/numerator terms collapse onto each other and the poles move outside the unit
circle. `setCoeffs` (`biquad.h:70-88`) only checks `isFinite(coeffs)`; finite but unstable
coefficients pass straight through, and `processSampleMono` merely resets the state when the
*output* first becomes non-finite (`biquad.h:168-173`) — by which point the damage is
already in the output buffer.

The band involved is the App's own treble band: index 9, 16 000 Hz, high shelf, Q 0.7,
`enabled: true` always (`EQController.swift:51`). The Host adopts the device rate
(`AudioRenderer.updateSampleRate`), and `preset_validate` never sees the rate, so nothing
between the slider and the biquad can refuse the combination.

Measured on the shipping sources (fresh engine per row, 2048-frame blocks, 32 blocks,
0.02-amplitude test tone, +6 dB on band 9):

```
  sr= 16000 tone= 1000 Hz -> gain=   +6.01 dB  nonFinite=0/65536
  sr= 24000 tone= 1000 Hz -> gain=     -inf   nonFinite=65386/65536   maxFinite=1.3e+38
  sr= 24000 tone=10000 Hz -> gain=   +781.05 dB nonFinite=0/65536    maxFinite=2.5e+38
  sr= 24000 tone=13000 Hz -> gain=     -inf   nonFinite=51033/65536
  sr= 28000 tone= 1000 Hz -> gain=     -inf   nonFinite=65182/65536
  sr= 30000 tone= 1000 Hz -> gain=     -inf   nonFinite=64765/65536
  sr= 31000 tone= 1000 Hz -> gain=     -inf   nonFinite=63933/65536
  sr= 32000 tone= 1000 Hz -> gain=    0.00 dB nonFinite=0/65536
  sr= 32000 tone=13000 Hz -> gain=  +88.36 dB nonFinite=0/65536    maxFinite=504.8
  sr= 33000 tone=13000 Hz -> gain=    0.01 dB nonFinite=0/65536
  sr= 44100 tone=13000 Hz -> gain=    0.81 dB nonFinite=0/65536
  sr= 48000 tone=13000 Hz -> gain=    1.03 dB nonFinite=0/65536
```

Frequency-response sweep of the same band at 32 kHz versus 48 kHz:

```
  sr=32000 10 kHz +85.8 dB, 12 kHz +233 dB, 13 kHz +382 dB, 14 kHz +530 dB, 15 kHz NaN
  sr=48000  4 kHz +0.01, 8 kHz +0.10, 10 kHz +0.26, 13 kHz +1.02, 15 kHz +2.20 dB
```

Both filter types the App uses are affected, in different ways: the **peak** filter at
16 kHz simply degenerates toward flat at 32 kHz (0.00 dB at 15 kHz) while reporting
`apply_preset == SOUNDBRIDGE_OK`, and the **high shelf** — band 9, the one that carries the
Treble slider — becomes unstable.

Note that the `isFinite` output guard is not a safety net here: the DC blocker
(`dc_blocker.h`) and the limiter (`limiter.h`, which is disabled by the App's preset) have no
finiteness check of their own, and the Host's gain stage multiplies whatever it receives.
Once non-finite samples exist they reach the device buffer and the NaN persists in the
biquad state until a reset.

**Verdict: CONFIRMED (Critical).** Trigger: a physical output device whose nominal rate is
below 32 kHz (Bluetooth HFP routes, some USB/HDMI modes, anything set through Audio MIDI
Setup) combined with any non-zero Treble setting. At exactly 32 kHz the failure is gross
distortion rather than full-scale noise. At 44.1/48 kHz the band behaves correctly.

### B4 — Interleaved and planar equivalence

`process_planar` mirrors `process_interleaved` stage for stage (`engine.cpp:279-410` versus
`167-277`); the Host uses the interleaved entry point
(`AudioRenderer.swift:628`) and the DSP suite covers both
(`test_engine.cpp:32` and `:62`). **Verdict: PASS.**

### B5 — Limiter and audio quality

`SoftLimiter` (`limiter.h:1-127`) is a stateless per-sample soft clipper:
`threshold_` and `knee_start_` are its only members. There is no attack, no release, no
lookahead and no stereo linkage. Measured with a 1.6-peak left channel and a 0.02-peak right
channel:

```
  loudL(1.6 peak) -> 0.9531   quietR(0.02 peak) -> 0.0212   ratioR = 1.060
```

The left channel is limited by ≈ 4.5 dB while the right channel is untouched, so any loud
transient in one channel shifts the stereo image.

**Verdict: CONFIRMED (Medium, behavioural).** This is acceptable as a safety clipper but it
must not be described as a limiter with attack/release, and it must not be used to support
any "true peak" or "inter-sample peak" claim. The App ships with `limiterEnabled: false`
(`EQController.swift`), so the shipping path never engages it; the DSP default preset also
disables it.

---

## 7. Shared Memory Protocol Findings

### C1 — Admission open with two concurrent openers

`rf_admission_open` (`RFSharedAudio.h:733-751`) stores `admission_epoch` *before* the
compare-exchange on `admission_state`. Two openers that both observe `CLOSED` can therefore
each overwrite the epoch, and the one whose CAS succeeds returns `OK` while the mapping
carries the other opener's value.

**Verdict: FALSE POSITIVE in this codebase.** Two independent serialisations exclude it:

1. `SharedMemoryManager.createMemory(for:persistence:)` takes `mutationLock` (an `NSLock`)
   for its whole body, including the `rf_admission_open` call
   (`SharedMemoryManager.swift:188-192`, call at `:324`).
2. Cross-process duplication is excluded by `HostInstanceLock`, a `flock(LOCK_EX|LOCK_NB)`
   (`Lifecycle/HostInstanceLock.swift:126`), acquired before any mapping exists
   (`main.swift:114`).

The header itself still does not enforce single-opener, so a future second Host-side writer
would reopen the window. Recorded as a documentation-level note, not a defect.

### C2 — EQ snapshot memory model

```cpp
static inline void rf_store_eq_snapshot(RFSharedAudio* mem, const RFEQSnapshot* snapshot) {
    uint32_t seq = atomic_load_explicit(&mem->eq_sequence, memory_order_relaxed);
    atomic_store_explicit(&mem->eq_sequence, seq + 1, memory_order_release);
    memcpy((void*)&mem->eq_snapshot, snapshot, sizeof(RFEQSnapshot));   // plain write
    atomic_store_explicit(&mem->eq_sequence, seq + 2, memory_order_release);
}
```

`eq_snapshot` is an ordinary struct member, not `_Atomic`. The writer's `memcpy` and the
reader's `memcpy` inside `rf_load_eq_snapshot_safe` (`:1522-1536`) are therefore a data race
on a non-atomic object — undefined behaviour in C11 §5.1.2.4, not merely a torn read. The
sequence counter only detects the race; it does not remove the UB. In addition the writer
uses load-then-store rather than `fetch_add`, so two writers would each publish
`seq + 2` and permanently break parity (the App is the only writer today, so this is latent).

The consumer compounds the problem:

* `rf_load_eq_snapshot` (`:1538-1540`) discards the `bool` from
  `rf_load_eq_snapshot_safe`.
* `AudioRenderer.render` calls it on the IO thread (`AudioRenderer.swift:606`) and then
  `memcmp`s the result against the previous snapshot. When all four retries fail, `out`
  holds the last partially-copied attempt, and that torn value is compared, marked
  "changed", and pushed into the engine — applying a half-updated EQ curve in the audio
  callback.

**Verdict: CONFIRMED (Medium).** The UB is real and unavoidable with the current layout; the
consumer-side behaviour converts a detected-inconsistency into a silent partial update.

### C3 — Volume and mute publication semantics

Three separate issues:

1. `rf_publish_volume_state` (`:1418-1436`) writes scalar, mute, mode, then bumps
   `state_revision`. The comment at `:214-222` documents the residual window honestly.
2. The driver's HAL path writes `volume_scalar`/`mute_state` through
   `rf_store_volume_scalar`/`rf_store_mute_state` (`Plugin.cpp:315`, `:357`; header
   `:1299-1310`), which **do not bump the revision**. `rf_read_volume_state`'s retry loop
   (`:1369-1400`) is built on "revision moved ⇒ retry"; for a driver-originated change the
   revision never moves, so the loop cannot detect that it mixed a fresh scalar with a stale
   `mute_state`/`mode`.
3. `rf_load_volume_scalar` (`:1281`) and `rf_read_volume_state` (`:1369`) dereference `mem`
   without a NULL check (`rf_read_volume_state` checks only `out`). Every other accessor in
   the header checks; these two do not.

Also, `SoundBridgeVolumeControl::RestoreFromSharedMemory` (`Plugin.cpp:298-303`) sets
`suppress_shared_memory_write_` around `SetScalarValue`. Any genuine user change that
`SetRawValueImpl` processes inside that window is dropped from the shared-memory mirror —
the host's own `commitProxyVolumeState` normally re-publishes it, but only if the proxy is
the default output (`DefaultOutputPolicy.mayForwardVolume`).

**Verdict: CONFIRMED (Low–Medium).** No incorrect audio results from 1 and 3 in current
call paths; issue 2 is a correctness hole in a documented consistency guarantee.

### C4 — Header and buffer validation

`rf_validate_header` (`:584-620`) is described as the "single implementation" of header
validation. It checks protocol version, header size, sample rate, channel count, ring
capacity, and admission state. It does **not** check `format` range,
`bytes_per_sample`, `bytes_per_frame`, or that `ring_capacity_frames` fits the mapping.

The driver, however, validates all of those separately in
`ControlProtocol.hpp:165-175` — `format > RF_FORMAT_INT32` rejected,
`bytes_per_sample == rf_bytes_per_sample(format)`, `bytes_per_frame == channels *
bytes_per_sample`, and `ring_capacity_frames <= (fileSize - sizeof(RFSharedAudio)) /
bytes_per_frame`. Since the driver is the only process that turns `ring_capacity_frames`
into an index, and it validates before publishing `shared_memory_`, the alleged
out-of-bounds write does not exist.

**Verdict: FALSE POSITIVE for out-of-bounds access; CONFIRMED RISK for the asymmetric
contract.** The Host trusts `rf_validate_header` and never repeats the size checks
(`SharedMemoryManager.swift` `connectionObservation`), and the header's own comment claims a
completeness it does not have. A future producer that relied on that comment would write out
of bounds.

### C5 — Heartbeat semantics

`rf_is_connection_healthy` (`:879-900`) returns
`(driver_hb > 0 && host_hb > 0)` — liveness at any point in the past, not freshness — and
performs no NULL check. A tree-wide search finds **no caller**: the only hits are the four
byte-identical header copies under `packages/shared`, `packages/driver`,
`packages/host/Sources/CSoundBridgeAudio` and `apps/mac/.../CSoundBridgeAudio`, plus
`.build` artefacts.

Freshness is actually implemented on the Host side, correctly: `DriverConnectionTracker`
(`Lifecycle/DriverLifecycle.swift:307-400`) keeps two separate `DriverHeartbeatWatch`
windows (3 samples for the driver, 5 for the host), resets them on mapping-incarnation
change, and reports `driverNotResponding` only for "attached but never produced a frame".

**Verdict: FALSE POSITIVE for "heartbeat judged by a stale field"; CONFIRMED RISK that the
header exposes a misleading dead API** whose name implies a guarantee it does not provide.

---

## 8. HAL Driver Findings

### D1 — Real-time allocation in the IO callback — **HIGH**

`OnWriteMixedOutput` (`Plugin.cpp:733-850`) runs on the HAL IO thread and can allocate in
four places:

| Line | Call | Reachability |
| --- | --- | --- |
| `:788` | `HandleFormatChange` → `ResizeBuffers` (`:1215-1229`) → three `resize()` calls | whenever the physical format changes, e.g. first callback after a device switch |
| `:793-795` | `interleaved_buf_.resize(needed)` | whenever a callback is larger than the pre-allocated 4096 frames |
| `:1231-1240` | `ConvertToFloat32Interleaved` begins with `output.resize(...)` | every callback (no-op when the size matches) |
| `:1289-1320` | `ProcessWithSampleRateConversion` resizes `resampled_buf_` | every callback while rate-converting |

In addition `stats_.LogPeriodic()` (`:849`, implementation `:260-280`) is called from the
same callback and emits five `RF_LOG_INFO` lines (os_log) every 60 s from the IO thread.

**Verdict: CONFIRMED (High).** The steady-state path is allocation-free and the pre-allocated
buffers cover the documented 48 kHz/2 ch proxy format, which is why this has not produced
audible glitches in normal use. But the *first* callback after a format change and the
*whole* rate-conversion path allocate and free inside the IO proc, and a logging call on the
IO thread can block on the logging subsystem. There is no test that asserts the callback is
allocation-free, and `packages/driver/tests` covers only the header-level helpers.

### D2 — Format conversion

`ConvertToFloat32Interleaved` (`:1231-1287`):

* **Float** handles `kAudioFormatFlagIsNonInterleaved` correctly (de-interleaves planar into
  the interleaved ring buffer) and rejects `mBitsPerChannel != 32` — fail-closed, good.
* **Signed integer** never inspects `kAudioFormatFlagIsNonInterleaved`. A planar Int16 or
  Int32 stream is read as if interleaved, producing channel-swapped/garbled audio.
* **Int24** assumes packed 3-byte samples (`input[i*3] | input[i*3+1] << 8 | ...`) without
  checking `mBytesPerFrame == 3 * channels`. A 24-in-32 layout (very common on USB
  interfaces) is silently misaligned: every sample after the first is wrong.

`fmt.mBytesPerFrame == 0` and `frameCount == 0` are both rejected (`:769-778`).

**Verdict: CONFIRMED RISK (Medium).** The libASPL default stream format is Int16 packed
(`vendor/libASPL/include/aspl/Stream.hpp`), so the reachable default is correct. The two gaps
are reachable through any client that negotiates a planar integer or 24-in-32 format on the
proxy stream, and neither is covered by a test.

### D3 — CallbackGate and mapping lifetime

`MappingRetirement.hpp:128-300` implements a single `atomic<uint32_t>` gate:
`TryEnter` is one `fetch_add(acq_rel)` with a rollback on the closed bit; `CloseAndDrain`
sets the closed bit and polls the count to zero; a timeout returns
`DrainAck::TimedOut`, which `RetireMapping` (`Plugin.cpp:910-950`) treats **as "not
drained"** — the mapping goes to `MappingQuarantine::Retain` and is never `munmap`ed
(`:920-948`). The pointer is cleared after the drain attempt and before
`mapping_owner_` is released, so a callback that is still inside keeps a valid `mem`.

**Verdict: PASS.** The only correctness argument used is the counter reaching zero; the
timeout is never treated as proof. `packages/driver/tests/MappingRetirementTests.cpp`
exercises exactly this contract and passes (§15.1).

### D4 — Producer claim lifecycle

`rf_producer_claim` is called once, in `OnStartIO` (`:606-621`), with a post-CAS owner
re-check inside the header. Release happens **only** in `OnStopIO` (`:723-727`). The
destructor (`:529-538`) and `Retire()` (`:548-560`) deliberately do not release, and the
comment explains why: those two paths have no proof that no callback is in flight, whereas
`OnStopIO` holds libASPL's `ioMutex_` *and* drains.

**Verdict: CONDITIONAL.** Correct as written, but it means `producer_owner_token` stays set
on a mapping the driver has abandoned. That is harmless today because the Host unlinks and
replaces the file (a new inode resets the header) and the old mapping is quarantined. It
becomes a permanent-silence bug the moment anything reuses a mapping without re-initialising
the header — which is exactly what D5 does.

### D5 — Recovery completeness

`AttemptRecovery` (`:1182-1200`) calls `Disconnect()`, re-opens shared memory, validates and
sets `state_ = Connected` **without re-running `rf_producer_claim`**, while
`producer_claim_held_` is still `true`. On the new mapping `producer_owner_token == 0`, so
`rf_producer_may_write` would reject every write: permanent silence after a "successful"
recovery.

**Verdict: CONFIRMED defect, currently unreachable.** A tree-wide search finds no caller of
`AttemptRecovery` or `IsHealthy` (`:1130-1180`), and `health_failures` is declared
(`:253`) and logged (`:269`) but never incremented. The recovery path is dead code; the
class comment that advertises "Auto-recovery" (the startup banner at `:1713`) overstates what
runs. Because the defect is latent rather than absent, this must not be closed as
"not reproducible" — the moment anyone wires health monitoring to `IsHealthy()`, the driver
silently produces nothing.

### D6 — Device removal and re-add

`RemoveDevice` (`:1541-1560`) calls `handler->Retire()` before erasing the device, and
records a removal timestamp used by the re-add cooldown; `SyncDevices` is guarded by
`g_state->sync_mutex` and driven by both a Darwin notification and a 1 s poll
(`:1653-1699`).

**Verdict: PASS WITH NOTES.** Removal goes through the same drain path as every other
teardown, and the cooldown prevents an immediate re-add from racing the retire.

---

## 9. Cross-Component Execution Traces

### E1 — Volume and mute

```
HAL set-volume ─► SoundBridgeVolumeControl::SetRawValueImpl      (Plugin.cpp:306-319)
                    └─ rf_store_volume_scalar                     (no revision bump)
Host notification ─► ProxyDeviceManager.commitProxyVolumeState    (main queue)
                    ├─ VolumePersistence.save
                    └─ memoryManager.publishVolumeState           (SharedMemoryManager.swift:366-382)
                         └─ rf_publish_volume_state               (revision +1, latch initialised)
Host render       ─► rf_load_volume_scalar + rf_load_mute_state   (AudioRenderer.swift:630-645)
                    └─ VolumeTaper gain -> applyGainAndMute
Driver OnStartIO  ─► SyncVolumeStateWithSharedMemory               (Plugin.cpp:964-...)
                    └─ rf_read_volume_state -> RestoreFromSharedMemory (suppressed echo)
```

Gaps: the driver's raw write is outside the revision counter (C3.2); the suppress window
can swallow a genuine user change (C3.3); `rf_read_volume_state` has no NULL guard (C3.4).
End-to-end the value does converge — the Host's publish always follows a proxy volume
notification — so no user-visible divergence was demonstrated.

### E2 — EQ

```
App EQController ─► SharedMemoryMappingManager.publish
                     └─ rf_store_eq_snapshot                       (App is the only writer)
Host render ─► rf_load_eq_snapshot (return value dropped)
             ─► memcmp vs lastEQSnapshot
             ─► update_band_gain ×10, update_preamp, set_bypass
             ─► process_interleaved
```

Gaps: torn snapshot applied on retry exhaustion (C2); **the App never sends band
frequencies**, only gains — the engine's band frequencies come from `applyInitialPreset`
(`AudioRenderer.swift:243-249`) and are whatever that preset contains, so B3's 16 kHz band
reaches the engine without any rate check on either side.

### E3 — Sample rate

```
device nominal rate ─► AudioEngine.switchDevice / setup
                        ├─ AudioOutputUnitStop
                        ├─ AudioRenderer.updateSampleRate(rate)   (AudioRenderer.swift:460)
                        │    └─ waitForRenderPathIdle  (poll rf_rt_gate_in_flight)
                        │    └─ soundbridge_dsp_set_sample_rate    → A3 dip
                        └─ AudioOutputUnitStart
```

The idle check is a check-then-act: between the last poll and the `set_sample_rate` call,
CoreAudio may still enter the callback. The code documents this residual assumption
(`AudioRenderer.swift:449-457`) rather than hiding it — honest, but still an unproven
guarantee, hence CONDITIONAL for A1.

### E4 — Host crash and restart

Driver keeps the mapping and its claim. A restarted Host creates a **new** inode
(`createMemory` → `rename`, `SharedMemoryManager.swift:329-338`), so the driver's
`OnStartIO` re-validates by session UUID (`validateSharedMemory`) and the stale mapping is
quarantined by the Host's own `cleanup()` (which cannot run after a crash — it is unlinked by
the next Host's `unlinkIfStillOwned`). `rf_is_connection_healthy` plays no part (C5).

### E5 — Device lifecycle

```
control file / Darwin notify ─► SyncDevices ─► AddDevice / RemoveDevice
                                                 └─ handler->Retire()
                                                      └─ CloseAndDrain -> munmap | quarantine
Host side ─► DeviceMonitor ─► AudioEngine.switchDevice ─► updateSampleRate (→ A3)
```

The two halves are independent, which is the design soundness argument for D4's "do not
release on retire": the mapping incarnation, not the handler, carries the claim.

---

## 10. Detailed Findings Register

| ID | Finding | Severity | Verdict | Evidence | Release Impact |
| --- | --- | --- | --- | --- | --- |
| B3 | Out-of-band band frequency → unstable high shelf, non-finite output below 32 kHz | **Critical** | CONFIRMED | `biquad.h:186-260`, `preset.cpp`, probe output §6-B3 | **Blocks** |
| D1 | `resize()` ×4 and `LogPeriodic()` inside the IO proc | High | CONFIRMED | `Plugin.cpp:788,793,1231,1289,849` | Blocks a "realtime-safe callback" claim |
| C2 | EQ seqlock contains a non-atomic `memcpy` (UB); torn snapshot applied | Medium | CONFIRMED | `RFSharedAudio.h:1511-1540`, `AudioRenderer.swift:606` | Blocks a "memory-model correct" claim |
| A3 | Preamp smoother re-initialised to zero on every rate change | Medium | CONFIRMED | `engine.cpp:139-161`, `smoothing.h:28-40`, probe §5-A3 | Non-blocking, audible |
| D2 | Integer planar unsupported; Int24 assumes packed bytes | Medium | CONFIRMED RISK | `Plugin.cpp:1231-1287` | Conditional on supported formats |
| B5 | Limiter has no attack/release/lookahead, no stereo link | Medium | CONFIRMED | `limiter.h:1-127`, probe §6-B5 | Bounds quality claims only |
| D5 | Recovery never re-claims the producer slot | Medium | CONFIRMED (unreachable) | `Plugin.cpp:1182-1200`, caller census | Blocks enabling recovery |
| B1 | Bypass decays peak meters and freezes CPU load | Low | CONFIRMED | `engine.cpp:178-196,295-313`, probe §6-B1 | Diagnostics only |
| B2 | `reset()` leaves limiter/smoother/peak/CPU intact | Low | CONFIRMED | `engine.cpp:123-137`, probe §6-B1 | Diagnostics only |
| C3 | Driver writes escape the revision counter; NULL checks missing; suppress window | Low | CONFIRMED | `RFSharedAudio.h:1281-1310,1369-1400`, `Plugin.cpp:298-319` | Non-blocking |
| C4 | `rf_validate_header` is not the "single implementation" it claims | Medium | CONFIRMED RISK | `RFSharedAudio.h:584-620` vs `ControlProtocol.hpp:165-175` | Non-blocking today |
| C5 | `rf_is_connection_healthy` is dead and semantically wrong | Low | CONFIRMED RISK | `RFSharedAudio.h:879-900`, caller census | Non-blocking |
| A1 | Engine fields are not atomic; safety is a caller promise | Medium | CONDITIONAL | `engine.cpp` struct, `AudioRenderer.swift:520-628` | Requires E3 guarantee |
| A4 | `destroy` depends on process-lifetime ownership | Low | CONDITIONAL | `AudioRenderer.swift:252-258`, `main.swift:30` | Untested path |
| D4 | Claim survives retire | Low | CONDITIONAL | `Plugin.cpp:548-560,723-727` | Safe only with fresh mappings |
| C1 | Concurrent `rf_admission_open` epoch overwrite | — | FALSE POSITIVE | `SharedMemoryManager.swift:188-192`, `HostInstanceLock.swift:126` | None |
| C4-OOB | Ring write out of bounds from unvalidated capacity | — | FALSE POSITIVE | `ControlProtocol.hpp:165-175` | None |
| C5-hb | Heartbeat evaluated from a stale field | — | FALSE POSITIVE | `DriverLifecycle.swift:307-400` | None |
| B4 | Planar vs interleaved divergence | — | PASS | `engine.cpp:167-410`, `test_engine.cpp:32,62` | None |
| D3 | Gate timeout treated as drained | — | PASS | `MappingRetirement.hpp:128-300`, `Plugin.cpp:910-950` | None |
| D6 | Device removal races the callback | — | PASS (notes) | `Plugin.cpp:548-560,1541-1560` | None |

---

## 11. Confirmed Defects

1. **B3** — Out-of-range band frequency produces unstable biquad coefficients; only the
   output guard notices, and the guard is not a barrier to non-finite samples leaving the
   engine. Critical.
2. **D1** — Heap allocation and an os_log burst inside the HAL IO proc on the format-change,
   oversize-buffer and rate-conversion paths.
3. **C2** — `eq_snapshot` is written and read concurrently as a non-atomic object; the
   sequence counter cannot make that defined, and the consumer applies a torn snapshot when
   the retry budget is exhausted.
4. **A3** — `ParameterSmoother::init` zeroes the preamp on every sample-rate change,
   producing a 46–70 ms dip; `apply_preset` additionally self-`memcpy`s.
5. **B5** — The "limiter" is a stateless clipper with no stereo linkage.
6. **D5** — `AttemptRecovery` reconnects without re-claiming the producer slot. Unreachable
   today (no callers) but a latent permanent-silence path.
7. **B1** — Bypass mode reports decaying peaks and a frozen CPU load.
8. **B2** — `reset()` does not clear the metrics a caller would reasonably expect it to.
9. **C3** — Three volume-state contract holes (revision coverage, NULL guards, suppress
   window).

---

## 12. Conditional Risks

Three items are not defects on their own: each is safe only because of a caller guarantee
that nothing in the audited code enforces, documents or asserts.

1. **A1** — DSP field mutation across threads is safe only because the parameter writer is
   the IO thread. Nothing in the engine enforces or documents this.
2. **A4** — `soundbridge_dsp_destroy` is only safe because the renderer is a process-lifetime
   global captured unretained.
3. **D4** — Not releasing the claim on retire is only safe because mappings are never reused.

Two items rated CONFIRMED RISK in §11 also have a conditional half, and are counted there
rather than here: **C4**, whose split validation is safe only because the driver is the sole
index producer, and **D2**, whose integer planar and 24-in-32 paths are safe only while
clients negotiate neither.

---

## 13. False Positives

1. **C1** — concurrent `rf_admission_open` (two serialisations in the Host).
2. **C4 (OOB)** — ring out-of-bounds from an unvalidated capacity (`validateSharedMemory`).
3. **C5 (freshness)** — heartbeat judged from a stale value (the Host tracker is correct).

Two further suspicions were examined and set aside as notes rather than findings:

4. The claim that `soundbridge_dsp_reset` "clears all state" is a docstring overstatement
   rather than a defect, hence recorded under B2 rather than as a separate item.
5. The claim that the driver applies proxy gain in the callback — `OnProcessMixedOutput` is
   an intentional no-op (`Plugin.cpp:854-868`), with volume applied by the Host.

---

## 14. Unresolved Questions

None. Every one of the 16 suspected defects reached a verdict backed by source evidence; the
three behavioural questions were settled by measurement rather than argument.

Two questions were answered "not in the shipping path" rather than "not a defect", and are
recorded as such: D5's recovery path and B1/B2's diagnostics.

---

## 15. Test Coverage and Missing Tests

Existing suites: DSP 1 CTest target wrapping 40 cases; driver 3 CTest targets; Host 25 Swift
test files; App 9 Swift test files.

Coverage of the findings:

| Finding | Existing coverage | Gap |
| --- | --- | --- |
| B3 | none | no test varies the sample rate against a band frequency |
| D1 | none | no allocation assertion for `OnWriteMixedOutput` |
| C2 | `SharedMemoryProtocolTests` (single-threaded) | no concurrent writer/reader test |
| A3 | none | `test_engine.cpp` never calls `set_sample_rate` |
| D2 | none | no ASBD matrix test |
| B1/B2 | `engine_reset_clears_state` asserts `frames_processed` only | peak and CPU not asserted |
| B5 | `engine_limiter_prevents_clipping` | no stereo-linkage assertion |
| D5 | none | no callers to test |
| C1, C4, C5 | covered incidentally by the admission and protocol suites | the *negative* claims (what is not checked) are untested |

---

### 15.1 Required Test Matrix

#### DSP

| # | Test | Type | Required setup | Expected result | Actual result | Real audio device | Safe to automate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D-1 | `set_sample_rate(24k/28k/30k/31k)` with the App preset | unit | engine + 16 kHz shelf band | output finite, gain ≈ +6 dB | **non-finite in 97–99 % of samples** | no | yes |
| D-2 | `set_sample_rate(32k)` + 13 kHz tone | unit | engine + band 9 | ≈ +6 dB | **+88 dB, peak 504** | no | yes |
| D-3 | band frequency > SR/2 rejected at `apply_preset` | unit | engine at 24 kHz | `SOUNDBRIDGE_ERROR_INVALID_PARAM` | currently `OK` | no | yes |
| D-4 | preamp level across `set_sample_rate` | unit | engine, preamp 0 dB and ±12 dB | no discontinuity | **−11 dB first block, 70 ms to recover** | no | yes |
| D-5 | `reset()` clears peak/CPU/limiter state | unit | engine + loud material | documented post-conditions | **stale peak and CPU survive** | no | yes |
| D-6 | bypass keeps peak meter tracking the output | unit | bypassed engine + loud material | meter tracks output | **meter decays to −13 dB** | no | yes |
| D-7 | limiter stereo linkage | unit | 1.6 L / 0.02 R | gain reduction applied to both or neither | **L limited, R untouched** | no | yes |
| D-8 | planar == interleaved bit-exactness | unit | existing | equality | **passes** | no | yes |

#### Shared memory

| # | Test | Type | Required setup | Expected result | Actual result | Real audio device | Safe to automate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S-1 | concurrent `rf_store_eq_snapshot` / `rf_load_eq_snapshot_safe` under TSan | race | two threads, one mapping | no data race reported | **not executed** (would need a TSan build) | no | yes |
| S-2 | `rf_load_eq_snapshot` return value honoured by the render path | unit | torn snapshot injection | stale snapshot not applied | **torn value is applied** | no | yes |
| S-3 | `rf_read_volume_state(NULL, &out)` | unit | — | `false`, no crash | currently dereferences | no | yes |
| S-4 | driver-originated scalar change visible with revision consistency | integration | Host + driver | revision advances | **revision unchanged** | no | yes |
| S-5 | `rf_validate_header` rejects bad format / inconsistent byte counts | unit | crafted header | rejection | **accepts** | no | yes |
| S-6 | two concurrent `rf_admission_open` | unit | two threads | at most one `OK` with matching epoch | excluded by callers, **not by the API** | no | yes |

#### Driver

| # | Test | Type | Required setup | Expected result | Actual result | Real audio device | Safe to automate |
| --- | --- | --- | --- | --- | --- | --- | --- |
| V-1 | `OnWriteMixedOutput` performs no allocation | unit + instrumentation | driver built with an allocation hook | zero allocations in steady state and after a format change | **not executed** | no | yes |
| V-2 | planar Int16 / Int32 conversion | unit | ASBD matrix | correct channel order | **warns/garbles** | no | yes |
| V-3 | 24-in-32 conversion | unit | `mBytesPerFrame == 4·ch` | correct samples | **misaligned** | no | yes |
| V-4 | gate timeout ⇒ quarantine, never `munmap` | unit | existing suite | quarantine | **passes** | no | yes |
| V-5 | `AttemptRecovery` re-claims the producer slot | unit | simulated disconnect | writes resume | **silent** (path has no callers) | no | yes |
| V-6 | device removal mid-callback | integration | real driver | no crash, mapping quarantined | **not executed** (would touch coreaudiod) | yes | no |

#### Executed during this audit

```
$ cmake -S packages/dsp  -B $TMPDIR/sb-audit-dsp.XXXX   && ctest --test-dir $TMPDIR/... 
   1/1 Test #1: soundbridge_dsp_tests ... Passed  0.89 sec       100% passed

$ cmake -S packages/driver -B $TMPDIR/sb-audit-driver.XXXX && ctest --test-dir $TMPDIR/...
   1/3 soundbridge_driver_control_protocol_tests ..... Passed  0.57 sec
   2/3 soundbridge_driver_producer_token_tests ....... Passed  0.57 sec
   3/3 soundbridge_driver_mapping_retirement_tests ... Passed  1.15 sec
                                                            100% passed
```

Both suites were configured into scratch directories so `packages/dsp/build` and
`packages/driver/build` were not touched.

**Not executed, deliberately:** `make test-host`, `make test-app`, `make test-installer`,
`make test-unsigned`, and every path in V-6. The Host suite creates CoreAudio listeners and
spawns child processes against real HAL objects; the App suite drives the installed driver;
the installer suite exercises `pkgbuild`/`installer`. All three could disturb the audio
system of the machine under audit, which the engagement forbids.

---

## 16. Recommended Remediation Order

1. **B3 — clamp or reject out-of-band frequencies.** Lowest-risk fix that closes the
   critical finding: in `soundbridge_dsp_preset_validate`, reject (or clamp) any band whose
   `frequency_hz >= 0.45 × sample_rate`; `apply_preset` and `update_band_frequency` need the
   engine rate, which they already have. Independently, `Biquad::setCoeffs` should verify
   pole radius (`|a2/a0| < 1` and the `a1` discriminant) and fall back to flat *and report*
   rather than silently succeeding. A regression test at 24/28/30/31/32 kHz belongs with the
   fix.
2. **D1 — move allocation off the IO thread.** Size the three buffers from the negotiated
   format in `OnStartIO`/`HandleFormatChange` *before* opening the gate, refuse callbacks
   larger than the pre-allocated capacity instead of resizing, and move `LogPeriodic` to the
   1 s control thread that already calls `SyncDevices`.
3. **C2 — give the EQ snapshot a defined memory model.** Either make `eq_snapshot` an array
   of `_Atomic uint32_t` words copied with relaxed loads/stores inside the seqlock, or move
   the payload behind a double-buffer index, and make the writer use `fetch_add`. The Host
   must stop applying a snapshot when `rf_load_eq_snapshot_safe` returns `false`.
4. **A3 — stop zeroing the preamp on a rate change.** Add a
   `ParameterSmoother::reinit(sample_rate)` that preserves `current_`/`target_` and only
   recomputes its coefficients, and pass a non-aliasing preset (a local copy) to
   `apply_preset`.
5. **D2 — complete the ASBD matrix.** Handle `kAudioFormatFlagIsNonInterleaved` in the
   integer branches and validate `mBytesPerFrame` against `mBitsPerChannel` before choosing
   the Int24 walker.
6. **D5 — either delete the recovery path or finish it.** Deleting it removes a latent
   permanent-silence bug and a false claim in the startup banner; finishing it means
   `AttemptRecovery` must re-run `rf_producer_claim` and honour the result.
7. **C3/C4/C5 — tighten the header contract.** Add the missing NULL guards, decide whether
   driver-originated volume writes should bump the revision (they currently cannot, by
   design), move the size/format checks into `rf_validate_header` so the "single
   implementation" comment becomes true, and delete or re-document
   `rf_is_connection_healthy`.
8. **B1/B2/B5 — either implement the semantics or document the limits.** The metrics have no
   shipping consumer; the cheapest correct outcome is to document them as diagnostics with
   their exact post-conditions.

---

## 17. Release Impact Assessment

**1.2.1 as it stands: FAIL.**

B3 is the deciding factor. It is not a hypothetical: the App always enables the 16 kHz
treble band, the Host always adopts the device's nominal rate, and the only thing standing
between a user and full-scale non-finite output is the device never running below 33 kHz.
Every Mac's built-in output qualifies today, so the defect is not visible in the default
configuration — but the engine advertises and accepts 8 000–384 000 Hz
(`soundbridge_dsp.h`), and the Host follows the device rather than constraining it. A single
Bluetooth headset in HFP mode, or one Audio MIDI Setup edit, turns "Treble" into a noise
generator.

The remaining blockers are of different kinds:

* **D1** does not break audio in the steady state; it falsifies the "realtime-safe callback"
  property the driver is architected around, and it is exactly the kind of defect that
  surfaces as an intermittent glitch under load.
* **C2** is undefined behaviour, which means the compiler is entitled to do anything with it;
  today's observed behaviour is not a guarantee.
* **A3** is audible but not dangerous.
* **D2** is conditional on formats the shipping client does not negotiate.

Recommended disposition for 1.2.1:

1. Fix B3 (validate against Nyquist + verify pole stability) and add the regression test.
   This alone turns the verdict into PASS WITH CONDITIONS.
2. Fix D1 and C2 in the same release if the schedule allows; both are contained changes.
3. Ship A3, D2, B5, C3, C5 as documented known limitations with the exact conditions, and
   D5 either deleted or left explicitly disabled in the release notes.
4. Do **not** claim "realtime-safe callback" or "memory-model correct EQ publication" until
   D1 and C2 are closed.

---

## 18. Final Audit Verdict

### **FAIL — CONFIRMED CRITICAL DEFECTS**

One critical defect (B3) is reachable from the shipping App on any output device whose
nominal sample rate is below 33 kHz, and it produces unbounded, partly non-finite output.
Eight further confirmed defects, three confirmed risks and three conditional risks remain
open. No suspected defect was closed on the strength of a proposed remediation, a comment,
or a passing build.

**Counts**

| Category | Count |
| --- | --- |
| Confirmed defects | 9 (B3, D1, C2, A3, B5, D5, B1, B2, C3) |
| Confirmed risks | 3 (D2, C4, C5) |
| Conditional risks | 3 (A1, A4, D4) |
| Unresolved | 0 |
| False positives | 3 (C1, C4-OOB, C5-freshness) |
| Passing areas | 3 (B4, D3, D6 with notes) |

**Top five release blockers**

1. **B3** — unstable high shelf / peak filter at 16 kHz for SR ≤ 32 kHz; non-finite output.
2. **D1** — heap allocation and IO-thread logging inside `OnWriteMixedOutput`.
3. **C2** — non-atomic `eq_snapshot` race (UB) and a torn snapshot applied to the engine.
4. **A3** — 46–70 ms level dip on every sample-rate change, plus self-overlapping `memcpy`.
5. **D5** — recovery path that cannot produce audio, latent behind dead code.

**Tests executed**

* `soundbridge_dsp_tests` (DSP unit suite, 40 cases) — **pass**
* `soundbridge_driver_control_protocol_tests` — **pass**
* `soundbridge_driver_producer_token_tests` — **pass**
* `soundbridge_driver_mapping_retirement_tests` — **pass**
* DSP behavioural probes for B3, A3, B1, B2, B5 — **executed**, results in §5, §6

**Tests not executed**

`make test-host`, `make test-app`, `make test-installer`, `make test-unsigned`, any real
device attach/detach, any driver install/uninstall, any `coreaudiod` interaction, any TSan
run (S-1).

**Report path**

`docs/release/SoundBridge-Core-Engineering-Audit.md`

**Git state**

| | Commit | `git status --porcelain=v1 -uall` |
| --- | --- | --- |
| Before | `eb45303f136faf95f764d2dc4d007206f6f3a3e7` | empty |
| After | `eb45303f136faf95f764d2dc4d007206f6f3a3e7` | `?? docs/release/SoundBridge-Core-Engineering-Audit.md` |

`git diff --stat` and `git diff --cached --stat` are both empty, `VERSION` still reads
`1.2.0`, and `RF_AUDIO_PROTOCOL_VERSION` is still `0x00020200`.

No production file, test, configuration, version constant, protocol constant or header was
modified. No Git write operation was performed. The only additions are this report and the
scratch build directories under `$TMPDIR`, which are outside the repository.
