# SoundBridge DSP Engine — Remediation Report

**Report date:** 2026-11-22
**Revised:** 2026-11-23 — independent-review remediation (R1–R4) added as §F; the earlier claim in §A that no downstream struct layout had changed is corrected.
**Revised:** 2026-11-23 (verification round) — every finding re-checked against the tree in §G; one gap (F-02 producer side) closed with a bounded batch publish; §E.1's "bounded by one copy" claim corrected.
**Repository:** `/Users/chenjianyu/CodeGeeXProjects/SoundBridge`
**Remediates:** [`docs/release/SoundBridge-DSP-Engine-Code-Audit-Report.md`](SoundBridge-DSP-Engine-Code-Audit-Report.md) — 20 findings (P0 = 0, P1 = 2, P2 = 7, P3 = 11) plus one observation (F-21)
**Scope:** `packages/dsp` (engine, biquad, limiter, dc blocker, tests, build), the two copies of its public headers, `tools/verify_version_consistency.sh`, `tools/sync_dsp_headers.sh`, and the Host's DSP call site. The HAL driver, libASPL submodule and release pipeline were not modified.
**Working tree:** uncommitted. No commit, tag, reset, stash or submodule change was made in this round; `git submodule status` reports `633e0f7…` with no `+`/`-` prefix.

---

## A. Executive Summary

The audit's verdict was **FAIL — API CONTRACT & VERIFICATION**. The remediation is now **PASS — DSP CORE CORRECTNESS AND CONCURRENCY; SOURCE-COMPATIBLE; NO BINARY ABI PROMISE**, with one finding deferred (F-19, SwiftPM/CMake integration) and five residual risks stated in §E. An independent review of the finished diff then returned four further findings (R1–R4); all four are resolved and locked by tests in §F. A later verification round (§G) re-checked all twenty findings against the code and closed the last gap — the render callback publishing through blocking setters — with a bounded batch entry point. §H states the verdict as six separate properties, one of which — binary ABI compatibility — is **not** promised.

The two P1 findings were structural, and both were fixed by changing the shape of the code rather than by patching a symptom:

- **F-01** — the test suite could not fail. `static TestStats` at header scope gave every translation unit its own counter, so a failing assertion incremented a copy the runner never read. The suite now uses one function-local statistics object, and a two-TU failure-injection probe reports `Results: 0 passed, 1 failed` with exit status 1.
- **F-02** — the "queued, thread-safe, realtime-safe" parameter setters wrote biquad and smoother state that the audio thread was reading and writing per sample. There is now a real queue: a bounded, lock-free triple-buffered mailbox carrying one complete immutable configuration, including coefficients computed on the publishing thread. The audio thread consumes it exactly once, at the top of a block, and then owns everything it touches.

Phase order followed the audit's instruction: isolated numeric and lifecycle defects first (F-06, F-07, F-09, F-10, F-11, F-16, F-17), then diagnostics semantics and per-thread FPU state (F-08, F-12, F-13, F-14, F-15), then the concurrency architecture as a single coherent change (F-02, F-03, F-04, F-05), then header/version/build consistency (F-18, F-20), and F-19 investigated and deferred with a written migration plan.

**Numbers, all measured this round:**

| Gate | Result |
| --- | --- |
| DSP unit suite (Release, universal) | **72 passed, 0 failed** — 53 before the remediation, 66 at the end of it, 72 after the review fixes in §F |
| DSP suite under ThreadSanitizer | **72 passed, 0 failed, 0 data-race reports** |
| DSP suite under AddressSanitizer (Debug) | **72 passed, 0 failed, 0 ASan errors** |
| DSP suite under UndefinedBehaviorSanitizer | **72 passed, 0 failed, 0 runtime errors** |
| `make test` (whole repository) | **exit 0** — Host 399/399, App 298/298, Driver 3/3 suites, install transaction 168/168 scenarios, installer gate 99 checks, unsigned policy 97 checks, protocol/version checks pass |
| Host release build / App release build | both `Build complete!` |
| Version consistency | 13 sources checked, 0 failed |

§D records the runs as they were made (at 66 tests); §F.5 records the review round's re-runs at 72; §G.3 re-runs every gate at 75 and records the failure-injection and A/B experiments.

Downstream API: **source-compatible; the statistics struct grew.** No public function signature or symbol changed, and every consumer was rebuilt against the same headers within this round. One struct did change size: `soundbridge_stats_t` went from 32 to 40 bytes when the two pre-limiter level fields were appended (existing offsets 0…28 unchanged, new fields at 32 and 36). That is an append-only, source-compatible change, **not** a binary-compatible one, and an earlier revision of this report claimed otherwise; the policy, the size, the offsets and the limits are stated in §F.1 and encoded as `static_assert`s in the header. `packages/host` compiled and its 399 tests passed against the new library without editing any call site.

---

## B. Findings — F-01 … F-21

Legend for **Status**: `FIXED` · `FIXED (contract)` — the behaviour could not be implemented in the library and the contract now says so and is locked by a test · `DEFERRED` · `NOT APPLICABLE`.

| ID | Sev | Finding | Status | Where the change is | Evidence |
| --- | --- | --- | --- | --- | --- |
| F-01 | P1 | Test suite cannot report a failure (`static TestStats` per TU) | **FIXED** | `tests/test_utils.h` | Two-TU failure probe: `0 passed, 1 failed`, exit 1 |
| F-02 | P1 | Realtime setters race the audio thread; "queue" did not exist | **FIXED** | `src/config_mailbox.h`, `src/engine.cpp`, `src/biquad.h`, `include/soundbridge_dsp.h` | 10 mailbox/token tests + 6 engine concurrency tests; the audio-thread publish path is `soundbridge_dsp_try_update_eq()` (§G.2); TSan clean |
| F-03 | P2 | `num_active_bands` published before coefficients | **FIXED** | `src/engine.cpp` | Band count and coefficients travel in one snapshot; `engine_default_state_is_consistent` |
| F-04 | P2 | Audio-thread reads unprotected; `get_stats` read non-atomic `sample_rate` | **FIXED** | `src/engine.cpp` | Ownership split; `applied_sample_rate` atomic; TSan clean |
| F-05 | P2 | `SoftLimiter::setThreshold` wrote two coupled fields | **FIXED** | `src/limiter.h` | Only `threshold_` is stored; knee derived per sample |
| F-06 | P2 | Setters clamped NaN into the maximum value | **FIXED** | `src/engine.cpp` | `engine_realtime_parameter_rejects_non_finite` |
| F-07 | P2 | Biquad guard returned the offending input | **FIXED** | `src/biquad.h` | `engine_non_finite_input_stays_finite` |
| F-08 | P2 | Peak dB had a floor but no ceiling (769.54 dBFS observed) | **FIXED** | `src/engine.cpp`, `include/soundbridge_types.h` | `engine_stats_peak_reports_overrange`, `engine_stats_peak_is_finite_for_extreme_input` |
| F-09 | P2 | Fresh engine: 10 preset bands but 0 active | **FIXED** | `src/engine.cpp` | Concept deleted (`num_active_bands` no longer exists); `engine_default_state_is_consistent` |
| F-10 | P3 | Limiter returned NaN for finite input above ≈1.7e38 | **FIXED** | `src/limiter.h` | Curve evaluated in `double`; `limiter_process_buffer_is_never_non_finite` |
| F-11 | P3 | Limiter exceeded its own threshold by ~1 ULP | **FIXED** | `src/limiter.h` | Result clamped to the ceiling; `limiter_never_exceeds_threshold` |
| F-12 | P2 | Peak meters sampled after the limiter only | **FIXED** | `src/engine.cpp`, `include/soundbridge_types.h` | Pre-limiter peak fields; `engine_stats_pre_limiter_peak_sees_overdrive` |
| F-13 | P3 | `underrun_count` never incremented | **FIXED (contract)** | `include/soundbridge_dsp.h` | Field documented as reserved and always 0; `engine_stats_underrun_count_stays_reserved` |
| F-14 | P3 | Statistics machinery had no production consumer | **FIXED** | `packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift` | `takeDiagnostics()` now calls `soundbridge_dsp_get_stats()` |
| F-15 | P3 | Denormal suppression applied to the wrong thread | **FIXED** | `src/engine.cpp` | Both process entry points apply it per thread; `engine_denormal_suppression_applies_to_the_calling_thread` |
| F-16 | P3 | Release build used `-ffast-math` | **FIXED** | `CMakeLists.txt` | Removed, with the reason recorded in the flags block |
| F-17 | P3 | `num_frames * 2 * sizeof(float)` evaluated in `uint32_t` | **FIXED** | `src/buffer_math.h` | `size_t` arithmetic; 3 `buffer_math_*` tests |
| F-18 | P3 | Host's copy of the public header had drifted | **FIXED** | `tools/sync_dsp_headers.sh`, both header copies, `Makefile` | Drift probe: appending a line makes `--check` exit 1 |
| F-19 | P3 | SwiftPM links a CMake product through `.unsafeFlags` | **DEFERRED** | — | Migration plan in §E.5; was explicitly allowed not to block the DSP work |
| F-20 | P3 | DSP version string unrelated to the product version | **FIXED** | `CMakeLists.txt`, `src/version.cpp`, `tests/test_version.cpp`, `tools/verify_version_consistency.sh` | `version_matches_the_repository_product_version`; 13/13 version sources |
| F-21 | — | Observation: two clock reads per callback | **NOT APPLICABLE** | — | No action required; retained deliberately (see §E.4) |

### B.1 What F-02 … F-05 became

The audit called these four "the concurrency architecture". They were fixed as one change because a fix for any one of them in isolation leaves the others reachable:

- **F-02** required that no control-thread write ever lands in memory the audio thread is reading.
- **F-03** required that a band count and its coefficients become visible together.
- **F-04** required that the audio thread's reads be either private or atomic.
- **F-05** required that a threshold and its derived knee never come from two different configurations.

A double buffer plus a generation counter does not satisfy F-02: with two slots the producer has nowhere to write while the consumer reads, so it must either block, overwrite under the reader, or accept a check-then-read race. The implementation is therefore a **triple buffer** (see §C.1), and the derived quantity in F-05 was removed rather than protected.

### B.2 What was deliberately not changed

- Biquad coefficient design, `warp_factor = w0 / sin(w0)`, the 0.45-Nyquist clamp, the 10 ms coefficient ramp and the ~10 ms preamp ramp: untouched (regression-proven by the frequency-response and zipper tests).
- `SoftLimiter` remains memoryless: no attack, release, lookahead, compressor or stereo link was introduced.
- Both processing paths remain allocation-free, lock-free, fixed-size and in-place, with the same zero-frame and invalid-pointer behaviour.
- The Host's render callback still applies the shared-memory EQ snapshot band by band, only when the snapshot changed.

---

## C. Architecture Changes

### C.1 A bounded triple-buffered configuration mailbox

`packages/dsp/src/config_mailbox.h` (new) holds:

- `EngineConfig` — one complete, self-contained configuration: the requested preset (band table, preamp, limiter settings, band count, name), a `BiquadCoeffs` for each of the 10 band slots, the sample rate those coefficients were derived at, a band-smoothing mask, and a "snap every band" flag.
- `ConfigMailbox` — three slots and a single `std::atomic<uint32_t>` packing front / middle / back at two bits each plus a "new data" bit. `publish()` writes the back slot and then does one compare-exchange that makes it the newest pending slot; `consume()` does one compare-exchange that swaps middle and front, then reads the new front. All three indices are always a permutation of {0, 1, 2}, so the producer's back slot is never the consumer's front slot: **nothing is ever written while it is being read.**
- `PublisherToken` / `PublisherLock` — a short spin that serialises publishers, because the public API promises "parameter updates are thread safe, callable from any thread". This is what makes the arrangement MPSC rather than quietly SPSC. The critical section is one ~500-byte POD copy plus one compare-exchange; the consumer never takes the token.

Defined behaviour, as required by the audit:

| Situation | Behaviour |
| --- | --- |
| Updates arrive faster than the audio thread consumes them | Latest wins; intermediate configurations are dropped, which is lossless because each is an absolute snapshot |
| "Mailbox full" | Cannot occur. There is no queue depth, no allocation, no back-pressure |
| Audio thread calls `consume()` | One acquire load and **at most one** compare-exchange attempt per block. If the attempt fails — a publish landed in between — the current block retains the configuration it already applied, and the pending publication is retried at the next block boundary. **There is no consumer retry loop.** |
| Producer contention, realtime path | One non-blocking token acquisition attempt (`PublisherToken::tryLock`). A refusal returns immediately and nothing is written. |
| Producer contention, control-thread path | The token is still acquired by a blocking spin (`PublisherToken::lock`). Its wait has **no wall-clock bound**: it lasts as long as the holder is off-CPU. |
| A successful publication | A fixed-size configuration copy into the back slot, then one CAS publish that retries only if the consumer exchanged in between; the token serialises producers, so no producer can keep that exchange failing |
| Same configuration needed by one block | `process_*()` consumes once at the top; nothing in the render loop re-reads the mailbox |

Neither producer path is wait-free, and no producer path has a wall-clock bounded wait. The realtime path is bounded in *attempts* (one token try, no consumer retry); the control path is bounded only by the scheduler. See §G.2 for what that changed and the realtime integration report `SoundBridge-Host-CoreAudio-Realtime-Validation-Report.md` for the measured cost of the realtime path.

### C.2 Ownership after the hand-off

The engine struct is now explicitly divided into three regions, in this order and with comments saying so:

1. **Audio-thread exclusive** — sample rate, biquad array and their interpolation state, the coefficients actually installed, the applied preset (whose `num_bands` *is* the active band count), the preamp smoother, the limiter runtime threshold, the limiter enable flag, the DC blocker, and the applied-reset counter.
2. **Published atomics** — bypass, applied sample rate, reset requests, frames processed, underrun count, CPU load and the four peak meters.
3. **Publishing side** — the mailbox, the publisher token, and the shadow configuration.

Nothing outside `process_*()` writes region 1. Nothing in region 1 is read by another thread. Region 2 is only ever touched with explicit memory orders (`relaxed` for the meters, `acquire`/`release` for the sample rate and the reset counter).

### C.3 Coefficients travel with the configuration

`refresh_config_coeffs()` runs on the publisher: it derives all ten band coefficients from the shadow preset at the shadow's own sample rate. The audio thread therefore never computes a coefficient and never has to decide "which sample rate does this coefficient belong to" — F-04's ambiguity is removed by construction. The per-sample cost of the render path is unchanged; the coefficient work moved from `Biquad::setCoeffsSmooth()` (where it already ran on the caller) into the publisher.

Change detection uses `applied_coeffs[]` — what the biquad actually holds — rather than a comparison of band parameters. That distinction matters: after a preset that shrinks `num_bands`, a parameter comparison can conclude "unchanged" and leave a stale coefficient installed.

### C.4 Reset became a monotonic request, not a configuration flag

Filter-history clearing belongs to the audio thread, so `soundbridge_dsp_reset()` now increments an atomic request counter and lets the next block clear the biquads, the DC blocker and snap the preamp ramp. A counter, not a flag inside the snapshot: the common `reset(); apply_preset();` sequence would otherwise let the second publish overwrite the pending reset and lose it. Statistics are still cleared immediately, because they are atomics no thread owns and a caller that resets and then reads the meters must see zeros.

### C.5 A preset is a baseline, an update is a nudge

`apply_preset()` publishes with "snap all bands" set and the smoothing mask cleared, so every band takes its new coefficients immediately and any ramp in flight is cancelled. `update_*()` marks only the band it changed, so that band ramps over ~10 ms. `set_sample_rate()` forces a snap by nature. Without that split, either a preset change would ramp every band (audible sweep) or an update would snap (zipper noise).

### C.6 Diagnostics contract

`linear_to_dbfs()` owns the floor (−120 dBFS), the ceiling (+771 dBFS), the "positive means overrange" rule and the never-NaN guarantee; `get_stats()` cannot bypass it. The peak meters are now measured both before and after the limiter, so overdrive stays visible while the limiter holds the output. `underrun_count` is documented as reserved and locked at 0 by a test, because the engine genuinely cannot observe IO underruns — the Host's ring telemetry does.

### C.7 Numeric hardening

- Limiter: the knee is derived from a single stored threshold (no torn pair), the curve is evaluated in `double` (no `Inf/Inf` for large finite inputs), and the result is clamped to the ceiling (no ULP overshoot).
- Biquad: a non-finite output resets the section state and emits silence instead of forwarding the offending sample.
- Setters reject non-finite input before clamping (`std::min(12.0f, NaN)` is `12.0f`, i.e. "corrupt NaN → maximum boost").

### C.8 Build, version and header consistency

- **F-18:** the Host needs a local copy of the DSP headers because SwiftPM targets may only see headers inside their own directory. That copy had drifted — the Host's `soundbridge_types.h` was **missing two fields of `soundbridge_stats_t`**, an ABI mismatch, and its `soundbridge_dsp.h` still said `reset()` "may allocate". `tools/sync_dsp_headers.sh` (same shape as the existing `tools/sync_shared_header.sh`) makes the copies generated artifacts and `--check` makes drift a build-gate failure; `make protocol-check` runs it.
- **F-20:** `project(soundbridge_dsp VERSION …)` now reads the repository `VERSION` file before `project()` instead of pinning `1.0.0`. The library reports `1.2.0`; a test compares `soundbridge_dsp_get_version()` with the same `VERSION` file at runtime; `tools/verify_version_consistency.sh` gained a DSP section that fails if the version is pinned again.
- **Sanitizers:** `-DSOUNDBRIDGE_DSP_SANITIZE=thread|address|undefined` selects a sanitizer for the whole DSP tree. It forces a single architecture (ThreadSanitizer cannot instrument a universal binary) and refuses `CMAKE_BUILD_TYPE=Debug`, which hardcodes AddressSanitizer. `make test-dsp-tsan` is the one-command entry point.

---

## D. Test Evidence

Everything in this section was executed on this machine, on the current working tree. Nothing is inferred from compilation.

### D.1 DSP suite, Release (default universal build)

```
$ cd packages/dsp && cmake -S . -B build && cmake --build build --target soundbridge_dsp_tests
$ ./build/tests/soundbridge_dsp_tests
Results: 66 passed, 0 failed            (repeated 3× — 66/66 each time)
```

Test count history: **53** at the start of the remediation → **66** at the end of it (7 mailbox tests, 4 engine-level concurrency tests and 2 version tests) → **72** after the review fixes (2 biquad, 2 engine and 2 mailbox tests, all in §F) → **75** after the verification round (1 token test and 2 batch-publish tests, §G.2). This section records the 66-test runs as they were made; §F.5 re-runs every gate at 72, §G.3 at 75.

### D.2 ThreadSanitizer

```
$ make test-dsp-tsan
-- Sanitizer: thread (architecture forced to arm64)
Results: 66 passed, 0 failed
$ echo $?          → 0
$ grep -c "WARNING: ThreadSanitizer" …  → 0
```

Configuration: `CMAKE_BUILD_TYPE=RelWithDebInfo`, `SOUNDBRIDGE_DSP_SANITIZE=thread`, arm64, `TSAN_OPTIONS=halt_on_error=1`. This is the executed coverage for F-02 … F-05: the mailbox's multi-producer test (4 producers × 20 000 publishes, serialised by the token), the tearing test, and the four engine concurrency tests all run under it.

### D.3 AddressSanitizer and UndefinedBehaviorSanitizer

```
$ cmake -B /tmp/sb-dsp-asan -DCMAKE_BUILD_TYPE=Debug          # Debug hardcodes -fsanitize=address
Results: 66 passed, 0 failed, 0 "ERROR: AddressSanitizer"

$ cmake -B /tmp/sb-dsp-ubsan -DCMAKE_BUILD_TYPE=RelWithDebInfo -DSOUNDBRIDGE_DSP_SANITIZE=undefined
Results: 66 passed, 0 failed, 0 "runtime error"
```

`detect_leaks=1` is **not supported on this platform** (LeakSanitizer is unavailable on macOS arm64); the ASan runs above were therefore executed without leak detection.

### D.4 The new tests, and what each one actually proves

| Test | Proves |
| --- | --- |
| `config_mailbox_starts_empty` / `_delivers_a_published_configuration` | Delivery, and that a single pending configuration is consumed exactly once |
| `config_mailbox_coalesces_to_the_newest_pending_configuration` | Latest-wins; superseded configurations are not queued |
| `config_mailbox_survives_sustained_saturation` | 50 000 publishes with one consumer: the newest survives, the mailbox never grows |
| `config_mailbox_never_tears_a_snapshot` | Producer and consumer spinning flat out: every consumed snapshot is internally consistent, and the last consumed snapshot is the last published one |
| `config_mailbox_multi_producer_keeps_every_snapshot_whole` | MPSC shape, 4 producers × 20 000 publishes through the token |
| `config_mailbox_indices_stay_distinct_over_time` | 100 000 publish/consume alternations never write into the slot being read |
| `engine_saturated_mailbox_applies_only_the_newest_update` | 20 001 publishes before one block: the block uses the newest configuration, measured as gain |
| `engine_updates_from_another_thread_are_applied` | A producer thread hammering `update_band_gain`/`update_preamp` while 512-frame blocks render: all output finite, then the settled value is measured |
| `engine_concurrent_preset_switching_settles_on_the_last_preset` | Two threads applying opposite presets while rendering: finite, bounded output, correct final state |
| `engine_reset_survives_a_following_preset` | `reset()` then `apply_preset(flat)` then silence in → exactly zero out (a stale DC-blocker pole would ring) |
| `version_is_a_dotted_numeric_string` / `version_matches_the_repository_product_version` | F-20 |

Two honest limits on this table:

- The output-level concurrency tests **cannot** prove per-block atomicity. A block that mixed two configurations would produce output that looks like some legal configuration, and no level measurement distinguishes that from a legal one. That property rests on two other things: the mailbox tests prove a consumed snapshot is never torn, and `apply_config()` runs to completion at the top of the block before the first sample is read. Both are structural, and both are stated in `config_mailbox.h` under "Per-block consistency".
- The concurrency tests are bounded in time (≈120 ms of rendering each). They demonstrate absence of tearing and of crashes under load; they do not prove absence of races — ThreadSanitizer is the argument there.

### D.5 Failure injection for F-01 (A/B against the old framework)

A two-translation-unit probe was compiled against the current `test_utils.h` — runner in one TU, failing assertion in another, which is exactly the shape that used to break:

```
$ clang++ -std=c++17 -I packages/dsp/tests main.cpp failing.cpp -o probe && ./probe
Found 1 tests
Running: probe_deliberate_failure...❌ FAIL: failing.cpp:5: 1 == 2
 ✗
Results: 0 passed, 1 failed
PROBE_EXIT=1
```

The old framework reported `0 passed, 0 failed`, `✓`, and exit 0 for this input (the audit's §1.3 measurement). The probe sources were temporary and have been removed.

### D.6 Whole-repository gate

```
$ make test        → exit 0, "✓ All test suites passed"
```

| Stage | Result |
| --- | --- |
| `protocol-check` (shared protocol layout + 4 identical copies) | pass |
| `protocol-check` (DSP public headers, 2 identical copies) | pass |
| `version-check` | 13 sources checked, 0 failed |
| `test-dsp` (CTest) | 1/1 suite passed; the suite itself 66/66 |
| `test-driver` (CTest) | 3/3 suites passed |
| `test-host` (`swift test`) | **399 tests, 0 failures** |
| `test-app` (`swift test`) | **298 tests, 0 failures** |
| `test-installer` | 168 transaction scenarios passed; 99 checks passed, 0 failed, 0 skipped |
| `test-unsigned` | 97 checks, 0 failures (unsigned release policy) |

This matters beyond arithmetic: the Host's 399 tests include the render-path and lifecycle suites and they pass **against the new engine and the new headers with no change to any call site**.

### D.7 Builds

| Build | Result |
| --- | --- |
| DSP, Release, universal `arm64;x86_64` | success |
| DSP, RelWithDebInfo + ThreadSanitizer, arm64 | success |
| DSP, Debug + AddressSanitizer | success |
| DSP, RelWithDebInfo + UBSan, arm64 | success |
| `packages/host` `swift build -c release` | `Build complete!` |
| `apps/mac/SoundBridgeApp` `swift build -c release` | `Build complete!` |

### D.8 Not executed (stated explicitly)

- **No sanitizer coverage of the Swift or Objective-C++ code.** TSan/ASan/UBSan were run on the DSP test binary only. The Host's `AudioRenderer` shared-memory path was exercised by its own 399 tests, unsanitised.
- **No x86_64 sanitizer run.** Sanitizer builds were forced to the host architecture (arm64); the x86_64 slice of the universal release build was compiled but not executed.
- **No real-hardware or device-latency measurement.** Nothing in this report is a claim about callback latency under load on a customer machine.
- **No power-loss or filesystem-crash verification.** Out of scope; no such claim is made.
- **No Xcode/CI pipeline change.** The sanitizer runs are local commands, documented in `make test-dsp-tsan`; no workflow file was modified.

---

## E. Remaining Risks

### E.1 Producer-side wait: closed for the audio thread, still present for control threads

An earlier revision of this section said the audio thread's exposure was "bounded by that copy plus one compare-exchange". That was wrong, and §G.2 records the correction: the *consumer* makes one bounded attempt, but the Host's render callback used to publish through eleven blocking setters, so its wait was bounded by nothing this library controls — only by when the descheduled peer was scheduled again.

That gap is now closed for the realtime path. `soundbridge_dsp_try_update_eq()` is the entry point a render callback uses: it makes one token attempt, publishes the whole batch once, and returns `false` without touching anything if a peer holds the token. The Host calls it, and on a refusal the next block retries. One attempt, one compare-exchange, one publish, no loop.

What remains is stated rather than implied:

- The per-band and preamp setters (`soundbridge_dsp_update_band_gain`, `update_preamp`, `update_band_frequency`, `update_band_q`) are unchanged and still acquire the token with a blocking spin. They are control-thread calls; the header says so. Putting one on a realtime thread reintroduces the defect.
- The mailbox is not wait-free and is not claimed to be. A control-side publisher can be delayed by a descheduled peer, and an EQ change published on the control side therefore inherits that delay. The audio thread no longer does.
- A strictly wait-free producer path would need per-producer slots. It was rejected: the token already serialises the producers correctly, and the only defect was blocking acquisition on the realtime side, which is what changed.

### E.2 `get_preset()` returns the requested configuration, not the applied one

By design: a read-after-write in the UI must not show a stale value for one block. The consequence is that during the single block between publish and consume, `get_preset()` and what the audio thread is doing can differ by one update. Documented in the header.

### E.3 `reset()` clears filter history at the next block boundary

Statistics are immediate; the biquads, DC blocker and preamp ramp settle at the next boundary. A caller that resets and then expects the *next* sample to be computed from zeroed state is correct, because that sample is the next block. A caller that resets and then reads back filter state (there is no such API) would not be.

One deliberate limit, added with review finding R2 (§F.2): a reset clears history but does not cancel a coefficient transition that is already in flight, because the target of that transition is already recorded in the applied-configuration baseline and cancelling it would strand the filter at an intermediate coefficient set. So `reset()` means "the stream restarted", not "discard the pending parameter change".

### E.4 Per-callback clock reads are retained (F-21)

`process_*()` still calls `high_resolution_clock::now()` twice per block to maintain `cpu_load_percent`, and the CPU EMA still costs one `exp()`. The audit recorded this as an observation with no action required. It is now fed to a consumer (`takeDiagnostics()`), so the cost buys something; it is not optimised further because the measured cost is immaterial next to the filter work and removing it would break a documented stats field.

### E.5 F-19 is deferred, with a migration plan

**Current state.** `packages/host/Package.swift` links the sibling CMake product with:

```swift
.linkedLibrary("soundbridge_dsp"),
.unsafeFlags(["-L../../packages/dsp/build"]),
.unsafeFlags(["-lc++"]),
```

Established this round:

- A clean clone must run `make dsp-build` (or `make test-host`) before `swift build`; the Makefile already encodes that ordering and documents why.
- `.unsafeFlags` is only legal for a root package. Any future consumer of `SoundBridgeHost` as a *dependency* would be refused by SwiftPM.
- The DSP build is universal, so a single-architecture `swift build` links the matching slice correctly today.
- `-lc++` is required because the static archive contains C++ objects behind a C ABI.

**Why it is not fixed now.** Every alternative (an XCFramework binary target, a build-tool plugin, or a SwiftPM target that compiles the DSP sources directly) changes the artifact the release scripts consume: `tools/build_release.sh`, `create_app_bundle.sh`, `codesign.sh`, `create_dmg.sh` and four verifiers all reference `packages/dsp/build/libsoundbridge_dsp.a` or the signed bundle layout. That is a release-pipeline change, not a DSP change, and the audit explicitly allowed it to be a separate follow-up rather than a blocker.

**Concrete migration plan.**

1. Add a `dsp-xcframework` target to the Makefile that builds the static library for `arm64` and `x86_64` and runs `xcodebuild -create-xcframework`, writing `packages/dsp/build/SoundBridgeDSP.xcframework` and its `.dSYM`.
2. Add `.binaryTarget(name: "SoundBridgeDSPBinary", path: "../../packages/dsp/build/SoundBridgeDSP.xcframework")` and make `CSoundBridgeDSP` depend on it, keeping the existing headers/module map as the public interface.
3. Prove equivalence before deleting anything: `swift test` in `packages/host` (399 tests), `swift build -c release`, `make bundle`, then `tools/verify_release_payload.sh` and `tools/verify_dmg_contents.sh` on a signed artifact.
4. Only then point the release scripts at the XCFramework and remove the two `.unsafeFlags` entries.
5. Gate it: a `make protocol-check`-style step that fails if `Package.swift` still contains `-L../../packages/dsp/build` once the binary target exists.

Prerequisite: a machine that can build both slices, and a decision about whether to commit the XCFramework or build it in CI. Until step 3 passes, the current arrangement stays.

---

## F. Independent Review Remediation (R1–R4)

After the twenty findings in §B were closed and §D recorded 66/66, the working-tree diff — not this report — was handed to an independent review pass. It returned four findings: two defects in the implementation (R2, R4), one defect in a guarantee the implementation claims (R3), and one false statement in this report (R1). All four are resolved below, each with the test that locks it.

Nothing in §C was redesigned. The triple buffer, the publisher token, one complete configuration per publish, coefficients computed on the publishing thread, consumption once per block, the 10 ms smoothing, the Nyquist clamp, the sample-rate preamp preservation, and the biquad / DC-blocker / limiter algorithms are all unchanged. The diff for the four fixes is one new `Biquad` method, two call-site edits, one predicate, one compare-exchange shape, comments, and six tests.

Severity as filed by the review versus as accepted here:

| ID | Filed | Accepted | Why it changed |
| --- | --- | --- | --- |
| R1 | Blocking (out-of-bounds write for a stale caller) | **Medium** | No consumer in this repository can be stale: the DSP is a static archive linked into the Host, every call site lives in this tree, and `make protocol-check` refuses a drifting Host header copy. The defect is the report's false claim plus the missing policy, not a live memory-safety bug. |
| R2 | High | **High** | It is the only finding with a wrong number coming out of the library, and it is permanent: the filter never reaches the requested gain. |
| R3 | High | **Medium** | Unbounded retry is a realtime-budget defect, not a correctness one: the mailbox cannot tear or corrupt state, and the loop can only run long, not produce a wrong configuration. |
| R4 | Medium | **Low** | The settled gain is identical either way; what is lost is the instantaneous transition a preset is supposed to produce. |

### F.1 R1 — the statistics struct grew, and this report said it had not

**Original finding.** `soundbridge_dsp_get_stats()` takes no size argument and writes `sizeof(soundbridge_stats_t)` bytes into the caller's struct. F-12 appended `peak_left_db_pre_limiter` and `peak_right_db_pre_limiter`, growing the struct from 32 to 40 bytes — while §A of the previous revision stated that no downstream struct layout had changed. A caller compiled against the older header gets an 8-byte out-of-bounds write.

**Measured, not recalled.** Both headers were compiled into probes; the pre-change header was extracted with `git show HEAD:packages/dsp/include/soundbridge_types.h`, so the baseline is the real one rather than a description of it:

```
old: sizeof = 32  alignof = 8  peak_left_db at 24
new: sizeof = 40  alignof = 8
     frames_processed 0   underrun_count 8   cpu_load_percent 12   bypass_active 16
     sample_rate 20       peak_left_db 24    peak_right_db 28
     peak_left_db_pre_limiter 32            peak_right_db_pre_limiter 36
```

Every pre-existing offset is preserved, alignment is unchanged, and the two new fields are at the end. The change is append-only — and append-only is a *source* property, not a binary one.

**Scope of the actual risk, established rather than assumed.** A tree-wide search finds four `get_stats()` call sites: `packages/host/Sources/SoundBridgeHost/Audio/AudioRenderer.swift` (the only production one, through the C shim), `packages/dsp/tools/wav_processor.cpp`, `packages/dsp/tests/test_engine.cpp`, and `packages/dsp/bridge/SoundBridgeDSPEngine.mm` (a bridge that neither the Host nor the App links). All of them rebuilt in this round against the synchronised headers, and the Host's 399 tests re-passed without editing a call site. There is no in-tree consumer that can be stale, which is why the severity is Medium. The finding still stands as filed in substance: the report promised a compatibility property the code does not have.

**Resolution.**
- `include/soundbridge_types.h`: an "ABI policy — read this before adding a field" block above the struct, stating that the contract is **source compatibility with coordinated rebuilding**; that this is a statement about the product, **not** something static linking confers; that fields are append-only; that a consumer must be rebuilt with the library or not linked at all, because `get_stats()` cannot detect a smaller caller; and that binary compatibility, if it is ever required, needs a versioned entry point carrying a size or version rather than a wider write into the legacy one.
- The policy is machine-checked where it can be: `static_assert(sizeof(soundbridge_stats_t) == 40)` and nine `offsetof` assertions, inside `#ifdef __cplusplus`. A C consumer gets the prose, not the check — stated as a limitation below.
- `soundbridge_dsp.h` and the Host copies were synchronised with `tools/sync_dsp_headers.sh`; `make protocol-check` now fails if they drift, so a stale copy cannot survive the gate.
- §A of this report was rewritten accordingly, and the old claim is contradicted explicitly rather than quietly removed.

**Regression test.** None, and none is needed: a size is asserted more directly by a `static_assert` that fails the build than by a test that fails at runtime. What is *not* covered is a C caller compiled elsewhere, which no in-tree test can represent.

**Remaining limitations.** No versioned stats API exists and none is promised. A separately compiled legacy caller is not binary compatible and nothing in the library detects it. The `static_assert`s are C++-only.

### F.2 R2 — a reset cancelled a coefficient ramp that had already been recorded

**Original finding.** `sync_config()` applies a newly consumed configuration and then services any pending reset by calling `bq.reset()`. `reset()` zeroed the delay state *and* `transition_remaining_`, so a ramp started microseconds earlier in the same block was cancelled with `coeffs_` still at an interpolated intermediate set. Because `apply_config()` had already written that ramp's target into `applied_coeffs[]`, every later update carrying the same target was then skipped by the equality check — so the filter was stranded at the intermediate gain permanently, with no API that could recover it other than a different target.

**Measured.** A probe built outside the test suite: `update_band_gain(0, +12 dB)` immediately followed by `soundbridge_dsp_reset()`, then 1 s of 1 kHz sine.

```
before the fix:  A) update, no reset   +12.00 dB      B) update + reset   +0.00 dB
after  the fix:  A) update, no reset   +12.00 dB      B) update + reset   +12.00 dB
```

**Resolution.** The reset semantics were split rather than patched:
- `Biquad::resetHistory()` clears `state_left_` and `state_right_` only. Coefficients, target coefficients, the interpolation delta and `transition_remaining_` are untouched.
- `reset()` remains `resetHistory()` plus cancellation of the transition — the full reset that initialisation and any caller who means "discard the pending change" wants. Its behaviour is unchanged.
- `sync_config()` calls `resetHistory()`, with a comment naming the invariant: **clearing filter history must not cancel a coefficient transition whose target has already been recorded in the applied configuration baseline.**
- `soundbridge_dsp.h` documents the same thing at `soundbridge_dsp_reset()`, and §E.3 states the resulting rule: `reset()` means "the stream restarted", not "discard the pending parameter change".

**Files changed.** `packages/dsp/src/biquad.h`, `packages/dsp/src/engine.cpp`, `packages/dsp/include/soundbridge_dsp.h` (+ Host copy), `packages/dsp/tests/test_biquad.cpp`, `packages/dsp/tests/test_engine.cpp`, `packages/dsp/tests/test_main.cpp`.

**Regression test.** `engine_reset_does_not_cancel_a_pending_coefficient_ramp` — flat preset, baseline measured, `update_band_gain(+12 dB)`, `reset()`, then measure: asserts 12.0 ± 0.3 dB, and afterwards that a second reset followed by silence produces exactly `0.0f` (history really was cleared, not merely left alone). Its counter-test `biquad_reset_cancels_a_coefficient_transition` locks the *retained* `reset()` semantics so the split cannot silently collapse into one behaviour, and `biquad_reset_history_keeps_the_transition_running` pins `resetHistory()` against a biquad whose gain is directly observable.

**Verification evidence.** Reverting only `resetHistory()` → `reset()` in a copy of `engine.cpp` and rebuilding produces **70 passed, 2 failed**, and the failure is exactly this test: measured **0.0028579 dB** against a required 12.0 dB. Restoring the fix returns 72/72 and the probe above to `+12.00 / +12.00`.

**Remaining limitations.** The delayed reset still zeroes the DC blocker and snaps the preamp smoother to its target, both deliberately. `resetHistory()` is a public C++ method with no C entry point; the C ABI still exposes only `soundbridge_dsp_reset()`, which now means the history-clearing variant when the reset is serviced at a block boundary.

### F.3 R3 — the consumer's CAS retry had no bound

**Original finding.** `consume()` retried a weak compare-exchange in `for (;;)`. If a publisher wins the exchange before the consumer does, the consumer loops; a publisher publishing between attempts can keep it failing indefinitely. Lock-free is not the same as bounded: the audio thread can spend an unbounded number of iterations inside one block, which is precisely what a realtime callback cannot afford.

**Resolution.** The consumer path is now one load and at most one exchange:
- `consume()` = one `load(acquire)` + `try_consume(out, expected)`.
- `try_consume()` performs a single `compare_exchange_strong` (`acq_rel` on success, `acquire` on failure). On failure it returns false **without touching `state_`**, so the pending publication stays visible and the same block keeps the configuration it already had. On success it copies `slots_[middle]` — only after ownership is acquired — and returns true.
- The producer side, the index packing, the slot rotation and the memory orderings are untouched. No new shared state, no retry, no allocation, no lock.
- The failure path is reachable deterministically in tests through `friend struct ConfigMailboxTestAccess`, which reads the published state and calls `try_consume` with a deliberately stale expectation. The friend exists for tests only; it costs the production path nothing and requires no `#ifdef`.
- The header's behaviour table now says, verbatim, that **if consumer ownership acquisition fails, the current block retains its previously applied configuration and consumption is retried at the next block boundary.** It also states explicitly that lock-freedom alone does not give per-block bounded work, and that the mailbox as a whole is *not* claimed wait-free — the producer can still be delayed by a descheduled peer (§E.1).

**Files changed.** `packages/dsp/src/config_mailbox.h`, `packages/dsp/include/soundbridge_dsp.h` (+ Host copy), `packages/dsp/tests/test_config_mailbox.cpp`, `packages/dsp/tests/test_main.cpp`.

**Regression test.** `config_mailbox_failed_attempt_leaves_the_update_pending`: publish tag 11, record the state, publish tag 12, then attempt from the stale state — asserts the attempt fails, the output struct is unwritten (sentinel preserved), `has_pending()` is still true, and a normal `consume()` in the next "block" returns tag 12 and clears pending. `config_mailbox_empty_state_is_a_false_return` pins that an empty mailbox consumes nothing. The pre-existing `config_mailbox_never_tears_a_snapshot`, `_survives_sustained_saturation`, `_multi_producer_keeps_every_snapshot_whole` and `_indices_stay_distinct_over_time` are unchanged and still green, which is the evidence that ownership and ordering were preserved rather than merely not exercised.

**Verification evidence.** Restoring a retry loop in a copy of `config_mailbox.h` makes `config_mailbox_failed_attempt_leaves_the_update_pending` fail — the bounded property is what the test observes, not merely that a stale attempt is rejected. That artificial patch also broke `config_mailbox_never_tears_a_snapshot`, but for an unrelated reason: the patch reused the first `middle` index after a retry. That second failure is therefore not evidence about the retry loop; it is evidence that the tearing test is sensitive to a genuinely torn read.

**Remaining limitations.** The guarantee is *one attempt per block*, not eventual consumption. A publisher that publishes between every pair of blocks can starve the consumer for an unbounded number of blocks. The requirement was bounded consumer work, and that is what is now structural.

### F.4 R4 — a preset's snap could be lost to a later publish

**Original finding.** The equality skip in `apply_config()` was `if (!snap && biquadCoeffsEqual(...)) continue;`. `snap_all_bands` is cleared immediately after `apply_preset()` publishes, because the mailbox is latest-wins and the flag describes *that* publication. If a preset is still pending when another parameter is published, the preset is consumed as an ordinary non-snap update. When its target equals the applied baseline — the common case of re-selecting the preset already in force — the band was skipped, so the in-flight ramp was not cancelled and the block kept sliding toward the old target. The preset's defining behaviour, an instantaneous transition, disappeared.

**Resolution.** `if (!snap && config.is_smooth(i) && biquadCoeffsEqual(...)) continue;` — equality skipping is now permitted only for updates explicitly marked smooth. A non-smooth request is applied even when its target equals the baseline, which is what cancels the ramp and writes the intended coefficients. `snap_all_bands` is still cleared after each publish; it is not kept true.

**Files changed.** `packages/dsp/src/engine.cpp`, `packages/dsp/tests/test_engine.cpp`, `packages/dsp/tests/test_main.cpp`.

**Regression test.** `engine_preset_snap_survives_a_coalesced_publish`: preset at −12 dB and measured; `update_band_gain(+12 dB)` to start a ramp; one block processed so the ramp is in flight; then `apply_preset(+12 dB)` **and** `update_preamp(0)` published together, so the preset is consumed non-snapped exactly as in the field. The next 256-frame block must measure 12.0 ± 1.5 dB — the preset landed and the ramp was cancelled — instead of the ~7.8 dB the in-flight ramp would have produced. The same test then issues an ordinary `update_band_gain(0)` and asserts the first block is still smooth (> 6 dB, not an instant jump), proving the fix did not turn every update into a snap.

**Verification evidence.** Removing `config.is_smooth(i) &&` from a copy of `engine.cpp` and rebuilding gives **70 passed, 2 failed**, with this test measuring **7.82319 dB**; with the fix it measures **11.3793 dB**. The 0.62 dB shortfall from 12.0 is the block in which the snap is consumed plus preamp/meter settling within the assertion window, which is why the tolerance is 1.5 dB rather than 0.3.

**Remaining limitations.** A preset that is superseded in the mailbox before it is consumed is still lost — that is latest-wins, by design and by test. Only the final published configuration is applied.

### F.5 This round's re-run evidence

Every line below was produced by this round's runs, after the fixes. Nothing is carried over from §D.

| Gate | Result |
| --- | --- |
| DSP suite, Release, universal `arm64;x86_64` | **72 passed, 0 failed** |
| DSP suite, RelWithDebInfo + ThreadSanitizer, `halt_on_error=1` | **72 passed, 0 failed**, no `WARNING: ThreadSanitizer` |
| DSP suite, Debug + AddressSanitizer, `detect_leaks=0` | **72 passed, 0 failed**, no `ERROR: AddressSanitizer` |
| DSP suite, RelWithDebInfo + UBSan, `print_stacktrace=1` | **72 passed, 0 failed**, no `runtime error` |
| A/B, R2 and R4 reverted in a copy of `engine.cpp` | **70 passed, 2 failed** — exactly the two R2/R4 engine tests |
| A/B, R3 retry loop restored in a copy of `config_mailbox.h` | `config_mailbox_failed_attempt_leaves_the_update_pending` fails |
| ABI probe, pre-change header vs current header | old `sizeof = 32`, `alignof = 8`, `peak_left_db @ 24`; new `sizeof = 40`, `alignof = 8`, offsets 0/8/12/16/20/24/28/32/36 |
| R2 probe, `update` vs `update + reset()` | both `+12.00 dB` (was `+12.00` / `+0.00` before the fix) |
| `make protocol-check` | exit 0 — protocol header 4 files identical, DSP headers 2 files identical |
| `make test` | exit 0 — Host 399/399, App 298/298, Driver 3/3 suites, install transaction 168/168 scenarios, installer gate 99 passed / 0 failed, unsigned-release policy 97 checks / 0 failures, version 13 sources / 0 failed |
| `packages/host` `swift build -c release` | `Build complete!` |
| `apps/mac/SoundBridgeApp` `swift build -c release` | `Build complete!` |

---

## G. Post-Remediation Verification Round

This section is the record of a separate pass made after the review fixes landed. Its rule was simple: no finding counts as fixed because §B says so, and no gate counts as passed because an earlier run passed it. Every finding was located in the current tree, every gate was re-run at the current test count, and the one gap that survived was closed here rather than described here.

Nothing in §C was redesigned. The mailbox, its index packing, the token, the ownership regions, one complete configuration per publish, coefficients computed on the publisher, one consumption per block, the 10 ms smoothing, the Nyquist clamp, the preamp preservation across rate changes, the biquad/DC-blocker/limiter algorithms and the `reset()` / `resetHistory()` distinction are all unchanged.

### G.1 Status of every finding, checked against the tree

`VERIFIED` — implementation located in the current tree and its regression test ran green in this round's runs (§G.3). `CLOSED HERE` — a gap was found in this round and fixed in this round. `DEFERRED` — out of scope by the audit's own allowance.

| ID | Sev | Status | Implementation, as it stands | Test that locks it | Residual risk |
| --- | --- | --- | --- | --- | --- |
| F-01 | P1 | VERIFIED | `tests/test_utils.h`: one function-local `test_stats()` instance; `ASSERT*` increment it and return; `run_all_tests()` returns `failed == 0 ? 0 : 1` | Two-TU failure probe (§D.5) plus this round's in-suite injection (§G.3) | None |
| F-02 | P1 | CLOSED HERE (producer side); consumer side verified | Triple-buffered mailbox + publisher token (§C.1); `soundbridge_dsp_try_update_eq()` is now the realtime publish entry point (§G.2) | 10 mailbox/token tests, 6 engine concurrency tests | Control-thread setters still wait for a peer (§E.1) |
| F-03 | P2 | VERIFIED | Band count and coefficients travel in one `EngineConfig`; the consumer adopts the whole snapshot at a block boundary | `engine_default_state_is_consistent`, `engine_saturated_mailbox_applies_only_the_newest_update` | None |
| F-04 | P2 | VERIFIED | Three ownership regions; `applied_sample_rate` is a release/acquire atomic; `get_stats()` reads atomics only | `engine_statistics_tracking`, the concurrency tests, TSan | None |
| F-05 | P2 | VERIFIED | `SoftLimiter` stores one `threshold_`; the knee is derived from it per sample | `limiter_knee_is_continuous`, `limiter_threshold_change_moves_knee` | None |
| F-06 | P2 | VERIFIED | Non-finite input is rejected by `isfinite` before the ±12 dB clamp | `engine_realtime_parameter_rejects_non_finite` | None |
| F-07 | P2 | VERIFIED | The biquad's non-finite guard outputs 0 rather than the offending input | `engine_non_finite_input_stays_finite` | None |
| F-08 | P2 | VERIFIED | Peak dB conversion has both a floor and a ceiling; `double` intermediate | `engine_stats_peak_reports_overrange`, `engine_stats_peak_is_finite_for_extreme_input` | None |
| F-09 | P2 | VERIFIED | `num_active_bands` no longer exists; a preset's band count is the only count | `engine_default_state_is_consistent` | None |
| F-10 | P3 | VERIFIED | Limiter curve evaluated in `double`, result clamped | `limiter_process_buffer_is_never_non_finite` | None |
| F-11 | P3 | VERIFIED | `if (!(limited <= ceiling)) limited = ceiling;` | `limiter_never_exceeds_threshold` | None |
| F-12 | P2 | VERIFIED | Pre-limiter peaks recorded before the limiter stage, appended to the stats struct | `engine_stats_pre_limiter_peak_sees_overdrive` | Struct growth — source-compatible only (§F.1) |
| F-13 | P3 | VERIFIED (contract) | `underrun_count` documented as reserved and always 0 | `engine_stats_underrun_count_stays_reserved` | None |
| F-14 | P3 | VERIFIED | Host `takeDiagnostics()` calls `soundbridge_dsp_get_stats()` | Host suite 399/399 (§G.3) | None |
| F-15 | P3 | VERIFIED | Both process entry points apply denormal suppression on the calling thread, per block | `engine_denormal_suppression_applies_to_the_calling_thread` | None |
| F-16 | P3 | VERIFIED | No `-ffast-math` in `packages/dsp/CMakeLists.txt` | `freq_response_thd_remains_low` and the numeric tests | None |
| F-17 | P3 | VERIFIED | Byte arithmetic widened to `size_t` before multiplication | `buffer_math_copy_bytes_does_not_wrap`, `buffer_math_uint32_fit_predicate`, `buffer_math_wrapping_expression_differs` | None |
| F-18 | P3 | VERIFIED | Both public headers single-sourced; `tools/sync_dsp_headers.sh --check` re-run here | `make protocol-check`, exit 0 (§G.3) | None |
| F-19 | P3 | DEFERRED | Unchanged: SwiftPM links the CMake product through `.unsafeFlags` | — | Migration plan in §E.5 |
| F-20 | P3 | VERIFIED | Version parsed from the `VERSION` file; 13 sources cross-checked | `version_matches_the_repository_product_version` | None |
| F-21 | — | NOT APPLICABLE | Two clock reads per callback retained deliberately | — | §E.4 |

### G.2 The one gap: the render callback was a blocking publisher

**What was wrong.** §E.1 claimed the audio thread's exposure was "bounded by that copy plus one compare-exchange". The consumer's attempt is bounded; the producer's wait was not. In the shipping Host, `AudioRenderer.render()` published an EQ change by calling `soundbridge_dsp_update_band_gain()` ten times and `soundbridge_dsp_update_preamp()` once. Every one of those takes the publisher token with `PublisherToken::lock()` — a spin loop with `std::this_thread::yield()` — on the render thread. If a control thread was descheduled inside its own publish, the callback waited for the scheduler, and the file's own contract ("no blocking wait") was false.

**Is this a correctness gap, or a redesign?** It is a gap in one guarantee, and the fix is deliberately narrow. The mechanism that serialises producers — the token — is correct and stays. Concurrent control-side producers were never the problem: they are safely serialised exactly as §C.1 describes, and the mailbox is *not* an SPSC mechanism mislabelled as MPSC (the multi-producer test runs 4 producers × 20 000 publishes). What changes is the *form of acquisition on the realtime side*, plus the number of publishes a single EQ change costs: eleven became one.

**Rejected alternatives.** Per-producer slots or a multi-producer ring, so that no publisher ever waits: rejected. It would add producer-index allocation, memory-ordering constraints and a second consumer path to solve a problem that is not "producers contend" but "the realtime thread must not wait". Reusing the existing setters on a background thread with the audio thread reading a shadow copy: rejected as a larger ownership change with the same one-block-latency behaviour this fix already has.

**Implementation.**

| Piece | Change |
| --- | --- |
| `PublisherToken::tryLock()` | One `exchange(acquire)`, no loop. `lock()` is unchanged and remains control-thread only; its documentation now says its wait length is set by the scheduler. |
| `PublisherTryLock` | RAII wrapper that releases only if it acquired, so a refusal cannot unlock a peer's section. |
| `soundbridge_dsp_try_update_eq(engine, band_gains_db[SOUNDBRIDGE_MAX_BANDS], preamp_db)` | One token attempt; on refusal returns `false` having written nothing; on success applies the same ±12 dB clamp and the same non-finite rule as the per-band setter (a non-finite band keeps its last valid value), marks every band for the 10 ms ramp, and publishes once. Band count is the requested one, so a batch never widens or narrows the preset. |
| `AudioRenderer.render()` | One `soundbridge_dsp_try_update_eq()` per changed shared-memory snapshot instead of eleven setters. `soundbridge_dsp_set_bypass()` stays unconditional — it is an independent atomic and must not wait on the token. `lastEQSnapshot` is advanced **only** when the batch actually published, so a refused batch is retried on the next block rather than being recorded as applied. |
| `soundbridge_dsp.h` (both copies) | The Realtime Safety block now separates the two classes of entry point: `try_update_eq()` is bounded; the setters are control-thread only. |

**New tests (3, suite now 75).**

- `publisher_token_try_lock_is_bounded_and_exclusive` — a held token refuses `tryLock()`; a refusal leaves the peer's section intact; a granted `PublisherTryLock` releases on destruction.
- `engine_try_update_eq_publishes_the_whole_batch` — bands and preamp land together (0 → +12 dB, then +6 dB with preamp −6), a NaN band keeps the last valid value and does not refuse the batch, and the active band count is unchanged.
- `engine_try_update_eq_is_refused_while_a_peer_holds_the_token` — the token is held through a test seam (`soundbridge::test_support`, not part of the API) to make "a peer is publishing" a real state: the attempt returns `false`, the engine stays at 0 dB, the next block's retry succeeds, and null arguments are refused.

**A/B counter-proofs.** Both injections were applied to the working tree and then reverted; the reversion was confirmed by `shasum` against a pre-injection copy (byte-identical) and by a repository-wide grep for the injection markers (none).

| Injection | Result |
| --- | --- |
| Delete the `if (!lock.locked()) return false;` guard, so a refused attempt publishes anyway | `74 passed, 1 failed` — `engine_try_update_eq_is_refused_while_a_peer_holds_the_token` fails at `!published` (`test_engine.cpp:1352`) |
| Make `tryLock()` blocking (`lock(); return true;`), i.e. the pre-fix acquisition | The same test never completes: no `✓` after its banner, killed after 20 s. This is the old audio-thread behaviour reproduced — a stall, not a wrong number. |

### G.3 This round's gates

Every line was produced by a run made after the changes in §G.2 landed. No number is carried over from §D or §F.5.

| Gate | This round's result |
| --- | --- |
| DSP suite, Release, universal (`make test-dsp` → `ctest`) | **75 passed, 0 failed**; `ctest` 1/1 passed; `lipo -info` reports `x86_64 arm64` |
| Same universal binary, x86_64 slice executed | `arch -x86_64 …` — **75 passed, 0 failed**, exit 0 (arm64 is the native run above) |
| DSP suite, RelWithDebInfo + ThreadSanitizer, `halt_on_error=1` | **75 passed, 0 failed**, exit 0, zero `WARNING: ThreadSanitizer` |
| DSP suite, Debug + AddressSanitizer, `detect_leaks=0` | **75 passed, 0 failed**, exit 0, zero `ERROR: AddressSanitizer` |
| DSP suite, RelWithDebInfo + UBSan, `print_stacktrace=1` | **75 passed, 0 failed**, exit 0, zero `runtime error` |
| F-01 failure injection (in-suite) | Injected `ASSERT_EQ(1, 2)`: binary **exit 1**, `Results: 74 passed, 1 failed`, `ctest` **exit 8** with `***Failed`. Injection removed: `ctest` exit 0, 100 % passed. The failing path is real, not assumed. |
| A/B, refusal guard removed (§G.2) | `74 passed, 1 failed` at `!published` |
| A/B, `tryLock()` made blocking (§G.2) | stall reproduced; killed after 20 s |
| Injection reversion | `shasum` of `engine.cpp` and `config_mailbox.h` identical to the pre-injection copies; repository-wide grep for the injection markers returns nothing |
| `make protocol-check` | exit 0 — protocol header 4 files identical, DSP headers 2 files identical |
| `make test` (whole repository) | exit 0 — Host **399/399**, App **298/298**, Driver 3/3 suites, install transaction **168/168** scenarios, installer gate **99 passed / 0 failed**, unsigned-release policy **97 checks / 0 failures**, version **13 sources / 0 failed** |
| `packages/host` `swift build -c release` | `Build complete!`, exit 0 — run before **and** after the final header sync |
| `apps/mac/SoundBridgeApp` `swift build -c release` | `Build complete!`, exit 0 |

### G.4 Residual risk after this round

1. **Control-side setters still wait.** `update_band_gain`, `update_preamp`, `update_band_frequency` and `update_band_q` keep the blocking acquisition. They are documented as control-thread calls in both header copies. A caller that puts one on a realtime thread reintroduces exactly the defect §G.2 closes — the library cannot detect it.
2. **A refused batch costs latency, not data.** `lastEQSnapshot` is not advanced on a refusal, so the next block retries with the same values. If a control thread is descheduled while holding the token, the EQ change waits; the audio callback does not.
3. **`static_assert` is C++-only.** The size and offset assertions on `soundbridge_stats_t` guard C and C++ consumers. A Swift consumer compiled against the older header still gets the 8-byte overwrite described in §F.1; only the coordinated-rebuild discipline prevents it.
4. **F-19 remains deferred** (SwiftPM/CMake `.unsafeFlags`), with the migration plan in §E.5.
5. **Unchanged limits of the evidence:** no sanitizer run covers the Swift side, there is no x86_64 sanitizer run (the sanitizer builds are single-architecture), and nothing here measures hardware latency, thermals or power-loss behaviour.

---

## H. Final Verdict

**PASS — DSP CORE CORRECTNESS AND CONCURRENCY; SOURCE-COMPATIBLE; NO BINARY ABI PROMISE.**

- All 20 findings are resolved except F-19, which the audit permitted to be deferred and which now has a written migration plan; F-21 required no action.
- The two P1 findings — a test suite that could not fail, and a documented thread-safety contract that was a data race — are fixed at the level of structure, not symptom, and each is now guarded by tests that would fail if the defect returned.
- The concurrency architecture is one coherent mechanism (a bounded triple-buffered mailbox with explicit ownership, MPSC via a publisher token, coefficients computed on the publisher, and per-block consumption), not a set of scattered atomics.
- The evidence is measured, not asserted: 75/75 DSP tests in Release (universal) and under ThreadSanitizer, AddressSanitizer and UBSan, all re-run in the verification round (§G.3); 399/399 Host tests and 298/298 App tests with no call-site change; the whole `make test` gate green; version, header and protocol consistency checks automated and proven to fail on drift; and a failure-injection experiment that shows the suite exits non-zero and CTest reports it.
- The limits of that evidence are stated in §D.8, §E and §G.4 rather than smoothed over: no sanitizer coverage of the Swift side, no x86_64 sanitizer run, no hardware-latency or power-loss claim, and control-thread setters that still wait for a peer publisher.

The library now implements the contract its header advertises. Where it cannot implement a contract (underrun accounting) the header says so and a test locks that statement.

The verdict separates six properties rather than collapsing them into one, because "the DSP computes the right numbers" and "this library can be dropped into an already-compiled binary" are different claims with different evidence:

| Property | Verdict | Basis |
| --- | --- | --- |
| **DSP correctness** | **PASS** | 75/75 in Release and under all three sanitizers (§G.3). The two numerically observable defects found across both audits (F-06's clamp/preamp preservation, R2's cancelled ramp) have tests that fail against the pre-fix code. |
| **Concurrency correctness** | **PASS** | 75/75 under ThreadSanitizer with `halt_on_error=1`, including MPSC (4 × 20 000 publishes), tearing, sustained-saturation and 100 000 index-rotation tests. R3 changed the consumer's exchange shape without touching index packing, slot ownership or memory orderings, and the pre-existing mailbox tests still pass. |
| **Realtime bounded work (consumer path)** | **PASS** | One acquire load and at most one compare-exchange per block; no loop, no allocation, no lock, no blocking wait. The failure path leaves `state_` untouched and the pending publication visible. |
| **Realtime bounded work (producer path, audio callback)** | **PASS** | `soundbridge_dsp_try_update_eq()`: one token attempt, one publish, no retry, no allocation, no I/O — and the Host's render callback uses it (§G.2). The refusal path is exercised deterministically by holding the token, and against a blocking acquisition the test stalls instead of passing. Scope: this is bounded, not wait-free, and only for this entry point; the other setters are control-thread calls that still wait (§E.1, §G.4). |
| **Source compatibility** | **PASS** | No existing public function signature or symbol was changed. One new public entry point, `soundbridge_dsp_try_update_eq()`, was added. Both public headers are single-sourced and checked by `make protocol-check`; every consumer in the tree rebuilt against them; `soundbridge_stats_t` is append-only, so existing field offsets and alignment are unchanged. |
| **Binary ABI compatibility** | **NOT PROMISED** | `soundbridge_stats_t` grew from 32 to 40 bytes. A caller compiled against the previous header and linked to this library gets an 8-byte out-of-bounds write from `get_stats()`, and nothing detects it. The product contract is source compatibility with coordinated rebuilding, documented in the header and enforced by `static_assert`s on size and offsets; a versioned stats entry point is the prerequisite for any binary guarantee. |
