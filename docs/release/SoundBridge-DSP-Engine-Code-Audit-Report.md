# SoundBridge — DSP Engine Comprehensive Code Audit & Findings Report

**Audit date:** 2026-11-22
**Repository:** `/Users/chenjianyu/CodeGeeXProjects/SoundBridge`
**Audit scope:** `packages/dsp/` (public headers, implementation, internal DSP modules, tests, Objective-C++ bridge, CLI tool)
**Baseline commit:** `eb45303f136faf95f764d2dc4d007206f6f3a3e7` (`main`)
**Toolchain:** Apple clang 21.0.0 (clang-2100.4.1.1), macOS 27.2.1 (26B131), arm64 host, universal `arm64;x86_64` build
**Audit mode:** read-only. No production source, header, test, build file, or document was modified. One new file was created: this report.

---

## Working-tree state at audit start (recorded, not produced by this audit)

`git status --porcelain` at the start of this audit reported **9 modified tracked files and 3 untracked files**. These all pre-date this audit (they are the working state left by prior remediation work) and were **not** touched here:

```
 M apps/mac/SoundBridgeApp/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
 M packages/driver/include/RFSharedAudio.h
 M packages/dsp/src/biquad.h
 M packages/dsp/src/engine.cpp
 M packages/dsp/tests/test_engine.cpp
 M packages/dsp/tests/test_main.cpp
 M packages/host/Sources/CSoundBridgeAudio/include/RFSharedAudio.h
 M packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift
 M packages/shared/include/RFSharedAudio.h
?? docs/SoundBridge-API-Audit-Handbook.md
?? docs/SoundBridge-Main-Flow-Walkthrough.md
?? docs/release/SoundBridge-Core-Engineering-Audit.md
```

Submodule `packages/driver/vendor/libASPL` → `633e0f70203edd87d320fc5a3cae901e1363aac5` (`v3.1.2-1-g633e0f7`), no `+`/`-` prefix (clean).

> **Consequence for this report.** The audited DSP sources are the *working-tree* versions, which already contain uncommitted remediation for an earlier audit (`docs/release/SoundBridge-Core-Engineering-Audit.md`), notably the Nyquist clamp in `biquad.h` and the `set_sample_rate` preamp carry-over in `engine.cpp`. Section 5.4 re-verifies that clamp experimentally. The committed `HEAD` version of `biquad.h` does **not** contain it and is subject to the instability described in that earlier report.

---

## 1. Executive Summary

### 1.1 Verdict

**FAIL** — as an *API-contract and verification* verdict. The numeric DSP core itself is sound (§5.3–§5.6); the failure is that (a) the module's self-verification is structurally incapable of reporting a failure, and (b) the module's headline concurrency guarantee is false at the language level.

| Dimension | Result |
| --- | --- |
| Processing-path realtime safety (no alloc / no lock / bounded) | **PASS** |
| Biquad coefficient math and numeric accuracy | **PASS** (exact to 0.001 dB across 8 kHz–384 kHz) |
| DC blocker | **PASS** |
| Soft limiter shape, continuity, bound over the audio range | **PASS** |
| Parameter-update thread-safety as documented | **FAIL** (F-02, F-05) |
| Numerical edge-case handling | **FAIL** (F-06, F-07, F-08, F-10) |
| Statistics / diagnostics correctness | **FAIL** (F-08, F-12, F-13, F-14) |
| Lifecycle and default-state coherence | **FAIL** (F-09) |
| Test suite as a regression gate | **FAIL — the suite cannot fail** (F-01) |

### 1.2 Findings by severity

| Severity | Count | IDs |
| --- | --- | --- |
| **P0** — undefined behaviour with memory corruption / UAF / total realtime failure | **0** | — |
| **P1** — audible damage, crash, severe concurrency error, broken primary API guarantee | **2** | F-01, F-02 |
| **P2** — wrong behaviour, incomplete diagnostics, numeric boundary, significant performance | **7** | F-03, F-04, F-05, F-06, F-07, F-08, F-09 |
| **P3** — maintainability, documentation, portability, minor efficiency | **11** | F-10 … F-20 |
| **Total** | **20** | |

### 1.3 Most serious confirmed defects

1. **F-01 (P1, RUNTIME_OBSERVED) — the DSP test suite can never fail.** `packages/dsp/tests/test_utils.h:24` declares `static TestStats g_test_stats;` *inside a header*. Every translation unit therefore gets its own copy. `ASSERT()` increments the copy belonging to the test-case TU; `run_all_tests()` (in `test_main.cpp`) compares its own, untouched copy. An injected, deliberately failing assertion printed `❌ FAIL`, the test still rendered `✓`, the summary still read **`Results: 0 passed, 0 failed`**, the binary still exited **0**, and `ctest` still reported **1/1 Passed**. Every historical "all DSP tests pass" statement for this package is therefore unsupported.
2. **F-02 (P1, STATIC) — the documented thread-safe parameter-update API is a data race.** `soundbridge_dsp.h:202-230` advertises `update_band_gain()` / `update_preamp()` as "REALTIME-SAFE: **Queues** parameter change … Safe to call from UI thread while audio is processing". There is no queue. `Biquad::setCoeffsSmooth()` (`biquad.h:99`) writes `target_coeffs_`, `coeffs_delta_`, `transition_remaining_` and **reads** `coeffs_`, while the audio thread concurrently **writes** `coeffs_` per sample in `processSampleMono()` (`biquad.h:162-166`). All of these fields are plain `float`/`int`. This is a C++ data race, i.e. undefined behaviour, in exactly the scenario the header promises to support.
3. **F-09 (P2, STATIC) — a fresh engine is internally inconsistent.** The constructor sets `num_active_bands = 0` (`engine.cpp:65`) *after* `soundbridge_dsp_preset_init_flat()` has set `current_preset.num_bands = 10` (`preset.cpp:18`). Until a preset is applied, `soundbridge_dsp_get_preset()` reports a 10-band preset while every `soundbridge_dsp_update_band_*()` silently returns at the `band_index >= num_active_bands` guard.

### 1.4 Can it be used safely under its documented concurrency contract?

**No.** The documented contract is unsafe in two independent ways: the realtime update path races with the audio thread (F-02), and `get_stats()` is documented as "Safe to call from any thread" (`soundbridge_dsp.h:273`) while reading non-atomic `engine->sample_rate` (`engine.cpp:606`).

It *can* be used safely under a narrower, undocumented discipline: **every DSP entry point called on one single thread** (the audio thread), with `set_sample_rate()` performed only after the audio device is provably stopped. The shipping Host happens to satisfy this — see §3.4 — which is why these defects are latent rather than audible in the current product. That is a property of the *caller*, not of the library, and nothing in the library enforces or detects it.

### 1.5 What is genuinely good, and should not be "fixed"

- The processing path performs **no heap allocation, takes no locks, opens no files, and logs nothing**. Both `process_*` entry points are strictly `O(num_frames × num_active_bands)` with `num_active_bands ≤ 10`.
- Biquad magnitude accuracy is **exact to the measured resolution** (≤ 0.001 dB) for a +6 dB / 1 kHz peak band at 8 k, 16 k, 24 k, 32 k, 44.1 k, 48 k, 96 k, 192 k and 384 kHz (§5.4, Table A).
- The `warp_factor = w0 / sin(w0)` term in `calculateCoeffs()` is a legitimate bilinear-warp Q compensation, not a bug — the measurement in §5.4 confirms it.
- The soft-limiter curve is continuous across the knee (no discontinuity at `0.8 × threshold`), monotonic, sign-preserving, and bounded by the threshold for every input up to ≈1.7 × 10^38 (§5.6).
- The DC blocker is a textbook one-pole high-pass: −3.009 dB at the 5 Hz design corner, ≈0 dB from 100 Hz up, with an exact corner at every sample rate because the clamp `[0.95, 0.9999]` never engages over 8 kHz–384 kHz (§5.7).
- `processor_*` correctness under aliasing (`input == output`) is handled: the interleaved path guards the `memcpy` (`engine.cpp:203`) and the planar path guards both channels (`engine.cpp:317`).

---

## 2. Repository and Source Inventory

### 2.1 Files in scope

Measured with `wc -l`. All paths relative to `packages/dsp/`.

| Layer | File | LOC | Role |
| --- | --- | --- | --- |
| **Public API** | `include/soundbridge_dsp.h` | 315 | The C ABI and the *documented contract* under audit |
| | `include/soundbridge_types.h` | 90 | POD types: `soundbridge_band_t`, `soundbridge_preset_t`, `soundbridge_stats_t`, `soundbridge_error_t` |
| **Engine** | `src/engine.cpp` | 628 | Engine struct, all 19 public functions |
| **DSP internals** | `src/biquad.h` | 335 | Header-only DF2T biquad, RBJ coefficient design, per-sample coefficient interpolation |
| | `src/smoothing.h` | 141 | Header-only `ParameterSmoother` (velocity-assisted one-pole) |
| | `src/limiter.h` | 126 | Header-only `SoftLimiter` (rational knee) + unused `HardClipper` |
| | `src/dc_blocker.h` | 135 | Header-only `DCBlocker` / `StereoDCBlocker` (one-pole high-pass) |
| | `src/cpu_util.h` | 97 | FTZ/DAZ control, unused `denormal_offset()` |
| **Translation units** | `src/biquad.cpp`, `src/smoothing.cpp`, `src/limiter.cpp` | 12 / 11 / 11 | Deliberate stubs: `#include` only, to give the header-only modules a TU |
| | `src/preset.cpp` | 100 | `preset_init_flat`, `preset_validate` |
| | `src/version.cpp` | 14 | `get_version` |
| **Tests** | `tests/test_utils.h` | 251 | Assertion macros + `TestStats` + `run_all_tests()` (see F-01) |
| | `tests/test_main.cpp` | 98 | `main()` → `run_all_tests()` |
| | `tests/test_engine.cpp` | 436 | 13 tests |
| | `tests/test_biquad.cpp` | 263 | 6 tests |
| | `tests/test_frequency_response.cpp` | 379 | 6 tests |
| | `tests/test_preset.cpp` | 80 | 5 tests |
| | `tests/test_smoothing.cpp` | 101 | 5 tests |
| **Bridge** | `bridge/SoundBridgeDSPEngine.h` | 154 | Obj-C facade |
| | `bridge/SoundBridgeDSPEngine.mm` | 360 | Obj-C++ wrapper over the C ABI |
| **Tool** | `tools/wav_processor.cpp` | 380 | Offline WAV driver |
| **Build** | `CMakeLists.txt` | 159 | Static lib + tests + bridge + tools |

Total in-scope: **4 483 LOC**.

### 2.2 Public symbol inventory (19 functions)

`soundbridge_dsp_create`, `_destroy`, `_reset`, `_set_sample_rate`, `_process_interleaved`, `_process_planar`, `_apply_preset`, `_get_preset`, `_preset_init_flat`, `_preset_validate`, `_set_bypass`, `_get_bypass`, `_update_band_gain`, `_update_preamp`, `_update_band_frequency`, `_update_band_q`, `_get_stats`, `_get_version`, `_enable_denormal_suppression`.

### 2.3 Engine state layout (`engine.cpp:28-60`)

```
  sample_rate                  uint32_t                 NON-ATOMIC
  bands[10]                    Biquad × 10              NON-ATOMIC (coeffs_, target_coeffs_,
                                                        coeffs_delta_, transition_remaining_,
                                                        state_left_, state_right_)
  num_active_bands             uint32_t                 NON-ATOMIC
  current_preset               soundbridge_preset_t     NON-ATOMIC (280 bytes)
  preamp_smoother              ParameterSmoother        NON-ATOMIC (current_, target_, velocity_)
  coeff_transition_samples     int                      NON-ATOMIC (set only at create / set_sample_rate)
  limiter                      SoftLimiter              NON-ATOMIC (threshold_, knee_start_)
  limiter_enabled              bool                     NON-ATOMIC
  dc_blocker                   StereoDCBlocker          NON-ATOMIC (state only)
  bypass                       std::atomic<bool>        ATOMIC
  frames_processed             std::atomic<uint64_t>    ATOMIC
  underrun_count               std::atomic<uint32_t>    ATOMIC
  cpu_load_percent             std::atomic<float>       ATOMIC
  peak_left / peak_right       std::atomic<float>       ATOMIC
```

Only 6 of 16 members are atomic, and none of the six participate in the parameter-update path except `bypass`. This layout is the direct cause of F-02, F-03, F-04 and F-05.

### 2.4 Struct ABI (measured on the audited build)

Measured with a probe linked against `packages/dsp/build/libsoundbridge_dsp.a`:

```
sizeof(soundbridge_band_t)    = 20
sizeof(soundbridge_preset_t)  = 280
sizeof(soundbridge_stats_t)   = 32
offsetof(preset, preamp_db)   = 204
offsetof(preset, name)        = 216
```

`soundbridge_preset_t` is memcpy'd wholesale (`engine.cpp:457`, `:494`), so its layout is ABI. The Host carries a **second, hand-maintained copy** of the header (§5.11, F-18) with no automated layout check comparable to `tools/check_protocol_layout.sh` (which covers `RFSharedAudio.h`, not this header).

### 2.5 Build configuration (`CMakeLists.txt`, verified against `build/CMakeFiles/soundbridge_dsp.dir/flags.make`)

```
-O3 -DNDEBUG -std=c++17 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0
-Wall -Wextra -Wpedantic -Wno-unused-parameter -O3 -ffast-math -fno-finite-math-only
-Xarch_arm64 -mcpu=apple-m1 -Xarch_x86_64 -msse4.2
```

The Debug configuration substitutes `-O0 -g -fsanitize=address` and links the ASan runtime (`CMakeLists.txt:28-36`). There is **no** ThreadSanitizer configuration and no UBSan configuration anywhere in the package. `-fno-finite-math-only` appears *after* `-ffast-math` in the emitted command line, which is the order that matters for clang: `std::isfinite()` retains its semantics. `-ffast-math` nevertheless still implies `-funsafe-math-optimizations`, `-freciprocal-math`, `-fassociative-math` and `-fno-signed-zeros` (F-16).

---

## 3. Architecture and Execution Flow

### 3.1 Signal chain (fixed order, no reordering possible)

```
input L/R
   │
   ├─ [1] bypass? ──yes──▶ memcpy / no-op + peak-meter decay ──▶ return (frames_processed += n)
   │        no
   ├─ [2] preamp       ParameterSmoother::next()  (10 ms one-pole, velocity-assisted)
   │                   — skipped entirely when isStable() (block-rate shortcut)
   ├─ [3] EQ×N         Biquad::processSample / processBuffer, N = num_active_bands ≤ 10,
   │                   each stage gated by current_preset.bands[i].enabled
   │                   per-sample linear coefficient interpolation for 10 ms after a change
   ├─ [4] DC blocker   StereoDCBlocker, one-pole HPF, fc = 5 Hz, independent L/R state
   ├─ [5] limiter      SoftLimiter, threshold −0.1 dBFS, knee starts at 0.8 × threshold
   │                   — gated by limiter_enabled
   ├─ [6] meters       per-block peak → 300 ms exponential decay → atomic peak_left/right
   │                   (measured AFTER the limiter — see F-12)
   └─ [7] stats        2 × high_resolution_clock, CPU% EMA (500 ms), frames_processed += n
```

### 3.2 Call graph (production only; excludes tests and tools)

```
App (SwiftUI)
 └─ EQController  ──writes──▶ shared memory EQ snapshot (seqlock)
                                │
Host (audio device IO thread)   ▼
 └─ AudioRenderer.render()  ── rf_load_eq_snapshot_safe() ──▶ dspEngine
      ├─ soundbridge_dsp_update_band_gain()      × up to 10   (:622)   ┐
      ├─ soundbridge_dsp_update_preamp()                     (:626)   ├ same callback,
      ├─ soundbridge_dsp_set_bypass()                        (:627)   │ same thread as (★)
      └─ soundbridge_dsp_process_interleaved()               (:633)   ┘
                                                        ★
Host (control / main thread)
 └─ AudioRenderer.init        → soundbridge_dsp_create / apply_preset   (:243, :247)
 └─ AudioRenderer.deinit      → soundbridge_dsp_destroy                (:254)
 └─ AudioRenderer.updateSampleRate
        waitForRenderPathIdle(...) ──▶ soundbridge_dsp_set_sample_rate (:468)
 └─ AudioRenderer.takeDiagnostics → soundbridge_dsp_get_bypass         (:278)
```

### 3.3 Thread attribution of each entry point

| Entry point | Documented thread rule | Actual production call site | Thread |
| --- | --- | --- | --- |
| `create` | "main thread" | `AudioRenderer.init:243` | control |
| `destroy` | "main thread" | `AudioRenderer.deinit:254` | control (`deinit`) |
| `reset` | "not realtime-safe with concurrent processing" | **none** | — |
| `set_sample_rate` | "NOT realtime-safe" | `updateSampleRate:468`, behind `waitForRenderPathIdle` | control, quiesced |
| `process_interleaved` | "audio thread only" | `render:633` | **IO thread** |
| `process_planar` | "audio thread only" | **none** (tests + `wav_processor` only) | — |
| `apply_preset` | "NOT realtime-safe" | `applyInitialPreset:758` (from `init`) | control |
| `get_preset` | — | **none** | — |
| `set_bypass` | "any thread, lock-free" | `render:627` | **IO thread** |
| `get_bypass` | "any thread" | `takeDiagnostics:278` | control |
| `update_band_gain` | "any thread; safe from UI while processing" | `render:622` | **IO thread** |
| `update_preamp` | "any thread; safe from UI while processing" | `render:626` | **IO thread** |
| `update_band_frequency` | "any thread" | **none** — not even declared in the Host's header copy | — |
| `update_band_q` | "any thread" | **none** — same | — |
| `get_stats` | "any thread (reads atomic counters)" | **none** | — |
| `enable_denormal_suppression` | "call once from the audio thread" | **none** | — |
| `get_version` | — | **none** in DSP; used by release tooling | — |

Three consequences follow directly from this table, and they drive the severity assignments:

1. **Every realtime parameter update in the shipping product executes on the same thread as `process_interleaved`.** The F-02 race therefore *cannot* fire as integrated today; it is latent. Any client that does what the header says — nudge an EQ slider from the UI thread during playback — activates it immediately.
2. **Seven of nineteen functions have zero production callers.** `reset`, `process_planar`, `get_preset`, `get_stats`, `update_band_frequency`, `update_band_q`, `enable_denormal_suppression`. Their correctness is unverified by field use.
3. `set_sample_rate` is the only configuration mutation that is correctly serialised: `AudioEngine.swift:215-228` documents that it runs after `AudioOutputUnitStop`, and `AudioRenderer.updateSampleRate` gates on `memoryManager.waitForRenderPathIdle(timeout:)` before touching the engine. This is exactly what F-04 says the library itself does not provide.

### 3.4 Why the product currently sounds correct

`AudioRenderer.render()` is the only place that touches a live engine from the audio side, and it performs *all* its DSP interaction — snapshot load, up to ten band-gain writes, the preamp write, the bypass write, and the process call — inside one callback on one thread. The control-thread interactions (`init`, `deinit`, `set_sample_rate`, `get_bypass`) are either before the engine is published to the audio side, after it is torn down, or explicitly quiesced. The integration is, by construction, single-threaded with respect to the engine. **Nothing in the DSP library detects or enforces this.** F-02 is a defect in the library's contract, not a live bug in the Host.

### 3.5 Parameter-update data flow (the F-02 mechanism, in detail)

```
UI thread                                    Audio thread
─────────                                    ────────────
update_band_gain(engine, i, g)
  clamp g (-12..+12)
  current_preset.bands[i].gain_db = g        ┐  (torn read of current_preset
                                              │   is possible — F-04)
  Biquad::setCoeffsSmooth(band, fs, n)        │
    c = calculateCoeffs(...)                  │
    if !isFinite(c) { setCoeffsFlat(); }      │
    target_coeffs_   = c          ← WRITE     │
    coeffs_delta_.*  = (c - coeffs_.*) / n    │
                        ↑ READ coeffs_  ──────┼──▶  if (transition_remaining_ > 0)
    transition_remaining_ = n     ← WRITE     │       coeffs_.b0 += coeffs_delta_.b0;   ← WRITE
                                              │       ... (5 fields)
                                              │       if (--transition_remaining_ == 0)
                                              │           coeffs_ = target_coeffs_;     ← READ
                                              │     output = coeffs_.b0 * input + z1;    ← READ
```

There is no `std::atomic`, no memory fence, no queue, and no seqlock anywhere on this path. The header's word "**Queues**" describes an implementation that does not exist.

---

## 4. Public API Contract Audit

Legend for **Result**: MATCH / PARTIAL / MISMATCH / UNVERIFIED. Evidence citations are `file:line`.

| # | API | Documented contract (verbatim from `soundbridge_dsp.h`) | Actual implementation | Result | Evidence |
| --- | --- | --- | --- | --- | --- |
| 1 | `soundbridge_dsp_create` | "allocates memory. Do NOT call from audio thread." Returns `NULL` on failure. | Validates `8000 ≤ fs ≤ 384000`, then `new` inside `try/catch(...)`. | **MATCH** | `engine.cpp:105-115` |
| 2 | `soundbridge_dsp_destroy` | "deallocates memory. Do NOT call from audio thread." | `delete engine` (arguments never validated in practice: `NULL` is safe in C++). | **MATCH** | `engine.cpp:117-121` |
| 3 | `soundbridge_dsp_reset` | "Not realtime-safe with concurrent processing." Clears filter history; "useful when seeking or recovering from underrun." | Resets all 10 biquads, the DC blocker, snaps the preamp ramp to target, and zeroes all five atomics. Does **not** reset `current_preset`, `num_active_bands`, or `limiter_enabled` (correct — those are configuration, not state). | **MATCH** | `engine.cpp:123-150` |
| 4 | `soundbridge_dsp_set_sample_rate` | "Recalculates coefficients and reinitializes related state. NOT realtime-safe." | Rejects out-of-range with `SOUNDBRIDGE_ERROR_INVALID_PARAM`; stores `sample_rate`; re-inits the smoother **carrying the current gain across**; recomputes `coeff_transition_samples`; re-inits the DC blocker; re-applies the engine's own preset. | **MATCH** | `engine.cpp:153-183` |
| 5 | `soundbridge_dsp_process_interleaved` | "REALTIME-SAFE: No heap allocations or locks in the processing path." Audio thread only. | No allocation, no lock, no I/O. `O(n·N)`, `N ≤ 10`. Aliasing guarded. Two `high_resolution_clock::now()` calls per callback. | **MATCH** (see F-12, F-17) | `engine.cpp:189-299` |
| 6 | `soundbridge_dsp_process_planar` | Same. | Same, plus an unconditional input→output copy guarded by `input != output`. | **MATCH** (see F-12) | `engine.cpp:301-429` |
| 7 | `soundbridge_dsp_apply_preset` | "NOT realtime-safe." Returns `soundbridge_error_t`. | Validates the preset (incl. finiteness and all ranges), copies into `current_preset`, sets all band coefficients **without smoothing**, sets the preamp target, sets `limiter_enabled` and the threshold. | **PARTIAL** — publishes `num_active_bands` before the coefficients (F-03); no torn-write protection against a concurrent audio thread (F-04). | `engine.cpp:435-484` |
| 8 | `soundbridge_dsp_get_preset` | — | `memcpy` of `current_preset` out. | **PARTIAL** — on a fresh engine it reports `num_bands = 10` while the engine runs 0 bands (F-09). | `engine.cpp:486-497` |
| 9 | `soundbridge_dsp_preset_init_flat` | "flat response (all bands disabled)" | `memset` + 10 ISO frequencies, `q = 1.0`, `PEAK`, `enabled = false`, `num_bands = 10`, `limiter_enabled = false`. | **MATCH** | `preset.cpp:10-49` |
| 10 | `soundbridge_dsp_preset_validate` | Returns an error code for invalid presets. | Rejects `num_bands == 0` or `> 10`; rejects non-finite `frequency_hz` / `gain_db` / `q_factor`; enforces `20…20000 Hz`, `−12…+12 dB`, `Q 0.1…10`, `type` range; rejects non-finite `preamp_db` / `limiter_threshold_db`; enforces `−12…+12 dB` preamp and `−6…0 dB` threshold. | **MATCH** | `preset.cpp:51-100` |
| 11 | `soundbridge_dsp_set_bypass` | "REALTIME-SAFE: Uses atomic operation, safe to call from any thread." | Single `bypass.store(relaxed)`. | **MATCH** | `engine.cpp:502-506` |
| 12 | `soundbridge_dsp_get_bypass` | "REALTIME-SAFE" | Single `bypass.load(relaxed)`; returns `true` for a `NULL` engine. | **MATCH** | `engine.cpp:508-510` |
| 13 | `soundbridge_dsp_update_band_gain` | "REALTIME-SAFE: **Queues** parameter change, applied with smoothing." "Safe to call from UI thread while audio is processing." "Changes are applied over ~10ms." | Direct, unsynchronised writes into `current_preset.bands[i].gain_db` and into four non-atomic `Biquad` fields, reading a fifth that the audio thread writes. No queue. Clamps to `±12` **before** validating, so `NaN` becomes `+12`. | **MISMATCH** | F-02, F-06; `engine.cpp:512-530`, `biquad.h:99-123` |
| 14 | `soundbridge_dsp_update_preamp` | Same as #13. | Writes `current_preset.preamp_db` and `preamp_smoother.target_` (plain `float`). `NaN → +12 dB`. | **MISMATCH** | F-02, F-06; `engine.cpp:533-548`, `smoothing.h:61` |
| 15 | `soundbridge_dsp_update_band_frequency` | "REALTIME-SAFE: Changes are applied with smoothing." | Same shape; clamps to `20…20000 Hz`, so `NaN → 20000`. | **MISMATCH** | F-02, F-06; `engine.cpp:550-569` |
| 16 | `soundbridge_dsp_update_band_q` | "REALTIME-SAFE: Changes are applied with smoothing." | Same shape; clamps to `0.1…10`, so `NaN → 10`. | **MISMATCH** | F-02, F-06; `engine.cpp:571-594` |
| 17 | `soundbridge_dsp_get_stats` | "**Safe to call from any thread (reads atomic counters)**." | Reads five atomics **and one non-atomic `uint32_t sample_rate`**. dB conversion has a floor of −120 but **no ceiling**. | **MISMATCH** | F-04, F-08; `engine.cpp:596-620` |
| 18 | `soundbridge_dsp_get_version` | Returns the library version string. | Returns the compile-time `SOUNDBRIDGE_DSP_VERSION`, defaulting to `"1.0.0-dev"`. | **PARTIAL** — CMake injects `"1.0.0"`, which is the CMake project version, not the repository `VERSION` (1.2.0) (F-20). | `version.cpp:9-14` |
| 19 | `soundbridge_dsp_enable_denormal_suppression` | "This affects only the calling thread." "Automatically called in `soundbridge_dsp_create()`, but you should also call this once from your audio thread." | Sets FTZ/DAZ (x86) or FPCR.FZ (arm64) on the calling thread. Called from the constructor. **Zero other call sites in the tree.** | **MISMATCH (as used)** — creating thread is the control thread, so the audio thread runs with denormals enabled (F-15). | `cpu_util.h:30-62`, `engine.cpp:74`, `engine.cpp:626-628` |

### 4.1 Header-level contradictions

Two statements in the same header cannot both hold:

- `soundbridge_dsp.h:11` — "Parameter updates: Thread-safe (can call from any thread)".
- `soundbridge_dsp.h:17` — "All other functions may allocate and should not be called from audio thread", where "other" excludes only `process_*` and `set_bypass` — and therefore excludes the four `update_*` functions, even though each of those carries a `@note REALTIME-SAFE` of its own.

A client reading only line 11 will call `update_band_gain` from the UI thread. A client reading only line 17 will not call it at all. Neither reader learns the truth: the function is allocation-free but **not** synchronised.

---

## 5. Detailed Technical Findings

Each finding carries all twelve required elements. **Confirmation** is either `CONFIRMED (RUNTIME_OBSERVED)` — reproduced by executing the audited build — or `CONFIRMED (STATIC)` — established by reading the code against the C++ memory model, with the reasoning given. Nothing below is labelled confirmed on the strength of a comment.

### 5.1 Thread safety

#### F-01 — The DSP test suite is structurally incapable of reporting a failure

| | |
| --- | --- |
| **Severity** | **P1** |
| **Confirmation** | **CONFIRMED (RUNTIME_OBSERVED)** — three independent experiments |
| **Location** | `packages/dsp/tests/test_utils.h:24`, `:39-46`, `:78`, `:80-107`; `packages/dsp/tests/test_main.cpp:97` |

**Code excerpt** (`test_utils.h`):

```cpp
struct TestStats { int passed = 0; int failed = 0; };

static TestStats g_test_stats;            // :24  ← static, in a HEADER

#define ASSERT(condition) \                  // :39
    do { if (!(condition)) { \
        std::cerr << "❌ FAIL: " << __FILE__ << ":" << __LINE__ << ": " << #condition << std::endl; \
        g_test_stats.failed++; return; } } while(0)

#define PASS() g_test_stats.passed++          // :78

static int run_all_tests() {                  // :80
    ...
    for (const auto& [name, func] : tests) {
        int failed_before = g_test_stats.failed;   // :90
        func();
        if (g_test_stats.failed == failed_before) std::cout << " ✓";   // :94
        else                                      std::cout << " ✗";
    }
    ...
    return (g_test_stats.failed == 0) ? 0 : 1;    // :106
}
```

**Technical explanation.** `static` at namespace scope inside a header gives every translation unit its own object with internal linkage. The suite is built from five test-case TUs plus `test_main.cpp`. `ASSERT()` is expanded *inside the test-case TU*, so `g_test_stats.failed++` mutates that TU's private copy. `run_all_tests()` is compiled inside `test_main.cpp` and reads *its* copy, which no other TU can ever touch. `failed_before == g_test_stats.failed` is therefore unconditionally true, every test prints `✓`, the summary prints `0 passed, 0 failed`, and `main()` returns 0. `ctest` sees exit status 0 and reports PASS.

**Trigger condition.** Any failing assertion, anywhere, at any time.

**Expected impact.** The package's entire automated verification layer is a no-op gate. Every green DSP test run in the project's history — including the `ctest` result cited by release reports — is uninformative. This is the reason F-01 is P1 rather than P3: it invalidates the evidence for *all other* findings, in both directions.

**Existing test coverage.** None — the harness is the thing that is broken.

**Recommended fix direction.** Replace the header-scope `static` with a single definition: declare `extern TestStats g_test_stats;` in the header and define it once in `test_main.cpp` (or wrap the counter in a function-local `static` inside an `inline` accessor, which C++ guarantees is a single object). Then make the runner return non-zero.

**Verification standard.** Inject one deliberately false assertion into a test-case TU; require: the binary prints `✗` for that test, the summary reports `1 failed`, the process exit status is non-zero, and `ctest` reports failure. Then delete the injection.

**Experiment 1 — single-TU control.** A standalone probe that puts the test case and `run_all_tests()` in *one* TU:

```
❌ FAIL: harness_probe.cpp:12: 1 == 2
Results: 0 passed, 1 failed
EXIT_CODE=1
```

This proves the macros and the runner are individually correct — the defect is purely the per-TU duplication.

**Experiment 2 — two-TU reproduction.** `t_case.cpp` holds only the failing test; `t_main.cpp` holds `run_all_tests()` and `main()`, exactly mirroring the real layout:

```
❌ FAIL: t_case.cpp:6: 1 == 2
Running: always_fails... ✓
Results: 0 passed, 0 failed
EXIT_CODE=0
```

The `❌` is printed, the test is scored `✓`, and the process exits successfully.

**Experiment 3 — the real suite, injected.** A copy of `packages/dsp/tests/` was taken outside the repository, one `ASSERT(engine == nullptr)` (guaranteed false immediately after a successful `create`) was added to `engine_create_destroy`, and the copy was built and run:

```
BINARY_EXIT_CODE=0
tests with ✓ : 35
tests with ✗ : 0
❌ FAIL: test_engine.cpp:14: engine == nullptr      ← printed to stderr
Results: 0 passed, 0 failed
ctest: 1/1 Test #1: soundbridge_dsp_tests ... Passed  0.01 sec
```

A test that demonstrably fails still yields a fully green build.

---

#### F-02 — The realtime parameter-update path is a data race (documented as "queued" and "thread-safe")

| | |
| --- | --- |
| **Severity** | **P1** |
| **Confirmation** | **CONFIRMED (STATIC)** — by the C++ memory model; the precise interleaving is given below |
| **Location** | `packages/dsp/src/biquad.h:99-123`, `:159-186`, `:325-330`; `packages/dsp/src/smoothing.h:61-68`, `:83-100`, `:119-122`; `packages/dsp/src/engine.cpp:512-594`; contract at `packages/dsp/include/soundbridge_dsp.h:11`, `:202-260` |

**Code excerpt — the writer (control thread), `biquad.h:99`:**

```cpp
void setCoeffsSmooth(const soundbridge_band_t& band, float sample_rate, int transition_samples) {
    BiquadCoeffs c = calculateCoeffs(band, sample_rate);
    if (!isFinite(c)) { setCoeffsFlat(); return; }
    target_coeffs_ = c;                                        // WRITE
    if (transition_samples <= 0) { coeffs_ = target_coeffs_; transition_remaining_ = 0; return; }

    const float inv_n = 1.0f / static_cast<float>(transition_samples);
    coeffs_delta_.b0 = (target_coeffs_.b0 - coeffs_.b0) * inv_n;   // READ coeffs_ (audio thread writes it)
    coeffs_delta_.b1 = (target_coeffs_.b1 - coeffs_.b1) * inv_n;   // READ
    coeffs_delta_.b2 = (target_coeffs_.b2 - coeffs_.b2) * inv_n;   // READ
    coeffs_delta_.a1 = (target_coeffs_.a1 - coeffs_.a1) * inv_n;   // READ
    coeffs_delta_.a2 = (target_coeffs_.a2 - coeffs_.a2) * inv_n;   // READ
    transition_remaining_ = transition_samples;                     // WRITE
}
```

**Code excerpt — the reader/writer (audio thread), `biquad.h:159`:**

```cpp
inline float processSampleMono(float input, BiquadState& state) {
    if (transition_remaining_ > 0) {
        coeffs_.b0 += coeffs_delta_.b0;      // WRITE coeffs_
        coeffs_.b1 += coeffs_delta_.b1;
        coeffs_.b2 += coeffs_delta_.b2;
        coeffs_.a1 += coeffs_delta_.a1;
        coeffs_.a2 += coeffs_delta_.a2;
        if (--transition_remaining_ == 0) {
            coeffs_ = target_coeffs_;        // READ target_coeffs_
        }
    }
    float output = coeffs_.b0 * input + state.z1;   // READ coeffs_
    ...
}
```

**Storage, `biquad.h:325-330` — all plain, all non-atomic:**

```cpp
BiquadCoeffs coeffs_;
BiquadCoeffs target_coeffs_;
BiquadCoeffs coeffs_delta_;
int transition_remaining_ = 0;
```

`ParameterSmoother` is the same story (`smoothing.h:119-122`: `velocity_coeff_`, `current_`, `target_`, `velocity_` are plain `float`), written by `setTarget()` (`:61`) on the caller's thread and read/written by `next()` (`:83`) on the audio thread.

**Technical explanation.** C++ [intro.races] declares a data race when two threads access the same memory location concurrently, at least one access is a write, and the accesses are not ordered by a happens-before edge. Here `coeffs_.b0` (and four siblings) is written by `processSampleMono()` on the audio thread and *read* by `setCoeffsSmooth()` on the caller's thread. `transition_remaining_` is written by both. `target_coeffs_` is written by `setCoeffsSmooth()` and read by `processSampleMono()` at the snap. No atomic, no fence, no lock, no queue exists on this path. Every one of those accesses is a race; the standard makes the outcome undefined — not merely "possibly one stale sample".

The practical failure modes, if the race did fire, would be a torn `BiquadCoeffs` (six floats written non-atomically, so a filter can briefly run with `b0` from the new design and `a2` from the old — a pole set that may be outside the unit circle), plus a corrupted interpolation ramp producing a click at the exact moment the user expects smoothing to prevent one.

**Trigger condition.** Concurrent `soundbridge_dsp_update_band_gain` / `_update_preamp` / `_update_band_frequency` / `_update_band_q` and `soundbridge_dsp_process_*`, i.e. exactly the usage the header prescribes.

**Expected impact.** Undefined behaviour. In practice: click/pop, momentary filter instability, or a corrupted coefficient ramp. As integrated in the shipping Host the race cannot fire (§3.4) — this is a latent contract defect, which is why it is P1 and not P0.

**Existing test coverage.** None. There is no concurrency test, no TSan configuration, and `ctest` could not have reported one anyway (F-01).

**Recommended fix direction.** Two options, in order of preference:

1. **Make the claim true.** Publish parameter changes through a lock-free single-producer/single-consumer mailbox: the control thread writes a `std::atomic<uint32_t>` "generation" plus the payload into a double-buffered slot with release/acquire; the audio thread consumes at block start. This is the "queue" the comment already claims.
2. **Make the contract honest.** Downgrade the documentation to "not thread-safe; call from the audio thread only", and add an assertion or a debug-only thread-id check. Then the Host's current pattern becomes the documented one.

Additionally, `setCoeffsSmooth`'s read of `coeffs_` must remain on whichever side owns `coeffs_` under option 1.

**Verification standard.** Build with `-fsanitize=thread` and run a test that hammers `update_band_gain` from a second thread while `process_interleaved` runs on the audio thread; require zero TSan reports. Under option 2, a debug build must abort when the wrong thread calls an update function.

---

#### F-03 — `apply_preset` publishes `num_active_bands` before the coefficients

| | |
| --- | --- |
| **Severity** | **P2** |
| **Confirmation** | **CONFIRMED (STATIC)** |
| **Location** | `packages/dsp/src/engine.cpp:457-471` |

**Code excerpt:**

```cpp
if (preset != &engine->current_preset) {
    std::memcpy(&engine->current_preset, preset, sizeof(soundbridge_preset_t));
}
engine->num_active_bands = preset->num_bands;                     // :459  ← published FIRST

for (uint32_t i = 0; i < preset->num_bands; i++) {                // :462
    const soundbridge_band_t& band = preset->bands[i];
    if (band.enabled) engine->bands[i].setCoeffs(band, (float)engine->sample_rate);
    else              engine->bands[i].setCoeffsFlat();
}
```

**Technical explanation.** The loop bound in both process paths is `engine->num_active_bands` (`engine.cpp:238`, `:362`). Raising `num_active_bands` from 1 to 10 at `:459` makes bands 1…9 visible to the audio thread immediately, but their coefficients are still whatever the previous preset left there (or flat, for a fresh engine) until `:462-471` finishes. `apply_preset` is documented "NOT realtime-safe", so a client must not do this concurrently — but the write ordering makes the window strictly larger than it needs to be, and it is the *only* ordering that can produce the specific artefact "new bands audible with stale coefficients".

**Trigger condition.** `apply_preset` concurrent with processing (contract violation by the caller, but the library makes the resulting artefact as bad as possible).

**Expected impact.** One block of audibly wrong EQ (up to 10 bands of stale response) instead of one block of the previous preset.

**Existing test coverage.** None.

**Recommended fix direction.** Compute all ten biquad coefficient sets first, then publish `num_active_bands` last with a release store. Better: fold into F-02's mailbox so the whole preset swap is atomic.

**Verification standard.** A test that flips between a 1-band and a 10-band preset while processing, asserting that every output block matches either the old or the new response within tolerance — never a third, blended one.

---

#### F-04 — Configuration fields read by the audio thread are not protected on any path

| | |
| --- | --- |
| **Severity** | **P2** |
| **Confirmation** | **CONFIRMED (STATIC)** |
| **Location** | `packages/dsp/src/engine.cpp:28-51` (fields), `:157` / `:435-481` (writers), `:238-251` / `:362-383` (readers), `:606` (the `get_stats` read) |

**Code excerpt — the audio-thread reads:**

```cpp
for (uint32_t band = 0; band < engine->num_active_bands; band++) {          // :238
    if (engine->current_preset.bands[band].enabled) {                       // :238-239
        engine->bands[band].processSample(left, right, &left, &right);
    }
}
engine->dc_blocker.processStereo(left, right, &left, &right);               // :246
if (engine->limiter_enabled) {                                              // :249
    engine->limiter.processSampleStereo(&left, &right);
}
if (bypass) {                                                                 // :201
    const float peak_decay_samples = ... engine->sample_rate ...;            // :207
}
```

**Code excerpt — the `get_stats` read that contradicts its own doc comment, `:606`:**

```cpp
stats->sample_rate = engine->sample_rate;   // plain uint32_t read
```

**Technical explanation.** Four distinct non-atomic fields are read by the processing path and written by configuration functions: `num_active_bands` (`apply_preset:459`), `current_preset` — a 280-byte struct read field-by-field inside the per-frame loop (`:239`) and memcpy'd wholesale by `apply_preset:457` and `get_preset:494` — `limiter_enabled` (`:478`), and `sample_rate` (`:157`). `sample_rate` is additionally read by `get_stats:606`, a function whose header note says "Safe to call from any thread (reads atomic counters)" — five of its six reads *are* atomic; the sixth is not, and it is the one that is written by `set_sample_rate`.

**Trigger condition.** Any configuration call overlapping processing, plus `get_stats` from a control thread while `set_sample_rate` runs — the latter being reachable **without** violating any documented rule.

**Expected impact.** A torn 280-byte `current_preset` can yield a band whose `enabled` flag and coefficient set disagree, or a `gain_db` that is a mix of two presets' bytes decoded as an arbitrary float. `get_stats` can report a sample rate that was never configured (e.g. the high half of 48000 with the low half of 44100).

**Existing test coverage.** None.

**Recommended fix direction.** Route all configuration through the F-02 mailbox. In the interim, make `sample_rate` a `std::atomic<uint32_t>` — it is written once per rate change and read once per callback, so the cost is nil — and stop documenting `get_stats` as race-free until the rest follows.

**Verification standard.** Same TSan harness as F-02, extended to `apply_preset`, `set_sample_rate` and `get_stats`.

---

#### F-05 — `SoftLimiter::setThreshold` writes two coupled fields without ordering

| | |
| --- | --- |
| **Severity** | **P2** |
| **Confirmation** | **CONFIRMED (STATIC)**, with the arithmetic consequence derived |
| **Location** | `packages/dsp/src/limiter.h:39-43`, `:48-69` |

**Code excerpt:**

```cpp
void setThreshold(float threshold_db) {
    threshold_   = std::pow(10.0f, threshold_db / 20.0f);   // :40  store 1
    knee_start_  = threshold_ * 0.8f;                       // :42  store 2 (reads store 1)
}

inline float processSample(float input) {
    const float abs_input = std::abs(input);
    if (!std::isfinite(abs_input)) return 0.0f;
    if (abs_input <= knee_start_) return input;                                  // uses knee_start_
    const float scaled = (abs_input - knee_start_) / (threshold_ - knee_start_);  // uses both
    const float limited = knee_start_ + (threshold_ - knee_start_) * (scaled / (1.0f + scaled));
    return (input < 0.0f) ? -limited : limited;
}
```

**Technical explanation.** A concurrent reader can observe the new `threshold_` together with the old `knee_start_`. Two bad cases follow from the algebra:

- **Tightening** (−0.1 dB → −6 dB, i.e. `threshold_` ≈ 0.989 → 0.501, old `knee_start_` = 0.791): `threshold_ - knee_start_` becomes **negative** (−0.290). For an input of 0.85 the code takes the `abs_input > knee_start_` branch, computes `scaled = 0.059 / (−0.290) = −0.203`, then `limited = 0.791 + (−0.290) · (−0.203 / 0.797) = 0.865`. The limiter **raises** a 0.85 sample to 0.865, i.e. above the new −6 dBFS threshold and with an inverted transfer curve.
- **Loosening** (−6 dB → −0.1 dB): old `knee_start_` = 0.401, new `threshold_` = 0.989. `threshold_ - knee_start_ = 0.588`, and a 0.5 input is attenuated 20·log10(0.5/0.487) ≈ +0.2 dB — a small but spurious gain bump.

**Trigger condition.** `soundbridge_dsp_apply_preset` with `limiter_threshold_db` different from the current value, concurrent with processing.

**Expected impact.** A short burst of gain *above* the configured ceiling — the one thing a limiter exists to prevent.

**Existing test coverage.** None; the only limiter test asserts `peak <= 1.0f`, which is 0.11 dB weaker than the actual threshold and would not notice either case.

**Recommended fix direction.** Derive `knee_start_` from `threshold_` inside `processSample` (one multiply, negligible), or publish both through a single 64-bit atomic, or make the pair immutable and swap the whole limiter through the F-02 mailbox.

**Verification standard.** A TSan run across a threshold sweep pinning the race; and a property test asserting `|out| <= 10^(thr/20)` for every input in `[0, 10]` while the threshold changes.

---

#### F-15 — Denormal suppression is applied to the wrong thread

| | |
| --- | --- |
| **Severity** | **P3** |
| **Confirmation** | **CONFIRMED (STATIC)**; the "no call sites" half is **CONFIRMED (RUNTIME_OBSERVED)** by tree-wide grep |
| **Location** | `packages/dsp/src/cpu_util.h:30-62`; `packages/dsp/src/engine.cpp:74`, `:626-628`; `packages/dsp/include/soundbridge_dsp.h:288-309` |

**Code excerpt:**

```cpp
// cpu_util.h — the config is per-thread hardware state, not per-process
inline void enable_denormal_suppression() {
#if defined(__aarch64__) || defined(__arm64__) || defined(_M_ARM64)
    uint64_t fpcr;
    __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
    fpcr |= (1 << 24);                       // FZ
    __asm__ __volatile__("msr fpcr, %0" :: "r"(fpcr));
#endif
}
```

```cpp
// engine.cpp:74 — the constructor. Which thread runs this?
soundbridge_dsp_engine(uint32_t sr) : ... {
    enable_denormal_suppression();          // control/main thread
    ...
}
```

**Technical explanation.** `FPCR` on arm64 and `MXCSR` on x86 are *per-thread* architectural state. The constructor runs on whichever thread calls `soundbridge_dsp_create()` — in the Host, `AudioRenderer.init` on the control thread (`AudioRenderer.swift:243`), not the CoreAudio IO thread. The audio thread's `FPCR` is therefore untouched, and denormal products inside the biquad and DC-blocker feedback paths are not flushed. The exported `soundbridge_dsp_enable_denormal_suppression()` exists precisely to fix this and has **zero call sites** in the entire repository (verified by grep over `apps/`, `packages/`, `tools/`, excluding `packages/dsp` and `build/`).

**Trigger condition.** Signal decaying toward silence — the biquad `z1`/`z2` and the DC blocker `y_prev_` will enter the subnormal range. On Apple silicon this is slow-path microcode, not a trap, so the impact is bounded.

**Expected impact.** A soft CPU spike on near-silent passages. With 10 bands × 2 channels × 2 state variables = 40 subnormal accumulators per sample, this can matter in a low-latency callback, but it will not cause a dropout on its own. Density of the effect is hard to bound analytically in this audit — see §7.2.

**Existing test coverage.** None.

**Recommended fix direction.** Either call the hook from the Host's render-thread setup (an integration change, one line in `AudioRenderer`), or make the engine set FTZ/DAZ lazily on the first `process_*` call per thread. The latter requires a thread-local "already applied" flag and is cheap.

**Verification standard.** Read `FPCR` bit 24 at the top of the first `process_interleaved` invocation on the IO thread and assert it is set.

---

### 5.2 Realtime safety

The two `process_*` entry points were audited against the standard realtime criteria: no heap allocation, no blocking synchronisation, no unbounded loops, no I/O, no logging, no exceptions.

| Criterion | Interleaved (`:189-299`) | Planar (`:301-429`) | Verdict |
| --- | --- | --- | --- |
| Heap allocation / free | none | none | **PASS** |
| Mutex / lock / condition variable | none | none | **PASS** |
| `new` / `delete` / `std::vector` / `std::string` | none | none | **PASS** |
| File, socket, `printf`, `os_log` | none | none | **PASS** |
| Exceptions thrown | none (`calculateCoeffs` is not called on this path) | none | **PASS** |
| Loop bounds | `num_frames × num_active_bands`, `num_active_bands ≤ 10` (`SOUNDBRIDGE_MAX_BANDS`) | same | **PASS** |
| Clock reads | 2 × `high_resolution_clock::now()` (`:198`, `:283`) | 2 × (`:313`, `:399`) | **acceptable** — see F-21 note |
| `std::pow` / `std::log10` in the block prologue | `std::exp` ×2 for decay, `std::exp` ×1 for the CPU EMA | same | **acceptable** — 3 callse per block, not per sample |
| Allocation in the *bypass* path | none | none | **PASS** |

**F-21 note (observation, not a register entry).** `high_resolution_clock::now()` on Darwin resolves to `mach_absolute_time()`, which reads the commpage — not a syscall and not a lock. The `@note "No heap allocations or locks"` claim therefore holds. It is listed here only so the "no system calls" phrasing in §4 row 5 is understood as satisfied in spirit rather than literally.

**The one realtime-safety violation is behavioural rather than structural**, and it is F-02: the update functions are *structurally* realtime-safe (no allocation, no lock, bounded) but the README-level promise "safe to call from the UI thread while audio is processing" is unimplementable with the current unsynchronised writes. A reader who equates "no lock" with "thread-safe" will be wrong, which is precisely the trap this audit was asked to avoid.

---

### 5.3 Biquad design — what the code actually computes

`calculateCoeffs()` (`biquad.h:195-322`) implements RBJ-style designs with two project-specific additions:

```cpp
const float rate     = (sample_rate > 0.0f) ? sample_rate : 48000.0f;
const float max_freq = rate * kMaxNormalisedFrequency;                 // 0.45 · fs   :213
const float freq     = std::fmin(std::fmax(band.frequency_hz, 1.0f), max_freq);   // :214
const float w0       = 2.0f * PI * freq / rate;
const float warp_factor = (w0 < 0.01f) ? 1.0f : w0 / std::sin(w0);     // :217
const float alpha    = sin_w0 / (2.0f * Q * warp_factor);              // :219
const float A        = std::pow(10.0f, gain_db / 40.0f);
```

1. **`kMaxNormalisedFrequency = 0.45`** (`biquad.h:24`) clamps every design frequency to 0.45·fs. This is the fix for the critical defect reported by the earlier audit (a 16 kHz high shelf evaluated at 24–31 kHz sample rates, where `w0 > π` and the shelf stops being minimum-phase). It is present in the working tree and absent from `HEAD` — see the note at the top of this report. §5.4 Table B verifies it empirically.
2. **`warp_factor = w0 / sin(w0)`** divides `alpha` by a bilinear-warping correction, equivalent to `alpha = sin²(w0) / (2·Q·w0)`. This is **not** textbook RBJ (`alpha = sin(w0)/(2Q)`) and looks like a bug on inspection. It is not: it compensates for the frequency-axis compression of the bilinear transform so that the *peak gain* lands on the requested centre frequency rather than slightly below it. §5.4 Table A shows the resulting magnitude error is below the 0.001 dB measurement resolution across a 48× sample-rate span, which is the empirical justification for calling this correct rather than suspicious.

Structural properties:

- **DF2T** topology: two state variables per channel, `z1`/`z2` (`biquad.h:170-171`), numerically the better choice for time-varying coefficients — which matters here, because the coefficients *are* time-varying.
- **Interpolation**: on a parameter change, `coeffs_delta_ = (target − current)/n` and `processSampleMono` walks the coefficients toward the target one step per sample, snapping exactly at `n` to defeat float drift (`biquad.h:167-170`). `n = coeff_transition_samples = fs × 0.01` (`engine.cpp:91`, `:177`), i.e. **10 ms**, matching the header's "~10ms" claim and contradicting the Host's copy of the header, which says "~50ms" (F-18).
- **Non-finite guard**: `if (!std::isfinite(output)) { z1 = z2 = 0; return input; }` (`biquad.h:179-183`). The state reset is correct. The **returned value is not** — see F-07.
- **Compile-time finiteness**: `calculateCoeffs` is guarded by `isFinite(c)` at the call sites (`biquad.h:101`, `:81`), so a NaN/inf design falls back to flat. Good. But it cannot catch the case where the coefficients are finite and the *output* diverges — which is exactly the earlier audit's high-shelf defect, and exactly why the frequency clamp, not the coefficient guard, is the real fix.

### 5.4 Biquad — experimental verification

A probe linked against the audited `packages/dsp/build/libsoundbridge_dsp.a` instantiated `Biquad` directly through the private header and drove a 1-second sine through it, discarding the first 250 ms of settling and measuring the steady-state peak ratio.

**Table A — +6.000 dB peak band at 1 kHz, Q = 1.0**

| `fs` | measured | error |
| --- | --- | --- |
| 8 000 | +6.000 dB | +0.000 |
| 16 000 | +6.000 dB | +0.000 |
| 24 000 | +6.000 dB | −0.000 |
| 32 000 | +6.000 dB | +0.000 |
| 44 100 | +6.000 dB | +0.000 |
| 48 000 | +6.000 dB | +0.000 |
| 96 000 | +6.000 dB | −0.000 |
| 192 000 | +6.000 dB | +0.000 |
| 384 000 | +6.000 dB | +0.000 |

**Conclusion.** The RBJ + warp-factor design is numerically correct at the precision this method can resolve. Combined with `test_frequency_response.cpp`'s independent checks, the biquad *coefficient mathematics* is a **PASS** and should not be rewritten.

**Table B — 16 kHz high shelf, +6 dB, Q = 0.7 (the App's "Treble" band 9), 2-second sine**

| `fs` | non-finite samples | peak |
| --- | --- | --- |
| 8 000 | 0 / 16 000 | 1.017 |
| 16 000 | 0 / 32 000 | 1.001 |
| 24 000 | 0 / 48 000 | 1.000 |
| 32 000 | 0 / 64 000 | 1.000 |
| 44 100 | 0 / 88 200 | 1.000 |
| 48 000 | 0 / 96 000 | 1.000 |
| 96 000 | 0 / 192 000 | 1.000 |
| 192 000 | 0 / 384 000 | 1.000 |
| 384 000 | 0 / 768 000 | 1.000 |

**Conclusion.** The `kMaxNormalisedFrequency` clamp demonstrably removes the instability that the earlier audit measured as "97–99 % non-finite output at 24 kHz". The clamp is the load-bearing fix, and it is **uncommitted** — a fresh clone at `HEAD` still exhibits the defect. Two behavioural consequences of the clamp that belong in the product documentation, not in the bug list:

- at `fs = 8 kHz` the 16 kHz shelf is silently re-centred at 3.6 kHz (`0.45 × 8000`), so "Treble" becomes a broad upper-mid shelf rather than a treble shelf;
- every band above `0.45·fs` collapses onto the same corner, so at 8 kHz bands 8 (8 kHz) and 9 (16 kHz) become the *same* filter. Neither is wrong — the alternative is instability — but neither is documented.

---

#### F-07 — The biquad's non-finite guard returns the offending input, propagating NaN

| | |
| --- | --- |
| **Severity** | **P2** |
| **Confirmation** | **CONFIRMED (RUNTIME_OBSERVED)** |
| **Location** | `packages/dsp/src/biquad.h:178-183`; consumed at `engine.cpp:238-260`, `:376-394` |

**Code excerpt:**

```cpp
// Protect against NaN/Inf from filter state blowup
if (!std::isfinite(output)) {
    state.z1 = 0.0f;
    state.z2 = 0.0f;
    return input;        // ← returns the ORIGINAL INPUT, not 0
}
```

**Technical explanation.** The guard correctly resets the filter state, which stops a blown-up section from staying blown up. But it then returns `input` unmodified. If the non-finite value originated in the *input* rather than the state, the NaN passes straight through, stage after stage, and lands in the output buffer. The guard's purpose — "protect against NaN/Inf" — is defeated for the input-origin case, which is the case a corrupted upstream buffer produces.

**Measured behaviour** (probe linked against the audited library, `limiter_enabled = false`):

```
[2]  NaN input, limiter off ->  out L = nan   (isfinite = 0),  out R = 0.500000
[2b] NaN input, limiter on  ->  out L = 0.000000
```

The right channel is the control: it was fed a finite sample in the same frame and came out finite. The left channel carried the NaN all the way through five pipeline stages to the output.

**Trigger condition.** Any non-finite sample reaching `process_*` while the limiter is disabled — which is the *default* for a flat preset (`preset.cpp:41`: `limiter_enabled = false`).

**Expected impact.** NaN written to the hardware buffer. CoreAudio behaviour on a non-finite sample is driver-dependent: silence, a click, or an aborted IO cycle. The DC blocker and the preamp multiplier both preserve NaN; only the limiter (F-07 note) substitutes 0.

**Existing test coverage.** None. `test_engine.cpp` never feeds a non-finite sample.

**Recommended fix direction.** Return `0.0f` after resetting the state, not `input`. If "pass through unchanged" is genuinely wanted for a *bypass* scenario, that is what `set_bypass` is for.

**Verification standard.** A test that feeds a single NaN sample mid-buffer with the limiter disabled and asserts the entire output buffer is finite.

---

### 5.5 Parameter smoothing

`ParameterSmoother` (`smoothing.h`) is a velocity-assisted one-pole:

```cpp
inline float next() {                                          // :83
    const float error = target_ - current_;
    velocity_ = velocity_coeff_ * velocity_ + (1.0f - velocity_coeff_) * error;
    current_   = coeff_ * current_ + (1.0f - coeff_) * (target_ - velocity_ * 0.5f);
    return current_;
}

bool isStable(float epsilon = 0.0001f) const {                  // :102
    return std::abs(current_ - target_) < epsilon && std::abs(velocity_) < epsilon;
}
```

- The 10 ms time constant matches the header's "~10ms" (`soundbridge_dsp.h:210`) and `engine.cpp:87`, `:172`, `:177`.
- `isStable()` lets the *block-rate* shortcut in `process_interleaved:223-233` and `process_planar:346-359` skip 128 `next()` calls per block when the parameter has settled. This is a genuine optimisation and it is correct: when `|current − target| < 1e-4` and `|velocity| < 1e-4`, holding `current` constant for one block is inaudible (−80 dBFS error bound).
- `init()` zeroes `current_`/`target_`/`velocity_` (`smoothing.h:33-35`). This is a footgun that `engine.cpp:171-173` already handles correctly: `set_sample_rate` saves `getCurrent()` before `init()` and restores it with `setValue()`, avoiding the 46–70 ms level dip the earlier audit measured. That fix is uncommitted but present.
- The fields are plain `float` and the class has no synchronisation — F-02.

**Verdict: PASS on algorithm and on the sample-rate-change handling; FAIL only through F-02's concurrency hole.**

---

### 5.6 Soft limiter

```cpp
void setThreshold(float threshold_db) {                                  // :39
    threshold_  = std::pow(10.0f, threshold_db / 20.0f);
    knee_start_ = threshold_ * 0.8f;
}

inline float processSample(float input) {                                // :48
    const float abs_input = std::abs(input);
    if (!std::isfinite(abs_input)) return 0.0f;                          // NaN/Inf → silence
    if (abs_input <= knee_start_) return input;                          // linear region
    const float scaled  = (abs_input - knee_start_) / (threshold_ - knee_start_);
    const float limited = knee_start_ + (threshold_ - knee_start_) * (scaled / (1.0f + scaled));
    return (input < 0.0f) ? -limited : limited;
}
```

**Design properties.** This is a memoryless rational soft-knee, not a dynamic-range compressor: no attack, no release, no lookahead, no stereo link. The transfer function `knee + (T − knee)·s/(1+s)` with `s → ∞` converges to `T` from below, is strictly monotonic, is continuous at `s = 0` (`limited = knee`), and is odd-symmetric through the sign restore. For a mastering-grade limiter this is inadequate; for a safety clipper in an EQ chain with ±12 dB of preamp it is the right tool.

**Table C — measured bound at threshold −0.1 dBFS (= 0.988553095)**

| input | output | verdict | margin to threshold |
| --- | --- | --- | --- |
| 0.5 | 0.500000000 | BOUNDED | 4.886e−01 |
| 1 | 0.892479002 | BOUNDED | 9.607e−02 |
| 2 | 0.960768342 | BOUNDED | 2.778e−02 |
| 10 | 0.984397709 | BOUNDED | 4.155e−03 |
| 1 000 | 0.988514006 | BOUNDED | 3.909e−05 |
| 1e6 | 0.988553047 | BOUNDED | 4.748e−08 |
| 1e30 | 0.988553107 | **exceeds by 1.2e−08** | −1.213e−08 |
| 3.4e38 (`FLT_MAX`) | **`nan`** | **VIOLATION** | — |
| NaN | 0.000000 | silenced | — |
| +Inf | 0.000000 | silenced | — |

**Table D — knee continuity (threshold 0.988553, knee 0.790842)**

| input | output | gain |
| --- | --- | --- |
| 0.780 | 0.779999971 | +0.000 dB |
| 0.790 | 0.790000021 | +0.000 dB |
| 0.800 | 0.799594641 | −0.004 dB |
| 0.810 | 0.808307707 | −0.018 dB |
| 0.820 | 0.816252589 | −0.040 dB |
| 0.830 | 0.823526740 | −0.068 dB |

No discontinuity, no overshoot at the knee — the transfer curve is exactly what the design intends.

---

#### F-10 — The limiter returns NaN for finite inputs above ≈1.7 × 10³⁸

| | |
| --- | --- |
| **Severity** | **P3** |
| **Confirmation** | **CONFIRMED (RUNTIME_OBSERVED)** |
| **Location** | `packages/dsp/src/limiter.h:59-63` |

**Code excerpt:**

```cpp
const float scaled  = (abs_input - knee_start_) / (threshold_ - knee_start_);   // :59
const float limited = knee_start_ + (threshold_ - knee_start_) * (scaled / (1.0f + scaled));
```

**Technical explanation.** `threshold_ − knee_start_ = 0.2 · threshold ≈ 0.1977`. For `abs_input = 3.4e38`, `scaled ≈ 1.72e39`, which overflows `float` (max 3.4028e38) to `+Inf`. The next line then evaluates `Inf / (1 + Inf)` = `Inf / Inf` = **NaN**. The `isfinite` guard at `:51` runs *before* the division and only inspects the input, so it cannot catch this. The limiter reports NaN for a *finite* input — the exact inverse of its contract.

**Trigger condition.** A finite sample with magnitude above ≈1.7e38. Unreachable from audio-range signals (|x| ≤ ~4 after a +12 dB preamp). Reachable from an upstream buffer that is already corrupt, or from a filter output that has diverged — which is the very chain the limiter exists to terminate.

**Expected impact.** NaN in the output buffer at the last pipeline stage, with nothing downstream to catch it. Low probability, high consequence: this is a defence-in-depth gap, hence P3 rather than P2.

**Existing test coverage.** None — `test_engine.cpp:217` asserts only `peak <= 1.0f` on a 4 800-sample 1 kHz sine.

**Recommended fix direction.** Compute in `double` for the `scaled` term, or clamp `scaled` to a finite maximum (e.g. `if (!std::isfinite(scaled)) return threshold_ * sign`), or reject absurd inputs at block entry.

**Verification standard.** A property test asserting `std::isfinite(out) && |out| <= threshold` for `input ∈ {FLT_MAX, ±1e38, ±Inf, NaN}` and for a `float` bit-pattern sweep.

---

#### F-11 — The limiter can exceed its own threshold by one ULP

**Severity P3 · CONFIRMED (RUNTIME_OBSERVED) · `limiter.h:59-63`**

At `input = 1e30` the measured output is `0.988553107` against a threshold of `0.988553095`, an excursion of `+1.2e−8` (≈ 1 ULP at that magnitude). Cause: `knee_start_ + (threshold_ − knee_start_) · (s/(1+s))` is evaluated in `float`, and when `s` is huge the sum rounds *up* past `threshold_`. Audibly irrelevant (−0.1 dBFS vs −0.0999999 dBFS); relevant only because `test_engine.cpp` asserts a hard ceiling and a future test tightened to the true threshold would fail spuriously. Fix by clamping the result: `return std::fmin(limited, threshold_)` with the sign applied after. **Verification:** the bound test in F-10 should assert `≤ threshold` exactly, at 1 ULP tolerance.

---

#### F-12 — Peak meters are sampled after the limiter, so they cannot see clipping

| | |
| --- | --- |
| **Severity** | **P3** |
| **Confirmation** | **CONFIRMED (STATIC)** + **CONFIRMED (RUNTIME_OBSERVED)** |
| **Location** | `packages/dsp/src/engine.cpp:249-256` (interleaved), `:381-390` (planar) |

**Code excerpt:**

```cpp
if (engine->limiter_enabled) {
    engine->limiter.processSampleStereo(&left, &right);      // :249-251
}
buffer_peak_left  = std::max(buffer_peak_left,  std::abs(left));   // :254  ← AFTER the limiter
buffer_peak_right = std::max(buffer_peak_right, std::abs(right));
```

**Technical explanation.** The meter reports the post-limiter signal. With limiting enabled, the true ceiling is `threshold = 0.988553` → **−0.104 dBFS**, so the UI can never display a value above that, no matter how hard the engine is driven. A user who pushes the preamp to +12 dB with a 0 dBFS input sees the meter pin at −0.1 dBFS and cannot distinguish "limiter doing its job" from "signal is 20 dB into the limiter".

Measured confirmation: probe input peak 20.0 with +12 dB preamp produced `output peak = 0.988056` and `reported peak_left_db = −0.104 dBFS`.

**Trigger condition.** Any signal at or above the threshold with `limiter_enabled = true`.

**Expected impact.** The diagnostic cannot answer the question it is displayed to answer. It is not wrong — it accurately reports the output — but a meter labelled "peak" next to an EQ is read as "how hot is my signal", and it structurally cannot be.

**Existing test coverage.** `engine_statistics_tracking` (`test_engine.cpp:268`) checks `frames_processed` only.

**Recommended fix direction.** Either capture a pre-limiter peak into a separate `peak_pre_limiter_*` pair and expose both, or document the field as "post-limiter output peak".

**Verification standard.** Drive a +6 dB-over-threshold signal and assert the reported peak equals the threshold, then assert a documented pre-limiter value exceeds 0 dBFS.

---

#### F-13 — `underrun_count` is never incremented

**Severity P3 · CONFIRMED (STATIC) + CONFIRMED (RUNTIME_OBSERVED) · `engine.cpp:57`, `:150`, `:605`**

The engine owns `std::atomic<uint32_t> underrun_count` (`:57`), zeroes it in `reset()` (`:150`), and publishes it through `get_stats()` (`:605`). A tree-wide grep finds **no** `fetch_add`, `store(…+1)`, or `++` on that field anywhere. The counter is permanently 0.

Measured: after processing 4 800 frames, `underrun_count = 0`.

This is not necessarily wrong — the DSP engine has no visibility into whether the IO cycle met its deadline, so it *cannot* detect an underrun; the Host/driver would have to report it. But then a permanently-zero field is a lie-by-omission in a public stats struct: a client that monitors `underruns` will conclude there have never been any. **Fix direction:** remove the field, or have the Host push a value in, or document it as reserved. **Verification:** a test asserting either the documented semantics or the field's absence.

---

#### F-14 — The entire statistics machinery runs on the hot path with no consumers

**Severity P3 · CONFIRMED (STATIC) · `engine.cpp:198`, `:262-295` (and the planar equivalents)**

Per block, `process_*` performs: two `high_resolution_clock::now()` calls, a `std::exp` for the peak decay, a `std::exp` for the CPU EMA, four atomic loads and four atomic stores for the meters, two arithmetic sequences, and one `fetch_add`. `get_stats()` — the only consumer — has **zero** production call sites (grep over `apps/`, `packages/host/`, `packages/driver/`, `packages/shared/`, `tools/`; `AudioRenderer` exposes `takeDiagnostics()` which reads `get_bypass` only).

So the cost is paid unconditionally and the benefit is never collected. That is not a defect, it is dead weight; it is listed because a future reader optimising the hot path will find these exp() calls and must know they are load-bearing only for a feature nobody calls. `AudioRenderer.swift:278` in fact pulls bypass state directly. **Fix direction:** keep it (the cost is ~1 µs per 128-frame block, immaterial) but wire `get_stats` into `takeDiagnostics` so the numbers reach the UI, or compile it out.

---

### 5.7 DC blocker

```cpp
void init(float sample_rate, float cutoff_hz = 5.0f) {
    const float w_c = 2.0f * PI * cutoff_hz / sample_rate;
    coeff_ = 1.0f - w_c;                       // :42
    if (coeff_ < 0.95f)   coeff_ = 0.95f;      // :45
    if (coeff_ > 0.9999f) coeff_ = 0.9999f;    // :46
}

inline float process(float input) {            // :62
    const float output = input - x_prev_ + coeff_ * y_prev_;
    x_prev_ = input;
    y_prev_ = output;
    return output;
}
```

**Table E — measured response (4 s settle, 1 kHz reference)**

| `fs` | 1 Hz | 2 Hz | 5 Hz | 10 Hz | 20 Hz | 100 Hz | 1 kHz |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 44 100 | −14.150 | −8.603 | −3.009 | −0.967 | −0.260 | −0.008 | +0.003 |
| 48 000 | −14.150 | −8.603 | −3.009 | −0.967 | −0.261 | −0.008 | +0.003 |
| 96 000 | −14.149 | −8.603 | −3.009 | −0.968 | −0.262 | −0.009 | +0.001 |

**Table F — coefficient clamp never engages over the supported range**

| `fs` | raw `1 − 2π·5/fs` | clamped | effective corner |
| --- | --- | --- | --- |
| 8 000 | 0.99607301 | 0.996073 | 5.000 Hz |
| 44 100 | 0.99928762 | 0.999288 | 5.000 Hz |
| 48 000 | 0.99934550 | 0.999346 | 5.000 Hz |
| 96 000 | 0.99967275 | 0.999673 | 5.000 Hz |
| 192 000 | 0.99983638 | 0.999836 | 5.000 Hz |

**Verdict: PASS.** Textbook first-order high-pass, exactly the specified −3 dB at 5 Hz, 12 dB/octave below, transparent above 20 Hz, sample-rate-invariant because the clamp is never reached within `[8000, 384000]`. Two properties worth documenting rather than fixing: (i) the response is *not* the analogue prototype — the coefficient is a first-order Euler/backward approximation, so the −3 dB point is exact by construction and the stopband is only 6 dB/octave, not 12; the measured −14.15 / −8.60 / −3.01 dB at 1 / 2 / 5 Hz is 6 dB/octave behaviour, consistent with the implementation and with "first-order" in the design intent. (ii) `init()` calls `reset()` (`dc_blocker.h:37-49`), so re-initialising on a sample-rate change drops one sample of DC history — harmless.

### 5.8 Buffer and aliasing safety

| Check | Result | Evidence |
| --- | --- | --- |
| `process_interleaved` with `input == output` | **safe** — `memcpy` guarded by `if (input != output)` | `engine.cpp:203` |
| `process_planar` with `input_l == output_l` | **safe** — guarded per channel | `engine.cpp:317-324` |
| `process_planar` in-place EQ/DC/limiter | **safe** — `processBuffer` reads and writes index `i` in the same iteration | `biquad.h:133`, `dc_blocker.h:82`, `limiter.h:75` |
| `apply_preset(engine, &engine->current_preset)` self-copy | **safe** — self-`memcpy` explicitly skipped, with a comment explaining the UB | `engine.cpp:456-458` |
| Buffer size → byte count arithmetic | **defect** — F-17 | `engine.cpp:204` |
| `num_frames == 0` | short-circuits before any pointer use | `engine.cpp:196`, `:310` |
| `NULL` pointer arguments | every entry point checks | `engine.cpp` passim |
| `num_active_bands` bound vs `bands[10]` | `preset_validate` enforces `1 ≤ num_bands ≤ 10`; `apply_preset` copies from a validated preset | `preset.cpp:55-57` |

---

#### F-17 — `num_frames * 2 * sizeof(float)` is evaluated in `uint32_t`

**Severity P3 · CONFIRMED (STATIC) · `engine.cpp:204`**

```cpp
std::memcpy(output, input, num_frames * 2 * sizeof(float));
```

`num_frames` is `uint32_t`. The subexpression `num_frames * 2` is `unsigned int` arithmetic and wraps modulo 2³² before `sizeof(float)` widens it to `size_t`. For `num_frames ≥ 2³¹` the copy length wraps to a small number (or zero), producing a silently truncated copy. Not reachable: 2³¹ frames is 49 710 seconds of audio at 48 kHz and no CoreAudio callback exceeds ~4 096. Fix by casting first: `std::memcpy(output, input, static_cast<size_t>(num_frames) * 2 * sizeof(float))`. **Verification:** a unit test with a synthetic `num_frames` that only checks the computed length expression, not an actual 2³¹-frame buffer.

### 5.9 Numerical behaviour

#### F-06 — The realtime update functions clamp NaN into a maximum instead of rejecting it

| | |
| --- | --- |
| **Severity** | **P2** |
| **Confirmation** | **CONFIRMED (RUNTIME_OBSERVED)** |
| **Location** | `engine.cpp:520`, `:544`, `:558`, `:579` |

**Code excerpt** (`update_band_gain`, `:520`):

```cpp
gain_db = std::max(-12.0f, std::min(12.0f, gain_db));
```

**Technical explanation.** `std::min(12.0f, NaN)` returns `12.0f` (the comparison `NaN < 12.0f` is false, so `min` returns its first argument). The clamp therefore maps NaN to the **maximum allowed value**, and −NaN likewise to a bound. An out-of-range input is handled acceptably (it clamps), but a *non-numeric* input is amplified into the loudest legal setting. `preset_validate` (`preset.cpp:71-74`, `:86-88`) rejects NaN properly on the preset path; the four realtime setters do not, and a non-finite value is precisely what a divide-by-zero percentage or a broken binding produces in a UI.

**Measured behaviour** (probe, `soundbridge_dsp_update_band_gain(engine, 0, NaN)`):

```
[1] update_band_gain(NaN): gain at 1 kHz = +11.83 dB
```

The band was configured as +0 dB; after writing NaN the filter applies +12 dB (11.83 dB measured at the probe frequency, with the difference accounted for by the 10 ms coefficient ramp not yet complete over the measurement window).

**Trigger condition.** `NaN` or `±Inf` passed to `update_band_gain`, `update_preamp`, `update_band_frequency`, or `update_band_q`.

**Expected impact.** A full-scale gain jump in the loudest permitted direction — the worst possible response to a corrupted parameter — up to +12 dB preamp. With the limiter enabled the output stays bounded (F-07's measurement shows `0.988` for a 20.0 input), but a +12 dB preamp with the limiter off clips hard.

**Existing test coverage.** None. No test passes a non-finite parameter.

**Recommended fix direction.** `if (!std::isfinite(value)) return;` before the clamp, matching `preset_validate`'s policy. Returning an `soundbridge_error_t` would be better but changes the ABI.

**Verification standard.** For each of the four setters, write `NaN`, `+Inf`, `−Inf` and assert the engine's response is unchanged (compare the measured transfer function before and after).

---

#### F-08 — `get_stats` reports peak levels with no upper bound

| | |
| --- | --- |
| **Severity** | **P2** |
| **Confirmation** | **CONFIRMED (RUNTIME_OBSERVED)** |
| **Location** | `engine.cpp:612-619` |

**Code excerpt:**

```cpp
constexpr float min_db = -120.0f;
stats->peak_left_db = peak_left_linear > 0.0f
    ? std::max(20.0f * std::log10(peak_left_linear), min_db)     // floor only
    : min_db;
```

**Technical explanation.** The conversion clamps the *floor* at −120 dBFS but leaves the ceiling open. `20·log10(3e38)` = 769.5 dBFS. A meter driver that maps `[-120, 0]` onto a bar width will produce a nonsense position, and any downstream `pow(10, dB/20)` will overflow.

**Measured behaviour:**

```
[5] huge finite input 3e38: out = 3e+38, reported peak = 769.54 dBFS
```

**Trigger condition.** Any non-finite or extreme peak value stored by the meter. With F-07 unfixed, a single NaN input does *not* poison the meter (`std::max(finite, NaN)` returns the finite operand), but an upstream blow-up can store a very large finite peak.

**Expected impact.** A diagnostic that reports physically impossible values instead of flagging corruption.

**Existing test coverage.** `engine_statistics_tracking` checks `frames_processed` and `sample_rate`; peak levels are never asserted.

**Recommended fix direction.** Add `std::min(..., 0.0f)`. **Verification standard:** feed `3e38` and assert `peak_left_db <= 0.0f`.

---

### 5.10 Statistics (summary)

Covered by F-08 (unbounded ceiling), F-12 (post-limiter sampling), F-13 (permanent zero), F-14 (no consumers), plus one correctness note: the meter's attack is instantaneous and its release is exponential with a 300 ms time constant, made buffer-size-independent by `peak_decay = exp(−n / (0.3·fs))` (`engine.cpp:265`). That is the correct construction, and the CPU-load EMA uses the same technique with 500 ms (`:290`). The decay is a *release* only — there is no hold — so a transient shows for ~1 s. Acceptable.

### 5.11 Lifecycle, defaults, build and documentation

#### F-09 — A fresh engine is internally inconsistent: 10 preset bands, 0 active bands

| | |
| --- | --- |
| **Severity** | **P2** |
| **Confirmation** | **CONFIRMED (STATIC)** |
| **Location** | `engine.cpp:65` (constructor), `:79` (constructor body), `preset.cpp:18`; guards at `engine.cpp:517`, `:555`, `:576` |

**Code excerpt:**

```cpp
// engine.cpp — constructor initialiser list
, num_active_bands(0)                       // :65
...
{
    ...
    soundbridge_dsp_preset_init_flat(&current_preset);   // :79  → current_preset.num_bands = 10
    ...
}
```

```cpp
// preset.cpp:18
preset->num_bands = SOUNDBRIDGE_MAX_BANDS;   // 10
```

```cpp
// engine.cpp:517 — every realtime setter starts with this
if (!engine || band_index >= engine->num_active_bands) return;   // 0 >= 0 → always returns
```

**Technical explanation.** Three observable consequences on a freshly created engine, before any preset is applied:

1. `soundbridge_dsp_get_preset()` returns `num_bands = 10` with every band disabled — a perfectly valid preset.
2. The engine processes **0** bands (`process_*` bounds its loop by `num_active_bands`).
3. `soundbridge_dsp_update_band_gain(engine, 0, 6.0f)` silently does nothing, because `0 >= num_active_bands`.

So `get_preset()` round-trips a preset that is *not* the engine's current configuration, and the update API is silently inert. The public contract implies `create()` yields the flat preset, i.e. 10 bands, all disabled — which is behaviourally flat, so the audio is correct; only the API semantics are wrong.

**Trigger condition.** Any client that creates an engine and then adjusts a band without first calling `apply_preset`.

**Expected impact.** Silent no-op on a public API. The shipping Host is immune because `AudioRenderer.init` calls `applyInitialPreset` immediately (`AudioRenderer.swift:247`), which sets `num_active_bands = 10`. A new integrator — or `tools/wav_processor.cpp` with a partial preset — is not.

**Existing test coverage.** None; `test_engine.cpp` always calls `apply_preset` before touching bands.

**Recommended fix direction.** Initialise `num_active_bands(SOUNDBRIDGE_MAX_BANDS)` in the constructor (matching `preset_init_flat`), or have the constructor delegate to `apply_preset(&current_preset)`. The latter is cleaner and establishes the invariant "engine state always equals `current_preset`".

**Verification standard.** `create()` → `update_band_gain(0, +6)` → process a 1 kHz sine → assert ≈ +6 dB. Currently this yields 0 dB.

---

#### F-16 — The Release build uses `-ffast-math`

| | |
| --- | --- |
| **Severity** | **P3** |
| **Confirmation** | **VERIFIED** (emitted command line, not inferred) |
| **Location** | `packages/dsp/CMakeLists.txt:26-27`; `build/CMakeFiles/soundbridge_dsp.dir/flags.make` |

**Evidence.**

```cmake
$<$<CONFIG:Release>:-O3>
$<$<CONFIG:Release>:-ffast-math>
$<$<CONFIG:Release>:-fno-finite-math-only>  # Preserve NaN/Inf handling
```

```make
CXX_FLAGS = -O3 -DNDEBUG ... -O3 -ffast-math -fno-finite-math-only ...
```

**Technical explanation.** `-ffast-math` is a bundle: `-funsafe-math-optimizations` (which itself enables `-freciprocal-math`, `-fno-signed-zeros`, `-fno-trapping-math`, `-ffinite-math-only`, `-fassociative-math`), `-fno-math-errno`, and `-fno-honor-nans/infinities`. The trailing `-fno-finite-math-only` correctly restores `std::isfinite`, which the code depends on in three places (`biquad.h:179`, `limiter.h:51`, `preset.cpp:71`). **Nothing restores the other sub-flags.** In particular `-freciprocal-math` permits `x/y` to become `x·(1/y)`, and `-fassociative-math` permits reassociation of the biquad's `b0·x + z1` chains — which changes the last bits of every output sample and can, in principle, move a pole.

**Trigger condition.** Any Release build.

**Expected impact.** No measured behavioural difference; the audited build produced exact ±6.000 dB and stable shelves across the full rate range (§5.4), so in practice clang does not currently exploit these freedoms in a damaging way here. The concern is a maintenance and reproducibility one: the numeric behaviour of the shipping library is not the behaviour of the source, and no test can detect a regression introduced by a compiler upgrade. Note also that `-ffast-math` with `-fno-finite-math-only` is a non-standard combination whose interaction is not specified by documentation and may change between compiler versions.

**Existing test coverage.** None; there is no test that pins bit-exact arithmetic, and none of the numeric assertions in the suite are tight enough to reveal reassociation.

**Recommended fix direction.** Replace the bundle with the specific flags that are wanted: `-O3 -fno-math-errno` (safe, removes the `errno` write in `pow`/`log`), optionally `-fno-signed-zeros`. Drop `-ffast-math` entirely; the DSP is ~30 multiply-adds per sample per band and is not floating-point-throughput-bound. **Verification standard:** a golden-impulse-response test with a bit-exact comparison against a stored reference, run in Release.

---

#### F-18 — The Host's copy of the public header has drifted

| | |
| --- | --- |
| **Severity** | **P3** |
| **Confirmation** | **VERIFIED** (direct diff) |
| **Location** | `packages/host/Sources/CSoundBridgeDSP/include/soundbridge_dsp.h` vs `packages/dsp/include/soundbridge_dsp.h`; consumed via `packages/host/Package.swift:18` |

**Technical explanation.** Two copies of a 315-line public header are maintained by hand. The diff shows:

- **3 missing declarations**: `soundbridge_dsp_update_band_frequency`, `soundbridge_dsp_update_band_q`, `soundbridge_dsp_enable_denormal_suppression`. Swift code physically cannot call them. This is why the call-site table (§3.3) shows zero production callers for those three — not by choice, by inaccessibility.
- **Comment drift, including a factual contradiction**: the Host copy says band-gain changes are "smoothly ramped in over **~50ms**"; the authoritative header says "~10ms" and `engine.cpp:91`/`:177` implement 10 ms. A Host developer sizing a fade against 50 ms is off by 5×.
- Several smaller note differences (the "requires reset" wording, the "No allocations, no locks, no system calls" phrasing).

Because the header is only a declaration surface and both copies use the same POD types, a mismatch does not break linkage today. But there is **no automated check** that the two copies agree — unlike the protocol header, which has `tools/check_protocol_layout.sh` and `tools/sync_shared_header.sh`.

**Expected impact.** Documentation that contradicts the implementation, and three masked entry points. No ABI break.

**Existing test coverage.** None.

**Recommended fix direction.** Make `CSoundBridgeDSP` a thin umbrella that `#include`s the authoritative header (via an `unsafeFlags` include path or a generated copy in the build step), or add a `diff` check to `tools/verify_version_consistency.sh`. **Verification standard:** a CI step that byte-compares the two headers modulo a known allowlist; it must currently fail.

---

#### F-19 — SwiftPM links a CMake build product through `.unsafeFlags`

| | |
| --- | --- |
| **Severity** | **P3** |
| **Confirmation** | **VERIFIED** |
| **Location** | `packages/host/Package.swift:31-32` |

**Code excerpt:**

```swift
.linkedLibrary("soundbridge_dsp"),
.unsafeFlags(["-L../../packages/dsp/build"]),
```

**Technical explanation.** The Host's SwiftPM manifest reaches into a sibling CMake build directory by relative path. Consequences: (a) `packages/dsp/build` must be populated by `make dsp-build` before `swift build` can link, and a clean clone cannot build the Host at all; (b) `.unsafeFlags` makes the target ineligible as a package dependency for any external consumer — by SwiftPM design; (c) the library is universal (`arm64;x86_64`) while nothing guarantees the CMake build used that setting. **Expected impact:** build fragility and an implicit ordering dependency between two build systems. **Fix direction:** produce an XCFramework, or a SwiftPM binary target, or a generated `.modulemap`-backed system library with an absolute-path config that a script writes. **Verification:** delete `packages/dsp/build` and confirm the failure mode is a clear, actionable error rather than a link failure deep in the build log.

---

#### F-20 — The DSP library's version string is unrelated to the product version

**Severity P3 · VERIFIED · `version.cpp:9-14`, `CMakeLists.txt:2`, `VERSION`**

```cpp
#ifndef SOUNDBRIDGE_DSP_VERSION
#define SOUNDBRIDGE_DSP_VERSION "1.0.0-dev"
#endif
```

CMake defines `SOUNDBRIDGE_DSP_VERSION="${PROJECT_VERSION}"` (`CMakeLists.txt:89`) where `project(soundbridge_dsp VERSION 1.0.0)` (`:2`). So the shipping library reports **`1.0.0`** while the repository `VERSION` file says **`1.2.0`** and `tools/verify_version_consistency.sh` tracks eleven other version sources. The DSP version is a fourth independent source of truth that the consistency script does not cover. Nothing is broken — the DSP has its own semantic version — but an operator reading `soundbridge_dsp_get_version()` cannot correlate it with a release. **Fix direction:** either derive the DSP project version from `VERSION` at configure time, or add it to `verify_version_consistency.sh`'s source list with an explicit mapping. **Verification:** `verify_version_consistency.sh` should enumerate the DSP project version and either assert a mapping or explicitly exempt it.

---

#### F-21 (observation) — clock reads per callback

`high_resolution_clock::now()` is called twice per `process_*` invocation to populate `cpu_load_percent` (`engine.cpp:198`, `:283`; `:313`, `:399`). On Darwin this resolves to `mach_absolute_time()`, a commpage read — no syscall, no lock. Cost is tens of nanoseconds. Recorded only so that a future optimisation pass knows these calls exist and are feeding a metric with no production consumer (F-14). No action required.

---

## 6. Findings Register

Sorted by severity, then by ID. "Section" is the §5 subsection containing the full twelve-element write-up.

| ID | Sev | Title | Location | Type | Confirmation | Section |
| --- | --- | --- | --- | --- | --- | --- |
| **F-01** | **P1** | DSP test suite can never report a failure (`static TestStats` per TU) | `tests/test_utils.h:24`, `:39-107`; `tests/test_main.cpp:97` | Test infrastructure | RUNTIME_OBSERVED | 5.1 |
| **F-02** | **P1** | Realtime parameter updates race with the audio thread on non-atomic biquad/smoother state; contract claims a queue that does not exist | `biquad.h:99-123`, `:159-186`; `smoothing.h:61`, `:83`; `engine.cpp:512-594` | Concurrency | STATIC | 5.1 |
| **F-03** | P2 | `apply_preset` publishes `num_active_bands` before writing band coefficients | `engine.cpp:457-471` | Ordering | STATIC | 5.1 |
| **F-04** | P2 | `num_active_bands`, `current_preset`, `limiter_enabled`, `sample_rate` read unprotected by the audio thread; `get_stats` reads non-atomic `sample_rate` while documented as any-thread | `engine.cpp:28-51`, `:238-251`, `:606` | Concurrency | STATIC | 5.1 |
| **F-05** | P2 | `SoftLimiter::setThreshold` writes `threshold_` then `knee_start_`; a torn pair inverts the transfer curve and can *raise* the signal above the new threshold | `limiter.h:39-43`, `:48-69` | Ordering / numeric | STATIC (arithmetic derived) | 5.1 |
| **F-06** | P2 | Realtime setters clamp NaN into the maximum permitted value (`+12 dB`, `20 kHz`, `Q 10`) instead of rejecting | `engine.cpp:520`, `:544`, `:558`, `:579` | Numeric | RUNTIME_OBSERVED | 5.9 |
| **F-07** | P2 | Biquad non-finite guard resets state but returns the offending input, propagating NaN to the output | `biquad.h:178-183` | Numeric | RUNTIME_OBSERVED | 5.4 |
| **F-08** | P2 | `get_stats` converts peak to dB with a floor but no ceiling (measured −120 → 769.54 dBFS) | `engine.cpp:612-619` | Diagnostics | RUNTIME_OBSERVED | 5.9 |
| **F-09** | P2 | Fresh engine: `current_preset.num_bands = 10` while `num_active_bands = 0` → every `update_band_*` silently no-ops | `engine.cpp:65`, `:79`; `preset.cpp:18`; guards `:517`, `:555`, `:576` | Lifecycle | STATIC | 5.11 |
| **F-10** | P3 | Limiter returns NaN for finite inputs above ≈1.7e38 (`Inf/Inf` in the knee division) | `limiter.h:59-63` | Numeric | RUNTIME_OBSERVED | 5.6 |
| **F-11** | P3 | Limiter output exceeds the configured threshold by ~1 ULP at very high input | `limiter.h:59-63` | Numeric | RUNTIME_OBSERVED | 5.6 |
| **F-12** | P3 | Peak meters sample *after* the limiter; with limiting on they cannot exceed −0.104 dBFS | `engine.cpp:249-256`, `:381-390` | Diagnostics | STATIC + RUNTIME_OBSERVED | 5.6 |
| **F-13** | P3 | `underrun_count` is never incremented anywhere → permanently 0 | `engine.cpp:57`, `:150`, `:605` | Diagnostics | STATIC + RUNTIME_OBSERVED | 5.6 |
| **F-14** | P3 | Full statistics machinery (2 chrono reads, 2 `exp`, 8 atomics) runs per block with zero production consumers | `engine.cpp:198`, `:262-295` | Performance | STATIC | 5.6 |
| **F-15** | P3 | Denormal suppression applies to the calling thread only; `create()` runs on the control thread and the exported hook has zero call sites, so the audio thread runs unflushed | `cpu_util.h:30-62`; `engine.cpp:74`, `:626-628` | Realtime / performance | STATIC + grep | 5.1 |
| **F-16** | P3 | Release build uses `-ffast-math`; only `-finite-math-only` is restored | `CMakeLists.txt:26-27`; `flags.make` | Build / reproducibility | VERIFIED | 5.11 |
| **F-17** | P3 | `num_frames * 2 * sizeof(float)` computed in `uint32_t`; wraps for `num_frames ≥ 2³¹` | `engine.cpp:204` | Buffer arithmetic | STATIC | 5.8 |
| **F-18** | P3 | Host header copy drifted: 3 missing declarations, and a "~50 ms" claim where the implementation is 10 ms | `packages/host/Sources/CSoundBridgeDSP/include/soundbridge_dsp.h` | Documentation / integration | VERIFIED (diff) | 5.11 |
| **F-19** | P3 | SwiftPM target links a CMake build directory via `.unsafeFlags -L../../packages/dsp/build` | `packages/host/Package.swift:31-32` | Build | VERIFIED | 5.11 |
| **F-20** | P3 | DSP library reports version `1.0.0` while the repository ships `1.2.0`; not covered by `verify_version_consistency.sh` | `version.cpp:9-14`; `CMakeLists.txt:2`, `:89`; `VERSION` | Release hygiene | VERIFIED | 5.11 |
| *(F-21)* | — | *Observation:* two `high_resolution_clock::now()` calls per callback — not a defect | `engine.cpp:198`, `:283` | — | — | 5.11 |

**Counts:** P0 = 0 · P1 = 2 · P2 = 7 · P3 = 11 · **total = 20**.

---

## 7. Confirmed Defects vs. Unverified Risks

### 7.1 Confirmed defects (reproduced or proven)

**Reproduced by execution** (`RUNTIME_OBSERVED`) — 8 findings. Each was measured against the audited Release build; the exact commands are in the Appendix.

| ID | Measurement that establishes it |
| --- | --- |
| F-01 | Injected false assertion → printed `❌ FAIL`, scored `✓`, summary `0 passed, 0 failed`, exit 0, `ctest` 1/1 Passed. Reproduced in three configurations (single TU / two TU / real suite copy). |
| F-06 | `update_band_gain(engine, 0, NaN)` → measured +11.83 dB at 1 kHz from a +0 dB configuration. |
| F-07 | NaN input with limiter off → `out L = nan (isfinite = 0)`; with limiter on → `out L = 0.0`. |
| F-08 | 3e38 peak → reported `769.54 dBFS`. |
| F-10 | `FLT_MAX` input → limiter output `nan`. |
| F-11 | 1e30 input → output `0.988553107` vs threshold `0.988553095`. |
| F-12 | 20.0 input at +12 dB preamp → output peak `0.988056`, reported `−0.104 dBFS`. |
| F-13 | 4 800 frames processed → `underrun_count = 0`, and no increment exists in the tree. |

**Proven by code** (`STATIC`, reasoning stated in each write-up) — 9 findings: F-02, F-03, F-04, F-05, F-09, F-14, F-15, F-17, plus the second half of F-13.

**Proven by inspection of build artefacts** (`VERIFIED`) — 4 findings: F-16 (emitted `flags.make`), F-18 (header diff), F-19 (`Package.swift`), F-20 (`CMakeLists.txt` + `VERSION`).

*(8 + 9 + 4 = 21 slots because F-12 and F-13 each carry two independent evidence types; the register's 20 unique findings stand.)*

### 7.2 Risks that are real but **not** confirmed — deliberately not counted

These are hypotheses this audit could not settle from available evidence. They are recorded so that nobody mistakes the finding count for a completeness claim.

| Risk | Why it is not confirmed | What would settle it |
| --- | --- | --- |
| **Torn `BiquadCoeffs` produces an actual click in the field** | F-02's race is undeniably present, but no test triggers it and the Host never triggers it. Whether a torn pole pair is audible depends on the interleaving, which no deterministic experiment here can force. | A TSan build plus an intentional high-rate parameter sweep on a two-thread harness, with output correlation against a race-free reference. |
| **Denormal slowdown reaches audibility** | The mechanism (F-15) is certain; the magnitude is not. Whether 40 subnormal accumulators per sample measurably raise callback time on Apple silicon was not measured — it would need an `mach_absolute_time` histogram from the IO thread on a real device with a real 10-band preset and a decaying signal. | Instrumented callback-duration histogram, 30 s of decaying audio, denormals on vs off. |
| **`-ffast-math` changes a float result in this codebase today** | No behavioural difference was observed (§5.4 is exact), but no bit-exact golden reference exists to prove the *absence* of a difference. | A golden-impulse-response test at `-O0` vs `-O3 -ffast-math`, bit-compared. |
| **`apply_preset` concurrent with processing is reachable in a shipping client** | The Host serialises it. No other in-tree client exists. Reachability by a *future* client is a design question, not a measurable fact. | Review of any new integration; or a code-level barrier that makes the violation impossible. |
| **The 0.45·fs clamp is the correct long-term answer vs. redesigning the shelf for low rates** | The clamp is stable and bounded (proven, Table B), but whether a 3.6 kHz "Treble" shelf at 8 kHz is *acceptable product behaviour* is a product decision, not an engineering fact. | Product sign-off, or a minimum-sample-rate policy for the Host. |

### 7.3 Things the audit looked for and did **not** find

Stated explicitly so the absence is on the record:

- **No heap allocation, lock, or I/O in either processing path.** Verified by reading every statement reachable from `process_interleaved` and `process_planar`, including the bypass branches.
- **No unbounded loop.** The band loop is bounded by `num_active_bands ≤ 10`; the frame loop by `num_frames`.
- **No buffer overrun in the engine.** `num_active_bands` is bounded by `preset_validate`; per-band state is fixed-size; every `memcpy` length is derived from `num_frames`.
- **No use-after-free in the engine.** `destroy` is a plain `delete`; there is no shared ownership, no callback, no background thread. (Lifetime correctness across `AudioRenderer.deinit` is a Host concern, audited separately.)
- **No exception can escape a public entry point.** `create` is the only allocating function and it is wrapped in `try/catch(...)`.
- **No uninitialised read.** Every member has a default member initialiser or a constructor initialiser (verified against `engine.cpp:62-99`, `biquad.h:325-330`, `smoothing.h:116-122`, `limiter.h:118-121`, `dc_blocker.h:90-93`, `:100-135`).
- **No integer overflow in indexing.** All indices are `uint32_t` bounded by 10 or by `num_frames`.
- **The biquad output guard does not mask an instability in the current tree.** Table B shows zero non-finite samples at nine sample rates, including the 24–31 kHz range that `HEAD` fails on.
- **The limiter cannot self-oscillate.** It is memoryless.
- **The DC blocker cannot self-oscillate.** `0 ≤ coeff_ ≤ 0.9999 < 1` at every supported rate (Table F).

---

## 8. Test Coverage Assessment

### 8.1 What was executed

| Command | Result |
| --- | --- |
| `./packages/dsp/build/tests/soundbridge_dsp_tests` | 35 tests printed `✓`, 0 printed `✗`, summary **`Results: 0 passed, 0 failed`**, exit status **0** |
| `ctest` in `packages/dsp/build` | `1/1 Test #1: soundbridge_dsp_tests ... Passed 0.01 sec` · `100% tests passed` · exit 0 |

Both results are **untrustworthy** because of F-01. The suite's green status carries no information about whether the assertions in it hold.

### 8.2 Inventory — 35 tests

| File | Count | Names |
| --- | --- | --- |
| `test_biquad.cpp` | 6 | `biquad_passthrough_when_flat`, `biquad_impulse_response_peak_filter`, `biquad_low_pass_attenuates_high_freq`, `biquad_high_pass_attenuates_low_freq`, `biquad_peak_filter_boosts_at_center_freq`, `biquad_reset_clears_state` |
| `test_engine.cpp` | 13 | `engine_create_destroy`, `engine_invalid_sample_rate`, `engine_bypass_is_bit_perfect`, `engine_bypass_interleaved_is_bit_perfect`, `engine_apply_flat_preset`, `engine_process_with_flat_preset`, `engine_peak_filter_boosts_signal`, `engine_limiter_prevents_clipping`, `engine_update_band_gain_realtime`, `engine_statistics_tracking`, `engine_reset_clears_state`, `engine_band_above_nyquist_stays_finite`, `engine_sample_rate_change_preserves_preamp` |
| `test_frequency_response.cpp` | 6 | `freq_response_flat_preset_is_transparent`, `freq_response_peak_filter_at_1khz`, `freq_response_low_shelf_boosts_bass`, `freq_response_high_shelf_boosts_treble`, `freq_response_multi_band_eq`, `freq_response_thd_remains_low` |
| `test_preset.cpp` | 5 | `preset_init_flat`, `preset_validate_valid`, `preset_validate_invalid_frequency`, `preset_validate_invalid_gain`, `preset_validate_invalid_q` |
| `test_smoothing.cpp` | 5 | `smoother_initialization`, `smoother_set_value_immediate`, `smoother_ramps_to_target`, `smoother_no_zipper_noise`, `db_to_gain_conversion` |

### 8.3 What the suite covers well

- **Biquad shape and direction**: pass-through when flat, boost at centre, attenuation outside a low-pass/high-pass band, state cleared by `reset`.
- **Bypass bit-exactness** in both interleaved and planar form (`signals_identical`).
- **Frequency response at 1 kHz** with ±1.0 dB tolerance (`test_frequency_response.cpp:88`), flat transparency with a ±0.1 ratio tolerance (`:45`), shelf direction with >3 dB thresholds (`:154`, `:219`), and multi-band behaviour (`:296`, `:315`, `:334`).
- **THD < 0.001** for a processed tone (`:375`) — the strongest numeric assertion in the suite.
- **Two regression tests from the earlier audit**: `engine_band_above_nyquist_stays_finite` (`test_engine.cpp:352-380`) and `engine_sample_rate_change_preserves_preamp` (`:395-432`).

### 8.4 Gaps

| Gap | Consequence |
| --- | --- |
| **No concurrency test, no TSan/UBSan configuration** | F-02, F-03, F-04, F-05 are all invisible to this suite. |
| **No non-finite *parameter* test** | F-06 unguarded. |
| **No non-finite *sample* test with the limiter disabled** | F-07 unguarded; the one finiteness test (`:379`) runs with a limiter-enabled preset. |
| **Limiter ceiling asserted only as `peak <= 1.0f`** (`:217`) | 0.11 dB weaker than the true threshold; would pass a limiter that leaks 0.5 dB. |
| **`get_stats` peak fields never asserted** | F-08 unguarded. |
| **No opcode test for a fresh engine** | F-09 unguarded. |
| **Single sample rate in the engine tests (48 kHz)**; `test_frequency_response.cpp` is 48 kHz only | Rate-dependent defects are caught only by the two targeted regression tests. |
| **No test for `process_planar`'s aliasing guards** | Correct, but unverified by test. |
| **No test for `update_band_frequency` / `update_band_q`** | Both untested; both have zero callers (F-18). |
| **No test for `get_version`** | F-20 unguarded. |
| **No test that a failing assertion makes `ctest` fail** | The harness itself is untested — which is how F-01 survived. |

**Assessment.** The suite is well designed for its era — the frequency-response and THD tests are genuinely good — but it verifies *the happy path of the numeric core* and nothing about the API contract. As a score it is roughly: numeric core well covered, concurrency not covered at all, numerical edge cases not covered at all, diagnostics not covered at all, lifecycle defaults not covered at all. And because of F-01, **none of it currently functions as a gate.**

---

## 9. Remediation Priority

Ordered so that each item is independently landable. **Nothing here is to be implemented as part of this audit.**

### 9.1 P0 — none

No finding met the P0 bar (memory corruption, use-after-free, total realtime failure). The two closest candidates — the F-02 data race (undefined behaviour by the language rule) and the F-10 NaN — are bounded: neither corrupts memory, and neither is reachable through the shipping Host.

### 9.2 P1 — before any further reliance on this module

1. **F-01 — repair the test harness.** Smallest possible change: one `extern`/definition pair, or a function-local `static` behind an `inline` accessor. Then add a meta-test that deliberately fails and asserts a non-zero exit. *Do this first*: until it lands, no other fix can be shown to work, and no regression can be caught.
2. **F-02 — choose a contract and honour it.** Either implement the mailbox the comment already promises, or demote the documentation to "audio thread only" and add a debug-only thread assertion. The second option is 10 lines and makes the library honest; the first is the right long-term answer. *Blocking decision:* pick one before touching any update function.

### 9.3 P2 — correctness and diagnostics

3. **F-06** — reject non-finite parameters in the four realtime setters (one `if` each, matching `preset_validate`'s existing policy).
4. **F-07** — return `0.0f`, not `input`, from the biquad's non-finite guard.
5. **F-09** — initialise `num_active_bands` to `SOUNDBRIDGE_MAX_BANDS`, or delegate the constructor to `apply_preset(&current_preset)`.
6. **F-08** — clamp `peak_*_db` at `0.0f`.
7. **F-03** — write all coefficients, then publish `num_active_bands` last.
8. **F-05** — derive `knee_start_` from `threshold_` inside `processSample`, or publish the pair atomically.
9. **F-04** — same remedy as F-02; make `sample_rate` atomic in the interim and stop advertising `get_stats` as race-free until then.

### 9.4 P3 — hygiene, documentation, reproducibility

10. **F-16** — replace `-ffast-math` with `-fno-math-errno`; add one bit-exact golden-IR test.
11. **F-18** — single-source the public header, or add a diff gate to `verify_version_consistency.sh`.
12. **F-20** — derive the DSP project version from `VERSION`, or enumerate it in the consistency script.
13. **F-19** — replace the `.unsafeFlags` link path with a reproducible artefact.
14. **F-12 / F-13 / F-14** — decide the meter semantics (pre- or post-limiter), remove or document `underrun_count`, and wire `get_stats` into `AudioRenderer.takeDiagnostics` so the cost buys something.
15. **F-15** — call `soundbridge_dsp_enable_denormal_suppression()` from the Host's render-thread setup.
16. **F-10 / F-11** — clamp `scaled` and clamp the result to `threshold_`.
17. **F-17** — cast to `size_t` before multiplying.

---

## 10. Final Verdict

### **FAIL**

Not because the DSP is broken — the numeric core is measurably correct — but because the two things an audit most needs from a module are both absent:

1. **The module cannot tell you when it is wrong.** `packages/dsp/tests/test_utils.h:24` gives every translation unit its own assertion counter, so the suite reports `0 passed, 0 failed` while a deliberately failing assertion is printed to stderr, and `ctest` reports 1/1 Passed with exit status 0. Every prior statement that "the DSP tests pass" — in release reports, in commit messages, in this repository's own documentation — is unsupported by evidence. F-01 is a P1 because it destroys the evidential value of the entire test suite, not because it breaks audio.
2. **The module cannot be used the way it says it can.** `soundbridge_dsp.h:11` and `:202-260` promise that parameter updates are "thread-safe", "REALTIME-SAFE", and "Queues parameter change[d] … safe to call from UI thread while audio is processing". There is no queue. `Biquad::setCoeffsSmooth` reads `coeffs_` while the audio thread writes it, and writes four other plain-float fields the audio thread also touches. That is a data race — undefined behaviour — in exactly the scenario the header advertises. F-02 is a P1 for the same reason: it is a broken primary API guarantee.

### What is nonetheless in good shape

- The processing path honours every realtime constraint: no allocation, no lock, no I/O, bounded loops.
- Biquad magnitude accuracy measures exact (±0.001 dB) across 8 kHz–384 kHz, and the `warp_factor` term that looks suspicious is a correct bilinear-compensation.
- The DC blocker is textbook-correct at every rate, with its coefficient clamp never engaging.
- The soft limiter is continuous across the knee, monotonic, sign-symmetric, and bounded by its threshold for every input up to ≈1.7e38.
- Both process paths handle `input == output` aliasing, `num_frames == 0`, and `NULL` arguments.
- The uncommitted Nyquist clamp in `biquad.h` demonstrably repairs the low-sample-rate shelf instability that the earlier audit measured at 97–99 % non-finite output.

### The one-sentence operational read

**The shipping product is safe today because the Host happens to call the engine from a single thread and applies its preset before starting the IO cycle — not because the library makes it safe; and nobody would know if that stopped being true, because the tests cannot fail.**

### What would move this to PASS WITH WARNINGS

1. F-01 fixed and demonstrated with a deliberately failing injection.
2. F-02 resolved — either a real mailbox, or documentation that matches the implementation.
3. F-06 and F-07 fixed (two small, local changes).

### What would move it to PASS

All of the above, plus F-03, F-04, F-05, F-08, F-09 addressed, and TSan plus UBSan configurations added to the package so the concurrency and numeric findings can never silently return.

---

## Appendix A — Environment and reproducibility

```
Repository      /Users/chenjianyu/CodeGeeXProjects/SoundBridge
Branch / HEAD   main / eb45303f136faf95f764d2dc4d007206f6f3a3e7
Submodule       633e0f70203edd87d320fc5a3cae901e1363aac5  packages/driver/vendor/libASPL (v3.1.2-1-g633e0f7)
OS              macOS 27.2.1 (26B131), arm64
Compiler        Apple clang 21.0.0 (clang-2100.4.1.1)
DSP artefacts   packages/dsp/build/libsoundbridge_dsp.a        33 696 bytes
                packages/dsp/build/tests/soundbridge_dsp_tests 247 064 bytes
Release flags   -O3 -DNDEBUG -std=c++17 -arch arm64 -arch x86_64
                -mmacosx-version-min=13.0 -Wall -Wextra -Wpedantic
                -Wno-unused-parameter -ffast-math -fno-finite-math-only
                -Xarch_arm64 -mcpu=apple-m1 -Xarch_x86_64 -msse4.2
```

All probe sources and binaries were kept **outside** the repository (`/tmp/sb-audit/`). No file inside the repository other than this report was created, modified, or deleted.

## Appendix B — Commands used

```bash
# Baseline
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
git status --porcelain
git submodule status
wc -l packages/dsp/{include,src,tests,bridge,tools}/*

# Existing test suite (read-only; the build directory already existed)
packages/dsp/build/tests/soundbridge_dsp_tests ; echo "exit=$?"
cd packages/dsp/build && ctest --output-on-failure

# Emitted Release flags (read-only)
cat packages/dsp/build/CMakeFiles/soundbridge_dsp.dir/flags.make

# F-01 experiments — three configurations, all outside the repo
clang++ -std=c++17 -O0 /tmp/sb-audit/harness_probe.cpp -o /tmp/sb-audit/harness_probe
clang++ -std=c++17 -O0 /tmp/sb-audit/t_case.cpp /tmp/sb-audit/t_main.cpp -o /tmp/sb-audit/t_twotu
cp -R packages/dsp/tests /tmp/sb-audit/realtests   # then inject one failing ASSERT
cmake -B /tmp/sb-audit/realtests-build -S /tmp/sb-audit/realtests-parent
/tmp/sb-audit/realtests_broken > out.txt 2>&1 ; echo "BINARY_EXIT_CODE=$?"

# Behaviour probes — linked against the audited static library
clang++ -std=c++17 -O2 -Ipackages/dsp/include -Ipackages/dsp/src \
        /tmp/sb-audit/engine_probe.cpp packages/dsp/build/libsoundbridge_dsp.a \
        -framework Accelerate -o /tmp/sb-audit/engine_probe
clang++ -std=c++17 -O2 -Ipackages/dsp/include -Ipackages/dsp/src \
        /tmp/sb-audit/probe2.cpp packages/dsp/build/libsoundbridge_dsp.a \
        -framework Accelerate -o /tmp/sb-audit/probe2
```

## Appendix C — Call-site survey method

Every public symbol was searched tree-wide with `Grep`, excluding `packages/dsp` (the module itself) and any `build/` directory:

```
apps/mac/SoundBridgeApp/Sources/**
packages/host/Sources/**
packages/driver/**
packages/shared/**
tools/**
```

The results are the "actual production call site" column of §3.3. Symbols with no hits are recorded as zero-caller and treated as unverified-by-use: `reset`, `process_planar`, `get_preset`, `get_stats`, `update_band_frequency`, `update_band_q`, `enable_denormal_suppression`. `update_band_frequency` and `update_band_q` additionally do not exist in the Host's header copy (F-18), so they are unreachable from Swift by construction.

---

*End of report. This audit produced no code changes. Findings are reported for prioritisation and are not to be remediated under this task.*
